import Foundation

/// A phase on the **watch's** clock, built from a `PhaseAnchor` the moment it arrives.
///
/// The phone sends durations ("12 s in, 168 s left"); this turns them into a countdown and a phase
/// start date on the watch's own clock, so the two devices' clocks are never compared. Error is the
/// one-way message delay the anchor estimates — about 0.07 s measured on 2026-09-29 — far below the
/// whole seconds the screen shows. Every new anchor re-anchors, so error cannot accumulate.
///
/// Pure: all times are passed in. Tested in `WatchPhaseSyncTests`.
struct PhaseClock: Equatable, Sendable {
    let anchor: PhaseAnchor
    /// Watch clock, when the anchor arrived.
    let receivedAt: Date

    /// When the phase began, on the watch's clock — the date its workout event is written with.
    var phaseStartedAt: Date {
        receivedAt.addingTimeInterval(-(anchor.oneWayLatency + anchor.elapsedAtSend))
    }

    /// Seconds into the phase at `now`. Frozen while paused.
    func elapsed(at now: Date) -> TimeInterval {
        anchor.isPaused ? anchor.elapsedAtSend : anchor.elapsedAtSend + sinceSent(now)
    }

    /// Seconds left at `now`: nil for an open-ended phase, frozen while paused, and never below 0 —
    /// with `isOverdue` saying so when 0 is not the truth.
    func remaining(at now: Date) -> TimeInterval? {
        guard let raw = rawRemaining(at: now) else { return nil }
        return max(0, raw)
    }

    /// The phase should have ended and the phone's next anchor has not arrived. Shown on the watch,
    /// so a late message reads as late rather than as a phase stuck at 0:00.
    func isOverdue(at now: Date) -> Bool {
        guard let raw = rawRemaining(at: now) else { return false }
        return raw < 0
    }

    private func rawRemaining(at now: Date) -> TimeInterval? {
        guard let remainingAtSend = anchor.remainingAtSend else { return nil }
        return anchor.isPaused ? remainingAtSend : remainingAtSend - sinceSent(now)
    }

    /// Time since the phone sent the anchor: the estimated transit plus time since arrival.
    private func sinceSent(_ now: Date) -> TimeInterval {
        anchor.oneWayLatency + now.timeIntervalSince(receivedAt)
    }
}
