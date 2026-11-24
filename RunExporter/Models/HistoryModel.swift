import Foundation
import CoreLocation

/// A run's route as History draws it.
enum RouteLoad {
    case points([CLLocationCoordinate2D])
    /// The run recorded no route — indoors, or GPS was off. Normal, and said plainly.
    case noRoute
    /// A route may exist but could not be read. Shown with its reason, never as "no route".
    case failed(String)
}

/// One run as the History screen shows it.
struct HistoryRun: Identifiable {
    let workout: HealthKitManager.WorkoutSummary
    /// Nil when the run has no kind: recorded before kinds existed, or not started from a plan in
    /// this app. A stored kind this build does not know is `unknownKind`, never silently nil.
    let kind: RunKind?
    let unknownKind: String?
    /// What the run was started as — the plan's name when it began. Nil for a run this app did not
    /// start.
    let planName: String?
    /// A log saved against this workout, or one written during cooldown that is still waiting to
    /// attach to it (see LEARNINGS.md, "Run logging"): either way the run is logged.
    let isLogged: Bool
    /// False when the run has no timer session in this app, so there is nowhere to keep a kind.
    let canChangeKind: Bool

    var id: UUID { workout.uuid }
}

/// What History shows: every run, or one kind.
enum HistoryFilter: Hashable {
    case all
    case kind(RunKind)
}

/// How the runs are grouped when every kind is shown.
enum HistoryGrouping: String, CaseIterable, Identifiable {
    case week, kind
    var id: String { rawValue }
    var displayName: String { self == .week ? "By week" : "By kind" }
}

struct HistoryGroup: Identifiable {
    let id: String
    let title: String
    let detail: String
    let runs: [HistoryRun]
}

/// The week arithmetic History uses. Weeks start on Monday, whatever the phone's region says,
/// because the owner plans a week of runs Monday to Sunday.
enum HistoryWeeks {

    /// The weekly goal the summary counts against: three runs a week, on whichever days.
    static let runGoal = 3

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    /// The Monday that starts `date`'s week, at midnight.
    static func start(of date: Date) -> Date {
        // Every date has a week in the Gregorian calendar; nil here would be a Foundation bug, and
        // guessing a week instead would file runs under the wrong one without saying so.
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            preconditionFailure("No week contains \(date)")
        }
        return week.start
    }

    struct Total: Identifiable {
        let start: Date
        let runs: Int
        let miles: Double
        let seconds: TimeInterval
        var id: Date { start }
    }

    /// The last `count` weeks, oldest first, including weeks with no runs.
    static func totals(_ runs: [HistoryRun], now: Date, count: Int = 8) -> [Total] {
        let thisWeek = start(of: now)
        return (0..<count).reversed().map { back in
            let weekStart = adding(days: -7 * back, to: thisWeek)
            let inWeek = runs.filter { start(of: $0.workout.startDate) == weekStart }
            return Total(start: weekStart,
                         runs: inWeek.count,
                         miles: inWeek.reduce(0) { $0 + ($1.workout.distanceMiles ?? 0) },
                         seconds: inWeek.reduce(0) { $0 + $1.workout.duration })
        }
    }

    /// "This week", "Last week", or the week's dates.
    static func title(weekStart: Date, now: Date) -> String {
        let thisWeek = start(of: now)
        if weekStart == thisWeek { return "This week" }
        if weekStart == adding(days: -7, to: thisWeek) { return "Last week" }
        let end = adding(days: 6, to: weekStart)
        return shortDate.string(from: weekStart) + " – " + shortDate.string(from: end)
    }

    /// Calendar arithmetic on a Gregorian date. Nil would be a Foundation bug; substituting a date
    /// would mislabel weeks without saying so, so it stops instead.
    static func adding(days: Int, to date: Date) -> Date {
        guard let result = calendar.date(byAdding: .day, value: days, to: date) else {
            preconditionFailure("Could not add \(days) days to \(date)")
        }
        return result
    }

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}

enum HistoryGrouper {

    static func filtered(_ runs: [HistoryRun], by filter: HistoryFilter) -> [HistoryRun] {
        switch filter {
        case .all: return runs
        case .kind(let kind): return runs.filter { $0.kind == kind }
        }
    }

    /// Newest week first, and inside a week, Monday to Sunday — the order the days were run in.
    static func byWeek(_ runs: [HistoryRun], now: Date, showsGoal: Bool) -> [HistoryGroup] {
        let weeks = Dictionary(grouping: runs) { HistoryWeeks.start(of: $0.workout.startDate) }
        return weeks.keys.sorted(by: >).map { weekStart in
            let inWeek = (weeks[weekStart] ?? []).sorted { $0.workout.startDate < $1.workout.startDate }
            let miles = inWeek.reduce(0) { $0 + ($1.workout.distanceMiles ?? 0) }
            let distance = String(format: "%.1f mi", miles)
            let detail = showsGoal
                ? "\(inWeek.count) of \(HistoryWeeks.runGoal) · " + distance
                : distance
            return HistoryGroup(id: "week-\(weekStart.timeIntervalSince1970)",
                                title: HistoryWeeks.title(weekStart: weekStart, now: now),
                                detail: detail,
                                runs: inWeek)
        }
    }

    /// Speed, Recovery, Endurance, then runs without a kind; newest first inside each.
    static func byKind(_ runs: [HistoryRun]) -> [HistoryGroup] {
        let newestFirst = runs.sorted { $0.workout.startDate > $1.workout.startDate }
        var groups: [HistoryGroup] = RunKind.allCases.compactMap { kind in
            let inKind = newestFirst.filter { $0.kind == kind }
            guard !inKind.isEmpty else { return nil }
            return HistoryGroup(id: "kind-\(kind.rawValue)", title: kind.displayName,
                                detail: count(inKind), runs: inKind)
        }
        let without = newestFirst.filter { $0.kind == nil }
        if !without.isEmpty {
            groups.append(HistoryGroup(id: "kind-none", title: "No kind",
                                       detail: count(without), runs: without))
        }
        return groups
    }

    private static func count(_ runs: [HistoryRun]) -> String {
        runs.count == 1 ? "1 run" : "\(runs.count) runs"
    }
}
