import Foundation

/// The one-way phone→watch message delay, from measured ping round trips.
///
/// Uses the **smallest** round trip, as NTP does: channel warm-up and scheduling only ever add delay,
/// so the fastest sample is the closest to the link's real latency. The median was used until
/// 2026-09-29, when the only sample was a connect-time ping of 1.71 s (0.13 s once warm) and the
/// watch subtracted 0.86 s it should not have. Tested in `LatencyEstimateTests`.
enum LatencyEstimate {
    /// Half the smallest non-negative round trip; 0 when there is none, which errs by the true delay
    /// (about 0.07 s) rather than by a guess. A negative round trip is impossible on one clock and is
    /// ignored rather than read as a faster link.
    static func oneWay(fromRoundTrips roundTrips: [TimeInterval]) -> TimeInterval {
        guard let fastest = roundTrips.filter({ $0 >= 0 }).min() else { return 0 }
        return fastest / 2
    }
}
