import Foundation
import Observation
import WatchConnectivity

/// A timestamped record of what this app did, **kept across launches**.
///
/// The first link tests could not tell "the phone's launch never reached this app" from "it
/// reached it, stalled, and the system closed the app before anyone looked": the only breadcrumb
/// lived in memory and died with the process. `devicectl` cannot reach this Watch and its logs are
/// out of reach, so this screen-readable log is the instrument.
///
/// Stored in `UserDefaults` as preformatted lines — nothing to encode, so nothing that can fail to
/// save. Capped so it cannot grow without bound.
@MainActor
@Observable
final class WatchEventLog {
    static let shared = WatchEventLog()

    private static let key = "watchEventLog"
    private static let capacity = 60

    /// Newest last.
    private(set) var lines: [String]

    private init() {
        lines = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func record(_ text: String) {
        let stamp = Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .secondFraction(.fractional(1)))
        let line = "\(stamp)  \(text)"
        lines.append(line)
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
        UserDefaults.standard.set(lines, forKey: Self.key)
        WatchLogForwarder.shared.forward(line)
    }

    /// Clears the watch's copy only. Every line already went to the phone's
    /// `Documents/watch-events.log`, so clearing here loses nothing — which is the point: this
    /// button once took the only evidence of a successful launch with it.
    func clear() {
        lines.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// Sends every event-log line to the iPhone app, which appends it to `Documents/watch-events.log`
/// where it can be pulled with `devicectl` — this Watch cannot be reached by `devicectl` itself.
///
/// `transferUserInfo` is queued and delivered by the system, even if this app is killed or the
/// phone app is not running, so a line recorded just before the app dies still arrives. Lines
/// recorded before the session finishes activating are held and sent once it has. WatchConnectivity
/// is watchOS 2+, so legal on the Series 5.
@MainActor
final class WatchLogForwarder {
    static let shared = WatchLogForwarder()

    private var pending: [String] = []
    private var isActivated = false
    private lazy var bridge = WatchLogForwarderBridge(owner: self)

    private init() {}

    /// Called once at launch, from the app's `init`.
    func activate() {
        guard WCSession.isSupported() else {
            WatchEventLog.shared.record("ERROR: WatchConnectivity is not supported; the phone will not receive this log")
            return
        }
        WCSession.default.delegate = bridge
        WCSession.default.activate()
    }

    func forward(_ line: String) {
        guard isActivated else {
            pending.append(line)
            return
        }
        WCSession.default.transferUserInfo([WatchLogTransfer.key: [line]])
    }

    fileprivate func activationCompleted(_ state: WCSessionActivationState, error: String?) {
        if let error {
            // Recorded locally; it cannot be forwarded, which is exactly what it reports.
            WatchEventLog.shared.record("ERROR: phone log link failed to activate: \(error)")
            return
        }
        guard state == .activated else {
            WatchEventLog.shared.record("ERROR: phone log link activation ended in state \(state.rawValue)")
            return
        }
        isActivated = true
        if !pending.isEmpty {
            WCSession.default.transferUserInfo([WatchLogTransfer.key: pending])
            pending.removeAll()
        }
    }
}

private final class WatchLogForwarderBridge: NSObject, WCSessionDelegate {
    nonisolated(unsafe) private weak var owner: WatchLogForwarder?

    init(owner: WatchLogForwarder) {
        self.owner = owner
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor [weak owner] in owner?.activationCompleted(activationState, error: message) }
    }
}

/// The build this app was built as, so "is the new build on the Watch?" is answered by looking.
/// `CFBundleVersion` is set to a build timestamp by `scripts/sideload.sh`; the phone shows the same
/// number in Settings → Version, so matching numbers mean matching builds.
enum WatchBuildInfo {
    static var label: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
