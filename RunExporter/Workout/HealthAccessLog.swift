import Foundation
import HealthKit

/// Every Health permission request the phone makes, recorded with what each requested type said
/// **before** the request and **after** it, in `Documents/health-access-phone.log`.
///
/// Until 2026-10-23 the phone logged none of its requests, so "it asks me every time I open it"
/// could be measured only on the Watch. Pull the file like the watch link's logs:
///
///     xcrun devicectl device copy from --device <PHONE_COREDEVICE_ID> --domain-type appDataContainer \
///       --domain-identifier is.doug.runexporter --source Documents/health-access-phone.log --destination <local>
///
/// Every phone request goes through `request`, so no path asks without leaving a line. A request
/// that throws is logged, then rethrown to its caller unchanged.
@MainActor
enum HealthAccessLog {
    private static let file = DiagnosticLogFile.inDocuments(named: "health-access-phone.log")

    /// Asks HealthKit for `share` and `read`, recording the per-type answers around it.
    ///
    /// - Parameter context: who is asking, e.g. "Today refresh", so the log says which screen
    ///   showed a sheet.
    /// - Returns: why the log could not be written, or nil. The request itself has still been
    ///   made: a broken diagnostic file must not stop the app reading Health, but the caller must
    ///   show the problem rather than drop it.
    static func request(_ context: String,
                        store: HKHealthStore,
                        share: Set<HKSampleType>,
                        read: Set<HKObjectType>) async throws -> String? {
        var problems: [String] = []
        let started = Date()
        let before = await HealthAccessProbe.describe(store: store, share: share, read: read)
        write("\(context): before request: \(before)", into: &problems)
        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            write("\(context): request FAILED: \(error.localizedDescription)", into: &problems)
            throw error
        }
        // A request that shows no sheet returns in milliseconds; one that shows a sheet waits for
        // the user. The duration is how this log tells them apart.
        let seconds = String(format: "%.2f s", Date().timeIntervalSince(started))
        let after = await HealthAccessProbe.describe(store: store, share: share, read: read)
        write("\(context): request returned after \(seconds); after: \(after)", into: &problems)
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    private static func write(_ text: String, into problems: inout [String]) {
        guard let file else {
            problems.append("No Documents folder; Health access checks are not being saved.")
            return
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        do {
            try file.append("\(stamp)  \(text)")
        } catch {
            problems.append("Could not save the Health access log: \(error.localizedDescription)")
        }
    }
}
