import HealthKit
import XCTest
@testable import RunExporter

/// The workout the phone asks the Watch to record must be the plan's activity.
///
/// Found by the 2026-09-29 sweep: `WatchLink.launchWatchWorkout` always built an outdoor **running**
/// configuration, so a Walking plan's Start saved an Outdoor Run to Health, and nothing on either
/// screen said so. A walk recorded as a run is a silent deviation — the data is wrong in Health and
/// in every export, and the owner would believe it was a walk.
final class WatchLaunchConfigurationTests: XCTestCase {

    func testARunningPlanRecordsAnOutdoorRun() {
        let configuration = WatchLink.workoutConfiguration(for: .running)
        XCTAssertEqual(configuration.activityType, .running)
        XCTAssertEqual(configuration.locationType, .outdoor)
    }

    func testAWalkingPlanRecordsAnOutdoorWalk() {
        let configuration = WatchLink.workoutConfiguration(for: .walking)
        XCTAssertEqual(configuration.activityType, .walking,
                       "A Walking plan must not be saved to Health as a run")
        XCTAssertEqual(configuration.locationType, .outdoor)
    }

    /// Every plan activity maps to a distinct HealthKit activity, so a new case cannot silently
    /// fall through to running.
    func testEveryPlanActivityMapsToItsOwnWorkoutType() {
        let types = PlannedActivityType.allCases.map { WatchLink.workoutConfiguration(for: $0).activityType }
        XCTAssertEqual(Set(types.map(\.rawValue)).count, PlannedActivityType.allCases.count)
    }
}
