import Foundation
import SwiftData

/// One free-text observation captured **during** a workout, at the moment the thought existed.
///
/// ## Why this is its own record rather than a field on `WorkoutIntervalLog`
///
/// The interval a note belongs to is the right way to read it — a note taken during walk 3 is a
/// different fact from one taken during cooldown — but `WorkoutIntervalLog` cannot *hold* it.
/// Those rows are written from `IntervalTimerEngine.onIntervalCompleted`, at the phase boundary,
/// so while walk 3 is happening there is no row for walk 3 yet. Writing the note there would mean
/// keeping the user's writing in memory for up to a whole interval before it reached disk, and
/// this project has already lost a set of notes once.
///
/// So the note is written the instant it is entered, and carries the context it was written in:
/// `phaseType` and `repetitionNumber` say which segment, `secondsIntoWorkout` and `createdAt` say
/// when. **`phaseType` and `repetitionNumber` are the authoritative link**, recorded at capture; the
/// matching `WorkoutIntervalLog` is then found by time, not by a link that has to be maintained.
///
/// That time comparison needs one correction, measured in the 2026-08-22 export. When a phase is
/// paused, `IntervalTimerEngine.resume()` shifts its `phaseStartDate` **forward** by the paused
/// duration, so the interval's recorded `startDate` is later than the moment the phase really
/// began. A note taken in that opening window carries a `createdAt` earlier than the `startDate` of
/// the very interval it belongs to, and a naive `startDate ≤ createdAt ≤ endDate` test drops it into
/// the gap. Widen the lower bound by the pauses recorded inside the phase, or just trust
/// `phaseType`. See LEARNINGS.md → Run logging.
///
/// `healthKitWorkoutUUID` is optional for the same reason it is on `WorkoutIntervalLog`: the
/// Watch's workout does not exist yet while the note is being written. It is stamped later by
/// `RunLoggerModel.attach(workoutUUID:toExecution:)`, on the same path that stamps the intervals.
@Model
final class WorkoutNote {

    @Attribute(.unique) var id: UUID
    var executionID: UUID
    var healthKitWorkoutUUID: UUID?

    /// When the note was entered. The primary ordering, and what joins it to an interval.
    var createdAt: Date

    /// The phase in progress when the note was written, as `WorkoutPhase.rawValue`.
    var phaseType: String
    /// The repetition in progress, when the phase has one. Nil during warmup and cooldown.
    var repetitionNumber: Int?
    /// Elapsed workout time at the moment of capture, excluding paused time — the same clock the
    /// active-workout screen shows, so a note can be placed in the run without arithmetic on dates.
    var secondsIntoWorkout: Double

    var text: String

    init(id: UUID = UUID(),
         executionID: UUID,
         healthKitWorkoutUUID: UUID? = nil,
         createdAt: Date = Date(),
         phaseType: WorkoutPhase,
         repetitionNumber: Int? = nil,
         secondsIntoWorkout: Double,
         text: String) {
        self.id = id
        self.executionID = executionID
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.createdAt = createdAt
        self.phaseType = phaseType.rawValue
        self.repetitionNumber = repetitionNumber
        self.secondsIntoWorkout = secondsIntoWorkout
        self.text = text
    }

    var phaseTypeValue: WorkoutPhase? { WorkoutPhase(rawValue: phaseType) }
}
