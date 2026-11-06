import Foundation
import HealthKit

/// The Health types the Watch app asks for. One list, used both when asking up front and when
/// checking at launch, so the two cannot drift apart: the first link test stalled when the link
/// asked for a type the probe never had. `workoutRoute` is shared so the GPS route can be saved
/// with the workout.
///
/// The phone asks for `share` too, and both apps read `workoutRoute`. While the phone only read
/// routes and the Watch only wrote them, answering either device's Health sheet re-opened the
/// other's (LEARNINGS.md, "Answering one device's Health sheet re-opens the other's");
/// `PairedHealthRequestTests` holds every type both apps ask about to the same access.
///
/// In `Shared/` so the phone's tests can check the probe against exactly what the Watch asks for.
enum WatchHealthTypes {
    static let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    static let read: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKSeriesType.workoutRoute(),
        HKQuantityType(.heartRate),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
    ]
}

/// What HealthKit says about **each** requested type, one line, for both apps' diagnostic logs.
///
/// Built 2026-10-23 to measure the repeated Health sheets: answering the phone's sheet was followed
/// within seconds by the Watch's Workout Routes reading denied (LEARNINGS.md, "Answering one
/// device's Health sheet re-opens the other's"). The whole-request check says only that *some*
/// type would prompt; this names which.
///
/// Per type it reports `asks` (asking for this type alone would show a sheet), `answered` or
/// `unknown`, from `statusForAuthorizationRequest` — the one per-type answer HealthKit gives for
/// read access, which it otherwise hides. For a type the app writes it adds `write=` with
/// `authorizationStatus(for:)`. A check that throws is reported in its place, never dropped.
///
/// In `Shared/`, compiled into both apps, so the two logs spell every answer the same way.
@MainActor
enum HealthAccessProbe {
    static func describe(store: HKHealthStore,
                         share: Set<HKSampleType>,
                         read: Set<HKObjectType>) async -> String {
        let types = Set(share.map { $0 as HKObjectType }).union(read)
            .sorted { $0.identifier < $1.identifier }
        var parts: [String] = []
        for type in types {
            let sample = type as? HKSampleType
            var shareOne: Set<HKSampleType> = sample.map { share.contains($0) ? [$0] : [] } ?? []
            var readOne: Set<HKObjectType> = read.contains(type) ? [type] : []
            var fields = [shareOne.isEmpty ? "r" : (readOne.isEmpty ? "w" : "w+r")]
            // A route may not be asked about without its workout. HealthKit does not return an error
            // for that: it throws an Objective-C exception (`_throwIfParentTypeNotRequestedForSharing`),
            // which Swift cannot catch, and both apps aborted at launch on 2026-10-23. So a route is
            // checked together with Workouts, and its answer reads "with Workout": if Workout alone
            // says `answered` and this says `asks`, the route is what is unanswered.
            if type == HKSeriesType.workoutRoute() {
                if !shareOne.isEmpty { shareOne.insert(HKObjectType.workoutType()) }
                if !readOne.isEmpty { readOne.insert(HKObjectType.workoutType()) }
                fields.append("with Workout")
            }
            do {
                switch try await store.statusForAuthorizationRequest(toShare: shareOne, read: readOne) {
                case .shouldRequest: fields.append("asks")
                case .unnecessary: fields.append("answered")
                case .unknown: fields.append("unknown")
                @unknown default: fields.append("unrecognized request status")
                }
            } catch {
                fields.append("check failed: \(error.localizedDescription)")
            }
            if let sample, share.contains(sample) {
                switch store.authorizationStatus(for: sample) {
                case .sharingAuthorized: fields.append("write=authorized")
                case .sharingDenied: fields.append("write=denied")
                case .notDetermined: fields.append("write=notDetermined")
                @unknown default: fields.append("write=unrecognized")
                }
            }
            parts.append("\(shortName(type)) \(fields.joined(separator: " "))")
        }
        return parts.joined(separator: "; ")
    }

    /// `HKQuantityTypeIdentifierHeartRate` → `HeartRate`, `HKWorkoutRouteTypeIdentifier` →
    /// `WorkoutRoute`. Unknown shapes pass through whole rather than being guessed at.
    static func shortName(_ type: HKObjectType) -> String {
        let id = type.identifier
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier"] where id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        if id.hasPrefix("HK"), id.hasSuffix("TypeIdentifier") {
            return String(id.dropFirst(2).dropLast("TypeIdentifier".count))
        }
        return id
    }
}

/// The Watch's Health access, as the two separate questions HealthKit answers.
///
/// `request` is `statusForAuthorizationRequest`: **will a sheet appear if we ask?** Its
/// `unnecessary` means the sheet has been answered — not that every toggle on it was turned on.
/// The sharing fields are `authorizationStatus(for:)`: **may this app write this type?** The launch
/// check used to read only the first and log it as "granted". On the first run after a Watch
/// reinstall it said granted, and HealthKit then refused every GPS batch for the whole run.
///
/// Read access is not here because HealthKit never reveals it: an app cannot learn whether it may
/// read heart rate, only whether it may write. That is a privacy rule, not an omission.
///
/// In `Shared/` so the phone's test target can reach it; only the watch calls it.
struct WatchHealthAccess: Equatable {
    enum Request: Equatable { case unanswered, answered, unknown }
    enum Sharing: Equatable { case notDetermined, denied, authorized }

    var request: Request
    /// `HKObjectType.workoutType()`. Without it nothing the run records can be saved.
    var workouts: Sharing
    /// `HKSeriesType.workoutRoute()`. Without it the run records everything but its GPS route.
    var routes: Sharing

    enum LaunchDecision: Equatable {
        /// Show the Health sheet, then decide again — with `canShowSheet: false`, so a dismissed
        /// sheet stops the launch instead of asking in a loop.
        case ask
        case start
        /// Record the workout without a route builder, saying why before the run.
        case startWithoutRoute(reason: String)
        case stop(String)
    }

    /// A sheet can only appear while the app is on screen, so every time it comes on screen with
    /// the request unanswered is a chance to ask — not just the first time the process starts.
    var shouldAskOnScreen: Bool { request == .unanswered }

    /// What a launch from the phone should do.
    ///
    /// - Parameter canShowSheet: the Watch app is on screen. A phone launch can arrive with the
    ///   screen off, where a sheet has nowhere to appear.
    func launchDecision(canShowSheet: Bool) -> LaunchDecision {
        switch request {
        case .unknown:
            return .stop("HealthKit could not say whether access has been granted.")
        case .unanswered:
            if canShowSheet { return .ask }
            return .stop("Health access not granted yet. Open RunExporterWatch, allow Health access, "
                         + "then start again from the phone.")
        case .answered:
            break
        }
        // Once the sheet is answered, HealthKit does not show it again for these types until
        // something resets the answer — measured: an install did, and the sheet came back offering
        // routes again. Until then a type left off can only be turned on in Settings, so the fix
        // is named, not asked for.
        guard workouts == .authorized else {
            return .stop("RunExporterWatch may not save workouts. Turn on Workouts in the Watch's "
                         + "Settings → Health → Apps → RunExporterWatch, then start again from the phone.")
        }
        guard routes == .authorized else {
            return .startWithoutRoute(reason: "Workout Routes is off for RunExporterWatch. Turn it on in "
                                      + "the Watch's Settings → Health → Apps → RunExporterWatch.")
        }
        return .start
    }

    /// One line for the event log, with every answer — not one status presented as all of them.
    var logLine: String {
        "Health access: sheet \(request), workouts \(workouts), routes \(routes)"
    }
}

/// What happened to a run's GPS route, counted as it is recorded.
///
/// Every failed batch used to log its own line: one a second, 95% of everything the Watch logged
/// on the run that found it. The first refusal says what went wrong; the rest are a count, given at
/// the save.
struct RouteTally: Equatable {
    private(set) var pointsInserted = 0
    private(set) var refusedBatches = 0
    private(set) var firstRefusal: String?

    enum Result: Equatable {
        /// Every batch HealthKit was given, it stored.
        case complete
        /// Some points stored, some batches refused: a route with holes in it.
        case incomplete
        /// Nothing stored — refused, no GPS fix, or no route builder. Still saved, without a route.
        case none
    }

    mutating func recordInserted(_ count: Int) { pointsInserted += count }

    /// Counts a refused batch. Returns the message only the first time, for the log.
    mutating func recordRefusal(_ message: String) -> String? {
        refusedBatches += 1
        guard firstRefusal == nil else { return nil }
        firstRefusal = message
        return message
    }

    var result: Result {
        if pointsInserted == 0 { return .none }
        return refusedBatches > 0 ? .incomplete : .complete
    }
}
