import Foundation
import HealthKit
import Observation

/// Runs the watch's workout session and mirrors it to the iPhone — plan of record step 1 in
/// `docs/WATCHOS_RECORDER_PLAN.md`: **does the phone launch this app, and can the two talk?**
///
/// The phone decides, the watch records. This type makes no decisions about the workout; it starts
/// the session when told, reports what its sensors see, and ends when told.
///
/// **Step 1 discards the workout instead of saving it.** Every test launch would otherwise leave a
/// short fake run in the owner's Health record. Saving arrives with step 2, together with the route
/// and the checks that the result carries no less data than Apple's own Workout app records.
@MainActor
@Observable
final class WatchWorkoutController: NSObject {

    /// One instance, because the app delegate (a phone launch) and the screen (a local start) must
    /// both reach the same session.
    static let shared = WatchWorkoutController()

    private static let statusInterval: TimeInterval = 5

    // MARK: - Observable state, all of it shown on the watch

    private(set) var isRunning = false
    private(set) var origin: WatchWorkoutOrigin?
    private(set) var startedAt: Date?
    private(set) var sessionState = "not started"
    /// Plain words for the mirroring state: the phone link is the thing step 1 measures.
    private(set) var mirroring = "not started" {
        didSet { WatchEventLog.shared.record("iPhone link: \(mirroring)") }
    }
    private(set) var heartRate: Double?
    private(set) var pingsAnswered = 0
    private(set) var lastPingAt: Date?
    private(set) var statusesSent = 0
    /// Every failure lands here verbatim, and in the saved event log. Nothing on this path fails
    /// quietly.
    private(set) var lastError: String? {
        didSet {
            if let lastError { WatchEventLog.shared.record("ERROR: \(lastError)") }
        }
    }

    /// When the phone's `startWatchApp` last reached this app's code. Set before anything else can
    /// fail, so "the launch never arrived" and "it arrived and stalled" are told apart on screen —
    /// the first test of the link could not, because nothing showed until a session was running.
    private(set) var launchReceivedAt: Date?
    /// The last thing `start` got to. Read together with `launchReceivedAt`.
    private(set) var step = "idle" {
        didSet { WatchEventLog.shared.record("step: \(step)") }
    }
    /// Outcome of asking for Health access in the foreground. HealthKit does not reveal whether a
    /// *read* was granted, only whether the question has been answered, so this says "answered".
    private(set) var healthAccess = "not asked yet" {
        didSet { WatchEventLog.shared.record("Health access request: \(healthAccess)") }
    }

    /// One list, used both when asking up front and when checking at launch, so the two cannot drift
    /// apart — which is how the first link test stalled: the link asked for a type the probe never had.
    private static let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.heartRate),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
    ]

    // MARK: - Machinery

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private lazy var bridge = WatchSessionBridge(owner: self)

    // MARK: - Health access

    /// Asks for everything the link needs, from the foreground, where the permission sheet can
    /// actually appear. Called when the app's screen opens. A launch from the phone may arrive in
    /// the background, where a sheet has nowhere to show and a request can wait indefinitely.
    func prepareHealthAccess() async {
        healthAccess = "asking"
        do {
            try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
            healthAccess = "answered"
        } catch {
            healthAccess = "failed"
            lastError = "HealthKit authorization failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Start

    func start(configuration: HKWorkoutConfiguration, origin: WatchWorkoutOrigin) async {
        if origin == .phone {
            launchReceivedAt = Date()
        }
        guard !isRunning else {
            // A second launch from the phone while a session runs is plausible (a double tap).
            // Say so rather than silently starting nothing.
            lastError = "Ignored a start from the \(origin.rawValue): a session is already running."
            return
        }
        lastError = nil

        step = "checking Health access"
        let status: HKAuthorizationRequestStatus
        do {
            status = try await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes)
        } catch {
            step = "stopped"
            lastError = "Could not check Health access: \(error.localizedDescription)"
            return
        }
        WatchEventLog.shared.record("Health access status at launch: \(status.rawValue) (1 = would prompt, 2 = granted)")
        switch status {
        case .unnecessary:
            break
        case .shouldRequest:
            // Never wait on a sheet that may not be able to appear. Say what to do instead.
            step = "stopped"
            lastError = "Health access not granted yet. Open RunExporterWatch, allow Health access, "
                + "then start again from the phone."
            return
        case .unknown:
            step = "stopped"
            lastError = "HealthKit could not say whether access has been granted."
            return
        @unknown default:
            step = "stopped"
            lastError = "HealthKit returned an unknown authorization status (\(status.rawValue))."
            return
        }

        step = "starting session"
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                         workoutConfiguration: configuration)
            session.delegate = bridge
            builder.delegate = bridge
            self.session = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)

            self.origin = origin
            startedAt = now
            isRunning = true
            sessionState = "running"
            pingsAnswered = 0
            statusesSent = 0
            heartRate = nil
        } catch {
            step = "stopped"
            lastError = "Could not start the workout session: \(error.localizedDescription)"
            session = nil
            builder = nil
            return
        }

        step = "connecting to iPhone"
        await startMirroring()
    }

    /// A failure here leaves the workout running — it is still a valid local session — but the
    /// screen says plainly that the phone is not connected.
    private func startMirroring() async {
        guard let session else { return }
        mirroring = "connecting…"
        do {
            try await session.startMirroringToCompanionDevice()
            mirroring = "connected"
            step = "running"
            startStatusTimer()
            sendStatus()
        } catch {
            mirroring = "failed"
            step = "running, not connected"
            lastError = "Could not mirror to the iPhone: \(error.localizedDescription)"
        }
    }

    // MARK: - End

    func end() {
        guard isRunning, let session, let builder else { return }
        statusTimer?.invalidate()
        statusTimer = nil
        let now = Date()
        session.stopActivity(with: now)
        session.end()
        isRunning = false
        step = "ended"
        Task {
            do {
                try await builder.endCollection(at: now)
                builder.discardWorkout()   // Step 1: see the type comment.
            } catch {
                self.lastError = "Ending data collection failed: \(error.localizedDescription)"
            }
        }
        self.session = nil
        self.builder = nil
    }

    // MARK: - Talking to the phone

    private func startStatusTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.statusInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func sendStatus() {
        guard let startedAt, let origin else { return }
        send(.status(WatchStatus(sentAt: Date(), sessionStartedAt: startedAt,
                                 heartRate: heartRate, origin: origin))) { [weak self] in
            self?.statusesSent += 1
        }
    }

    private func send(_ message: WatchLinkMessage, onSent: (() -> Void)? = nil) {
        guard let session else { return }
        let data: Data
        do {
            data = try WatchLinkCodec.encode(message)
        } catch {
            lastError = "Could not encode a message for the phone: \(error.localizedDescription)"
            return
        }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
                onSent?()
            } catch {
                self.lastError = "Sending to the phone failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Callbacks, already on the main actor

    fileprivate func received(_ batch: [Data]) {
        for data in batch {
            do {
                switch try WatchLinkCodec.decode(data) {
                case let .ping(id, _):
                    let now = Date()
                    lastPingAt = now
                    pingsAnswered += 1
                    send(.pong(id: id, watchReceivedAt: now))
                case .endWorkout:
                    end()
                case .phaseBegan, .finishWorkout:
                    // Handled in watch plan step 2, stages 4–5. Until then, say so: silently dropping
                    // a phase or a finish would leave the watch showing the wrong thing, or not saving.
                    lastError = "This watch build cannot act on phase or finish messages yet."
                case .pong, .status:
                    lastError = "The phone sent a message only the watch should send."
                }
            } catch {
                lastError = "Could not read a message from the phone: \(error.localizedDescription)"
            }
        }
    }

    fileprivate func sessionChanged(to state: HKWorkoutSessionState) {
        sessionState = Self.name(for: state)
        WatchEventLog.shared.record("session: \(sessionState)")
        if state == .ended && isRunning {
            lastError = "The system ended the workout session."
            end()
        }
    }

    fileprivate func sessionFailed(_ error: Error) {
        lastError = "Workout session failed: \(error.localizedDescription)"
        sessionState = "failed"
    }

    fileprivate func mirroringDisconnected(_ error: Error?) {
        mirroring = "disconnected"
        statusTimer?.invalidate()
        statusTimer = nil
        if let error {
            lastError = "Lost the iPhone: \(error.localizedDescription)"
        }
    }

    fileprivate func heartRateUpdated(_ bpm: Double) {
        heartRate = bpm
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

/// Carries HealthKit's callbacks, which arrive on framework threads, to the main actor. Same
/// pattern, and same reasoning for `nonisolated(unsafe)`, as `SessionDelegateBridge` in
/// `BackgroundExecutionProbe.swift`: `owner` is written once in `init`, before HealthKit holds the
/// bridge, and every read hops straight back to the main actor.
private final class WatchSessionBridge: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated(unsafe) private weak var owner: WatchWorkoutController?

    init(owner: WatchWorkoutController) {
        self.owner = owner
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor [weak owner] in owner?.sessionChanged(to: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.sessionFailed(error) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor [weak owner] in owner?.received(data) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor [weak owner] in owner?.mirroringDisconnected(error) }
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let quantity = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity() else { return }
        // Read here, on HealthKit's thread, so only a Double crosses to the main actor.
        let bpm = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
        Task { @MainActor [weak owner] in owner?.heartRateUpdated(bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
