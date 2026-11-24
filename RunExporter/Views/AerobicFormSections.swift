import SwiftUI

/// A plan's intent (aerobic spec §1, §25): one picker, "None" unless chosen, and the aerobic target
/// shown only once Easy aerobic is chosen — an ordinary plan asks nothing more.
///
/// Shared by both plan editors so the two cannot come to describe intent differently.
struct IntensitySection: View {
    @Binding var mode: WorkoutIntensityMode

    /// What the picker offers: today's modes, plus the plan's own if it is one not offered — a
    /// picker whose selection has no row shows nothing, which would read as "None".
    private var options: [WorkoutIntensityMode] {
        WorkoutIntensityMode.offered.contains(mode)
            ? WorkoutIntensityMode.offered : WorkoutIntensityMode.offered + [mode]
    }

    var body: some View {
        Section {
            Picker("Intensity", selection: $mode) {
                ForEach(options) { option in
                    Text(option.displayName).tag(option)
                }
            }
            if mode == .easyAerobicObservation {
                LabeledContent("Target effort", value: WorkoutIntensityMode.easyAerobicTargetText)
            }
        } header: {
            Text("Intensity")
        } footer: {
            if mode == .easyAerobicObservation {
                Text("Heart rate is recorded, not targeted.")
            }
        }
    }
}

/// The intent an editor reads from and writes to a plan.
///
/// An editor writes intent only when it is new or changed. A stored value this build does not
/// know reads as nil; rewriting it as "None" on an unrelated save would replace it silently.
struct IntensityChoice {
    var mode: WorkoutIntensityMode = .notSpecified
    private var loaded: WorkoutIntensityMode?

    init() {}

    init(plan: PlannedWorkout) {
        loaded = plan.intensity
        mode = plan.intensity ?? .notSpecified
    }

    func write(to plan: PlannedWorkout, isNew: Bool) {
        guard isNew || mode != (loaded ?? .notSpecified) else { return }
        plan.intensityMode = mode.rawValue
        switch mode {
        case .easyAerobicObservation:
            plan.targetRPEMin = WorkoutIntensityMode.easyAerobicRPE.lowerBound
            plan.targetRPEMax = WorkoutIntensityMode.easyAerobicRPE.upperBound
            plan.targetHeartRateMin = nil
            plan.targetHeartRateMax = nil
        case .notSpecified:
            plan.targetRPEMin = nil
            plan.targetRPEMax = nil
            plan.targetHeartRateMin = nil
            plan.targetHeartRateMax = nil
        case .heartRateRange:
            // Not offered (§20). Kept as the plan already holds it.
            plan.targetRPEMin = nil
            plan.targetRPEMax = nil
        }
    }
}

// The talk test's form section (aerobic spec §7) was removed 2026-11-24: it was never once
// answered. `TalkTest` and `RunLog.talkTest` stay, so answers already given are kept and exported.
