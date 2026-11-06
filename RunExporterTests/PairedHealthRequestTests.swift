import HealthKit
import XCTest
@testable import RunExporter

/// Answering one device's Health sheet re-opened the other's, on every open, for weeks
/// (LEARNINGS.md, "Answering one device's Health sheet re-opens the other's"). The type that
/// flipped was Workout Routes, which the phone asked only to read and the Watch only to write;
/// Workouts, asked for the same way by both, never flipped. So every type both apps ask about must
/// be asked for with the same access in every request that names it.
@MainActor
final class PairedHealthRequestTests: XCTestCase {

    private struct Request {
        let name: String
        let share: Set<HKSampleType>
        let read: Set<HKObjectType>

        func access(to type: HKObjectType) -> String? {
            let writes = (type as? HKSampleType).map(share.contains) ?? false
            let reads = read.contains(type)
            switch (writes, reads) {
            case (true, true): return "read and write"
            case (true, false): return "write only"
            case (false, true): return "read only"
            case (false, false): return nil
            }
        }

        var types: Set<HKObjectType> { Set(share.map { $0 as HKObjectType }).union(read) }
    }

    func testEveryTypeBothAppsAskForIsAskedForTheSameWay() {
        let health = HealthKitManager()
        let phone = [
            Request(name: "phone Today/Export", share: health.shareTypes(), read: health.readTypes()),
            Request(name: "phone run start", share: WatchLink.runStartShareTypes,
                    read: WatchLink.runStartReadTypes),
        ]
        let watch = Request(name: "Watch", share: WatchHealthTypes.share, read: WatchHealthTypes.read)

        for request in phone {
            for type in request.types.intersection(watch.types) {
                XCTAssertEqual(request.access(to: type), watch.access(to: type),
                               "\(HealthAccessProbe.shortName(type)): \(request.name) asks "
                               + "\(request.access(to: type) ?? "nothing"), the Watch asks "
                               + "\(watch.access(to: type) ?? "nothing")")
            }
        }
    }
}
