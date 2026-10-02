import Foundation

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
        // Once the sheet is answered, HealthKit never shows it again for these types: a type left
        // off can only be turned on in Settings. So the fix is named, not asked for.
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
