import Foundation
import XCTest
@testable import JamfReports

/// The score is Σ(weight × share) / Σ(weight) over the listed factors that have data. A
/// factor with no data drops out and the rest are rescaled; a factor at weight 0 is neither
/// scored nor missing.
final class SecurityScoreCalculatorTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor
    private typealias Measure = SecurityScoreMeasure

    private func score(
        _ factors: [Factor], _ measures: [Factor: Measure]
    ) -> SecurityScore {
        SecurityScoreCalculator.score(
            factors: factors, measures: Dictionary(uniqueKeysWithValues: measures.map {
                ($0.key.key, $0.value)
            }))
    }

    // MARK: - The weighted share

    /// FileVault 80% at 15, SIP 100% at 5: (80 x 15 + 100 x 5) / 20 = 1700 / 20 = 85.0.
    func testScoreIsTheWeightedShare() {
        let fileVault = Factor(.fileVault, weight: 15)
        let sip = Factor(.sip, weight: 5)
        let result = score([fileVault, sip], [
            fileVault: Measure(passing: 80, evaluated: 100),
            sip: Measure(passing: 100, evaluated: 100),
        ])
        XCTAssertEqual(result.value, 85.0, accuracy: 0.0001)
        XCTAssertEqual(result.grade, .b)
        XCTAssertEqual(result.available, [fileVault, sip])
        XCTAssertTrue(result.missing.isEmpty)
    }

    /// Every default native factor measured on 100 Macs (Secure Boot on the 50 that support
    /// it, patch compliance in device-title pairs): 7225 points of 85 weight is 85.0.
    /// 90 x 15 + 100 x 10 + 80 x 10 + 100 x 5 + 50 x 5 + 100 x 5 + 70 x 15 + 100 x 5
    /// + 80 x 10 + 95 x 5 = 1350 + 1000 + 800 + 500 + 250 + 500 + 1050 + 500 + 800 + 475.
    func testEveryNativeFactorMeasuredScoresOverTheirTotalWeight() {
        let shares: [(Int, Int)] = [
            (90, 100), (100, 100), (80, 100), (100, 100), (25, 50), (100, 100),
            (70, 100), (100, 100), (800, 1000), (95, 100),
        ]
        var measures: [String: Measure] = [:]
        for (factor, share) in zip(Factor.nativeDefaults, shares) {
            measures[factor.key] = Measure(passing: share.0, evaluated: share.1)
        }
        let result = SecurityScoreCalculator.score(
            factors: Factor.nativeDefaults, measures: measures)
        XCTAssertEqual(result.value, 85.0, accuracy: 0.0001)
        XCTAssertEqual(result.available.count, 10)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.basis,
                       "filevault=15,sip=10,firewall=10,gatekeeper=5,secure_boot=5,"
                       + "bootstrap_token=5,os_current=15,xprotect_current=5,"
                       + "patch_compliance=10,checked_in=5")
    }

    // MARK: - Missing data

    /// A factor with no measure drops out of the denominator and is listed as missing:
    /// (100 x 10) / 10 = 100, not (100 x 10 + 0 x 15) / 25.
    func testAFactorWithoutAMeasureIsMissingAndDropsOut() {
        let sip = Factor(.sip, weight: 10)
        let agent = Factor(.agent, weight: 15, target: "Falcon")
        let result = score([sip, agent], [sip: Measure(passing: 10, evaluated: 10)])
        XCTAssertEqual(result.value, 100.0, accuracy: 0.0001)
        XCTAssertEqual(result.available, [sip])
        XCTAssertEqual(result.missing, [agent])
        XCTAssertEqual(result.basis, "sip=10", "a factor that did not score is not in the basis")
    }

    /// A measure that judged no Mac has no share: the same as no measure.
    func testAFactorThatJudgedNoMacIsMissing() {
        let sip = Factor(.sip, weight: 10)
        let secureBoot = Factor(.secureBoot, weight: 5)
        let result = score([sip, secureBoot], [
            sip: Measure(passing: 5, evaluated: 10),
            secureBoot: Measure(passing: 0, evaluated: 0),
        ])
        XCTAssertEqual(result.value, 50.0, accuracy: 0.0001)
        XCTAssertEqual(result.missing, [secureBoot])
        XCTAssertNil(Measure(passing: 0, evaluated: 0).share)
        XCTAssertNil(Measure(passing: 3, evaluated: -1).share)
    }

    /// An empty list, and a list where nothing has data, score nothing: 0, grade F, no parts,
    /// and no basis to compare on.
    func testNothingMeasuredScoresNothing() {
        let empty = SecurityScoreCalculator.score(factors: [], measures: [:])
        XCTAssertEqual(empty, .empty)
        XCTAssertEqual(empty.value, 0)
        XCTAssertEqual(empty.grade, .f)
        XCTAssertTrue(empty.parts.isEmpty)
        XCTAssertNil(empty.basis)

        let sip = Factor(.sip, weight: 10)
        let none = score([sip], [:])
        XCTAssertEqual(none.value, 0)
        XCTAssertEqual(none.grade, .f)
        XCTAssertEqual(none.missing, [sip])
        XCTAssertNil(none.basis)
    }

    // MARK: - Weight 0

    /// A factor at weight 0 is switched off: it is not scored and not listed as missing,
    /// whether or not it has a measure.
    func testAZeroWeightFactorIsNeitherScoredNorMissing() {
        let sip = Factor(.sip, weight: 10)
        let withMeasure = Factor(.firewall, weight: 0)
        let withoutMeasure = Factor(.gatekeeper, weight: 0)
        let result = score([sip, withMeasure, withoutMeasure], [
            sip: Measure(passing: 10, evaluated: 10),
            withMeasure: Measure(passing: 0, evaluated: 10),
        ])
        XCTAssertEqual(result.value, 100.0, accuracy: 0.0001)
        XCTAssertEqual(result.available, [sip])
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.basis, "sip=10")
    }

    func testEveryFactorAtZeroWeightScoresNothing() {
        let sip = Factor(.sip, weight: 0)
        let result = score([sip], [sip: Measure(passing: 10, evaluated: 10)])
        XCTAssertEqual(result, .empty)
    }

    // MARK: - Rounding and shares

    /// One decimal, as summary.json stores it: 1/3 is 33.3 and 2/3 is 66.7.
    func testValueIsRoundedToOneDecimal() {
        let sip = Factor(.sip, weight: 7)
        XCTAssertEqual(score([sip], [sip: Measure(passing: 1, evaluated: 3)]).value, 33.3)
        XCTAssertEqual(score([sip], [sip: Measure(passing: 2, evaluated: 3)]).value, 66.7)
    }

    /// A count above the total contributes exactly 100 (a fleet that shrank between two
    /// collects), never 109; renormalising over the factors that have data: with SIP at 50,
    /// (100 x 15 + 50 x 15) / 30 = 75.0.
    func testAShareIsClampedToOneHundred() {
        XCTAssertEqual(Measure(passing: 655, evaluated: 600).share, 100)
        XCTAssertEqual(Measure(passing: -4, evaluated: 600).share, 0)
        let fileVault = Factor(.fileVault, weight: 15)
        let sip = Factor(.sip, weight: 15)
        let result = score([fileVault, sip], [
            fileVault: Measure(passing: 655, evaluated: 600),
            sip: Measure(passing: 300, evaluated: 600),
        ])
        XCTAssertEqual(result.value, 75.0, accuracy: 0.0001)
    }

    // MARK: - Points

    /// Each part adds its weight's share of the total weight; together they are the score.
    func testPointsOfEachPartSumToTheValue() throws {
        let fileVault = Factor(.fileVault, weight: 15)
        let sip = Factor(.sip, weight: 10)
        let firewall = Factor(.firewall, weight: 10)
        let missing = Factor(.gatekeeper, weight: 5)
        let result = score([fileVault, sip, firewall, missing], [
            fileVault: Measure(passing: 90, evaluated: 100),
            sip: Measure(passing: 100, evaluated: 100),
            firewall: Measure(passing: 80, evaluated: 100),
        ])
        // (1350 + 1000 + 800) / 35 = 90.0
        XCTAssertEqual(result.value, 90.0, accuracy: 0.0001)
        let points = result.parts.map { result.points(of: $0) }
        XCTAssertEqual(points[0], 1350.0 / 35, accuracy: 0.0001)
        XCTAssertEqual(points[1], 1000.0 / 35, accuracy: 0.0001)
        XCTAssertEqual(points[2], 800.0 / 35, accuracy: 0.0001)
        XCTAssertEqual(points.reduce(0, +), result.value, accuracy: 0.05,
                       "the value is rounded to a tenth, the points are not")
        XCTAssertEqual(result.parts.map(\.share), [90, 100, 80])
        XCTAssertEqual(result.parts[0].measure, Measure(passing: 90, evaluated: 100))
    }

    func testPointsOfAPartOfAnEmptyScoreAreZero() {
        let part = SecurityScore.Part(
            factor: Factor(.sip, weight: 10), measure: Measure(passing: 1, evaluated: 1),
            share: 100)
        XCTAssertEqual(SecurityScore.empty.points(of: part), 0)
    }

    // MARK: - Grades

    func testGradeBanding() {
        XCTAssertEqual(SecurityScore.Grade.from(value: 99), .aPlus)
        XCTAssertEqual(SecurityScore.Grade.from(value: 95), .aPlus)
        XCTAssertEqual(SecurityScore.Grade.from(value: 94.9), .a)
        XCTAssertEqual(SecurityScore.Grade.from(value: 90), .a)
        XCTAssertEqual(SecurityScore.Grade.from(value: 89), .b)
        XCTAssertEqual(SecurityScore.Grade.from(value: 80), .b)
        XCTAssertEqual(SecurityScore.Grade.from(value: 75), .c)
        XCTAssertEqual(SecurityScore.Grade.from(value: 65), .d)
        XCTAssertEqual(SecurityScore.Grade.from(value: 50), .f)
        XCTAssertEqual(SecurityScore.Grade.from(value: nil), .f)
        XCTAssertEqual(SecurityScore.Grade.from(value: .nan), .f)
    }

    /// The grade is read from the rounded value the summary stores.
    func testTheGradeFollowsTheRoundedValue() {
        let sip = Factor(.sip, weight: 1)
        // 94.96% rounds to 95.0, which is A+.
        let result = score([sip], [sip: Measure(passing: 9496, evaluated: 10_000)])
        XCTAssertEqual(result.value, 95.0)
        XCTAssertEqual(result.grade, .aPlus)
    }
}
