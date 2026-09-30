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

    /// Phrasings that promise the user will hear nothing from this app.
    private let silenceClaims = ["plays no cues", "play nothing", "hear nothing",
                                 "no cues will play"]

    // MARK: - The invariant that was broken

    func testNoSourceClaimsSilenceWhileTheEngineStillPlaysSomething() {
        for source in CueSource.allCases where AudioCueEngine.shouldPlay(source: source) {
            let text = SettingsView.cueSourceExplanation(for: source).lowercased()
            for claim in silenceClaims {
                XCTAssertFalse(text.contains(claim),
                               "\(source.rawValue) plays cues but its Settings footer claims \"\(claim)\"")
            }
        }
    }

    /// The converse, so the rule cannot be satisfied by deleting every mention of silence.
    func testTheGenuinelySilentSourceDoesSaySoPlainly() {
        XCTAssertFalse(AudioCueEngine.shouldPlay(source: .none), "\"No cues\" must be silent")

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
