import XCTest
@testable import JamfReports

/// The Scoring tab writes the whole factor list through `SecurityPolicyConfigWriter`, outside
/// `ConfigService`'s managed keys, so a save must keep every other key in the file and drop the
/// retired `score_weights`. Fixtures are hand-written `config.yaml` text.
final class ScoreFactorsConfigWriteTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor

    private let profile = "jrc-factor-writer"

    private func withWorkspacesRoot(_ body: () throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-factor-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    private func configURL() throws -> URL {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace.appendingPathComponent("config.yaml")
    }

    private func write(_ yaml: String) throws {
        try yaml.write(to: try configURL(), atomically: true, encoding: .utf8)
    }

    private func readBack() throws -> String {
        try String(contentsOf: try configURL(), encoding: .utf8)
    }

    @discardableResult
    private func save(
        _ factors: [Factor]?
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        try SecurityPolicyConfigWriter.save(.scoreFactors(factors), profile: profile)
    }

    private func loaded() -> [Factor]? {
        SecurityPolicyConfigLoader.load(profile: profile).scoreFactors
    }

    private let listed: [Factor] = [
        Factor(.fileVault, weight: 15), Factor(.sip, weight: 10),
        Factor(.osCurrent, weight: 20, graceDays: 45),
        Factor(.xprotectCurrent, weight: 5),
        Factor(.agent, weight: 5, target: "CrowdStrike Falcon"),
        Factor(.mscp, weight: 10, target: "DISA STIG"),
        Factor(.mscp, weight: 3),
    ]

    // MARK: - Round trip

    func testAListRoundTripsThroughTheLoaderInItsOrder() throws {
        try withWorkspacesRoot {
            try write("columns:\n  serial_number: \"Serial Number\"\n")

            try save(listed)

            XCTAssertEqual(loaded(), listed)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
            let text = try readBack()
            XCTAssertTrue(text.contains("Serial Number"), "the rest of the file stays")
            XCTAssertTrue(text.contains("score_factors:"))
            for line in ["factor: filevault", "grace_days: 45", "agent: CrowdStrike Falcon",
                         "baseline: DISA STIG"] {
                XCTAssertTrue(text.contains(line), line)
            }
        }
    }

    /// Saved factors that equal the defaults are still a saved list: they load back as set,
    /// where an absent key would load as nil.
    func testFactorsEqualToTheDefaultsAreWrittenAsAList() throws {
        try withWorkspacesRoot {
            try save(Factor.nativeDefaults)
            XCTAssertEqual(loaded(), Factor.nativeDefaults)
            XCTAssertFalse(try readBack().contains("controls:"), "no control level was written")
        }
    }

    func testAnEmptyListIsWrittenAndLoadsBackEmpty() throws {
        try withWorkspacesRoot {
            try save([])
            XCTAssertEqual(loaded(), [])
            XCTAssertTrue(try readBack().contains("score_factors"))
        }
    }

    /// A grace period belongs to the two currency kinds only, and the entry holds only the keys
    /// its kind takes.
    func testAnEntryHoldsOnlyTheKeysItsKindTakes() throws {
        try withWorkspacesRoot {
            try save([Factor(.sip, weight: 10), Factor(.osCurrent, weight: 5)])
            let text = try readBack()
            XCTAssertFalse(text.contains("grace_days"), "unset: the kind's default applies")
            XCTAssertFalse(text.contains("agent:"))
            XCTAssertFalse(text.contains("baseline:"))
        }
    }

    // MARK: - Weights

    /// A whole weight is a number; a fractional one is text, which the decoder reads back
    /// (YAML has no quotes to write for it, so the file shows `12.5`).
    func testAFractionalWeightIsWrittenAsTextAndReadBack() throws {
        func weightNode(_ factor: Factor) -> YAMLCodec.YAMLValue? {
            SecurityPolicyConfigWriter.entry(factor).mapping?.entries
                .first { $0.key == "weight" }?.value
        }
        XCTAssertEqual(weightNode(Factor(.sip, weight: 12.5)), .scalar(.string("12.5")))
        XCTAssertEqual(weightNode(Factor(.sip, weight: 7)), .scalar(.int(7)))

        try withWorkspacesRoot {
            try save([Factor(.sip, weight: 12.5), Factor(.firewall, weight: 7)])

            let text = try readBack()
            XCTAssertTrue(text.contains("weight: 12.5\n"), text)
            XCTAssertTrue(text.contains("weight: 7\n"), text)
            XCTAssertEqual(loaded()?.map(\.weight), [12.5, 7])
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testWeightsAreWrittenFromZeroToOneHundred() throws {
        try withWorkspacesRoot {
            try save([
                Factor(.fileVault, weight: 150), Factor(.sip, weight: -3),
                Factor(.firewall, weight: 0),
            ])
            XCTAssertEqual(loaded()?.map(\.weight), [100, 0, 0])
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    // MARK: - Removing and replacing

    func testNilRemovesTheKeyAndNothingElse() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              mode: strict
              controls:
                sip: warning
              score_factors:
                - factor: sip
                  weight: 5
            notify:
              enabled: true
            """)
            XCTAssertNotNil(loaded())

            try save(nil)

            let text = try readBack()
            XCTAssertFalse(text.contains("score_factors"))
            for kept in ["mode: strict", "sip: warning", "notify:"] {
                XCTAssertTrue(text.contains(kept), kept)
            }
            XCTAssertNil(loaded())
        }
    }

    func testNilOnAFileWithoutTheKeyWritesNothing() throws {
        try withWorkspacesRoot {
            let typed = "security_policy:\n  # org notes\n  controls:\n    sip: warning\n"
            try write(typed)
            let saved = try save(nil)
            XCTAssertEqual(try readBack(), typed)
            XCTAssertNil(saved.report.backupName)
        }
    }

    /// Saving the list the file already holds changes nothing, so a comment in the block is
    /// not dropped and no backup is made.
    func testASaveOfTheListTheFileAlreadyHoldsLeavesTheFileAlone() throws {
        try withWorkspacesRoot {
            let typed = """
            security_policy:
              score_factors:
                # kept: the list is unchanged
                - factor: sip
                  weight: 5
            """
            try write(typed)

            let saved = try save(try XCTUnwrap(loaded()))

            XCTAssertEqual(try readBack(), typed)
            XCTAssertNil(saved.report.backupName)
        }
    }

    /// A value of the wrong shape under the key is replaced when a list is saved.
    func testAKeyOfTheWrongShapeIsReplacedByTheSavedList() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_factors: 5\n")
            try save(listed)
            XCTAssertEqual(loaded(), listed)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])

            try write("security_policy:\n  score_factors: 5\n")
            try save(nil)
            XCTAssertNil(loaded())
            XCTAssertFalse(try readBack().contains("score_factors"), "nil removes the key")
        }
    }

    func testARepeatedKeyIsWrittenOnce() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              score_factors: []
              score_factors:
                - {factor: sip, weight: 9}
            """)
            XCTAssertEqual(loaded(), [Factor(.sip, weight: 9)], "the last copy is what is read")

            try save([Factor(.sip, weight: 7)])

            XCTAssertEqual(loaded(), [Factor(.sip, weight: 7)])
            XCTAssertEqual(try readBack().components(separatedBy: "score_factors").count, 2)
        }
    }

    // MARK: - Other keys

    /// A level write names one key: a hand-typed list, a fractional weight included, keeps
    /// every value. The block is rewritten, so flow-style entries come back in block style.
    func testASaveOfAControlKeepsTheHandTypedList() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              score_factors:
                - {factor: sip, weight: 12.5}
                - {factor: agent, agent: Falcon, weight: 5}
            """)
            let before = loaded()

            try SecurityPolicyConfigWriter.save(.level(.warning, for: .sip), profile: profile)

            XCTAssertEqual(loaded(), before)
            XCTAssertEqual(loaded(), [
                Factor(.sip, weight: 12.5), Factor(.agent, weight: 5, target: "Falcon"),
            ])
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
        }
    }

    /// Saving a list keeps the levels, the EDR agent and the unknown keys of the block.
    func testASaveOfTheListKeepsTheRestOfTheBlock() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              mode: strict
              edr_agent: Falcon
              controls:
                firewall: warning
              on_values:
                sip: Protected
            """)

            try save([Factor(.sip, weight: 10)])

            let policy = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertEqual(policy.firewall, .warning)
            XCTAssertEqual(policy.edrAgent, "Falcon")
            XCTAssertEqual(policy.scoreFactors, [Factor(.sip, weight: 10)])
            let text = try readBack()
            XCTAssertTrue(text.contains("mode: strict"))
            XCTAssertTrue(text.contains("Protected"))
        }
    }

    /// A key typed by hand inside an entry, and the entry's key order, survive a weight change
    /// to that factor; a grace period the saved factor no longer has is removed.
    func testAnEntryKeepsItsHandTypedKeysWhenItsWeightChanges() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              score_factors:
                - note: keep this
                  factor: os_current
                  weight: 15
                  grace_days: 45
                - factor: agent
                  agent: Falcon
                  owner: secops
                  weight: 5
            """)

            try save([Factor(.osCurrent, weight: 20), Factor(.agent, weight: 8, target: "Falcon")])

            let text = try readBack()
            XCTAssertTrue(text.contains("note: keep this"), text)
            XCTAssertTrue(text.contains("owner: secops"), text)
            XCTAssertFalse(text.contains("grace_days"), text)
            XCTAssertLessThan(
                try XCTUnwrap(text.range(of: "note:")).lowerBound,
                try XCTUnwrap(text.range(of: "factor: os_current")).lowerBound)
            XCTAssertEqual(loaded(), [
                Factor(.osCurrent, weight: 20), Factor(.agent, weight: 8, target: "Falcon"),
            ])
        }
    }

    // MARK: - The retired score_weights

    /// No released build read `score_weights`; the next save of the block removes it, keeps a
    /// copy of the file and names the key.
    func testSavingTheBlockDropsARetiredScoreWeights() throws {
        try withWorkspacesRoot {
            let typed = """
            security_policy:
              controls:
                sip: warning
              score_weights:
                sip: 5
            notify:
              enabled: true
            """
            try write(typed)

            let saved = try save([Factor(.sip, weight: 10)])

            let text = try readBack()
            XCTAssertFalse(text.contains("score_weights"), text)
            XCTAssertTrue(text.contains("sip: warning"))
            XCTAssertTrue(text.contains("notify:"))
            XCTAssertEqual(saved.report.removedRetiredKeys, ["security_policy.score_weights"])
            let name = try XCTUnwrap(saved.report.backupName)
            let copy = try configURL().deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), typed)
        }
    }

    /// Any save of the block removes it, a control level included.
    func testALevelSaveAlsoDropsARetiredScoreWeights() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights:\n    sip: 5\n")
            let saved = try SecurityPolicyConfigWriter.save(
                .level(.warning, for: .sip), profile: profile)
            XCTAssertFalse(try readBack().contains("score_weights"))
            XCTAssertEqual(saved.report.removedRetiredKeys, ["security_policy.score_weights"])
        }
    }

    // MARK: - The entry writer

    func testEntryWritesFactorAndWeightFirstThenTheTargetThenTheGracePeriod() {
        func keys(_ factor: Factor) -> [String] {
            SecurityPolicyConfigWriter.entry(factor).mapping?.entries.map(\.key) ?? []
        }
        XCTAssertEqual(keys(Factor(.sip, weight: 5)), ["factor", "weight"])
        XCTAssertEqual(keys(Factor(.agent, weight: 5, target: "Falcon")),
                       ["factor", "weight", "agent"])
        XCTAssertEqual(keys(Factor(.mscp, weight: 5, target: "STIG")),
                       ["factor", "weight", "baseline"])
        XCTAssertEqual(keys(Factor(.mscp, weight: 5)), ["factor", "weight"])
        XCTAssertEqual(keys(Factor(.osCurrent, weight: 5, graceDays: 45)),
                       ["factor", "weight", "grace_days"])
    }
}
