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
}
