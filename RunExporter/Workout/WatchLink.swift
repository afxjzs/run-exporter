import Foundation
import HealthKit
import Observation
import WatchConnectivity

/// The phone's end of the watch link (plan of record in `docs/WATCHOS_RECORDER_PLAN.md`).
///
/// For a run, the run screen's Start calls `beginRun`: this launches the watch app with
/// `HKHealthStore.startWatchApp(toHandle:)`, receives its mirrored session, sends each phase as a
/// `PhaseAnchor`, and at the end asks the watch to save (`finishRun`) or discard (`abandonRun`). A
/// launch that fails or times out leaves the run phone-only, reported through `runConnection`.
/// (The Settings link test screen that step 1 used was removed in the 2026-09-29 clean-out.)
///
/// Every step is written to `watch-link-phone.log` timestamped on **this phone's clock**, and only
/// phone timestamps are ever subtracted from each other. Two devices' clocks are not one clock,
/// and a latency computed across them would be a guess.
@MainActor
@Observable
final class WatchLink: NSObject {

    private(set) var latestStatus: WatchStatus?
    /// True while the watch may be showing the wrong phase: the latest phase message failed to send.
    /// Cleared when a resend gets through. Measured on the first real outdoor run: one
    /// "Remote device is unreachable" left the watch on WALK through a whole run leg, with nothing
    /// on the phone saying so.
    private(set) var phaseUnsent = false
    /// Round trips measured on the phone's clock, most recent last.
    private(set) var roundTrips: [TimeInterval] = []
    /// Set when a diagnostic file cannot be written. Shown on the run screen, never swallowed —
    /// those files are how a failed Watch run gets diagnosed afterwards.
    private(set) var fileError: String?

    /// Both pulled with `devicectl device copy from … --source Documents/<name>`.
    @ObservationIgnored private let phoneLogFile = DiagnosticLogFile.inDocuments(named: "watch-link-phone.log")
    @ObservationIgnored private let watchLogFile = DiagnosticLogFile.inDocuments(named: "watch-events.log")

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var mirroredSession: HKWorkoutSession?
    @ObservationIgnored private var launchTappedAt: Date?
    @ObservationIgnored private var pendingPings: [UUID: Date] = [:]
    @ObservationIgnored private lazy var bridge = PhoneSessionBridge(owner: self)
    @ObservationIgnored private lazy var connectivityBridge = PhoneConnectivityBridge(owner: self)

    override init() {
        super.init()
        // WatchConnectivity carries the watch's event log here (see `WatchLogTransfer`). Activated
        // at launch because queued transfers are delivered to an activated session.
        if WCSession.isSupported() {
            WCSession.default.delegate = connectivityBridge
            WCSession.default.activate()
        } else {
            log("WatchConnectivity is not supported; the watch's log cannot arrive", isError: true)
        }
        // HealthKit's header: assign this "promptly after your app is launched". The system may
        // launch this app in the background purely to deliver a mirrored session, and a handler
        // installed later — say, when a screen appears — would miss it.
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor [weak self] in self?.attach(session) }
        }
    }

    var isConnected: Bool { mirroredSession != nil }

    // MARK: - A real run (watch plan step 2)

    /// The watch as the run screen sees it.
    enum RunConnection: Equatable {
        /// No run is using the watch.
        case off
        case connecting
        case connected
        /// The launch failed or timed out. The run carries on phone-only; the screen offers Try again.
        case failed(String)
        /// Was connected, and the link dropped.
        case disconnected(String)
    }

    private(set) var runConnection: RunConnection = .off

    /// True when the last run ended by asking the watch to save its workout. A request, not a
    /// confirmation — the phone cannot see the watch save — and false for a run the watch was not
    /// connected to at the finish, so the finish screen never implies a watch workout that is not there.
    private(set) var lastRunAskedWatchToSave = false

    /// How long a launch may take before it is reported as failed. Measured 2026-09-29: the watch
    /// was running and mirrored 1.71 s after the tap, from a killed app. Before this, a launch that
    /// never answered left the test screen stuck with every button disabled.
    static let launchTimeoutSeconds: TimeInterval = 15

    /// Builds the anchor for the phase in progress *at the moment it is called*, given the current
    /// latency estimate — so a watch that connects 1.7 s into a phase is sent where the phase is
    /// now, not where it was at the tap. Nil when no run is using the watch.
    /// Guards against a second launch while one is in flight. Not shown anywhere, so not observed.
    @ObservationIgnored private var isLaunching = false
    @ObservationIgnored private var anchorProvider: ((TimeInterval) -> PhaseAnchor?)?
    /// Counts phase sends, so only the latest one's result sets `phaseUnsent`.
    @ObservationIgnored private var phaseSendNumber = 0
    /// The run's plan activity, so a Try again launches the same workout as the first attempt.
    @ObservationIgnored private var runActivityType: PlannedActivityType = .running
    @ObservationIgnored private var launchTimeout: Task<Void, Never>?
    /// True once the watch's log shows this launch reached its code. See `reportWatchErrorDuringLaunch`.
    @ObservationIgnored private var sawLaunchArriveOnWatch = false

    /// The one-way delay `PhaseClock` subtracts: half the **smallest** round trip (`LatencyEstimate`).
    /// It was the median until 2026-09-29, when the only sample was the connect-time ping at 1.71 s
    /// and the watch subtracted 0.86 s it should not have.
    var oneWayLatencyEstimate: TimeInterval {
        LatencyEstimate.oneWay(fromRoundTrips: roundTrips)
    }

    /// Pings sent when the link connects. The first waits for the fresh channel, so it is never the
    /// estimate on its own; the minimum over several is.
    static let connectPings = 3

    /// Starts the watch's workout for a run. Called from the run screen's Start.
    ///
    /// `activityType` is the plan's, and is kept for Try again: the Watch records exactly this.
    func beginRun(activityType: PlannedActivityType, anchor: @escaping (TimeInterval) -> PhaseAnchor?) {
        runActivityType = activityType
        anchorProvider = anchor
        lastRunAskedWatchToSave = false
        log("Run started; connecting to the watch")
        connectForRun()
    }

    /// The run screen's Try again.
    func retryRun() {
        guard anchorProvider != nil else { return }
        log("Try again")
        connectForRun()
    }

    /// The engine's phase changed: send the watch where the run is now.
    func phaseChanged() {
        guard anchorProvider != nil, isConnected else { return }
        sendCurrentPhase()
    }

    /// The run ended normally: the watch saves its workout, tagged with the phone's execution id —
    /// or untagged when there is none, in which case the phone joins it by start time, the same
    /// fallback any untagged workout gets. It used to be discarded instead.
    func finishRun(executionID: UUID?) {
        guard anchorProvider != nil else { return }
        endRun()
        guard isConnected else {
            // Said, not assumed: no watch workout exists to save, so the run has no watch data.
            log("Run finished with the watch not connected; the watch saved nothing", isError: true)
            return
        }
        send(.finishWorkout(executionID: executionID),
             describe: executionID == nil
                ? "No execution id to tag it with; asked the watch to save the workout untagged"
                : "Asked the watch to save the workout")
        lastRunAskedWatchToSave = true
    }

    /// The run was abandoned: the watch discards its workout.
    func abandonRun() {
        guard anchorProvider != nil else { return }
        endRun()
        if isConnected {
            send(.endWorkout, describe: "Run abandoned; asked the watch to discard the workout")
        }
    }

    private func endRun() {
        anchorProvider = nil
        launchTimeout?.cancel()
        launchTimeout = nil
        runConnection = .off
        phaseUnsent = false
    }

    private func connectForRun() {
        if isConnected {
            runConnection = .connected
            sendCurrentPhase()
            return
        }
        runConnection = .connecting
        sawLaunchArriveOnWatch = false
        launchTimeout?.cancel()
        launchTimeout = Task { [weak self] in
            // Cancellation — the link connected, or the run ended — is the normal way this ends;
            // it is signalled by `isCancelled`, so the sleep's own CancellationError carries nothing.
            try? await Task.sleep(for: .seconds(Self.launchTimeoutSeconds))
            guard !Task.isCancelled, let self, self.runConnection == .connecting else { return }
            // The likely fix is named here because the watch's own reason can arrive too late: on
            // a real run its "Health access not granted yet" reached this phone 35 s after the tap,
            // well after this message. A build that adds a Health type needs that grant, on the
            // watch, once.
            let reason = "The Watch did not respond within \(Int(Self.launchTimeoutSeconds)) s. "
                + "If the Watch app is asking for Health access, allow it there, then tap Try again."
            self.runConnection = .failed(reason)
            self.log(reason, isError: true)
        }
        Task { [weak self] in
            guard let self else { return }
            if let error = await self.launchWatchWorkout(activityType: self.runActivityType),
               self.runConnection == .connecting {
                self.launchTimeout?.cancel()
                self.runConnection = .failed(error)
            }
        }
    }

    private func sendCurrentPhase() {
        guard let anchor = anchorProvider?(oneWayLatencyEstimate) else {
            log("No phase to send to the watch at this moment")
            return
        }
        phaseSendNumber += 1
        let number = phaseSendNumber
        send(.phaseBegan(anchor), describe: "Phase sent: \(anchor.phase.rawValue)"
             + (anchor.isPaused ? " (paused)" : "")) { [weak self] sent in
            // Only the latest send decides: an older send finishing late must not clear, or set,
            // the flag for a newer phase.
            guard let self, number == self.phaseSendNumber else { return }
            self.phaseUnsent = !sent
        }
    }

    // MARK: - Actions

    /// The workout the Watch is asked to record: the plan's activity, outdoors.
    ///
    /// Was a hardcoded `.running` until 2026-09-30, so a Walking plan was saved to Health as an
    /// Outdoor Run with nothing on either screen saying so. The `switch` is exhaustive on purpose:
    /// a new plan activity cannot compile until it is mapped here.
    nonisolated static func workoutConfiguration(for activityType: PlannedActivityType) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        switch activityType {
        case .running: configuration.activityType = .running
        case .walking: configuration.activityType = .walking
        }
        configuration.locationType = .outdoor
        return configuration
    }

    /// Asks the watch to start its workout. Returns why it failed, or nil once the request has been
    /// **sent** — `startWatchApp` succeeding says nothing about the watch (docs/WATCH_DEVELOPMENT.md).
    private func launchWatchWorkout(activityType: PlannedActivityType) async -> String? {
        guard !isLaunching else { return nil }
        isLaunching = true
        defer { isLaunching = false }

        // The owner approved phone-side write access on 2026-09-25; README's Privacy section says
        // so. Whether startWatchApp strictly needs it is unmeasured — requesting it keeps that
        // question from masquerading as a launch failure.
        do {
            // The UI smoke test, Debug builds only (`UITesting`). The simulator has no Watch, so the
            // launch below fails either way and the run screen reports it.
            if !UITesting.skipsHealthAuthorization {
                try await store.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                                     read: [HKObjectType.workoutType(), HKQuantityType(.heartRate)])
            }
        } catch {
            let message = "HealthKit authorization failed: \(error.localizedDescription)"
            log(message, isError: true)
            return message
        }

        let configuration = Self.workoutConfiguration(for: activityType)

        let tapped = Date()
        launchTappedAt = tapped
        log("Asked the watch to start (startWatchApp), activity \(activityType.rawValue)")
        do {
            try await store.startWatchApp(toHandle: configuration)
            log("startWatchApp returned success after \(Self.seconds(Date().timeIntervalSince(tapped)))")
            return nil
        } catch {
            let message = "Could not start the Watch: \(error.localizedDescription)"
            log(message, isError: true)
            return message
        }
    }

    private func ping() {
        let id = UUID()
        let sentAt = Date()
        pendingPings[id] = sentAt
        send(.ping(id: id, sentAt: sentAt), describe: "Ping sent")
    }

    /// Dismisses the file-write problem on the run screen. The next failed write sets it again.
    func clearFileError() {
        fileError = nil
    }

    // MARK: - Mirrored session

    private func attach(_ session: HKWorkoutSession) {
        mirroredSession = session
        session.delegate = bridge
        if let launchTappedAt {
            log("Watch session mirrored here, \(Self.seconds(Date().timeIntervalSince(launchTappedAt))) after the tap")
        } else {
            log("Watch session mirrored here (not started by this launch of the app)")
        }
        guard anchorProvider != nil else { return }
        launchTimeout?.cancel()
        launchTimeout = nil
        runConnection = .connected
        // Tell the watch where the run is now, then measure the delay its clock must allow for.
        // Each pong that improves the estimate re-sends the phase (see `received`).
        sendCurrentPhase()
        Task { [weak self] in
            for index in 0..<Self.connectPings {
                if index > 0 {
                    // Spacing only; an early wake-up is harmless, so the sleep's error carries nothing.
                    try? await Task.sleep(for: .seconds(1))
                }
                guard let self, self.isConnected else { return }
                self.ping()
            }
        }
    }

    /// `sent` is told whether the message reached the watch's session; a failure is logged either way.
    private func send(_ message: WatchLinkMessage, describe: String, sent: ((Bool) -> Void)? = nil) {
        guard let session = mirroredSession else {
            log("\(describe): not sent, no watch session is connected", isError: true)
            sent?(false)
            return
        }
        let data: Data
        do {
            data = try WatchLinkCodec.encode(message)
        } catch {
            log("Could not encode a message: \(error.localizedDescription)", isError: true)
            sent?(false)
            return
        }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
                self.log(describe)
                sent?(true)
            } catch {
                self.log("\(describe): send failed: \(error.localizedDescription)", isError: true)
                sent?(false)
            }
        }
    }

    // MARK: - Callbacks, already on the main actor

    fileprivate func received(_ batch: [Data]) {
        let now = Date()
        for data in batch {
            do {
                switch try WatchLinkCodec.decode(data) {
                case let .pong(id, _):
                    guard let sentAt = pendingPings.removeValue(forKey: id) else {
                        log("Pong for a ping this phone has no record of", isError: true)
                        continue
                    }
                    let roundTrip = now.timeIntervalSince(sentAt)
                    let before = oneWayLatencyEstimate
                    roundTrips.append(roundTrip)
                    log("Pong: round trip \(Self.seconds(roundTrip))")
                    // A better estimate is worth sending: the watch re-anchors the phase in progress,
                    // which is not a boundary, so it corrects the countdown and splits nothing.
                    if anchorProvider != nil, isConnected, oneWayLatencyEstimate < before || before == 0 {
                        sendCurrentPhase()
                    }
                case let .status(status):
                    if latestStatus == nil {
                        log("First status from the watch")
                    }
                    latestStatus = status
                    // A status arriving proves the link works again: resend where the run is now.
                    if phaseUnsent, anchorProvider != nil, isConnected {
                        log("Resending the phase after a failed send")
                        sendCurrentPhase()
                    }
                case .ping, .endWorkout, .phaseBegan, .finishWorkout:
                    log("The watch sent a message only the phone should send", isError: true)
                }
            } catch {
                log("Could not read a message from the watch: \(error.localizedDescription)", isError: true)
            }
        }
    }

    fileprivate func sessionChanged(to state: HKWorkoutSessionState) {
        log("Watch session is now \(Self.name(for: state))")
        if state == .ended {
            mirroredSession = nil
            if anchorProvider != nil {
                runConnection = .disconnected("The Watch's workout ended.")
            }
        }
    }

    fileprivate func sessionFailed(_ error: Error) {
        log("Watch session failed: \(error.localizedDescription)", isError: true)
    }

    fileprivate func disconnected(_ error: Error?) {
        mirroredSession = nil
        let reason = error.map { "Lost the Watch: \($0.localizedDescription)" } ?? "Lost the Watch."
        if error != nil {
            log(reason, isError: true)
        } else {
            log("Disconnected from the watch")
        }
        if anchorProvider != nil {
            runConnection = .disconnected(reason)
        }
    }

    fileprivate func receivedWatchLog(_ lines: [String]) {
        guard let watchLogFile else {
            fileError = "No Documents folder; the watch's log cannot be saved."
            return
        }
        let receivedAt = Self.stamp(Date())
        for line in lines {
            do {
                try watchLogFile.append("received \(receivedAt) | watch \(line)")
            } catch {
                fileError = "Could not save the watch's log: \(error.localizedDescription)"
            }
            reportWatchErrorDuringLaunch(line)
        }
    }

    /// While a run is waiting for the watch, an error the watch reports is the real reason it has not
    /// connected — say it now. Measured 2026-09-29: the watch's "Health access not granted yet" reached
    /// this phone 2.5 s after the tap, and the screen still waited out the 15 s timeout and then said
    /// only that the watch had not responded.
    ///
    /// The watch's log is a queue, so an old error from an earlier session can arrive during a new
    /// launch. The two clocks cannot be compared to filter it, so order does it instead: the watch
    /// logs `handle(workoutConfiguration) called` first on every phone launch, and only an error
    /// after that line, within this connecting window, is about this launch.
    private func reportWatchErrorDuringLaunch(_ line: String) {
        guard runConnection == .connecting else { return }
        if line.contains("handle(workoutConfiguration) called") {
            sawLaunchArriveOnWatch = true
            return
        }
        guard sawLaunchArriveOnWatch, let range = line.range(of: "ERROR: ") else { return }
        let reason = "The Watch reported: " + line[range.upperBound...]
        launchTimeout?.cancel()
        launchTimeout = nil
        runConnection = .failed(reason)
        log(reason, isError: true)
    }

    fileprivate func connectivityProblem(_ text: String) {
        log(text, isError: true)
    }

    // MARK: - Helpers

    private func log(_ text: String, isError: Bool = false) {
        let now = Date()
        guard let phoneLogFile else {
            fileError = "No Documents folder; phone link events are not being saved."
            return
        }
        do {
            try phoneLogFile.append("\(Self.stamp(now))  \(isError ? "ERROR: " : "")\(text)")
        } catch {
            // Shown on screen rather than logged, since the log is what failed.
            fileError = "Could not save phone link events: \(error.localizedDescription)"
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", interval)
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

/// Carries WatchConnectivity's callbacks to the main actor. Only the plain values cross — the
/// `[String]` of log lines, an error's text — never the `userInfo` dictionary itself.
private final class PhoneConnectivityBridge: NSObject, WCSessionDelegate {
    nonisolated(unsafe) private weak var owner: WatchLink?

    init(owner: WatchLink) {
        self.owner = owner
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let problem: String?
        if let error {
            problem = "Watch log link failed to activate: \(error.localizedDescription)"
        } else if activationState != .activated {
            problem = "Watch log link activation ended in state \(activationState.rawValue)"
        } else {
            problem = nil
        }
        guard let problem else { return }
        Task { @MainActor [weak owner] in owner?.connectivityProblem(problem) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let value = userInfo[WatchLogTransfer.key] else {
            let keys = userInfo.keys.sorted().joined(separator: ", ")
            Task { @MainActor [weak owner] in
                owner?.connectivityProblem("Received watch data with unknown keys: \(keys)")
            }
            return
        }
        guard let lines = value as? [String] else {
            Task { @MainActor [weak owner] in
                owner?.connectivityProblem("Received a watch log that is not a list of lines")
            }
            return
        }
        Task { @MainActor [weak owner] in owner?.receivedWatchLog(lines) }
    }

    // Required on iOS: the session goes inactive when the user switches watches. Reactivating is
    // Apple's documented response to `didDeactivate`.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

/// Carries HealthKit's callbacks, which arrive on framework threads, to the main actor. Same
/// pattern as the watch's `WatchSessionBridge`: `owner` is written once in `init`, before HealthKit
/// holds the bridge, and every read hops straight back to the main actor.
private final class PhoneSessionBridge: NSObject, HKWorkoutSessionDelegate {
    nonisolated(unsafe) private weak var owner: WatchLink?

    init(owner: WatchLink) {
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
        Task { @MainActor [weak owner] in owner?.disconnected(error) }
    }
}
