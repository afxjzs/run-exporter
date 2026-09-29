import XCTest
import SwiftData
@testable import RunExporter

/// `RunLoggerModel` against a real in-memory SwiftData store.
///
/// This harness exists because its absence is what let the central defect ship. The interval-to-
/// workout join was covered by the type checker and by reasoning, and the pure matcher logic was
/// unit-tested and correct — while in production 98 interval records reached no workout at all,
/// silently, because nothing tested the *wiring* between the matcher, the store and the save.
///
/// So the tests that matter most here are not about the matcher. They are about whether a save
/// actually stamps a row.
@MainActor
final class RunLoggerModelTests: XCTestCase {

    private var store: LoggerStore!
    private var defaults: LoggerDefaults!
    private var model: RunLoggerModel!

    /// Fixed so nothing depends on the clock. The workout below starts one second after the timer,
    /// which is what the owner's one verified real match actually measured.
    private let base = Date(timeIntervalSince1970: 1_775_000_000)

    override func setUp() {
        super.setUp()
        store = LoggerStore(inMemory: true)
        XCTAssertNil(store.containerError, "in-memory store failed to open")
        // A throwaway suite per test: LoggerDefaults reads real UserDefaults otherwise, and a test
        // that mutates the developer's own settings is its own kind of silent damage.
        defaults = LoggerDefaults(defaults: UserDefaults(suiteName: "RunLoggerModelTests")!)
        model = RunLoggerModel(store: store, defaults: defaults)
    }

    override func tearDown() {
        model = nil
        defaults = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func workout(startOffset: TimeInterval = 0,
                         duration: TimeInterval = 1_500,
                         uuid: UUID = UUID()) -> HealthKitManager.WorkoutSummary {
        let start = base.addingTimeInterval(startOffset)
        return HealthKitManager.WorkoutSummary(
            uuid: uuid,
            activityType: .running,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            duration: duration,
            distanceMiles: 2.0,
            averageHeartRate: 150,
            peakHeartRate: 170,
            temperatureFahrenheit: 72,
            humidityPercent: 59,
            sourceName: "My Watch",
            hasWeatherMetadata: true,
            isIndoor: false,
            metadataKeys: [],
            isReclassifiedAsRunning: false,
            executionID: nil)
    }

    /// Inserts an execution, and `intervalCount` interval records belonging to it.
    @discardableResult
    private func insertExecution(timerStartOffset: TimeInterval,
                                 timerEndOffset: TimeInterval?,
                                 status: ExecutionStatus = .completed,
                                 intervalCount: Int = 12) -> PendingWorkoutExecution {
        let context = store.context!
        let startedAt = base.addingTimeInterval(timerStartOffset)

        let execution = PendingWorkoutExecution(
            plannedWorkoutID: UUID(),
            plannedWorkoutName: "4/1 × 5",
            expectedActivityType: .running,
            expectedDurationSeconds: 1_500,
            runIntervalSeconds: 240,
            walkIntervalSeconds: 60,
            plannedRepetitions: 5,
            status: status,
            createdAt: startedAt)
        execution.timerStartedAt = startedAt
        execution.timerEndedAt = timerEndOffset.map { base.addingTimeInterval($0) }
        context.insert(execution)

        for index in 0..<intervalCount {
            let log = WorkoutIntervalLog(executionID: execution.id,
                                         sequenceIndex: index,
                                         phaseType: index.isMultiple(of: 2) ? .run : .walk,
                                         repetitionNumber: index / 2 + 1,
                                         plannedDurationSeconds: 240,
                                         actualDurationSeconds: 240,
                                         startDate: startedAt.addingTimeInterval(Double(index) * 240),
                                         endDate: startedAt.addingTimeInterval(Double(index + 1) * 240))
            context.insert(log)
        }

        XCTAssertNil(store.save(), "fixture insert failed")
        return execution
    }

    private func completeDraft() -> RunLogDraft {
        var draft = RunLogDraft(shoeID: nil)
        draft.effortRPE = 6
        draft.personalHeatRating = 5
        return draft
    }

    private func intervals(forExecution id: UUID) -> [WorkoutIntervalLog] {
        let descriptor = FetchDescriptor<WorkoutIntervalLog>(
            predicate: #Predicate { $0.executionID == id })
        guard case .success(let logs) = store.fetch(descriptor) else {
            XCTFail("could not read interval logs")
            return []
        }
        return logs
    }

    // MARK: - The join that was silently broken

    /// The test whose absence let the original defect ship: logging a run **after** it finished must
    /// stamp its interval records with the workout.
    func testLoggingAfterTheRunStampsTheIntervalsWithTheWorkout() {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        let run = workout()

        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        let stamped = intervals(forExecution: execution.id)
        XCTAssertEqual(stamped.count, 12)
        XCTAssertEqual(Set(stamped.compactMap(\.healthKitWorkoutUUID)), [run.uuid],
                       "every interval record should now name the workout")
        XCTAssertEqual(execution.matchedHealthKitWorkoutUUID, run.uuid)
        XCTAssertEqual(execution.statusValue, .matched)
    }

    /// The failure the export verifier detects, expressed as a unit test: a timer that ran nowhere
    /// near the workout must not have its intervals claimed by it.
    func testATimerFarFromTheWorkoutLeavesItsIntervalsAlone() {
        let execution = insertExecution(timerStartOffset: -3_600, timerEndOffset: -2_000)

        XCTAssertNil(model.save(draft: completeDraft(), for: workout()))

        XCTAssertTrue(intervals(forExecution: execution.id).allSatisfy {
            $0.healthKitWorkoutUUID == nil
        })
        XCTAssertNil(execution.matchedHealthKitWorkoutUUID)
    }

    func testALogWithNoTimerSessionAtAllSavesWithoutComplaint() {
        XCTAssertNil(model.save(draft: completeDraft(), for: workout()))
        // The ordinary case — most workouts were never planned in this app — so it must not report
        // anything. A spurious error here would train the user to ignore real ones.
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Backfilling the plan shape a blank form would otherwise erase

    /// A draft carrying no plan shape must not write blanks over what the timer session knows.
    ///
    /// This is how an earlier loss happened: the run was logged again from a blank form, and
    /// `plannedWorkoutID` plus the whole interval shape went to nil — while the execution that
    /// produced the run still held every one of those values.
    func testSavingWithNoPlanShapeBackfillsItFromTheTimerSession() {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        execution.completedRepetitions = 4
        XCTAssertNil(store.save())
        let run = workout()

        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        let log = model.runLog(forWorkout: run.uuid)
        XCTAssertEqual(log?.plannedWorkoutID, execution.plannedWorkoutID)
        XCTAssertEqual(log?.runIntervalSeconds, 240)
        XCTAssertEqual(log?.walkIntervalSeconds, 60)
        XCTAssertEqual(log?.plannedRepetitions, 5)
        XCTAssertEqual(log?.completedRepetitions, 4)
    }

    /// The two rows still sitting in the owner's export: a log that already exists with its plan
    /// linkage blanked. Opening it in History and saving must repair it, which is the only recovery
    /// route — there is deliberately no migration.
    func testEditingALogWhoseShapeWasAlreadyBlankedRepairsIt() throws {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        let run = workout()
        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        // Blank it exactly the way the old blank-form save did.
        let damaged = try XCTUnwrap(model.runLog(forWorkout: run.uuid))
        damaged.plannedWorkoutID = nil
        damaged.runIntervalSeconds = nil
        damaged.walkIntervalSeconds = nil
        damaged.plannedRepetitions = nil
        XCTAssertNil(store.save())

        // "Open the run in History, tap Edit log, Save" — the draft is rebuilt from the damaged log,
        // so it carries the blanks with it.
        XCTAssertNil(model.save(draft: RunLogDraft(log: damaged), for: run))

        let repaired = model.runLog(forWorkout: run.uuid)
        XCTAssertEqual(repaired?.plannedWorkoutID, execution.plannedWorkoutID)
        XCTAssertEqual(repaired?.runIntervalSeconds, 240)
        XCTAssertEqual(repaired?.walkIntervalSeconds, 60)
        XCTAssertEqual(repaired?.plannedRepetitions, 5)
    }

    /// Backfill must not invent an interval shape for a run that had several.
    ///
    /// A multi-block session records `0` for its run and walk lengths precisely because no single
    /// value is true of it. Copying those into the log would write "ran 0 seconds" into a column
    /// meant to describe the run — a wrong number where a blank belongs. The rounds are well
    /// defined and still fill, and the plan linkage still fills, which is what the backfill exists
    /// for in the first place.
    func testBackfillWritesNoIntervalShapeForAMultiBlockSession() {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        execution.runIntervalSeconds = 0
        execution.walkIntervalSeconds = 0
        execution.plannedRepetitions = 4
        execution.blockShape = "300/60x1|480/60x2|300/60x1"
        execution.completedRepetitions = 4
        XCTAssertNil(store.save())
        let run = workout()

        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        let log = model.runLog(forWorkout: run.uuid)
        XCTAssertNil(log?.runIntervalSeconds, "a blank is unknown; a zero is a claim")
        XCTAssertNil(log?.walkIntervalSeconds)
        XCTAssertEqual(log?.plannedRepetitions, 4)
        XCTAssertEqual(log?.plannedWorkoutID, execution.plannedWorkoutID)
        XCTAssertEqual(log?.completedRepetitions, 4)
    }

    /// Backfill fills gaps; it never overrules the user. A draft that states its own shape wins,
    /// including where it disagrees with the timer session.
    func testADraftThatCarriesItsOwnPlanShapeIsNotOverwritten() {
        insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)   // 240 / 60 / 5
        let chosenPlan = UUID()
        var draft = completeDraft()
        draft.plannedWorkoutID = chosenPlan
        draft.runIntervalSeconds = 300
        draft.walkIntervalSeconds = 90
        draft.plannedRepetitions = 3
        draft.completedRepetitions = 2
        let run = workout()

        XCTAssertNil(model.save(draft: draft, for: run))

        let log = model.runLog(forWorkout: run.uuid)
        XCTAssertEqual(log?.plannedWorkoutID, chosenPlan)
        XCTAssertEqual(log?.runIntervalSeconds, 300)
        XCTAssertEqual(log?.walkIntervalSeconds, 90)
        XCTAssertEqual(log?.plannedRepetitions, 3)
        XCTAssertEqual(log?.completedRepetitions, 2)
    }

    /// No timer session means no plan shape. Filling one in from a nearby run would be inventing
    /// data, which is worse than leaving the column blank.
    func testAWorkoutWithNoTimerSessionGetsNoInventedPlanShape() {
        let run = workout()

        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        let log = model.runLog(forWorkout: run.uuid)
        XCTAssertNotNil(log, "precondition: the log itself saved")
        XCTAssertNil(log?.plannedWorkoutID)
        XCTAssertNil(log?.runIntervalSeconds)
        XCTAssertNil(log?.plannedRepetitions)
    }

    // MARK: - Refusing to guess, and then offering the choice

    func testTwoOverlappingTimersLeaveTheIntervalsUnstampedAndSayWhy() {
        let first = insertExecution(timerStartOffset: -30, timerEndOffset: 1_500, intervalCount: 6)
        let second = insertExecution(timerStartOffset: 30, timerEndOffset: 1_500, intervalCount: 6)
        let run = workout()

        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        XCTAssertTrue(intervals(forExecution: first.id).allSatisfy { $0.healthKitWorkoutUUID == nil })
        XCTAssertTrue(intervals(forExecution: second.id).allSatisfy { $0.healthKitWorkoutUUID == nil })

        let message = model.errorMessage
        XCTAssertNotNil(message, "an unlinked run must not be silent")
        XCTAssertTrue(message?.contains("History") == true,
                      "the notice should point at where the choice can be made: \(message ?? "nil")")
    }

    func testAnAmbiguousRunOffersBothTimerSessionsAsChoices() {
        let first = insertExecution(timerStartOffset: -30, timerEndOffset: 1_500, intervalCount: 6)
        let second = insertExecution(timerStartOffset: 30, timerEndOffset: 1_500, intervalCount: 4)
        let run = workout()

        let choices = model.executionChoices(for: run)

        XCTAssertEqual(Set(choices.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(choices.map(\.startedAt), choices.map(\.startedAt).sorted(),
                       "choices should read in the order the timers ran")
        XCTAssertEqual(choices.first(where: { $0.id == second.id })?.intervalCount, 4,
                       "each choice should say how many intervals it would attach")
    }

    func testAConfidentMatchOffersNoChoiceAtAll() {
        insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        // An empty list must render as no picker: offering a choice that does not exist is its own
        // kind of lie.
        XCTAssertTrue(model.executionChoices(for: workout()).isEmpty)
    }

    func testChoosingATimerSessionStampsItsIntervals() {
        let chosen = insertExecution(timerStartOffset: -30, timerEndOffset: 1_500, intervalCount: 6)
        let other = insertExecution(timerStartOffset: 30, timerEndOffset: 1_500, intervalCount: 6)
        let run = workout()

        model.linkIntervals(ofExecution: chosen.id, to: run)

        XCTAssertEqual(Set(intervals(forExecution: chosen.id).compactMap(\.healthKitWorkoutUUID)),
                       [run.uuid])
        XCTAssertTrue(intervals(forExecution: other.id).allSatisfy { $0.healthKitWorkoutUUID == nil },
                      "the session the user did not choose must be left untouched")
        XCTAssertEqual(chosen.statusValue, .matched)
    }

    // MARK: - Retiring abandoned timers

    func testAnAbandonedTimerIsRetiredAndReported() {
        let abandoned = insertExecution(timerStartOffset: -60 * 60 * 24,
                                        timerEndOffset: nil,
                                        status: .started,
                                        intervalCount: 6)

        model.expireAbandonedExecutions(now: base)

        XCTAssertEqual(abandoned.statusValue, .expired)
        XCTAssertNotNil(model.maintenanceNotice, "retiring a timer must not be silent")
        XCTAssertNil(model.errorMessage, "retirement is housekeeping, not a failure")
    }

    /// The reason retirement sets a status instead of deleting: there is no SwiftData relationship
    /// between an execution and its interval records, so a delete would strand them.
    func testRetirementKeepsEveryIntervalRecord() {
        let abandoned = insertExecution(timerStartOffset: -60 * 60 * 24,
                                        timerEndOffset: nil,
                                        status: .started,
                                        intervalCount: 6)

        model.expireAbandonedExecutions(now: base)

        XCTAssertEqual(intervals(forExecution: abandoned.id).count, 6)
    }

    func testARetiredTimerNoLongerClaimsARunItOverlapped() {
        // The whole point: three abandoned timers near a real run are what made one of the owner's
        // workouts permanently ambiguous.
        let abandoned = insertExecution(timerStartOffset: -60 * 60 * 24,
                                        timerEndOffset: nil,
                                        status: .started,
                                        intervalCount: 6)
        model.expireAbandonedExecutions(now: base)

        let laterRun = workout(startOffset: -60 * 60 * 24)
        XCTAssertNil(model.save(draft: completeDraft(), for: laterRun))

        XCTAssertTrue(intervals(forExecution: abandoned.id).allSatisfy {
            $0.healthKitWorkoutUUID == nil
        })
    }

    func testNothingIsRetiredWhenNothingIsAbandoned() {
        insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)

        model.expireAbandonedExecutions(now: base)

        // Silence is correct here, and is the case that would make the notice untrustworthy if it
        // fired anyway.
        XCTAssertNil(model.maintenanceNotice)
    }

    /// Protects the feature verified on real hardware: a run logged three days later still resolves.
    func testAnOldCompletedTimerIsNeverRetiredAndStillLinks() {
        let old = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540, status: .completed)

        model.expireAbandonedExecutions(now: base.addingTimeInterval(60 * 60 * 24 * 3))

        XCTAssertEqual(old.statusValue, .completed)
        XCTAssertNil(model.save(draft: completeDraft(), for: workout()))
        XCTAssertEqual(Set(intervals(forExecution: old.id).compactMap(\.healthKitWorkoutUUID)).count, 1)
    }

    // MARK: - The observation signal the History screen depends on

    func testStoreRevisionAdvancesAfterASaveSoFetchedScreensRedraw() {
        insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        let before = model.storeRevision

        XCTAssertNil(model.save(draft: completeDraft(), for: workout()))

        // `@Observable` cannot see a SwiftData fetch, so this counter is the only reason a screen
        // built from `runLog(forWorkout:)` re-renders after a save. A save that worked once
        // displayed as one that had not happened.
        XCTAssertGreaterThan(model.storeRevision, before)
    }

    func testAnIncompleteDraftIsRefusedWithAReason() {
        var draft = RunLogDraft(shoeID: nil)
        draft.personalHeatRating = 5   // no RPE

        let error = model.save(draft: draft, for: workout())

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.lowercased().contains("rpe") == true, error ?? "nil")
    }

    // MARK: - Mid-workout logs finding their way to the workout

    /// Writes a cooldown log for `execution` — the state the app is in between "I logged how it
    /// felt" and "the Watch's workout reached HealthKit".
    @discardableResult
    private func logDuringCooldown(_ execution: PendingWorkoutExecution,
                                   notes: String) -> RunLogDraft {
        var draft = completeDraft()
        draft.notes = notes
        draft.executionID = execution.id
        XCTAssertNil(model.saveDuringWorkout(draft: draft,
                                             executionID: execution.id,
                                             startedAt: base,
                                             activityType: .running),
                     "fixture: the cooldown log itself must save")
        return draft
    }

    /// Regression test for silent data loss.
    ///
    /// A log written during cooldown has no `healthKitWorkoutUUID` — the workout did not exist yet —
    /// so `runLog(forWorkout:)` cannot see it however complete it is. `RunLogFormView` consulted
    /// only that lookup, so the "Needs a log" prompt opened a **blank** form on top of writing the
    /// user had already done, and saving it wrote those notes back as nil. No error, no warning.
    /// This asserts the seam the form now depends on.
    func testACooldownLogIsReachableFromTheWorkoutAlone() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "left calf tight from mile 2")
        let arrived = workout(startOffset: 1)

        XCTAssertNil(model.runLog(forWorkout: arrived.uuid),
                     "precondition: the workout-keyed lookup is blind to it, which is the trap")

        let found = model.pendingLog(forWorkout: arrived)

        XCTAssertNotNil(found, "a form that cannot find this opens blank over the user's own notes")
        XCTAssertEqual(found?.notes, "left calf tight from mile 2")
    }

    /// Regression test.
    ///
    /// The join used to be attempted exactly once, from `ActiveWorkoutView` at the instant the timer
    /// stopped, and only on its `.matched` branch. HealthKit routinely does not have the Watch's
    /// workout yet at that moment, so the log was orphaned permanently. Retrying on refresh is what
    /// makes it eventually consistent.
    func testReconciliationJoinsAnOrphanedCooldownLogToItsWorkout() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "brain dump: hot, legs fine")
        let arrived = workout(startOffset: 1)

        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 1)

        let joined = model.runLog(forWorkout: arrived.uuid)
        XCTAssertNotNil(joined, "the log must now be reachable from the workout")
        XCTAssertEqual(joined?.notes, "brain dump: hot, legs fine",
                       "reconciliation must join the existing log, never replace it")
        XCTAssertEqual(joined?.executionID, execution.id)
    }

    /// Reconciliation must not invent a join. A timer run on the phone with no Watch produces a log
    /// with no workout to attach to, and that is a supported way to use the app — not a fault, and
    /// not something to attach to whatever workout happens to be nearby.
    func testReconciliationLeavesALogAloneWhenThereIsNoWorkoutForIt() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "phone-only run")

        XCTAssertEqual(model.reconcilePendingCaptures(among: []), 0)

        let stranded = model.pendingLog(forExecution: execution.id)
        XCTAssertNotNil(stranded, "the log must survive untouched")
        XCTAssertEqual(stranded?.notes, "phone-only run")
        XCTAssertNil(stranded?.healthKitWorkoutUUID)
    }

    /// Regression test for the end-of-workout flow.
    ///
    /// A run logged during cooldown has no workout UUID and often no HealthKit workout at all — the
    /// run is still in progress. `ActiveWorkoutView` used to ask "is this workout in the unlogged
    /// queue?", which answers no for a logged run and no for an unsynced one, so it showed "No
    /// Apple Watch workout found" either way and offered to log it again. The question it asks now
    /// is this one, and it must answer yes from the execution alone.
    func testALogWrittenDuringCooldownIsFoundBeforeTheWorkoutExists() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "felt strong on rep 4")

        // Nothing has been matched, and HealthKit has nothing to offer — the state at the moment
        // the timer stops.
        XCTAssertTrue(model.unloggedWorkouts.isEmpty, "precondition: no workout has arrived")

        let found = model.existingLog(forExecution: execution.id)

        XCTAssertNotNil(found, "the run is logged; the end-of-workout prompt must not deny it")
        XCTAssertEqual(found?.notes, "felt strong on rep 4")
        XCTAssertNil(found?.healthKitWorkoutUUID, "still pending, and still counts as logged")
    }

    /// The same question must keep answering yes after reconciliation joins the log to its workout,
    /// or ending a run would re-offer to log it the moment the Watch finally synced.
    func testAJoinedLogIsStillFoundFromItsExecution() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "steady")
        let arrived = workout(startOffset: 17)   // a realistic offset between timer and workout

        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 1)

        let found = model.existingLog(forExecution: execution.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.healthKitWorkoutUUID, arrived.uuid)
    }

    /// An execution nobody logged must answer no, or the prompt would never appear at all.
    func testAnUnloggedExecutionHasNoExistingLog() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        XCTAssertNil(model.existingLog(forExecution: execution.id))
    }

    // MARK: - Notes captured during the workout

    /// The capture this feature exists for: a thought during walk 3, on disk the instant it is
    /// entered rather than held until the interval ends.
    ///
    /// `WorkoutIntervalLog` cannot own this, despite being the record that describes walk 3. Its
    /// rows are written from `onIntervalCompleted`, at the phase *boundary* — so while walk 3 is
    /// happening there is no row for walk 3 to write to, and storing the note there would mean
    /// holding the user's writing in memory for up to a whole interval before it reached disk.
    func testANoteTakenDuringAWalkIsSavedWhereItCanBeReadBack() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        let error = model.saveNote("left calf tight since rep 2",
                                   executionID: execution.id,
                                   phase: .walk,
                                   repetition: 3,
                                   secondsIntoWorkout: 742,
                                   at: base.addingTimeInterval(742))

        XCTAssertNil(error)
        let notes = model.notes(forExecution: execution.id)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "left calf tight since rep 2")
    }

    /// A note that is only whitespace is not a note. Refused with a reason rather than written as
    /// a blank row: an empty entry in the export is indistinguishable from a capture that failed.
    func testABlankNoteIsRefusedWithAReasonRatherThanSavedEmpty() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        let error = model.saveNote("   \n  ",
                                   executionID: execution.id,
                                   phase: .walk,
                                   repetition: 2,
                                   secondsIntoWorkout: 300,
                                   at: base.addingTimeInterval(300))

        XCTAssertNotNil(error, "refusing to save must not be silent")
        XCTAssertTrue(model.notes(forExecution: execution.id).isEmpty,
                      "nothing should have been written")
    }

    /// Surrounding whitespace is trimmed, but the note's own line breaks are kept — a brain dump
    /// typed in a walk break is often two half-sentences, and reflowing it would edit the user's
    /// words.
    func testANoteIsTrimmedAtTheEndsAndKeptIntactInTheMiddle() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        XCTAssertNil(model.saveNote("  calf tight\nright hip fine  ",
                                    executionID: execution.id,
                                    phase: .walk,
                                    repetition: 2,
                                    secondsIntoWorkout: 300,
                                    at: base.addingTimeInterval(300)))

        XCTAssertEqual(model.notes(forExecution: execution.id).first?.text,
                       "calf tight\nright hip fine")
    }

    /// Writes one mid-workout note, failing the test if the fixture itself cannot save.
    private func writeNote(_ text: String,
                           on execution: PendingWorkoutExecution,
                           phase: WorkoutPhase = .walk,
                           repetition: Int? = 2,
                           seconds: Double) {
        XCTAssertNil(model.saveNote(text,
                                    executionID: execution.id,
                                    phase: phase,
                                    repetition: repetition,
                                    secondsIntoWorkout: seconds,
                                    at: base.addingTimeInterval(seconds)),
                     "fixture: the note itself must save")
    }

    /// Between finishing a run and the Watch's workout reaching HealthKit — measured in minutes on
    /// this hardware, not seconds — a note carries no workout UUID. A screen that reads only by
    /// UUID would show nothing during that window, which reads exactly like the note was lost.
    func testNotesAreFoundThroughTheExecutionBeforeTheWorkoutIsMatched() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        writeNote("felt good all the way through", on: execution, seconds: 200)
        let arrived = workout(startOffset: 1)

        let found = model.notes(forWorkout: arrived.uuid, executionID: execution.id)

        XCTAssertEqual(found.map(\.text), ["felt good all the way through"])
    }

    /// And once matched, the workout alone is enough — a screen holding only a HealthKit workout,
    /// with no idea which timer session produced it, must still find the notes.
    func testNotesAreFoundByWorkoutAloneOnceMatched() {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        writeNote("negative split, felt easy", on: execution, seconds: 200)
        let run = workout()
        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        XCTAssertEqual(model.notes(forWorkout: run.uuid, executionID: nil).map(\.text),
                       ["negative split, felt easy"])
    }

    /// The requirement in one test: *multiple* notes across one workout, not a single field
    /// overwritten each time. Oldest first, because that is the order they were thought.
    func testEveryNoteInAWorkoutSurvivesInTheOrderItWasWritten() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        writeNote("second thought", on: execution, repetition: 3, seconds: 700)
        writeNote("first thought", on: execution, repetition: 1, seconds: 200)
        writeNote("third thought", on: execution, phase: .cooldown, repetition: nil, seconds: 1_400)

        XCTAssertEqual(model.notes(forExecution: execution.id).map(\.text),
                       ["first thought", "second thought", "third thought"])
    }

    /// The context is most of the value. A note that recorded only its text would have thrown away
    /// which walk it came from, which is the fact that makes a mid-run observation worth having.
    func testANoteRecordsWhichPartOfTheWorkoutItWasWrittenIn() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        writeNote("breathing settled", on: execution, phase: .walk, repetition: 3, seconds: 742)

        let note = model.notes(forExecution: execution.id).first
        XCTAssertEqual(note?.phaseTypeValue, .walk)
        XCTAssertEqual(note?.repetitionNumber, 3)
        XCTAssertEqual(note?.secondsIntoWorkout, 742)
        XCTAssertEqual(note?.createdAt, base.addingTimeInterval(742))
        XCTAssertNil(note?.healthKitWorkoutUUID,
                     "the Watch's workout does not exist while the note is being written")
    }

    /// A cooldown note carries no repetition, and must not invent one. Nil means "this phase has no
    /// repetition"; a 0 would read as a real round number.
    func testACooldownNoteHasNoRepetitionRatherThanZero() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        writeNote("legs fine, hips tight", on: execution,
                  phase: .cooldown, repetition: nil, seconds: 1_450)

        XCTAssertNil(model.notes(forExecution: execution.id).first?.repetitionNumber)
    }

    /// Same reason the run-log save bumps it: a screen built from `notes(forExecution:)` is a
    /// SwiftData fetch, which Observation cannot see. Without this the note count on the workout
    /// screen would not move after a save, and a save that worked would display as one that had not.
    func testSavingANoteAdvancesStoreRevisionSoTheScreenRedraws() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        let before = model.storeRevision

        writeNote("anything", on: execution, seconds: 100)

        XCTAssertGreaterThan(model.storeRevision, before)
    }

    // MARK: - Notes finding their way to the workout

    /// The defect class this repo has already shipped once, wearing new clothes: records reaching
    /// no workout, silently. A note that never joins its run is invisible to every screen that
    /// reads by workout, and lands in the export with a blank workout column.
    func testLoggingAfterTheRunStampsTheNotesWithTheWorkout() {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        XCTAssertNil(model.saveNote("hip flexor grumbling",
                                    executionID: execution.id,
                                    phase: .walk,
                                    repetition: 2,
                                    secondsIntoWorkout: 400,
                                    at: base.addingTimeInterval(400)))
        let run = workout()

        XCTAssertNil(model.save(draft: completeDraft(), for: run))

        XCTAssertEqual(model.notes(forExecution: execution.id).compactMap(\.healthKitWorkoutUUID),
                       [run.uuid])
    }

    /// The join has to be eventually consistent for notes too. The Watch's workout does not exist
    /// while the note is being written — that is the whole premise of writing it mid-run — so the
    /// sweep that repairs orphaned run logs must repair these as well.
    func testReconciliationStampsMidWorkoutNotesWithTheWorkout() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "cooldown log")
        XCTAssertNil(model.saveNote("legs heavy from rep 3",
                                    executionID: execution.id,
                                    phase: .walk,
                                    repetition: 3,
                                    secondsIntoWorkout: 742,
                                    at: base.addingTimeInterval(742)))
        let arrived = workout(startOffset: 17)

        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 1)

        XCTAssertEqual(model.notes(forExecution: execution.id).compactMap(\.healthKitWorkoutUUID),
                       [arrived.uuid])
    }

    /// A note from a timer that ran nowhere near this workout must not be claimed by it — the same
    /// rule the interval records follow, for the same reason: wrong is permanent and invisible.
    func testATimerFarFromTheWorkoutLeavesItsNotesAlone() {
        let execution = insertExecution(timerStartOffset: -3_600, timerEndOffset: -2_000)
        XCTAssertNil(model.saveNote("a different run entirely",
                                    executionID: execution.id,
                                    phase: .run,
                                    repetition: 1,
                                    secondsIntoWorkout: 60,
                                    at: base.addingTimeInterval(-3_540)))

        XCTAssertNil(model.save(draft: completeDraft(), for: workout()))

        XCTAssertTrue(model.notes(forExecution: execution.id).allSatisfy {
            $0.healthKitWorkoutUUID == nil
        })
    }

    /// Resolving an ambiguous run by hand has to carry the notes across too. Without this, picking
    /// the right timer session would attach its intervals and leave its notes behind — a partial
    /// link that looks complete on screen.
    func testChoosingATimerSessionStampsItsNotes() {
        let chosen = insertExecution(timerStartOffset: -30, timerEndOffset: 1_500, intervalCount: 6)
        let other = insertExecution(timerStartOffset: 30, timerEndOffset: 1_500, intervalCount: 6)
        XCTAssertNil(model.saveNote("this is the one",
                                    executionID: chosen.id,
                                    phase: .walk,
                                    repetition: 1,
                                    secondsIntoWorkout: 120,
                                    at: base.addingTimeInterval(120)))
        XCTAssertNil(model.saveNote("not this one",
                                    executionID: other.id,
                                    phase: .walk,
                                    repetition: 1,
                                    secondsIntoWorkout: 120,
                                    at: base.addingTimeInterval(180)))
        let run = workout()

        model.linkIntervals(ofExecution: chosen.id, to: run)

        XCTAssertEqual(model.notes(forExecution: chosen.id).compactMap(\.healthKitWorkoutUUID),
                       [run.uuid])
        XCTAssertTrue(model.notes(forExecution: other.id).allSatisfy {
            $0.healthKitWorkoutUUID == nil
        }, "the session the user did not choose must be left untouched")
    }

    /// The sweep must not depend on a run log existing.
    ///
    /// A note asks for no RPE, so "captured three notes, never opened the log form" is an ordinary
    /// run — and it was the one case reconciliation skipped entirely, because the sweep looked for
    /// orphaned *logs* and bailed out early when it found none. The notes then waited forever for a
    /// trigger that only fires on a code path the user never took.
    func testReconciliationJoinsNotesEvenWhenNoRunLogWasWritten() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        writeNote("never got round to logging this one", on: execution, seconds: 400)
        let arrived = workout(startOffset: 17)

        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 1)

        XCTAssertEqual(model.notes(forWorkout: arrived.uuid, executionID: nil).map(\.text),
                       ["never got round to logging this one"],
                       "the workout alone must now find them — no execution needed")
    }

    /// And having done it once, it must stop. This runs on every `refresh()`.
    func testReconcilingNotesIsIdempotent() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        writeNote("once is enough", on: execution, seconds: 400)
        let arrived = workout(startOffset: 17)

        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 1)
        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 0,
                       "nothing is waiting the second time")
        XCTAssertEqual(model.notes(forExecution: execution.id).count, 1)
    }

    /// An execution with nothing waiting must be left alone. `attach` marks the execution matched
    /// and stamps its intervals, and doing that from a background sweep for every unlogged workout
    /// would link runs the user never asked to link.
    func testReconciliationIgnoresAnExecutionWithNothingWaiting() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)

        XCTAssertEqual(model.reconcilePendingCaptures(among: [workout(startOffset: 17)]), 0)
        XCTAssertNil(execution.matchedHealthKitWorkoutUUID)
    }

    /// A run can be noted and never logged — a note asks for no RPE, and the whole premise is
    /// capture at the moment of the thought. Nothing stamps those notes with a workout, because
    /// stamping happens when a *log* is saved. So a screen holding only the workout has to be able
    /// to find the timer session on its own, or the notes are invisible everywhere in the app while
    /// sitting safely in the store — the worst of both.
    func testTheTimerSessionIsResolvableFromTheWorkoutWithNoRunLog() {
        let execution = insertExecution(timerStartOffset: -1, timerEndOffset: 1_540)
        writeNote("noted but never logged", on: execution, seconds: 300)
        let run = workout()

        let resolved = model.execution(forWorkout: run)

        XCTAssertEqual(resolved, execution.id)
        XCTAssertEqual(model.notes(forWorkout: run.uuid, executionID: resolved).map(\.text),
                       ["noted but never logged"])
    }

    /// And it must refuse when nothing plausibly matches, or one run's notes would surface under
    /// another run's screen and read as an observation about it.
    func testNoTimerSessionIsResolvedForAnUnrelatedWorkout() {
        let execution = insertExecution(timerStartOffset: -3_600, timerEndOffset: -2_000)
        writeNote("a different run entirely", on: execution, seconds: 60)

        XCTAssertNil(model.execution(forWorkout: workout()))
    }

    // MARK: - Notes reaching the export

    /// A capture that never leaves the app is a capture that did not happen — gathering the data is
    /// the stated point of the whole app.
    func testASavedNoteReachesTheExportSnapshot() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        writeNote("windy on the descent",
                  on: execution, phase: .walk, repetition: 4, seconds: 900)

        let data = LoggerExportSnapshot.make(store: store)

        XCTAssertEqual(data.notes.map(\.text), ["windy on the descent"])
        XCTAssertEqual(data.notes.first?.phaseType, "walk")
        XCTAssertEqual(data.notes.first?.repetitionNumber, 4)
        XCTAssertEqual(data.notes.first?.secondsIntoWorkout, 900)
        XCTAssertEqual(data.notes.first?.executionID, execution.id.uuidString)
    }

    /// An unmatched note is still exported, with the workout column blank. Same rule the orphaned
    /// run log follows: a record invisible to every screen is still the user's data, and the export
    /// is the only place it can be recovered from.
    func testANoteWithNoWorkoutYetIsExportedRatherThanDropped() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        writeNote("phone-only run, no Watch involved", on: execution, seconds: 120)

        let data = LoggerExportSnapshot.make(store: store)

        XCTAssertEqual(data.notes.count, 1)
        XCTAssertEqual(data.notes.first?.healthKitWorkoutUUID, "",
                       "blank means not yet matched; dropping it would lose the note")
    }

    /// Reconciling twice must not double-write or strand the log. `refresh()` runs on every
    /// appearance, so this path executes constantly.
    func testReconciliationIsIdempotent() {
        let execution = insertExecution(timerStartOffset: 0, timerEndOffset: 1_500)
        logDuringCooldown(execution, notes: "steady")
        let arrived = workout(startOffset: 1)

        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 1)
        XCTAssertEqual(model.reconcilePendingCaptures(among: [arrived]), 0,
                       "an already-joined log is no longer an orphan")

        let descriptor = FetchDescriptor<RunLog>()
        guard case .success(let logs) = store.fetch(descriptor) else {
            return XCTFail("could not read logs back")
        }
        XCTAssertEqual(logs.count, 1, "reconciliation must never produce a second log")
        XCTAssertEqual(logs.first?.notes, "steady")
    }
}
