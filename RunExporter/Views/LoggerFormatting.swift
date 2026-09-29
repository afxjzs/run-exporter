import Foundation
import SwiftUI

/// Display formatting shared by the logger screens.
///
/// Separate from `Fmt`, which formats values for the export files: those must stay machine-stable
/// and locale-independent, while these are for humans and follow the device's locale.
enum Display {

    /// "4:03" or "1:04:03".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Interval countdown, always m:ss so the digits do not jump around mid-run.
    static func countdown(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", max(0, total) / 60, max(0, total) % 60)
    }

    static func miles(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f mi", value)
    }

    /// Pace as m:ss per mile.
    static func pace(_ secondsPerMile: Double?) -> String {
        guard let secondsPerMile, secondsPerMile.isFinite, secondsPerMile > 0 else { return "—" }
        let total = Int(secondsPerMile.rounded())
        return String(format: "%d:%02d /mi", total / 60, total % 60)
    }

    static func heartRate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded())) bpm"
    }

    static func temperature(_ fahrenheit: Double?) -> String {
        guard let fahrenheit, fahrenheit.isFinite else { return "—" }
        return "\(Int(fahrenheit.rounded()))°F"
    }

    static func humidity(_ percent: Double?) -> String {
        guard let percent, percent.isFinite else { return "—" }
        return "\(Int(percent.rounded()))% humidity"
    }

    /// Half-point ratings read as "6" or "6.5", never "6.0".
    static func rating(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "Today", "Yesterday", or "Aug 3".
    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    static func dayAndTime(_ date: Date) -> String {
        "\(relativeDay(date)) · \(timeFormatter.string(from: date))"
    }

    /// Clock time including seconds — "14:32:07".
    ///
    /// Exists for controls whose result is often identical to what was already on screen. A refresh
    /// that re-reads unchanged data looks broken; a timestamp that visibly ticks proves it ran.
    /// Seconds are the point — minutes alone leave two taps in the same minute indistinguishable.
    static func timeWithSeconds(_ date: Date) -> String {
        secondsFormatter.string(from: date)
    }

    static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

extension WorkoutNote {

    /// Where in the workout this note was taken — "Walk · round 3 · 12:22".
    ///
    /// Lives here rather than on the model so the two screens that show a note cannot drift apart
    /// in how they describe it, while the model stays free of display formatting. An unrecognized
    /// stored phase is shown raw rather than swapped for something plausible.
    var contextSummary: String {
        let phase = phaseTypeValue?.displayName ?? phaseType
        let elapsed = Display.duration(secondsIntoWorkout)
        guard let repetitionNumber else { return "\(phase) · \(elapsed)" }
        return "\(phase) · round \(repetitionNumber) · \(elapsed)"
    }
}

/// A 1–10 scale in half-point steps.
///
/// A slider rather than a row of chips: twenty values is too many to tap accurately, and the
/// spec's 15–20 second budget rules out a picker wheel. `value` is optional so the control can
/// show "not chosen yet" — required fields must not arrive pre-answered (spec §26, Test 6).
struct HalfPointRatingPicker: View {
    let title: String
    let lowLabel: String
    let highLabel: String
    @Binding var value: Double?
    /// 1–10 for the effort and heat questions. An open-interval plan's signal reading uses 0–10,
    /// because a leg that ended when the target arrived can legitimately have felt like nothing.
    var range: ClosedRange<Double> = 1...10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let value {
                    Text(Display.rating(value))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                } else {
                    Text("Not set")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Unset, the thumb rests at the bottom of the scale rather than the middle. A centred
            // thumb reads as an answer already given — the orange warning below was carrying that
            // correction on its own, and a glance does not read warnings.
            //
            // `onEditingChanged` is what makes the lowest value reachable: touching the thumb
            // records the value under it. Without that, selecting the bottom of the scale would
            // mean dragging away and back, because a drag that never moves emits no new value.
            Slider(value: Binding(get: { value ?? range.lowerBound },
                                  set: { value = ($0 * 2).rounded() / 2 }),
                   in: range,
                   step: 0.5,
                   onEditingChanged: { editing in
                       if editing, value == nil { value = range.lowerBound }
                   })
                .tint(value == nil ? .secondary : .accentColor)

            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if value == nil {
                Text("Move the slider to choose a value.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A duration as two wheels, minutes and seconds.
///
/// Shared by both plan editors. The block editor had it first and the open-interval editor used
/// steppers, which meant setting a time felt like two different jobs depending on which kind of
/// plan you were building. Wheels win for this: a duration is picked from a range, not counted up
/// to, and a stepper asks for thirty taps to reach thirty minutes.
///
/// Seconds are quarter-minutes only. A run interval of 4:37 is not a thing anyone means, and the
/// shorter list is faster to land on with a thumb.
struct DurationWheels: View {

    let label: String
    @Binding var minutes: Int
    @Binding var seconds: Int
    /// Up to 30 suits an interval; an open-interval plan's target runs longer.
    var minuteRange: ClosedRange<Int> = 0...30

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Picker("\(label) minutes", selection: $minutes) {
                ForEach(Array(minuteRange), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(width: 62, height: 96)
            .clipped()
            Text("min")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("\(label) seconds", selection: $seconds) {
                ForEach([0, 15, 30, 45], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(width: 62, height: 96)
            .clipped()
            Text("sec")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A 0–10 body-signal stepper.
///
/// Defaults to 0 and stays there unless changed: 0 is a real answer meaning "nothing felt wrong",
/// which is why it is safe to pre-fill here but not for RPE or heat.
struct BodySignalRow: View {
    let area: BodyArea
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(area.displayName)
            Spacer()
            Text(Display.rating(value))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? .primary : .secondary)
                .frame(minWidth: 28, alignment: .trailing)
            // Half points, because the distinction a runner may actually be measuring lives
            // between the integers: the first clearly identifiable signal is a 0.5, and calling it
            // a 1 would put it on the same footing as a signal twice its size. `Display.rating` has
            // always formatted halves — the stepper was the only thing rounding them away.
            Stepper(area.displayName,
                    value: $value,
                    in: 0...10,
                    step: 0.5)
                .labelsHidden()
        }
    }
}
