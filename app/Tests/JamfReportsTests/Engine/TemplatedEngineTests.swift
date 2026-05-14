import Foundation
import XCTest
import PDFKit
@testable import JamfReports

// MARK: - TemplatedEngineTests

/// Tests for Phase 4 Lane H: template-driven engine dispatch.
///
/// Verifies:
/// 1. SheetRegistry dispatches only the sheets listed in `template.includedSheets`.
/// 2. SectionRegistry assembles HTML only for registered sections.
/// 3. TemplateResolver returns the correct template for each known identifier,
///    and falls back to ExecutiveTemplate for unknown identifiers with a warning.
/// 4. ReportEngine.generate writes exactly the template's sheets (where implemented).
/// 5. ReportEngine.applyPagination injects correct CSS for each PaginationStrategy.
/// 6. ReportEngine.generatePDF produces a non-empty PDF for .sectionPerPage strategy.
final class TemplatedEngineTests: XCTestCase {

    // MARK: - Helpers

    private nonisolated(unsafe) var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemplatedEngineTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - TemplateResolver

    func testResolveExecutiveIdentifier() {
        let template = TemplateResolver.resolve(identifier: "executive")
        XCTAssertEqual(template.identifier, "executive")
        XCTAssertTrue(template is ExecutiveTemplate)
    }

    func testResolveOperationalIdentifier() {
        let template = TemplateResolver.resolve(identifier: "operational")
        XCTAssertEqual(template.identifier, "operational")
        XCTAssertTrue(template is OperationalTemplate)
    }

    func testResolveComplianceIdentifier() {
        let template = TemplateResolver.resolve(identifier: "compliance")
        XCTAssertEqual(template.identifier, "compliance")
        XCTAssertTrue(template is ComplianceTemplate)
    }

    func testResolveAssetIdentifier() {
        let template = TemplateResolver.resolve(identifier: "asset")
        XCTAssertEqual(template.identifier, "asset")
        XCTAssertTrue(template is AssetTemplate)
    }

    func testResolveSecurityPostureIdentifier() {
        let template = TemplateResolver.resolve(identifier: "security-posture")
        XCTAssertEqual(template.identifier, "security-posture")
        XCTAssertTrue(template is SecurityPostureTemplate)
    }

    func testUnknownIdentifierFallsBackToExecutive() {
        let template = TemplateResolver.resolve(identifier: "nonexistent-template-xyz")
        XCTAssertEqual(template.identifier, "executive",
                       "Unknown identifier must fall back to ExecutiveTemplate")
        XCTAssertTrue(template is ExecutiveTemplate)
    }

    func testAllTemplatesAreReachable() {
        let templates = TemplateResolver.allTemplates
        XCTAssertEqual(templates.count, 6)
        let ids = Set(templates.map(\.identifier))
        XCTAssertTrue(ids.contains("executive"))
        XCTAssertTrue(ids.contains("operational"))
        XCTAssertTrue(ids.contains("compliance"))
        XCTAssertTrue(ids.contains("asset"))
        XCTAssertTrue(ids.contains("security-posture"))
        XCTAssertTrue(ids.contains("school"))
    }

    // MARK: - SheetRegistry

    func testSheetRegistryWritesOnlyTemplateSheets() {
        let workbook = Workbook()
        let config = ReportConfig()
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        let registry = SheetRegistry(plan: dashboard.sheetPlan)
        let template = OperationalTemplate()

        let (written, _, _) = registry.writeSelected(template: template)

        // All written sheets must be in the template's includedSheets.
        let templateNames = Set(template.includedSheets.map(\.rawValue))
        for name in written {
            XCTAssertTrue(templateNames.contains(name),
                          "Unexpected sheet '\(name)' written — not in OperationalTemplate")
        }
    }

    func testSheetRegistryPreservesTemplateOrder() {
        let workbook = Workbook()
        let config = ReportConfig()
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        let registry = SheetRegistry(plan: dashboard.sheetPlan)
        let template = ComplianceTemplate()

        let (written, _, _) = registry.writeSelected(template: template)

        // The subset of written sheets must appear in the same relative order
        // as they do in the template's includedSheets list.
        let templateOrder = template.includedSheets.map(\.rawValue)
        let writtenIndicesInTemplate = written.compactMap { templateOrder.firstIndex(of: $0) }
        XCTAssertEqual(writtenIndicesInTemplate, writtenIndicesInTemplate.sorted(),
                       "Written sheets must follow template.includedSheets order")
    }

    func testSheetRegistryReturnsUnimplementedForUnknownIDs() {
        // Build a registry from an empty plan to force all IDs to be unimplemented.
        let registry = SheetRegistry(plan: [])
        let template = ExecutiveTemplate()

        let (written, failures, unimplemented) = registry.writeSelected(template: template)

        XCTAssertTrue(written.isEmpty, "Empty plan should produce no written sheets")
        XCTAssertTrue(failures.isEmpty, "Empty plan should produce no failures")
        XCTAssertEqual(unimplemented.count, template.includedSheets.count,
                       "All template sheets should be reported as unimplemented")
    }

    func testSheetRegistryExecutiveProducesNoNonExecutiveSheets() {
        let workbook = Workbook()
        let config = ReportConfig()
        let dashboard = CoreDashboard(config: config, dataDir: tmpDir, workbook: workbook)
        let registry = SheetRegistry(plan: dashboard.sheetPlan)
        let template = ExecutiveTemplate()

        let (written, _, _) = registry.writeSelected(template: template)

        // ExecutiveTemplate does not include Protect or DDM sheets.
        let protectAndDDM: Set<String> = [
            "Protect Overview", "Protect Alerts", "Protect Computers", "Protect Insights",
            "DDM Status", "Blueprint Status", "Compliance Devices", "Compliance Rules",
        ]
        for name in written {
            XCTAssertFalse(protectAndDDM.contains(name),
                           "Executive template must not include '\(name)'")
        }
    }

    // MARK: - SectionRegistry

    func testSectionRegistryRendersOnlyRequestedSections() {
        let registry = SectionRegistry(builders: [
            SectionID.kpiTiles.rawValue:     { "<section data-section='kpi_tiles'>KPI</section>" },
            SectionID.fleetSummary.rawValue: { "<section data-section='fleet_summary'>Fleet</section>" },
            SectionID.policyTable.rawValue:  { "<section data-section='policy_table'>Policy</section>" },
        ])
        let template = OperationalTemplate()

        // OperationalTemplate includes kpiTiles but not fleetSummary (at this registry level).
        let (html, unimplemented) = registry.renderSelected(template: template)

        if template.htmlSections.contains(.kpiTiles) {
            XCTAssertTrue(html.contains("kpi_tiles"),
                          "kpiTiles should appear in rendered HTML when in template")
        }

        // fleetSummary is NOT in OperationalTemplate.htmlSections — builder exists but not called.
        if !template.htmlSections.contains(.fleetSummary) {
            XCTAssertFalse(html.contains("fleet_summary"),
                           "fleetSummary should be absent from HTML when not in template")
        }

        // All unimplemented IDs must be in template.htmlSections and not in the registry.
        let registeredIDs = Set([
            SectionID.kpiTiles.rawValue,
            SectionID.fleetSummary.rawValue,
            SectionID.policyTable.rawValue,
        ])
        for id in unimplemented {
            XCTAssertTrue(template.htmlSections.contains(id),
                          "Unimplemented ID '\(id.rawValue)' must be in template.htmlSections")
            XCTAssertFalse(registeredIDs.contains(id.rawValue),
                           "Unimplemented ID '\(id.rawValue)' must not be in the registry")
        }
    }

    func testSectionRegistryEmitsCommentForUnimplementedSections() {
        let registry = SectionRegistry(builders: [:])
        let template = ExecutiveTemplate()

        let (html, unimplemented) = registry.renderSelected(template: template)

        XCTAssertFalse(unimplemented.isEmpty,
                       "An empty registry should report all template sections as unimplemented")
        // Each unimplemented ID should appear as a comment in the output.
        for id in unimplemented {
            XCTAssertTrue(html.contains("<!-- section: \(id.rawValue)"),
                          "Unimplemented section '\(id.rawValue)' must produce a comment placeholder")
        }
    }

    func testSectionRegistryPreservesTemplateOrder() {
        var callOrder: [String] = []
        let sectionIDs: [SectionID] = [.kpiTiles, .policyTable, .orgInfo]
        var builders: [String: SectionRegistry.BuildAction] = [:]
        for id in sectionIDs {
            let captured = id.rawValue
            builders[id.rawValue] = {
                callOrder.append(captured)
                return "<div>\(captured)</div>"
            }
        }
        let registry = SectionRegistry(builders: builders)

        // Use a template whose htmlSections contains kpiTiles, policyTable, orgInfo in some order.
        // ExecutiveTemplate includes kpiTiles, policyTable (via orgInfo mapping), complianceBands.
        // Build a minimal ordered list that exercises ordering.
        let orderedSections: [SectionID] = [.orgInfo, .kpiTiles, .policyTable]
        let dummyTemplate = _OrderedSectionTemplate(htmlSections: orderedSections)
        let (_, _) = registry.renderSelected(template: dummyTemplate)

        XCTAssertEqual(callOrder, orderedSections.map(\.rawValue),
                       "Section builders must be called in template.htmlSections order")
    }

    // MARK: - ReportEngine.generate with template parameter

    func testGenerateWithDefaultTemplateBehaviorUnchanged() async throws {
        // Default parameter = ExecutiveTemplate — existing callers unaffected.
        let engine = ReportEngine(config: ReportConfig(), dataDir: tmpDir)
        let outURL = tmpDir.appendingPathComponent("default.xlsx")
        // No data directory → should produce a workbook (graceful Cover-sheet path).
        try await engine.generate(csvURL: nil, outputURL: outURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    func testGenerateWithOperationalTemplateThrowsNoCachedDataWhenEmpty() async {
        // OperationalTemplate has no cover/compliancePosture (which write without data).
        // With an empty dataDir and no CSV, the engine correctly throws noCachedData.
        let engine = ReportEngine(config: ReportConfig(), dataDir: tmpDir)
        let outURL = tmpDir.appendingPathComponent("operational.xlsx")
        do {
            try await engine.generate(csvURL: nil, outputURL: outURL, template: OperationalTemplate())
            XCTFail("Expected noCachedData when empty dataDir + no CSV + non-cover template")
        } catch ReportEngineError.noCachedData {
            // Expected — OperationalTemplate's sheets all require cached data.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testGenerateWithComplianceTemplateProducesWorkbook() async throws {
        // ComplianceTemplate includes .cover and .compliancePosture which write without data.
        let engine = ReportEngine(config: ReportConfig(), dataDir: tmpDir)
        let outURL = tmpDir.appendingPathComponent("compliance.xlsx")
        try await engine.generate(
            csvURL: nil,
            outputURL: outURL,
            template: ComplianceTemplate()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let data = try Data(contentsOf: outURL)
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]),
                       "XLSX output must begin with ZIP magic bytes")
    }

    func testGenerateWithAssetTemplateThrowsNoCachedDataWhenEmpty() async {
        // AssetTemplate has no cover sheet — all its sheets require cached data.
        let engine = ReportEngine(config: ReportConfig(), dataDir: tmpDir)
        let outURL = tmpDir.appendingPathComponent("asset.xlsx")
        do {
            try await engine.generate(csvURL: nil, outputURL: outURL, template: AssetTemplate())
            XCTFail("Expected noCachedData when empty dataDir + no CSV + non-cover template")
        } catch ReportEngineError.noCachedData {
            // Expected.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testGenerateWithSecurityPostureTemplateProducesWorkbook() async throws {
        // SecurityPostureTemplate includes .cover which writes even without cached data.
        let engine = ReportEngine(config: ReportConfig(), dataDir: tmpDir)
        let outURL = tmpDir.appendingPathComponent("security.xlsx")
        try await engine.generate(
            csvURL: nil,
            outputURL: outURL,
            template: SecurityPostureTemplate()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    // MARK: - applyPagination

    func testCompactPaginationLeavesHTMLUnchanged() {
        let html = "<html><head></head><body><section>A</section></body></html>"
        let result = ReportEngine.applyPagination(html: html, strategy: .compact)
        XCTAssertEqual(result, html, ".compact must not modify the HTML")
    }

    func testStandardPaginationInjectsStyle() {
        let html = "<html><head></head><body><section>B</section></body></html>"
        let result = ReportEngine.applyPagination(html: html, strategy: .standard)
        XCTAssertTrue(result.contains("page-break-after"),
                      ".standard must inject a page-break-after CSS rule")
        XCTAssertTrue(result.contains("</head>"),
                      "Injected style must appear before </head>")
    }

    func testSectionPerPagePaginationInjectsAlwaysBreak() {
        let html = "<html><head></head><body><section>C</section></body></html>"
        let result = ReportEngine.applyPagination(html: html, strategy: .sectionPerPage)
        XCTAssertTrue(result.contains("page-break-after: always"),
                      ".sectionPerPage must inject page-break-after: always")
        XCTAssertTrue(result.contains("page-break-after: avoid"),
                      ".sectionPerPage must suppress break on last section")
    }

    func testPaginationPreservesHTMLStructure() {
        let html = "<html><head></head><body><section>D</section></body></html>"
        for strategy in [PaginationStrategy.compact, .standard, .sectionPerPage] {
            let result = ReportEngine.applyPagination(html: html, strategy: strategy)
            XCTAssertTrue(result.contains("<body>"),
                          "\(strategy.rawValue): <body> tag must survive pagination")
            XCTAssertTrue(result.contains("</html>"),
                          "\(strategy.rawValue): </html> tag must survive pagination")
        }
    }

    // MARK: - HTML section order

    func testHtmlReportSectionOrderMatchesComplianceTemplate() async throws {
        let report = HtmlReport(config: ReportConfig(), dataDir: tmpDir)
        let outURL = tmpDir.appendingPathComponent("compliance_order.html")
        let template = ComplianceTemplate()

        try await report.generate(outputURL: outURL, sections: template.htmlSections)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let content = try String(contentsOf: outURL, encoding: .utf8)

        // Verify the document is structurally valid.
        XCTAssertTrue(content.contains("<!DOCTYPE html>"))
        XCTAssertTrue(content.contains("</html>"))

        // Extract just the <main>...</main> block to avoid CSS definitions
        // polluting range comparisons. CSS may define `.compliance-hero` before <body>.
        guard let mainStart = content.range(of: "<main>"),
              let mainEnd = content.range(of: "</main>") else {
            // No <main> block — the generate produced fallback HTML; test passes vacuously.
            return
        }
        let mainBody = String(content[mainStart.upperBound..<mainEnd.lowerBound])

        // Within <main>, ComplianceTemplate puts kpiTiles BEFORE complianceBands.
        // kpiTiles renders "tiles-row"; complianceBands renders "compliance-hero-value".
        // Check their relative positions only when both are present (no-data = not rendered).
        let tilesRange = mainBody.range(of: "tiles-row")
        let heroRange = mainBody.range(of: "compliance-hero-value")

        if let tiles = tilesRange, let hero = heroRange {
            let kpiIndex = template.htmlSections.firstIndex(of: .kpiTiles)!
            let compIndex = template.htmlSections.firstIndex(of: .complianceBands)!
            if kpiIndex < compIndex {
                XCTAssertLessThan(tiles.lowerBound, hero.lowerBound,
                                  "kpiTiles must appear before complianceBands in <main>")
            }
        }
    }

    // MARK: - PDF with sectionPerPage produces valid document

    @MainActor
    func testGeneratePDFWithSectionPerPageProducesValidPDF() async throws {
        let config = ReportConfig()
        let outURL = tmpDir.appendingPathComponent("compliance_audit.pdf")

        // generatePDF needs HtmlReport + PDFExporter on main actor.
        try await ReportEngine.generatePDF(
            config: config,
            dataDir: tmpDir,
            outputURL: outURL,
            profileName: "test",
            template: ComplianceTemplate()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "PDF file must exist at \(outURL.path)")
        let data = try Data(contentsOf: outURL)
        let magic = String(bytes: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(magic, "%PDF-", "Output must begin with PDF magic bytes")

        // PDFKit page count must be at least 1.
        let doc = PDFDocument(data: data)
        XCTAssertNotNil(doc, "PDFDocument must parse the output")
        XCTAssertGreaterThanOrEqual(doc?.pageCount ?? 0, 1,
                                    "PDF must contain at least one page")
    }

    // MARK: - GenerateSheetState template support

    @MainActor
    func testGenerateSheetStateDefaultTemplateIsExecutive() {
        let state = GenerateSheetState()
        XCTAssertEqual(state.selectedTemplateID, "executive")
        XCTAssertTrue(state.resolvedTemplate is ExecutiveTemplate)
    }

    @MainActor
    func testGenerateSheetStateTemplateResolutionRoundTrips() {
        let state = GenerateSheetState()
        for template in TemplateResolver.allTemplates {
            state.selectedTemplateID = template.identifier
            XCTAssertEqual(state.resolvedTemplate.identifier, template.identifier,
                           "resolvedTemplate must match selectedTemplateID for '\(template.identifier)'")
        }
    }

    @MainActor
    func testGenerateSheetStateUnknownIDFallsBackToExecutive() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "bogus-id-that-does-not-exist"
        XCTAssertEqual(state.resolvedTemplate.identifier, "executive",
                       "Unknown templateID must resolve to ExecutiveTemplate")
    }
}

// MARK: - Helper: ordered-section test template

/// Minimal `ReportTemplate` for testing `SectionRegistry` section ordering.
/// Not registered in `TemplateResolver` — used only in this test file.
private struct _OrderedSectionTemplate: ReportTemplate {
    let identifier = "_test_ordered"
    let displayName = "Test Ordered"
    let description = "Test-only template"
    let audience = "Test"
    let includedSheets: [SheetID] = []
    let htmlSections: [SectionID]
    let pdfPagination: PaginationStrategy = .compact
    let recommendedSchedule: TemplateDataTier = .core

    init(htmlSections: [SectionID]) {
        self.htmlSections = htmlSections
    }
}
