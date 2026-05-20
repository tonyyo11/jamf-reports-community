import Foundation
import XCTest
@testable import JamfReports

/// Tests for the Stage-1 read-only smart-group service.
///
/// Covers (1) the templates+preview JSON decode contract from PR #205, (2) feature-detect
/// behavior when `pro sg` is missing, and (3) the executor → service error translation.
/// No real `Process` involvement — uses `MockCLIExecutor` to inject canned output.
@MainActor
final class SmartGroupTemplateServiceTests: XCTestCase {

    // MARK: - listTemplates

    func testListTemplatesDecodesPR205Shape() async throws {
        // Fixture mirrors the actual shape emitted by `pro sg templates --output json`
        // built from PR #205 head c2ed951 — category-prefixed slugs and integer
        // defaults with a typed `type` discriminator. Real output has 23 templates;
        // three is enough to exercise the decode + sort + int-default cases.
        let json = """
        [
          {
            "slug": "mdm/stale-checkin",
            "category": "mdm",
            "description": "Computers that have not checked in for N+ days.",
            "params": [
              {
                "name": "days",
                "type": "int",
                "default": 7,
                "description": "Days since last inventory update",
                "required": false
              }
            ]
          },
          {
            "slug": "updates/os-version-below",
            "category": "updates",
            "description": "Computers running an OS version below a threshold.",
            "params": [
              {
                "name": "below-version",
                "type": "version",
                "default": null,
                "description": "Threshold OS version (e.g. 15.0)",
                "required": true
              }
            ]
          },
          {
            "slug": "compliance/firewall-disabled",
            "category": "compliance",
            "description": "Macs with the application firewall disabled",
            "params": []
          }
        ]
        """
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupTemplates(profile: "harbor"), .success(Data(json.utf8))),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        let templates = try await service.listTemplates(profile: "harbor")

        XCTAssertEqual(templates.count, 3)
        // Sort: compliance < mdm < updates alphabetically by category, then by slug.
        XCTAssertEqual(templates[0].slug, "compliance/firewall-disabled")
        XCTAssertTrue(templates[0].params.isEmpty)
        XCTAssertEqual(templates[1].slug, "mdm/stale-checkin")
        XCTAssertEqual(templates[1].params.count, 1)
        XCTAssertEqual(templates[1].params[0].name, "days")
        // Int default `7` normalizes to "7" so the SwiftUI TextField binding works.
        XCTAssertEqual(templates[1].params[0].default, "7")
        XCTAssertEqual(templates[1].params[0].type, "int")
        XCTAssertFalse(templates[1].params[0].required)
        XCTAssertEqual(templates[2].slug, "updates/os-version-below")
        XCTAssertEqual(templates[2].params[0].name, "below-version")
        XCTAssertNil(templates[2].params[0].default)
        XCTAssertEqual(templates[2].params[0].type, "version")
        XCTAssertTrue(templates[2].params[0].required)
    }

    func testListTemplatesSortsByCategoryThenSlug() async throws {
        // Out-of-order input; service must return alphabetical-by-category, then-by-slug.
        let json = """
        [
          {"slug": "zeta", "category": "updates", "description": "", "params": []},
          {"slug": "alpha", "category": "encryption", "description": "", "params": []},
          {"slug": "beta", "category": "updates", "description": "", "params": []}
        ]
        """
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupTemplates(profile: "p"), .success(Data(json.utf8))),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        let templates = try await service.listTemplates(profile: "p")

        XCTAssertEqual(templates.map(\.slug), ["alpha", "beta", "zeta"])
    }

    func testListTemplatesDecodeFailureWrapsError() async {
        // Plausible-but-wrong shape — should not crash, should surface decodeFailed.
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupTemplates(profile: "p"), .success(Data(#"{"unexpected": "shape"}"#.utf8))),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        do {
            _ = try await service.listTemplates(profile: "p")
            XCTFail("expected decodeFailed")
        } catch SmartGroupTemplateServiceError.decodeFailed {
            // expected
        } catch {
            XCTFail("expected decodeFailed, got \(error)")
        }
    }

    // MARK: - Feature detection

    func testUnknownCommandStderrTranslatesToFeatureNotAvailable() async {
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupTemplates(profile: "p"), .failure(
                CLIExecutorError.nonZeroExit(code: 2, stderr: "Error: unknown command \"sg\" for \"jamf-cli pro\"")
            )),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        do {
            _ = try await service.listTemplates(profile: "p")
            XCTFail("expected featureNotAvailable")
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            // expected
        } catch {
            XCTFail("expected featureNotAvailable, got \(error)")
        }
    }

    func testBinaryNotFoundTranslatesToFeatureNotAvailable() async {
        // Same UI outcome (hide buttons) whether jamf-cli is uninstalled or just too old.
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupTemplates(profile: "p"), .failure(
                CLIExecutorError.binaryNotFound("jamf-cli")
            )),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        do {
            _ = try await service.listTemplates(profile: "p")
            XCTFail("expected featureNotAvailable")
        } catch SmartGroupTemplateServiceError.featureNotAvailable {
            // expected
        } catch {
            XCTFail("expected featureNotAvailable, got \(error)")
        }
    }

    func testUnknownTemplateStderrTranslatesToUnknownTemplate() async {
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupPreview(profile: "p", templateSlug: "no-such-template", params: [:]), .failure(
                CLIExecutorError.nonZeroExit(code: 2, stderr: "Error: unknown template: no-such-template\n")
            )),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        do {
            _ = try await service.preview(profile: "p", templateSlug: "no-such-template", params: [:])
            XCTFail("expected unknownTemplate")
        } catch SmartGroupTemplateServiceError.unknownTemplate {
            // expected
        } catch {
            XCTFail("expected unknownTemplate, got \(error)")
        }
    }

    func testGenericExecutionFailurePassesThrough() async {
        let executor = MockCLIExecutor(canned: [
            (.proSmartGroupTemplates(profile: "p"), .failure(
                CLIExecutorError.nonZeroExit(code: 3, stderr: "Error: HTTP 401 Unauthorized")
            )),
        ])
        let service = SmartGroupTemplateService(executor: executor)

        do {
            _ = try await service.listTemplates(profile: "p")
            XCTFail("expected executionFailed")
        } catch SmartGroupTemplateServiceError.executionFailed(let code, _) {
            XCTAssertEqual(code, 3)
        } catch {
            XCTFail("expected executionFailed, got \(error)")
        }
    }

    // MARK: - Feature-detect helper (pure)

    func testStderrIndicatesUnknownCommandMatchesVariants() {
        XCTAssertTrue(SmartGroupTemplateService.stderrIndicatesUnknownCommand("unknown command \"sg\""))
        XCTAssertTrue(SmartGroupTemplateService.stderrIndicatesUnknownCommand("Error: unknown subcommand"))
        XCTAssertTrue(SmartGroupTemplateService.stderrIndicatesUnknownCommand("UNKNOWN COMMAND"))
        XCTAssertFalse(SmartGroupTemplateService.stderrIndicatesUnknownCommand("HTTP 401 Unauthorized"))
        XCTAssertFalse(SmartGroupTemplateService.stderrIndicatesUnknownCommand(""))
    }

    func testStderrIndicatesUnknownTemplateMatchesVariants() {
        XCTAssertTrue(SmartGroupTemplateService.stderrIndicatesUnknownTemplate("unknown template: foo"))
        XCTAssertTrue(SmartGroupTemplateService.stderrIndicatesUnknownTemplate("Error: template not found"))
        XCTAssertFalse(SmartGroupTemplateService.stderrIndicatesUnknownTemplate("HTTP 500"))
    }

    // MARK: - Preview decoder (pure)

    func testDecodePreviewObjectShapeExtractsBodyAndCount() {
        let json = #"""
        {
          "body": {"name": "X", "criteria": []},
          "estimated_match_count": 42
        }
        """#
        let preview = SmartGroupTemplateService.decodePreview(Data(json.utf8))
        XCTAssertEqual(preview.estimatedMatchCount, 42)
        // Body should be present and re-pretty-printed with sorted keys.
        XCTAssertTrue(preview.bodyJSON.contains("\"name\""))
        XCTAssertTrue(preview.bodyJSON.contains("\"criteria\""))
    }

    func testDecodePreviewObjectShapeMissingCountReturnsNil() {
        let json = #"{"body": {"name": "X"}}"#
        let preview = SmartGroupTemplateService.decodePreview(Data(json.utf8))
        XCTAssertNil(preview.estimatedMatchCount)
        XCTAssertTrue(preview.bodyJSON.contains("\"name\""))
    }

    func testDecodePreviewRawBodyShapeFallback() {
        // If PR #205 ends up shipping the raw body without an envelope, the
        // decoder must still produce a sensible bodyJSON string.
        let json = #"{"name": "Stale 90d", "criteria": []}"#
        let preview = SmartGroupTemplateService.decodePreview(Data(json.utf8))
        XCTAssertNil(preview.estimatedMatchCount)
        XCTAssertTrue(preview.bodyJSON.contains("\"name\""))
    }

    func testDecodePreviewMalformedReturnsRawString() {
        // Last-resort path: garbage in → garbage-but-string out (no crash).
        let preview = SmartGroupTemplateService.decodePreview(Data("not-json".utf8))
        XCTAssertNil(preview.estimatedMatchCount)
        XCTAssertEqual(preview.bodyJSON, "not-json")
    }
}

// MARK: - Mock CLIExecutor

/// In-memory executor that returns canned results keyed by the literal `argv` shape
/// of the expected command. argv-as-key avoids requiring `CLICommand: Hashable`
/// retroactively (Swift 6 rejects retro-public conformances across modules), and
/// matches what the production executor actually invokes.
///
/// Lives in this file because it's only used by these tests; promote to a shared
/// helper if a second test file needs it.
final class MockCLIExecutor: CLIExecutor, @unchecked Sendable {
    enum Outcome {
        case success(Data)
        case failure(CLIExecutorError)
    }

    private let canned: [[String]: Outcome]

    /// Accepts pairs rather than a dictionary literal so `CLICommand` doesn't
    /// need a retro-public `Hashable` conformance across the test boundary.
    init(canned: [(CLICommand, Outcome)]) {
        var byArgv: [[String]: Outcome] = [:]
        byArgv.reserveCapacity(canned.count)
        for (command, outcome) in canned {
            byArgv[command.argv] = outcome
        }
        self.canned = byArgv
    }

    func execute(_ command: CLICommand) async throws -> Data {
        guard let outcome = canned[command.argv] else {
            throw CLIExecutorError.nonZeroExit(
                code: -1,
                stderr: "no canned outcome for argv: \(command.argv)"
            )
        }
        switch outcome {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}
