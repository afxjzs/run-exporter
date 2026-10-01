import HealthKit
import XCTest
@testable import RunExporter

/// End-to-end checks on the files an export produces: that every expected file is written, that
/// the ZIP is a real ZIP, and that the manifest's inventory matches the archive exactly.
///
/// These run the real `ExportBuilder`, `ZipService` and `CSVWriter`. HealthKit returns nothing in
/// the test environment, which is fine — the point is the file layer, and an export with no
/// workouts must still produce a complete, valid archive.
final class ExportPipelineTests: XCTestCase {

    private var builder: ExportBuilder!

    override func setUp() {
        super.setUp()
        builder = ExportBuilder(health: HealthKitManager(), appVersion: "1.1.0-test")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory
                .appendingPathComponent("running_health_export", isDirectory: true))
        builder = nil
        super.tearDown()
    }

    private var audioSettings: IntervalAudioSettings {
        IntervalAudioSettings(cueSource: CueSource.iphoneAudioEngine.rawValue,
                              cueMode: CueMode.voiceAndBeeps.rawValue,
                              countdownSeconds: 3,
                              fiveSecondWarning: false,
                              finalRoundAnnouncement: true,
                              halfwayAnnouncement: false,
                              transitionCountdown: false,
                              duckOtherAudio: true)
    }

    /// Writes a complete export from a prepared dataset and zips it, exercising the real file
    /// writer, manifest builder and ZIP writer.
    ///
    /// Deliberately does not go through `build`, which reads HealthKit: an unauthorized store in
    /// the test environment would fail every one of these for a reason that has nothing to do
    /// with the file layer under test.
    ///
    /// **Nothing covers the `build` path today.** This comment used to say
    /// `testBuildSurfacesHealthKitFailure` did, and that test was removed on 2026-09-30 for passing
    /// whether `build` threw or not — so it never covered the path it was credited with. Covering
    /// it properly means a fake store; see the entry in `docs/BACKLOG.md`.
    private func runExport(logger: LoggerExportData = LoggerExportData(),
                           workouts: [WorkoutExportRow] = [],
                           includeWalking: Bool = false,
                           reclassified: Set<UUID> = []) throws -> ExportBuilder.Result {
        let fm = FileManager.default
        let exportFolder = fm.temporaryDirectory
            .appendingPathComponent("running_health_export", isDirectory: true)
        try? fm.removeItem(at: exportFolder)
        let extractFolder = exportFolder
            // Shaped like a real export folder — start date to the date it was taken. A fixture,
            // not an assertion: this helper writes the files directly rather than going through
            // `build`, which is where the name is actually decided.
            .appendingPathComponent("running_health_extract_2026-06-18_to_2026-09-23",
                                    isDirectory: true)
        try fm.createDirectory(at: extractFolder, withIntermediateDirectories: true)

        var dataset = ExportDataset()
        dataset.workouts = workouts
        var loggerData = logger
        for index in dataset.workouts.indices {
            if let join = loggerData.join(forWorkoutUUID: dataset.workouts[index].uuid) {
                dataset.workouts[index].loggerValues = join.values
            } else {
                loggerData.unloggedWorkoutCount += 1
            }
        }
        dataset.logger = loggerData

        let start = Date(timeIntervalSinceReferenceDate: 0)
        let createdAt = Date()
        try builder.writeFiles(dataset: dataset,
                               into: extractFolder,
                               programStart: start,
                               queryStart: start,
                               queryEnd: start.addingTimeInterval(86_400),
                               mode: .fullDateRange,
                               options: ExportOptions(includeWeather: true, includeRoutes: false,
                                                      includeWalking: includeWalking,
                                                      reclassifiedAsRunning: reclassified),
                               intervalAudio: audioSettings,
                               createdAt: createdAt)

        let zipURL = exportFolder.appendingPathComponent("export.zip")
        try ZipService.zipFolder(at: extractFolder, to: zipURL, entryDate: createdAt)

        return ExportBuilder.Result(exportFolder: exportFolder,
                                    extractFolder: extractFolder,
                                    zipURL: zipURL)
    }

    // MARK: - Files

    /// Both the v1.0 files and the v1.1 additions must be present.
    func testExportWritesEveryExpectedFile() throws {
        let result = try runExport()
        let fm = FileManager.default

        let v1Files = ["workouts.csv", "records.csv", "activity_summaries.csv",
                       "routes_summary.csv", "manifest.json", "export_log.json",
                       "workout_type_counts.json", "records_by_type.json", "README.txt"]
        let v11Files = ["planned_workouts.csv", "planned_workout_blocks.csv",
                        "run_logs.csv", "recovery_logs.csv",
                        "shoes.csv", "workout_intervals.csv",
                        "pending_workout_executions.csv", "body_signal_details.csv",
                        "workout_notes.csv"]

        for name in v1Files + v11Files {
            let url = result.extractFolder.appendingPathComponent(name)
            XCTAssertTrue(fm.fileExists(atPath: url.path), "Missing \(name)")
        }
    }

    /// An empty logger still writes header rows, so "no data yet" is distinguishable from
    /// "this export predates the logger".
    func testEmptyLoggerFilesStillHaveHeaders() throws {
        let result = try runExport()

        let runLogs = try String(contentsOf: result.extractFolder
            .appendingPathComponent("run_logs.csv"), encoding: .utf8)
        let lines = runLogs.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 1, "Header only")
        XCTAssertEqual(lines[0], CSVWriter.encodeRow(RunLogExportRow.columns))
    }

    func testWorkoutsCSVHeaderMatchesDeclaredColumns() throws {
        let result = try runExport()

        let csv = try String(contentsOf: result.extractFolder
            .appendingPathComponent("workouts.csv"), encoding: .utf8)
        let header = csv.components(separatedBy: "\r\n")[0]

        XCTAssertEqual(header, CSVWriter.encodeRow(WorkoutExportRow.columns))
    }

    // MARK: - Activity type filtering

    /// Excluding walks must be recorded, not silent. A reader who finds no walking workouts has to
    /// be able to tell "filtered out" from "this person never walked".
    func testExcludingWalkingIsRecordedInManifestAndReadme() throws {
        let result = try runExport(includeWalking: false)
        let manifest = try loadManifest(result)

        XCTAssertEqual(manifest["walking_included"] as? Bool, false)
        XCTAssertEqual(manifest["workout_types_to_keep"] as? [String], ["running"])

        let readme = try String(contentsOf: result.extractFolder
            .appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("ONLY RUNNING"),
                      "README.txt must state that walking was excluded")
        XCTAssertTrue(readme.contains("still exist in Apple Health"),
                      "README.txt must make clear this is a filter, not missing data")
    }

    func testIncludingWalkingIsRecorded() throws {
        let result = try runExport(includeWalking: true)
        let manifest = try loadManifest(result)

        XCTAssertEqual(manifest["walking_included"] as? Bool, true)
        XCTAssertEqual(manifest["workout_types_to_keep"] as? [String], ["running", "walking"])
    }

    /// The rule itself, used by the export, the logger queue and History alike.
    func testActivityTypeRule() {
        XCTAssertTrue(HealthKitManager.keeps(.running, includeWalking: false))
        XCTAssertTrue(HealthKitManager.keeps(.running, includeWalking: true))

        XCTAssertFalse(HealthKitManager.keeps(.walking, includeWalking: false))
        XCTAssertTrue(HealthKitManager.keeps(.walking, includeWalking: true))

        // Nothing else is ever kept, whatever the walking setting says.
        for other in [HKWorkoutActivityType.cycling, .swimming, .hiking, .yoga] {
            XCTAssertFalse(HealthKitManager.keeps(other, includeWalking: true))
            XCTAssertFalse(HealthKitManager.keeps(other, includeWalking: false))
        }
    }

    // MARK: - Reclassified walks

    /// A walk the user marked as really a run must survive the walking filter — that is the
    /// entire purpose of the annotation.
    func testReclassifiedWalkIsKeptEvenWhenWalkingIsExcluded() {
        let target = UUID()
        let otherWalk = UUID()

        XCTAssertTrue(HealthKitManager.keeps(.walking, uuid: target,
                                             includeWalking: false,
                                             reclassifiedAsRunning: [target]))
        XCTAssertFalse(HealthKitManager.keeps(.walking, uuid: otherWalk,
                                              includeWalking: false,
                                              reclassifiedAsRunning: [target]))
    }

    /// Reclassification promotes walks; it never demotes runs or admits other activities.
    func testReclassificationNeverAffectsOtherTypes() {
        let id = UUID()
        XCTAssertTrue(HealthKitManager.keeps(.running, uuid: id, includeWalking: false,
                                             reclassifiedAsRunning: []))
        XCTAssertFalse(HealthKitManager.keeps(.cycling, uuid: id, includeWalking: true,
                                              reclassifiedAsRunning: [id]))
    }

    /// The export records the assertion without rewriting what Apple stored.
    func testReclassifiedWorkoutKeepsItsRecordedActivityType() throws {
        let walkUUID = UUID()
        var row = WorkoutExportRow(
            uuid: walkUUID.uuidString,
            workoutActivityType: "HKWorkoutActivityTypeWalking",
            workoutActivityTypeName: "walking",
            startDate: "", endDate: "", duration: "1",
            totalDistance: "1", totalDistanceUnit: "mi", totalDistanceMeters: "1609",
            totalEnergyBurned: "1", totalEnergyBurnedUnit: "kcal", totalEnergyKilocalories: "1",
            sourceName: "Apple Watch", sourceBundleIdentifier: "b", sourceVersion: "v",
            deviceName: "d", deviceJSON: "{}",
            metadataJSON: "{}", workoutEventsJSON: "[]", workoutStatisticsJSON: "[]")
        row.reclassifiedAsRunning = true

        let result = try runExport(workouts: [row], includeWalking: false)
        let csv = try String(contentsOf: result.extractFolder
            .appendingPathComponent("workouts.csv"), encoding: .utf8)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 2)
        let columns = WorkoutExportRow.columns
        let fields = lines[1].components(separatedBy: ",")

        let typeIndex = try XCTUnwrap(columns.firstIndex(of: "workoutActivityType"))
        XCTAssertEqual(fields[typeIndex], "HKWorkoutActivityTypeWalking",
                       "HealthKit's own value must never be rewritten by a user assertion")

        let flagIndex = try XCTUnwrap(columns.firstIndex(of: "reclassifiedAsRunning"))
        XCTAssertEqual(fields[flagIndex], "true")
    }

    func testManifestListsReclassifiedWorkouts() throws {
        let uuid = UUID()
        let result = try runExport(includeWalking: false, reclassified: [uuid])
        let manifest = try loadManifest(result)

        XCTAssertEqual(manifest["reclassified_as_running_count"] as? Int, 1)
        XCTAssertEqual(manifest["reclassified_as_running_uuids"] as? [String], [uuid.uuidString])
    }

    func testNoReclassificationsIsReportedAsZero() throws {
        let manifest = try loadManifest(runExport())
        XCTAssertEqual(manifest["reclassified_as_running_count"] as? Int, 0)
    }

    // MARK: - Manifest

    func testManifestContainsRunLoggerAndIntervalAudioBlocks() throws {
        var logger = LoggerExportData()
        logger.index()
        let result = try runExport(logger: logger)

        let manifest = try loadManifest(result)

        let runLogger = try XCTUnwrap(manifest["run_logger"] as? [String: Any])
        XCTAssertNotNil(runLogger["planned_workout_count"])
        XCTAssertNotNil(runLogger["run_log_count"])
        XCTAssertNotNil(runLogger["recovery_log_count"])
        XCTAssertNotNil(runLogger["shoe_count"])
        XCTAssertNotNil(runLogger["interval_log_count"])
        XCTAssertNotNil(runLogger["unlogged_workout_count"])

        let audio = try XCTUnwrap(manifest["interval_audio"] as? [String: Any])
        XCTAssertEqual(audio["cue_source"] as? String, "iphone_audio_engine")
        XCTAssertEqual(audio["cue_mode"] as? String, "voice_and_beeps")
        XCTAssertEqual(audio["countdown_seconds"] as? Int, 3)
    }

    /// v1.0 manifest keys must all survive.
    func testManifestKeepsV1Keys() throws {
        let manifest = try loadManifest(runExport())

        for key in ["app_name", "app_version", "export_created_at", "program_start_date",
                    "start_date", "end_date", "end_date_mode", "timezone", "export_mode",
                    "workout_types_to_keep", "record_types_requested", "workout_count",
                    "record_count", "weather_source", "weather_metadata", "route_export",
                    "files"] {
            XCTAssertNotNil(manifest[key], "manifest.json lost v1.0 key \"\(key)\"")
        }
    }

    /// The inventory must list every file, with no duplicates, recursively.
    func testManifestFileListHasNoDuplicatesAndIncludesItself() throws {
        let manifest = try loadManifest(runExport())
        let files = try XCTUnwrap(manifest["files"] as? [String])

        XCTAssertEqual(Set(files).count, files.count, "Duplicate manifest entries")
        XCTAssertTrue(files.contains("manifest.json"))
        XCTAssertEqual(files, files.sorted(), "File list must be deterministic")
    }

    /// The strongest invariant: what the manifest claims and what the ZIP holds must agree.
    func testManifestInventoryMatchesZipContentsExactly() throws {
        let result = try runExport()
        let manifest = try loadManifest(result)
        let claimed = Set(try XCTUnwrap(manifest["files"] as? [String]))

        let archived = try zipEntryNames(at: result.zipURL)
        // ZIP paths are prefixed with the top-level folder name.
        let prefix = result.extractFolder.lastPathComponent + "/"
        let stripped = Set(archived.map { $0.hasPrefix(prefix)
            ? String($0.dropFirst(prefix.count)) : $0 })

        XCTAssertEqual(claimed, stripped,
                       "manifest.json and the ZIP must describe the same set of files")
    }

    // MARK: - ZIP validity

    func testZipIsAWellFormedArchive() throws {
        let result = try runExport()
        let data = try Data(contentsOf: result.zipURL)

        XCTAssertGreaterThan(data.count, 22, "Smaller than an empty ZIP's EOCD record")
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04],
                       "Must start with a local file header signature")
        XCTAssertFalse(try zipEntryNames(at: result.zipURL).isEmpty)
    }

    /// Every entry's CRC must match its stored data, or the archive is corrupt.
    func testZipEntryChecksumsAreCorrect() throws {
        let entries = [
            ZipService.Entry(path: "a/one.csv", data: Data("hello,world\r\n".utf8),
                             modified: Date(timeIntervalSinceReferenceDate: 0)),
            ZipService.Entry(path: "a/two.txt", data: Data(repeating: 0x41, count: 5_000),
                             modified: Date(timeIntervalSinceReferenceDate: 0)),
        ]
        let archive = try ZipService.build(entries: entries)
        let central = try centralDirectoryRecords(in: archive)

        XCTAssertEqual(central.count, 2)
        for (index, record) in central.enumerated() {
            XCTAssertEqual(record.crc, ZipService.crc32(entries[index].data),
                           "CRC mismatch for \(record.name)")
            XCTAssertEqual(record.uncompressedSize, UInt32(entries[index].data.count))
        }
    }

    /// Spec: ZIP timestamps must be valid, not 1980 placeholders.
    func testZipTimestampsUseTheExportInstant() throws {
        let result = try runExport()
        let archive = try Data(contentsOf: result.zipURL)
        let records = try centralDirectoryRecords(in: archive)

        XCTAssertFalse(records.isEmpty)
        let years = Set(records.map { 1980 + Int(($0.dosDate >> 9) & 0x7F) })
        XCTAssertEqual(years.count, 1, "Every entry must carry the same export timestamp")

        let year = try XCTUnwrap(years.first)
        let currentYear = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(year, currentYear, "Entry dates must be the real export date")

        for record in records {
            let month = Int((record.dosDate >> 5) & 0x0F)
            let day = Int(record.dosDate & 0x1F)
            XCTAssertTrue((1...12).contains(month), "Invalid month \(month) in \(record.name)")
            XCTAssertTrue((1...31).contains(day), "Invalid day \(day) in \(record.name)")
        }
    }

    /// The month/day bit-packing regression the existing code documents.
    func testDosDateTimePacksMonthAndDayWithoutOverlap() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 6
        components.hour = 14; components.minute = 30; components.second = 44
        let date = try! XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        let (time, packedDate) = ZipService.dosDateTime(from: date)

        XCTAssertEqual(Int((packedDate >> 9) & 0x7F) + 1980, 2026)
        XCTAssertEqual(Int((packedDate >> 5) & 0x0F), 8)
        XCTAssertEqual(Int(packedDate & 0x1F), 6)
        XCTAssertEqual(Int((time >> 11) & 0x1F), 14)
        XCTAssertEqual(Int((time >> 5) & 0x3F), 30)
    }

    // MARK: - Cleanup

    // MARK: - Helpers

    private func loadManifest(_ result: ExportBuilder.Result) throws -> [String: Any] {
        let data = try Data(contentsOf: result.extractFolder
            .appendingPathComponent("manifest.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct CentralRecord {
        let name: String
        let crc: UInt32
        let uncompressedSize: UInt32
        let dosDate: UInt16
        let dosTime: UInt16
    }

    private func zipEntryNames(at url: URL) throws -> [String] {
        try centralDirectoryRecords(in: try Data(contentsOf: url)).map(\.name)
    }

    /// Minimal central-directory reader, so ZIP validity is checked by parsing the archive rather
    /// than by trusting the writer that produced it.
    private func centralDirectoryRecords(in data: Data) throws -> [CentralRecord] {
        let bytes = [UInt8](data)

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }

        // Find the End Of Central Directory record, searching backwards for its signature.
        var eocd = -1
        var index = bytes.count - 22
        while index >= 0 {
            if u32(index) == 0x0605_4b50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else {
            throw NSError(domain: "ZipTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No EOCD record found"])
        }

        let entryCount = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        var records: [CentralRecord] = []

        for _ in 0..<entryCount {
            guard u32(offset) == 0x0201_4b50 else {
                throw NSError(domain: "ZipTest", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "Bad central directory signature at \(offset)"])
            }
            let dosTime = u16(offset + 12)
            let dosDate = u16(offset + 14)
            let crc = u32(offset + 16)
            let compressed = Int(u32(offset + 20))
            let uncompressed = u32(offset + 24)
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))

            let nameBytes = bytes[(offset + 46)..<(offset + 46 + nameLength)]
            let name = String(decoding: nameBytes, as: UTF8.self)
            records.append(CentralRecord(name: name, crc: crc, uncompressedSize: uncompressed,
                                         dosDate: dosDate, dosTime: dosTime))
            _ = compressed
            offset += 46 + nameLength + extraLength + commentLength
        }
        return records
    }
}
