import XCTest
@testable import JamfReports

/// Translated text must never reach a report, a log line, a stored file or a comparison.
final class LocalizationValueTests: XCTestCase {
    private let marker = "\u{27E6}"

    /// A label the GUI reads first must still read English when a report reads it next: a
    /// `static let` froze the first language it was read in.
    func testLabelReadByTheGUIFirstStaysEnglishForAReport() {
        let labels: [() -> String] = [
            { SecurityControlPolicy.hardwareEncryptedFileVaultOffLabel },
            { SecurityControlPolicy.hardwareEncryptedFileVaultOffShortLabel },
            { BinaryMissing.shortLabel },
            { FailureCause.keychainLockedHint },
            { FailureCause.retiredGatewayHint },
            { CLIBridge.keychainLockedDetail },
            { PlatformScopeLevel.organizationLevelReason },
        ]
        for label in labels {
            let shown = Localization.$isPseudo.withValue(true) { label() }
            XCTAssertTrue(shown.contains(marker), shown)
            let reported = Localization.$isPseudo.withValue(true) {
                Localization.english { label() }
            }
            XCTAssertFalse(reported.contains(marker), reported)
        }
    }

    func testEnglishDescriptionOfATranslatedErrorIsEnglish() {
        let error: Error = CLIBridgeError.tickLockHeld
        let text = Localization.$isPseudo.withValue(true) {
            (error.localizedDescription, error.englishDescription)
        }
        XCTAssertTrue(text.0.contains(marker), text.0)
        XCTAssertFalse(text.1.contains(marker), text.1)
    }

    /// The refusal text is logged and carried by `wrongProduct`, so it is English.
    func testProRefusalIsEnglish() throws {
        var resolved = ProfileAuthMethod.Resolved(authMethod: "platform", isTenantLevel: false)
        resolved.isOrganizationLevel = true
        let reason = try XCTUnwrap(Localization.$isPseudo.withValue(true) {
            resolved.proRefusal(profile: "Example", operation: "backup")
        })
        XCTAssertFalse(reason.contains(marker), reason)
        XCTAssertFalse(CollectRouter.schoolBackupReason(profile: "Example").contains(marker))
    }

    /// The app's own findings carry translated names, so their jump link goes by category.
    func testAppFindingsRouteByCategoryWhateverTheirName() {
        let names = ["Geräte mit fehlgeschlagenen Befehlen", "Contact gap name", "Mobile name"]
        let categories = ["Command health", "Contact gap", MobileFinding.category]
        let tabs: [Tab] = [.devices, .devices, .mobileFleet]
        for (index, category) in categories.enumerated() {
            let finding = AuditFinding(
                name: names[index], affected: 1, category: category,
                recommendation: "", severity: "WARNING")
            XCTAssertEqual(auditActionDestination(for: finding)?.tab, tabs[index], category)
        }
        let category = Localization.$isPseudo.withValue(true) { MobileFinding.category }
        XCTAssertFalse(category.contains(marker), "matched and sent to the AI input")
    }

    /// No `static let` holds text from `L`: it would keep the first language it was read in.
    func testNoStaticLetHoldsTranslatedText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JamfReports")
        let pattern = try NSRegularExpression(
            pattern: #"static let \w+[^=\n]*=[ \t]*\n?[ \t]*\[?[ \t]*\n?[ \t]*\w*\(?(?<![\w.])L\("#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            if pattern.firstMatch(in: text, range: range) != nil { hits.append(url.lastPathComponent) }
        }
        XCTAssertEqual(hits, [])
    }
}
