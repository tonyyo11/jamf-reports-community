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
