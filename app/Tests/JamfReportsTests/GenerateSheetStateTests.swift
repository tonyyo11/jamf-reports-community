import XCTest
@testable import JamfReports

@MainActor
final class GenerateSheetStateTests: XCTestCase {

    // MARK: - Default state

    func testDefaultSelectedTypesAreXLSXOnly() {
        let state = GenerateSheetState()
        XCTAssertEqual(state.selectedTypes, [.xlsx], "Default selection should be XLSX only")
    }

    func testDefaultCollectFreshIsTrue() {
        let state = GenerateSheetState()
        XCTAssertTrue(state.collectFresh)
    }

    func testDefaultCustomOutputDirIsNil() {
        let state = GenerateSheetState()
        XCTAssertNil(state.customOutputDir)
    }

    func testDefaultStateIsNotRunning() {
        let state = GenerateSheetState()
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.completedCount, 0)
        XCTAssertTrue(state.logLines.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    // MARK: - canGenerate

    func testCanGenerateWithDefaultState() {
        let state = GenerateSheetState()
        XCTAssertTrue(state.canGenerate)
    }

    func testCanGenerateIsFalseWhenNoTypesSelected() {
        let state = GenerateSheetState()
        state.selectedTypes = []
        XCTAssertFalse(state.canGenerate)
    }

    func testCanGenerateIsFalseWhileRunning() {
        let state = GenerateSheetState()
        state.isRunning = true
        XCTAssertFalse(state.canGenerate)
    }

    func testCanGenerateIsFalseWhenRunningAndNoTypes() {
        let state = GenerateSheetState()
        state.isRunning = true
        state.selectedTypes = []
        XCTAssertFalse(state.canGenerate)
    }

    func testCanGenerateWithPDFOnlySelected() {
        let state = GenerateSheetState()
        state.selectedTypes = [.pdf]
        XCTAssertTrue(state.canGenerate)
    }

    // MARK: - resolvedOutputDir

    func testResolvedOutputDirFallsBackToDefaultWhenNotSet() {
        let state = GenerateSheetState()
        // "invalid-profile-xyz" has no workspace URL; should return home-based fallback.
        let dir = state.resolvedOutputDir(for: "invalid-profile-xyz")
        XCTAssertTrue(dir.path.hasSuffix("Generated Reports"),
                      "Expected fallback to end in 'Generated Reports', got: \(dir.path)")
    }

    /// With no folder chosen, the folder `output.output_dir` names, where the generators write.
    func testResolvedOutputDirIsTheConfiguredFolderWhenNoneIsChosen() {
        let state = GenerateSheetState()
        let configured = URL(fileURLWithPath: "/Users/Shared/Team Reports", isDirectory: true)
        state.configuredOutputDir = configured
        XCTAssertEqual(state.resolvedOutputDir(for: "any-profile"), configured)
        let custom = URL(fileURLWithPath: "/tmp/my-reports")
        state.customOutputDir = custom
        XCTAssertEqual(state.resolvedOutputDir(for: "any-profile"), custom, "a chosen folder wins")
    }

    func testResolvedOutputDirUsesCustomWhenSet() {
        let state = GenerateSheetState()
        let custom = URL(fileURLWithPath: "/tmp/my-reports")
        state.customOutputDir = custom
        let dir = state.resolvedOutputDir(for: "any-profile")
        XCTAssertEqual(dir, custom)
    }

    // MARK: - Mutation helpers

    func testAppendLineAddsToLogLines() {
        let state = GenerateSheetState()
        let line = CLIBridge.LogLine(timestamp: Date(), level: .info, text: "hello")
        state.appendLine(line)
        XCTAssertEqual(state.logLines.count, 1)
        XCTAssertEqual(state.logLines[0].text, "hello")
    }

    func testResetClearsAllRunState() {
        let state = GenerateSheetState()
        state.isRunning = true
        state.completedCount = 3
        state.errorMessage = "something went wrong"
        state.logLines = [CLIBridge.LogLine(timestamp: Date(), level: .fail, text: "err")]

        state.reset()

        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.completedCount, 0)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.logLines.isEmpty)
    }

    // MARK: - Folder writability

    func testFolderPickerErrorStartsNil() {
        let state = GenerateSheetState()
        XCTAssertNil(state.folderPickerError)
    }

    func testCanGenerateBlockedByFolderPickerError() {
        let state = GenerateSheetState()
        state.folderPickerError = "Cannot write to Documents: Permission denied"
        XCTAssertFalse(state.canGenerate)
    }

    func testCanGenerateRestoredAfterClearingFolderError() {
        let state = GenerateSheetState()
        state.folderPickerError = "Cannot write to Documents: Permission denied"
        XCTAssertFalse(state.canGenerate)
        state.folderPickerError = nil
        XCTAssertTrue(state.canGenerate)
    }

    func testFolderPickerErrorPropagatesMessage() {
        let state = GenerateSheetState()
        let msg = "Cannot write to MyFolder: Operation not permitted"
        state.folderPickerError = msg
        XCTAssertEqual(state.folderPickerError, msg)
    }

    // MARK: - GenerateOutputType

    func testAllOutputTypesHaveDescriptionAndIcon() {
        for type in GenerateOutputType.allCases {
            XCTAssertFalse(type.description.isEmpty, "\(type.rawValue) missing description")
            XCTAssertFalse(type.icon.isEmpty, "\(type.rawValue) missing icon")
        }
    }

    func testOutputTypeRawValues() {
        XCTAssertEqual(GenerateOutputType.xlsx.rawValue, "XLSX")
        XCTAssertEqual(GenerateOutputType.html.rawValue, "HTML")
        XCTAssertEqual(GenerateOutputType.pdf.rawValue,  "PDF")
        XCTAssertEqual(GenerateOutputType.csv.rawValue,  "CSV")
    }

    // MARK: - Item 1: GenerateSheetState.summarize

    func testSummarizeAllSucceedReturnsCountAndNilMessage() {
        var result = GenerateAllResult()
        result.succeeded = [.xlsx, .html]
        let (count, message) = GenerateSheetState.summarize(result)
        XCTAssertEqual(count, 2)
        XCTAssertNil(message, "all-success must produce nil error message")
    }

    func testSummarizeAllFailReturnsZeroCountAndMessage() {
        var result = GenerateAllResult()
        result.failed = [(.xlsx, 1), (.html, 3)]
        let (count, message) = GenerateSheetState.summarize(result)
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("failed") == true,
                      "all-fail message must mention 'failed'; got: \(message ?? "<nil>")")
        XCTAssertTrue(message?.contains("XLSX") == true)
        XCTAssertTrue(message?.contains("HTML") == true)
    }

    func testSummarizePartialSuccessReturnsSucceededCountAndMessage() {
        var result = GenerateAllResult()
        result.succeeded = [.xlsx]
        result.failed = [(.html, 5)]
        let (count, message) = GenerateSheetState.summarize(result)
        XCTAssertEqual(count, 1, "partial success count must equal succeeded.count")
        XCTAssertNotNil(message)
        // Message must name the succeeded format and the failed format.
        XCTAssertTrue(message?.contains("XLSX") == true,
                      "partial message must mention the succeeded type; got: \(message ?? "<nil>")")
        XCTAssertTrue(message?.contains("HTML") == true,
                      "partial message must mention the failed type; got: \(message ?? "<nil>")")
        XCTAssertTrue(message?.contains("failed") == true)
    }

    func testSummarizeEmptyResultReturnsZeroAndNilMessage() {
        let result = GenerateAllResult()
        let (count, message) = GenerateSheetState.summarize(result)
        XCTAssertEqual(count, 0)
        XCTAssertNil(message, "empty result (nothing requested) must return nil message")
    }

    /// A failed format reads its cause, as other screens do, once per exit code.
    func testFailedFormatsAreExplainedByTheirExitCode() {
        let result = GenerateAllResult(
            succeeded: [.pdf], failed: [(.xlsx, 1), (.csv, 3), (.html, 1)])
        let (count, message) = GenerateSheetState.summarize(result)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(message, "Generated PDF. "
            + CLIBridge.explainExit(1, operation: "XLSX, HTML generation") + " "
            + CLIBridge.explainExit(3, operation: "CSV generation"))
    }

    // MARK: - Footer and the audit line

    /// The dismiss button keeps its own label while a run goes; only Generate says Running.
    func testOnlyGenerateSaysRunningWhileARunGoes() {
        let running = GenerateSheetState.footerTitles(isRunning: true)
        XCTAssertEqual(running.dismiss, "Done")
        XCTAssertEqual(running.generate, "Running\u{2026}")
        let idle = GenerateSheetState.footerTitles(isRunning: false)
        XCTAssertEqual(idle.dismiss, "Done")
        XCTAssertEqual(idle.generate, "Generate")
    }

    func testAnAuditThatExitsZeroEndsWithAnOkLine() {
        let line = GenerateSheetState.auditResultLine(exitCode: 0)
        XCTAssertEqual(line.level, .ok)
        XCTAssertTrue(line.text.hasPrefix("[ok] health audit finished"), line.text)
    }

    /// Any other exit still lets the generate go on, and the log says why the audit is stale.
    func testAnAuditThatFailsOrIsPartialEndsWithAWarnNamingTheCause() {
        let partial = GenerateSheetState.auditResultLine(exitCode: CLIBridge.exitCodePartialFailure)
        XCTAssertEqual(partial.level, .warn)
        XCTAssertTrue(partial.text.contains("partial results (exit 7)"), partial.text)
        let rejected = GenerateSheetState.auditResultLine(exitCode: CLIBridge.exitCodeUnauthorized)
        XCTAssertEqual(rejected.level, .warn)
        XCTAssertTrue(rejected.text.contains("health audit failed: authentication failed (401)"),
                      rejected.text)
        XCTAssertTrue(rejected.text.hasSuffix("Continuing with the cached audit data."))
    }

    // MARK: - Custom template selection

    func testDefaultSelectedTemplateIDIsFullInstance() {
        let state = GenerateSheetState()
        XCTAssertEqual(state.selectedTemplateID, FullInstanceTemplate().identifier)
    }

    func testCustomSelectedSheetsStartsEmpty() {
        // A selection left by an interrupted run would persist into this one.
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey)
        let state = GenerateSheetState()
        XCTAssertTrue(state.customSelectedSheets.isEmpty)
    }

    func testResolvedTemplateWithNonCustomTemplate() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "executive"
        let template = state.resolvedTemplate
        XCTAssertEqual(template.identifier, "executive")
        XCTAssertTrue(template is ExecutiveTemplate)
    }

    func testResolvedTemplateWithCustomTemplateAndSheets() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "custom"
        state.customSelectedSheets = [.executiveSummary, .securityPosture]
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        let template = state.resolvedTemplate
        XCTAssertEqual(template.identifier, "custom")
        if let customTemplate = template as? CustomTemplate {
            XCTAssertEqual(
                Set(customTemplate.includedSheets),
                Set([.executiveSummary, .securityPosture]))
        } else {
            XCTFail("Expected CustomTemplate, got \(type(of: template))")
        }
    }

    /// The engine writes a template's sheets in its order, so Custom must not take a Set's
    /// hash order, which changes from run to run.
    func testCustomTemplateListsTheSelectionInStoredOrder() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "custom"
        let picked: [SheetID] = [
            .patchVelocity, .executiveSummary, .osCurrency, .activeDevices,
            .securityPosture, .cover, .mdmCommandHealth, .hardwareModels,
        ]
        state.customSelectedSheets = Set(picked)
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        XCTAssertEqual(state.resolvedTemplate.includedSheets,
                       picked.sorted { $0.rawValue < $1.rawValue })
    }

    func testResolvedTemplateWithCustomTemplateAndEmptySheetsFallsBackToExecutive() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "custom"
        state.customSelectedSheets = []
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        let template = state.resolvedTemplate
        XCTAssertEqual(template.identifier, "executive")
        XCTAssertTrue(template is ExecutiveTemplate)
    }

    func testCanGenerateWithCustomTemplateAndSheets() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "custom"
        state.customSelectedSheets = [.executiveSummary]
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        XCTAssertTrue(state.canGenerate)
    }

    func testCanGenerateFalseWithCustomTemplateAndNoSheets() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "custom"
        state.customSelectedSheets = []
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        XCTAssertFalse(state.canGenerate)
    }

    func testCanGenerateWithNonCustomTemplate() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "executive"
        XCTAssertTrue(state.canGenerate) // Should not be affected by custom sheet requirement
    }

    func testCustomSelectedSheetsRoundTripUserDefaults() {
        // Clear any existing value
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey)

        let state = GenerateSheetState()
        let selectedSheets: Set<SheetID> = [.executiveSummary, .securityPosture, .patchCompliance]

        state.customSelectedSheets = selectedSheets

        // Create a new state instance to test persistence
        let newState = GenerateSheetState()
        XCTAssertEqual(newState.customSelectedSheets, selectedSheets)

        // Clean up
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey)
    }

    /// Every sheet the engine writes can be picked for Custom, and only once.
    func testTheCustomListOffersEverySheetOnce() {
        let listed = CustomSheetGroup.allGroups.flatMap(\.sheets)
        XCTAssertEqual(listed.count, Set(listed).count, "a sheet is listed twice")
        let missing = Set(SheetID.allCases).subtracting(listed)
        XCTAssertTrue(missing.isEmpty,
                      "not offered: \(missing.map(\.rawValue).sorted().joined(separator: ", "))")
    }

    /// A tap must redraw the checkmark, the "N sheets selected" line and Generate, so a
    /// change to the selection has to reach the view's observation, and still be saved.
    func testATappedSheetReachesObserversAndIsSaved() {
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey)
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        let state = GenerateSheetState()
        let changed = ObservedChange()
        withObservationTracking {
            _ = state.customSelectedSheets
        } onChange: {
            changed.seen = true
        }
        state.customSelectedSheets.insert(.cover)
        XCTAssertTrue(changed.seen, "the view would not redraw")
        XCTAssertEqual(GenerateSheetState().customSelectedSheets, [.cover])
    }
}

private final class ObservedChange: @unchecked Sendable {
    var seen = false
}
