import SwiftUI
import Charts
import MapKit

/// Past runs: this week against the weekly goal, then every run as a card with its route, grouped
/// by week or by kind (redesigned 2026-11-24; the prototype that settled it is on the
/// `prototype/history-redesign` branch).
///
/// Runs only. The old Logged/Unlogged/Walks filters are gone: logging state is a badge on each
/// card, and walks the Watch suggests while walking about are not runs.
struct HistoryView: View {
    let logger: RunLoggerModel

    @State private var filter: HistoryFilter = .all
    @State private var grouping: HistoryGrouping = .week

    private var runs: [HistoryRun] { logger.historyRuns() }

    var body: some View {
        let all = runs
        let now = Date()
        let shown = HistoryGrouper.filtered(all, by: filter)
        let groups = filter == .all && grouping == .kind
            ? HistoryGrouper.byKind(shown)
            : HistoryGrouper.byWeek(shown, now: now, showsGoal: filter == .all)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HistorySummaryCard(runs: all, now: now)
                controls
                HistoryChartsRow(runs: shown, filter: filter, progress: logger.progress,
                                 notice: logger.progressNotice)
                if all.isEmpty {
                    Text(logger.isLoading ? "Reading Health…" : "No runs in the last 120 days.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                } else if shown.isEmpty {
                    Text(emptyFilterText)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
                ForEach(groups) { group in
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.title).font(.headline)
                        Spacer()
                        Text(group.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                    ForEach(group.runs) { run in
                        NavigationLink {
                            WorkoutDetailView(workout: run.workout, logger: logger)
                        } label: {
                            HistoryRunCard(run: run, logger: logger)
                        }
                        .buttonStyle(.plain)
                    }
                }
                hiddenRunsLink
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("History")
        .refreshable { await logger.refresh() }
        .task { if logger.recentWorkouts.isEmpty { await logger.refresh() } }
        // Again whenever the set of runs changes. Samples are cached, so this reads Health only
        // for runs it has not seen.
        .task(id: logger.recentWorkouts.map(\.uuid)) { await logger.loadProgress() }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Kind", selection: $filter) {
            Text("All").tag(HistoryFilter.all)
            ForEach(RunKind.allCases) { kind in
                Text(kind.displayName).tag(HistoryFilter.kind(kind))
            }
        }
        .pickerStyle(.segmented)
        if filter == .all {
            Picker("Group", selection: $grouping) {
                ForEach(HistoryGrouping.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The way back to runs hidden from History. Only there when some are.
    @ViewBuilder
    private var hiddenRunsLink: some View {
        let hidden = logger.hiddenHistoryRuns()
        if !hidden.isEmpty {
            NavigationLink("Hidden runs (\(hidden.count))") {
                HiddenRunsView(logger: logger)
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyFilterText: String {
        guard case .kind(let kind) = filter else { return "" }
        return "No " + kind.displayName.lowercased() + " runs in the last 120 days."
    }
}

/// The two "am I getting better" charts, side by side, swiped between. Both show only the runs the
/// kind control shows, because a speed day and a recovery day are not comparable.
private struct HistoryChartsRow: View {
    let runs: [HistoryRun]
    let filter: HistoryFilter
    let progress: [UUID: RunProgress]
    let notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    LongestLegCard(runs: runs, filter: filter, progress: progress)
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.88 }
                    EfficiencyCard(runs: runs, filter: filter, progress: progress)
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.88 }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// "runs", or "recovery runs" when one kind is shown — for "Needs 3 … You have 2."
private func kindWord(_ filter: HistoryFilter) -> String {
    switch filter {
    case .all: return "runs"
    case .kind(let kind): return kind.displayName.lowercased() + " runs"
    }
}

/// "all runs", or "recovery runs" — for a chart's title.
private func kindTitle(_ filter: HistoryFilter) -> String {
    filter == .all ? "all runs" : kindWord(filter)
}

/// A colored dot, then the text in the secondary color, for a chart legend.
private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// One point on a chart, oldest first.
private struct ChartPoint: Identifiable {
    let index: Int
    let run: HistoryRun
    let progress: RunProgress
    var id: Int { index }
}

/// The charts need this many runs before a line means anything.
private let chartMinimumRuns = 3

/// A tappable ⓘ that shows or hides an explanation, so long text is there when wanted and out
/// of the way otherwise.
struct InfoToggle: View {
    @Binding var isShown: Bool
    /// What it explains, for VoiceOver and the UI test: "About heart rate".
    var subject = "this chart"
    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: isShown ? "info.circle.fill" : "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About " + subject)
        .accessibilityValue(isShown ? "shown" : "hidden")
    }
}

private struct LongestLegCard: View {
    let runs: [HistoryRun]
    let filter: HistoryFilter
    let progress: [UUID: RunProgress]

    @State private var showInfo = false
    @State private var selected: Int?

    var body: some View {
        let points = runs.sorted { $0.workout.startDate < $1.workout.startDate }
            .compactMap { run -> HistoryRun? in progress[run.id]?.longestLegMinutes == nil ? nil : run }
            .enumerated()
            .compactMap { index, run in progress[run.id].map { ChartPoint(index: index, run: run, progress: $0) } }
        let missing = runs.count - points.count

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                InfoToggle(isShown: $showInfo)
            }
            if showInfo {
                Text(explanation(missing: missing)).font(.caption).foregroundStyle(.secondary)
            }
            if points.count < chartMinimumRuns {
                Text(needsText(points.count))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .multilineTextAlignment(.center)
            } else {
                if let last = points.last?.progress.longestLegMinutes {
                    Text(String(format: "%.1f min", last)).font(.title2.bold())
                }
                // Two charts, not two lines on one: running minutes (around 20) on the same axis
                // as the longest leg (a few minutes) flattened the line that matters most.
                Chart(points) { point in
                    LineMark(x: .value("Run", point.index),
                             y: .value("Longest leg", point.progress.longestLegMinutes ?? 0))
                    PointMark(x: .value("Run", point.index),
                              y: .value("Longest leg", point.progress.longestLegMinutes ?? 0))
                }
                .foregroundStyle(.green)
                .chartXAxis(.hidden)
                .chartXSelection(value: $selected)
                .frame(height: 90)
                Chart(points) { point in
                    LineMark(x: .value("Run", point.index),
                             y: .value("Running minutes", point.progress.runningMinutes ?? 0))
                    PointMark(x: .value("Run", point.index),
                              y: .value("Running minutes", point.progress.runningMinutes ?? 0))
                }
                .foregroundStyle(.blue)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .chartXSelection(value: $selected)
                .frame(height: 60)
                HStack(spacing: 12) {
                    Label("longest leg", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("running minutes", systemImage: "circle.fill").foregroundStyle(.blue)
                }
                .font(.caption)
                .labelStyle(LegendLabelStyle())
                Text(tip(points))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var title: String { "Longest run leg · " + kindTitle(filter) }

    private func needsText(_ have: Int) -> String {
        "Needs \(chartMinimumRuns) " + kindWord(filter) + " with recorded legs. You have \(have)."
    }

    private func explanation(missing: Int) -> String {
        var text = "Green is your longest unbroken run leg; blue is every minute you ran in that "
            + "workout. A leg you skipped or cut short counts for what you actually ran."
        if missing > 0 {
            text += " \(missing) of these runs have no recorded legs and are left out."
        }
        return text
    }

    private func tip(_ points: [ChartPoint]) -> String {
        guard let selected, let point = points.first(where: { $0.index == selected }) else {
            return "Tap a point for that run"
        }
        let day = HistoryRunCard.day.string(from: point.run.workout.startDate)
        let longest = String(format: "%.1f", point.progress.longestLegMinutes ?? 0)
        let running = String(format: "%.0f", point.progress.runningMinutes ?? 0)
        return day + " · longest leg " + longest + " min · " + running + " min running"
    }
}

private struct EfficiencyCard: View {
    let runs: [HistoryRun]
    let filter: HistoryFilter
    let progress: [UUID: RunProgress]

    @State private var showInfo = false
    @State private var selected: Int?

    var body: some View {
        let withEfficiency = runs.sorted { $0.workout.startDate < $1.workout.startDate }
            .filter { progress[$0.id]?.efficiency != nil }
        let points = withEfficiency.enumerated().compactMap { index, run in
            progress[run.id].map { ChartPoint(index: index, run: run, progress: $0) }
        }
        let unreadable = runs.compactMap { progress[$0.id]?.samplesProblem }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                InfoToggle(isShown: $showInfo)
            }
            if showInfo {
                Text(explanation(left: runs.count - points.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if points.count < chartMinimumRuns {
                Text(needsText(points.count))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .multilineTextAlignment(.center)
            } else {
                if let last = points.last?.progress.efficiency {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.2f", last)).font(.title2.bold())
                        Text("m per heartbeat").foregroundStyle(.secondary)
                    }
                }
                Chart(points) { point in
                    LineMark(x: .value("Run", point.index),
                             y: .value("Meters per beat", point.progress.efficiency ?? 0))
                        .foregroundStyle(.orange)
                    PointMark(x: .value("Run", point.index),
                              y: .value("Meters per beat", point.progress.efficiency ?? 0))
                        .foregroundStyle(.orange)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXSelection(value: $selected)
                .frame(height: 140)
                if filter == .all {
                    Text("Mixing kinds. Pick one above to compare like with like.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(tip(points))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            if !unreadable.isEmpty {
                Text(unreadableText(unreadable))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var title: String { "Efficiency · " + kindTitle(filter) }

    private func needsText(_ have: Int) -> String {
        "Needs \(chartMinimumRuns) " + kindWord(filter) + " with Watch heart rate. You have \(have)."
    }

    private func explanation(left: Int) -> String {
        var text = "How far you travel for each heartbeat while running: running speed divided by "
            + "running heart rate, walks left out. More ground for the same heartbeats means your "
            + "heart is doing less work at that pace, so up is fitter. It only compares fairly "
            + "between runs of the same kind."
        if left > 0 {
            text += " \(left) of these runs have too little Watch heart rate or no recorded legs, "
                + "and are left out."
        }
        return text
    }

    private func unreadableText(_ problems: [String]) -> String {
        let count = problems.count == 1 ? "1 run's" : "\(problems.count) runs'"
        return "Heart rate for " + count + " couldn't be read: " + (problems.first ?? "")
    }

    private func tip(_ points: [ChartPoint]) -> String {
        guard let selected, let point = points.first(where: { $0.index == selected }) else {
            return "Tap a point for that run's pace and heart rate"
        }
        let day = HistoryRunCard.day.string(from: point.run.workout.startDate)
        let value = String(format: "%.2f m/beat", point.progress.efficiency ?? 0)
        return day + " · " + value + " · " + Display.pace(point.progress.runningPaceSecondsPerMile)
            + " · " + Display.heartRate(point.progress.runningHeartRate) + " running"
    }
}

/// This week's runs against the goal, its miles and time, over eight weeks of miles.
private struct HistorySummaryCard: View {
    let runs: [HistoryRun]
    let now: Date

    var body: some View {
        let totals = HistoryWeeks.totals(runs, now: now)
        let week = totals.last
        VStack(alignment: .leading, spacing: 10) {
            Text("This week")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(goalText(week?.runs ?? 0)).font(.title2.bold())
                Text(String(format: "%.1f mi", week?.miles ?? 0)).font(.title2.bold())
                Text(Display.duration(week?.seconds ?? 0)).font(.title2.bold())
            }
            Chart(totals) { total in
                BarMark(x: .value("Week", HistoryWeeks.monthDay.string(from: total.start)),
                        y: .value("Miles", total.miles))
                    .foregroundStyle(total.start == week?.start ? Color.green : Color.gray.opacity(0.5))
                    .cornerRadius(4)
            }
            .chartXAxis {
                // Each bar's Monday, weekday over date: "Mon, Nov 23" is too wide for eight bars.
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            VStack(spacing: 0) {
                                Text(weekdays[label] ?? "")
                                Text(label)
                            }
                            .font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
            Text("Miles per week, each labeled by its Monday")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func goalText(_ count: Int) -> String {
        "\(count) of \(HistoryWeeks.runGoal) runs"
    }

    /// Each bar's label to its weekday.
    private var weekdays: [String: String] {
        Dictionary(HistoryWeeks.totals(runs, now: now).map {
            (HistoryWeeks.monthDay.string(from: $0.start), HistoryWeeks.weekday.string(from: $0.start))
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// One run: its route, then its day, kind, logging state and numbers. Reads as one element, so
/// VoiceOver and the UI test hear the whole card.
struct HistoryRunCard: View {
    let run: HistoryRun
    let logger: RunLoggerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RouteMapView(workout: run.workout, logger: logger, height: 120)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Self.day.string(from: run.workout.startDate)).font(.headline)
                    Spacer()
                    RunKindTag(kind: run.kind, unknown: run.unknownKind)
                    if !run.isLogged {
                        Text("Not logged")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.black)
                    }
                }
                Text(statLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let clipNote = Self.clipNote(run) {
                    Text(clipNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    /// Built here, not inline: this project's Release build fails on interpolation mixed with
    /// concatenation inside a view initializer.
    private var statLine: String {
        var parts: [String] = []
        if let plan = run.planName { parts.append(plan) }
        let figures = run.figures
        parts.append(figures.reading ? "reading…" : Display.miles(figures.miles))
        parts.append(Display.duration(figures.seconds))
        if let heartRate = figures.averageHeartRate {
            parts.append(Display.heartRate(heartRate) + " avg")
        }
        return parts.joined(separator: " · ")
    }

    /// Said on the card, so a run read only inside its timer never passes for Health's record.
    static func clipNote(_ run: HistoryRun) -> String? {
        guard let clip = run.clip else { return nil }
        let extra = run.workout.duration - clip.duration
        var note = "Watch kept recording \(Display.duration(extra)) more · only your timer is counted"
        if let problem = run.figures.problem { note += ". Miles and heart rate: " + problem }
        return note
    }

    static var day: DateFormatter { HistoryWeeks.day }
}

/// A run's kind as a colored tag, or "No kind", or — for a stored value this build does not
/// know — "Unknown kind", never quietly nothing.
struct RunKindTag: View {
    let kind: RunKind?
    let unknown: String?

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(kind == nil ? Color.primary : Color.black)
    }

    private var label: String {
        if let kind { return kind.displayName }
        return unknown == nil ? "No kind" : "Unknown kind"
    }

    private var color: Color {
        switch kind {
        case .speed: return .pink
        case .recovery: return .cyan
        case .endurance: return .purple
        case nil: return Color(.tertiarySystemFill)
        }
    }
}

/// A run's route as a still map, fitted to the route so an out-and-back fills the width.
struct RouteMapView: View {
    let workout: HealthKitManager.WorkoutSummary
    let logger: RunLoggerModel
    let height: CGFloat

    private enum Phase {
        case loading
        case drawn(UIImage)
        case noRoute
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The frame sets the size and the content is an overlay. As a ZStack child, a
        // `scaledToFill` image reported its own (wider) size and pushed the whole History column
        // past both edges of the screen.
        Color(.tertiarySystemFill)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay { content }
            .clipped()
            .task(id: mapKey) { await load() }
    }

    /// The cache key: one drawing per run, height and appearance.
    private var mapKey: String {
        "\(workout.uuid.uuidString)-\(Int(height))-\(colorScheme == .dark ? "dark" : "light")"
    }

    @ViewBuilder
    private var content: some View {
        if let drawn = logger.mapImage(mapKey) {
            Image(uiImage: drawn)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            switch phase {
            case .loading:
                ProgressView()
            case .drawn(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            case .noRoute:
                Text("No route recorded")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text("Route couldn't be shown: " + reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
    }

    private func load() async {
        let key = mapKey
        if let drawn = logger.mapImage(key) {
            phase = .drawn(drawn)
            return
        }
        switch await logger.route(for: workout) {
        case .noRoute:
            phase = .noRoute
        case .failed(let reason):
            phase = .failed(reason)
        case .points(let points):
            do {
                let drawn = try await RouteSnapshot.draw(points,
                                                         size: CGSize(width: 400, height: height),
                                                         dark: colorScheme == .dark)
                logger.keepMapImage(drawn, key: key)
                phase = .drawn(drawn)
            } catch {
                phase = .failed("the map could not be drawn (\(error.localizedDescription)).")
            }
        }
    }
}

/// A still map image with the route drawn on it.
enum RouteSnapshot {

    struct NoPoints: LocalizedError {
        var errorDescription: String? { "the route has no points" }
    }

    static func draw(_ points: [CLLocationCoordinate2D], size: CGSize, dark: Bool) async throws -> UIImage {
        guard !points.isEmpty else { throw NoPoints() }
        let line = MKPolyline(coordinates: points, count: points.count)
        let bounds = line.boundingMapRect
        // Padding so the line never touches the edge, and a floor so a very short route is not
        // zoomed to street-sign level.
        let padX = max(bounds.width * 0.2, 300)
        let padY = max(bounds.height * 0.2, 300)

        let options = MKMapSnapshotter.Options()
        options.mapRect = bounds.insetBy(dx: -padX, dy: -padY)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let snapshot = try await MKMapSnapshotter(options: options).start()

        return UIGraphicsImageRenderer(size: size).image { _ in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                let spot = snapshot.point(for: point)
                if index == 0 { path.move(to: spot) } else { path.addLine(to: spot) }
            }
            path.lineWidth = 4
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            UIColor.systemRed.setStroke()
            path.stroke()

            let start = snapshot.point(for: points[0])
            let dot = UIBezierPath(ovalIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12))
            UIColor.systemGreen.setFill()
            dot.fill()
        }
    }
}

/// Runs hidden from History, each with the way to show it again.
struct HiddenRunsView: View {
    let logger: RunLoggerModel

    var body: some View {
        let hidden = logger.hiddenHistoryRuns()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hidden runs are left out of History's cards, totals and charts. They stay in "
                     + "Apple Health and in exports.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if hidden.isEmpty {
                    Text("No hidden runs.").foregroundStyle(.secondary).padding(.vertical, 24)
                }
                ForEach(hidden) { run in
                    NavigationLink {
                        WorkoutDetailView(workout: run.workout, logger: logger)
                    } label: {
                        HistoryRunCard(run: run, logger: logger)
                    }
                    .buttonStyle(.plain)
                    Button("Show in History") {
                        if let error = logger.setHiddenFromHistory(false, workout: run.workout) {
                            logger.errorMessage = error
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Hidden runs")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Something went wrong",
               isPresented: Binding(get: { logger.errorMessage != nil },
                                    set: { if !$0 { logger.errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { logger.errorMessage = nil } },
               message: { Text(logger.errorMessage ?? "") })
    }
}
