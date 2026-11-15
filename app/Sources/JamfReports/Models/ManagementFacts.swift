import Foundation

/// A Jamf binary version's major and minor, from `general.jamfBinaryVersion`.
struct BinaryVersion: Sendable, Hashable, Comparable {
    let major: Int
    let minor: Int

    /// Reads the leading `major.minor` of "11.33.3-t1793127642444"; nil when it has neither.
    init?(_ raw: String) {
        let parts = raw.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let major = Int(parts[0].prefix { $0.isASCII && $0.isNumber }),
              let minor = Int(parts[1].prefix { $0.isASCII && $0.isNumber }) else { return nil }
        self.major = major
        self.minor = minor
    }

    static func < (lhs: BinaryVersion, rhs: BinaryVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    var label: String { "\(major).\(minor)" }
}

/// One Mac's management fields from its `computers` row. Each is read on its own, so an odd
/// value costs that field: an absent key, a null and a value of the wrong type are all nil
/// (not reported), never false, 0 or "".
struct ManagementFacts: Sendable, Hashable {
    var mdmProfileExpiration: Date?
    var jamfBinaryVersion: String?
    var binaryVersion: BinaryVersion?
    var userApprovedMDM: Bool?
    var mdmCapable: Bool?
    var supervised: Bool?
    var enrolledViaADE: Bool?
    var lastCloudBackupDate: Date?
    var appleEnrollmentType: String?
    var awaitingConfiguration: Bool?
    var attestationStatus: String?
    var lastSuccessfulAttestation: Date?
    var recoveryLockEnabled: Bool?
    var activationLockEnabled: Bool?
    var externalBootLevel: String?
    var autoLoginDisabled: Bool?
    var remoteDesktopEnabled: Bool?
    var lockdownModeEnabled: Bool?
    var batteryHealth: String?
    /// Jamf reports -1 with no battery reading; that is not reported.
    var batteryCapacityPercent: Double?

    init(item: [String: Any]) {
        mdmProfileExpiration = Self.date(Self.at(item, "general", "mdmProfileExpiration"))
        jamfBinaryVersion = Self.string(Self.at(item, "general", "jamfBinaryVersion"))
        binaryVersion = jamfBinaryVersion.flatMap(BinaryVersion.init)
        userApprovedMDM = Self.bool(Self.at(item, "general", "userApprovedMdm"))
        mdmCapable = Self.bool(Self.at(item, "general", "mdmCapable", "capable"))
        supervised = Self.bool(Self.at(item, "general", "supervised"))
        enrolledViaADE = Self.bool(Self.at(item, "general", "enrolledViaAutomatedDeviceEnrollment"))
        lastCloudBackupDate = Self.date(Self.at(item, "general", "lastCloudBackupDate"))
        appleEnrollmentType = Self.string(Self.at(item, "general", "appleEnrollmentType"))
        awaitingConfiguration = Self.bool(Self.at(item, "general", "awaitingConfiguration"))
        attestationStatus = Self.string(Self.at(item, "security", "attestationStatus"))
        lastSuccessfulAttestation = Self.date(
            Self.at(item, "security", "lastSuccessfulAttestation"))
        recoveryLockEnabled = Self.bool(Self.at(item, "security", "recoveryLockEnabled"))
        activationLockEnabled = Self.bool(Self.at(item, "security", "activationLockEnabled"))
        externalBootLevel = Self.string(Self.at(item, "security", "externalBootLevel"))
        autoLoginDisabled = Self.bool(Self.at(item, "security", "autoLoginDisabled"))
        remoteDesktopEnabled = Self.bool(Self.at(item, "security", "remoteDesktopEnabled"))
        lockdownModeEnabled = Self.bool(Self.at(item, "security", "lockdownModeEnabled"))
        batteryHealth = Self.string(Self.at(item, "hardware", "batteryHealth"))
        batteryCapacityPercent = Self.number(Self.at(item, "hardware", "batteryCapacityPercent"))
            .flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func at(_ item: [String: Any], _ path: String...) -> Any? {
        var node: Any? = item
        for key in path { node = (node as? [String: Any])?[key] }
        return node
    }

    // `as? Bool` would read a JSON 0 or 1 as a Boolean; only a real JSON boolean counts.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func date(_ value: Any?) -> Date? {
        string(value).flatMap(DeviceInventoryService.parseDate)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }
}
