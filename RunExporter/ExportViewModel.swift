import Foundation
import SwiftUI

/// Identifiable wrapper so the share sheet can be driven by `.sheet(item:)`,
/// which guarantees a single `onDismiss` callback for cleanup.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class ExportViewModel: ObservableObject {

    // MARK: - Published state

    @Published var startDate: Date
    @Published var endDate: Date = Date()
    @Published var exportMode: ExportMode = .fullDateRange

    /// "Additional Data" toggles. Both start on at every launch, like `endDate` and
    /// `exportMode`, so an export never quietly omits data because of an earlier session.
    @Published var includeWeather = true
    @Published var includeRoutes = true

    /// Unlike the two above, this one is **persisted** (in `LoggerDefaults`) and defaults to off.
    /// It is a statement about what counts as training data rather than a per-export choice, and
    /// the same value drives the logger queue and History so they can never disagree.
    @Published var includeWalking = false

    @Published var permissionRequested: Bool
    @Published var isExporting = false
    @Published var progressText = ""
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?

    /// When set, the UI presents the share sheet.
    @Published var shareItem: ShareItem?

    // MARK: - Private

    private let health: HealthKitManager
    /// Read at export time to add the subjective columns and files. Optional so the exporter still
    /// works exactly as it did in v1.0 when the logger store failed to open.
    private var loggerStore: LoggerStore?
    private var loggerDefaults: LoggerDefaults?
    private var pendingResult: ExportBuilder.Result?

    private let startDateKey = "savedStartDate"
    private let permissionRequestedKey = "permissionRequested"
    private let permissionSchemaVersionKey = "permissionSchemaVersion"

    /// True when authorization has been requested for the *current* set of read types.
    ///
    /// Someone who granted access before workout routes were added has already dismissed the
    /// permission sheet, so the route type would never be requested and routes would come back
    /// empty with no visible reason. Comparing the stored schema version forces one more prompt
    /// after an upgrade.
    private var authorizationIsCurrent: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: permissionRequestedKey) else { return false }
        return defaults.integer(forKey: permissionSchemaVersionKey)
            >= HealthKitManager.authorizationSchemaVersion
    }

    private func markAuthorizationRequested() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: permissionRequestedKey)
        defaults.set(HealthKitManager.authorizationSchemaVersion, forKey: permissionSchemaVersionKey)
        permissionRequested = true
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Fixed program start: 2026-06-18 00:00:00 America/Los_Angeles.
    let programStartDate: Date = {
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
        comps.year = 2026; comps.month = 6; comps.day = 18
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }()

    var isHealthAvailable: Bool { health.isAvailable }

    // MARK: - Init

    init(health: HealthKitManager = HealthKitManager(),
         loggerStore: LoggerStore? = nil,
         loggerDefaults: LoggerDefaults? = nil) {
        self.health = health
        self.loggerStore = loggerStore
        self.loggerDefaults = loggerDefaults

        let defaults = UserDefaults.standard
        // Persisted start date (defaults to program start on first launch).
        if let saved = defaults.object(forKey: startDateKey) as? Date {
            self.startDate = saved
        } else {
            var comps = DateComponents()
            comps.timeZone = TimeZone(identifier: "America/Los_Angeles")
            comps.year = 2026; comps.month = 6; comps.day = 18
            self.startDate = Calendar.current.date(from: comps) ?? Date()
        }
        // Show as "granted" only when the current read-type set has actually been requested.
        self.permissionRequested = defaults.bool(forKey: permissionRequestedKey)
            && defaults.integer(forKey: permissionSchemaVersionKey)
                >= HealthKitManager.authorizationSchemaVersion
    }

    func persistStartDate() {
        UserDefaults.standard.set(startDate, forKey: startDateKey)
    }

    /// Connects the run logger, whose contents are added to the export.
    ///
    /// Set after init because the view creates the model with `@StateObject` and only then has
    /// access to the environment's store. Exporting without it still produces the complete v1.0
    /// export; the logger files are written with headers only and the manifest says why.
    func attachLogger(store: LoggerStore, defaults: LoggerDefaults) {
        loggerStore = store
        loggerDefaults = defaults
        includeWalking = defaults.includeWalkingWorkouts
    }

    /// Persists the walking choice, so the logger queue and History match the next export.
    func persistIncludeWalking() {
        loggerDefaults?.includeWalkingWorkouts = includeWalking
    }

    // MARK: - Permissions

    func requestHealthAccess() {
        Task {
            do {
                try await health.requestAuthorization()
                markAuthorizationRequested()
                statusMessage = "Health access granted. Ready to export."
            } catch {
                errorMessage = "Health access failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export

    func export() {
        guard !isExporting else { return }
        guard health.isAvailable else {
            errorMessage = "HealthKit is not available on this device."
            return
        }

        persistStartDate()
        isExporting = true
        errorMessage = nil
        statusMessage = "Exporting…"
        progressText = "Starting…"

        Task {
            do {
                // Ensure the current read-type set has been requested at least once.
                if !authorizationIsCurrent {
                    try await health.requestAuthorization()
                    markAuthorizationRequested()
                }

                let (queryStart, queryEnd) = queryWindow()

                // Copy the logger out of SwiftData here, on the main actor, before the export
                // task starts. The models are not Sendable and must not cross into it.
                let loggerData = await loggerSnapshot()
                let audioSettings = loggerDefaults?.intervalAudioSettings
                    ?? Self.cuesUnavailableSettings

                let builder = ExportBuilder(health: health, appVersion: appVersion)
                let result = try await builder.build(
                    programStart: programStartDate,
                    queryStart: queryStart,
                    queryEnd: queryEnd,
                    displayStart: startDate,
                    mode: exportMode,
                    options: ExportOptions(includeWeather: includeWeather,
                                           includeRoutes: includeRoutes,
                                           includeWalking: includeWalking,
                                           reclassifiedAsRunning:
                                            loggerDefaults?.reclassifiedAsRunning ?? []),
                    logger: loggerData,
                    intervalAudio: audioSettings,
                    // Not `[weak self]`: the enclosing Task already holds this view model strongly
                    // and outlives the build, so a weak capture here promised a lifetime the
                    // surrounding code contradicts — the compiler says so as #ImplicitStrongCapture.
                    // The closure cannot outlive `build`, so there is no cycle to break.
                    progress: { text in
                        Task { @MainActor in self.progressText = text }
                    }
                )

                pendingResult = result
                isExporting = false
                progressText = ""

                statusMessage = "Export ready. Choose where to share."
                shareItem = ShareItem(url: result.zipURL)
            } catch {
                isExporting = false
                progressText = ""
                errorMessage = "Export failed: \(error.localizedDescription)"
                statusMessage = "Export failed."
                cleanupPending()
            }
        }
    }

    /// The logger's contribution to this export.
    ///
    /// A missing store is a reportable fact, not an empty result: the returned value carries
    /// `storeUnavailable` and an error entry that reach `export_log.json` and `manifest.json`.
    private func loggerSnapshot() async -> LoggerExportData {
        guard let loggerStore else {
            var data = LoggerExportData()
            data.storeUnavailable = true
            data.issues.append(ExportLogEntry(
                level: .warning, category: "run_logger",
                message: "This export ran without the run logger attached, so the logger files "
                    + "contain headers only."))
            return data
        }

        let note = await retryPendingJoins(store: loggerStore)
        var data = LoggerExportSnapshot.make(store: loggerStore)
        if let note { data.issues.append(note) }
        if let legs = Self.unjoinedLegsEntry(store: loggerStore) { data.issues.append(legs) }
        return data
    }

    /// Says how many interval legs export with no workout UUID, and stops there.
    ///
    /// Reported as a fact at `info`, not as a warning, because the honest reading is genuinely
    /// ambiguous: a phone-only run is a supported way to use the app and **every** leg of one
    /// carries a nil UUID. Calling that a warning would fire on every phone-only run and teach the
    /// reader to ignore the line — the same false-positive trap `reconcilePendingCaptures` records
    /// for the sweep it guards.
    ///
    /// Counted after `retryPendingJoins`, so a leg joined moments ago is not reported as orphaned.
    private static func unjoinedLegsEntry(store: LoggerStore) -> ExportLogEntry? {
        let count = LoggerExportSnapshot.unjoinedIntervalLegCount(store: store)
        guard count > 0 else { return nil }
        let legWord = count == 1 ? "leg" : "legs"
        return ExportLogEntry(
            level: .info, category: "run_logger",
            message: "\(count) interval \(legWord) in workout_intervals.csv have no workout UUID, "
                + "so they cannot be joined to a workout in workouts.csv. Expected for a "
                + "phone-only run; otherwise their timer and the Watch workout started more than "
                + "two minutes apart.")
    }

    /// Joins any log still waiting for its workout, immediately before serializing.
    ///
    /// A log written during cooldown has no workout UUID — often no workout exists yet, because the
    /// run is still in progress — and is joined later by `RunLoggerModel.reconcilePendingCaptures`,
    /// which runs on `refresh()`. Exporting without visiting a screen that refreshes therefore
    /// serializes a log that would have joined moments later, and the export reads exactly like a
    /// matching bug. That is not hypothetical: an export taken during cooldown showed an unmatched
    /// log, one taken later the same day showed it matched, and no code changed in between. An
    /// outside review of the first file concluded the matcher was broken.
    ///
    /// Builds its own `RunLoggerModel` rather than taking one: the export screen does not own the
    /// logger, and every ingredient — store, defaults, HealthKit — is already here. Both instances
    /// write through the same `LoggerStore`, so the join persists.
    ///
    /// Returns a line for `export_log.json`, because an export that silently repaired its own data
    /// is still an export that changed something without saying so.
    private func retryPendingJoins(store: LoggerStore) async -> ExportLogEntry? {
        guard let loggerDefaults else { return nil }

        // Notes count, not just logs. Gating on orphaned run logs alone made this blind to a run
        // with notes and no log — an ordinary run, since a note asks for no RPE — so the sweep it
        // guards never ran for exactly the case it was written to catch.
        let before = LoggerExportSnapshot.pendingCaptureCounts(store: store)
        guard before.total > 0 else { return nil }

        let logger = RunLoggerModel(health: health, store: store, defaults: loggerDefaults)
        await logger.refresh()
        let after = LoggerExportSnapshot.pendingCaptureCounts(store: store)

        if before.total > after.total {
            return ExportLogEntry(
                level: .info, category: "run_logger",
                message: "Joined " + Self.capturePhrase(logs: before.logs - after.logs,
                                                        notes: before.notes - after.notes)
                    + " to the workout recorded just before exporting.")
        }
        // Names every cause rather than the comfortable one. This used to end "This is normal if
        // the Watch has not finished syncing", which asserts a cause nothing here checked — and is
        // wrong in the case that actually loses data, where the two starts were more than
        // `RecentWorkoutMatcher.startToleranceSeconds` apart and no amount of syncing will help.
        return ExportLogEntry(
            level: .warning, category: "run_logger",
            message: Self.capturePhrase(logs: after.logs, notes: after.notes)
                + " still waiting for a matching workout in Apple Health, so it appears in "
                + "run_logs.csv and workout_notes.csv without a workout UUID. Ordinary for a "
                + "phone-only run, or a Watch workout that has not synced yet. It is also what a "
                + "start more than two minutes from the timer's leaves behind, which waiting does "
                + "not fix.")
    }

    /// "2 run logs and 1 note" — named separately because they live in different CSVs, and a
    /// reader chasing one should not have to guess which file the number refers to.
    private static func capturePhrase(logs: Int, notes: Int) -> String {
        let logPart = "\(logs) run \(logs == 1 ? "log" : "logs")"
        let notePart = "\(notes) \(notes == 1 ? "note" : "notes")"
        if logs > 0 && notes > 0 { return logPart + " and " + notePart }
        if notes > 0 { return notePart }
        return logPart
    }

    /// Recorded when settings could not be read, so the manifest never claims a cue configuration
    /// that was not actually in effect.
    private static let cuesUnavailableSettings = IntervalAudioSettings(
        cueSource: CueSource.none.rawValue,
        cueMode: CueMode.voiceAndBeeps.rawValue,
        countdownSeconds: 0,
        fiveSecondWarning: false,
        finalRoundAnnouncement: false,
        halfwayAnnouncement: false,
        transitionCountdown: false,
        duckOtherAudio: false)

    /// Query window with the intentional 1-day buffers, based on the user-selected dates.
    private func queryWindow() -> (Date, Date) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: startDate)
        let queryStart = cal.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
        let queryEnd = cal.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        return (queryStart, queryEnd)
    }

    // MARK: - Cleanup after share

    /// Called by the ShareSheet completion handler: dismiss the sheet.
    /// Cleanup happens in `shareFinished()`, invoked by the sheet's onDismiss.
    func dismissShare() {
        shareItem = nil
    }

    /// Called exactly once by the sheet's onDismiss (covers both completion and swipe-to-dismiss).
    func shareFinished() {
        let ok = cleanupPending()
        if ok {
            statusMessage = "Export complete. Temporary files deleted."
        } else {
            statusMessage = "Export shared, but temporary file cleanup failed. You can try again or restart the app."
        }
    }

    @discardableResult
    private func cleanupPending() -> Bool {
        guard let result = pendingResult else { return true }
        let fm = FileManager.default
        var ok = true
        do { try fm.removeItem(at: result.zipURL) } catch { ok = false }
        do { try fm.removeItem(at: result.exportFolder) } catch { ok = false }
        pendingResult = nil
        return ok
    }
}
