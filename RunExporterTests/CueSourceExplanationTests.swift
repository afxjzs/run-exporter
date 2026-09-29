import XCTest
@testable import RunExporter

/// Ties the Settings footer to what the engine actually does.
///
/// Settings is the screen `AudioCueEngine.shouldPlay`'s own doc comment cites as the authority on
/// what the user was promised, and two of its footers once promised silence the engine never
/// delivered: "This app plays NO cues" for the two Watch sources (removed 2026-09-29), while pause,
/// resume, skip and end always played under them. Nothing but a test can keep a promise and its
/// implementation in step — the code was correct, the sentence was wrong, and neither one knew
/// about the other.
@MainActor
final class CueSourceExplanationTests: XCTestCase {

    /// Every cue the app can emit, transitions and confirmations alike.
    private let allCues: [AudioCue] = [.countdown(3), .countdown(2), .countdown(1),
                                       .run, .walk, .cooldown, .finalRound, .halfway,
                                       .nextPhase(.walk, seconds: 5), .complete,
                                       .paused, .resumed(.run), .skipped, .ended]

    /// Phrasings that promise the user will hear nothing from this app.
    private let silenceClaims = ["plays no cues", "play nothing", "hear nothing",
                                 "no cues will play"]

    // MARK: - The invariant that was broken

    func testNoSourceClaimsSilenceWhileTheEngineStillPlaysSomething() {
        for source in CueSource.allCases {
            let audible = allCues.filter { AudioCueEngine.shouldPlay($0, source: source) }
            guard !audible.isEmpty else { continue }

            let text = SettingsView.cueSourceExplanation(for: source).lowercased()
            for claim in silenceClaims {
                XCTAssertFalse(
                    text.contains(claim),
                    "\(source.rawValue) still plays \(audible.count) cue(s) "
                        + "(\(audible.map(\.identifier).joined(separator: ", "))) "
                        + "but its Settings footer claims \"\(claim)\"")
            }
        }
    }

    /// The converse, so the rule cannot be satisfied by deleting every mention of silence.
    func testTheGenuinelySilentSourceDoesSaySoPlainly() {
        let audible = allCues.filter { AudioCueEngine.shouldPlay($0, source: .none) }
        XCTAssertTrue(audible.isEmpty,
                      "\"No cues\" must be silent; \(audible.map(\.identifier)) got through")

        let text = SettingsView.cueSourceExplanation(for: CueSource.none).lowercased()
        XCTAssertTrue(silenceClaims.contains { text.contains($0) }, text)
    }

    // MARK: - Nothing left unexplained

    func testEverySourceHasAnExplanation() {
        for source in CueSource.allCases {
            let text = SettingsView.cueSourceExplanation(for: source)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(source.rawValue) has no footer text")
        }
    }
}
