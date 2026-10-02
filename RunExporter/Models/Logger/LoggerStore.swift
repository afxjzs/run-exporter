import Foundation
import SwiftData

/// Owns the SwiftData stack for everything the logger persists.
///
/// Container creation is allowed to fail loudly. If the store cannot be opened the app does **not**
/// silently fall back to an in-memory container that would drop the user's logs on the next launch:
/// `containerError` is set, the UI shows it, and the pre-existing HealthKit export keeps working
/// without the logger.
@MainActor
@Observable
final class LoggerStore {

    /// Every model in the store. Kept in one place so the container and any test container agree.
    static let models: [any PersistentModel.Type] = [
        Shoe.self,
        PlannedWorkout.self,
        PlannedWorkoutBlock.self,
        OpenIntervalShape.self,
        PendingWorkoutExecution.self,
        RunLog.self,
        BodySignalDetail.self,
        RecoveryLog.self,
        WorkoutIntervalLog.self,
        WorkoutNote.self,
    ]

    private(set) var container: ModelContainer?
    /// Non-nil when the store could not be opened. Surfaced in the UI; never swallowed.
    private(set) var containerError: String?
    /// Non-nil when `ShapeZeroRepair` failed. The store works, but plans and runs saved by an older
    /// build may still report a zero where "not set" belongs. Surfaced in the UI; never swallowed.
    private(set) var repairError: String?

    var context: ModelContext? {
        guard let container else { return nil }
        return container.mainContext
    }

    init(inMemory: Bool = false) {
        do {
            let schema = Schema(Self.models)
            let configuration = ModelConfiguration(schema: schema,
                                                   isStoredInMemoryOnly: inMemory)
            let opened = try ModelContainer(for: schema, configurations: [configuration])
            container = opened
            do {
                _ = try ShapeZeroRepair.run(in: opened.mainContext)
            } catch {
                repairError = "Plans and runs saved by an older version could not be updated: "
                    + "\(error.localizedDescription). Everything still works, but some of them "
                    + "may show or export 0 where a value is not set. This is tried again at "
                    + "every launch."
            }
        } catch {
            container = nil
            containerError = "The run logger database could not be opened: "
                + "\(error.localizedDescription). Exporting HealthKit data still works, but "
                + "planning, logging and shoe tracking are unavailable this session."
        }
    }

    // MARK: - Saving

    /// Saves, returning the error text instead of throwing it away. Callers show it.
    @discardableResult
    func save() -> String? {
        guard let context else { return "The run logger database is unavailable, so nothing was saved." }
        guard context.hasChanges else { return nil }
        do {
            try context.save()
            return nil
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: - Fetching

    /// Fetches, reporting failure rather than returning a misleading empty array.
    ///
    /// An empty result and an unreadable store are different facts, and a plain `[]` return would
    /// make them indistinguishable to every caller.
    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Result<[T], LoggerStoreError> {
        guard let context else {
            return .failure(LoggerStoreError("The run logger database is unavailable."))
        }
        do {
            return .success(try context.fetch(descriptor))
        } catch {
            return .failure(LoggerStoreError("Could not read \(T.self): \(error.localizedDescription)"))
        }
    }
}

/// A store failure carrying a message meant to be shown to the user.
struct LoggerStoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - First-run seeding

/// Initial local data for *this* installation (spec §18).
///
/// Deliberately not part of any reusable code path: it runs once, only when the store is empty,
/// and only until the user has any shoe of their own. `SeedInstallData` exists so the shoe is a
/// data decision that can be deleted in one place, not a constant embedded in application logic.
enum SeedInstallData {

    private static let seedCompletedKey = "logger.seed.v1.completed"

    struct InitialShoe {
        let brand: String
        let model: String
        let displayName: String
        let firstUseComponents: DateComponents
    }

    /// The shoe this installation was already running in when v1.1 was built.
    static let initialShoe = InitialShoe(
        brand: "On",
        model: "Cloudmonster 2",
        displayName: "On Cloudmonster 2",
        firstUseComponents: {
            var comps = DateComponents()
            comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
            comps.year = 2026; comps.month = 7; comps.day = 17
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return comps
        }()
    )

    /// Inserts the initial shoe exactly once, and only into an empty shoe list.
    ///
    /// Returns an error string when seeding was attempted and failed. Returns nil both when
    /// seeding succeeded and when it was correctly skipped — the caller can tell the difference
    /// from the store's contents, and a skipped seed is not a failure.
    @MainActor
    @discardableResult
    static func seedIfNeeded(store: LoggerStore, defaults: LoggerDefaults,
                             userDefaults: UserDefaults = .standard) -> String? {
        guard !userDefaults.bool(forKey: seedCompletedKey) else { return nil }
        guard store.container != nil else {
            // The store failed to open; that is already being reported. Do not mark the seed done,
            // so it can still run on a later launch when the store works.
            return nil
        }

        switch store.fetch(FetchDescriptor<Shoe>()) {
        case .failure(let error):
            return "Could not check existing shoes before seeding: \(error.message)"
        case .success(let existing):
            guard existing.isEmpty else {
                // The user already has shoes — never overwrite them. Seeding is done.
                userDefaults.set(true, forKey: seedCompletedKey)
                return nil
            }
        }

        guard let context = store.context else { return nil }
        let shoe = Shoe(brand: initialShoe.brand,
                        model: initialShoe.model,
                        displayName: initialShoe.displayName,
                        firstUseDate: Calendar.current.date(from: initialShoe.firstUseComponents),
                        startingMileage: 0,
                        isDefault: true)
        context.insert(shoe)

        if let error = store.save() {
            return "Could not create the initial shoe: \(error)"
        }
        defaults.defaultShoeID = shoe.id
        userDefaults.set(true, forKey: seedCompletedKey)
        return nil
    }
}
