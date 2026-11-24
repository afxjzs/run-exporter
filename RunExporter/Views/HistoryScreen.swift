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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("History")
        .refreshable { await logger.refresh() }
        .task { if logger.recentWorkouts.isEmpty { await logger.refresh() } }
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

    private var emptyFilterText: String {
        guard case .kind(let kind) = filter else { return "" }
        return "No " + kind.displayName.lowercased() + " runs in the last 120 days."
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
                BarMark(x: .value("Week", HistoryWeeks.shortDate.string(from: total.start)),
                        y: .value("Miles", total.miles))
                    .foregroundStyle(total.start == week?.start ? Color.green : Color.gray.opacity(0.5))
                    .cornerRadius(4)
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
        parts.append(Display.miles(run.workout.distanceMiles))
        parts.append(Display.duration(run.workout.duration))
        if let heartRate = run.workout.averageHeartRate {
            parts.append(Display.heartRate(heartRate) + " avg")
        }
        return parts.joined(separator: " · ")
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()
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
            .task(id: workout.uuid) { await load() }
    }

    @ViewBuilder
    private var content: some View {
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

    private func load() async {
        switch await logger.route(for: workout) {
        case .noRoute:
            phase = .noRoute
        case .failed(let reason):
            phase = .failed(reason)
        case .points(let points):
            do {
                phase = .drawn(try await RouteSnapshot.draw(points,
                                                            size: CGSize(width: 400, height: height),
                                                            dark: colorScheme == .dark))
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
