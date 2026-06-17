import Foundation
import XCTest
@testable import JamfReports

/// Unit tests for ScaffoldService.proposeEAs — type guessing, exclusion of
/// mapped/built-in headers, and sample-value selection.
final class ScaffoldEAProposalTests: XCTestCase {

    // MARK: - Type guessing

    func test_proposeEAs_booleanFromSampleValue() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["CrowdStrike Falcon Status"],
            sampleRows: [["Installed"], ["Not Installed"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.type, "boolean")
        XCTAssertEqual(proposals.first?.sampleValue, "Installed")
    }

    func test_proposeEAs_dateFromHeader() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Certificate Expiry Date"],
            sampleRows: [["2026-09-01"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "date")
    }

    func test_proposeEAs_dateFromSampleValue() {
        // Header gives no date hint, but the sample parses as a date.
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Kerberos SSO password_expires"],
            sampleRows: [["2026-12-31 09:00:00"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "date")
    }

    func test_proposeEAs_dateFollowedByProseIsTextNotDate() {
        // A status string that *starts* with a timestamp must not be typed as a
        // date EA (would mis-parse). Header gives no date hint.
        let proposals = ScaffoldService.proposeEAs(
            headers: ["AAP-Status"],
            sampleRows: [["2026-04-07 12:58:59 -0600: Completed: Collecting patches"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "text")
    }

    func test_proposeEAs_dateWithTimezoneStillDate() {
        // A bare timestamp with a timezone is still a date (header has no date hint,
        // so this exercises the sample regex, not the header keyword).
        let proposals = ScaffoldService.proposeEAs(
            headers: ["AAP-LastEvent"],
            sampleRows: [["2026-04-07 12:58:59 -0600"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "date")
    }

    func test_proposeEAs_versionFromHeader() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["SysTrack Agent Version"],
            sampleRows: [["9.1.2"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "version")
    }

    func test_proposeEAs_versionFromSampleValue() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["McAfee Agent"],
            sampleRows: [["5.7.6"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "version")
    }

    func test_proposeEAs_percentageFromSampleValue() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Patch Coverage"],
            sampleRows: [["87%"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "percentage")
    }

    func test_proposeEAs_textFallback() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Notes Field"],
            sampleRows: [["arbitrary free text"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "text")
    }

    func test_proposeEAs_booleanFromTwoDistinctSamples() {
        // Sample value "enabled" alone is in the boolean set, but verify the
        // distinct-values path also classifies as boolean.
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Some Toggle"],
            sampleRows: [["On"], ["Off"], ["On"], ["Off"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.type, "boolean")
    }

    // MARK: - Exclusions

    func test_proposeEAs_skipsMappedHeaders() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["FileVault 2 - Status", "Custom EA Field"],
            sampleRows: [["Encrypted", "yes"]],
            mappedHeaders: ["FileVault 2 - Status"]
        )
        XCTAssertEqual(proposals.map(\.column), ["Custom EA Field"],
                       "mapped headers must be excluded from EA proposals")
    }

    func test_proposeEAs_skipsMappedHeaders_normalizedCompare() {
        // mappedHeaders differs in case/spacing; normalized compare still excludes.
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Computer  Name", "EA One"],
            sampleRows: [["mac-1", "yes"]],
            mappedHeaders: ["computer name"]
        )
        XCTAssertEqual(proposals.map(\.column), ["EA One"])
    }

    func test_proposeEAs_skipsBuiltInHeaders() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Serial Number", "Model", "Department", "My EA"],
            sampleRows: [["C02XYZ", "MacBookPro18,1", "IT", "compliant"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.map(\.column), ["My EA"],
                       "built-in identity/inventory headers must be excluded")
    }

    // MARK: - Sample value selection

    func test_proposeEAs_picksFirstNonEmptySample() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Agent State"],
            sampleRows: [[""], ["   "], ["Connected"], ["Disconnected"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.sampleValue, "Connected",
                       "first non-empty (trimmed) sample value must be selected")
    }

    func test_proposeEAs_emptySampleValueWhenAllBlank() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Mystery"],
            sampleRows: [[""], [""]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.sampleValue, "")
        XCTAssertEqual(proposals.first?.type, "text",
                       "no sample → text fallback")
    }

    // MARK: - Naming + ordering

    func test_proposeEAs_titleCasesNameAndKeepsExactColumn() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["systrack install status"],
            sampleRows: [["yes"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.first?.name, "Systrack Install Status")
        XCTAssertEqual(proposals.first?.column, "systrack install status",
                       "exact CSV header must be preserved as column")
    }

    func test_proposeEAs_sortedByColumn() {
        let proposals = ScaffoldService.proposeEAs(
            headers: ["Zeta EA", "Alpha EA", "Mid EA"],
            sampleRows: [["x", "y", "z"]],
            mappedHeaders: []
        )
        XCTAssertEqual(proposals.map(\.column), ["Alpha EA", "Mid EA", "Zeta EA"])
    }
}
