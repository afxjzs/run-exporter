import XCTest
@testable import RunExporter

/// Whether the live heart rate on the run screens may be shown as current (aerobic spec §6).
///
/// The bug this exists for: the watch kept its last reading with no time on it and resent it every
/// five seconds, so a sensor that stopped reporting left both screens showing an old number as if
/// it were live.
final class LiveHeartRateTests: XCTestCase {

    /// The watch's clock, deliberately hours away from the phone's: the two are never one clock.
    private let watchSentAt = Date(timeIntervalSince1970: 1_790_000_000)
    private let phoneReceivedAt = Date(timeIntervalSince1970: 1_790_009_999)

    private func status(heartRate: Double?, sampledSecondsBeforeSend: TimeInterval?) -> WatchStatus {
        WatchStatus(sentAt: watchSentAt,
                    sessionStartedAt: watchSentAt.addingTimeInterval(-600),
                    heartRate: heartRate,
                    heartRateSampledAt: sampledSecondsBeforeSend.map { watchSentAt.addingTimeInterval(-$0) },
                    origin: .phone)
    }

    func testARecentReadingIsCurrent() {
        let reading = LiveHeartRate.onPhone(status(heartRate: 138, sampledSecondsBeforeSend: 4),
                                            receivedAt: phoneReceivedAt,
                                            now: phoneReceivedAt.addingTimeInterval(3))
        XCTAssertEqual(reading, .current(bpm: 138))
    }

    /// The real failure: the link is fine and statuses keep arriving, but the reading inside them
    /// stopped changing a while ago.
    func testAnOldReadingInAFreshStatusIsStale() {
        let reading = LiveHeartRate.onPhone(status(heartRate: 138, sampledSecondsBeforeSend: 40),
                                            receivedAt: phoneReceivedAt,
                                            now: phoneReceivedAt)
        XCTAssertEqual(reading, .stale(ageSeconds: 40))
    }

    /// The link went quiet: the last status was fine when it arrived, and nothing has come since.
    func testAReadingAgesWhileNoStatusArrives() {
        let reading = LiveHeartRate.onPhone(status(heartRate: 138, sampledSecondsBeforeSend: 2),
                                            receivedAt: phoneReceivedAt,
                                            now: phoneReceivedAt.addingTimeInterval(30))
        XCTAssertEqual(reading, .stale(ageSeconds: 32))
    }

    func testNoReadingYetIsNotStaleWhileStatusesArrive() {
        let reading = LiveHeartRate.onPhone(status(heartRate: nil, sampledSecondsBeforeSend: nil),
                                            receivedAt: phoneReceivedAt,
                                            now: phoneReceivedAt.addingTimeInterval(2))
        XCTAssertEqual(reading, .noReading)
    }

    func testNoStatusAtAllIsNoReading() {
        XCTAssertEqual(LiveHeartRate.onPhone(nil, receivedAt: nil, now: phoneReceivedAt), .noReading)
    }

    /// A watch app from before readings carried their time: the number cannot be judged, so it is
    /// not shown as current.
    func testAReadingWithNoTimeHasUnknownAge() {
        let reading = LiveHeartRate.onPhone(status(heartRate: 138, sampledSecondsBeforeSend: nil),
                                            receivedAt: phoneReceivedAt,
                                            now: phoneReceivedAt)
        XCTAssertEqual(reading, .ageUnknown)
    }

    func testTheWatchJudgesItsOwnReadingOnItsOwnClock() {
        XCTAssertEqual(LiveHeartRate.onWatch(bpm: 140, sampledAt: watchSentAt,
                                             now: watchSentAt.addingTimeInterval(5)),
                       .current(bpm: 140))
        XCTAssertEqual(LiveHeartRate.onWatch(bpm: 140, sampledAt: watchSentAt,
                                             now: watchSentAt.addingTimeInterval(25)),
                       .stale(ageSeconds: 25))
    }

    /// The phone and watch are installed separately, so a status from a watch app that predates the
    /// reading's time must still decode.
    func testAStatusWithoutTheReadingTimeStillDecodes() throws {
        let body = #"{"sentAt":0,"sessionStartedAt":0,"heartRate":131,"origin":"phone"}"#
        let envelope = #"{"version":\#(WatchLinkCodec.protocolVersion),"kind":"status","body":\#(body)}"#
        guard case let .status(decoded) = try WatchLinkCodec.decode(Data(envelope.utf8)) else {
            return XCTFail("Decoded a different kind of message")
        }
        XCTAssertEqual(decoded.heartRate, 131)
        XCTAssertNil(decoded.heartRateSampledAt)
    }
}
