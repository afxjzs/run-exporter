import XCTest

/// End-to-end smoke test: drives the real app in the simulator through every tab and the run screen,
/// and saves a screenshot at each step.
///
/// Written after the 2026-09-29 clean-out (docs/BACKLOG.md) to show the app still works with the
/// removed screens gone. It checks that each removed control is **absent**, not only that the
/// remaining ones are present — a smoke test that only looks for what should be there would pass
/// with every deleted screen restored.
///
/// What the simulator cannot show: the Watch. `startWatchApp` has no Watch to reach, so the run
/// screen is expected to report that the run continues on the phone only. That is the failure path
/// working; the Watch path itself needs the device.
///
/// Run it with `scripts/smoke-test.sh`, which starts from a clean install and exports the
/// screenshots to a folder.
///
/// **No Health permission sheet.** The app is launched with `-uiTestingSkipsHealthAuthorization`,
/// which a Debug build honors by not requesting HealthKit access (`UITesting`). The sheet used to
/// appear here at an unpredictable time, queue a second one, and replace itself mid-tap; dismissing
/// it from the test failed three runs in five on 2026-09-30. The test now asserts the sheet never
/// shows, so a request the flag does not cover fails loudly instead of flaking.
final class SmokeTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-uiTestingSkipsHealthAuthorization",
            // Cues off for this launch only, through UserDefaults' argument domain — LoggerDefaults
            // reads `.standard`, and `cue.source` = `none` is "Play cues" off. The simulator plays
            // through the Mac's speakers, and every run announced "3, 2, 1, Run" out loud.
            "-cue.source", "none",
        ]
    }

    func testWalkThroughTheApp() {
        app.launch()

        step("Today, before any plan") {
            tapTab("Today")
            // The deterministic check that Health was not asked: while a request is pending, Today
            // says "Reading Health…" — and whether the system's sheet has appeared yet is not
            // predictable (a run on 2026-09-30 passed a sheet check while the request sat pending).
            // With the launch flag honored, the app skips the read and settles on this instead.
            expect(app.staticTexts["No running or walking workouts found yet."],
                   "Today finished without waiting on Health")
            expect(app.buttons["Export Data"], "Export Data on Today")
            expect(app.buttons["Shoes"], "Shoes on Today")
            expectAbsent(app.buttons["Send to Apple Watch"], "WorkoutKit send link")
        }

        step("Plans: create a plan from a preset") {
            tapTab("Plans")
            let preset = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "4/1 × 5")).firstMatch
            expect(preset, "the 4/1 × 5 preset")
            preset.tap()
        }

        step("Plan detail: Start Workout, no send route") {
            let row = app.cells.containing(.staticText, identifier: "4/1 × 5").firstMatch
            expect(row, "the new 4/1 × 5 plan in the list")
            row.tap()
            expect(app.buttons["Start Workout"], "Start Workout on the plan screen")
            expectAbsent(app.buttons["Send to Apple Watch"], "WorkoutKit send link")
            snapshot("Plan detail, before going back")
            app.navigationBars.buttons.firstMatch.tap()
        }

        step("Plans: create an open-interval plan") {
            app.navigationBars["Plans"].buttons["Add"].tap()
            let openIntervals = app.buttons["Open intervals"]
            expect(openIntervals, "the Open intervals menu item")
            openIntervals.tap()
            expect(app.buttons["Save"], "Save in the open-interval editor")
            app.buttons["Save"].tap()
        }

        step("Open-interval plan detail: no Lap instruction") {
            let row = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", "Run to")).firstMatch
            expect(row, "the new open-interval plan in the list")
            row.tap()
            expect(app.buttons["Start Workout"], "Start Workout on the open-interval plan screen")
            let lap = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "use Lap")).firstMatch
            expectAbsent(lap, "the retired 'use Lap' instruction")
            snapshot("Open-interval plan detail, before going back")
            app.navigationBars.buttons.firstMatch.tap()
        }

        step("History") {
            tapTab("History")
            expect(app.navigationBars["History"], "the History screen")
        }

        step("Settings: Play cues, no removed diagnostics") {
            tapTab("Settings")
            expect(app.switches["Play cues"], "the Play cues toggle")
            expectAbsent(app.buttons["Cue test"], "the Cue test link")
            expectAbsent(app.buttons["Watch link test"], "the Watch link test link")
            expectAbsent(app.buttons["Export Data"], "the Settings Export Data link")
            expectAbsent(app.staticTexts["Cue source"], "the old Cue source picker")
        }

        step("Export Data opens from Today") {
            tapTab("Today")
            app.buttons["Export Data"].tap()
            expect(app.navigationBars["Export Data"], "the export screen")
            snapshot("Export screen, before going back")
            app.navigationBars.buttons.firstMatch.tap()
        }

        step("Start Workout opens the READY screen") {
            expect(app.buttons["Start Workout"], "Start Workout on Today")
            app.buttons["Start Workout"].tap()
            expect(app.staticTexts["READY"], "the READY screen")
        }

        step("Start: the run screen, and the Watch failure reported") {
            app.buttons["Start"].tap()
            expect(app.buttons["End Workout"], "End Workout on the run screen")
            // The simulator has no Watch. The launch fails at once or after the 15 s timeout, and
            // either way the screen must say the run carries on without it.
            let phoneOnly = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                                 "continues on the phone only")).firstMatch
            XCTAssertTrue(phoneOnly.waitForExistence(timeout: 25),
                          "The run screen never said the run continues on the phone only")
            expect(app.buttons["Try again"], "Try again after the Watch failed")
        }

        step("End the workout") {
            app.buttons["End Workout"].tap()
            let endAlert = app.alerts["End this workout?"]
            expect(endAlert, "the end confirmation")
            endAlert.buttons["End workout"].tap()
            let complete = app.alerts["Workout complete"]
            expect(complete, "the workout-complete prompt")
            complete.buttons["Later"].tap()
            expect(app.buttons["Start Workout"], "back on Today after the run")
        }

        // Last, with a wait: the sheet has arrived as late as 27 s after its request, and both
        // requests — the logger's at launch and the Watch launch's at Start — are behind us now.
        XCTAssertFalse(healthSheet.waitForExistence(timeout: 5),
                       "A Health permission sheet appeared despite -uiTestingSkipsHealthAuthorization")
    }

    // MARK: - Helpers

    /// Runs one named step and attaches a screenshot of where it ended — or where it failed.
    private func step(_ name: String, _ body: () -> Void) {
        XCTAssertFalse(healthSheet.exists,
                       "A Health permission sheet is showing before \"\(name)\"; the launch flag "
                           + "did not cover some HealthKit request")
        XCTContext.runActivity(named: name) { activity in
            defer { activity.add(screenshot(named: name)) }
            body()
        }
    }

    /// A screenshot mid-step, for a screen the step leaves before it ends — otherwise the evidence
    /// would show where the step went back to, not the screen it checked.
    private func snapshot(_ name: String) {
        add(screenshot(named: name))
    }

    /// A kept, named screenshot of the app as it is now.
    private func screenshot(named name: String) -> XCTAttachment {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        return shot
    }

    private func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        expect(tab, "the \(name) tab")
        tab.tap()
    }

    private func expect(_ element: XCUIElement, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Not found: \(what)",
                      file: file, line: line)
    }

    private func expectAbsent(_ element: XCUIElement, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(element.exists, "Should be gone but is present: \(what)",
                       file: file, line: line)
    }

    /// The Health permission sheet's decline button. The sheet belongs to its own process,
    /// `com.apple.HealthPrivacyService` — in neither the app's element tree nor SpringBoard's — and
    /// `UIA.Health.DoNotAllow.Button` is the system's own identifier for it.
    private var healthSheet: XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
            .buttons["UIA.Health.DoNotAllow.Button"]
    }
}
