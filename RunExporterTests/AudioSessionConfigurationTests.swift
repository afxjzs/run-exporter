import AVFAudio
import XCTest
@testable import RunExporter

/// Checks the audio session configuration against the real `AVAudioSession`.
///
/// Regression tests. `.allowAirPlay` (play-and-record only) and `.allowBluetoothA2DP` (implicitly
/// true and unsettable for `.playback`) were both passed to a `.playback` session. `setCategory`
/// rejected the entire call with `paramErr (-50)`, the category was never applied, and the session
/// silently stayed on the default `.soloAmbient`.
///
/// That failure is nearly invisible: cues still sound in the foreground, so hearing them proves
/// nothing. What breaks is exactly what this app exists to do — cues surviving a locked screen —
/// plus ducking, and the Ring/Silent switch then mutes everything.
///
/// These tests ask AVAudioSession to accept the configuration rather than trusting a reading of
/// the documentation, which is what went wrong the first time.
///
/// **The simulator accepts configurations a device rejects** — including the exact invalid set
/// above — so the acceptance test can only fail on a device, and the option set is also asserted
/// directly. (A test that pinned the simulator's leniency was removed on 2026-09-30: it tested
/// Apple's simulator, not this app.)
final class AudioSessionConfigurationTests: XCTestCase {

    private let session = AVAudioSession.sharedInstance()

    override func tearDown() {
        // Leave the shared session as found; other tests construct audio players.
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        super.tearDown()
    }

    /// The configuration the engine actually uses must be accepted, ducking or not.
    func testPlaybackSessionConfigurationIsAccepted() throws {
        for ducking in [false, true] {
            XCTAssertNoThrow(
                try session.setCategory(.playback, mode: .voicePrompt,
                                        options: AudioCueEngine.sessionOptions(ducking: ducking)),
                "Options for ducking=\(ducking) were rejected by AVAudioSession")
        }
    }

    /// Applying it must genuinely leave the session on `.playback` — the category that keeps
    /// playing with the screen locked and ignores the Ring/Silent switch.
    func testSessionEndsUpOnPlaybackCategory() throws {
        try session.setCategory(.playback, mode: .voicePrompt,
                                options: AudioCueEngine.sessionOptions(ducking: false))

        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers),
                      "Cues must mix so a podcast is not stopped outright")
    }

    /// Ducking is applied per cue, so switching it on and off mid-session must keep working.
    func testDuckingCanBeToggledOnAnActiveSession() throws {
        try session.setCategory(.playback, mode: .voicePrompt,
                                options: AudioCueEngine.sessionOptions(ducking: false))
        try session.setActive(true)

        XCTAssertNoThrow(try session.setCategory(.playback, mode: .voicePrompt,
                                                 options: AudioCueEngine.sessionOptions(ducking: true)))
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers))

        XCTAssertNoThrow(try session.setCategory(.playback, mode: .voicePrompt,
                                                 options: AudioCueEngine.sessionOptions(ducking: false)))
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers),
                       "Ducking must lift again, or media stays quiet for the whole workout")
    }

    /// Guards the specific mistake, so it cannot be reintroduced by "this looks useful".
    func testOptionsExcludeOnesInvalidForPlayback() {
        for ducking in [false, true] {
            let options = AudioCueEngine.sessionOptions(ducking: ducking)
            XCTAssertFalse(options.contains(.allowAirPlay),
                           "allowAirPlay is only valid with playAndRecord and fails the call")
            XCTAssertFalse(options.contains(.allowBluetoothA2DP),
                           "allowBluetoothA2DP cannot be set for playback; it is implicitly true")
        }
    }
}
