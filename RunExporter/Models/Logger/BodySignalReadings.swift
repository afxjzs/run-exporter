import Foundation

/// One reading per body area, as given at the end of a running leg.
///
/// Mirrors the five severity columns of `RunLog` exactly — same areas, same 0–10 scale — so a leg's
/// readings and the post-run readings are the same measurement taken at different moments, rather
/// than two numbers that happen to share a range.
///
/// **Optional throughout, and the two empty-looking answers are different.** `nil` means the
/// question was never asked: every phase of every interval workout, every recovery walk, and a leg
/// the accumulated target ended without a prompt. `0` means it was asked and the answer was
/// nothing, which is a real measurement. The export keeps them apart as blank and `0`, which is the
/// rule `ExportBuilder`'s README states for the whole file.
struct BodySignalReadings: Equatable {

    var lowerBack: Double?
    var leftAnkle: Double?
    var rightAnkle: Double?
    var leftKnee: Double?
    var rightKnee: Double?

    init(lowerBack: Double? = nil,
         leftAnkle: Double? = nil,
         rightAnkle: Double? = nil,
         leftKnee: Double? = nil,
         rightKnee: Double? = nil) {
        self.lowerBack = lowerBack
        self.leftAnkle = leftAnkle
        self.rightAnkle = rightAnkle
        self.leftKnee = leftKnee
        self.rightKnee = rightKnee
    }

    /// Reading for one area, by the same `BodyArea` the run log and its editor use.
    subscript(area: BodyArea) -> Double? {
        get {
            switch area {
            case .lowerBack: return lowerBack
            case .leftAnkle: return leftAnkle
            case .rightAnkle: return rightAnkle
            case .leftKnee: return leftKnee
            case .rightKnee: return rightKnee
            }
        }
        set {
            switch area {
            case .lowerBack: lowerBack = newValue
            case .leftAnkle: leftAnkle = newValue
            case .rightAnkle: rightAnkle = newValue
            case .leftKnee: leftKnee = newValue
            case .rightKnee: rightKnee = newValue
            }
        }
    }

    /// True when nothing was asked. Distinct from "asked, and every answer was zero".
    var isEmpty: Bool { BodyArea.allCases.allSatisfy { self[$0] == nil } }

    /// True when at least one area reads above zero.
    ///
    /// What the end-of-leg sheet requires before it will save. Every row starts at zero, so without
    /// this the sheet would record five zeros for a leg nobody looked at — five measurements the
    /// runner never made. Requiring one edit is what turns the other four zeros into real answers.
    var hasAnyNonZero: Bool { BodyArea.allCases.contains { (self[$0] ?? 0) > 0 } }
}
