import Foundation

/// Switches the UI smoke test (`RunExporterUITests/SmokeTests.swift`) sets with launch arguments.
///
/// **Debug builds only.** In a Release build — anything installed on the owner's phone by
/// `scripts/sideload.sh` — every switch here is `false` whatever the launch arguments say, so no
/// test hook can change what the real app does.
enum UITesting {

    /// `-uiTestingSkipsHealthAuthorization`: never request HealthKit access, and so never read it.
    ///
    /// The simulator's Health permission sheet appears an unpredictable time after a request, can
    /// queue a second one, and can replace itself mid-tap; dismissing it from the test failed three
    /// smoke runs in five on 2026-09-30. With this on, Today shows no workouts rather than waiting
    /// on Health, which is also how the test tells the switch took effect.
    ///
    /// Covers the two requests the app makes on its own: the logger's at launch
    /// (`RunLoggerModel.refresh`) and the Watch launch's at Start (`WatchLink`). The export screen's
    /// two requests run only when the user taps Grant Health Access or Export, which the smoke test
    /// does not; if it ever did, the test's no-sheet check would fail rather than flake.
    ///
    /// Logged when on: a skipped permission request is a different mode of the app, and a mode
    /// nobody can see is the kind of silent deviation this project refuses.
    static let skipsHealthAuthorization: Bool = {
        #if DEBUG
        let on = ProcessInfo.processInfo.arguments.contains("-uiTestingSkipsHealthAuthorization")
        if on {
            NSLog("UI TESTING: HealthKit authorization is skipped (-uiTestingSkipsHealthAuthorization)")
        }
        return on
        #else
        return false
        #endif
    }()

    /// `-uiTestingSilencesNoWatchAlarm`: show the no-Watch warning but play no sound or vibration.
    ///
    /// The alarm ignores "Play cues" on purpose, and the simulator never has a Watch, so every smoke
    /// test run would otherwise sound it through the Mac's speakers. Only the sound is skipped; the
    /// warning screen, which is what the test checks, is unchanged. Logged when on, like the flag above.
    static let silencesNoWatchAlarm: Bool = {
        #if DEBUG
        let on = ProcessInfo.processInfo.arguments.contains("-uiTestingSilencesNoWatchAlarm")
        if on {
            NSLog("UI TESTING: the no-Watch alarm is silent (-uiTestingSilencesNoWatchAlarm)")
        }
        return on
        #else
        return false
        #endif
    }()
}
