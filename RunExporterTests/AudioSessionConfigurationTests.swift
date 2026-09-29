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

    /// The simulator **accepts** the invalid option set that a real device rejects with -50.
    ///
    /// Verified while writing these tests: asserting that the old configuration throws passes on
    /// hardware and fails in the simulator. So no simulator test can catch this class of mistake,
    /// and `testOptionsExcludeOnesInvalidForPlayback` above — which checks our own option set
    /// rather than the platform's reaction to it — is the guard that actually works everywhere.
    ///
    /// The wider lesson is the reason spec §26 insists the audio tests run on real hardware: the
    /// simulator's audio session is not a faithful model of the device's.
    func testSimulatorAcceptsConfigurationsDeviceMayReject() throws {
        #if targetEnvironment(simulator)
        let invalid: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP,
                                                       .allowAirPlay]
        // Documenting the divergence, not endorsing it: this is why the option set is asserted
        // directly instead of being validated by asking the platform.
        XCTAssertNoThrow(try session.setCategory(.playback, mode: .voicePrompt, options: invalid),
                         "Simulator behaviour changed; re-check the device assumption")
        #else
        throw XCTSkip("Device rejects this configuration; the divergence only matters in the simulator.")
        #endif
    }
}
