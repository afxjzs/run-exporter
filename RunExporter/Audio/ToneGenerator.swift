import Foundation

/// Synthesizes the cue tones as in-memory 16-bit PCM WAV data.
///
/// Generated rather than bundled so there is no third-party or licensed audio anywhere in the app
/// (spec §9.3), and pure so the waveform maths can be tested without an audio device.
enum ToneGenerator {

    static let sampleRate = 44_100.0

    /// One constant-amplitude segment of a cue.
    ///
    /// `endFrequency` makes a segment glide, which is what distinguishes the descending cooldown
    /// tone from the flat run/walk beeps by ear rather than by pitch alone.
    struct Segment {
        let startFrequency: Double
        let endFrequency: Double
        let duration: Double
        /// Trailing silence, so a double beep reads as two events rather than one long one.
        let gapAfter: Double

        init(frequency: Double, duration: Double, gapAfter: Double = 0) {
            self.startFrequency = frequency
            self.endFrequency = frequency
            self.duration = duration
            self.gapAfter = gapAfter
        }

        init(from startFrequency: Double, to endFrequency: Double,
             duration: Double, gapAfter: Double = 0) {
            self.startFrequency = startFrequency
            self.endFrequency = endFrequency
            self.duration = duration
            self.gapAfter = gapAfter
        }
    }

    /// Fade applied to both ends of every segment. Without it each segment starts and stops at a
    /// non-zero sample, which is audible as a click — especially through in-ear headphones.
    private static let fadeSeconds = 0.008

    /// Peak amplitude, well below full scale so a cue never clips on top of ducked music.
    private static let amplitude = 0.55

    // MARK: - Cue voices

    /// Higher-pitched double beep (spec §9.3).
    static let run: [Segment] = [
        Segment(frequency: 1_180, duration: 0.09, gapAfter: 0.06),
        Segment(frequency: 1_180, duration: 0.09),
    ]

    /// Lower-pitched single beep.
    static let walk: [Segment] = [
        Segment(frequency: 620, duration: 0.20),
    ]

    /// Descending tone.
    static let cooldown: [Segment] = [
        Segment(from: 900, to: 480, duration: 0.42),
    ]

    /// Completion chime — a rising major triad.
    static let complete: [Segment] = [
        Segment(frequency: 659.25, duration: 0.11, gapAfter: 0.02),
        Segment(frequency: 830.61, duration: 0.11, gapAfter: 0.02),
        Segment(frequency: 1_318.51, duration: 0.26),
    ]

    /// Short neutral tick used for countdown digits.
    static let countdownTick: [Segment] = [
        Segment(frequency: 880, duration: 0.07),
    ]

    /// Two quick clicks warning that the interval is nearly over.
    static let warning: [Segment] = [
        Segment(frequency: 760, duration: 0.05, gapAfter: 0.05),
        Segment(frequency: 760, duration: 0.05),
    ]

    /// Falling two-note figure — unmistakably "stopped".
    static let paused: [Segment] = [
        Segment(frequency: 700, duration: 0.10, gapAfter: 0.03),
        Segment(frequency: 440, duration: 0.16),
    ]

    /// The inverse of `paused`, so starting and stopping cannot be confused.
    static let resumed: [Segment] = [
        Segment(frequency: 440, duration: 0.10, gapAfter: 0.03),
        Segment(frequency: 700, duration: 0.16),
    ]

    /// Neutral acknowledgement that a control was pressed.
    static let confirm: [Segment] = [
        Segment(frequency: 980, duration: 0.06),
    ]

    // MARK: - Rendering

    /// Renders segments to mono 16-bit PCM samples.
    static func samples(for segments: [Segment]) -> [Int16] {
        var output: [Int16] = []
        for segment in segments {
            output.append(contentsOf: renderSamples(segment))
            let gapFrames = Int(segment.gapAfter * sampleRate)
            if gapFrames > 0 {
                output.append(contentsOf: [Int16](repeating: 0, count: gapFrames))
            }
        }
        return output
    }

    private static func renderSamples(_ segment: Segment) -> [Int16] {
        let frameCount = Int(segment.duration * sampleRate)
        guard frameCount > 0 else { return [] }

        let fadeFrames = min(Int(fadeSeconds * sampleRate), frameCount / 2)
        var samples = [Int16](repeating: 0, count: frameCount)

        // Integrating phase (rather than sin(2π·f(t)·t)) keeps a gliding tone continuous — the
        // naive form jumps in phase as the frequency changes and buzzes.
        var phase = 0.0
        for frame in 0..<frameCount {
            let progress = frameCount > 1 ? Double(frame) / Double(frameCount - 1) : 0
            let frequency = segment.startFrequency
                + (segment.endFrequency - segment.startFrequency) * progress
            phase += 2 * .pi * frequency / sampleRate

            var envelope = 1.0
            if fadeFrames > 0 {
                if frame < fadeFrames {
                    envelope = Double(frame) / Double(fadeFrames)
                } else if frame >= frameCount - fadeFrames {
                    envelope = Double(frameCount - 1 - frame) / Double(fadeFrames)
                }
            }
            envelope = max(0, min(1, envelope))

            let value = sin(phase) * amplitude * envelope
            samples[frame] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }
        return samples
    }

    // MARK: - WAV container

    /// A complete mono 16-bit PCM WAV file, ready for `AVAudioPlayer(data:)`.
    static func wav(for segments: [Segment]) -> Data {
        wav(samples: samples(for: segments))
    }

    /// `frames` samples of pure silence — used to hold the audio session open in the background
    /// without making any sound.
    static func silenceWAV(seconds: Double) -> Data {
        wav(samples: [Int16](repeating: 0, count: max(1, Int(seconds * sampleRate))))
    }

    static func wav(samples: [Int16]) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36) + dataBytes)   // chunk size = 36 + data
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))               // PCM fmt chunk size
        data.appendLE(UInt16(1))                // format = PCM
        data.appendLE(channels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)

        data.append(contentsOf: Array("data".utf8))
        data.appendLE(dataBytes)
        for sample in samples { data.appendLE(UInt16(bitPattern: sample)) }
        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
