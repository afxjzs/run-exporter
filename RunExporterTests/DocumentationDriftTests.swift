import XCTest

/// Fails when a document quotes a control the app does not have.
///
/// Two documents instructed the reader to press **"Remove all workouts from Watch"** and to confirm
/// the screen reported **"Workout sent to Apple Watch"**. Both instructions were correct when
/// written. `8d145b9`, on 2026-09-07, renamed the first to **"Clear this iPhone's queue"** — named
/// for what it actually does, since it never could reach the Watch — and deleted the second. The
/// documents were not touched, and for eighteen days told readers to press buttons that were gone.
///
/// **Nobody invented anything, which is the whole lesson.** An ordinary rename, made for a good
/// reason, with a careful comment explaining itself, was enough. Whoever renames a control cannot be
/// expected to remember which of nine documents quote it — so the check belongs here, where it costs
/// one test run instead of one reader's afternoon.
///
/// A button name is the one part of a document a machine can verify, so it is verified.
///
/// **Adding to `labels` is the maintenance cost, and it is the point.** When a document starts
/// quoting a new control, add it. When a label is renamed, this test names every document that has
/// to change with it — which is the thing a human sweep reliably misses.
final class DocumentationDriftTests: XCTestCase {

    /// A UI string some document depends on, and where it is quoted.
    private struct QuotedLabel {
        let text: String
        /// Repo-relative paths. Checked in both directions: the label must still be in the app, and
        /// it must still be in each of these files, so a stale entry fails rather than rotting.
        let citedBy: [String]
    }

    /// Verified against the source on 2026-09-25. Every entry existed in both places when added.
    private static let labels: [QuotedLabel] = [
        .init(text: "Start Audio Timer",
              citedBy: ["README.md", "docs/CUE_FEASIBILITY_TEST.md", "RUNNING_APP_V1_1_SPEC.md",
                        "docs/BACKLOG.md"]),
        .init(text: "Start next leg",
              citedBy: ["README.md", "docs/BACKLOG.md"]),
        .init(text: "End this leg",
              citedBy: ["docs/BACKLOG.md"]),
        .init(text: "Back to baseline",
              citedBy: ["README.md"]),
        .init(text: "Add note",
              citedBy: ["README.md", "docs/BACKLOG.md"]),
        .init(text: "Include walking workouts",
              citedBy: ["README.md"]),
        .init(text: "Edit log",
              citedBy: ["README.md", "LEARNINGS.md"]),
        .init(text: "Log it anyway",
              citedBy: ["LEARNINGS.md"]),
        .init(text: "Use it anyway",
              citedBy: ["docs/BACKLOG.md"]),
        .init(text: "No Apple Watch workout found",
              citedBy: ["README.md", "LEARNINGS.md", "docs/BACKLOG.md"]),
        // Added 2026-09-29 with the watch development runbook.
        .init(text: "Watch link test",
              citedBy: ["docs/WATCH_DEVELOPMENT.md", "docs/BACKLOG.md"]),
        // Added 2026-09-29 with the clean-out backlog entry.
        .init(text: "Export Data",
              citedBy: ["docs/BACKLOG.md"]),
        .init(text: "Start watch workout",
              citedBy: ["docs/WATCH_DEVELOPMENT.md"]),
        .init(text: "Reset this screen",
              citedBy: ["docs/WATCH_DEVELOPMENT.md"]),
    ]

    // MARK: - Locating the repository

    /// The repo root, derived from this file's own compile-time path.
    ///
    /// `#filePath` is the only handle a test has on the source tree: the bundle carries compiled
    /// code, not the documents being checked. Tests therefore have to run on the machine that built
    /// them, which is already true of every other suite here.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)        // …/RunExporterTests/DocumentationDriftTests.swift
            .deletingLastPathComponent()       // …/RunExporterTests
            .deletingLastPathComponent()       // repo root
    }

    /// Every `.swift` file in the app target, concatenated, plus how many were read.
    ///
    /// The count is returned so the caller can assert it. A silent enumerator failure would make
    /// every `contains` check below run against an empty string and pass — which is precisely the
    /// vacuous-test trap `LoggerStoreMigrationTests` exists to remember. Assert the premise.
    private static func appSources() throws -> (text: String, fileCount: Int) {
        let root = repoRoot.appendingPathComponent("RunExporter", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            throw DriftError.directoryUnreadable(root.path)
        }

        var combined = ""
        var count = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            combined += try String(contentsOf: url, encoding: .utf8)
            count += 1
        }
        return (combined, count)
    }

    /// A document's text with every run of whitespace collapsed to one space.
    ///
    /// Markdown wraps at the column, not at the phrase, so a quoted label is regularly split across
    /// a line break — `README.md` holds `**Start\nnext leg**` today. Comparing raw text would report
    /// that as missing and teach everyone to distrust this test.
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func document(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DriftError.documentUnreadable(relativePath)
        }
        return normalized(text)
    }

    private enum DriftError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case documentUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "Could not enumerate \(path)"
            case .documentUnreadable(let path):
                return "Could not read \(path) — was it moved or renamed without updating this test?"
            }
        }
    }

    // MARK: - Tests

    /// Every label a document quotes still exists in the app.
    ///
    /// This is the direction that catches the original bug: a control renamed or removed while the
    /// documents telling people to press it stay exactly as they were.
    func testEveryQuotedLabelStillExistsInTheApp() throws {
        let (sources, fileCount) = try Self.appSources()

        XCTAssertGreaterThan(fileCount, 50,
                             "Only \(fileCount) source files were read, so the checks below would "
                                 + "pass against almost nothing. Fix the traversal, not this number.")
        XCTAssertFalse(Self.labels.isEmpty, "An empty registry makes this suite vacuous")

        for label in Self.labels {
            XCTAssertTrue(sources.contains(label.text),
                          "No source file contains \"\(label.text)\", but it is quoted by "
                              + label.citedBy.joined(separator: ", ")
                              + ". Either the control was renamed and those documents now tell the "
                              + "reader to press something that does not exist, or this entry is "
                              + "obsolete and should be removed.")
        }
    }

    /// Every registered label is still quoted where the registry says it is.
    ///
    /// Without this the registry rots in the other direction: entries accumulate for documents that
    /// stopped mentioning them, the list stops describing anything real, and the suite above keeps
    /// passing while protecting less and less.
    func testEveryRegisteredLabelIsStillQuotedWhereItSaysItIs() throws {
        for label in Self.labels {
            for path in label.citedBy {
                let text = try Self.document(path)
                XCTAssertTrue(text.contains(label.text),
                              "\(path) no longer quotes \"\(label.text)\". Drop that path from the "
                                  + "entry in DocumentationDriftTests — a registry that names files "
                                  + "which do not mention the label protects nothing.")
            }
        }
    }

    /// A label that was real and is not any more.
    private struct RetiredLabel {
        let text: String
        /// What retired it: a commit, or `cleanOut` for the labels the 2026-09-29 clean-out removed.
        /// Any document still mentioning the label must cite this, so a reader who goes looking for
        /// the control is told where it went. The clean-out is cited by name rather than hash
        /// because its decisions are recorded, with reasons, in docs/BACKLOG.md.
        let retiredIn: String
        let replacement: String?
    }

    private static let cleanOut = "2026-09-29 clean-out"

    private static let retiredLabels: [RetiredLabel] = [
        // Its replacement, "Clear this iPhone's queue", was itself removed by the clean-out.
        .init(text: "Remove all workouts from Watch", retiredIn: "8d145b9", replacement: nil),
        .init(text: "Workout sent to Apple Watch", retiredIn: "8d145b9", replacement: nil),
        // The WorkoutKit route to the Watch, superseded by Start launching this app's own watch
        // workout.
        .init(text: "Send to Apple Watch", retiredIn: cleanOut, replacement: nil),
        .init(text: "Add to Apple Watch", retiredIn: cleanOut, replacement: nil),
        .init(text: "Schedule for a time", retiredIn: cleanOut, replacement: nil),
        .init(text: "Clear this iPhone's queue", retiredIn: cleanOut, replacement: nil),
        // The on-device cue harness; its tests are done and recorded.
        .init(text: "Cue test", retiredIn: cleanOut, replacement: nil),
    ]

    /// Every document that names a retired control also says where it went.
    ///
    /// Mentioning one is legitimate — `MISTAKES.md` records advice given while the button still
    /// existed, and deleting that would falsify the history. What is not legitimate is naming it
    /// bare, because a reader today goes looking for a control that is not there. Citing the commit
    /// is the cheapest fix that stays true as the code moves on.
    func testDocumentsNamingARetiredControlSayWhereItWent() throws {
        let documents = ["README.md", "CLAUDE.md", "LEARNINGS.md", "MISTAKES.md",
                         "docs/BACKLOG.md", "docs/CUE_FEASIBILITY_TEST.md", "docs/INSTALLS.md",
                         "docs/WATCHOS_RECORDER_PLAN.md", "docs/WATCH_DEVELOPMENT.md",
                         "RUNNING_APP_V1_1_SPEC.md"]

        for path in documents {
            let text = try Self.document(path)
            for retired in Self.retiredLabels where text.contains(retired.text) {
                let wentTo = retired.replacement.map { " It is now \"\($0)\"." } ?? ""
                XCTAssertTrue(text.contains(retired.retiredIn),
                              "\(path) names the retired control \"\(retired.text)\" without citing "
                                  + "\(retired.retiredIn), the commit that retired it.\(wentTo) "
                                  + "Mentioning it is fine; leaving a reader to hunt for it is not.")
            }
        }
    }

    /// A retired label is gone from the app, which is what makes it retired.
    ///
    /// Guards the registry above from describing something that is not true any more — if a label
    /// came back, every "where it went" note pointing at its removal would be wrong.
    func testRetiredLabelsAreActuallyGoneFromTheApp() throws {
        let (sources, fileCount) = try Self.appSources()
        XCTAssertGreaterThan(fileCount, 50, "Read \(fileCount) files; the check below is vacuous")

        for retired in Self.retiredLabels {
            XCTAssertFalse(sources.contains(retired.text),
                           "\"\(retired.text)\" is back in the source, but the documents describe "
                               + "it as retired in \(retired.retiredIn). Remove it from "
                               + "retiredLabels and add it to labels instead.")
        }
    }
}
