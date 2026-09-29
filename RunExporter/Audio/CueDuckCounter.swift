import Foundation

/// Tracks which cue sounds are playing right now, so overlapping cues do not un-duck other audio
/// early and the last one to finish always restores it.
///
/// ## Why this is a type and not an `Int`
///
/// It *was* an `Int` inside `AudioCueEngine`, and the defect that motivated splitting it out is the
/// reason it should not go back to being one.
///
/// The engine incremented for every cue it started and decremented in the completion callbacks —
/// but the speech callback also had to ignore the silent warm-up utterance, which never
/// incremented. It did so by testing `utterance.volume > 0`: a **value** test standing in for an
/// **identity** question. The two come apart as soon as a real cue legitimately has volume 0, which
/// is exactly what happens when the user drags cue volume to 0 in Settings. That cue incremented,
/// was skipped on the way out, and the count never returned to zero — so `.duckOthers` stayed on
/// the session and the user's music or video was held quiet for the rest of the workout, with no
/// error raised anywhere and nothing wrong-looking inside this app. `duckOtherAudio` defaults to
/// true, so a stock install could reach it.
///
/// Keying on the identity of the object making the sound makes "only clear what you started"
/// structural instead of inferred. The warm-up utterance then needs no special case at all: it is
/// never started, so finishing it is a no-op.
///
/// **Known limit, and a deliberate trade.** Identity is `ObjectIdentifier`, so a source released
/// while still registered could in principle have its address reused by a later allocation and
/// match by accident. In practice the engine holds its tone players in `tonePlayers` and
/// `AVSpeechSynthesizer` retains an utterance until it reports finishing or cancelling, so a
/// registered source stays alive. If it ever did happen the result is one cue un-ducking a beat
/// early and correcting itself on the next cue — strictly better than the failure it replaces,
/// which was silent and permanent.
struct CueDuckCounter {

    /// Identities of the utterances and players currently sounding.
    private var sounding: Set<ObjectIdentifier> = []

    /// True while at least one cue is sounding and other audio should stay ducked.
    var isDucking: Bool { !sounding.isEmpty }

    /// Registers a sound as started.
    ///
    /// Starting the same source twice is deliberately idempotent. The countdown digits share a
    /// single `AVAudioPlayer`, and a player restarted mid-tick reports finishing only once however
    /// many times it was told to play — so counting it twice would strand a reference that nothing
    /// can ever clear, which is the exact failure this type exists to prevent.
    mutating func started(_ source: AnyObject) {
        sounding.insert(ObjectIdentifier(source))
    }

    /// Deregisters a sound. Returns `true` when it was the last one and ducking should be lifted.
    ///
    /// Returns `false` for a source that was never started — the warm-up utterance, or a callback
    /// arriving after `reset()` — so a stray completion cannot un-duck a cue that is still
    /// sounding.
    mutating func finished(_ source: AnyObject) -> Bool {
        guard sounding.remove(ObjectIdentifier(source)) != nil else { return false }
        return sounding.isEmpty
    }

    /// Drops every registration, for teardown and interruptions where the sounds in flight will
    /// never report finishing.
    mutating func reset() {
        sounding.removeAll()
    }
}
