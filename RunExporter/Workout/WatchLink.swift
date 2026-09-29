import Foundation
import HealthKit
import Observation
import WatchConnectivity

/// The phone's end of the watch link — plan of record step 1 in `docs/WATCHOS_RECORDER_PLAN.md`.
///
/// Answers two questions by measurement, not by reading documentation:
/// 1. Does `HKHealthStore.startWatchApp(toHandle:)` launch the watch app, closed or not, and how
///    long until the watch's session is mirrored back here?
/// 2. Does the mirrored session's data channel carry messages both ways, and how fast?
///
/// Every step is timestamped on **this phone's clock** in `events`, and only phone timestamps are
/// ever subtracted from each other. The watch's times are shown but never mixed in — two devices'
/// clocks are not one clock, and a latency computed across them would be a guess.
@MainActor
@Observable
final class WatchLink: NSObject {

    struct Event: Identifiable {
        let id = UUID()
        let at: Date
        let text: String
        let isError: Bool
    }

    private(set) var events: [Event] = []
    private(set) var isLaunching = false
    /// The watch's session as the phone sees it. Nil until the watch starts mirroring.
    private(set) var sessionState: String?
    private(set) var latestStatus: WatchStatus?
    private(set) var latestStatusReceivedAt: Date?
    private(set) var statusesReceived = 0
    /// Round trips measured on the phone's clock, most recent last.
    private(set) var roundTrips: [TimeInterval] = []
    /// Lines of the watch's event log received this launch; each is also in `watch-events.log`.
    private(set) var watchLogLinesReceived = 0
    /// Set when a diagnostic file cannot be written. Shown on the test screen, never swallowed.
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

    // MARK: - Actions

    func launchWatchWorkout() async {
        guard !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }

        // The owner approved phone-side write access on 2026-09-25; README's Privacy section says
        // so. Whether startWatchApp strictly needs it is unmeasured — requesting it keeps that
        // question from masquerading as a launch failure.
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                                 read: [HKObjectType.workoutType(), HKQuantityType(.heartRate)])
        } catch {
            log("HealthKit authorization failed: \(error.localizedDescription)", isError: true)
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor

        let tapped = Date()
        launchTappedAt = tapped
        log("Asked the watch to start (startWatchApp)")
        do {
            try await store.startWatchApp(toHandle: configuration)
            log("startWatchApp returned success after \(Self.seconds(Date().timeIntervalSince(tapped)))")
        } catch {
            log("startWatchApp failed: \(error.localizedDescription)", isError: true)
        }
    }

    func ping() {
        let id = UUID()
        let sentAt = Date()
        pendingPings[id] = sentAt
        send(.ping(id: id, sentAt: sentAt), describe: "Ping sent")
    }

    func endWatchWorkout() {
        send(.endWorkout, describe: "Asked the watch to end")
    }

    func clearLog() {
        events.removeAll()
        roundTrips.removeAll()
    }

    /// Forgets this screen's view of the link so every button works again. Added after a test left
    /// all three disabled: `startWatchApp` never returned and the watch app had been killed, and the
    /// only way out was force-quitting the phone app. Does not reach the watch — a watch session
    /// that is still running stays running, which the log says.
    func reset() {
        let hadSession = mirroredSession != nil
        mirroredSession = nil
        isLaunching = false
        launchTappedAt = nil
        pendingPings.removeAll()
        sessionState = nil
        log("Reset this screen" + (hadSession ? "; a watch session may still be running on the watch" : ""))
    }

    // MARK: - Mirrored session

    private func attach(_ session: HKWorkoutSession) {
        mirroredSession = session
        session.delegate = bridge
        sessionState = "running"
        if let launchTappedAt {
            log("Watch session mirrored here, \(Self.seconds(Date().timeIntervalSince(launchTappedAt))) after the tap")
        } else {
            log("Watch session mirrored here (not started from this screen)")
        }
    }

    private func send(_ message: WatchLinkMessage, describe: String) {
        guard let session = mirroredSession else {
            log("\(describe): not sent, no watch session is connected", isError: true)
            return
        }
        let data: Data
        do {
            data = try WatchLinkCodec.encode(message)
        } catch {
            log("Could not encode a message: \(error.localizedDescription)", isError: true)
            return
        }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
                self.log(describe)
            } catch {
                self.log("\(describe): send failed: \(error.localizedDescription)", isError: true)
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
                    roundTrips.append(roundTrip)
                    log("Pong: round trip \(Self.seconds(roundTrip))")
                case let .status(status):
                    if statusesReceived == 0 {
                        log("First status from the watch")
                    }
                    latestStatus = status
                    latestStatusReceivedAt = now
                    statusesReceived += 1
                case .ping, .endWorkout, .phaseBegan, .finishWorkout:
                    log("The watch sent a message only the phone should send", isError: true)
                }
            } catch {
                log("Could not read a message from the watch: \(error.localizedDescription)", isError: true)
            }
        }
    }

    fileprivate func sessionChanged(to state: HKWorkoutSessionState) {
        sessionState = Self.name(for: state)
        log("Watch session is now \(Self.name(for: state))")
        if state == .ended {
            mirroredSession = nil
        }
    }

    fileprivate func sessionFailed(_ error: Error) {
        log("Watch session failed: \(error.localizedDescription)", isError: true)
    }

    fileprivate func disconnected(_ error: Error?) {
        mirroredSession = nil
        sessionState = "disconnected"
        if let error {
            log("Disconnected from the watch: \(error.localizedDescription)", isError: true)
        } else {
            log("Disconnected from the watch")
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
                watchLogLinesReceived += 1
            } catch {
                fileError = "Could not save the watch's log: \(error.localizedDescription)"
            }
        }
    }

    fileprivate func connectivityProblem(_ text: String) {
        log(text, isError: true)
    }

    // MARK: - Helpers

    private func log(_ text: String, isError: Bool = false) {
        let now = Date()
        events.append(Event(at: now, text: text, isError: isError))
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

    static func seconds(_ interval: TimeInterval) -> String {
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
