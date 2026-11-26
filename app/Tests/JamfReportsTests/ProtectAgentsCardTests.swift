import XCTest
@testable import JamfReports

/// What the Protect agents card says for each finding: a count, or a dash and why.
@MainActor
final class ProtectAgentsCardTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_795_000_000)

    func testACountReadsNOfMAndAnUnevaluatedFindingIsADash() {
        XCTAssertEqual(ProtectAgentsCard.value(.init(
            share: .init(met: 3, of: 11), baseline: nil, notEvaluated: nil)), "3 of 11")
        XCTAssertEqual(ProtectAgentsCard.value(.unavailable(.noCollectionTime)), "—")
    }

    func testTheCaptionNamesTheBaselineOrTheReason() throws {
        let published = try XCTUnwrap(ProtectAgentsCard.caption(.init(
            share: .init(met: 0, of: 1), baseline: .published(id: 40_215, created: date),
            notEvaluated: nil)))
        XCTAssertTrue(published.hasPrefix("Compared with version 40215, published "), published)
        let installer = try XCTUnwrap(ProtectAgentsCard.caption(.init(
            share: .init(met: 0, of: 1), baseline: .installer(version: "5.1", firstSeen: date),
            notEvaluated: nil)))
        XCTAssertTrue(installer.hasPrefix("Compared with installer 5.1, first seen "), installer)
        XCTAssertEqual(ProtectAgentsCard.caption(.unavailable(.noPublishedVersions)),
                       "Not evaluated: Protect published no signature versions")
        XCTAssertNil(ProtectAgentsCard.caption(.init(
            share: .init(met: 0, of: 0), baseline: nil, notEvaluated: nil)))
    }

    func testEveryReasonHasWords() {
        let reasons: [ProtectAgentHealth.Unavailable] = [
            .notCollected(kind: "protect-installer"), .unreadable(kind: "protect-installer"),
            .noPublishedVersions, .noVersionOldEnough, .noInstallerVersion,
            .installerNotAVersion("x"), .installerTooNew(version: "5.1", firstSeen: date),
            .firstSeenUnknown("5.1"), .noCollectionTime,
        ]
        let texts = reasons.map(ProtectAgentsCard.text)
        XCTAssertEqual(Set(texts).count, reasons.count, "each reason reads differently")
        XCTAssertFalse(texts.contains(where: \.isEmpty))
        XCTAssertEqual(Set(reasons.map(\.englishText)).count, reasons.count)
    }
}
