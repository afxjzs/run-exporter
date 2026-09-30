import XCTest
@testable import RunExporter

/// The phone-side file that watch-link diagnostics are written to, so they can be pulled off the
/// phone with `devicectl device copy from` instead of read off a screen.
///
/// It exists because an on-screen log was cleared by accident mid-investigation and the evidence
/// went with it. A diagnostic file that silently fails to write would repeat that loss invisibly.
final class DiagnosticLogFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAppendsKeepTheirOrderOneLineEach() throws {
        let log = DiagnosticLogFile(url: directory.appendingPathComponent("a.log"))
        try log.append("one")
        try log.append("two")
        try log.append("three")
        XCTAssertEqual(try contents(of: log), "one\ntwo\nthree\n")
    }

    /// An error message with a newline in it must stay one entry, or a reader counts two events.
    func testANewlineInsideALineDoesNotSplitIt() throws {
        let log = DiagnosticLogFile(url: directory.appendingPathComponent("a.log"))
        try log.append("error: first part\nsecond part")
        let lines = try contents(of: log).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("first part"))
        XCTAssertTrue(lines[0].contains("second part"))
    }

    func testAWriteThatCannotHappenThrows() {
        let missingDirectory = directory.appendingPathComponent("does-not-exist", isDirectory: true)
        let log = DiagnosticLogFile(url: missingDirectory.appendingPathComponent("a.log"))
        XCTAssertThrowsError(try log.append("lost"))
    }

    private func contents(of log: DiagnosticLogFile) throws -> String {
        try String(contentsOf: log.url, encoding: .utf8)
    }
}
