import XCTest
@testable import RunExporter

/// The stop the phone owes the Watch when a run ends (`WatchStop`).
///
/// The bug this exists for (2026-11-25, a real run): at Finish the phone's "save the workout"
/// message failed with "Remote device is unreachable". The run screen still said the Watch "was
/// asked to save", nothing sent the message again, and the Watch kept recording for hours —
/// although it reconnected within a minute.
///
/// Ways it can fail, each a test below:
/// 1. A failed send is reported as delivered.
/// 2. A failed stop is never sent again when the Watch reconnects.
/// 3. The resend is a different message: a save resent as a discard, or without its execution id.
/// 4. A delivered stop is sent again at a later reconnect.
/// 5. A resend that fails too is forgotten.
/// 6. A run that lost the Watch mid-run is treated as having no Watch workout, though the Watch is
///    still recording it.
/// 7. A run that never reached the Watch is told to end a Watch workout that does not exist.
/// 8. A new run starts with the last run's stop still owed, and nothing says so.
/// 9. A send's result arriving for an older message decides a newer one.
final class WatchStopTests: XCTestCase {

    private let id = UUID()

    // 1
    func testAFailedSendIsOwedNotDelivered() {
        var stop = WatchStop()
        XCTAssertEqual(stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true),
                       .save(executionID: id))
        stop.sendFinished(.save(executionID: id), error: "Remote device is unreachable")
        XCTAssertEqual(stop.state, .owed(.save(executionID: id), reason: "Remote device is unreachable"))
    }

    func testASuccessfulSendIsDelivered() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: nil)
        XCTAssertEqual(stop.state, .delivered(.save(executionID: id)))
    }

    // 2, 3
    func testAnOwedStopIsSentAgainOnReconnect() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: "Remote device is unreachable")
        XCTAssertEqual(stop.reconnected(), .save(executionID: id))
        XCTAssertEqual(stop.state, .sending(.save(executionID: id)))
    }

    func testAnOwedDiscardIsResentAsADiscard() {
        var stop = WatchStop()
        _ = stop.runEnded(.discard, connected: true, runReachedWatch: true)
        stop.sendFinished(.discard, error: "Remote device is unreachable")
        XCTAssertEqual(stop.reconnected(), .discard)
    }

    // 4
    func testADeliveredStopIsNotSentAgain() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: nil)
        XCTAssertNil(stop.reconnected())
    }

    func testAStopInFlightIsNotSentTwice() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        XCTAssertNil(stop.reconnected())
    }

    // 5
    func testAFailedResendStaysOwed() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: "Remote device is unreachable")
        _ = stop.reconnected()
        stop.sendFinished(.save(executionID: id), error: "Failed to send data to remote session.")
        XCTAssertEqual(stop.state, .owed(.save(executionID: id), reason: "Failed to send data to remote session."))
        XCTAssertEqual(stop.reconnected(), .save(executionID: id))
    }

    // 6
    func testARunThatLostTheWatchOwesItsStop() {
        var stop = WatchStop()
        XCTAssertNil(stop.runEnded(.save(executionID: id), connected: false, runReachedWatch: true))
        guard case .owed(.save(executionID: id), _) = stop.state else {
            return XCTFail("Expected the save to be owed, got \(stop.state)")
        }
        XCTAssertEqual(stop.reconnected(), .save(executionID: id))
    }

    // 7
    func testARunThatNeverReachedTheWatchOwesNothing() {
        var stop = WatchStop()
        XCTAssertNil(stop.runEnded(.save(executionID: id), connected: false, runReachedWatch: false))
        XCTAssertEqual(stop.state, .none)
        XCTAssertNil(stop.reconnected())
    }

    // 8
    func testANewRunReportsAStopStillOwed() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: "Remote device is unreachable")
        XCTAssertEqual(stop.runStarted(), .save(executionID: id))
        XCTAssertEqual(stop.state, .none)
    }

    func testANewRunAfterADeliveredStopReportsNothing() {
        var stop = WatchStop()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: nil)
        XCTAssertNil(stop.runStarted())
    }

    // 9
    func testAnOlderRunsResultDoesNotDecideANewerStop() {
        var stop = WatchStop()
        let newer = UUID()
        _ = stop.runEnded(.save(executionID: id), connected: true, runReachedWatch: true)
        _ = stop.runStarted()
        _ = stop.runEnded(.save(executionID: newer), connected: true, runReachedWatch: true)
        stop.sendFinished(.save(executionID: id), error: nil)
        XCTAssertEqual(stop.state, .sending(.save(executionID: newer)))
    }
}
