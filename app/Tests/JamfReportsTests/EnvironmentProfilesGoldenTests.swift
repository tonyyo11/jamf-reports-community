import CryptoKit
import XCTest
@testable import JamfReports

/// The gate for the environment model's first phases: every config.yaml shape a workspace has
/// today routes a collect to the same products, with the same `-p` profiles and the same router
/// lines, so the jamf-cli command lines are byte for byte what they were before `profiles:`.
/// Captured through the router's closure seams; no jamf-cli runs.
@MainActor
final class EnvironmentProfilesGoldenTests: XCTestCase {
    private let workspace = "ws-golden"
    private var root: URL!

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
            sha256: "c364263b639293cb634de5d932acd6e31616f01db793527f7fbdf147d01545a1"),
        "pro-platform": (
            transcript: """
                pro ws-golden
                """,
            sha256: "c364263b639293cb634de5d932acd6e31616f01db793527f7fbdf147d01545a1"),
        "pro-protect": (
            transcript: """
                pro ws-golden
                log [info] running protect collect for ws-golden
                protect ws-golden-protect
                """,
            sha256: "f0efc4da5917b07516b6211d95aa3cc6fbba44a79430dbeacc58a1d75f98ffbc"),
        "pro-protect-blank": (
            transcript: """
                pro ws-golden
                log [warn] Jamf Protect not collected: protect.profile is blank
                """,
            sha256: "b135a596664d85e0aa149309ef852658f7a9721e321bdf03a2f0de1b58a98f08"),
        "pro-protect-disabled": (
            transcript: """
                pro ws-golden
                """,
            sha256: "c364263b639293cb634de5d932acd6e31616f01db793527f7fbdf147d01545a1"),
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
            sha256: "f0efc4da5917b07516b6211d95aa3cc6fbba44a79430dbeacc58a1d75f98ffbc"),
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
            sha256: "c364263b639293cb634de5d932acd6e31616f01db793527f7fbdf147d01545a1"),
        "no-config": (
            transcript: """
                pro ws-golden
                """,
            sha256: "c364263b639293cb634de5d932acd6e31616f01db793527f7fbdf147d01545a1"),
    ]

    func testEveryOldShapeRunsTheSameCommandLines() async throws {
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

    private func run(_ shape: Shape) async throws -> GoldenCalls {
        let config = try shape.yaml.map { try ConfigLoader.loadFromString($0) }
        // The dashboard row is the one command line built from config.yaml inside the collect.
        let calls = GoldenCalls { profile, base in
            ReportEngine.dashboardArguments(
                base: base, profile: profile,
                protect: EnvironmentProfiles.resolve(config: config, workspace: profile).protect)
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
            profile: workspace, force: true, config: config, now: .testNoon,
            proCollect: { profile, _, _, _, _, _ in
                calls.add(product: "pro", profile: profile); return .collected
            },
            schoolCollect: { profile, _, _, _, _ in
                calls.add(product: "school", profile: profile)
            },
            protectCollect: { profile, _, _ in calls.add(product: "protect", profile: profile) },
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
