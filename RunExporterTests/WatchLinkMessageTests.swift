import XCTest
@testable import RunExporter

/// The wire format between the iPhone app and the watch app.
///
/// The two apps are installed separately — the watch copy arrives minutes after the phone's, over a
/// link that has already failed silently in this project — so for a while after every install a new
/// phone can be talking to an old watch. Anything one side does not understand must fail loudly on
/// that side, never decode as something plausible.
final class WatchLinkMessageTests: XCTestCase {

    private let sentAt = Date(timeIntervalSince1970: 1_790_000_000.25)

    // MARK: - Round trips

    func testEveryMessageSurvivesARoundTrip() throws {
        let id = UUID()
        let messages: [WatchLinkMessage] = [
            .ping(id: id, sentAt: sentAt),
            .pong(id: id, watchReceivedAt: sentAt.addingTimeInterval(0.4)),
            .status(WatchStatus(sentAt: sentAt,
                                sessionStartedAt: sentAt.addingTimeInterval(-90),
                                heartRate: 142.5,
                                origin: .phone)),
            .status(WatchStatus(sentAt: sentAt,
                                sessionStartedAt: sentAt,
                                heartRate: nil,       // no reading yet
                                origin: .phone)),
            .endWorkout,
        ]
        for message in messages {
            let decoded = try WatchLinkCodec.decode(WatchLinkCodec.encode(message))
            XCTAssertEqual(decoded, message)
        }
    }

    /// Sub-second precision matters: the ping round trip is the latency measurement, and a codec
    /// that rounded dates to whole seconds would report every link as instant or a second slow.
    func testDatesKeepSubSecondPrecision() throws {
        let original = WatchLinkMessage.ping(id: UUID(), sentAt: sentAt)
        guard case let .ping(_, decodedDate) = try WatchLinkCodec.decode(WatchLinkCodec.encode(original)) else {
            return XCTFail("Decoded a different kind of message")
        }
        XCTAssertEqual(decodedDate.timeIntervalSince1970, sentAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - What must fail

    func testAnUnknownKindThrowsAndNamesIt() {
        let data = envelope(kind: "startIntervals", body: "{}")
        XCTAssertThrowsError(try WatchLinkCodec.decode(data)) { error in
            XCTAssertEqual(error as? WatchLinkError, .unknownKind("startIntervals"))
        }
    }

    func testANewerProtocolVersionThrowsAndNamesBothVersions() {
        let newer = WatchLinkCodec.protocolVersion + 1
        let data = envelope(version: newer, kind: "endWorkout", body: "{}")
        XCTAssertThrowsError(try WatchLinkCodec.decode(data)) { error in
            XCTAssertEqual(error as? WatchLinkError,
                           .unsupportedVersion(received: newer, supported: WatchLinkCodec.protocolVersion))
        }
    }

    func testAnUnknownOriginThrowsRatherThanDefaulting() {
        let body = #"{"sentAt":0,"sessionStartedAt":0,"origin":"ipad"}"#
        XCTAssertThrowsError(try WatchLinkCodec.decode(envelope(kind: "status", body: body)))
    }

    func testAMissingRequiredFieldThrows() {
        // A ping without its id cannot be matched to its pong, so it must not decode.
        XCTAssertThrowsError(try WatchLinkCodec.decode(envelope(kind: "ping", body: #"{"sentAt":0}"#)))
    }

    func testDataThatIsNotAMessageThrows() {
        XCTAssertThrowsError(try WatchLinkCodec.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try WatchLinkCodec.decode(Data()))
    }

    // MARK: - Helpers

    /// Builds a raw envelope by hand, so these tests pin the wire format rather than trusting the
    /// encoder under test to produce it.
    private func envelope(version: Int = WatchLinkCodec.protocolVersion, kind: String, body: String) -> Data {
        Data(#"{"version":\#(version),"kind":"\#(kind)","body":\#(body)}"#.utf8)
    }
}
