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
                LabeledContent("Target effort", value: Self.aerobicTarget)
            }
        } header: {
            Text("Intensity")
        } footer: {
            if mode == .easyAerobicObservation {
                Text("Heart rate is recorded, not targeted. After the run you will be asked how "
                     + "talking felt.")
            }
        }
    }

    /// Its own string: interpolation inside a view initializer fails this project's Release build.
    private static var aerobicTarget: String {
        let range = WorkoutIntensityMode.easyAerobicRPE
        return "RPE \(Int(range.lowerBound))–\(Int(range.upperBound)) · conversational"
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

/// The talk test (aerobic spec §7), for a run whose plan was easy aerobic. Shared by both run-log
/// forms.
struct TalkTestSection: View {
    @Binding var talkTest: TalkTest?

    var body: some View {
        Section {
            Picker("Talk test", selection: Binding(get: { talkTest ?? .notRecorded },
                                                   set: { talkTest = $0 })) {
                ForEach(TalkTest.allCases) { answer in
                    Text(answer.displayName).tag(answer)
                }
            }
        } footer: {
            Text("How talking would have felt during the run.")
        }
    }
}

extension RunLoggerModel {
    /// Whether a run's log form asks the talk test: only for a run planned as easy aerobic (§7).
    func offersTalkTest(executionID: UUID?) -> Bool {
        intensity(forExecution: executionID) == .easyAerobicObservation
    }
}
