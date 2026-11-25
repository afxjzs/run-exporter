import XCTest

/// End-to-end smoke test: drives the real app in the simulator through every tab and the run screen,
/// and saves a screenshot at each step.
///
/// Written after the 2026-09-29 clean-out (docs/BACKLOG.md) to show the app still works with the
/// removed screens gone. It checks that each removed control is **absent**, not only that the
/// remaining ones are present — a smoke test that only looks for what should be there would pass
/// with every deleted screen restored.
///
/// What the simulator cannot show: the Watch. `startWatchApp` has no Watch to reach, so every run
/// raises the full-screen no-Watch warning, which pauses the run until it is answered
/// (`answerNoWatchWarning`). That is the failure path working; the Watch path itself needs the
/// device.
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

    /// History, redesigned 2026-11-24: runs only, grouped by week, filtered and grouped by kind,
    /// with a run's kind changeable on its detail screen.
    ///
    /// The simulator has no Health data, so this launches with `-uiTestingHistoryFixture`: a
    /// Debug-only set of invented runs in an in-memory store (`UITesting.historyFixture`). Each
    /// run's shape is chosen to be unique where the test needs to find one card.
    func testHistoryByWeekAndKind() {
        app.launchArguments.append("-uiTestingHistoryFixture")
        app.launch()

        step("History: this week against the goal, and runs grouped by week") {
            tapTab("History")
            expect(app.staticTexts["This week"], "the This week summary")
            let goal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "of 3 runs"))
            expect(goal.firstMatch, "this week's runs counted against three a week")
            expect(app.staticTexts["Last week"], "the Last week group")
            let endurance = card("6/1 × 4")
            expect(endurance, "the unlogged endurance run's card")
            XCTAssertTrue(endurance.label.contains("Endurance"),
                          "The card should name its kind; it reads \"\(endurance.label)\"")
            XCTAssertTrue(endurance.label.contains("Not logged"),
                          "The card should say it is not logged; it reads \"\(endurance.label)\"")
            expect(card("No route recorded"), "a card for the run with no route")
            // The old filters: History is runs only now, and logging state is a badge.
            expectAbsent(app.buttons["Unlogged"], "the old Logged/Unlogged filter")
            expectAbsent(app.buttons["Walks"], "the old Walks list")
        }

        step("One kind filters the cards") {
            app.buttons["Recovery"].tap()
            expect(card("3/1 × 6"), "a recovery run under Recovery")
            // Drawn in the same pass as the recovery card, so this absence is about the filter.
            expectAbsent(card("1/2 × 8"), "a speed run under Recovery")
            app.buttons["All"].tap()
            expect(card("1/2 × 8"), "the speed run back under All")
        }

        step("Group by kind") {
            app.buttons["By kind"].tap()
            expect(app.staticTexts["No kind"], "the group for runs without a kind")
            expect(card("4/1 × 5"), "the run with no kind, in its group")
            snapshot("History grouped by kind")
            app.buttons["By week"].tap()
            expect(app.staticTexts["Last week"], "back to weeks")
        }

        step("Charts compare runs of one kind, and say when there are too few") {
            // Recovery: three runs with legs and Watch heart rate, so both charts draw.
            app.buttons["Recovery"].tap()
            expect(app.staticTexts["Longest run leg · recovery runs"], "the longest-leg chart for recovery runs")
            expect(app.staticTexts["Efficiency · recovery runs"], "the efficiency chart for recovery runs")
            snapshot("Charts for recovery runs")
            // Speed: one of its three runs has no Watch heart rate, so efficiency has two points.
            app.buttons["Speed"].tap()
            expect(app.staticTexts["Needs 3 speed runs with Watch heart rate. You have 2."],
                   "efficiency saying how many more speed runs it needs")
            // Endurance: only two runs, so neither chart has enough.
            app.buttons["Endurance"].tap()
            expect(app.staticTexts["Needs 3 endurance runs with recorded legs. You have 2."],
                   "the longest-leg chart saying how many more endurance runs it needs")
            app.buttons["All"].tap()
        }

        step("A run's kind changes on its detail screen") {
            card("2/1 × 10").tap()
            let kind = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kind")).firstMatch
            expect(kind, "the Kind picker on the run's detail")
            kind.tap()
            let endurance = app.buttons["Endurance"]
            expect(endurance, "Endurance in the Kind picker")
            endurance.tap()
            snapshot("Run detail after changing its kind")
            app.navigationBars.buttons.firstMatch.tap()
            app.buttons["Endurance"].tap()
            expect(card("2/1 × 10"), "the re-tagged run under Endurance")
        }
    }

    func testWalkThroughTheApp() {
        app.launch()

        step("Today, before any plan") {
            tapTab("Today")
            // The deterministic check that Health was not asked: while a request is pending, Today
            // says "Reading Health…" — and whether the system's sheet has appeared yet is not
            // predictable (a run on 2026-09-30 passed a sheet check while the request sat pending).
            // With the launch flag honored, the app skips the read and settles on this instead.
            expect(app.staticTexts["No runs yet."],
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
            // A plan named after its shape says it once on the page (the title bar aside).
            expectOnce("4/1 × 5", in: app.collectionViews.firstMatch, "the plan's name and shape")
            // Hardcoded "Outdoor", never a setting: a WorkoutKit leftover.
            expectAbsent(app.staticTexts["Location"], "the Location row")
            snapshot("Plan detail, before going back")
            app.navigationBars.buttons.firstMatch.tap()
        }

        step("Duplicate opens the copy") {
            // The screen used to stay as it was, so nothing said the copy was made and the owner
            // tapped again, making more. One tap must land on the copy itself.
            app.cells.containing(.staticText, identifier: "4/1 × 5").firstMatch.tap()
            let duplicate = app.buttons["Duplicate"]
            expect(duplicate, "Duplicate on the plan screen")
            duplicate.tap()
            expect(app.navigationBars["4/1 × 5 copy"], "the copy's own screen after one tap")
            snapshot("The copy, opened by Duplicate")
            app.navigationBars.buttons.firstMatch.tap()
            expect(app.navigationBars["4/1 × 5"], "back on the original plan")
            app.navigationBars.buttons.firstMatch.tap()
            expect(app.navigationBars["Plans"], "back on the Plans list")
            let copies = app.cells.containing(.staticText, identifier: "4/1 × 5 copy")
            XCTAssertEqual(copies.count, 1, "One tap on Duplicate should make exactly one copy")
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
            // Every plan needs a kind, so History can compare like with like. There is no
            // default, on purpose: the owner wants to choose it every time.
            let save = app.buttons["Save"]
            XCTAssertFalse(save.isEnabled, "Save should stay disabled until a kind is chosen")
            let kind = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kind")).firstMatch
            expect(kind, "the Kind picker")
            kind.tap()
            let recovery = app.buttons["Recovery"]
            expect(recovery, "Recovery in the Kind picker")
            recovery.tap()
            XCTAssertTrue(save.isEnabled, "Save should be enabled once a kind is chosen")
            snapshot("Open-interval editor with Easy aerobic and Recovery chosen")
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

        step("Run the aerobic plan; its log does not ask the talk test") {
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
            // The talk test (aerobic spec §7) was dropped on 2026-11-24: the owner logs straight
            // after running and never once answered it. Not even an easy aerobic run asks it now.
            // Waiting for the ratings first makes the absence a fact about the form, not timing.
            expect(app.staticTexts["Effort (RPE)"], "the form's required ratings")
            expectAbsent(talkTestPicker, "the dropped talk test on an easy aerobic run's log")
            snapshot("Aerobic run log, no talk test")
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
            expect(app.switches["Announce halfway"], "Announce halfway, kept unfolded")
            // Fine-tuning is folded away until asked for.
            expectAbsent(app.switches["Duck other audio"], "Duck other audio before unfolding")
            let fineTuning = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                              "Fine-tuning")).firstMatch
            expect(fineTuning, "the folded Fine-tuning group")
            fineTuning.tap()
            expect(app.switches["Duck other audio"], "Duck other audio once unfolded")
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
            // The preset made this plan in one tap, so it has no kind yet. Start asks once, and
            // the answer is saved on the plan. (The aerobic plan above has one and went straight
            // to READY.)
            let speed = app.buttons["Speed"]
            expect(speed, "the question asking a plan with no kind for one")
            snapshot("Start asks for the kind")
            speed.tap()
            expect(app.staticTexts["READY"], "the READY screen")
            // READY is a full-screen cover, and Today's card is still in the element tree beneath
            // it, so only what can be tapped (what is on top) is counted.
            expectOnce("4/1 × 5", in: app, "the plan's name and shape on READY", onTopOnly: true)
        }

        step("Start: the run screen, and the Watch failure reported") {
            app.buttons["Start"].tap()
            // Chosen to run on: the screen must then say the run carries on without the Watch.
            answerNoWatchWarning(with: runWithoutWatch)
            expect(app.buttons["End Workout"], "End Workout on the run screen")
            let phoneOnly = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                                 "phone only")).firstMatch
            expect(phoneOnly, "the run screen saying the run continues on the phone only")
            expect(app.buttons["Try again"], "Try again after the Watch failed")
            // Drawn in the same pass as End Workout, which is already on screen, so this absence
            // is a fact about the screen rather than about timing.
            expectAbsent(aerobicTarget, "the aerobic panel on an ordinary run")
        }

        step("Slide to skip, twice in a row") {
            // The slider stayed stuck at the end after one skip, so a second skip needed a pause
            // and resume first. Two skips in a row must each move the run on.
            expect(app.staticTexts["RUN"], "the first run interval, after the countdown")
            slideToSkip()
            expect(app.staticTexts["WALK"], "the walk, after the first skip")
            slideToSkip()
            expect(app.staticTexts["RUN"], "the next run interval, after the second skip")
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

        step("Start with no Watch, try to reconnect, then stop to go and get it") {
            app.buttons["Start Workout"].tap()
            expect(app.staticTexts["READY"], "the READY screen")
            app.buttons["Start"].tap()
            waitForNoWatchWarning()
            // The simulator has no Watch, so the attempt fails, at once or at the 15 s timeout.
            // The warning must say so and offer the attempt again, rather than look untouched.
            let reconnect = app.buttons["Try to reconnect now"]
            expect(reconnect, "Try to reconnect now on the warning")
            reconnect.tap()
            let failed = app.staticTexts["Reconnecting didn't work."]
            XCTAssertTrue(failed.waitForExistence(timeout: 25),
                          "The reconnect attempt failed and the warning never said so")
            expect(reconnect, "Try to reconnect now, offered again after the attempt failed")
            snapshot("No-Watch warning after a failed reconnect")
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

    /// Drags the Skip slider's thumb all the way across, as a thumb on the screen would.
    ///
    /// A real drag, never `tap()`: the slider's accessibility action fires Skip without the drag,
    /// so a tap would pass even with the drag path broken.
    private func slideToSkip() {
        let slider = app.buttons["Slide to skip"]
        expect(slider, "the Skip slider")
        let thumb = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        thumb.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Waits for the no-Watch warning and answers it. The simulator has no Watch, so every run's
    /// launch fails, at once or at the 15 s timeout; waiting for the warning before anything else on
    /// the run screen keeps a late warning from landing on top of a later tap.
    private func answerNoWatchWarning(with choice: XCUIElement) {
        let warning = waitForNoWatchWarning()
        expect(runWithoutWatch, "Run without Watch on the warning")
        expect(stopForWatch, "Stop on the warning")
        choice.tap()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5),
                      "The no-Watch warning stayed up after it was answered")
    }

    /// Waits for the no-Watch warning, without answering it.
    @discardableResult
    private func waitForNoWatchWarning() -> XCUIElement {
        let warning = app.staticTexts["NO WATCH"]
        XCTAssertTrue(warning.waitForExistence(timeout: 25),
                      "The run started with no Watch and the no-Watch warning never appeared")
        snapshot("No-Watch warning")
        return warning
    }

    private var runWithoutWatch: XCUIElement { app.buttons["Run without Watch"] }
    private var stopForWatch: XCUIElement { app.buttons["Stop — I'll get my Watch"] }

    private var aerobicTarget: XCUIElement {
        app.staticTexts["RPE 3–4 · conversational"]
    }

    /// A History run card whose text contains `text`. Each card reads as one element.
    private func card(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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

    /// Exactly one static text reads `label` inside `container`. Waits for the first, so the count is
    /// taken of a drawn screen, not an empty one.
    private func expectOnce(_ label: String, in container: XCUIElement, _ what: String,
                            onTopOnly: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) {
        let matches = container.staticTexts.matching(NSPredicate(format: "label == %@", label))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "Not found: \(what)",
                      file: file, line: line)
        let count = onTopOnly
            ? matches.allElementsBoundByIndex.filter(\.isHittable).count
            : matches.count
        XCTAssertEqual(count, 1, "Shown \(count) times: \(what)", file: file, line: line)
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
