import Foundation

/// Computes the fleet-wide weighted security score from what each listed factor measured.
///
/// A factor with no measure (or one that judged no Mac) is listed as missing and its weight
/// is left out of the denominator, so a tenant without an EDR agent gets a score comparable to
/// one that has it. A factor at weight 0 is neither scored nor listed as missing.
enum SecurityScoreCalculator {
    /// `measures` is keyed by `SecurityScoreFactor.key`.
    static func score(
        factors: [SecurityScoreFactor], measures: [String: SecurityScoreMeasure]
    ) -> SecurityScore {
        var parts: [SecurityScore.Part] = []
        var missing: [SecurityScoreFactor] = []
        var weightedSum = 0.0
        var totalWeight = 0.0
        for factor in factors where factor.weight > 0 {
            guard let measure = measures[factor.key], let share = measure.share else {
                missing.append(factor)
                continue
            }
            parts.append(.init(factor: factor, measure: measure, share: share))
            weightedSum += share * factor.weight
            totalWeight += factor.weight
        }
        guard totalWeight > 0 else {
            return SecurityScore(value: 0, grade: .f, parts: [], missing: missing)
        }
        let rounded = (weightedSum / totalWeight * 10).rounded() / 10
        return SecurityScore(
            value: rounded, grade: .from(value: rounded), parts: parts, missing: missing)
    }
}
