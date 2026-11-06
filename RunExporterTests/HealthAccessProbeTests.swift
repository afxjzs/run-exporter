import HealthKit
import XCTest
@testable import RunExporter

/// The per-type Health probe crashed both apps at launch on 2026-10-23, build 202610231106.
///
/// It asked HealthKit about each requested type alone, and Workout Routes may not be asked about
/// without its parent type, Workouts. HealthKit throws an Objective-C exception for that
/// (`_throwIfParentTypeNotRequestedForSharing:types:`), which Swift cannot catch, so the app
/// aborted before the phone wrote a single line. These run the probe on exactly what each app
/// requests, against the simulator's real HealthKit: the crash needs no permission sheet.
@MainActor
final class HealthAccessProbeTests: XCTestCase {

    func testThePhonesRequestIsDescribedTypeByType() async {
        let health = HealthKitManager()
        let read = health.readTypes()
        let line = await HealthAccessProbe.describe(store: health.store, share: [], read: read)
        assertNamesEvery(read, in: line)
    }

    func testTheWatchsRequestIsDescribedTypeByType() async {
        let line = await HealthAccessProbe.describe(store: HKHealthStore(),
                                                    share: WatchHealthTypes.share,
                                                    read: WatchHealthTypes.read)
        assertNamesEvery(Set(WatchHealthTypes.share.map { $0 as HKObjectType }).union(WatchHealthTypes.read),
                         in: line)
    }

    /// The probe exists to say which type a sheet is for, so every requested type must be named.
    private func assertNamesEvery(_ types: Set<HKObjectType>, in line: String,
                                  file: StaticString = #filePath, lineNumber: UInt = #line) {
        let entries = line.components(separatedBy: "; ")
        for type in types {
            let name = HealthAccessProbe.shortName(type)
            XCTAssertTrue(entries.contains { $0.hasPrefix("\(name) ") },
                          "\(name) is missing from: \(line)", file: file, line: lineNumber)
        }
    }
}
