import AVFAudio
import XCTest
@testable import RunExporter

/// The generated cue tones — checked as data, since whether they are *audible* is a hardware
/// question only a person with headphones on can answer.
final class ToneGeneratorTests: XCTestCase {

    func testWAVHasValidRIFFHeader() {
        let wav = ToneGenerator.wav(for: ToneGenerator.run)
        let bytes = [UInt8](wav)

        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: bytes[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
    }

    /// The declared chunk sizes must match the real byte counts, or decoders reject the file.
    func testWAVChunkSizesAreConsistent() {
        let samples = ToneGenerator.samples(for: ToneGenerator.walk)
        let wav = ToneGenerator.wav(samples: samples)
        let bytes = [UInt8](wav)

        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }

        XCTAssertEqual(Int(u32(4)), wav.count - 8, "RIFF chunk size")
        XCTAssertEqual(Int(u32(40)), samples.count * 2, "data chunk size")
    }

    /// Every generated WAV must actually decode — a cue that cannot be loaded is a silent cue.
    func testEveryCueToneDecodesAsPlayableAudio() throws {
        let cues: [AudioCue] = [.run, .walk, .cooldown, .complete,
                                .countdown(3), .nextPhase(.walk, seconds: 5)]
        for cue in cues {
            let data = ToneGenerator.wav(for: cue.tone)
            let player = try AVAudioPlayer(data: data)
            XCTAssertGreaterThan(player.duration, 0, "\(cue.identifier) has no duration")
        }
    }

    func testRunAndWalkTonesAreDistinguishable() {
        let run = ToneGenerator.samples(for: ToneGenerator.run)
        let walk = ToneGenerator.samples(for: ToneGenerator.walk)

        XCTAssertNotEqual(run, walk)
        // Run is a double beep, so it contains an interior run of silence that walk does not.
        let runSilenceGaps = countInteriorSilentRuns(run)
        let walkSilenceGaps = countInteriorSilentRuns(walk)
        XCTAssertGreaterThan(runSilenceGaps, walkSilenceGaps,
                             "Run should be a double beep and walk a single one")
    }

    func testSilenceIsActuallySilent() {
        let samples = ToneGenerator.samples(for: [])
        XCTAssertTrue(samples.isEmpty)

        let silence = ToneGenerator.silenceWAV(seconds: 0.1)
        let bytes = [UInt8](silence.dropFirst(44))
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 }, "Keep-alive audio must be inaudible")
    }

    /// Fading in and out prevents the click that an abrupt waveform start makes in earbuds.
    func testTonesStartAndEndNearZero() {
        let samples = ToneGenerator.samples(for: ToneGenerator.cooldown)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThan(abs(Int(samples.first!)), 500, "Tone must fade in")
        XCTAssertLessThan(abs(Int(samples.last!)), 500, "Tone must fade out")
    }

    func testTonesDoNotClip() {
        for segments in [ToneGenerator.run, ToneGenerator.walk,
                         ToneGenerator.cooldown, ToneGenerator.complete] {
            let peak = ToneGenerator.samples(for: segments).map { abs(Int($0)) }.max() ?? 0
            XCTAssertLessThan(peak, Int(Int16.max), "A cue must not clip at full scale")
        }
    }

    /// Counts stretches of silence that are surrounded by sound.
    private func countInteriorSilentRuns(_ samples: [Int16]) -> Int {
        var runs = 0
        var inSilence = false
        var sawSound = false
        for sample in samples {
            let silent = abs(Int(sample)) < 200
            if silent, sawSound, !inSilence {
                inSilence = true
            } else if !silent {
                if inSilence { runs += 1 }
                inSilence = false
                sawSound = true
            }
        }
        return runs
    }
}

/// Cue selection rules that do not need an audio device.
final class AudioCueTests: XCTestCase {

    func testTransitionCuesHaveDistinctSpokenText() {
        XCTAssertEqual(AudioCue.run.spokenText, "Run")
        XCTAssertEqual(AudioCue.walk.spokenText, "Walk")
        XCTAssertEqual(AudioCue.cooldown.spokenText, "Cooldown")
        XCTAssertEqual(AudioCue.complete.spokenText, "Workout complete")
        XCTAssertEqual(AudioCue.countdown(3).spokenText, "3")
    }

    /// The spoken remaining time must never exceed what the screen is showing.
    ///
    /// The display counts down in m:ss, so with 990 seconds left it reads "16:30". Rounding up
    /// announced "17 minutes left" over the top of it — observed on a real run. A cue that
    /// contradicts the number in front of the runner is worse than one half a minute conservative,
    /// so this truncates.
    func testRemainingRunningNeverAnnouncesMoreThanTheClockShows() {
        XCTAssertEqual(AudioCue.runningRemaining(seconds: 990).spokenText, "16 minutes left")
        XCTAssertEqual(AudioCue.runningRemaining(seconds: 1800).spokenText, "30 minutes left")
        XCTAssertEqual(AudioCue.runningRemaining(seconds: 120).spokenText, "2 minutes left")
        XCTAssertEqual(AudioCue.runningRemaining(seconds: 119).spokenText, "One minute left")
        XCTAssertEqual(AudioCue.runningRemaining(seconds: 59).spokenText, "Less than a minute left")
    }

    /// In beeps-only mode an announcement would be an unlabelled tick, which is worse than
    /// nothing — it is indistinguishable from a countdown tick.
    func testAnnouncementsAreMarkedAsVoiceOnly() {
        XCTAssertTrue(AudioCue.finalRound.isAnnouncementOnly)
        XCTAssertTrue(AudioCue.halfway.isAnnouncementOnly)
        XCTAssertFalse(AudioCue.run.isAnnouncementOnly)
        XCTAssertFalse(AudioCue.walk.isAnnouncementOnly)
        XCTAssertFalse(AudioCue.cooldown.isAnnouncementOnly)
    }

    func testCueIdentifiersAreUnique() {
        let cues: [AudioCue] = [.countdown(1), .countdown(2), .countdown(3),
                                .run, .walk, .cooldown, .complete,
                                .finalRound, .halfway, .nextPhase(.walk, seconds: 5),
                                .paused, .resumed(.run), .skipped, .ended]
        XCTAssertEqual(Set(cues.map(\.identifier)).count, cues.count)
    }

    // MARK: - Whether cues play at all

    /// **"No cues" must mean no cues** — confirmations of taps included.
    ///
    /// Regression test. The gate once let control confirmations through for every source that was
    /// not the iPhone engine — right for the Watch sources (removed 2026-09-29), but wrong for
    /// `.none`, whose Settings footer promises "No cues will play from this app at all." Choosing
    /// silence produced four cues, with nothing to indicate it. The gate no longer looks at the cue
    /// at all, so one assertion per source covers every cue.
    func testNoCuesSourceIsCompletelySilent() {
        XCTAssertFalse(AudioCueEngine.shouldPlay(source: .none))
    }

    func testIPhoneEnginePlaysEveryCue() {
        XCTAssertTrue(AudioCueEngine.shouldPlay(source: .iphoneAudioEngine))
    }
}

/// Shoe mileage arithmetic.
final class ShoeMileageTests: XCTestCase {

    private let shoeA = UUID()
    private let shoeB = UUID()
    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func assignment(_ shoe: UUID, day: Double, miles: Double?) -> ShoeMileage.Assignment {
        ShoeMileage.Assignment(shoeID: shoe,
                               workoutStartDate: base.addingTimeInterval(day * 86_400),
                               distanceMiles: miles)
    }

    func testAssignedMilesGroupByShoe() {
        let totals = ShoeMileage.assignedMiles(from: [
            assignment(shoeA, day: 0, miles: 2),
            assignment(shoeA, day: 1, miles: 3),
            assignment(shoeB, day: 2, miles: 5),
        ])

        XCTAssertEqual(totals[shoeA] ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(totals[shoeB] ?? 0, 5, accuracy: 0.0001)
    }

    func testNegativeAndNonFiniteDistancesContributeNothing() {
        let totals = ShoeMileage.assignedMiles(from: [
            assignment(shoeA, day: 0, miles: -4),
            assignment(shoeA, day: 1, miles: .nan),
            assignment(shoeA, day: 2, miles: nil),
            assignment(shoeA, day: 3, miles: 2),
        ])

        XCTAssertEqual(totals[shoeA] ?? 0, 2, accuracy: 0.0001)
    }

    func testMileageAtWorkoutIncludesThatWorkoutAndEarlierOnes() {
        let assignments = [assignment(shoeA, day: 0, miles: 2),
                           assignment(shoeA, day: 1, miles: 3),
                           assignment(shoeA, day: 2, miles: 4)]

        let atSecond = ShoeMileage.mileageAtWorkout(shoeID: shoeA,
                                                    startingMileage: 10,
                                                    workoutStartDate: base.addingTimeInterval(86_400),
                                                    assignments: assignments)

        XCTAssertEqual(atSecond, 15, accuracy: 0.0001)
    }

    func testMileageAtWorkoutIgnoresOtherShoes() {
        let assignments = [assignment(shoeA, day: 0, miles: 2),
                           assignment(shoeB, day: 0, miles: 99)]

        let value = ShoeMileage.mileageAtWorkout(shoeID: shoeA,
                                                 startingMileage: 0,
                                                 workoutStartDate: base,
                                                 assignments: assignments)

        XCTAssertEqual(value, 2, accuracy: 0.0001)
    }

    /// Two workouts starting at the same instant must produce a stable reading regardless of
    /// fetch order.
    func testSimultaneousWorkoutsAreOrderIndependent() {
        let assignments = [assignment(shoeA, day: 0, miles: 2),
                           assignment(shoeA, day: 0, miles: 3)]

        let forward = ShoeMileage.mileageAtWorkout(shoeID: shoeA, startingMileage: 0,
                                                   workoutStartDate: base,
                                                   assignments: assignments)
        let reversed = ShoeMileage.mileageAtWorkout(shoeID: shoeA, startingMileage: 0,
                                                    workoutStartDate: base,
                                                    assignments: assignments.reversed())

        XCTAssertEqual(forward, reversed, accuracy: 0.0001)
    }
}

/// Settings persistence, including how unreadable stored values are handled.
final class LoggerDefaultsTests: XCTestCase {

    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LoggerDefaultsTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testDefaultsMatchSpec() {
        let defaults = LoggerDefaults(defaults: suite)

        // Deliberate deviation from spec §9.2, which defaults to voice + beeps. Changed after a
        // real run where the cues drifted audibly off their seconds: the combined
        // mode plays a tone *and* an utterance per cue, and delays the speech 0.14s so the tone
        // lands first, on a timeline that already packs five cues into the last five seconds of
        // every interval. `AVSpeechSynthesizer` queues serially, so the extra audio pushes later
        // cues late. The voice carries the whole meaning; the tone only added queue pressure.
        // Still user-switchable. See LEARNINGS.md → Audio cues.
        XCTAssertEqual(defaults.cueMode, .voice, "Voice only by default; see §9.2 deviation")
        // Spec §6's 3 seconds, restored in the 2026-09-29 clean-out. It was 0 while a run started as
        // two taps, the Watch then the phone, where a countdown added exactly the offset the start
        // was trying to close. Start now launches the Watch itself, and the Watch usually connects
        // within the countdown. Existing plans keep their own value.
        XCTAssertEqual(defaults.countdownSeconds, 3, "Spec §6 default")
        XCTAssertEqual(defaults.cooldownMode, .open, "Spec §6 default")
        // Deliberate deviation from spec §11.3, which defaults this off. Turned on after a real
        // run where unannounced transitions were repeatedly surprising. Still user-switchable.
        XCTAssertTrue(defaults.transitionCountdown,
                      "Transitions are counted down by default; see §11.3 deviation")
        XCTAssertTrue(defaults.fiveSecondWarning,
                      "The upcoming phase is announced five seconds ahead by default")
        XCTAssertEqual(defaults.unloggedPromptDays, 7, "Spec §21 default")
        XCTAssertFalse(defaults.includeWalkingWorkouts,
                       "Walking workouts are excluded unless explicitly turned on")
        XCTAssertTrue(defaults.configurationIssues.isEmpty)
    }

    func testIncludeWalkingPersists() {
        let first = LoggerDefaults(defaults: suite)
        first.includeWalkingWorkouts = true

        XCTAssertTrue(LoggerDefaults(defaults: suite).includeWalkingWorkouts)
    }

    /// The two Watch cue sources were removed in the 2026-09-29 clean-out. A phone that had one
    /// selected must not be quietly moved to the iPhone engine — its transition cues would start
    /// playing mid-run with nothing on screen saying why. It is reported, and the phone plays cues.
    func testRetiredWatchCueSourcesAreReportedAndFallBackToThePhone() {
        for retired in ["apple_workout", "watch_companion"] {
            suite.set(retired, forKey: "cue.source")
            let defaults = LoggerDefaults(defaults: suite)

            XCTAssertEqual(defaults.cueSource, .iphoneAudioEngine, retired)
            XCTAssertTrue(defaults.configurationIssues.contains { $0.contains(retired) },
                          "\(retired) must be reported, got \(defaults.configurationIssues)")
        }
    }

    /// Settings' "Play cues" toggle is `playsCues`, a view onto `cueSource` rather than a second
    /// stored setting, so the two can never disagree — and the export's `cue_source` keeps its
    /// existing values.
    func testPlaysCuesIsTheCueSourceAndPersists() {
        let defaults = LoggerDefaults(defaults: suite)
        XCTAssertTrue(defaults.playsCues, "Cues are on by default")

        defaults.playsCues = false
        XCTAssertEqual(defaults.cueSource, CueSource.none)
        XCTAssertEqual(suite.string(forKey: "cue.source"), "none")
        XCTAssertFalse(LoggerDefaults(defaults: suite).playsCues, "Off must survive a relaunch")

        defaults.playsCues = true
        XCTAssertEqual(defaults.cueSource, .iphoneAudioEngine)
        XCTAssertEqual(suite.string(forKey: "cue.source"), "iphone_audio_engine")
    }

    /// An unrecognized stored value must be reported, not silently swapped for a default.
    func testUnknownStoredEnumIsReported() {
        suite.set("telepathy", forKey: "cue.source")
        let defaults = LoggerDefaults(defaults: suite)

        XCTAssertEqual(defaults.cueSource, .iphoneAudioEngine)
        XCTAssertTrue(defaults.configurationIssues.contains { $0.contains("telepathy") },
                      "The unreadable value must be surfaced, got \(defaults.configurationIssues)")
    }

    func testInvalidCountdownIsReported() {
        suite.set(7, forKey: "cue.countdownSeconds")
        let defaults = LoggerDefaults(defaults: suite)

        // Falls back to the documented default — 3 seconds since the 2026-09-29 clean-out — and
        // says so rather than silently substituting it.
        XCTAssertEqual(defaults.countdownSeconds, 3)
        XCTAssertFalse(defaults.configurationIssues.isEmpty)
    }

    // MARK: - The half-typed note

    /// A note being thumbed in during a 60-second walk break has to survive the phone going into a
    /// pocket. Locking the screen alone would not lose it — SwiftUI keeps the sheet's state — but
    /// the app being killed would, and this is the app's own writing surface for data the user
    /// cannot reconstruct later. The committed note lives in SwiftData; this is only the draft.
    func testAHalfTypedNoteSurvivesRelaunch() {
        let executionID = UUID()
        let first = LoggerDefaults(defaults: suite)

        first.setNoteDraft("left calf tigh", forExecution: executionID)

        XCTAssertEqual(LoggerDefaults(defaults: suite).noteDraft(forExecution: executionID),
                       "left calf tigh")
    }

    /// A draft belongs to the workout it was typed in. Without this an abandoned draft would
    /// reappear inside an unrelated run days later, reading as that run's observation — a quiet
    /// way to put words in the user's mouth.
    func testADraftFromAnotherWorkoutIsNotOffered() {
        let defaults = LoggerDefaults(defaults: suite)
        defaults.setNoteDraft("from last week", forExecution: UUID())

        XCTAssertEqual(defaults.noteDraft(forExecution: UUID()), "")
    }

    func testClearingADraftRemovesIt() {
        let executionID = UUID()
        let defaults = LoggerDefaults(defaults: suite)
        defaults.setNoteDraft("already committed to the store", forExecution: executionID)

        defaults.clearNoteDraft(forExecution: executionID)

        XCTAssertEqual(defaults.noteDraft(forExecution: executionID), "")
    }

    /// Clearing is scoped to one workout: finishing a note in today's run must not discard a draft
    /// belonging to a session that is somehow still open.
    func testClearingOneWorkoutsDraftLeavesAnothersAlone() {
        let mine = UUID()
        let other = UUID()
        let defaults = LoggerDefaults(defaults: suite)
        defaults.setNoteDraft("someone else's writing", forExecution: other)

        defaults.clearNoteDraft(forExecution: mine)

        XCTAssertEqual(defaults.noteDraft(forExecution: other), "someone else's writing")
    }

    func testSettingsRoundTrip() {
        let first = LoggerDefaults(defaults: suite)
        first.cueMode = .beeps
        first.countdownSeconds = 10
        first.unloggedPromptDays = 14

        let second = LoggerDefaults(defaults: suite)
        XCTAssertEqual(second.cueMode, .beeps)
        XCTAssertEqual(second.countdownSeconds, 10)
        XCTAssertEqual(second.unloggedPromptDays, 14)
        XCTAssertTrue(second.configurationIssues.isEmpty)
    }

    /// Cue volume 0 is retired. It was silent but still *started* a cue — which ducked other audio
    /// and then had to un-duck it — so "mute" was a half-state that did the work inaudibly rather
    /// than skipping it. Silence is `CueSource.none` now, and the slider floor is 10%.
    ///
    /// A value stored under the old rule is raised rather than kept, so it is **reported**: a user
    /// who had muted cues would otherwise find out mid-run.
    func testStoredCueVolumeBelowTheFloorIsRaisedAndReported() {
        suite.set(0.0, forKey: "cue.volume")
        let defaults = LoggerDefaults(defaults: suite)

        XCTAssertEqual(defaults.cueVolume, LoggerDefaults.minimumCueVolume, accuracy: 0.0001)
        XCTAssertTrue(defaults.configurationIssues.contains { $0.contains("Cue volume") },
                      "Raising a muted setting must be surfaced, got \(defaults.configurationIssues)")
        XCTAssertTrue(defaults.configurationIssues.contains { $0.contains("Play cues") },
                      "The report must point at the control that actually silences cues")
    }

    func testStoredCueVolumeInRangeIsKeptAndNotReported() {
        suite.set(0.5, forKey: "cue.volume")
        let defaults = LoggerDefaults(defaults: suite)

        XCTAssertEqual(defaults.cueVolume, 0.5, accuracy: 0.0001)
        XCTAssertTrue(defaults.configurationIssues.isEmpty)
    }

    func testCueVolumeDefaultsToFullWhenUnset() {
        let defaults = LoggerDefaults(defaults: suite)

        XCTAssertEqual(defaults.cueVolume, 1.0, accuracy: 0.0001)
        XCTAssertTrue(defaults.configurationIssues.isEmpty)
    }

    func testIntervalAudioSettingsMirrorConfiguration() {
        let defaults = LoggerDefaults(defaults: suite)
        defaults.cueSource = .none
        defaults.cueMode = .voice

        let json = defaults.intervalAudioSettings.json
        XCTAssertEqual(json["cue_source"] as? String, "none")
        XCTAssertEqual(json["cue_mode"] as? String, "voice")
    }
}
