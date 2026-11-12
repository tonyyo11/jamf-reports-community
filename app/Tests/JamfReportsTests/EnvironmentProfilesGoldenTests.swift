import CryptoKit
import XCTest
@testable import JamfReports

/// The gate for the environment model's first phases: every config.yaml shape a workspace has
/// today routes a collect to the same products, with the same `-p` profiles and the same router
/// lines, so the jamf-cli command lines are byte for byte what they were before `profiles:`.
/// Captured through the router's closure seams, which since P2 hand each collect the workspace
/// and, separately, the `-p` profile the transcript records; no jamf-cli runs. The dashboard row
/// goes through `ReportEngine.dashboardProtectProfile`, the collect's own call; the refusal step
/// after it (`dashboardProtect`) is covered by `DashboardCollectTests`.
@MainActor
final class EnvironmentProfilesGoldenTests: XCTestCase {
    private let workspace = "ws-golden"
    private nonisolated(unsafe) var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvGolden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(workspace, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private struct Shape {
        let name: String
        let yaml: String?
        let workspaceAuth: String
        let workspaceProduct: JamfCLIProduct
    }

    private let shapes: [Shape] = [
        Shape(name: "pro-oauth", yaml: "jamf_cli:\n  data_dir: jamf-cli-data\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        Shape(name: "pro-platform", yaml: "jamf_cli:\n  data_dir: jamf-cli-data\n",
              workspaceAuth: "platform", workspaceProduct: .pro),
        Shape(name: "pro-protect",
              yaml: "protect:\n  enabled: true\n  profile: ws-golden-protect\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        Shape(name: "pro-protect-blank", yaml: "protect:\n  enabled: true\n  profile: \"\"\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        Shape(name: "pro-protect-disabled",
              yaml: "protect:\n  enabled: false\n  profile: ws-golden-protect\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        Shape(name: "school-primary", yaml: "school_cli:\n  enabled: true\n  profile: ws-golden\n",
              workspaceAuth: "apikey", workspaceProduct: .school),
        Shape(name: "school-blank", yaml: "school_cli:\n  enabled: true\n",
              workspaceAuth: "apikey", workspaceProduct: .school),
        Shape(name: "school-foreign",
              yaml: "school_cli:\n  enabled: true\n  profile: other-school\n"
                + "protect:\n  enabled: true\n  profile: ws-golden-protect\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        Shape(name: "school-protect",
              yaml: "school_cli:\n  enabled: true\n  profile: ws-golden\n"
                + "protect:\n  enabled: true\n  profile: ws-golden-protect\n",
              workspaceAuth: "apikey", workspaceProduct: .school),
        Shape(name: "jamf-cli-profile-equal", yaml: "jamf_cli:\n  profile: ws-golden\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        // P2: the key names neither the folder nor `-p`, so a copied workspace runs as itself.
        Shape(name: "jamf-cli-profile-differs", yaml: "jamf_cli:\n  profile: ws-other\n",
              workspaceAuth: "oauth2", workspaceProduct: .pro),
        Shape(name: "no-config", yaml: nil, workspaceAuth: "oauth2", workspaceProduct: .pro),
    ]

    /// What each shape ran before `profiles:` existed: the router's lines and the product and
    /// profile each collect closure was handed, then the SHA-256 of that transcript with every
    /// call expanded into its jamf-cli command lines.
    private let golden: [String: (transcript: String, sha256: String)] = [
        "pro-oauth": (
            transcript: """
                pro ws-golden
                """,
            sha256: "265dbc2be4ab708f87f2ec50512acbb097579674e9438f68ee68d837e5aaebcd"),
        "pro-platform": (
            transcript: """
                pro ws-golden
                """,
            sha256: "265dbc2be4ab708f87f2ec50512acbb097579674e9438f68ee68d837e5aaebcd"),
        "pro-protect": (
            transcript: """
                pro ws-golden
                log [info] running protect collect for ws-golden
                protect ws-golden-protect
                """,
            sha256: "b6c2561860d88c9142d93869a9650f93b044768343d70984b2447ba51e237acf"),
        "pro-protect-blank": (
            transcript: """
                pro ws-golden
                log [warn] Jamf Protect not collected: protect.profile is blank
                """,
            sha256: "3a847f5e868bc156875cf828bcaae0184b82195d20397edc28b843058c41a1f7"),
        "pro-protect-disabled": (
            transcript: """
                pro ws-golden
                """,
            sha256: "265dbc2be4ab708f87f2ec50512acbb097579674e9438f68ee68d837e5aaebcd"),
        "school-primary": (
            transcript: """
                log [info] routing ws-golden → Jamf School collect
                school ws-golden
                """,
            sha256: "b8d373822f3170238787c4e7d67938b836e6efd8206e618cfbc8ca2fdc376404"),
        "school-blank": (
            transcript: """
                log [info] routing ws-golden → Jamf School collect
                school ws-golden
                """,
            sha256: "b8d373822f3170238787c4e7d67938b836e6efd8206e618cfbc8ca2fdc376404"),
        "school-foreign": (
            transcript: """
                pro ws-golden
                log [info] running protect collect for ws-golden
                protect ws-golden-protect
                """,
            sha256: "b6c2561860d88c9142d93869a9650f93b044768343d70984b2447ba51e237acf"),
        "school-protect": (
            transcript: """
                log [info] routing ws-golden → Jamf School collect
                school ws-golden
                log [info] running protect collect for ws-golden
                protect ws-golden-protect
                """,
            sha256: "8f60c12292b9a6e3fbf599c5632c10bc3cbe92f4ff8f4f6bd48d5c42a4220abc"),
        "jamf-cli-profile-equal": (
            transcript: """
                pro ws-golden
                """,
            sha256: "265dbc2be4ab708f87f2ec50512acbb097579674e9438f68ee68d837e5aaebcd"),
        "jamf-cli-profile-differs": (
            transcript: """
                pro ws-golden
                """,
            sha256: "265dbc2be4ab708f87f2ec50512acbb097579674e9438f68ee68d837e5aaebcd"),
        "no-config": (
            transcript: """
                pro ws-golden
                """,
            sha256: "265dbc2be4ab708f87f2ec50512acbb097579674e9438f68ee68d837e5aaebcd"),
    ]

    func testEveryOldShapeRunsTheSameCommandLines() async throws {
        XCTAssertEqual(shapes.count, golden.count, "every shape has a golden value")
        var mismatches: [String] = []
        for shape in shapes {
            let calls = try await run(shape)
            let expected = golden[shape.name]
            if calls.transcript != expected?.transcript || calls.sha256 != expected?.sha256 {
                mismatches.append("\"\(shape.name)\": (transcript: \"\"\"\n"
                    + calls.transcript + "\n\"\"\", sha256: \"\(calls.sha256)\"),\n"
                    + calls.commandLines)
            }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    /// D3: the `profiles:` block a new workspace is created with runs exactly what the old
    /// shape it replaces ran, and a Platform API workspace still runs its Platform kinds itself.
    func testANewWorkspaceBlockRunsWhatItsOldShapeRan() async throws {
        let cases: [(old: String, kind: ProfilesConfigWriter.NewWorkspace, auth: String,
                     product: JamfCLIProduct, platform: PlatformRoute?)] = [
            ("pro-oauth", .init(), "oauth2", .pro,
             .unavailable(EnvironmentProfiles.noPlatformReason)),
            ("pro-platform", .init(platform: true), "platform", .pro, .profile(workspace)),
            // A Jamf School environment never reads the platform slot.
            ("school-primary", .init(school: true), "apikey", .school, nil),
        ]
        for c in cases {
            let yaml = ScaffoldService.minimalConfigYAML(
                profile: workspace, eas: [], workspace: c.kind)
            XCTAssertFalse(yaml.contains("  profile:"), c.old)
            let calls = try await run(Shape(
                name: c.old, yaml: yaml, workspaceAuth: c.auth, workspaceProduct: c.product))
            XCTAssertEqual(calls.transcript, golden[c.old]?.transcript, c.old)
            XCTAssertEqual(calls.sha256, golden[c.old]?.sha256, c.old)
            guard let route = c.platform else { continue }
            let config = try ConfigLoader.loadFromString(yaml)
            XCTAssertEqual(ReportEngine.platformRoute(
                config: config, workspace: try WorkspaceID(validating: workspace)),
                route, c.old)
        }
    }

    private func run(_ shape: Shape) async throws -> GoldenCalls {
        let config = try shape.yaml.map { try ConfigLoader.loadFromString($0) }
        // The dashboard row is the one command line built from config.yaml inside the collect.
        let id = try XCTUnwrap(WorkspaceID(workspace))
        let calls = GoldenCalls { profile, base in
            ReportEngine.dashboardArguments(
                base: base, profile: profile,
                protect: ReportEngine.dashboardProtectProfile(config: config, workspace: id))
        }
        let auth = shape.workspaceAuth
        let product = shape.workspaceProduct
        let workspace = workspace
        let resolved: @Sendable (String) -> ProfileAuthMethod.Resolved? = { name in
            name == workspace
                ? .init(authMethod: auth, isTenantLevel: false, product: product)
                : .init(authMethod: "oauth2", isTenantLevel: false, product: .protect)
        }
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: workspace),
            force: true, config: config, now: .testNoon,
            proCollect: { _, profile, _, _, _, _, _ in
                calls.add(product: "pro", profile: profile); return .collected
            },
            schoolCollect: { _, profile, _, _, _, _ in
                calls.add(product: "school", profile: profile)
            },
            protectCollect: { profile, _, _ in
                calls.add(product: "protect", profile: profile); return ["protect-alerts"]
            },
            resolved: resolved,
            onLine: { calls.log($0.text) })
        return calls
    }
}

private final class GoldenCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriptLines: [String] = []
    private var commandLineText: [String] = []
    private let dashboard: @Sendable (String, [String]) -> [String]

    init(dashboard: @escaping @Sendable (String, [String]) -> [String]) {
        self.dashboard = dashboard
    }

    func log(_ text: String) { append("log " + text, expanded: []) }

    func add(product: String, profile: String) {
        let matrix: [(args: [String], kind: String)] = switch product {
        case "pro": ReportEngine.collectCommandMatrix(profile: profile, staleDays: 30)
        case "school": ReportEngine.schoolCommandMatrix(profile: profile)
        default: ReportEngine.protectCommandMatrix(profile: profile)
        }
        let lines = matrix.map { row in
            row.kind == ReportEngine.dashboardKind && product == "pro"
                ? dashboard(profile, row.args) : row.args
        }
        append("\(product) \(profile)",
               expanded: lines.map { "jamf-cli " + $0.joined(separator: " ") })
    }

    private func append(_ line: String, expanded: [String]) {
        lock.lock(); defer { lock.unlock() }
        transcriptLines.append(line)
        commandLineText += [line] + expanded
    }

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return transcriptLines.joined(separator: "\n")
    }

    var commandLines: String {
        lock.lock(); defer { lock.unlock() }
        return commandLineText.joined(separator: "\n")
    }

    var sha256: String {
        SHA256.hash(data: Data(commandLines.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
