import XCTest
@testable import JamfReports

final class DebugLoggingServiceTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-debuglog-\(UUID().uuidString).plist")
    }

    func test_absentFile_readsBothOff() {
        XCTAssertEqual(DebugLoggingService.current(at: tempURL()), .off)
    }

    func test_roundTrip_persistVerboseOnly() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(DebugLoggingState(persistVerbose: true, revealPrivate: false), at: url)
        XCTAssertEqual(DebugLoggingService.current(at: url),
                       DebugLoggingState(persistVerbose: true, revealPrivate: false))
    }

    func test_roundTrip_revealPrivate() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(DebugLoggingState(persistVerbose: true, revealPrivate: true), at: url)
        XCTAssertEqual(DebugLoggingService.current(at: url),
                       DebugLoggingState(persistVerbose: true, revealPrivate: true))
    }

    func test_revealPrivateDefaultsOff_whenOnlyPersistWritten() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(DebugLoggingState(persistVerbose: true, revealPrivate: false), at: url)
        XCTAssertFalse(DebugLoggingService.current(at: url).revealPrivate)
    }

    func test_off_writesEmptyOptions() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try DebugLoggingService.apply(.off, at: url)
        XCTAssertEqual(DebugLoggingService.current(at: url), .off)
    }
}
