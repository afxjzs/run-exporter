import Foundation

/// Everything the iPhone app and the watch app say to each other, carried over the mirrored
/// workout session's data channel (`HKWorkoutSession.sendToRemoteWorkoutSession`).
///
/// Compiled into **both** apps from `Shared/`, so the two ends cannot disagree about the format —
/// only about the version, which is what `WatchLinkCodec.protocolVersion` is for. The watch copy of
/// the app installs minutes after the phone's, so a new phone talking to an old watch is an
/// ordinary state after every install, not an edge case.
///
/// **Division of labour** (docs/WATCHOS_RECORDER_PLAN.md, "Plan of record"): the phone decides,
/// the watch records. Nothing here asks the watch to make a decision.
enum WatchLinkMessage: Equatable, Sendable {
    /// Phone → watch. Answered by `.pong` with the same id; the round trip is the link's latency.
    case ping(id: UUID, sentAt: Date)
    /// Watch → phone. `watchReceivedAt` is the watch's clock, so it is shown but never subtracted
    /// from a phone timestamp — the two clocks are not the same clock.
    case pong(id: UUID, watchReceivedAt: Date)
    /// Watch → phone, periodically, while the watch's session runs.
    case status(WatchStatus)
    /// Phone → watch: end the session.
    case endWorkout
}

/// Who started the watch's workout session. Recorded because the two paths behave differently and
/// a result from one says nothing about the other.
enum WatchWorkoutOrigin: String, Codable, Sendable {
    /// `HKHealthStore.startWatchApp(toHandle:)` on the phone launched the watch app.
    case phone
    /// Started from the watch's own screen.
    case watch
}

struct WatchStatus: Codable, Equatable, Sendable {
    /// Watch clock.
    var sentAt: Date
    /// Watch clock.
    var sessionStartedAt: Date
    /// Most recent heart rate, beats per minute. Nil until the watch has taken a reading, which
    /// is normal for the first several seconds of a session and is shown as such, not as zero.
    var heartRate: Double?
    var origin: WatchWorkoutOrigin
}

enum WatchLinkError: Error, Equatable, LocalizedError {
    case unsupportedVersion(received: Int, supported: Int)
    case unknownKind(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(received, supported):
            return "The other device sent watch-link version \(received); this app understands up to \(supported). "
                + "Update both apps from the same build."
        case let .unknownKind(kind):
            return "The other device sent a \"\(kind)\" message, which this app does not know. "
                + "The phone and watch apps are probably from different builds."
        }
    }
}

/// The watch's event log travelling to the phone. Separate from `WatchLinkMessage` because it rides
/// a different channel: `WCSession.transferUserInfo`, which the system queues and delivers even with
/// no workout session running — the mirrored session's channel only exists while one is.
enum WatchLogTransfer {
    /// `userInfo` key; the value is `[String]`, oldest first, each line already timestamped on the
    /// watch's clock.
    static let key = "watchEventLog"
}

/// Wire format: `{"version": 1, "kind": "ping", "body": {…}}`.
enum WatchLinkCodec {
    /// Bump when a message changes meaning or a new kind is added.
    static let protocolVersion = 1

    static func encode(_ message: WatchLinkMessage) throws -> Data {
        switch message {
        case let .ping(id, sentAt):
            return try envelope("ping", PingBody(id: id, sentAt: sentAt))
        case let .pong(id, watchReceivedAt):
            return try envelope("pong", PongBody(id: id, watchReceivedAt: watchReceivedAt))
        case let .status(status):
            return try envelope("status", status)
        case .endWorkout:
            return try envelope("endWorkout", EmptyBody())
        }
    }

    static func decode(_ data: Data) throws -> WatchLinkMessage {
        // The header is read first, from the same bytes — JSON decoding ignores the body key it
        // does not declare — so the body's type can be chosen from the kind.
        let header = try decoder.decode(Header.self, from: data)
        // Checked before the kind: a newer sender may use a kind this build has never heard of,
        // and "update the apps" is the more useful of the two errors.
        guard header.version <= protocolVersion else {
            throw WatchLinkError.unsupportedVersion(received: header.version, supported: protocolVersion)
        }
        switch header.kind {
        case "ping":
            let ping = try body(PingBody.self, from: data)
            return .ping(id: ping.id, sentAt: ping.sentAt)
        case "pong":
            let pong = try body(PongBody.self, from: data)
            return .pong(id: pong.id, watchReceivedAt: pong.watchReceivedAt)
        case "status":
            return .status(try body(WatchStatus.self, from: data))
        case "endWorkout":
            return .endWorkout
        default:
            throw WatchLinkError.unknownKind(header.kind)
        }
    }

    // MARK: - Wire types

    private struct Header: Decodable {
        var version: Int
        var kind: String
    }

    private struct Envelope<Body: Codable>: Codable {
        var version: Int
        var kind: String
        var body: Body
    }

    private struct PingBody: Codable { var id: UUID; var sentAt: Date }
    private struct PongBody: Codable { var id: UUID; var watchReceivedAt: Date }
    private struct EmptyBody: Codable {}

    private static func envelope<Body: Codable>(_ kind: String, _ body: Body) throws -> Data {
        try encoder.encode(Envelope(version: protocolVersion, kind: kind, body: body))
    }

    private static func body<Body: Codable>(_ type: Body.Type, from data: Data) throws -> Body {
        try decoder.decode(Envelope<Body>.self, from: data).body
    }

    // `.deferredToDate` writes Date's own stored value — seconds since 2001 as a Double — so a date
    // comes back bit-for-bit. `.secondsSince1970` does not: it adds and removes 978,307,200 s, which
    // costs the low bits, and a test caught a pong that no longer equalled itself. `.iso8601` would
    // drop sub-second precision outright, and the ping round trip is measured in fractions of one.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
