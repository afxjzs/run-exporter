import Foundation

/// The aerobic analysis (aerobic spec §9–§16): heart rate and distance from a workout's own
/// HealthKit samples (Decisions D1), sliced by the app's own legs (D2).
///
/// Every rule here is one of the Decisions in `docs/AEROBIC_TRACKING_SPEC.md` and cites it by
/// number. Change the document with the code: the export's methodology section and the tests both
/// answer to it.
///
/// Pure — legs and samples in, numbers out. Nil means "not measurable" and exports blank, never
/// zero (§17).
enum AerobicAnalysis {

    /// Written into every summary row. Raise it whenever a formula or threshold below changes, so
    /// an analysis can tell which rules produced a number.
    static let analysisVersion = "1"

    /// D5: a heart-rate sample stands for the moments within this many seconds of it.
    static let sampleTolerance: TimeInterval = 5
    /// D8, D9: the coverage below which heart-rate conclusions are withheld.
    static let minimumCoverage = 0.8
    /// D9: fewer samples than this, and a leg's heart-rate figures are blank.
    static let minimumLegSamples = 2
    /// D11: seconds after a run ends at which recovery is read.
    static let recoveryOffsets: [TimeInterval] = [30, 60, 120]
    /// D15.
    static let metersPerMile = 1_609.344

    // MARK: - Results

    /// Heart rate over a set of windows.
    struct HeartRate: Equatable {
        /// Samples inside the windows (D12's "inside").
        var sampleCount = 0
        /// Share of the windows' time within 5 s of a sample inside them, 0…1 (D6). Nil when the
        /// windows hold no time at all.
        var coverage: Double?
        /// Longest stretch with no sample, edges included (D7). Nil when there are no windows.
        var largestGap: Double?
        var average: Double?
        var median: Double?
        var minimum: Double?
        var maximum: Double?
    }

    struct Workout: Equatable {
        var runningSeconds: Double
        var running: HeartRate
        /// Nil when no distance sample overlaps the running time (D14).
        var runningDistance: Double?
        var insufficientHeartRate: Bool
        /// Blank under `insufficientHeartRate` (D8).
        var firstHalfHeartRate: Double?
        var secondHalfHeartRate: Double?
        /// Speed does not depend on heart rate, so these stay under `insufficientHeartRate`.
        var firstHalfSpeed: Double?
        var secondHalfSpeed: Double?

        var runningSpeed: Double? { AerobicAnalysis.speed(runningDistance, over: runningSeconds) }
        var runningPaceSecondsPerMile: Double? { AerobicAnalysis.pace(runningSpeed) }
        /// D17.
        var heartRateDriftBPM: Double? {
            guard let first = firstHalfHeartRate, let second = secondHalfHeartRate else { return nil }
            return second - first
        }
        var heartRateDriftPercent: Double? {
            AerobicAnalysis.percentChange(firstHalfHeartRate, secondHalfHeartRate)
        }
        var speedDriftPercent: Double? { AerobicAnalysis.percentChange(firstHalfSpeed, secondHalfSpeed) }
        /// D16.
        var firstHalfEfficiency: Double? {
            AerobicAnalysis.efficiency(firstHalfSpeed, firstHalfHeartRate)
        }
        var secondHalfEfficiency: Double? {
            AerobicAnalysis.efficiency(secondHalfSpeed, secondHalfHeartRate)
        }
        var efficiencyChangePercent: Double? {
            AerobicAnalysis.percentChange(firstHalfEfficiency, secondHalfEfficiency)
        }
    }

    struct Leg: Equatable {
        var sampleCount: Int
        /// Blank unless the leg has enough samples and coverage (D9).
        var average: Double?
        var median: Double?
        var minimum: Double?
        var maximum: Double?
        var startHeartRate: Double?
        var endHeartRate: Double?
        /// Keyed by the offsets in `recoveryOffsets`. Only a walk or cooldown straight after a run
        /// has any (D11).
        var recoveryDrops: [TimeInterval: Double] = [:]
    }

    // MARK: - Analysis

    /// One run's figures, and each leg's by its `workout_intervals.csv` row id.
    static func analyze(_ run: RecordedRun,
                        samples: WorkoutSamples) -> (workout: Workout, legs: [String: Leg]) {
        let heartRate = samples.heartRate.sorted { $0.start < $1.start }
        let running = run.runLegs.flatMap(\.activeWindows).sorted { $0.start < $1.start }
        let runningSeconds = running.reduce(0) { $0 + $1.duration }

        let whole = Self.heartRate(in: running, samples: heartRate)
        let halves = split(running)
        let first = Self.heartRate(in: halves.first, samples: heartRate)
        let second = Self.heartRate(in: halves.second, samples: heartRate)

        // D8: withheld when the run, or either half, is short of coverage — or there is no running.
        let insufficient = [whole.coverage, first.coverage, second.coverage]
            .contains { ($0 ?? 0) < minimumCoverage }

        let workout = Workout(
            runningSeconds: runningSeconds,
            running: whole,
            runningDistance: distance(in: running, samples: samples.distance),
            insufficientHeartRate: insufficient,
            firstHalfHeartRate: insufficient ? nil : first.average,
            secondHalfHeartRate: insufficient ? nil : second.average,
            firstHalfSpeed: speed(distance(in: halves.first, samples: samples.distance),
                                  over: total(halves.first)),
            secondHalfSpeed: speed(distance(in: halves.second, samples: samples.distance),
                                   over: total(halves.second)))

        var legs: [String: Leg] = [:]
        for (index, leg) in run.legs.enumerated() {
            let stats = Self.heartRate(in: leg.activeWindows, samples: heartRate)
            let enough = stats.sampleCount >= minimumLegSamples
                && (stats.coverage ?? 0) >= minimumCoverage
            var result = Leg(sampleCount: stats.sampleCount)
            if enough {
                result.average = stats.average
                result.median = stats.median
                result.minimum = stats.minimum
                result.maximum = stats.maximum
                result.startHeartRate = leg.activeWindows.first.flatMap { reading(at: $0.start, heartRate) }
                result.endHeartRate = leg.activeWindows.last.flatMap { reading(at: $0.end, heartRate) }
            }
            // D11: a walk or cooldown that directly follows a run.
            if [.walk, .cooldown].contains(leg.phase), index > 0, run.legs[index - 1].phase == .run,
               let runEnd = run.legs[index - 1].activeWindows.last?.end,
               let legEnd = leg.activeWindows.last?.end,
               let atRunEnd = reading(at: runEnd, heartRate) {
                for offset in recoveryOffsets {
                    let moment = runEnd.addingTimeInterval(offset)
                    guard moment <= legEnd, let later = reading(at: moment, heartRate) else { continue }
                    result.recoveryDrops[offset] = atRunEnd - later
                }
            }
            legs[leg.intervalLogID] = result
        }
        return (workout, legs)
    }

    // MARK: - Heart rate over windows (D6, D7, D12)

    /// `samples` must be sorted by time.
    static func heartRate(in windows: [DateInterval], samples: [WorkoutSample]) -> HeartRate {
        var result = HeartRate()
        guard !windows.isEmpty else { return result }

        var values: [Double] = []
        var covered = 0.0
        var weighted = 0.0
        var largestGap = 0.0
        for window in windows {
            // D12: inside means start-inclusive, end-exclusive.
            let inside = samples.filter { $0.start >= window.start && $0.start < window.end }
            values += inside.map(\.value)

            let times = inside.map(\.start)
            guard !times.isEmpty else {
                largestGap = max(largestGap, window.duration)
                continue
            }
            largestGap = max(largestGap,
                             times[0].timeIntervalSince(window.start),
                             window.end.timeIntervalSince(times[times.count - 1]))
            for (i, sample) in inside.enumerated() {
                if i > 0 { largestGap = max(largestGap, times[i].timeIntervalSince(times[i - 1])) }
                // The moments nearer this sample than its neighbours, within the tolerance.
                let lower = i == 0 ? window.start : midpoint(times[i - 1], times[i])
                let upper = i == times.count - 1 ? window.end : midpoint(times[i], times[i + 1])
                let from = max(lower, times[i].addingTimeInterval(-sampleTolerance))
                let to = min(upper, times[i].addingTimeInterval(sampleTolerance))
                let credit = max(0, to.timeIntervalSince(from))
                covered += credit
                weighted += credit * sample.value
            }
        }

        let duration = total(windows)
        result.sampleCount = values.count
        result.coverage = duration > 0 ? covered / duration : nil
        result.largestGap = largestGap
        result.average = covered > 0 ? weighted / covered : nil
        let sorted = values.sorted()
        if !sorted.isEmpty {
            let middle = sorted.count / 2
            result.median = sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            result.minimum = sorted.first
            result.maximum = sorted.last
        }
        return result
    }

    /// D10, D11: the sample nearest `moment`, within the tolerance, from any leg. The earlier of
    /// two equally near.
    static func reading(at moment: Date, _ samples: [WorkoutSample]) -> Double? {
        var best: (distance: TimeInterval, value: Double)?
        for sample in samples {
            let distance = abs(sample.start.timeIntervalSince(moment))
            guard distance <= sampleTolerance else { continue }
            if best == nil || distance < best!.distance { best = (distance, sample.value) }
        }
        return best?.value
    }

    // MARK: - Distance (D14) and the split (D13)

    /// The distance samples overlapping `windows`, each prorated by its share inside them. Nil when
    /// none overlaps at all.
    static func distance(in windows: [DateInterval], samples: [WorkoutSample]) -> Double? {
        var total = 0.0
        var any = false
        for sample in samples {
            let span = sample.end.timeIntervalSince(sample.start)
            for window in windows {
                if span > 0 {
                    let overlap = min(sample.end, window.end).timeIntervalSince(max(sample.start, window.start))
                    guard overlap > 0 else { continue }
                    total += sample.value * overlap / span
                    any = true
                } else if sample.start >= window.start && sample.start < window.end {
                    total += sample.value
                    any = true
                }
            }
        }
        return any ? total : nil
    }

    /// Cuts sorted windows at half their total time — cumulative running time, not the clock — and
    /// splits the window that contains that moment.
    static func split(_ windows: [DateInterval]) -> (first: [DateInterval], second: [DateInterval]) {
        let half = total(windows) / 2
        var first: [DateInterval] = []
        var second: [DateInterval] = []
        var elapsed = 0.0
        for window in windows {
            if elapsed >= half {
                second.append(window)
            } else if elapsed + window.duration <= half {
                first.append(window)
            } else {
                let cut = window.start.addingTimeInterval(half - elapsed)
                first.append(DateInterval(start: window.start, end: cut))
                second.append(DateInterval(start: cut, end: window.end))
            }
            elapsed += window.duration
        }
        return (first, second)
    }

    // MARK: - Arithmetic (D15–D17)

    static func total(_ windows: [DateInterval]) -> Double {
        windows.reduce(0) { $0 + $1.duration }
    }

    static func speed(_ meters: Double?, over seconds: Double) -> Double? {
        guard let meters, seconds > 0 else { return nil }
        return meters / seconds
    }

    static func pace(_ speed: Double?) -> Double? {
        guard let speed, speed > 0 else { return nil }
        return metersPerMile / speed
    }

    /// Meters per heartbeat.
    static func efficiency(_ speed: Double?, _ heartRate: Double?) -> Double? {
        guard let speed, let heartRate, heartRate > 0 else { return nil }
        return speed / (heartRate / 60)
    }

    /// (second − first) ÷ first × 100.
    static func percentChange(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second, first != 0 else { return nil }
        return (second - first) / first * 100
    }

    private static func midpoint(_ a: Date, _ b: Date) -> Date {
        a.addingTimeInterval(b.timeIntervalSince(a) / 2)
    }
}
