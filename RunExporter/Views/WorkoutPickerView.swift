import SwiftUI

/// Asks which workout was just completed (spec §14).
///
/// Shown whenever the matcher cannot single out one workout with confidence. This screen exists so
/// the app never has to guess: a subjective log attached to the wrong workout is not something the
/// user has any way to notice later.
struct WorkoutPickerView: View {
    let workouts: [HealthKitManager.WorkoutSummary]
    let onSelect: (HealthKitManager.WorkoutSummary) -> Void
    let onCancel: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(workouts) { workout in
                    Button {
                        onSelect(workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Display.timeFormatter.string(from: workout.startDate)) · "
                                 + workout.activityType.displayName)
                                .font(.headline)
                            Text("\(Display.miles(workout.distanceMiles)) · "
                                 + Display.duration(workout.duration))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(Display.relativeDay(workout.startDate)) · \(workout.sourceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Which workout did you just complete?")
            } footer: {
                Text("More than one workout could be the one you just finished, so this app will "
                     + "not choose for you.")
            }
        }
        .navigationTitle("Select Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not now") { onCancel() }
            }
        }
    }
}
