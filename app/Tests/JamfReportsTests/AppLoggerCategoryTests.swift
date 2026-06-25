import XCTest
import OSLog
@testable import JamfReports

final class AppLoggerCategoryTests: XCTestCase {
    /// Each of the eight categories must exist and be a distinct usable Logger.
    func test_allEightCategoriesEmitWithoutCrashing() {
        AppLogger.cli.debug("t")
        AppLogger.collect.debug("t")
        AppLogger.report.debug("t")
        AppLogger.auth.debug("t")
        AppLogger.schedule.debug("t")
        AppLogger.webhook.debug("t")
        AppLogger.platform.debug("t")
        AppLogger.ui.debug("t")
    }
}
