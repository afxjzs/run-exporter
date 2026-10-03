import XCTest
@testable import RunExporter

/// What the Watch does about its Health access at launch, and how it reports the route at save.
///
/// From the first run on the build that hid shoes. Any install, phone or Watch, resets the Watch's
/// Health access, and the launch stopped until the app was opened by hand. Then the run lost its whole GPS route: HealthKit refused every batch
/// with "Not authorized", the log took one line per refusal, and the Watch drew a clean save
/// reading "no GPS points were collected". The launch check had read `statusForAuthorizationRequest`
/// — whether a sheet would appear — and logged it as "granted". Whether this app may write routes
/// is a different question, answered per type.
final class WatchHealthAccessTests: XCTestCase {

    private func access(_ request: WatchHealthAccess.Request,
                        workouts: WatchHealthAccess.Sharing = .authorized,
                        routes: WatchHealthAccess.Sharing = .authorized) -> WatchHealthAccess {
        WatchHealthAccess(request: request, workouts: workouts, routes: routes)
    }

    // MARK: - Asking

    /// The sheet can only appear while the app is on screen, so every time it comes on screen with
    /// a question unanswered is a chance to ask. It used to ask once per process.
    func testAnUnansweredRequestIsAskedWheneverTheAppIsOnScreen() {
        XCTAssertTrue(access(.unanswered).shouldAskOnScreen)
        XCTAssertFalse(access(.answered).shouldAskOnScreen,
                       "an answered request shows no sheet; asking again only adds log noise")
    }

    /// That launch stopped at "would prompt" and waited for the owner to open the app by hand. With the screen on, the sheet can appear right there.
    func testALaunchWithTheScreenOnAsksInsteadOfStopping() {
        XCTAssertEqual(access(.unanswered).launchDecision(canShowSheet: true), .ask)
    }

    /// With the screen off there is nowhere for a sheet to appear. This is also the decision after
    /// one ask was dismissed, which is what keeps the launch from asking in a loop.
    func testALaunchThatCannotShowTheSheetStops() {
        guard case .stop = access(.unanswered).launchDecision(canShowSheet: false) else {
            return XCTFail("expected .stop")
        }
    }

    func testAStatusHealthKitCannotDetermineStops() {
        guard case .stop = access(.unknown).launchDecision(canShowSheet: true) else {
            return XCTFail("expected .stop: asking cannot fix an error")
        }
    }

    // MARK: - What the answers allow

    /// Without workout sharing nothing can be saved, so a run would record into nothing and fail
    /// at the save, after the run. Better to stop at the start, where the fix can still be made.
    func testRefusedWorkoutSharingStopsTheLaunch() {
        for workouts in [WatchHealthAccess.Sharing.denied, .notDetermined] {
            guard case .stop = access(.answered, workouts: workouts).launchDecision(canShowSheet: true) else {
                return XCTFail("expected .stop for workout sharing \(workouts)")
            }
        }
    }

    /// That run's case. The workout and heart rate can still be recorded, so the run starts —
    /// but without a route builder HealthKit would refuse, and saying so before the run.
    func testRefusedRouteSharingStartsWithoutARoute() {
        for routes in [WatchHealthAccess.Sharing.denied, .notDetermined] {
            guard case .startWithoutRoute = access(.answered, routes: routes).launchDecision(canShowSheet: true) else {
                return XCTFail("expected .startWithoutRoute for route sharing \(routes)")
            }
        }
    }

    func testFullAccessStarts() {
        XCTAssertEqual(access(.answered).launchDecision(canShowSheet: true), .start)
    }

    // MARK: - The route at save

    func testARouteWithEveryBatchStoredIsComplete() {
        var tally = RouteTally()
        tally.recordInserted(40)
        XCTAssertEqual(tally.result, .complete)
    }

    /// No points stored is no route, whatever the reason — refused, no GPS fix, no builder. Every
    /// one of these drew a clean save until now.
    func testNoStoredPointsIsNoRoute() {
        XCTAssertEqual(RouteTally().result, .none)

        var refused = RouteTally()
        _ = refused.recordRefusal("Not authorized")
        XCTAssertEqual(refused.result, .none)
    }

    func testARouteWithSomeBatchesRefusedIsIncomplete() {
        var tally = RouteTally()
        tally.recordInserted(40)
        _ = tally.recordRefusal("Not authorized")
        XCTAssertEqual(tally.result, .incomplete)
    }

    /// One line per refused batch was 95% of everything the Watch logged on that run. The first
    /// refusal is worth a line; the rest are a count.
    func testOnlyTheFirstRefusalIsReturnedForTheLog() {
        var tally = RouteTally()
        XCTAssertEqual(tally.recordRefusal("Not authorized"), "Not authorized")
        XCTAssertNil(tally.recordRefusal("Not authorized"))
        XCTAssertNil(tally.recordRefusal("Something else"))
        XCTAssertEqual(tally.refusedBatches, 3)
        XCTAssertEqual(tally.firstRefusal, "Not authorized")
    }
}
