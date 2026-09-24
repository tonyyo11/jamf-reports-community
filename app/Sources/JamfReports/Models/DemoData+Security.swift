import Foundation

/// Demo data for the posture, compliance, device-management and Protect screens.
/// Every value is derived from the shared demo facts in `DemoData.swift` and
/// `DemoData+Config.swift` (the 524-Mac fleet, its security controls, macOS
/// versions and compliance bands), so no demo screen contradicts another.
extension DemoData {

    // MARK: - macOS versions

    /// The version number in an `osDistribution` label: "macOS Sequoia 15.4" is
    /// "15.4" and "macOS 13.7.6 (Ventura)" is "13.7.6".
    static func osVersionNumber(_ label: String) -> String {
        let number = label.split(separator: " ").first { $0.first?.isNumber == true }
        return number.map(String.init) ?? label
    }

    /// An ISO 8601 timestamp `minutes` before `referenceDate`, as jamf-cli writes
    /// dates. Built from the reference date, never the clock, so demo ages hold.
    static func timestamp(minutesBefore minutes: Int) -> String {
        let date = referenceDate.addingTimeInterval(-Double(minutes) * 60)
        return ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Fleet

    /// One Mac of the 524-Mac demo fleet. The first eight are `deviceInventory`'s
    /// Macs; the rest follow fixed rules, so every screen that lists Macs names the
    /// same ones and agrees with the fleet's totals: its macOS versions are
    /// `osDistribution`'s, and 26 Macs are stale (13 offline, 9 inactive and
    /// 4 dormant), leaving the 498 active Macs `activeDevicesTrend` ends on.
    struct FleetMac: Sendable, Equatable {
        let jamfID: String
        let name: String
        let serial: String
        let user: String
        let department: String
        let osVersion: String
        let daysSinceContact: Int

        var email: String { "\(user)@meridian.health" }
        var osMajor: Int { ComplianceBandingService.parseOSMajor(osVersion) ?? 0 }
    }

    static let fleetMacs: [FleetMac] = inventoryFleetMacs() + generatedFleetMacs()

    private static func inventoryFleetMacs() -> [FleetMac] {
        var macs: [FleetMac] = []
        for (position, record) in deviceInventory.enumerated() {
            macs.append(FleetMac(
                jamfID: String(1001 + position), name: record.name, serial: record.serial,
                user: record.user, department: record.department,
                osVersion: record.osVersion, daysSinceContact: record.daysSinceContact ?? 0))
        }
        return macs
    }

    private static func generatedFleetMacs() -> [FleetMac] {
        let count = max(totalDevices - deviceInventory.count, 0)
        let versions = generatedOSVersions()
        guard !versions.isEmpty else { return [] }
        var macs: [FleetMac] = []
        for (position, pair) in generatedInitials(count: count).enumerated() {
            let suffix = modelSuffixes[(position * 3) % modelSuffixes.count]
            let initials = initialsLabel(first: pair.first, surname: pair.surname)
            let user = String(firstInitials[pair.first]) + "." + surnames[pair.surname]
            macs.append(FleetMac(
                jamfID: String(1001 + deviceInventory.count + position),
                name: "MERIDIAN-\(initials)-\(suffix)",
                serial: serial(position: position, prefix: serialPrefixes[suffix] ?? "C02"),
                user: user,
                department: departmentCycle[(position * 7) % departmentCycle.count],
                osVersion: versions[(position * 211) % versions.count],
                daysSinceContact: checkInDays(position: position)))
        }
        return macs
    }

    private static let firstInitials = Array("abcdefghjklmnoprstvwy")
    private static let surnames = [
        "adeyemi", "brooks", "castro", "dubois", "evans", "ferreira", "gupta", "haddad",
        "ito", "jensen", "kowalski", "larsen", "moreau", "nguyen", "okafor", "petrov",
        "quinn", "reyes", "sato", "turner", "ueda", "varga", "walsh", "xu", "yamada", "zhou",
    ]
    /// 11 MacBook Pros, 7 MacBook Airs and 2 Mac minis in every 20 Macs.
    private static let modelSuffixes = [
        "MBP", "MBP", "MBP", "MBP", "MBP", "MBP", "MBP", "MBP", "MBP", "MBP", "MBP",
        "MBA", "MBA", "MBA", "MBA", "MBA", "MBA", "MBA", "MM", "MM",
    ]
    private static let serialPrefixes = ["MBP": "C02", "MBA": "FVF", "MM": "H4T"]
    /// `deviceInventory`'s departments, weighted toward a health system's clinical
    /// staff: in every 20 Macs, 6 Clinical, 3 Engineering, 3 Operations, 2 each other.
    private static let departmentCycle = [
        "Clinical", "Clinical", "Clinical", "Clinical", "Clinical", "Clinical",
        "Engineering", "Engineering", "Engineering", "Operations", "Operations", "Operations",
        "Research", "Research", "Finance", "Finance", "Design", "Design", "IT", "IT",
    ]
    /// Days since check-in for the 26 stale generated Macs, every 19th from the
    /// eleventh: 13 offline (31-90), 9 inactive (91-180) and 4 dormant (181+).
    private static let staleCheckInDays = [
        33, 35, 37, 41, 45, 49, 52, 57, 60, 68, 71, 76, 88,
        95, 101, 119, 124, 132, 143, 157, 170, 178,
        188, 214, 266, 390,
    ]
    /// Days since check-in for the other generated Macs, repeating; all under 30.
    private static let activeCheckInDays = [
        0, 0, 1, 0, 2, 0, 1, 0, 0, 3, 0, 7, 0, 1, 14, 0, 0, 2, 0, 22,
    ]

    private static func initialsLabel(first: Int, surname: Int) -> String {
        (String(firstInitials[first]) + String(surnames[surname].prefix(1))).uppercased()
    }

    /// (first initial, surname) index pairs for the generated Macs: a fixed walk
    /// through all 546 pairs that skips the inventory Macs' initials, so no
    /// generated name shares a prefix with one of theirs.
    private static func generatedInitials(count: Int) -> [(first: Int, surname: Int)] {
        let pairCount = firstInitials.count * surnames.count
        let taken = Set(deviceInventory.compactMap { record in
            record.name.split(separator: "-").dropFirst().first.map(String.init)
        })
        var pairs: [(first: Int, surname: Int)] = []
        var step = 0
        while pairs.count < count && step < pairCount {
            let pair = (step * 97 + 13) % pairCount
            let first = pair % firstInitials.count
            let surname = pair / firstInitials.count
            if !taken.contains(initialsLabel(first: first, surname: surname)) {
                pairs.append((first: first, surname: surname))
            }
            step += 1
        }
        return pairs
    }

    /// The generated Macs' macOS versions, grouped: `osDistribution`'s counts less
    /// the inventory Macs' own versions. The fleet spreads them with a fixed stride.
    private static func generatedOSVersions() -> [String] {
        var pool: [String] = []
        for entry in osDistribution {
            let version = osVersionNumber(entry.version)
            let inventory = deviceInventory.filter { $0.osVersion == version }.count
            pool += Array(repeating: version, count: max(entry.count - inventory, 0))
        }
        return pool
    }

    /// A 12-character serial: the model's prefix and nine characters of a fixed
    /// multiplicative hash of the Mac's position, different for every position.
    private static func serial(position: Int, prefix: String) -> String {
        let alphabet = Array("0123456789CDFGHJKLMNPQRTVWXY")
        var modulus = 1
        for _ in 0..<9 { modulus *= alphabet.count }
        var value = ((position + 1) * 6_537_485_779_207) % modulus
        var characters: [Character] = []
        for _ in 0..<9 {
            characters.append(alphabet[value % alphabet.count])
            value /= alphabet.count
        }
        return prefix + String(characters)
    }

    private static func checkInDays(position: Int) -> Int {
        let offset = position - 10
        if offset >= 0, offset % 19 == 0, offset / 19 < staleCheckInDays.count {
            return staleCheckInDays[offset / 19]
        }
        return activeCheckInDays[position % activeCheckInDays.count]
    }

    // MARK: - Offline Outreach

    /// The Offline Outreach screen's inventory: every Mac in `fleetMacs`, last in
    /// contact `daysSinceContact` days before `referenceDate`.
    static let outreachRecords: [DeviceInventoryRecord] = fleetMacs.map(outreachRecord)

    private static func outreachRecord(_ mac: FleetMac) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: mac.jamfID, source: "demo")
        record.jamfID = mac.jamfID
        record.name = mac.name
        record.serial = mac.serial
        record.osVersion = mac.osVersion
        record.user = mac.user
        record.email = mac.email
        record.department = mac.department
        record.managedState = "Managed"
        record.daysSinceContact = mac.daysSinceContact
        record.stale = mac.daysSinceContact >= 30
        record.lastContact = timestamp(minutesBefore: mac.daysSinceContact * 1_440)
        return record
    }

    // MARK: - Compliance Benchmarks

    /// A rule of the demo benchmark and how many of the fleet's Macs fail it.
    struct BenchmarkRule: Sendable, Equatable {
        let id: String
        let failing: Int
    }

    /// The Secure Boot rule, which reports no result on any demo Mac.
    static let unknownBenchmarkRule = "os_secure_boot_verify"
    private static let fileVaultBenchmarkRule = "system_settings_filevault_enforce"

    /// The demo benchmark's rules with results, most failing first: the Overview's
    /// top failing rules and the four security controls.
    static let benchmarkRules: [BenchmarkRule] = {
        let controls = securityControls
        let controlRules = [
            BenchmarkRule(
                id: fileVaultBenchmarkRule, failing: controls.total - controls.fileVault),
            BenchmarkRule(
                id: "system_settings_firewall_enable", failing: controls.total - controls.firewall),
            BenchmarkRule(
                id: "os_gatekeeper_enable", failing: controls.total - controls.gatekeeper),
            BenchmarkRule(id: "os_sip_enable", failing: controls.total - controls.sip),
        ]
        let topRules = topFailingRules.map { BenchmarkRule(id: $0.ruleID, failing: $0.fails) }
        return (topRules + controlRules).sorted { $0.failing > $1.failing }
    }()

    /// The rules each Mac in `fleetMacs` fails, in fleet order. An inventory Mac
    /// fails one top rule per five failed mSCP rules it reports, plus FileVault
    /// when its disk is not encrypted. 209 generated Macs pass everything, so 213
    /// pass in all, the Pass band of `complianceBands`. Each rule's remaining
    /// failures are dealt in turn across the other generated Macs, so every rule
    /// fails on exactly its count.
    static let benchmarkFailures: [Set<String>] = {
        var failures = deviceInventory.map(inventoryBenchmarkFailures)
        let generated = max(fleetMacs.count - failures.count, 0)
        let passing = (complianceBands.first?.count ?? 0) - failures.filter(\.isEmpty).count
        var remaining: [String: Int] = [:]
        for rule in benchmarkRules {
            let taken = failures.filter { $0.contains(rule.id) }.count
            remaining[rule.id] = max(rule.failing - taken, 0)
        }
        failures += [Set<String>](repeating: [], count: generated)
        // A fixed stride through the generated Macs picks the ones that pass.
        let pool = (0..<generated)
            .filter { ($0 * 41) % generated >= passing }
            .map { $0 + deviceInventory.count }
        guard !pool.isEmpty else { return failures }
        var cursor = 0
        for rule in benchmarkRules {
            let count = min(remaining[rule.id] ?? 0, pool.count)
            for offset in 0..<count {
                failures[pool[(cursor + offset) % pool.count]].insert(rule.id)
            }
            cursor = (cursor + count) % pool.count
        }
        return failures
    }()

    private static func inventoryBenchmarkFailures(_ record: DeviceInventoryRecord) -> Set<String> {
        let topCount = record.failedRules == 0
            ? 0 : min(topFailingRules.count, (record.failedRules + 4) / 5)
        var failing = Set(topFailingRules.prefix(topCount).map(\.ruleID))
        if record.fileVault != "Encrypted" {
            failing.insert(fileVaultBenchmarkRule)
        }
        return failing
    }

    /// The Compliance Benchmarks screen: the configured benchmark's rules and all
    /// 524 Macs, each passing or failing the 11 rules that report a result.
    static let complianceBenchmarksSnapshot = makeComplianceBenchmarksSnapshot()

    private static func makeComplianceBenchmarksSnapshot() -> ComplianceBenchmarksService.Snapshot {
        typealias Rule = ComplianceBenchmarksService.Snapshot.Rule
        typealias Device = ComplianceBenchmarksService.Snapshot.Device
        let total = fleetMacs.count
        var rules: [Rule] = benchmarkRules.map { rule in
            Rule(rule: rule.id, passed: total - rule.failing, failed: rule.failing, unknown: 0,
                 devices: total, passRate: percentLabel(total - rule.failing, of: total),
                 ruleId: rule.id, benchmark: complianceBaseline)
        }
        rules.append(Rule(
            rule: unknownBenchmarkRule, passed: 0, failed: nil, unknown: total, devices: total,
            passRate: "", ruleId: unknownBenchmarkRule, benchmark: complianceBaseline))
        let evaluated = benchmarkRules.count
        var devices: [Device] = []
        for (mac, failing) in zip(fleetMacs, benchmarkFailures) {
            let passed = evaluated - failing.count
            devices.append(Device(
                device: mac.name, deviceId: mac.jamfID, rulesPassed: passed,
                rulesFailed: failing.count, compliance: percentLabel(passed, of: evaluated),
                benchmark: complianceBaseline))
        }
        return ComplianceBenchmarksService.Snapshot(
            rules: rules, devices: devices, rulesSourceFile: nil, devicesSourceFile: nil,
            snapshotDate: referenceDate)
    }

    /// A share to one decimal place without a trailing ".0" ("92%", "74.4%"), the
    /// way jamf-cli prints pass rates.
    static func percentLabel(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "" }
        let tenths = (Double(part) / Double(whole) * 1_000).rounded()
        if tenths.truncatingRemainder(dividingBy: 10) == 0 {
            return "\(Int(tenths / 10))%"
        }
        return String(format: "%.1f%%", tenths / 10)
    }

    // MARK: - DDM

    /// Macs with Declarative Device Management enabled: every Mac on macOS 13 or
    /// later. The 17 on macOS Monterey 12 cannot use it.
    static let ddmFleetMacs: [FleetMac] = fleetMacs.filter { $0.osMajor >= 13 }

    /// The declarations each DDM-enabled Mac reports: Baseline Security's four,
    /// Software Update Eligibility's two and Jamf's group-membership declaration.
    private enum DDMIdentifier {
        static let passcode = "com.meridian.baseline.passcode"
        static let diskManagement = "com.meridian.baseline.disk-management"
        static let legacyProfile = "com.meridian.baseline.legacy-profile"
        static let statusSubscriptions = "com.meridian.baseline.status-subscriptions"
        static let updateEnforcement = "com.meridian.softwareupdate.enforcement"
        static let updateSettings = "com.meridian.softwareupdate.settings"
        static let groupMembership = "com.jamf.device-group-membership"
    }

    private static let updateFailureReasons = [
        "Not enough free disk space to prepare the update",
        "The update could not be downloaded",
    ]

    /// The per-device DDM scan, one row per DDM-enabled Mac. Baseline Security's
    /// legacy-profile declaration is invalid on 12 Macs. The Macs one release behind
    /// the newest (15.3.2) all have 15.4 pending, and on 42 of them the update
    /// failed, which leaves the update enforcement declaration inactive.
    static let ddmDeviceStatusSnapshot = makeDDMDeviceStatusSnapshot()

    private static func makeDDMDeviceStatusSnapshot() -> DDMDeviceStatusService.Snapshot {
        let latest = osVersionNumber(osDistribution.first?.version ?? "")
        let latestMajor = ComplianceBandingService.parseOSMajor(latest) ?? 0
        var records: [DDMDeviceStatusRecord] = []
        var behind = 0
        for (position, mac) in ddmFleetMacs.enumerated() {
            var pending: String?
            var failure: String?
            if mac.osMajor == latestMajor && mac.osVersion != latest {
                pending = latest
                if behind % 7 < 3 {
                    failure = updateFailureReasons[behind % 7 < 2 ? 0 : 1]
                }
                behind += 1
            }
            records.append(ddmRecord(
                mac, baselineInvalid: position % 42 == 17, pending: pending, failure: failure))
        }
        return DDMDeviceStatusService.Snapshot(
            records: records, isDetected: true, readFailed: false,
            snapshotDate: referenceDate, sourceDates: [:])
    }

    private static func ddmRecord(
        _ mac: FleetMac, baselineInvalid: Bool, pending: String?, failure: String?
    ) -> DDMDeviceStatusRecord {
        typealias Declaration = DDMDeviceStatusRecord.Declaration
        let declarations = [
            Declaration(identifier: DDMIdentifier.passcode, active: true, valid: true),
            Declaration(identifier: DDMIdentifier.diskManagement, active: true, valid: true),
            Declaration(
                identifier: DDMIdentifier.legacyProfile,
                active: !baselineInvalid, valid: !baselineInvalid),
            Declaration(identifier: DDMIdentifier.statusSubscriptions, active: true, valid: true),
            Declaration(
                identifier: DDMIdentifier.updateEnforcement, active: failure == nil, valid: true),
            Declaration(identifier: DDMIdentifier.updateSettings, active: true, valid: true),
            Declaration(identifier: DDMIdentifier.groupMembership, active: true, valid: true),
        ]
        var installState: String?
        if pending != nil {
            installState = failure == nil ? "downloading" : "failed"
        }
        return DDMDeviceStatusRecord(
            deviceId: mac.jamfID, name: mac.name, managementId: "meridian-\(mac.jamfID)",
            osVersion: mac.osVersion,
            reportDate: timestamp(minutesBefore: mac.daysSinceContact * 1_440),
            ddmReported: true, declarations: declarations,
            softwareUpdate: DDMDeviceStatusRecord.SoftwareUpdate(
                pendingOSVersion: pending, installState: installState, failureReason: failure))
    }

    /// The Platform blueprints and declaration sources, counted from the per-device
    /// scan so both halves of the DDM screen agree. Blueprints reach only the
    /// DDM-enabled Macs: Baseline Security fails where its legacy profile is invalid,
    /// Software Update Eligibility where the update failed.
    static let ddmBlueprintSnapshot = makeDDMBlueprintSnapshot()

    private static func makeDDMBlueprintSnapshot() -> DDMBlueprintService.Snapshot {
        let records = ddmDeviceStatusSnapshot.records
        let enabled = records.count
        let baselineFailed = records.filter { record in
            record.declarations.contains { $0.valid == false }
        }.count
        let updateFailed = records.filter { $0.softwareUpdate.failureReason != nil }.count
        return DDMBlueprintService.Snapshot(
            blueprints: [
                .init(name: "Baseline Security", state: "DEPLOYED", scope: enabled, steps: 4,
                      succeeded: enabled - baselineFailed, failed: baselineFailed, pending: 0),
                .init(name: "Software Update Eligibility", state: "DEPLOYED", scope: enabled,
                      steps: 2, succeeded: enabled - updateFailed, failed: updateFailed,
                      pending: 0),
                .init(name: "Beta Test Group", state: "DEPLOYED", scope: 24,
                      steps: 1, succeeded: 22, failed: 0, pending: 2),
                .init(name: "Legacy Profile Removal", state: "NOT_DEPLOYED", scope: 100,
                      steps: 1, succeeded: 0, failed: nil, pending: nil),
                .init(name: "OOO Macs Lockdown", state: "OUT_OF_DATE", scope: 12,
                      steps: 3, succeeded: 0, failed: nil, pending: nil),
            ],
            declarations: [
                .init(source: "Baseline Security", type: "blueprint", declarations: 4,
                      devices: enabled, successful: enabled - baselineFailed,
                      unsuccessful: baselineFailed),
                .init(source: "Software Update Eligibility", type: "blueprint", declarations: 2,
                      devices: enabled, successful: enabled - updateFailed,
                      unsuccessful: updateFailed),
                .init(source: "Device Group Membership", type: "system", declarations: 1,
                      devices: enabled, successful: enabled, unsuccessful: 0),
            ],
            blueprintsSourceFile: nil,
            declarationsSourceFile: nil,
            snapshotDate: referenceDate)
    }

    // MARK: - Security Posture

    /// The Security Posture screen's `pro report security` snapshot: the four
    /// controls out of the 524-Mac fleet and the Overview's macOS distribution.
    static let securityPostureSnapshot = SecurityPostureService.Snapshot(
        totalDevices: securityControls.total,
        fileVaultEncrypted: securityControls.fileVault,
        sipEnabled: securityControls.sip,
        firewallEnabled: securityControls.firewall,
        gatekeeperEnabled: securityControls.gatekeeper,
        osVersions: osDistribution.map { entry in
            SecurityPostureService.Snapshot.OSVersion(
                osVersion: osVersionNumber(entry.version), count: entry.count, pct: entry.pct)
        },
        sourceFile: nil,
        snapshotDate: referenceDate
    )

    // MARK: - Compliance Posture

    /// The Compliance Posture screen's mSCP baselines. The configured benchmark is
    /// banded exactly as `complianceBands`, with 22 of the 524 Macs reporting no
    /// failure count; DISA STIG reports on every Mac.
    static let complianceBaselineResults: [MSCPComplianceService.BaselineResult] = [
        baselineResult(
            name: complianceBaseline, column: configState.failuresCountColumn,
            bandCounts: complianceBands.map(\.count)),
        baselineResult(
            name: "DISA STIG", column: "STIG Failures Count",
            bandCounts: [304, 96, 64, 32, 28]),
    ]

    /// A failure count inside each of the Pass, Low, Med-Low, Medium and High bands.
    private static let bandFailureCounts = [0, 5, 20, 40, 60]

    /// A baseline whose Pass through High bands hold `bandCounts` Macs; the rest of
    /// the fleet reports no failure count.
    private static func baselineResult(
        name: String, column: String, bandCounts: [Int]
    ) -> MSCPComplianceService.BaselineResult {
        var failures: [Int?] = []
        for (count, failureCount) in zip(bandCounts, bandFailureCounts) {
            failures += [Int?](repeating: failureCount, count: count)
        }
        let withData = failures.count
        failures += [Int?](repeating: nil, count: max(totalDevices - withData, 0))
        let passing = bandCounts.first ?? 0
        return MSCPComplianceService.BaselineResult(
            name: name,
            failuresCountColumn: column,
            bands: ComplianceBandingService.bands(failures: failures),
            noDataCount: failures.count - withData,
            totalDevices: failures.count,
            compliancePct: withData > 0 ? Double(passing) / Double(withData) * 100 : nil)
    }

    /// Macs on each macOS major version with none, one and two of FileVault, SIP,
    /// Firewall and Gatekeeper failing: 65 gaps in all, the complements of
    /// `securityControls` (firewall 42, Gatekeeper 12, FileVault 11, SIP 0).
    static let controlGapsByOSMajor: [(osMajor: Int, macsByGapCount: [Int])] = [
        (15, [360, 25, 0]), (14, [70, 12, 2]), (13, [24, 10, 4]), (12, [12, 4, 1]),
    ]

    /// The control-gap proxy the Compliance Posture screen bands by when no mSCP
    /// baseline is configured, and always uses for its per-OS breakdown.
    static let compliancePostureSnapshot: CompliancePostureService.Snapshot = {
        var pairs: [(osMajor: Int, failures: Int?)] = []
        for row in controlGapsByOSMajor {
            for (gaps, macs) in row.macsByGapCount.enumerated() {
                let pair: (osMajor: Int, failures: Int?) = (row.osMajor, gaps)
                pairs += Array(repeating: pair, count: macs)
            }
        }
        let controls = securityControls
        let failing: [(control: String, macs: Int)] = [
            ("FileVault", controls.total - controls.fileVault),
            ("SIP", controls.total - controls.sip),
            ("Firewall", controls.total - controls.firewall),
            ("Gatekeeper", controls.total - controls.gatekeeper),
        ]
        let gaps = failing
            .map { entry in
                CompliancePostureService.Snapshot.ControlGap(
                    control: entry.control, failingDevices: entry.macs,
                    totalDevices: controls.total)
            }
            .sorted { $0.failingDevices > $1.failingDevices }
        return CompliancePostureService.Snapshot(
            totalDevices: pairs.count,
            bands: ComplianceBandingService.bands(failures: pairs.map { $0.failures }),
            perOSMajor: ComplianceBandingService.bandsByOSMajor(pairs),
            controlGaps: gaps,
            sourceFile: nil,
            snapshotDate: referenceDate)
    }()
}
