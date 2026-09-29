import XCTest
import SwiftData
@testable import RunExporter

/// Opening a store that was written before `WorkoutNote` joined the schema.
///
/// Adding a model is the canonical additive change and SwiftData is documented to migrate it
/// automatically — but "documented to" and "measured" are different claims, and this one is made
/// against a device holding months of the owner's real logged runs. The failure mode is not subtle:
/// `LoggerStore` refuses to open, `containerError` fires, and planning, logging and shoe tracking
/// all go away for the session.
///
/// This uses a raw `ModelContainer` on a temporary file rather than `LoggerStore`, because
/// `LoggerStore` only ever opens the *current* schema and the point here is to write one schema and
/// read it back with another.
@MainActor
final class LoggerStoreMigrationTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString).store")
    }

    override func tearDown() {
        // SwiftData writes companions alongside the store; leaving them would let one test's data
        // leak into a rerun.
        for suffix in ["", "-shm", "-wal"] {
            let path = storeURL.path + suffix
            try? FileManager.default.removeItem(atPath: path)
        }
        storeURL = nil
        super.tearDown()
    }

    /// The schema exactly as it stood before this feature: `LoggerStore.models` minus `WorkoutNote`.
    private static let modelsBeforeNotes: [any PersistentModel.Type] = [
        Shoe.self,
        PlannedWorkout.self,
        PendingWorkoutExecution.self,
        RunLog.self,
        BodySignalDetail.self,
        RecoveryLog.self,
        WorkoutIntervalLog.self,
    ]

    private func container(for models: [any PersistentModel.Type]) throws -> ModelContainer {
        let schema = Schema(models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)])
    }

    func testAStoreWrittenBeforeNotesExistedStillOpensAndKeepsItsData() throws {
        let workoutUUID = UUID()
        let executionID = UUID()

        try autoreleasepool {
            let old = try container(for: Self.modelsBeforeNotes)
            let context = old.mainContext
            context.insert(RunLog(healthKitWorkoutUUID: workoutUUID,
                                  workoutStartDate: Date(timeIntervalSince1970: 1_775_000_000),
                                  workoutDistanceMiles: 2.4,
                                  workoutActivityType: "running",
                                  executionID: executionID,
                                  effortRPE: 6.5,
                                  personalHeatRating: 7,
                                  notes: "written before notes existed"))
            context.insert(WorkoutIntervalLog(executionID: executionID,
                                              sequenceIndex: 0,
                                              phaseType: .run,
                                              actualDurationSeconds: 240,
                                              startDate: Date(timeIntervalSince1970: 1_775_000_000),
                                              endDate: Date(timeIntervalSince1970: 1_775_000_240)))
            try context.save()
        }

        // Reopen with the shipping schema, which now includes WorkoutNote.
        let migrated = try container(for: LoggerStore.models)
        let context = migrated.mainContext

        let logs = try context.fetch(FetchDescriptor<RunLog>())
        XCTAssertEqual(logs.count, 1, "the existing run log must survive the added model")
        XCTAssertEqual(logs.first?.notes, "written before notes existed")
        XCTAssertEqual(logs.first?.healthKitWorkoutUUID, workoutUUID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutIntervalLog>()).count, 1)

        // The new entity is present and empty, rather than the store refusing to open.
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutNote>()).isEmpty)
    }

    /// The schema as it stands on the owner's phone today, declared properly rather than by
    /// omission.
    ///
    /// The obvious approach — list `LoggerStore.models` minus `PlannedWorkoutBlock` — does not
    /// work, and fails in the worst way: silently. `PlannedWorkout` declares
    /// `@Relationship(inverse: \PlannedWorkoutBlock.plan)`, and SwiftData resolves a relationship's
    /// destination into the schema whether or not the type was listed. The "old" schema therefore
    /// came out byte-identical to the new one, and the test wrote and read the same schema while
    /// passing. Measured: `Schema([...minus the type...]).entities` still contains
    /// `PlannedWorkoutBlock`.
    ///
    /// So the previous shape of each model is declared here instead, nested in an enum. SwiftData
    /// names an entity after its type, and a nested `PreBlocksSchema.PlannedWorkout` is still
    /// called "PlannedWorkout" — which is what makes this the same table, one version back.
    ///
    /// These are deliberately frozen copies. If a property is added to the real models, do NOT add
    /// it here: the point is what the owner's phone already wrote.
    enum PreBlocksSchema: VersionedSchema {
        static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

        static var models: [any PersistentModel.Type] {
            [PlannedWorkout.self, PendingWorkoutExecution.self]
        }

        /// `PlannedWorkout` before it could hold blocks — no `blocks` relationship.
        @Model
        final class PlannedWorkout {
            @Attribute(.unique) var id: UUID
            var name: String
            var activityType: String
            var warmupMode: String
            var warmupSeconds: Int?
            var runIntervalSeconds: Int
            var walkIntervalSeconds: Int
            var plannedRepetitions: Int
            var includesFinalWalk: Bool
            var cooldownMode: String
            var cooldownSeconds: Int?
            var countdownSeconds: Int
            var createdAt: Date
            var updatedAt: Date
            var isNextWorkout: Bool
            var workoutKitIdentifier: String?

            init(id: UUID, name: String,
                 runIntervalSeconds: Int, walkIntervalSeconds: Int, plannedRepetitions: Int) {
                self.id = id
                self.name = name
                self.activityType = "running"
                self.warmupMode = "none"
                self.runIntervalSeconds = runIntervalSeconds
                self.walkIntervalSeconds = walkIntervalSeconds
                self.plannedRepetitions = plannedRepetitions
                self.includesFinalWalk = false
                self.cooldownMode = "open"
                self.countdownSeconds = 0
                self.createdAt = Date()
                self.updatedAt = Date()
                self.isNextWorkout = false
            }
        }

        /// `PendingWorkoutExecution` before it recorded a shape — no `blockShape`.
        @Model
        final class PendingWorkoutExecution {
            @Attribute(.unique) var id: UUID
            var plannedWorkoutID: UUID
            var expectedActivityType: String
            var createdAt: Date
            var expectedDurationSeconds: Int
            var status: String
            var matchedHealthKitWorkoutUUID: UUID?
            var plannedWorkoutName: String
            var runIntervalSeconds: Int
            var walkIntervalSeconds: Int
            var plannedRepetitions: Int
            var timerStartedAt: Date?
            var timerEndedAt: Date?
            var completedRepetitions: Int?
            var updatedAt: Date

            init(plannedWorkoutID: UUID, plannedWorkoutName: String,
                 runIntervalSeconds: Int, walkIntervalSeconds: Int, plannedRepetitions: Int) {
                self.id = UUID()
                self.plannedWorkoutID = plannedWorkoutID
                self.plannedWorkoutName = plannedWorkoutName
                self.expectedActivityType = "running"
                self.createdAt = Date()
                self.expectedDurationSeconds = 1_500
                self.status = "completed"
                self.runIntervalSeconds = runIntervalSeconds
                self.walkIntervalSeconds = walkIntervalSeconds
                self.plannedRepetitions = plannedRepetitions
                self.updatedAt = Date()
            }
        }
    }

    /// Opening a store written before plans could hold blocks.
    ///
    /// This is the migration the owner's phone will actually perform, holding months of real runs:
    /// neither `PlannedWorkoutBlock` nor the `blockShape` column has ever been installed on it. If
    /// this fails on device, `LoggerStore` refuses to open and planning, logging and shoe tracking
    /// all disappear for the session.
    ///
    /// Unlike the earlier version of this test, the store below really is written by an older
    /// schema — see `PreBlocksSchema` for why listing models minus one type did not achieve that.
    /// Both halves of the change are covered here: the added `PlannedWorkoutBlock` entity and the
    /// added `blockShape` attribute.
    func testAStoreWrittenBeforePlanBlocksExistedStillOpensAndKeepsItsData() throws {
        // The premise, asserted rather than assumed. If the old schema somehow contains the new
        // entity, this test writes and reads the same schema and measures nothing while passing.
        let oldSchema = Schema(PreBlocksSchema.models)
        XCTAssertFalse(oldSchema.entities.contains { $0.name == "PlannedWorkoutBlock" },
                       "the pre-blocks schema must not contain PlannedWorkoutBlock")
        XCTAssertFalse(
            oldSchema.entities
                .first { $0.name == "PendingWorkoutExecution" }?
                .properties.contains { $0.name == "blockShape" } ?? true,
            "the pre-blocks schema must not contain the blockShape attribute")

        let planID = UUID()

        try autoreleasepool {
            let old = try container(for: PreBlocksSchema.models)
            let context = old.mainContext
            context.insert(PreBlocksSchema.PlannedWorkout(id: planID,
                                                          name: "4/1 × 5",
                                                          runIntervalSeconds: 240,
                                                          walkIntervalSeconds: 60,
                                                          plannedRepetitions: 5))
            context.insert(PreBlocksSchema.PendingWorkoutExecution(plannedWorkoutID: planID,
                                                                   plannedWorkoutName: "4/1 × 5",
                                                                   runIntervalSeconds: 240,
                                                                   walkIntervalSeconds: 60,
                                                                   plannedRepetitions: 5))
            try context.save()
        }

        let migrated = try container(for: LoggerStore.models)
        let context = migrated.mainContext

        let plans = try context.fetch(FetchDescriptor<PlannedWorkout>())
        XCTAssertEqual(plans.count, 1, "the existing plan must survive the added model")
        XCTAssertEqual(plans.first?.name, "4/1 × 5")

        // A plan carrying no blocks is a one-segment plan, not a broken one. This is the property
        // that lets blocks ship without a migration, asserted against a store that predates them.
        let plan = try XCTUnwrap(plans.first)
        XCTAssertTrue(plan.blocks.isEmpty)
        XCTAssertEqual(plan.resolvedBlocks,
                       [PlannedWorkout.Block(runSeconds: 240, walkSeconds: 60, repetitions: 5)])
        XCTAssertEqual(plan.intervalSummary, "4/1 × 5")

        // And a session from before shapes were recorded reads as "not recorded", never as
        // "had several segments" — its own interval columns are the truth about it.
        let execution = try XCTUnwrap(
            context.fetch(FetchDescriptor<PendingWorkoutExecution>()).first)
        XCTAssertNil(execution.blockShape)
        XCTAssertFalse(execution.hasMultipleBlocks)
        XCTAssertEqual(execution.runIntervalSeconds, 240)

        XCTAssertTrue(try context.fetch(FetchDescriptor<PlannedWorkoutBlock>()).isEmpty)
    }

    /// A plan given blocks after the migration keeps them, in the same store as the older records.
    func testBlocksAddedAfterMigrationPersistBesideTheOlderRecords() throws {
        let planID = UUID()

        try autoreleasepool {
            let old = try container(for: PreBlocksSchema.models)
            old.mainContext.insert(PreBlocksSchema.PlannedWorkout(id: planID,
                                                                  name: "4/1 × 5",
                                                                  runIntervalSeconds: 240,
                                                                  walkIntervalSeconds: 60,
                                                                  plannedRepetitions: 5))
            try old.mainContext.save()
        }

        try autoreleasepool {
            let migrated = try container(for: LoggerStore.models)
            let plan = try XCTUnwrap(
                migrated.mainContext.fetch(FetchDescriptor<PlannedWorkout>()).first)
            plan.blocks = [
                PlannedWorkoutBlock(orderIndex: 0, runIntervalSeconds: 300,
                                    walkIntervalSeconds: 60, repetitions: 1),
                PlannedWorkoutBlock(orderIndex: 1, runIntervalSeconds: 480,
                                    walkIntervalSeconds: 60, repetitions: 2),
            ]
            try migrated.mainContext.save()
        }

        let reopened = try container(for: LoggerStore.models)
        let plan = try XCTUnwrap(
            reopened.mainContext.fetch(FetchDescriptor<PlannedWorkout>()).first)

        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertEqual(plan.intervalSummary, "5/1×1 · 8/1×2")
    }

    /// And a note written after the migration lands in the same store as the pre-existing data,
    /// rather than in a second one created alongside it.
    func testANoteWrittenAfterMigrationPersistsBesideTheOlderRecords() throws {
        let executionID = UUID()

        try autoreleasepool {
            let old = try container(for: Self.modelsBeforeNotes)
            old.mainContext.insert(PendingWorkoutExecution(
                id: executionID,
                plannedWorkoutID: UUID(),
                plannedWorkoutName: "4/1 × 5",
                expectedActivityType: .running,
                expectedDurationSeconds: 1_500,
                runIntervalSeconds: 240,
                walkIntervalSeconds: 60,
                plannedRepetitions: 5,
                status: .completed))
            try old.mainContext.save()
        }

        try autoreleasepool {
            let migrated = try container(for: LoggerStore.models)
            migrated.mainContext.insert(WorkoutNote(executionID: executionID,
                                                    phaseType: .walk,
                                                    repetitionNumber: 3,
                                                    secondsIntoWorkout: 742,
                                                    text: "calf tight"))
            try migrated.mainContext.save()
        }

        let reopened = try container(for: LoggerStore.models)
        let notes = try reopened.mainContext.fetch(FetchDescriptor<WorkoutNote>())
        XCTAssertEqual(notes.map(\.text), ["calf tight"])
        XCTAssertEqual(try reopened.mainContext.fetch(
            FetchDescriptor<PendingWorkoutExecution>()).count, 1,
            "the record written under the old schema must still be there")
    }

    // MARK: - Open intervals

    /// The store exactly as it stands on the owner's phone before open intervals: plans can hold
    /// blocks, and nothing knows about `OpenIntervalShape` or the seven columns added to
    /// `WorkoutIntervalLog`.
    ///
    /// Frozen copies, like `PreBlocksSchema`. If a property is added to the real models, do **not**
    /// add it here — the point of this schema is what the phone has already written.
    enum PreOpenIntervalsSchema: VersionedSchema {
        static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

        static var models: [any PersistentModel.Type] {
            [PlannedWorkout.self, PlannedWorkoutBlock.self, WorkoutIntervalLog.self]
        }

        /// `PlannedWorkout` with blocks but no `openIntervalShape` relationship.
        @Model
        final class PlannedWorkout {
            @Attribute(.unique) var id: UUID
            var name: String
            var activityType: String
            var warmupMode: String
            var warmupSeconds: Int?
            var runIntervalSeconds: Int
            var walkIntervalSeconds: Int
            var plannedRepetitions: Int
            var includesFinalWalk: Bool
            var cooldownMode: String
            var cooldownSeconds: Int?
            var countdownSeconds: Int
            var createdAt: Date
            var updatedAt: Date
            var isNextWorkout: Bool
            var workoutKitIdentifier: String?

            @Relationship(deleteRule: .cascade, inverse: \PlannedWorkoutBlock.plan)
            var blocks: [PlannedWorkoutBlock] = []

            init(id: UUID, name: String,
                 runIntervalSeconds: Int, walkIntervalSeconds: Int, plannedRepetitions: Int) {
                self.id = id
                self.name = name
                self.activityType = "running"
                self.warmupMode = "none"
                self.runIntervalSeconds = runIntervalSeconds
                self.walkIntervalSeconds = walkIntervalSeconds
                self.plannedRepetitions = plannedRepetitions
                self.includesFinalWalk = false
                self.cooldownMode = "open"
                self.countdownSeconds = 0
                self.createdAt = Date()
                self.updatedAt = Date()
                self.isNextWorkout = false
            }
        }

        @Model
        final class PlannedWorkoutBlock {
            @Attribute(.unique) var id: UUID
            var orderIndex: Int
            var runIntervalSeconds: Int
            var walkIntervalSeconds: Int
            var repetitions: Int
            var plan: PlannedWorkout?

            init(orderIndex: Int, runIntervalSeconds: Int,
                 walkIntervalSeconds: Int, repetitions: Int) {
                self.id = UUID()
                self.orderIndex = orderIndex
                self.runIntervalSeconds = runIntervalSeconds
                self.walkIntervalSeconds = walkIntervalSeconds
                self.repetitions = repetitions
            }
        }

        /// `WorkoutIntervalLog` before it could describe a leg — no `endReason`, no
        /// `baselineReachedAt`, none of the five severity columns.
        @Model
        final class WorkoutIntervalLog {
            @Attribute(.unique) var id: UUID
            var executionID: UUID
            var healthKitWorkoutUUID: UUID?
            var sequenceIndex: Int
            var phaseType: String
            var repetitionNumber: Int?
            var plannedDurationSeconds: Int?
            var actualDurationSeconds: Double
            var startDate: Date
            var endDate: Date
            var wasSkipped: Bool
            var wasInterrupted: Bool

            init(executionID: UUID, sequenceIndex: Int, phaseType: String,
                 actualDurationSeconds: Double) {
                self.id = UUID()
                self.executionID = executionID
                self.sequenceIndex = sequenceIndex
                self.phaseType = phaseType
                self.actualDurationSeconds = actualDurationSeconds
                self.startDate = Date()
                self.endDate = Date()
                self.wasSkipped = false
                self.wasInterrupted = false
            }
        }
    }

    /// Opening a store written before open intervals existed.
    ///
    /// This is the migration the owner's phone performs on the next install, over months of real
    /// runs. If it fails, `LoggerStore` refuses to open and planning, logging and shoe tracking all
    /// disappear for the session — the whole app, for a feature he may never use.
    func testAStoreWrittenBeforeOpenIntervalsStillOpensAndKeepsItsData() throws {
        // The premise, asserted rather than assumed. `Schema(models)` pulls in the destination of
        // any relationship a listed model declares, which is exactly how the first version of the
        // blocks test came to write and read the same schema while appearing to measure a
        // migration.
        let oldSchema = Schema(PreOpenIntervalsSchema.models)
        XCTAssertFalse(oldSchema.entities.contains { $0.name == "OpenIntervalShape" },
                       "the pre-open-intervals schema must not contain OpenIntervalShape")
        XCTAssertFalse(
            oldSchema.entities
                .first { $0.name == "WorkoutIntervalLog" }?
                .properties.contains { $0.name == "endReason" } ?? true,
            "the pre-open-intervals schema must not contain the endReason attribute")

        let planID = UUID()
        let executionID = UUID()

        try autoreleasepool {
            let old = try container(for: PreOpenIntervalsSchema.models)
            let context = old.mainContext
            let plan = PreOpenIntervalsSchema.PlannedWorkout(id: planID,
                                                             name: "5/1×1 · 8/1×2",
                                                             runIntervalSeconds: 0,
                                                             walkIntervalSeconds: 0,
                                                             plannedRepetitions: 0)
            context.insert(plan)
            plan.blocks = [
                PreOpenIntervalsSchema.PlannedWorkoutBlock(orderIndex: 0, runIntervalSeconds: 300,
                                                           walkIntervalSeconds: 60, repetitions: 1),
                PreOpenIntervalsSchema.PlannedWorkoutBlock(orderIndex: 1, runIntervalSeconds: 480,
                                                           walkIntervalSeconds: 60, repetitions: 2),
            ]
            context.insert(PreOpenIntervalsSchema.WorkoutIntervalLog(executionID: executionID,
                                                                     sequenceIndex: 0,
                                                                     phaseType: "run",
                                                                     actualDurationSeconds: 300))
            try context.save()
        }

        let migrated = try container(for: LoggerStore.models)
        let context = migrated.mainContext

        let plans = try context.fetch(FetchDescriptor<PlannedWorkout>())
        XCTAssertEqual(plans.count, 1, "the existing plan must survive the added model")
        // The block plan is still a block plan afterwards. Its zeroed flat fields are what
        // `hasDamagedShape` keys on, so a migration that lost the blocks would leave it reporting
        // itself as destroyed — the exact silent loss this app already suffered once.
        XCTAssertEqual(plans.first?.resolvedBlocks.count, 2)
        XCTAssertNil(plans.first?.openIntervalShape,
                     "a plan written before open intervals has no shape record, which is what "
                     + "makes it an interval plan")
        XCTAssertFalse(plans.first?.hasDamagedShape ?? true)

        let intervals = try context.fetch(FetchDescriptor<WorkoutIntervalLog>())
        XCTAssertEqual(intervals.count, 1, "the recorded interval must survive the added columns")
        // Blank, not zero: these rows predate the question being asked. The export depends on the
        // difference, and a migration that defaulted them to 0 would write five measurements into
        // every interval ever recorded.
        XCTAssertNil(intervals.first?.endReason)
        XCTAssertNil(intervals.first?.lowerBackSeverity)
        XCTAssertNil(intervals.first?.baselineReachedAt)
        XCTAssertTrue(intervals.first?.signalReadings.isEmpty ?? false)
    }
}
