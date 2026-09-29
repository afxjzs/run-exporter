import AVFAudio
import XCTest
@testable import RunExporter

/// The cue ducking reference count.
///
/// Regression tests for a defect with no error message and no visible symptom inside this app:
/// with cue volume set to 0, a cue ducked the user's music or video and **never un-ducked it**, so
/// media stayed quiet for the rest of the workout. It was reachable on stock settings, because
/// `duckOtherAudio` defaults to true.
///
/// These assert the counting rule directly rather than asking `AVAudioSession` what it did.
/// `AudioSessionConfigurationTests` documents why: the simulator's audio session is not a faithful
/// model of the device's, so a test that observes platform behaviour proves nothing off-device.
/// Counting is the part of cue audio that can be checked anywhere, and counting was the bug.
///
/// Every source is held in a local `let` for the length of each test on purpose. The counter keys
/// on `ObjectIdentifier`, so a source released mid-test could have its address reused by the next
/// allocation and produce a false match.
final class CueDuckCounterTests: XCTestCase {

    private func cue(_ text: String = "cue") -> AVSpeechUtterance {
        AVSpeechUtterance(string: text)
    }

    func testDuckingLiftsWhenTheOnlyCueFinishes() {
        var counter = CueDuckCounter()
        let only = cue()

        counter.started(only)
        XCTAssertTrue(counter.isDucking)

        XCTAssertTrue(counter.finished(only), "The last cue finishing must lift ducking")
        XCTAssertFalse(counter.isDucking)
    }

    func testOverlappingCuesDoNotUnDuckEachOtherEarly() {
        var counter = CueDuckCounter()
        let tone = cue("tone")
        let voice = cue("voice")

        counter.started(tone)
        counter.started(voice)

        XCTAssertFalse(counter.finished(tone), "Ducking must hold while the second cue sounds")
        XCTAssertTrue(counter.isDucking)
        XCTAssertTrue(counter.finished(voice))
        XCTAssertFalse(counter.isDucking)
    }

    /// **The regression.** A cue at volume 0 is inaudible but is still started and still reports
    /// finishing, so it must lift ducking like any other.
    ///
    /// The previous implementation excluded it with `utterance.volume > 0` — a test written for the
    /// silent warm-up utterance — which a real cue matches whenever the user drags cue volume to 0.
    /// The count never drained and other audio stayed ducked forever.
    func testSilentCueAtVolumeZeroStillLiftsDucking() {
        var counter = CueDuckCounter()
        let silent = cue("Run")
        silent.volume = 0

        counter.started(silent)
        XCTAssertTrue(counter.isDucking)

        XCTAssertTrue(counter.finished(silent),
                      "A volume-0 cue must un-duck; this leak kept the user's media quiet forever")
        XCTAssertFalse(counter.isDucking)
    }

    /// What the old volume test was actually for, now handled structurally: the warm-up utterance
    /// is never started, so finishing it must change nothing.
    func testUnstartedSourceCannotLiftDucking() {
        var counter = CueDuckCounter()
        let real = cue("Walk")
        let warmUp = cue(" ")
        warmUp.volume = 0

        counter.started(real)

        XCTAssertFalse(counter.finished(warmUp),
                       "A sound that was never started must not un-duck a live cue")
        XCTAssertTrue(counter.isDucking, "The real cue is still sounding")
    }

    /// A duplicated completion callback must not stand in for a cue that has not finished.
    func testFinishingTwiceIsNotCountedTwice() {
        var counter = CueDuckCounter()
        let first = cue("first")
        let second = cue("second")

        counter.started(first)
        counter.started(second)

        XCTAssertFalse(counter.finished(first))
        XCTAssertFalse(counter.finished(first), "A repeated callback must not double-decrement")
        XCTAssertTrue(counter.isDucking, "The second cue is still sounding")
    }

    /// The countdown digits all share a single `AVAudioPlayer`, which can only report finishing
    /// once however many times it is restarted. Starting the same source twice must therefore still
    /// drain on one completion, or ducking would never lift.
    func testSameSourceStartedTwiceDrainsOnOneCompletion() {
        var counter = CueDuckCounter()
        let sharedTick = cue("tick")

        counter.started(sharedTick)
        counter.started(sharedTick)

        XCTAssertTrue(counter.finished(sharedTick),
                      "One completion must clear a shared player, or ducking never lifts")
        XCTAssertFalse(counter.isDucking)
    }

    /// Teardown and interruptions cancel sounds that will never report finishing.
    func testResetClearsEverything() {
        var counter = CueDuckCounter()
        let tone = cue("tone")
        let voice = cue("voice")

        counter.started(tone)
        counter.started(voice)
        counter.reset()

        XCTAssertFalse(counter.isDucking)
        XCTAssertFalse(counter.finished(tone), "A cleared source must not report being the last")
    }
}
