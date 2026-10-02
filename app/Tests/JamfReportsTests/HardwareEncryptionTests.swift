import XCTest
@testable import JamfReports

/// Whether a Mac's internal volume is hardware-encrypted (Apple silicon, or Intel with a
/// T2 chip), the fact the `filevault_off_hardware_encrypted` rule needs.
final class HardwareEncryptionTests: XCTestCase {

    private let t2Models = [
        "iMac20,1", "iMac20,2", "iMacPro1,1", "MacPro7,1", "Macmini8,1", "MacBookAir8,1",
        "MacBookAir8,2", "MacBookAir9,1", "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3",
        "MacBookPro15,4", "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",
    ]

    private func check(
        appleSilicon: Bool? = nil, model: String? = nil, architecture: String? = nil
    ) -> Bool? {
        HardwareEncryption.isHardwareEncrypted(
            appleSilicon: appleSilicon, modelIdentifier: model, architecture: architecture)
    }

    // MARK: - isHardwareEncrypted(appleSilicon:modelIdentifier:architecture:)

    func testT2SetIsExactlyTheSixteenModels() {
        XCTAssertEqual(HardwareEncryption.t2ModelIdentifiers, Set(t2Models))
        XCTAssertEqual(HardwareEncryption.t2ModelIdentifiers.count, 16)
    }

    func testEveryT2ModelIsHardwareEncryptedOnModelAlone() {
        for model in t2Models { XCTAssertEqual(check(model: model), true, model) }
        XCTAssertEqual(check(model: "  MacBookPro16,2 "), true, "model is trimmed")
    }

    /// A T2 Mac is an Intel Mac, so a stated Intel does not override the model.
    func testT2ModelWinsOverAnIntelArchitecture() {
        XCTAssertEqual(check(appleSilicon: false, model: "MacBookPro16,2"), true)
        XCTAssertEqual(check(model: "iMac20,1", architecture: "x86_64"), true)
    }

    func testIntelMacsWithoutT2AreNotHardwareEncrypted() {
        XCTAssertEqual(check(appleSilicon: false, model: "MacBookPro14,1"), false)
        XCTAssertEqual(check(appleSilicon: false, model: "iMac19,1"), false)
        XCTAssertEqual(check(model: "MacBookPro14,1", architecture: "x86_64"), false)
        XCTAssertEqual(check(model: "iMac19,1", architecture: "i386"), false)
        XCTAssertEqual(check(model: "iMac19,1", architecture: " Intel Core i7 "), false)
    }

    /// Not a T2 model and nothing says Intel: these two are Apple silicon, but the
    /// identifier alone does not tell, so the control's own level applies.
    func testAModelWithNoOtherFactIsUnknown() {
        XCTAssertNil(check(model: "MacBookPro17,1"))
        XCTAssertNil(check(model: "MacBookAir10,1"))
    }

    func testAppleSiliconIsHardwareEncrypted() {
        XCTAssertEqual(check(appleSilicon: true), true)
        XCTAssertEqual(check(architecture: "arm64"), true)
        XCTAssertEqual(check(architecture: "Apple M3 Pro"), true)
        XCTAssertEqual(check(architecture: "  APPLE M1 "), true)
        XCTAssertEqual(check(appleSilicon: true, model: "iMac19,1", architecture: "x86_64"), true,
                       "first match wins")
        XCTAssertEqual(check(appleSilicon: false, architecture: "arm64"), true,
                       "first match wins")
    }

    /// A guest's disk is a file on the host, not a volume the Secure Enclave encrypts, yet
    /// an Apple-silicon guest reports `appleSilicon: true`.
    func testAVirtualMachineIsNeverHardwareEncrypted() {
        XCTAssertNil(check(appleSilicon: true, model: "VirtualMac2,1"))
        XCTAssertNil(check(appleSilicon: true, model: " virtualmac2,1 "))
        XCTAssertNil(check(model: "VirtualMac2,1", architecture: "arm64"))
        XCTAssertNil(check(model: "VMware7,1", architecture: "x86_64"))
        XCTAssertNil(check(appleSilicon: true, model: "Parallels-ARM", architecture: "Apple M1"))
        XCTAssertNil(check(model: "PARALLELS20,1"))
        XCTAssertEqual(check(appleSilicon: true, model: "Mac14,2"), true,
                       "a real Apple-silicon Mac still is")
    }

    func testIntelWithoutAModelIsUnknown() {
        XCTAssertNil(check(appleSilicon: false))
        XCTAssertNil(check(appleSilicon: false, model: ""))
        XCTAssertNil(check(appleSilicon: false, model: "   "))
        XCTAssertNil(check(architecture: "x86_64"))
    }

    func testNoFactsIsUnknown() {
        XCTAssertNil(check())
        XCTAssertNil(check(model: "", architecture: ""))
        XCTAssertNil(check(architecture: "something new"))
    }

    // MARK: - isHardwareEncrypted(computer:)

    func testComputerReadsAppleSiliconAsBoolNumberOrString() {
        func computer(_ value: Any) -> [String: Any] {
            ["hardware": ["appleSilicon": value, "modelIdentifier": "MacBookPro14,1"]]
        }
        XCTAssertEqual(HardwareEncryption.isHardwareEncrypted(computer: computer(true)), true)
        XCTAssertEqual(HardwareEncryption.isHardwareEncrypted(computer: computer(false)), false)
        XCTAssertEqual(
            HardwareEncryption.isHardwareEncrypted(computer: computer(NSNumber(value: true))), true)
        XCTAssertEqual(
            HardwareEncryption.isHardwareEncrypted(computer: computer(NSNumber(value: false))),
            false)
        XCTAssertEqual(HardwareEncryption.isHardwareEncrypted(computer: computer("true")), true)
        XCTAssertEqual(HardwareEncryption.isHardwareEncrypted(computer: computer(" False ")), false)
        XCTAssertNil(HardwareEncryption.isHardwareEncrypted(computer: computer("maybe")),
                     "an unreadable flag is no flag, and MacBookPro14,1 alone does not say Intel")
    }

    func testAVirtualMachineComputerIsNotIndexed() {
        let vm = computer(name: "vm-1", serial: "VM1", appleSilicon: true, model: "VirtualMac2,1")
        XCTAssertNil(HardwareEncryption.isHardwareEncrypted(computer: vm))
        XCTAssertTrue(HardwareEncryption.index(computers: [vm]).isEmpty)
    }

    func testComputerFallsBackToTheModelIdentifier() {
        let t2: [String: Any] = ["hardware": ["modelIdentifier": "MacBookPro16,1"]]
        let unknown: [String: Any] = ["hardware": ["modelIdentifier": "MacBookPro17,1"]]
        XCTAssertEqual(HardwareEncryption.isHardwareEncrypted(computer: t2), true)
        XCTAssertNil(HardwareEncryption.isHardwareEncrypted(computer: unknown))
        XCTAssertNil(HardwareEncryption.isHardwareEncrypted(computer: [:]))
        XCTAssertNil(HardwareEncryption.isHardwareEncrypted(computer: ["hardware": "x"]))
    }

    // MARK: - serialKey

    func testSerialKeyIsTrimmedAndUppercased() {
        XCTAssertEqual(HardwareEncryption.serialKey(" c02xk9phjg5j\n"), "C02XK9PHJG5J")
        XCTAssertNil(HardwareEncryption.serialKey(""))
        XCTAssertNil(HardwareEncryption.serialKey("  \t"))
        XCTAssertNil(HardwareEncryption.serialKey(nil))
    }

    // MARK: - index(computers:) and lookup

    /// A `computers` snapshot row: the real keys only (`general.name`, `hardware.*`).
    private func computer(
        name: String? = nil, serial: String? = nil, appleSilicon: Bool? = nil,
        model: String? = nil
    ) -> [String: Any] {
        var hardware: [String: Any] = [:]
        if let serial { hardware["serialNumber"] = serial }
        if let appleSilicon { hardware["appleSilicon"] = appleSilicon }
        if let model { hardware["modelIdentifier"] = model }
        var row: [String: Any] = ["hardware": hardware]
        if let name { row["general"] = ["name": name] }
        return row
    }

    private func fixtureComputers(_ path: String) throws -> [[String: Any]] {
        let url = TestFixtures.dir("jamf-cli-data/\(path)")
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(parsed as? [[String: Any]])
    }

    /// `computers-v4.json` is the Jamf Pro v4 shape jamf-cli returns for `--section HARDWARE`;
    /// its three Mac14,x models are Apple silicon and carry `hardware.appleSilicon`.
    func testIndexOfTheV4Fixture() throws {
        let index = HardwareEncryption.index(computers: try fixtureComputers(
            "computers-v4/computers-v4.json"))
        let serialKeys = index.keys.filter { $0.hasPrefix("s:") }.sorted()
        XCTAssertEqual(serialKeys, ["s:FXTR0021AA", "s:FXTR0022AA", "s:FXTR0023AA"])
        XCTAssertEqual(index.keys.filter { $0.hasPrefix("n:") }.sorted(),
                       ["n:lab-mac-21", "n:lab-mac-22", "n:lab-mac-23"],
                       "each name is unique in the snapshot")
        XCTAssertTrue(index.values.allSatisfy { $0 })
        XCTAssertEqual(index.count, 6)
    }

    func testIndexOfAListWithNoHardwareFactsIsEmpty() throws {
        let index = HardwareEncryption.index(computers: try fixtureComputers(
            "computers-list/computers-list.json"))
        XCTAssertTrue(index.isEmpty)
    }

    func testIndexStoresOnlyComputersWithAnAnswer() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "a", serial: "S1", appleSilicon: true),
            computer(name: "b", serial: "S2", appleSilicon: false, model: "iMac19,1"),
            computer(name: "c", serial: "S3"),
        ])
        XCTAssertEqual(index["s:S1"], true)
        XCTAssertEqual(index["s:S2"], false, "a known Intel Mac is a stored false, not absent")
        XCTAssertNil(index["s:S3"])
        XCTAssertNil(index["n:c"])
    }

    /// A logic-board swap leaves two records with one serial. When they disagree the
    /// index must not pick one: a wrong `true` would hide a real FileVault gap.
    func testADuplicateSerialWithConflictingAnswersIsNotStored() {
        let silicon = computer(name: "a", serial: "dup1", appleSilicon: true)
        let intel = computer(name: "b", serial: " DUP1 ", appleSilicon: false, model: "iMac19,1")
        for order in [[silicon, intel], [intel, silicon]] {
            let index = HardwareEncryption.index(computers: order)
            XCTAssertNil(index["s:DUP1"])
            XCTAssertNil(HardwareEncryption.lookup(serial: "DUP1", name: "a", in: index),
                         "a row with a serial is never matched by name")
        }
    }

    /// A computer with no answer that shares the serial makes it ambiguous, as a shared
    /// name does.
    func testADuplicateSerialWithAComputerThatHasNoAnswerIsNotStored() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "a", serial: "dup1", appleSilicon: true),
            computer(name: "b", serial: "dup1"),
        ])
        XCTAssertNil(index["s:DUP1"])
        let reversed = HardwareEncryption.index(computers: [
            computer(name: "b", serial: "dup1"),
            computer(name: "a", serial: "dup1", appleSilicon: true),
        ])
        XCTAssertNil(reversed["s:DUP1"])
    }

    func testADuplicateSerialWithTheSameAnswerIsStored() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "a", serial: "dup1", appleSilicon: true),
            computer(name: "b", serial: " DUP1 ", appleSilicon: true),
            computer(name: "c", serial: "dup2", appleSilicon: false, model: "iMac19,1"),
            computer(name: "d", serial: "dup2", appleSilicon: false, model: "iMac19,1"),
        ])
        XCTAssertEqual(index["s:DUP1"], true)
        XCTAssertEqual(index["s:DUP2"], false)
    }

    func testLookupBySerialIsCaseAndWhitespaceInsensitive() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "a", serial: "ab12", appleSilicon: true)])
        XCTAssertEqual(HardwareEncryption.lookup(serial: " AB12 ", name: "x", in: index), true)
    }

    /// A row with a serial the snapshot does not hold is not matched by name: the
    /// serial says which Mac it is.
    func testLookupWithASerialNeverFallsBackToTheName() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "Lab-Mac-1", serial: "S1", appleSilicon: true)])
        XCTAssertNil(HardwareEncryption.lookup(serial: "S9", name: "Lab-Mac-1", in: index))
    }

    func testLookupWithNoSerialResolvesAUniqueName() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "Lab-Mac-1", appleSilicon: true),
            computer(name: "Lab-Mac-2", appleSilicon: false, model: "iMac19,1"),
        ])
        XCTAssertEqual(HardwareEncryption.lookup(serial: "", name: "lab-mac-1", in: index), true)
        XCTAssertEqual(HardwareEncryption.lookup(serial: nil, name: "  LAB-MAC-2 ", in: index),
                       false)
        XCTAssertNil(HardwareEncryption.lookup(serial: "  ", name: "Lab-Mac-3", in: index))
    }

    /// Two computers called "MacBook Pro" cannot be told apart by name; guessing would
    /// give one Mac the other's hardware.
    func testLookupWithNoSerialAndASharedNameIsUnknown() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "MacBook Pro", appleSilicon: true),
            computer(name: "macbook pro ", appleSilicon: true),
        ])
        XCTAssertTrue(index.isEmpty)
        XCTAssertNil(HardwareEncryption.lookup(serial: "", name: "MacBook Pro", in: index))
    }

    /// A computer with no answer still makes a name ambiguous.
    func testASharedNameStaysAmbiguousWhenOnlyOneComputerHasAnAnswer() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "MacBook Pro", appleSilicon: true), computer(name: "MacBook Pro"),
        ])
        XCTAssertNil(HardwareEncryption.lookup(serial: nil, name: "MacBook Pro", in: index))
    }

    /// A Mac the snapshot knows by serial still resolves for a row that carries only a name.
    func testALookupByNameFindsAComputerThatHasASerial() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "Lab-Mac-1", serial: "S1", appleSilicon: true)])
        XCTAssertEqual(HardwareEncryption.lookup(serial: nil, name: "Lab-Mac-1", in: index), true)
    }

    func testLookupWithNothingToMatchIsUnknown() {
        let index = HardwareEncryption.index(computers: [
            computer(name: "a", serial: "S1", appleSilicon: true)])
        XCTAssertNil(HardwareEncryption.lookup(serial: nil, name: nil, in: index))
        XCTAssertNil(HardwareEncryption.lookup(serial: "", name: "  ", in: index))
        XCTAssertNil(HardwareEncryption.lookup(serial: nil, name: "a", in: [:]))
    }

    // MARK: - index(dataDir:for:)

    private func dataDir(withComputers fixture: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-hw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let fixture {
            let dir = root.appendingPathComponent("computers", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: TestFixtures.dir("jamf-cli-data/\(fixture)"),
                to: dir.appendingPathComponent("computers_20261001T090000.json"))
        }
        return root
    }

    private let hardwareRule = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)

    func testIndexFromDiskIsEmptyWithoutTheHardwareRule() throws {
        let root = try dataDir(withComputers: "computers-v4/computers-v4.json")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(HardwareEncryption.index(dataDir: root, for: .default).isEmpty)
        let ignored = SecurityControlPolicy(
            fileVault: .ignore, fileVaultOffHardwareEncrypted: .warning)
        XCTAssertTrue(HardwareEncryption.index(dataDir: root, for: ignored).isEmpty,
                      "FileVault is not evaluated, so the rule is not in use")
    }

    func testIndexFromDiskReadsTheNewestComputersSnapshotWhenTheRuleIsOn() throws {
        let root = try dataDir(withComputers: "computers-v4/computers-v4.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HardwareEncryption.index(dataDir: root, for: hardwareRule)
        XCTAssertEqual(index["s:FXTR0021AA"], true)
        XCTAssertEqual(index.count, 6)
    }

    func testIndexFromDiskIsEmptyForMissingUnreadableOrNonArrayData() throws {
        let missing = try dataDir(withComputers: nil)
        defer { try? FileManager.default.removeItem(at: missing) }
        XCTAssertTrue(HardwareEncryption.index(dataDir: missing, for: hardwareRule).isEmpty)

        let object = try dataDir(withComputers: nil)
        defer { try? FileManager.default.removeItem(at: object) }
        let dir = object.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"results\": []}".utf8).write(
            to: dir.appendingPathComponent("computers_20261001T090000.json"))
        XCTAssertTrue(HardwareEncryption.index(dataDir: object, for: hardwareRule).isEmpty)

        let garbage = try dataDir(withComputers: nil)
        defer { try? FileManager.default.removeItem(at: garbage) }
        let garbageDir = garbage.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: garbageDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: garbageDir.appendingPathComponent("computers_20261001T090000.json"))
        XCTAssertTrue(HardwareEncryption.index(dataDir: garbage, for: hardwareRule).isEmpty)
    }
}
