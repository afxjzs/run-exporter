import SwiftUI
import MapKit

/// The top of a run's detail screen (History redesign, 2026-11-24): a map you can move, the
/// running figures, and every leg as it was run. The screen's older sections follow unchanged.
///
/// Figures come from `RunLoggerModel.progress` — the export's own leg derivation and
/// `AerobicAnalysis` — so the detail, the charts and the export agree about a run.
struct RunDetailSections<Middle: View>: View {
    let workout: HealthKitManager.WorkoutSummary
    let logger: RunLoggerModel
    /// Shown between the figures and the legs — the run's kind, near the top where it is found.
    @ViewBuilder let middle: () -> Middle

    @State private var route: RouteLoad?
    @State private var showHeartRateInfo = false
    @State private var showEfficiencyInfo = false
    @State private var showLegsInfo = false

    private var progress: RunProgress? { logger.progress[workout.uuid] }

    var body: some View {
        Group {
            Section {
                map
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
            }
            Section { figures }
            middle()
            legsSection
        }
        .task {
            route = await logger.route(for: workout)
            // Reached from Today too, before History has loaded anything.
            if logger.progress[workout.uuid] == nil { await logger.loadProgress() }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var map: some View {
        switch route {
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noRoute:
            Text("No route recorded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            Text("Route couldn't be shown: " + reason)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .points(let points):
            Map(initialPosition: .rect(Self.fitted(points))) {
                MapPolyline(coordinates: points)
                    .stroke(.red, lineWidth: 4)
                if let start = points.first {
                    Annotation("Start", coordinate: start) {
                        Circle().fill(.green).stroke(.black, lineWidth: 2).frame(width: 14, height: 14)
                    }
                }
            }
        }
    }

    /// The route's bounds with room around it, so the line never touches the edge.
    private static func fitted(_ points: [CLLocationCoordinate2D]) -> MKMapRect {
        let bounds = MKPolyline(coordinates: points, count: points.count).boundingMapRect
        return bounds.insetBy(dx: -max(bounds.width * 0.25, 200), dy: -max(bounds.height * 0.25, 200))
    }

    // MARK: - Figures

    private var figures: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                figure("Running pace", value: Display.pace(progress?.runningPaceSecondsPerMile),
                       note: "run legs only")
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Efficiency").font(.subheadline).foregroundStyle(.secondary)
                        InfoToggle(isShown: $showEfficiencyInfo, subject: "efficiency")
                    }
                    Text(efficiencyValue).font(.title3.bold())
                    Text(efficiencyNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showEfficiencyInfo {
                Text(Self.efficiencyExplanation).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Heart rate").font(.subheadline).foregroundStyle(.secondary)
                    InfoToggle(isShown: $showHeartRateInfo, subject: "heart rate")
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(runningHeartRate).font(.title3.bold())
                    Text(wholeHeartRate).font(.title3.bold()).foregroundStyle(.secondary)
                }
                if showHeartRateInfo {
                    Text(Self.heartRateExplanation).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func figure(_ title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var efficiencyValue: String {
        guard let efficiency = progress?.efficiency else { return "—" }
        return String(format: "%.2f", efficiency)
    }

    /// Why there is no figure, when there is none — each reason said as itself.
    private var efficiencyNote: String {
        guard let progress else { return "reading…" }
        if progress.efficiency != nil { return "m per heartbeat" }
        if progress.recorded == nil { return "no recorded legs" }
        if let problem = progress.samplesProblem { return problem }
        return "too little Watch heart rate"
    }

    private var runningHeartRate: String {
        guard let rate = progress?.runningHeartRate else { return "— running" }
        return Display.heartRate(rate) + " running"
    }

    /// The whole workout's average, or for a run whose Watch kept recording, the whole timer's
    /// (`RunClip`): Health's own average there includes the hours after the run.
    private var wholeHeartRate: String {
        let run = logger.allHistoryRunsIncludingHidden().first(where: { $0.id == workout.uuid })
        if let run, run.clip != nil {
            return Display.heartRate(run.figures.averageHeartRate) + " whole run"
        }
        return Display.heartRate(workout.averageHeartRate) + " whole workout"
    }

    static var heartRateExplanation: String { "Running counts the run legs only, so it is higher than the "
        + "whole workout, which includes the walks." }

    static var efficiencyExplanation: String { "How far you travel for each heartbeat while running: "
        + "running speed divided by running heart rate, walks left out. More ground for the same "
        + "heartbeats means your heart is doing less work at that pace. It compares fairly only "
        + "with runs of the same kind." }

    // MARK: - Legs

    @ViewBuilder
    private var legsSection: some View {
        if let recorded = progress?.recorded {
            Section {
                if showLegsInfo {
                    Text("Each leg as it was run, pauses removed. Heart rate start → end shows how "
                         + "fast it climbed in a run and how far it came back down in the walk after.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Self.shown(recorded.legs), id: \.intervalLogID) { leg in
                    legRow(leg)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Legs")
                    InfoToggle(isShown: $showLegsInfo, subject: "legs")
                }
            }
        }
    }

    /// Run, walk, warmup and cooldown legs; the countdown before the start is not a leg anyone ran.
    private static func shown(_ legs: [RecordedRun.Leg]) -> [RecordedRun.Leg] {
        legs.filter { [.warmup, .run, .walk, .cooldown].contains($0.phase) }
    }

    private func legRow(_ leg: RecordedRun.Leg) -> some View {
        let stats = progress?.analysis?.legs[leg.intervalLogID]
        let meters = progress?.meters(in: leg)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.name(of: leg)).font(.headline)
                Spacer()
                if let reason = leg.endReason {
                    Text(reason.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    legFigure(Display.duration(leg.activeSeconds), "time")
                    legFigure(meters.map { String(format: "%.2f", $0 / AerobicAnalysis.metersPerMile) } ?? "—", "mi")
                    legFigure(Self.pace(meters: meters, seconds: leg.activeSeconds), "pace /mi")
                }
                GridRow {
                    legFigure(Self.startToEnd(stats), "HR start → end")
                    legFigure(stats?.average.map { String(Int($0.rounded())) } ?? "—", "avg HR")
                }
            }
        }
        .opacity(leg.phase == .run ? 1 : 0.75)
        .accessibilityElement(children: .contain)
    }

    private func legFigure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.subheadline.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private static func name(of leg: RecordedRun.Leg) -> String {
        switch leg.phase {
        case .run: return leg.repetition.map { "Run \($0)" } ?? "Run"
        case .walk: return leg.repetition.map { "Walk \($0)" } ?? "Walk"
        case .warmup: return "Warmup"
        case .cooldown: return "Cooldown"
        case .idle, .countdown, .paused, .completed: return leg.phase.rawValue
        }
    }

    private static func pace(meters: Double?, seconds: Double) -> String {
        guard let meters, meters > 0, seconds > 0 else { return "—" }
        let perMile = seconds / (meters / AerobicAnalysis.metersPerMile)
        let total = Int(perMile.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func startToEnd(_ stats: AerobicAnalysis.Leg?) -> String {
        guard let start = stats?.startHeartRate, let end = stats?.endHeartRate else { return "—" }
        return "\(Int(start.rounded())) → \(Int(end.rounded()))"
    }
}
