import Foundation
import HealthKit
import Observation

/// Stage 2 of `docs/WATCHOS_RECORDER_PLAN.md` (§9) — **the foundational proof**.
///
/// The entire watch recorder rests on one unverified assumption: that an `HKWorkoutSession` grants
/// real background execution, so a timer keeps firing with the wrist down and the screen asleep.
/// This type exists only to measure that. **Build nothing on top of it until it passes.**
///
/// It is a probe, not production code. It starts a bare session, ticks once a second, and records
/// how long each gap between ticks actually was. A gap materially longer than the tick interval
/// means the app was suspended, and the premise fails.
///
/// ## Why the result is shown on screen, not just written to a file
///
/// The plan says to pull the log with `devicectl copy from`. That does not work against this Watch:
/// `xcrun devicectl` lists it as `available (paired)` and then times out on every query
/// (`CoreDeviceError 4000`). A five-minute test whose result cannot be read is not a test, so the
/// measurement is rendered on the watch face itself and the file is only a backup.
///
/// This mirrors what the audio work concluded: when the tooling cannot observe the device, the
/// person holding it is the instrument.
///
/// ## Reading the result
///
/// `worstGap` is the number that matters. With a 1 s tick:
/// * **~1 s** — background execution is working. Stage 2 passes.
/// * **Tens of seconds, or one huge gap ending when you raised your wrist** — the app was suspended
///   and resumed on wake. Stage 2 fails and the recorder premise is dead; stop and report.
@MainActor
@Observable
final class BackgroundExecutionProbe: NSObject {

    /// How often the probe ticks. One second gives enough resolution to distinguish "running
    /// normally" from "suspended and resumed" without generating an unreasonable log.
    private static let tickInterval: TimeInterval = 1.0

    /// A gap longer than this is counted as evidence of suspension rather than ordinary timer
    /// jitter. Timers are allowed to fire late; 2.5× the interval is comfortably outside jitter
    /// while still catching a real stall.
    private static let gapThreshold: TimeInterval = 2.5

    // MARK: - Observable state (all of it is rendered on the watch)

    private(set) var isRunning = false
    private(set) var sessionState: String = "not started"
    private(set) var tickCount = 0
    private(set) var startedAt: Date?
    private(set) var lastTickAt: Date?

    /// The longest interval observed between two consecutive ticks. **The headline result.**
    private(set) var worstGap: TimeInterval = 0

    /// How many gaps exceeded `gapThreshold`. One long gap and fifty small ones mean different
    /// things, so both the count and the worst case are kept.
    private(set) var gapCount = 0

    /// Surfaced verbatim in the UI. Nothing here fails quietly — an authorization refusal, a
    /// session error, or a failed file write all end up on the screen.
    private(set) var lastError: String?

    /// Where the backup log was written, shown so it can be found if the Watch ever becomes
    /// reachable by other means.
    private(set) var logFileName: String?

    // MARK: - Private

    // `@ObservationIgnored` on all of these: they are machinery, not screen state, so there is no
    // reason to register them with the observation system. It is also *required* on
    // `delegateBridge` — `@Observable` rewrites stored properties into computed ones, and `lazy`
    // is only legal on a stored property, so the two collide with a confusing
    // "'lazy' cannot be used on a computed property" error.
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var logURL: URL?
    @ObservationIgnored private lazy var delegateBridge = SessionDelegateBridge(owner: self)

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Start / stop

    func start() async {
        guard !isRunning else { return }
        lastError = nil

        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "HealthKit is not available on this device."
            return
        }

        // Workouts only, in both directions — the scope agreed in plan §6. Read access to heart
        // rate and active energy is what HKLiveWorkoutDataSource collects during a session; it is
        // not used by this probe, but requesting it here means the recorder does not trigger a
        // second permission sheet later.
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
        ]

        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            // A refusal is a legitimate outcome, but it must not look like a background-execution
            // failure — that is the exact confusion this probe exists to avoid.
            lastError = "HealthKit authorization failed: \(error.localizedDescription)"
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                         workoutConfiguration: configuration)
            session.delegate = delegateBridge

            self.session = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)

            startedAt = now
            lastTickAt = now
            tickCount = 0
            worstGap = 0
            gapCount = 0
            isRunning = true
            sessionState = "running"

            openLog(startedAt: now)
            startTimer()
        } catch {
            lastError = "Could not start the workout session: \(error.localizedDescription)"
            teardown()
        }
    }

    /// Ends the session. **Deliberately does NOT call `finishWorkout()`** — this probe measures
    /// background execution and has no business writing an `HKWorkout` into the user's Health
    /// record. Saving belongs to the real recorder, at plan stage 5.
    func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil

        appendToLog("STOP  ticks=\(tickCount) worstGap=\(formatted(worstGap)) gaps=\(gapCount)")

        session?.stopActivity(with: Date())
        session?.end()
        isRunning = false
        sessionState = "ended"
        teardown()
    }

    private func teardown() {
        session = nil
        builder = nil
    }

    // MARK: - The measurement

    private func startTimer() {
        // `.common` so the timer is not starved by UI tracking. The point of the probe is to
        // measure the system suspending us, not to measure our own run-loop mistakes.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        defer { lastTickAt = now }

        tickCount += 1

        guard let previous = lastTickAt else { return }
        let gap = now.timeIntervalSince(previous)
        if gap > worstGap { worstGap = gap }
        if gap > Self.gapThreshold {
            gapCount += 1
            // A gap is the finding, so it is logged conspicuously rather than blending in.
            appendToLog("GAP   \(formatted(gap)) after tick \(tickCount - 1)")
        }
        appendToLog("tick  \(tickCount) gap=\(formatted(gap)) state=\(sessionState)")
    }

    // MARK: - Backup log

    private func openLog(startedAt: Date) {
        let stamp = ISO8601DateFormatter().string(from: startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let name = "background-probe-\(stamp).log"
        guard let directory = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            lastError = "Could not locate the Documents directory; the backup log is not being written."
            return
        }
        let url = directory.appendingPathComponent(name)
        logURL = url
        logFileName = name
        appendToLog("START \(stamp) tickInterval=\(Self.tickInterval)s")
    }

    /// Appends one line. A failure here is reported but never stops the probe — the on-screen
    /// counters are the primary instrument and must survive a broken log.
    private func appendToLog(_ line: String) {
        guard let logURL else { return }
        let entry = line + "\n"
        guard let data = entry.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL)
            }
        } catch {
            lastError = "Backup log write failed: \(error.localizedDescription)"
            self.logURL = nil   // Stop retrying every second once it is known to be broken.
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", interval)
    }

    // MARK: - Session callbacks

    fileprivate func sessionChanged(to state: HKWorkoutSessionState) {
        sessionState = Self.name(for: state)
        appendToLog("STATE \(sessionState)")
        // If the system ends the session out from under us, the tick log would keep running and
        // look like a pass. Say so instead.
        if state == .ended && isRunning {
            lastError = "The system ended the workout session before you stopped it."
            isRunning = false
            timer?.invalidate()
            timer = nil
        }
    }

    fileprivate func sessionFailed(_ error: Error) {
        lastError = "Workout session failed: \(error.localizedDescription)"
        appendToLog("ERROR \(error.localizedDescription)")
        isRunning = false
        sessionState = "failed"
        timer?.invalidate()
        timer = nil
    }

    private static func name(for state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: return "not started"
        case .running: return "running"
        case .ended: return "ended"
        case .paused: return "paused"
        case .prepared: return "prepared"
        case .stopped: return "stopped"
        @unknown default: return "unknown (\(state.rawValue))"
        }
    }
}

/// Bridges HealthKit's delegate callbacks, which arrive on a framework thread, onto the main actor
/// where the probe's state lives. Mirrors the pattern `AudioCueEngine` uses on the phone.
private final class SessionDelegateBridge: NSObject, HKWorkoutSessionDelegate {
    /// `nonisolated(unsafe)` for the same reason as `AudioCueEngine.DelegateBridge.owner` on the
    /// phone, and it is safe for the same reason: this is written exactly once, on the main actor,
    /// in `init` — before the bridge is handed to HealthKit and therefore before any callback can
    /// read it. Reads happen on a framework thread and immediately hop back to the main actor.
    ///
    /// Without this the target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes the property
    /// main-actor isolated, and touching it from the `nonisolated` delegate methods warns (and
    /// becomes an error under stricter concurrency checking).
    nonisolated(unsafe) private weak var owner: BackgroundExecutionProbe?

    init(owner: BackgroundExecutionProbe) {
        self.owner = owner
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor [weak owner] in owner?.sessionChanged(to: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.sessionFailed(error) }
    }
}
