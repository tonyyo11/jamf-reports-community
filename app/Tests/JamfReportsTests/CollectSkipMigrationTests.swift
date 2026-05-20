import XCTest
@testable import JamfReports

/// PR-22 T-12 + T-13: `jamf_cli.collect_skip` → `per_report: <kind>: never`
/// migration runs at config-load time so the Swift engine reads both keys
/// during the transition window.
///
/// The migration is intentionally one-way (read both, write only the new
/// shape — that part lives in PR-23's GUI save). Tests pin: normalization,
/// explicit per_report wins, no-op when collect_skip is empty/absent.
final class CollectSkipMigrationTests: XCTestCase {

    func testCollectSkipMigratesToNeverEntries() throws {
        let yaml = """
        jamf_cli:
          collect_skip:
            - update-status
            - patch-device-failures
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.collectCadence?.perReport?["update-status"]?.cadence, .never)
        XCTAssertEqual(cfg.collectCadence?.perReport?["patch-device-failures"]?.cadence, .never)
    }

    func testUnderscoreVariantsNormalizeToHyphenated() throws {
        // Python's PR-16 accepts both shapes; the migration normalizes to
        // the hyphen form so the resolver's tier-map lookup hits.
        let yaml = """
        jamf_cli:
          collect_skip:
            - update_status
            - patch_device_failures
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertNotNil(cfg.collectCadence?.perReport?["update-status"])
        XCTAssertNotNil(cfg.collectCadence?.perReport?["patch-device-failures"])
        XCTAssertNil(cfg.collectCadence?.perReport?["update_status"],
                     "Underscore form must NOT survive — would silently miss tier-map lookup")
    }

    func testExplicitPerReportEntryWinsOverMigration() throws {
        // Operator explicitly set per_report: update-status: 86400. The
        // migration must NOT clobber that with .never even though
        // collect_skip lists the same kind. The new schema is the
        // authoritative one once it's set.
        let yaml = """
        jamf_cli:
          collect_skip:
            - update-status
        collect_cadence:
          per_report:
            update-status: 86400
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(
            cfg.collectCadence?.perReport?["update-status"]?.cadence,
            .seconds(86_400),
            "Explicit per_report wins — collect_skip is legacy"
        )
    }

    func testEmptyCollectSkipIsNoOp() throws {
        let yaml = """
        jamf_cli:
          collect_skip: []
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        // No per_report entries should be synthesized.
        XCTAssertTrue(
            cfg.collectCadence?.perReport?.isEmpty ?? true,
            "Empty collect_skip must not create a phantom per_report block"
        )
    }

    func testAbsentCollectSkipDoesNotCreateCollectCadence() throws {
        let yaml = """
        jamf_cli:
          profile: prod
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        // No collect_skip ⇒ no migration ⇒ collectCadence stays nil so
        // the resolver hits the "missing config" path cleanly.
        XCTAssertNil(cfg.collectCadence,
                     "No collect_skip, no per_report — collectCadence must stay nil")
    }

    func testBlankEntriesAreDroppedSilently() throws {
        // Hand-edited YAML can produce stray empty list items. Skip them
        // rather than synthesizing a `per_report: "": never` ghost entry
        // that would never match any real kind.
        let yaml = """
        jamf_cli:
          collect_skip:
            - update-status
            - ""
            - "   "
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.collectCadence?.perReport?.count, 1)
        XCTAssertNotNil(cfg.collectCadence?.perReport?["update-status"])
    }

    func testMigrationAppliesToWithDefaultsToo() {
        // Tests using `loadFromString` exercise the same `withDefaults`
        // path as production. Pin that `withDefaults` is the migration
        // site — if a future refactor moves it elsewhere, this fails
        // and surfaces the regression before users hit it.
        var input = ReportConfig()
        input.jamfCli = JamfCLIConfig()
        input.jamfCli?.collectSkip = ["update-status"]
        let migrated = input.withDefaults()
        XCTAssertEqual(
            migrated.collectCadence?.perReport?["update-status"]?.cadence,
            .never
        )
    }

    func testMigrationResolvesThroughCadenceResolver() {
        // End-to-end: after migration, CadenceResolver should treat the
        // migrated kind as never-due. This is the behavior contract the
        // collect loop will observe.
        var input = ReportConfig()
        input.jamfCli = JamfCLIConfig()
        input.jamfCli?.collectSkip = ["app-status"]
        let migrated = input.withDefaults()
        let cadence = CadenceResolver.resolve(report: "app-status", config: migrated.collectCadence)
        XCTAssertEqual(cadence, .never,
                       "Migration must feed through to the resolver — the whole point of T-12")
    }
}
