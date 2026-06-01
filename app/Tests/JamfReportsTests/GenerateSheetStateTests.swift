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
}
