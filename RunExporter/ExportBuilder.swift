import Foundation
import HealthKit

/// Orchestrates the export: asks HealthKitManager for data, writes CSV/JSON files into a temp
/// folder, builds the manifest, and returns the folder + zip URLs.
struct ExportBuilder {

    /// Name of the sub-folder holding per-workout route files.
    static let routesFolderName = "routes"

    struct Progress {
        var text: String
    }

    struct Result {
        let exportFolder: URL   // the temp working folder (parent of the extract folder)
        let extractFolder: URL  // running_health_extract_..._to_now
        let zipURL: URL
    }

    let health: HealthKitManager
    let appVersion: String

    /// - Parameters:
    ///   - programStart: the fixed program start (2026-06-18 local).
    ///   - queryStart / queryEnd: the buffered query window.
    ///   - displayStart: the user-facing start date, used to name the folder.
    ///   - logger: run-logger contents, already snapshotted off the SwiftData store.
    ///   - intervalAudio: the cue configuration, recorded in the manifest.
    func build(programStart: Date,
               queryStart: Date,
               queryEnd: Date,
               displayStart: Date,
               mode: ExportMode,
               options: ExportOptions,
               logger: LoggerExportData,
               intervalAudio: IntervalAudioSettings,
               progress: @escaping (String) -> Void) async throws -> Result {

        let fm = FileManager.default
        let startYMD = folderDateString(displayStart)
        // The day the export was taken, not the word "now". "now" was true while it was being
        // written and dates the file to whenever it is next read, and every export of the same
        // start date landed on one filename — so a Downloads folder collected
        // "..._to_now 5.zip", "..._to_now 6.zip", named by the operating system rather than by
        // this app, in the order they happened to be saved.
        //
        // Date only, no clock time: exports are a once-a-day thing outside of testing, and a
        // second one on the same day is still disambiguated by the download itself.
        let takenYMD = folderDateString(Date())
        let extractName = "running_health_extract_\(startYMD)_to_\(takenYMD)"

        // temp/running_health_export/running_health_extract_..._to_.../
        let exportFolder = fm.temporaryDirectory.appendingPathComponent("running_health_export", isDirectory: true)
        // Clean any stale folder from a previous run.
        try? fm.removeItem(at: exportFolder)
        let extractFolder = exportFolder.appendingPathComponent(extractName, isDirectory: true)
        try fm.createDirectory(at: extractFolder, withIntermediateDirectories: true)

        var dataset = ExportDataset()
        let resolved = health.resolveSpecs()
        dataset.requestedTypes = HealthKitManager.quantitySpecs.map { $0.key }
        dataset.availableTypes = resolved.available.map { $0.spec.key }
        dataset.unavailableTypes = resolved.unavailable.map { $0.key }

        // 1. Workouts
        progress("Reading workouts…")
        let workoutResult = try await health.fetchWorkouts(
            start: queryStart, end: queryEnd,
            includeWalking: options.includeWalking,
            reclassifiedAsRunning: options.reclassifiedAsRunning)
        let workouts = workoutResult.workouts
        dataset.allWorkoutTypeCounts = workoutResult.allCounts
        dataset.keptWorkoutTypeCounts = workoutResult.keptCounts

        if !options.includeWalking {
            let walkCount = workoutResult.allCounts["HKWorkoutActivityTypeWalking"] ?? 0
            dataset.log(.info, "workouts",
                        "Walking workouts were excluded from this export; \(walkCount) were seen "
                            + "in the window and skipped. They still exist in HealthKit — see "
                            + "\"walking_included\" in manifest.json.")
        }

        // 2. Workout weather, straight from metadata already loaded with each workout.
        progress("Reading workout weather…")
        let metadataExporter = WorkoutMetadataExporter()
        if !options.includeWeather {
            dataset.log(.info, "weather",
                        "Workout weather was switched off for this export; weather columns are blank.")
        }
        for workout in workouts {
            var output = metadataExporter.makeRow(for: workout, includeWeather: options.includeWeather)
            // The row keeps HealthKit's own activity type; the user's assertion rides alongside it
            // in its own column rather than overwriting the source record.
            output.row.reclassifiedAsRunning = options.reclassifiedAsRunning.contains(workout.uuid)
            dataset.workouts.append(output.row)
            if let weather = output.weather {
                dataset.weatherDiagnostics.record(weather)
            } else {
                dataset.weatherDiagnostics.recordSkipped()
            }
            for issue in output.issues { dataset.append(issue) }
        }

        // In workout-windows mode, build the merged, buffered windows used to filter records.
        let bufferSeconds = TimeInterval(ExportMode.workoutWindowBufferMinutes * 60)
        let mergedWindows: [DateInterval]? = (mode == .workoutWindowsOnly)
            ? HealthKitManager.mergedWindows(from: workoutResult.keptIntervals, buffer: bufferSeconds)
            : nil
        dataset.rawWorkoutWindowsCount = workoutResult.keptIntervals.count
        dataset.mergedWorkoutWindowsCount = mergedWindows?.count ?? 0

        // 3. Quantity records
        for (index, item) in resolved.available.enumerated() {
            let spec = item.spec
            if spec.key == "heartRate" {
                progress("Reading heart rate…")
            } else if index == 0 {
                progress("Reading \(spec.key)…")
            } else {
                progress("Reading heart rate and running metrics… (\(spec.key))")
            }

            do {
                let rows = try await health.fetchRecords(spec: spec, type: item.type,
                                                         start: queryStart, end: queryEnd,
                                                         windows: mergedWindows)
                dataset.records.append(contentsOf: rows)
                if rows.isEmpty {
                    dataset.emptyRequestedTypes.append(spec.key)
                } else {
                    dataset.keptRecordCounts[spec.key] = rows.count
                }
            } catch {
                dataset.log(.warning, "records",
                            "Failed reading \(spec.key): \(error.localizedDescription)")
                dataset.emptyRequestedTypes.append(spec.key)
            }
        }

        // 4. Activity summaries (optional / best effort)
        progress("Reading activity summaries…")
        do {
            dataset.activitySummaries = try await health.fetchActivitySummaries(start: queryStart, end: queryEnd)
        } catch {
            dataset.log(.warning, "summaries",
                        "Activity summaries unavailable: \(error.localizedDescription)")
        }

        // 5. Workout routes
        await exportRoutes(workouts: workouts,
                           options: options,
                           into: extractFolder,
                           dataset: &dataset,
                           progress: progress)

        // Fold each workout's route summary into its workouts.csv row.
        let summariesByUUID = Dictionary(dataset.routeSummaries.map { ($0.workoutUUID, $0) },
                                         uniquingKeysWith: { first, _ in first })
        for index in dataset.workouts.indices {
            guard let summary = summariesByUUID[dataset.workouts[index].uuid] else { continue }
            dataset.workouts[index].routeValues = summary.workoutValues
        }

        // 6. Fold the subjective run log into each workouts.csv row. Workouts with no log keep
        // the all-blank defaults, so "not logged" stays distinguishable from a logged zero.
        progress("Reading run logs…")
        dataset.logger = logger
        for entry in logger.issues { dataset.append(entry) }
        var unloggedCount = 0
        for index in dataset.workouts.indices {
            if let join = logger.join(forWorkoutUUID: dataset.workouts[index].uuid) {
                dataset.workouts[index].loggerValues = join.values
            } else {
                unloggedCount += 1
            }
        }
        dataset.logger.unloggedWorkoutCount = unloggedCount

        // 7. Write files. Capture a single "export created at" instant so the manifest and
        // every ZIP entry timestamp agree.
        progress("Writing export files…")
        let exportCreatedAt = Date()
        try writeFiles(dataset: dataset,
                       into: extractFolder,
                       programStart: programStart,
                       queryStart: queryStart,
                       queryEnd: queryEnd,
                       mode: mode,
                       options: options,
                       intervalAudio: intervalAudio,
                       createdAt: exportCreatedAt)

        // 8. Zip — stamp every entry with export_created_at.
        progress("Creating ZIP…")
        let zipURL = exportFolder.appendingPathComponent("\(extractName).zip")
        try ZipService.zipFolder(at: extractFolder, to: zipURL, entryDate: exportCreatedAt)

        return Result(exportFolder: exportFolder, extractFolder: extractFolder, zipURL: zipURL)
    }

    // MARK: - Routes

    /// Reads each workout's HealthKit routes and writes `routes/route_<uuid>.csv` + `.gpx`.
    ///
    /// Route files are written as each workout is read so a long history never holds every point
    /// of every run in memory at once. Failures are recorded and skipped: one unreadable route
    /// must not fail the export.
    private func exportRoutes(workouts: [HKWorkout],
                              options: ExportOptions,
                              into extractFolder: URL,
                              dataset: inout ExportDataset,
                              progress: @escaping (String) -> Void) async {

        // Summary rows exist for every workout, including ones with no route data.
        func placeholderSummary(for workout: HKWorkout) -> RouteSummaryRow {
            RouteSummaryRow(
                workoutUUID: workout.uuid.uuidString,
                workoutActivityType: HealthKitManager.activityTypeRawName(workout.workoutActivityType),
                startDate: Fmt.isoString(workout.startDate),
                endDate: Fmt.isoString(workout.endDate))
        }

        guard options.includeRoutes else {
            dataset.routeDiagnostics.authorizationRequested = false
            dataset.routeDiagnostics.authorizationStatus = .notRequested
            dataset.routeSummaries = workouts.map(placeholderSummary)
            dataset.log(.info, "route",
                        "GPS route export was switched off for this export; no route data was requested.")
            return
        }

        guard health.isAvailable else {
            dataset.routeDiagnostics.authorizationRequested = false
            dataset.routeDiagnostics.authorizationStatus = .unavailable
            dataset.routeSummaries = workouts.map(placeholderSummary)
            dataset.log(.warning, "route", "HealthKit is unavailable; no routes were read.")
            return
        }

        dataset.routeDiagnostics.authorizationRequested = true

        let routesFolder = extractFolder.appendingPathComponent(Self.routesFolderName,
                                                               isDirectory: true)
        var routesFolderCreated = false

        let exporter = WorkoutRouteExporter(store: health.store)
        var observedProblem: RouteAuthorizationStatus?
        var completedWithoutAuthError = false

        for (index, workout) in workouts.enumerated() {
            progress("Reading routes \(index + 1) of \(workouts.count)…")
            dataset.routeDiagnostics.workoutsChecked += 1

            var output = await exporter.readRoutes(for: workout)

            if let problem = output.authorizationProblem {
                // Denied outranks notDetermined: it is the more specific finding.
                if observedProblem != .denied { observedProblem = problem }
            } else {
                completedWithoutAuthError = true
            }

            dataset.routeDiagnostics.routeSamplesFound += output.routeSampleCount
            dataset.routeDiagnostics.pointsDroppedInvalid += output.droppedInvalidCount
            dataset.routeDiagnostics.duplicatePointsRemoved += output.duplicateCount
            if output.routeSampleCount > 0 && output.points.isEmpty {
                dataset.routeDiagnostics.routesWithZeroValidPoints += 1
            }

            if output.points.isEmpty {
                dataset.routeDiagnostics.workoutsWithoutRoutes += 1
            } else {
                // Only create routes/ once there is something to put in it.
                if !routesFolderCreated {
                    do {
                        try FileManager.default.createDirectory(at: routesFolder,
                                                                withIntermediateDirectories: true)
                        routesFolderCreated = true
                    } catch {
                        dataset.log(.error, "route",
                                    "Could not create the routes folder: \(error.localizedDescription). Route files were skipped.")
                    }
                }

                if routesFolderCreated {
                    let created = exporter.writeFiles(for: &output,
                                                      workout: workout,
                                                      activityTypeName: HealthKitManager.activityTypeHumanName(workout.workoutActivityType),
                                                      routesFolder: routesFolder,
                                                      relativeFolder: Self.routesFolderName)
                    for path in created {
                        dataset.routeDiagnostics.files.append(path)
                        if path.hasSuffix(".csv") { dataset.routeDiagnostics.routeCSVFilesCreated += 1 }
                        if path.hasSuffix(".gpx") { dataset.routeDiagnostics.routeGPXFilesCreated += 1 }
                    }
                }

                dataset.routeDiagnostics.workoutsWithRoutes += 1
                dataset.routeDiagnostics.routePointsExported += output.points.count
            }

            for issue in output.issues { dataset.append(issue) }
            dataset.routeSummaries.append(output.summary)
        }

        dataset.routeDiagnostics.authorizationStatus = Self.routeStatus(
            observedProblem: observedProblem,
            completedWithoutAuthError: completedWithoutAuthError,
            workoutsChecked: workouts.count)

        if dataset.routeDiagnostics.authorizationStatus == .denied
            || dataset.routeDiagnostics.authorizationStatus == .notDetermined {
            dataset.log(.warning, "route",
                        "Route access reported \(dataset.routeDiagnostics.authorizationStatus.rawValue); the rest of the export is unaffected.")
        }

        progress("Writing route files…")
    }

    /// Resolves the deterministic route-authorization value reported in the manifest.
    ///
    /// HealthKit does not disclose *read* authorization, so this reflects only what was actually
    /// observable: an explicit authorization error, or its absence.
    static func routeStatus(observedProblem: RouteAuthorizationStatus?,
                            completedWithoutAuthError: Bool,
                            workoutsChecked: Int) -> RouteAuthorizationStatus {
        if let observedProblem { return observedProblem }
        if workoutsChecked == 0 {
            // Nothing was queried, so there is no evidence either way.
            return .unknown
        }
        return completedWithoutAuthError ? .authorized : .unknown
    }

    // MARK: - File writing

    /// Writes every file of the export into `folder`, manifest last.
    ///
    /// Internal rather than private so the file layer — names, headers, manifest inventory — can
    /// be verified directly from a prepared dataset, without HealthKit authorization standing
    /// between the tests and the thing being tested.
    func writeFiles(dataset: ExportDataset,
                    into folder: URL,
                    programStart: Date,
                    queryStart: Date,
                    queryEnd: Date,
                    mode: ExportMode,
                    options: ExportOptions,
                    intervalAudio: IntervalAudioSettings,
                    createdAt: Date) throws {

        // --- CSV files ---

        var workoutsCSV = CSVWriter(columns: WorkoutExportRow.columns)
        for row in dataset.workouts { workoutsCSV.addRow(row.values) }
        try write(workoutsCSV.data, "workouts.csv", folder)

        var recordsCSV = CSVWriter(columns: RecordExportRow.columns)
        for row in dataset.records { recordsCSV.addRow(row.values) }
        try write(recordsCSV.data, "records.csv", folder)

        var summariesCSV = CSVWriter(columns: ActivitySummaryExportRow.columns)
        for row in dataset.activitySummaries { summariesCSV.addRow(row.values) }
        try write(summariesCSV.data, "activity_summaries.csv", folder)

        // One row per workout — including workouts with no route — so route coverage is visible
        // without opening every route file.
        var routesCSV = CSVWriter(columns: RouteSummaryRow.columns)
        for row in dataset.routeSummaries { routesCSV.addRow(row.values) }
        try write(routesCSV.data, "routes_summary.csv", folder)

        // --- Run-logger CSV files (v1.1) ---
        //
        // Always written, even with no rows and even when the store failed to open, so a consumer
        // can tell "no data yet" (header-only file) from "this export predates the logger" (no
        // file at all). manifest.json records which of those it was.

        try writeCSV(columns: PlannedWorkoutExportRow.columns,
                     rows: dataset.logger.plannedWorkouts.map { $0.values },
                     "planned_workouts.csv", folder)
        try writeCSV(columns: PlannedWorkoutBlockExportRow.columns,
                     rows: dataset.logger.plannedWorkoutBlocks.map { $0.values },
                     "planned_workout_blocks.csv", folder)
        try writeCSV(columns: RunLogExportRow.columns,
                     rows: dataset.logger.runLogs.map { $0.values },
                     "run_logs.csv", folder)
        try writeCSV(columns: RecoveryLogExportRow.columns,
                     rows: dataset.logger.recoveryLogs.map { $0.values },
                     "recovery_logs.csv", folder)
        try writeCSV(columns: ShoeExportRow.columns,
                     rows: dataset.logger.shoes.map { $0.values },
                     "shoes.csv", folder)
        try writeCSV(columns: IntervalLogExportRow.columns,
                     rows: dataset.logger.intervalLogs.map { $0.values },
                     "workout_intervals.csv", folder)
        try writeCSV(columns: ExecutionExportRow.columns,
                     rows: dataset.logger.executions.map { $0.values },
                     "pending_workout_executions.csv", folder)
        try writeCSV(columns: BodySignalDetailExportRow.columns,
                     rows: dataset.logger.bodySignalDetails.map { $0.values },
                     "body_signal_details.csv", folder)
        try writeCSV(columns: WorkoutNoteExportRow.columns,
                     rows: dataset.logger.notes.map { $0.values },
                     "workout_notes.csv", folder)

        // --- JSON sidecars (everything except manifest, which is written last) ---

        let workoutCounts: [String: Any] = [
            "all_workout_types_in_window": dataset.allWorkoutTypeCounts,
            "kept_workout_types": dataset.keptWorkoutTypeCounts,
            "workout_types_to_keep": HealthKitManager.keptTypeNames(includeWalking: options.includeWalking),
        ]
        try writeJSON(workoutCounts, "workout_type_counts.json", folder)

        let recordsByType: [String: Any] = [
            "requested_types": dataset.requestedTypes,
            "available_types": dataset.availableTypes,
            "unavailable_types": dataset.unavailableTypes,
            "kept_record_types": dataset.keptRecordCounts,
            "empty_requested_types": dataset.emptyRequestedTypes,
        ]
        try writeJSON(recordsByType, "records_by_type.json", folder)

        // `issues` keeps the v1 flat-string shape; `entries` adds the structured form.
        let log: [String: Any] = [
            "issues": dataset.issues,
            "entries": dataset.logEntries.map { $0.json },
            "entry_counts": [
                "info": dataset.logEntries.filter { $0.level == .info }.count,
                "warning": dataset.logEntries.filter { $0.level == .warning }.count,
                "error": dataset.logEntries.filter { $0.level == .error }.count,
            ],
            "created_at": Fmt.isoString(createdAt),
        ]
        try writeJSON(log, "export_log.json", folder)

        try write(Data(readmeText(dataset: dataset, mode: mode, options: options,
                                  intervalAudio: intervalAudio).utf8),
                  "README.txt", folder)

        // --- Source-count diagnostics (reflect the rows actually exported) ---

        let recordSourceCounts = sourceCounts(dataset.records.map { $0.sourceName })
        let heartRateSourceCounts = sourceCounts(
            dataset.records.filter { $0.type == "heartRate" }.map { $0.sourceName })
        let workoutSourceCounts = sourceCounts(dataset.workouts.map { $0.sourceName })

        // --- manifest.json (written last so the files list can include everything) ---

        var manifest: [String: Any] = [
            "app_name": "Running Health Export",
            "app_version": appVersion,
            "export_created_at": Fmt.isoString(createdAt),
            "program_start_date": Fmt.isoString(programStart),
            "start_date": Fmt.isoString(queryStart),
            "end_date": Fmt.isoString(queryEnd),
            "end_date_mode": "dynamic_now_plus_one_day",
            "timezone": TimeZone.current.identifier,
            "export_mode": mode.rawValue,
            "workout_types_to_keep": HealthKitManager.keptTypeNames(includeWalking: options.includeWalking),
            "record_types_requested": dataset.requestedTypes,
            "record_types_available": dataset.availableTypes,
            "record_types_unavailable": dataset.unavailableTypes,
            "workout_count": dataset.workouts.count,
            "record_count": dataset.records.count,
            "activity_summary_count": dataset.activitySummaries.count,
            "record_source_counts": recordSourceCounts,
            "heart_rate_source_counts": heartRateSourceCounts,
            "workout_source_counts": workoutSourceCounts,

            // Weather: read from metadata already attached to each workout. Naming this
            // explicitly makes clear no historical-weather service was queried.
            "weather_source": "healthkit_workout_metadata",
            "weather_included": options.includeWeather,

            // Recorded so a reader can tell "walks were filtered out" from "this person never
            // walked". `all_workout_types_in_window` in workout_type_counts.json shows how many.
            "walking_included": options.includeWalking,

            // Walks the user asserted were really runs. Listed explicitly so the assertion is
            // auditable: workoutActivityType still says walking for these rows.
            "reclassified_as_running_count": options.reclassifiedAsRunning.count,
            "reclassified_as_running_uuids": options.reclassifiedAsRunning
                .map(\.uuidString).sorted(),
            "weather_metadata": dataset.weatherDiagnostics.json,

            // Routes
            "route_export": dataset.routeDiagnostics.json,
            "route_files": dataset.routeDiagnostics.files.sorted(),

            // Run logger (v1.1)
            "run_logger": dataset.logger.manifestCounts,
            "interval_audio": intervalAudio.json,

            "files": try fileList(in: folder, including: "manifest.json"),
        ]
        if mode == .workoutWindowsOnly {
            manifest["workout_window_buffer_minutes"] = ExportMode.workoutWindowBufferMinutes
            manifest["workout_windows_count"] = dataset.rawWorkoutWindowsCount
            manifest["merged_workout_windows_count"] = dataset.mergedWorkoutWindowsCount
        }
        try writeJSON(manifest, "manifest.json", folder)
    }

    // MARK: - README.txt

    private func readmeText(dataset: ExportDataset,
                            mode: ExportMode,
                            options: ExportOptions,
                            intervalAudio: IntervalAudioSettings) -> String {
        let weatherSection: String
        if options.includeWeather {
            weatherSection = """
            WEATHER
            Weather values come from the metadata Apple already stored with each HealthKit \
            workout (HKMetadataKeyWeatherTemperature, HKMetadataKeyWeatherHumidity, \
            HKMetadataKeyWeatherCondition, HKMetadataKeyBarometricPressure). No external weather \
            service, historical-weather API, or network lookup of any kind was used.

            Weather is absent for many workouts: Apple only records it for some outdoor \
            workouts, mostly those captured by an Apple Watch. When no weather fields are \
            present, weatherMetadataAvailable is false and the individual weather columns are \
            blank. Blank always means "not recorded", never zero.

            Temperature is exported in both Celsius and Fahrenheit. Humidity is normalized to a \
            0-100 percentage; HealthKit stores it either as a 0-1 fraction or as percentage \
            points, and manifest.json reports how many values arrived in each shape. Barometric \
            pressure is converted to hPa. Condition names come from Apple's HKWeatherCondition \
            enum only — an unrecognized code is exported with the numeric value intact and the \
            name "unknown" rather than a guessed label. A weather value stored in an unexpected \
            type is left blank and noted in export_log.json; the untouched original is still \
            visible in the workout's metadataJSON column.
            """
        } else {
            weatherSection = """
            WEATHER
            Workout weather was switched OFF for this export, so every weather column is blank \
            and weatherMetadataAvailable is false for all workouts. This says nothing about \
            whether Apple recorded weather for these workouts. See "weather_included" in \
            manifest.json.
            """
        }

        let routeSection: String
        if options.includeRoutes {
            routeSection = """
            GPS ROUTES
            Routes come from HKWorkoutRoute samples stored in HealthKit by the device that \
            recorded the workout. The app reads historical route data only — it never starts \
            location services, never reads your current position, and needs no Core Location \
            permission.

            routes_summary.csv has one row per workout, including workouts with no route. \
            Workouts that do have a route also get routes/route_<workoutUUID>.csv (every GPS \
            point) and routes/route_<workoutUUID>.gpx (standard GPX 1.1, openable in common \
            mapping tools). Route points from all of a workout's route samples are merged into \
            one chronological set; routeCount still reports how many HealthKit route samples \
            were found.

            GPS data from a consumer watch or phone carries normal inaccuracies. Horizontal \
            accuracy is exported per point, plus average and median accuracy per route, so you \
            can judge how much to trust a track. Core Location marks unavailable readings with \
            negative sentinel values; those are exported as blank fields, never as real \
            measurements.

            Elevation gain and loss are ESTIMATES, not surveyed elevation. GPS altitude is \
            noisy, so vertical changes smaller than \
            \(RouteMath.elevationNoiseThresholdMeters) m between sequential accepted points are \
            ignored as noise; larger rises are added to gain and larger drops to loss. Only \
            points whose vertical accuracy was valid are used. The threshold is recorded as \
            elevation_noise_threshold_meters in manifest.json.

            Route distance is measured along the recorded GPS points, independently of the \
            workout's own total-distance value, so the two can legitimately differ. The route \
            centroid is a plain arithmetic mean of latitude and longitude — adequate for short \
            local routes, not a great-circle centroid. Average route speed is route distance \
            divided by elapsed route time.

            PRIVACY: route data reveals where you live, work, and run, and habitual routes and \
            times. Treat these files as sensitive and share them deliberately.
            """
        } else {
            routeSection = """
            GPS ROUTES
            GPS route export was switched OFF for this export. No route data was requested, no \
            routes/ folder was created, and routes_summary.csv reports routeAvailable=false for \
            every workout. This says nothing about whether route data exists in HealthKit. See \
            "route_export" in manifest.json.
            """
        }

        let activitySection: String
        if options.includeWalking {
            activitySection = """
            ACTIVITY TYPES
            Both running and walking workouts are included. Walking is kept because a run/walk \
            session is occasionally recorded by the Watch as "Outdoor Walk" rather than \
            "Outdoor Run".
            """
        } else {
            activitySection = """
            ACTIVITY TYPES
            ONLY RUNNING workouts are included. Walking workouts were deliberately excluded from \
            this export and are absent from workouts.csv, routes and the record windows.

            This is a filter, not an absence of data: the walks still exist in Apple Health. \
            workout_type_counts.json reports every workout type seen in the window under \
            "all_workout_types_in_window", including how many walks were skipped, and \
            manifest.json records "walking_included": false.

            One caveat worth knowing: a run/walk session is occasionally recorded by the Watch as \
            "Outdoor Walk" rather than "Outdoor Run". Any such session is excluded here too. Turn \
            "Include walking workouts" on in the app and re-export if you need them.
            """
        }

        return """
        This export was generated locally on iPhone from HealthKit.
        It includes \(options.includeWalking ? "running and walking" : "running") workouts from \
        June 18, 2026 through the export date, plus relevant HealthKit quantity samples such as \
        heart rate, distance, steps, energy, running speed, running dynamics, walking metrics, \
        resting heart rate, HRV, and VO2 Max when available.

        \(activitySection)

        Export mode: \(mode.displayName).
        In "Full date range" mode, quantity records span the whole window. In "Workout windows \
        only" mode, quantity records are limited to within \(ExportMode.workoutWindowBufferMinutes) \
        minutes before/after each running or walking workout; workouts and activity summaries \
        still cover the full range.

        \(weatherSection)

        \(routeSection)

        \(loggerSection(dataset: dataset, intervalAudio: intervalAudio))

        TIMESTAMPS
        CSV timestamps are ISO 8601 with the device's timezone offset. GPX timestamps are UTC \
        with a trailing Z, which is what GPX readers expect.

        ERRORS
        Missing weather or route data never fails an export. Anything skipped is recorded in \
        export_log.json, as both a flat "issues" list and structured "entries".

        PRIVACY
        This app makes no network requests, contains no analytics and no third-party SDKs, and \
        stores nothing on a server. No data was uploaded by this app. The ZIP was shared \
        manually using the iOS share sheet, and the app's temporary files are deleted after \
        sharing or cancelling.

        The iPhone app reads from HealthKit and never writes to it, so nothing in your Health \
        record was created or modified to produce this export. The companion Apple Watch app is \
        the one exception: it is permitted to save workouts it records, and only workouts. That \
        is a separate action from this export and does not alter any data exported here.
        """
    }

    /// Explains the v1.1 subjective files: what they are, and — more importantly — what a blank
    /// value in them does and does not mean.
    private func loggerSection(dataset: ExportDataset,
                               intervalAudio: IntervalAudioSettings) -> String {
        let logger = dataset.logger

        let availability: String
        if logger.storeUnavailable {
            availability = """
            The run logger database could NOT be opened for this export, so every logger file \
            below contains only its header row. This does not mean you have no logs — it means \
            they could not be read. See "run_logger" in manifest.json and the entries in \
            export_log.json.
            """
        } else {
            availability = """
            \(logger.runLogs.count) run log(s), \(logger.recoveryLogs.count) recovery log(s), \
            \(logger.plannedWorkouts.count) planned workout(s), \(logger.shoes.count) shoe(s) and \
            \(logger.intervalLogs.count) interval record(s) were exported. \
            \(logger.unloggedWorkoutCount) of the \(dataset.workouts.count) workout(s) in this \
            export have no run log.
            """
        }

        return """
        SUBJECTIVE RUN LOG
        Everything above this section is objective data Apple recorded. Everything in this section \
        was typed by the user in this app and stored locally with SwiftData. The two are kept in \
        separate columns and separate files on purpose — do not treat a subjective rating as a \
        measurement.

        \(availability)

        run_logs.csv        one row per logged workout: effort RPE, personal heat rating, body \
        signals, shoe, notes.
        recovery_logs.csv   optional next-day recovery ratings.
        shoes.csv           shoe profiles with derived mileage.
        planned_workouts.csv the interval plans defined in the app. A plan with \
        openIntervalTargetSeconds set is an OPEN INTERVAL plan: its running legs end when the \
        runner ends them, not on a clock, so it has no interval lengths and no round count and \
        those columns are BLANK. openIntervalWalkFloorSeconds is the shortest recovery walk it \
        allows. Such a plan's totalRunSeconds is its target, which is the one duration it fixes in \
        advance; the readings taken at the end of each leg are in workout_intervals.csv.
        planned_workout_blocks.csv the shape of every plan, one row per segment, in the order the \
        plan runs them. A plan can run segments of differing length — 5/1 x 1, then 8/1 x 2, then \
        5/1 x 1 — which one run length and one repetition count cannot describe. EVERY plan appears \
        here, including an ordinary 4/1 x 5, which is a plan of one segment; that way this file is \
        always the complete answer to what shape a plan is. Join on plannedWorkoutID, order by \
        orderIndex. NOTE: when a plan has more than one segment, runIntervalSeconds, \
        walkIntervalSeconds and plannedRepetitions in planned_workouts.csv are BLANK, because there \
        is no single honest value for them — read this file instead. Blank there does not mean \
        zero. The totalRunSeconds, totalWalkSeconds and mainSetSeconds columns stay populated for \
        every plan, because they sum all of its segments.
        workout_intervals.csv actual run/walk/cooldown boundaries recorded by the app's timer. \
        Seven further columns describe a leg of an OPEN INTERVAL workout — one whose running \
        legs end when the runner ends them rather than on a clock — and are BLANK on every other \
        run, which measures none of them. endReason says why a leg stopped: runnerEnded means the \
        runner called it, which is the measurement, while targetReached means the accumulated \
        running target ended the leg instead. The two are NOT distinguishable from duration, \
        which is why the reason is recorded rather than inferred. The five severity columns are \
        the 0-10 readings taken as the leg ended, and carry the SAME NAMES AND SCALE as the \
        severity columns in run_logs.csv on purpose: a leg's reading and a post-run reading are \
        one measurement taken at two moments. They are written together or not at all — the app \
        refuses to record a set of zeros nobody looked at — so BLANK means the question was never \
        answered and 0 means it was, and that area was fine. baselineReachedAt is the instant \
        during a recovery walk when the runner reported that signal gone, which is NOT the end of \
        the walk — the walk runs on to its floor and beyond, and the gap between this timestamp \
        and the walk's startDate is the recovery time the protocol exists to measure.
        pending_workout_executions.csv each attempt to perform a plan, and which HealthKit \
        workout it matched. blockShape records the shape that was actually run, as \
        300/60x1|480/60x2|300/60x1 — run seconds, walk seconds and repetitions per segment, \
        segments separated by |, or as open:1800/180 for an OPEN INTERVAL run — target seconds \
        then walk floor — which has no segments at all. When it names more than one segment, \
        runIntervalSeconds and \
        walkIntervalSeconds are BLANK, because no single value is true of that run; blank does not \
        mean zero. plannedRepetitions stays populated either way, since rounds are well defined \
        however many segments there were. An EMPTY blockShape means the session was recorded \
        before that column existed, and its own interval columns are the truth about it.
        body_signal_details.csv optional extra context on a body signal (timing, character, note).
        workout_notes.csv   free-text notes typed DURING a workout, one row each, with the phase \
        and repetition they were written in. Distinct from the notes column in run_logs.csv, which \
        is written once for the run as a whole: a note taken during walk 3 is a different \
        observation from one taken afterwards, and this file keeps them apart. Its phaseType and \
        repetitionNumber are recorded at capture and are the reliable link to a segment; see \
        READING workout_intervals.csv below before joining on timestamps instead.

        READING workout_intervals.csv: two properties of this file surprise people, and both are \
        deliberate. FIRST, sequenceIndex is the order records were written, not the order phases \
        started. A pause is written when you resume, so it gets a LOWER sequenceIndex than the \
        phase it interrupted — a pause taken during cooldown has a sequenceIndex one lower than \
        the cooldown containing it, even though the cooldown started first. Sort by startDate for \
        chronology. SECOND, a phase that was paused has its startDate shifted FORWARD by the time \
        spent paused, because actualDurationSeconds counts only running time. The phases therefore \
        do not tile the workout end to end: the gaps are the pauses, which are listed as their own \
        rows. Both matter when joining workout_notes.csv by time — widen the lower bound by any \
        pause inside the phase, or trust the note's own phaseType.

        JOINED COLUMNS: workouts.csv repeats the most useful of these fields so ordinary analysis \
        does not require joining every file. They are a convenience copy, never a second source of \
        truth — run_logs.csv is authoritative. A workout with no run log has every one of those \
        columns BLANK. Blank means "not logged". It never means zero, and zero never means \
        "not logged": a body-signal severity of 0 is a real answer meaning "nothing felt wrong".

        effortRPE is 1 (extremely easy) to 10 (maximum effort), half points allowed.

        personalHeatRating is 1 (felt cold), 5 (thermally neutral), 10 (severely overheated), half \
        points allowed. It is a SEPARATE, SUBJECTIVE field. It is not derived from the objective \
        weather columns, and the two are expected to disagree.

        Body-signal severities are 0-10 per area, defaulting to 0.

        SHOE MILEAGE is derived, not stored: a shoe's total is its startingMileage plus the \
        distance of every run log assigned to it. shoeMileageAtWorkoutMiles in workouts.csv is \
        that shoe's odometer immediately AFTER the workout on that row. Correcting a shoe \
        assignment therefore corrects every total, which is why no running total is kept.

        MAIN SET vs COOLDOWN: mainSetDurationSeconds counts only run and walk intervals. Cooldown \
        and paused time are reported separately and are never folded into the main set, so a long \
        open cooldown — or a twenty-minute conversation mid-cooldown — cannot distort main-set \
        timing.

        CUES: this export was created with cue_source "\(intervalAudio.cueSource)" and cue_mode \
        "\(intervalAudio.cueMode)". See "interval_audio" in manifest.json.
        """
    }

    /// Count occurrences by source name, mapping blank names to "Unknown".
    private func sourceCounts(_ names: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for name in names {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : name
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Every non-hidden file currently under `folder`, **recursively**, plus `extra` (the
    /// not-yet-written manifest), as relative paths — de-duplicated and sorted alphabetically.
    ///
    /// Recursion matters: route files live in `routes/`, and the manifest inventory has to match
    /// the ZIP's contents exactly. `ZipService` walks the same tree, so the two agree.
    ///
    /// Internal rather than private so the manifest/ZIP agreement can be verified directly.
    func fileList(in folder: URL, including extra: String) throws -> [String] {
        let fm = FileManager.default
        var names = Set<String>([extra])

        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadUnknown)
        }

        let baseComponents = folder.standardizedFileURL.pathComponents
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let relative = fileURL.standardizedFileURL.pathComponents
                .dropFirst(baseComponents.count)
                .joined(separator: "/")
            names.insert(relative)
        }

        return names.sorted()
    }

    private func write(_ data: Data, _ name: String, _ folder: URL) throws {
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Writes a CSV with a header row and zero or more data rows.
    private func writeCSV(columns: [String], rows: [[String]],
                          _ name: String, _ folder: URL) throws {
        var csv = CSVWriter(columns: columns)
        for row in rows { csv.addRow(row) }
        try write(csv.data, name, folder)
    }

    private func writeJSON(_ object: [String: Any], _ name: String, _ folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try write(data, name, folder)
    }

    private func folderDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
