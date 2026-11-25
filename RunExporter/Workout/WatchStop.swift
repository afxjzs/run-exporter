import Foundation

/// The stop the phone owes the Watch when a run ends: save its workout, or discard it.
///
/// Until 2026-11-25 the phone sent the stop once and forgot it. On a real run that send failed
/// ("Remote device is unreachable"), the run screen still said the Watch had been asked to save,
/// and the Watch recorded for hours more although it reconnected within a minute. Now a
/// stop that was not delivered stays owed, the run screen says so, and it is sent again whenever a
/// Watch session mirrors to this phone. `WatchStopTests` lists every way this can go wrong.
///
/// The Watch takes the moment the stop *arrives* as the workout's end, so a late stop makes a
/// longer workout. History reads such a run only inside the phone's own timer (`RunClip`).
struct WatchStop: Equatable {
    enum Message: Equatable {
        /// Save the workout, tagged with the run's execution id when there is one.
        case save(executionID: UUID?)
        /// Discard it: the run was abandoned.
        case discard
    }

    enum State: Equatable {
        /// No run has ended since the last one started, or the run never reached the Watch.
        case none
        case sending(Message)
        case delivered(Message)
        /// Not delivered. Sent again when the Watch reconnects; until then it may still be recording.
        case owed(Message, reason: String)
    }

    private(set) var state: State = .none

    /// What the runner must be told while a stop is owed; nil otherwise. Shown on the finish alert
    /// and on Today until the stop is delivered. It never says to end the workout on the Watch:
    /// the Watch app's only control, End, discards it.
    var undeliveredWarning: String? {
        guard case let .owed(message, reason) = state else { return nil }
        let what: String
        switch message {
        case .save: what = "save it"
        case .discard: what = "discard it"
        }
        return "Your Watch may still be recording your last run. The phone's request to \(what) "
            + "didn't reach it (\(reason)). It's sent again as soon as the Watch reconnects: keep "
            + "the Watch near this phone with RunExporter open."
    }

    /// The run ended. Returns the message to send now, or nil when there is nothing to send now.
    ///
    /// `runReachedWatch`: whether a Watch session was connected at any point in this run. A run that
    /// lost the Watch mid-run still has a Watch workout recording, so its stop is owed.
    mutating func runEnded(_ message: Message, connected: Bool, runReachedWatch: Bool) -> Message? {
        guard runReachedWatch else {
            state = .none
            return nil
        }
        guard connected else {
            state = .owed(message, reason: "the Watch was not connected when the run ended")
            return nil
        }
        state = .sending(message)
        return message
    }

    /// A send finished; `error` is nil when it reached the Watch's session.
    mutating func sendFinished(_ message: Message, error: String?) {
        guard state == .sending(message) else { return }
        state = error.map { .owed(message, reason: $0) } ?? .delivered(message)
    }

    /// A Watch session mirrored to this phone. Returns the owed stop to send again, if any.
    mutating func reconnected() -> Message? {
        guard case let .owed(message, _) = state else { return nil }
        state = .sending(message)
        return message
    }

    /// A new run is starting. Returns the last run's stop if it was never delivered, so the caller
    /// can say so: that Watch workout may still be recording.
    mutating func runStarted() -> Message? {
        defer { state = .none }
        switch state {
        case let .owed(message, _), let .sending(message): return message
        case .none, .delivered: return nil
        }
    }
}
