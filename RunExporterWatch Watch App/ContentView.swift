import SwiftUI

/// Stage 2 harness UI (`docs/WATCHOS_RECORDER_PLAN.md` §9).
///
/// This is a measuring instrument, not a product screen. Everything on it exists so the result of
/// the five-minute wrist-down test can be read **at a glance**, because `devicectl` cannot reach
/// this Watch to pull the log (see `BackgroundExecutionProbe`).
///
/// The worst gap is the headline and is sized accordingly: it is the single number that decides
/// whether the whole watch-recorder premise survives.
struct ContentView: View {
    @State private var probe = BackgroundExecutionProbe()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                verdict
                counters
                if let error = probe.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
                footnote
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Verdict

    /// Deliberately phrased as a measurement, not a pass mark. A green tick before the full five
    /// minutes have elapsed would be a status report that outran the evidence.
    private var verdict: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WORST GAP")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(gapText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(gapColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private var gapText: String {
        guard probe.tickCount > 0 else { return "—" }
        return String(format: "%.1fs", probe.worstGap)
    }

    /// Grey until there is data; green while gaps look like ordinary jitter; red once a gap is big
    /// enough to mean the app was suspended.
    private var gapColor: Color {
        guard probe.tickCount > 0 else { return .secondary }
        return probe.worstGap > 2.5 ? .red : .green
    }

    // MARK: - Counters

    private var counters: some View {
        let minutes = Int(probe.elapsed) / 60
        let seconds = Int(probe.elapsed) % 60
        let elapsedText = String(format: "%d:%02d", minutes, seconds)

        return VStack(alignment: .leading, spacing: 3) {
            row("elapsed", elapsedText)
            row("ticks", "\(probe.tickCount)")
            row("gaps > 2.5s", "\(probe.gapCount)")
            row("session", probe.sessionState)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        Group {
            if probe.isRunning {
                Button("Stop", role: .destructive) { probe.stop() }
            } else {
                Button("Start probe") {
                    Task { await probe.start() }
                }
                .tint(.green)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start, lower your wrist, wait 5 minutes, then raise it and read WORST GAP.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let name = probe.logFileName {
                Text(name)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }
}

#Preview {
    ContentView()
}
