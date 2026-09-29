import AVFAudio
import Foundation
import Observation

/// Plays the interval cues through whatever the current output route is (spec §9).
///
/// ## Why the audio session is configured the way it is
///
/// The spec's suggested option set needs two changes against this SDK:
///
/// * `.allowBluetooth` is deprecated, and its replacement `.allowBluetoothHFP` selects the
///   *call* profile. Forcing HFP would drop AirPods to mono call quality for the whole workout.
///   `.playback` already routes to A2DP, which is what headphones should get, so `.allowBluetoothA2DP`
///   is set and HFP is deliberately not.
/// * `.interruptSpokenAudioAndMixWithOthers` *pauses* spoken audio and only lets it resume when the
///   session is deactivated. The session has to stay active for the whole workout to keep the timer
///   running in the background, so that option would leave a podcast paused for the entire run —
///   which the same spec section forbids ("should not permanently pause the user's media"). Cues
///   duck instead, and ducking is switched on per cue rather than for the session, so music and
///   podcasts play normally between cues and dip only while a cue sounds.
///
/// Background execution comes from the `audio` background mode plus a silent looping player that
/// keeps the session genuinely playing. Nothing is audible from it.
@MainActor
@Observable
final class AudioCueEngine {

    /// The last audio problem, in words meant for the user. Never silently discarded — a cue that
    /// did not play is the single most important failure this app can have.
    private(set) var lastError: String?

    /// A route change worth mentioning that is **not** a failure — the audio recovered by itself.
    ///
    /// Separate channel from `lastError` for two reasons, both learned from a real run. A
    /// half-second AirPods dropout wrote to `lastError`, where nothing ever cleared it, so the
    /// banner asserted "cues are now playing through the speaker" for the rest of the workout after
    /// the AirPods were already back — a statement that had become false. And because the workout
    /// screen renders only the first non-nil of several sources, that stale notice could hide a
    /// genuine error behind a condition that had already passed.
    private(set) var routeNotice: String?

    /// Cues actually played, newest last. Drives the on-device cue test (spec §26, Test 2).
    private(set) var playbackLog: [PlaybackRecord] = []

    private(set) var isSessionActive = false
    /// True when the `.playback` category was actually applied.
    ///
    /// Surfaced because the difference is invisible in the foreground and decisive once the screen
    /// locks: a session that failed to configure still makes noise, so "I can hear it" is not
    /// evidence that background cues will work.
    private(set) var isSessionConfigured = false
    /// True while an interruption (a call, Siri) is in effect.
    private(set) var isInterrupted = false
    private(set) var currentRouteDescription = ""

    struct PlaybackRecord: Identifiable {
        let id = UUID()
        let cue: String
        /// When `play(_:)` was entered.
        let requestedAt: Date
        /// When the tone actually started, or nil when this cue had no tone.
        let soundedAt: Date?
        let route: String
        let spoke: Bool
        let played: Bool

        /// How long this cue spent between being requested and being audible.
        ///
        /// The number that matters for "the beeps are not on the seconds". Nil for a voice-only cue,
        /// where there is no tone whose start could be late.
        var startLatency: TimeInterval? {
            soundedAt.map { $0.timeIntervalSince(requestedAt) }
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBridge = DelegateBridge()

    /// Preloaded one per cue voice, so no file is decoded at a transition boundary (spec §9.6).
    private var tonePlayers: [String: AVAudioPlayer] = [:]
    private var silencePlayer: AVAudioPlayer?

    /// The cues currently sounding. Ducking is lifted only when the last one finishes, so
    /// overlapping cues do not un-duck each other early. See `CueDuckCounter` for why this tracks
    /// identities rather than counting.
    private var duckCounter = CueDuckCounter()

    private var settings: LoggerDefaults?

    init() {
        delegateBridge.owner = self
        synthesizer.delegate = delegateBridge
        registerForNotifications()
    }

    // MARK: - Preparation

    /// Configures the session and preloads every player. Call before the workout starts, not at
    /// the first transition.
    ///
    /// Returns an error message on failure rather than throwing it away; the caller shows it and
    /// the workout screen refuses to promise cues it cannot deliver.
    @discardableResult
    func prepare(settings: LoggerDefaults) -> String? {
        self.settings = settings

        do {
            try configureSession(ducking: false)
            isSessionConfigured = true
        } catch {
            // Do NOT claim cues will not play: they generally still do, through whatever session
            // the system falls back to. What is actually lost is background and locked-screen
            // playback, and ducking — so say that, and keep going rather than refusing to run.
            isSessionConfigured = false
            let message = "Audio is running in a reduced mode (\(error.localizedDescription)). "
                + "Cues should still play while the app is open, but may stop when the screen "
                + "locks, and may interrupt music instead of ducking it."
            lastError = message
            // Deliberately not an early return — a degraded session is far better than none.
        }

        loadTonePlayers(volume: Float(settings.cueVolume))
        loadSilencePlayer()
        warmUpSpeech()
        currentRouteDescription = Self.describe(route: session.currentRoute)
        return nil
    }

    /// Activates the session and starts the silent keep-alive player.
    @discardableResult
    func beginWorkoutAudio() -> String? {
        do {
            try session.setActive(true)
            isSessionActive = true
        } catch {
            let message = "Audio could not start: \(error.localizedDescription). "
                + "Interval cues will not play."
            lastError = message
            isSessionActive = false
            return message
        }

        currentRouteDescription = Self.describe(route: session.currentRoute)
        if silencePlayer?.play() != true {
            // Not fatal on its own — cues still work while the app is in the foreground — but it
            // is exactly what makes background cues stop, so it is reported rather than ignored.
            lastError = "Background audio could not start. Cues may stop if you leave the app or "
                + "lock the phone. Reopen the app to continue the workout."
        }
        return nil
    }

    /// Stops the keep-alive player and releases the session so other audio returns to full volume.
    func endWorkoutAudio() {
        silencePlayer?.stop()
        synthesizer.stopSpeaking(at: .immediate)
        for player in tonePlayers.values { player.stop() }
        // `stop()` does not call the delegate, so these sounds will never report finishing.
        duckCounter.reset()

        do {
            try configureSession(ducking: false)
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            lastError = "Audio could not be released: \(error.localizedDescription). "
                + "Other apps' audio may stay quiet until you reopen this app."
        }
        isSessionActive = false
    }

    // MARK: - Playing

    /// Plays a cue in whatever mode the user selected.
    ///
    /// Deliberately does nothing when the cue source is not this app: the engine never competes
    /// with the Apple Workout app for the same transition.
    func play(_ cue: AudioCue) {
        // Taken on entry, before any session work, so the log can show how long a cue spent getting
        // to the speaker. It used to be stamped at the very end of this method, which meant the log
        // recorded when the work finished and had nothing to compare it against — perfectly regular
        // rows while the audible beeps drifted. A timing log that cannot show drift is not a timing
        // log.
        let requestedAt = Date()

        guard let settings else {
            lastError = "A cue was requested before audio was prepared, so it did not play."
            return
        }
        guard Self.shouldPlay(cue, source: settings.cueSource) else { return }

        let mode = settings.cueMode
        let wantsVoice = mode.includesVoice && cue.spokenText != nil
        // An announcement rendered as a bare tick is indistinguishable from a countdown tick.
        let wantsTone = mode.includesBeeps && !(cue.isAnnouncementOnly && !wantsVoice)

        guard wantsVoice || wantsTone else { return }

        if settings.duckOtherAudio { beginDucking() }

        var spoke = false
        var played = false

        var soundedAt: Date?

        if wantsTone, let player = tonePlayers[cue.identifier] {
            player.volume = Float(settings.cueVolume)
            player.currentTime = 0
            played = player.play()
            // Stamped immediately after `play()` returns, so `soundedAt - requestedAt` is the delay
            // this cue actually suffered. Everything expensive on that path — `setCategory` for
            // ducking is a synchronous round trip to the audio server — lands inside this gap.
            soundedAt = Date()
            if played {
                duckCounter.started(player)
            } else {
                lastError = "The \(cue.identifier) tone did not play."
            }
        }

        if wantsVoice, let text = cue.spokenText {
            let utterance = AVSpeechUtterance(string: text)
            utterance.volume = Float(settings.cueVolume)
            // Slightly brisk: a cue that arrives late is worse than one that sounds hurried.
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.preUtteranceDelay = wantsTone ? 0.14 : 0
            utterance.postUtteranceDelay = 0
            utterance.voice = resolvedVoice(settings: settings)
            synthesizer.speak(utterance)
            duckCounter.started(utterance)
            spoke = true
        }

        if !spoke && !played && settings.duckOtherAudio && !duckCounter.isDucking {
            // Nothing will report finishing, so lift the ducking we just applied — unless an
            // earlier cue is still sounding, which must keep it.
            restoreOtherAudio()
        }

        playbackLog.append(PlaybackRecord(cue: cue.identifier,
                                          requestedAt: requestedAt,
                                          soundedAt: soundedAt,
                                          route: currentRouteDescription,
                                          spoke: spoke,
                                          played: played))
        if playbackLog.count > 200 { playbackLog.removeFirst(playbackLog.count - 200) }
    }

    /// Whether `cue` may be played at all under `source`.
    ///
    /// **`.none` means silence, full stop.** The Settings footer promises "No cues will play from
    /// this app at all", so nothing gets through — not even a button confirmation. With cues on,
    /// everything plays.
    ///
    /// The gate once let the four confirmation cues through under `.none`, so choosing "No cues"
    /// produced four cues, with no error and nothing on screen to contradict the footer. (That rule
    /// existed for the Watch cue sources, which were removed on 2026-09-29.)
    ///
    /// `nonisolated static` for the same reason as `sessionOptions`: it makes the rule assertable
    /// without an audio device.
    nonisolated static func shouldPlay(_ cue: AudioCue, source: CueSource) -> Bool {
        source == .iphoneAudioEngine
    }

    func clearPlaybackLog() { playbackLog.removeAll() }

    func clearError() { lastError = nil }

    // MARK: - Voices

    /// English voices offered in Settings.
    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }

    /// The chosen voice, or the system default when none is chosen or the stored one is gone
    /// (voices can be deleted in iOS Settings).
    private func resolvedVoice(settings: LoggerDefaults) -> AVSpeechSynthesisVoice? {
        guard let identifier = settings.cueVoiceIdentifier else { return nil }
        if let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        lastError = "The selected cue voice is no longer installed on this device. "
            + "Cues are using the system default voice — pick another in Settings."
        return nil
    }

    // MARK: - Session configuration

    /// Category options for a `.playback` session.
    ///
    /// **Only options that are legal for `.playback`.** Two that look useful are not:
    ///
    /// * `.allowAirPlay` is documented "only valid with `AVAudioSessionCategoryPlayAndRecord`".
    /// * `.allowBluetoothA2DP` is, for every category other than `playAndRecord`, "always
    ///   implicitly true and cannot be changed".
    ///
    /// Passing either makes `setCategory` fail the *whole* call with `paramErr (-50)`, leaving the
    /// session on the default `.soloAmbient` — which does not play in the background, is silenced
    /// by the Ring/Silent switch, and interrupts other audio instead of ducking it. Cues still
    /// sound while the app is in the foreground, so the breakage is nearly invisible until the
    /// screen locks mid-run. Neither option is a loss: `.playback` already routes to A2DP and
    /// AirPlay by default.
    ///
    /// Exercised directly by `AudioSessionConfigurationTests`, which asks AVAudioSession to accept
    /// them rather than trusting this comment.
    nonisolated static func sessionOptions(ducking: Bool) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if ducking { options.insert(.duckOthers) }
        return options
    }

    /// `.playback` keeps audio going with the screen locked; `.voicePrompt` tells the system these
    /// are short spoken prompts, which makes ducking behave the way a navigation app's does.
    private func configureSession(ducking: Bool) throws {
        try session.setCategory(.playback, mode: .voicePrompt,
                                options: Self.sessionOptions(ducking: ducking))
    }

    private func beginDucking() {
        do {
            try configureSession(ducking: true)
        } catch {
            // The cue still plays, just without dipping the music. Worth reporting, not worth
            // suppressing the cue over.
            lastError = "Could not duck other audio for this cue: \(error.localizedDescription)"
        }
    }

    /// Lifts ducking when `source` was the last cue still sounding.
    ///
    /// Safe to call for a sound that was never started — the warm-up utterance, or a callback that
    /// arrives after teardown. `CueDuckCounter` reports those as "not the last one" and nothing
    /// happens, which is what the old `utterance.volume > 0` guard was reaching for and got wrong.
    private func cueFinished(_ source: AnyObject) {
        guard duckCounter.finished(source) else { return }
        restoreOtherAudio()
    }

    private func restoreOtherAudio() {
        do {
            try configureSession(ducking: false)
        } catch {
            lastError = "Could not restore other audio after a cue: \(error.localizedDescription)"
        }
    }

    // MARK: - Player loading

    private func loadTonePlayers(volume: Float) {
        let cues: [AudioCue] = [.run, .walk, .cooldown, .complete,
                                .nextPhase(.walk, seconds: 5), .finalRound, .countdown(3),
                                .paused, .resumed(.run), .skipped, .ended]
        var players: [String: AVAudioPlayer] = [:]
        var failures: [String] = []

        for cue in cues {
            let data = ToneGenerator.wav(for: cue.tone)
            do {
                let player = try AVAudioPlayer(data: data)
                player.volume = volume
                player.delegate = delegateBridge   // lifts ducking when the tone finishes
                player.prepareToPlay()
                players[cue.identifier] = player
            } catch {
                failures.append(cue.identifier)
            }
        }

        // Countdown digits all share one tick; register it under every digit's identifier so the
        // lookup in `play` stays a plain dictionary hit at the transition boundary.
        if let tick = players[AudioCue.countdown(3).identifier] {
            for digit in 1...10 {
                players[AudioCue.countdown(digit).identifier] = tick
            }
        }
        // `halfway` shares the tick voice too.
        players[AudioCue.halfway.identifier] = players[AudioCue.countdown(3).identifier]

        tonePlayers = players
        if !failures.isEmpty {
            lastError = "These cue tones could not be prepared and will be silent: "
                + failures.joined(separator: ", ") + "."
        }
    }

    /// A long silent loop. This is what keeps the app running — and therefore the timer ticking
    /// and cues firing — once the screen locks or the app is backgrounded.
    private func loadSilencePlayer() {
        do {
            let player = try AVAudioPlayer(data: ToneGenerator.silenceWAV(seconds: 2))
            player.numberOfLoops = -1
            player.volume = 1  // The samples are silence; the level is irrelevant.
            player.prepareToPlay()
            silencePlayer = player
        } catch {
            silencePlayer = nil
            lastError = "Background audio could not be prepared: \(error.localizedDescription). "
                + "Cues may stop when the app is backgrounded or the phone is locked."
        }
    }

    /// Speaks a silent utterance so the first real cue does not pay the synthesizer's start-up
    /// cost at a transition boundary (spec §9.6).
    private func warmUpSpeech() {
        let utterance = AVSpeechUtterance(string: " ")
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    // MARK: - Interruptions and routing

    private func registerForNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            isInterrupted = true
            duckCounter.reset()
        case .ended:
            isInterrupted = false
            // Only resume when the system says it is appropriate; forcing it can fail silently.
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume) else {
                lastError = "Audio was interrupted and the system did not allow it to resume "
                    + "automatically. Open the app and tap Resume to restore cues."
                return
            }
            resumeAfterInterruption()
        @unknown default:
            // A future interruption type is not assumed to be harmless.
            lastError = "An unrecognized audio interruption occurred. If cues stop, reopen the app."
        }
    }

    private func resumeAfterInterruption() {
        do {
            try configureSession(ducking: false)
            try session.setActive(true)
            isSessionActive = true
            if silencePlayer?.play() != true {
                lastError = "Background audio did not restart after the interruption. Keep the app "
                    + "open, or restart the timer, to keep hearing cues."
            }
        } catch {
            isSessionActive = false
            lastError = "Audio did not resume after the interruption: \(error.localizedDescription)"
        }
    }

    private func handleRouteChange(_ note: Notification) {
        currentRouteDescription = Self.describe(route: session.currentRoute)

        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // AirPods pulled out or disconnected: iOS pauses playback. Restart the keep-alive so
            // the workout does not go quiet on the phone speaker without warning.
            if silencePlayer?.play() != true {
                // Cues may genuinely stop, so this belongs on the error channel and should persist
                // until the user acknowledges it.
                lastError = "Headphones disconnected and background audio did not restart. "
                    + "Cues may stop until you reopen the app."
            } else {
                // Recovered on its own: information, not a failure.
                routeNotice = "Headphones disconnected. Cues are now playing through "
                    + "\(currentRouteDescription)."
            }

        case .newDeviceAvailable:
            // The route came back, so anything said about having lost it is now false. A notice must
            // not outlive the condition it describes — a half-second dropout used to leave a banner
            // insisting cues were on the speaker for the remainder of the run.
            routeNotice = nil

        default:
            break
        }
    }

    func clearRouteNotice() { routeNotice = nil }

    private func handleMediaServicesReset() {
        // Everything the system handed us is invalid after this; rebuild it all.
        isSessionActive = false
        tonePlayers.removeAll()
        silencePlayer = nil
        lastError = "The system audio service restarted, so cue audio was rebuilt. "
            + "Check that you can still hear cues."
        guard let settings else { return }
        _ = prepare(settings: settings)
        _ = beginWorkoutAudio()
    }

    static func describe(route: AVAudioSessionRouteDescription) -> String {
        let outputs = route.outputs.map { $0.portName }
        return outputs.isEmpty ? "no output" : outputs.joined(separator: ", ")
    }

    // MARK: - Delegates

    /// Speech and player callbacks arrive on framework threads; this bridges them back onto the
    /// main actor where the engine's state lives.
    private final class DelegateBridge: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
        /// Written exactly once, on the main actor, in `AudioCueEngine.init` — before the bridge
        /// is handed to AVFoundation and therefore before any callback can read it. Reads happen
        /// on framework threads and immediately hop back to the main actor.
        nonisolated(unsafe) weak var owner: AudioCueEngine?

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                           didFinish utterance: AVSpeechUtterance) {
            finishSpeech(utterance)
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                           didCancel utterance: AVSpeechUtterance) {
            finishSpeech(utterance)
        }

        private nonisolated func finishSpeech(_ utterance: AVSpeechUtterance) {
            // Nothing is filtered here. This is where a `utterance.volume > 0` guard used to sit,
            // meaning "skip the silent warm-up utterance" — but a real cue also has volume 0 when
            // the user sets cue volume to 0, so those cues never lifted the ducking they applied.
            // The counter now recognises the warm-up by never having started it.
            Task { @MainActor [weak owner] in owner?.cueFinished(utterance) }
        }

        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                     successfully flag: Bool) {
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                if !flag {
                    owner.lastError = "A cue tone stopped before it finished playing."
                }
                owner.cueFinished(player)
            }
        }

        nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            let description = error?.localizedDescription ?? "unknown decoding error"
            Task { @MainActor [weak owner] in
                owner?.lastError = "A cue tone could not be decoded: \(description)"
                owner?.cueFinished(player)
            }
        }
    }
}
