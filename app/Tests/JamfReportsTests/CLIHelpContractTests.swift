import XCTest
@testable import JamfReports

/// Every jamf-cli command and long flag the app issues exists in jamf-cli's own command catalog.
///
/// The catalog is the fixture `Fixtures/jamf-cli/commands-1.31.1.json`, captured from
/// `jamf-cli commands -o json` (1.31.1, 2026-10-29). Tests never run jamf-cli, so the fixture
/// is refreshed by hand when the jamf-cli floor moves: run
/// `app/scripts/capture-jamf-cli-catalog.zsh`, then fix whatever this suite reports.
///
/// One source of truth: `AppCommand` lists each place the app builds an argv, and its
/// `invocations` switch has no `default`, so a new case does not compile until it says what it
/// runs. A new argv builder in a file `argvSourceFiles` does not know fails
/// `testNoUnlistedFileBuildsAnArgv`; one more builder in a listed file is for the reviewer.
@MainActor
final class CLIHelpContractTests: XCTestCase {

    /// One argv the app passes to jamf-cli. `positionals` counts the trailing path words that are
    /// arguments (an ID, a title), not command names.
    struct Invocation {
        let label: String
        let argv: [String]
        var positionals = 0
        var isRootFlag = false
    }

    /// Flags jamf-cli accepts on every command (`jamf-cli pro device --help`, Global Flags,
    /// 1.31.1); the catalog lists each command's own flags only. `--version` and `--help` are the
    /// root command's.
    private static let globalFlags: Set<String> = [
        "--output", "--out-file", "--no-input", "--no-color", "--no-hints", "--no-version-check",
        "--profile", "--url", "--environment-id", "--tenant-id", "--version", "--help",
    ]

    /// Commands the installed jamf-cli 1.31.1 runs (`jamf-cli pro device --help`) but whose rows
    /// `commands -o json` leaves out. The test checks they are still absent, so the entry goes
    /// when the catalog gains the row.
    private static let missingFromCatalog: Set<String> = ["pro device"]

    /// Paths the app reaches through an alias jamf-cli lists on the row of another name.
    private static let reachedByAlias: Set<String> = ["pro computers list"]

    /// Files that build an argv; `testNoUnlistedFileBuildsAnArgv` fails on another.
    private static let argvSourceFiles: Set<String> = [
        "Engine/ReportEngine.swift", "Engine/ReportEngine+DeviceScan.swift",
        "Engine/ReportEngine+ComplianceBenchmarks.swift", "Services/CLIBridge.swift",
        "Services/CLICommand.swift", "Services/ConnectionCheck.swift",
        "Services/JamfCLIInstaller.swift", "Services/OnboardingFlow+StartOver.swift",
        "Services/OnboardingFlow.swift", "Services/PlatformTwin.swift",
        "Services/ProductSetupChecks.swift", "Services/ProfileService.swift",
        "Services/ProtectBackup.swift", "Services/SchoolPlatformCheck.swift",
    ]

    /// Files with a `"config", "<word>"` or `"protect", "<word>"` pair that is a config.yaml key
    /// path, not an argv.
    private static let argvLookalikeFiles: Set<String> = [
        "Engine/BackupDiffModel.swift", "Services/ConfigDoctorService.swift",
        "Services/ConfigService.swift", "Services/SharedConfigPin.swift",
    ]

    // MARK: - The enumeration

    @MainActor
    enum AppCommand: CaseIterable {
        case collectMatrix, protectMatrix, schoolMatrix, dashboard, audit
        case deviceScan, patchDefinitions, benchmarks, authRefreshProbe
        case cliCommand, connectionCheck, schoolPlatformCheck, productSetupCheck
        case platformTwin, configList, deviceDetail, backupAndDiff, groupAnalysis, configValidate
        case onboarding, rootFlags

        var invocations: [Invocation] {
            switch self {
            case .collectMatrix:
                return ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30)
                    .map { Invocation(label: $0.kind, argv: $0.args) }
            case .protectMatrix:
                return ReportEngine.protectCommandMatrix(profile: "p")
                    .map { Invocation(label: $0.kind, argv: $0.args) }
            case .schoolMatrix:
                return ReportEngine.schoolCommandMatrix(profile: "p")
                    .map { Invocation(label: $0.kind, argv: $0.args) }
            case .dashboard:
                let base = ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30)
                    .first { $0.kind == ReportEngine.dashboardKind }?.args ?? []
                let withProtect = ReportEngine.dashboardArguments(
                    base: base, profile: "p", protect: ProtectConfig(enabled: true, profile: "q"))
                return [Invocation(label: "dashboard with Protect", argv: withProtect)]
            case .audit:
                return [Invocation(
                    label: "audit checks",
                    argv: ReportEngine.auditArguments(profile: "p", staleDays: 30, category: "x"))]
            case .deviceScan:
                return [
                    Invocation(label: "device history",
                               argv: ReportEngine.historyArguments(profile: "p", id: "1"),
                               positionals: 1),
                    Invocation(label: "status items",
                               argv: ReportEngine.statusItemsArguments(
                                   profile: "p", managementId: "m"),
                               positionals: 1),
                ]
            case .patchDefinitions:
                return [Invocation(
                    label: "patch definitions",
                    argv: ReportEngine.patchDefinitionArguments(profile: "p", titleId: "1"),
                    positionals: 1)]
            case .benchmarks:
                let rows = ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30)
                    .filter { ["compliance-devices", "compliance-rules"].contains($0.kind) }
                return [Invocation(
                    label: "benchmark list",
                    argv: ReportEngine.benchmarkListArguments(profile: "p"))]
                    + rows.map {
                        Invocation(
                            label: "\($0.kind) per title",
                            argv: ReportEngine.benchmarkReportArguments($0.args, title: "T"),
                            positionals: 1)
                    }
            case .authRefreshProbe:
                return [Invocation(label: "auth refresh",
                                   argv: ReportEngine.authRefreshArguments(profile: "p"))]
            case .cliCommand:
                return CLIHelpContractTests.cliCommandSamples().map {
                    Invocation(label: "CLICommand", argv: $0.argv)
                }
            case .connectionCheck:
                return [
                    Invocation(label: "version",
                               argv: ConnectionCheck.versionArguments(profile: "p")),
                    Invocation(label: "probe", argv: ConnectionCheck.probeArguments(profile: "p")),
                ]
            case .schoolPlatformCheck:
                return [Invocation(label: "school blueprints",
                                   argv: SchoolPlatformCheck.arguments(profile: "p"))]
            case .productSetupCheck:
                return [
                    Invocation(
                        label: "protect read",
                        argv: ProductSetupChecks.credentialArguments(.protect, profile: "p")),
                    Invocation(
                        label: "school read",
                        argv: ProductSetupChecks.credentialArguments(.school, profile: "p")),
                    Invocation(label: "set-default",
                               argv: ProductSetupChecks.setDefaultArguments(
                                   previous: "a", setUp: "b") ?? []),
                ]
            case .platformTwin:
                return [Invocation(label: "server URL",
                                   argv: PlatformTwin.serverURLArguments(profile: "p"))]
            case .configList:
                return [Invocation(label: "config list", argv: ProfileService.configListArguments)]
            case .deviceDetail:
                return [
                    Invocation(label: "computer detail",
                               argv: CLIBridge.computerDetailArguments("1"), positionals: 1),
                    Invocation(label: "mobile detail",
                               argv: CLIBridge.mobileDetailArguments("1"), positionals: 1),
                ]
            case .backupAndDiff:
                return [
                    Invocation(
                        label: "pro backup",
                        argv: CLIBridge.backupArguments(profile: "p", outputDirectory: "/o")),
                    Invocation(label: "protect backup",
                               argv: ProtectBackup.arguments(profile: "p", outputDirectory: "/o")),
                    Invocation(
                        label: "pro diff",
                        argv: CLIBridge.diffArguments(profile: "p", source: "/a", target: "/b")),
                ]
            case .groupAnalysis:
                return [Invocation(label: "group analysis",
                                   argv: CLIBridge.groupAnalyzeArguments(profile: "p"))]
            case .configValidate:
                return [Invocation(label: "config validate",
                                   argv: CLIBridge.configValidateArguments(profile: "p"))]
            case .onboarding:
                return [
                    Invocation(label: "add-profile oauth2",
                               argv: OnboardingFlow.proOAuth2Arguments(profile: "p", url: "u")),
                    Invocation(label: "add-profile platform environment",
                               argv: OnboardingFlow.platformGatewayArguments(
                                   profile: "p", gatewayURL: "u", scope: .environment,
                                   scopeID: "i")),
                    Invocation(label: "add-profile platform tenant",
                               argv: OnboardingFlow.platformGatewayArguments(
                                   profile: "p", gatewayURL: "u", scope: .tenant, scopeID: "i")),
                    Invocation(label: "protect setup",
                               argv: OnboardingFlow.protectArguments(profile: "p", url: "u")),
                    Invocation(label: "school setup",
                               argv: OnboardingFlow.schoolArguments(profile: "p", url: "u")),
                    Invocation(label: "remove-profile",
                               argv: OnboardingFlow.removeProfileArguments(name: "p")),
                ]
            case .rootFlags:
                // `Provenance`, `DiagnosticBundleService` and `JamfCLIInstaller.installedVersion`
                // pass this literal; it is the root command's flag, not a catalog row.
                return [
                    Invocation(label: "--version", argv: ["--version"], isRootFlag: true),
                    Invocation(label: "version -o json",
                               argv: JamfCLIInstaller.versionJSONArguments),
                ]
            }
        }
    }

    /// One sample of every `CLICommand` case. The switch has no `default`: a new case fails to
    /// compile until it is listed here.
    static func cliCommandSamples() -> [CLICommand] {
        let samples: [CLICommand] = [
            .proAuthToken(profile: "p"), .configList, .proHelp, .proDoctor(profile: "p"),
            .schoolDepDevicesList(profile: "p"), .schoolIBeaconsList(profile: "p"),
        ]
        for sample in samples {
            switch sample {
            case .proAuthToken, .configList, .proHelp, .proDoctor, .schoolDepDevicesList,
                 .schoolIBeaconsList:
                break
            }
        }
        return samples
    }

    // MARK: - Tests

    private func catalog() throws -> CommandCatalog {
        let url = TestFixtures.dir("jamf-cli/commands-1.31.1.json")
        return try CommandCatalog(data: Data(contentsOf: url))
    }

    func testEveryAppCommandExistsInTheCatalogWithItsFlags() throws {
        let catalog = try catalog()
        var checked = 0
        for command in AppCommand.allCases {
            for item in command.invocations {
                checked += 1
                let shown = "\(item.label): \(item.argv.joined(separator: " "))"
                XCTAssertFalse(item.argv.isEmpty, "\(shown) built no argv")
                let (path, flags) = CommandCatalog.invocation(
                    of: item.argv, positionals: item.positionals)
                if item.isRootFlag {
                    XCTAssertTrue(Set(flags).isSubset(of: Self.globalFlags), shown)
                    continue
                }
                let name = path.joined(separator: " ")
                XCTAssertFalse(path.isEmpty, "\(shown) names no command")
                if Self.missingFromCatalog.contains(name) {
                    XCTAssertFalse(catalog.exists(path: path), "\(name) is in the catalog now")
                    continue
                }
                guard catalog.exists(path: path) else {
                    XCTFail("not in jamf-cli's catalog — \(shown)")
                    continue
                }
                XCTAssertFalse(catalog.isDestructive(path: path), "destructive — \(shown)")
                XCTAssertEqual(
                    !catalog.isCanonical(path: path), Self.reachedByAlias.contains(name),
                    "alias use changed for \(name)")
                let allowed = Set(catalog.flags(for: path)).union(Self.globalFlags)
                for flag in flags where !allowed.contains(flag) {
                    XCTFail("\(flag) is not a flag of '\(name)' — \(shown)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 80)
    }

    func testEveryAppCommandCaseBuildsAnArgv() {
        for command in AppCommand.allCases {
            XCTAssertFalse(command.invocations.isEmpty, "\(command) issues nothing")
        }
    }

    func testNoUnlistedFileBuildsAnArgv() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JamfReports", isDirectory: true)
        let pattern = try NSRegularExpression(
            pattern: #""(pro|protect|school|platform|config|doctor|dashboard|version)""#
                + #"\s*,\s*"-{0,2}[a-z]"#)
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var found: Set<String> = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let file = sources.appendingPathComponent(relative)
            let text = try String(contentsOf: file, encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                found.insert(relative)
            }
        }
        let unlisted = found.subtracting(Self.argvSourceFiles).subtracting(Self.argvLookalikeFiles)
        XCTAssertTrue(
            unlisted.isEmpty,
            "\(unlisted.sorted()) build a jamf-cli argv: add it to AppCommand and argvSourceFiles")
        XCTAssertTrue(
            Self.argvSourceFiles.isSubset(of: found), "\(Self.argvSourceFiles.subtracting(found))")
    }

    func testCLICommandSamplesCoverEveryCase() {
        XCTAssertEqual(Self.cliCommandSamples().count, 6)
    }

    func testPathReadingSkipsProfileLeadingFlagsAndPositionals() {
        let parsed = CommandCatalog.invocation(
            of: ["-p", "--odd", "--no-input", "pro", "classic-computer-history", "get", "12",
                 "--subset=commands", "--output", "json", "--", "--name"],
            positionals: 1)
        XCTAssertEqual(parsed.path, ["pro", "classic-computer-history", "get"])
        XCTAssertEqual(parsed.flags, ["--no-input", "--subset", "--output"])
    }
}
