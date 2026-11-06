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
            // The no-Watch alarm plays even with cues off, so without this every run in the
            // simulator, which has no Watch, would sound it through the Mac's speakers.
            "-uiTestingSilencesNoWatchAlarm",
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
            // Hidden, not removed: the owner has one pair, so the picker asked a question with one
            // answer. A new log still records that shoe through `defaultShoe()` — the data keeps
            // accruing, so bringing the screens back later leaves no gap.
            expectAbsent(app.buttons["Shoes"], "Shoes on Today")
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

        step("Plans: create an easy aerobic open-interval plan") {
            app.navigationBars["Plans"].buttons["Add"].tap()
            let openIntervals = app.buttons["Open intervals"]
            expect(openIntervals, "the Open intervals menu item")
            openIntervals.tap()
            expect(app.buttons["Save"], "Save in the open-interval editor")
            // An ordinary plan asks nothing about intensity beyond the one picker (aerobic spec §25).
            let target = app.staticTexts["Target effort"]
            expectAbsent(target, "the aerobic target before Easy aerobic is chosen")
            let intensity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                             "Intensity")).firstMatch
            expect(intensity, "the Intensity picker")
            intensity.tap()
            let aerobic = app.buttons["Easy aerobic"]
            expect(aerobic, "Easy aerobic in the Intensity picker")
            aerobic.tap()
            expect(target, "the aerobic target once Easy aerobic is chosen")
            snapshot("Open-interval editor with Easy aerobic chosen")
            // No scrolling in this editor: a swipe lands on its duration wheels and changes the plan.
            app.buttons["Save"].tap()
        }

        step("Open-interval plan detail: no Lap instruction") {
            let row = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", "Run to")).firstMatch
            expect(row, "the new open-interval plan in the list")
            row.tap()
            expect(app.buttons["Start Workout"], "Start Workout on the open-interval plan screen")
            let lap = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "use Lap")).firstMatch
            expectAbsent(lap, "the retired 'use Lap' instruction")
            snapshot("Open-interval plan detail")
        }

        step("Run the aerobic plan; its log asks the talk test") {
            app.buttons["Start Workout"].tap()
            expect(app.staticTexts["READY"], "the READY screen for the aerobic plan")
            app.buttons["Start"].tap()
            answerNoWatchWarning(with: runWithoutWatch)
            expect(app.buttons["End Workout"], "End Workout on the aerobic run")
            // The aerobic panel (aerobic spec §4). The simulator has no Watch, so its heart rate
            // must read as unavailable, never as a number (§6).
            expect(aerobicTarget, "the aerobic target on the aerobic run screen")
            expect(app.staticTexts["HR --"], "an unavailable heart rate with no Watch")
            snapshot("Aerobic run screen")
            endRunAndOpenLog()
            // Offered because the run was easy aerobic (aerobic spec §7), and unanswered until chosen.
            expect(talkTestPicker, "the Talk test picker on the aerobic run's log")
            XCTAssertTrue(talkTestPicker.label.contains("Not recorded"),
                          "The talk test should start at Not recorded; it reads \"\(talkTestPicker.label)\"")
            snapshot("Aerobic run log with the talk test")
            app.navigationBars["Log Run"].buttons["Cancel"].tap()
            expect(app.buttons["Start Workout"], "back on the plan screen after the aerobic run")
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
            // The owner had to scroll to reach Export. It must be on screen as the screen opens,
            // even with Health access not yet granted (the test never grants it), which is when the
            // screen has the most to show.
            let export = app.buttons["Export"]
            expect(export, "the Export button")
            XCTAssertTrue(export.isHittable, "Export is not on screen without scrolling")
            expect(app.buttons["Grant Health Access"], "the Health access prompt when not granted")
            // The default range, said on screen so the mode is never a guess.
            let lastWorkouts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                                    "Last 15 workouts")).firstMatch
            expect(lastWorkouts, "the Last 15 workouts default")
            // Retired: walks are kept by rule now, and the explanations live in Settings.
            expectAbsent(app.switches["Include walking workouts"], "the walking toggle")
            let footnote = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                                "Only running workouts are read")).firstMatch
            expectAbsent(footnote, "the walking footnote")
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
            // Chosen to run on: the screen must then say the run carries on without the Watch.
            answerNoWatchWarning(with: runWithoutWatch)
            expect(app.buttons["End Workout"], "End Workout on the run screen")
            let phoneOnly = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                                 "continues on the phone only")).firstMatch
            expect(phoneOnly, "the run screen saying the run continues on the phone only")
            expect(app.buttons["Try again"], "Try again after the Watch failed")
            // Drawn in the same pass as End Workout, which is already on screen, so this absence
            // is a fact about the screen rather than about timing.
            expectAbsent(aerobicTarget, "the aerobic panel on an ordinary run")
        }

        step("End the ordinary run; its log does not ask the talk test") {
            endRunAndOpenLog()
            // The rating row renders in the same pass as the talk test would, so waiting for it
            // first means the absence below is a fact about the form, not about timing.
            expect(app.staticTexts["Effort (RPE)"], "the form's required ratings")
            expectAbsent(talkTestPicker, "the talk test on an ordinary run's log (§7)")
            app.navigationBars["Log Run"].buttons["Cancel"].tap()
            expect(app.buttons["Start Workout"], "back on Today after the run")
        }

        step("Start with no Watch, and stop to go and get it") {
            app.buttons["Start Workout"].tap()
            expect(app.staticTexts["READY"], "the READY screen")
            app.buttons["Start"].tap()
            answerNoWatchWarning(with: stopForWatch)
            // Stopping abandons the run: no end confirmation, no log prompt, straight back.
            expect(app.buttons["Start Workout"], "back on Today after stopping for the Watch")
            expectAbsent(app.alerts["Workout complete"], "a log prompt for the abandoned run")
        }
        // No closing "no sheet appeared" wait: the sheet has arrived as late as 27 s after its
        // request, so a 5 s wait passed whenever it was merely late. The launch flag is proved by
        // Today's own state in the first step instead.
    }

    // MARK: - Helpers

    /// Ends the run on screen and opens its log. The simulator has no Watch workout to match, so
    /// the run is logged without one, through "Log it anyway".
    private func endRunAndOpenLog() {
        app.buttons["End Workout"].tap()
        let endAlert = app.alerts["End this workout?"]
        expect(endAlert, "the end confirmation")
        endAlert.buttons["End workout"].tap()
        let complete = app.alerts["Workout complete"]
        expect(complete, "the workout-complete prompt")
        complete.buttons["Log it now"].tap()
        let noWorkout = app.alerts["No Apple Watch workout found"]
        expect(noWorkout, "the no-workout prompt")
        noWorkout.buttons["Log it anyway"].tap()
        expect(app.navigationBars["Log Run"], "the run log form")
    }

    /// Waits for the no-Watch warning and answers it. The simulator has no Watch, so every run's
    /// launch fails, at once or at the 15 s timeout; waiting for the warning before anything else on
    /// the run screen keeps a late warning from landing on top of a later tap.
    private func answerNoWatchWarning(with choice: XCUIElement) {
        let warning = app.staticTexts["NO WATCH"]
        XCTAssertTrue(warning.waitForExistence(timeout: 25),
                      "The run started with no Watch and the no-Watch warning never appeared")
        snapshot("No-Watch warning")
        expect(runWithoutWatch, "Run without Watch on the warning")
        expect(stopForWatch, "Stop on the warning")
        choice.tap()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5),
                      "The no-Watch warning stayed up after it was answered")
    }

    private var runWithoutWatch: XCUIElement { app.buttons["Run without Watch"] }
    private var stopForWatch: XCUIElement { app.buttons["Stop — I'll get my Watch"] }

    private var aerobicTarget: XCUIElement {
        app.staticTexts["RPE 3–4 · conversational"]
    }

    private var talkTestPicker: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talk test")).firstMatch
    }

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
