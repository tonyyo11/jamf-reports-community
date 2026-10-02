import Foundation

/// Whether a Mac's internal volume is encrypted by hardware (Apple silicon, or an Intel Mac
/// with the T2 chip). `security_policy`'s `filevault_off_hardware_encrypted` rule needs it.
/// Every answer is nil when the facts do not say, so the control's own level applies.
enum HardwareEncryption {

    /// Intel Macs with the Apple T2 Security Chip, by model identifier. Source:
    /// https://support.apple.com/en-us/103265 and Apple's "Identify your … model" pages
    /// (checked 2026-10-01).
    static let t2ModelIdentifiers: Set<String> = [
        "iMac20,1", "iMac20,2", "iMacPro1,1", "MacPro7,1", "Macmini8,1", "MacBookAir8,1",
        "MacBookAir8,2", "MacBookAir9,1", "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3",
        "MacBookPro15,4", "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",
    ]

    /// First match wins: Apple silicon, then a T2 model, then a known Intel Mac (false).
    /// An Intel Mac without a model identifier stays nil, since it could still be a T2.
    static func isHardwareEncrypted(
        appleSilicon: Bool?, modelIdentifier: String?, architecture: String?
    ) -> Bool? {
        let model = trimmed(modelIdentifier)
        let arch = trimmed(architecture).lowercased()
        if appleSilicon == true || arch == "arm64" || arch.hasPrefix("apple m") { return true }
        if t2ModelIdentifiers.contains(model) { return true }
        let intel = appleSilicon == false || arch == "x86_64" || arch == "i386"
            || arch.hasPrefix("intel")
        guard intel, !model.isEmpty else { return nil }
        return false
    }

    /// One row of the `computers` snapshot: `hardware.appleSilicon` and
    /// `hardware.modelIdentifier`.
    static func isHardwareEncrypted(computer item: [String: Any]) -> Bool? {
        let hardware = item["hardware"] as? [String: Any]
        return isHardwareEncrypted(
            appleSilicon: boolean(hardware?["appleSilicon"]),
            modelIdentifier: hardware?["modelIdentifier"] as? String,
            architecture: nil)
    }

    static func serialKey(_ serial: String?) -> String? {
        let key = trimmed(serial).uppercased()
        return key.isEmpty ? nil : key
    }

    /// Answers for the `computers` snapshot, under `s:<serial>` and, when exactly one
    /// computer has the name, `n:<name>`: security rows on some tenants carry no serial.
    /// A Mac with no answer is not stored; a duplicate serial keeps its first answer.
    static func index(computers items: [[String: Any]]) -> [String: Bool] {
        let names = items.map { nameKey(($0["general"] as? [String: Any])?["name"] as? String) }
        var nameCounts: [String: Int] = [:]
        for case let name? in names { nameCounts[name, default: 0] += 1 }

        var index: [String: Bool] = [:]
        for (item, name) in zip(items, names) {
            guard let encrypted = isHardwareEncrypted(computer: item) else { continue }
            let hardware = item["hardware"] as? [String: Any]
            if let serial = serialKey(hardware?["serialNumber"] as? String),
               index["s:" + serial] == nil {
                index["s:" + serial] = encrypted
            }
            if let name, nameCounts[name] == 1 { index["n:" + name] = encrypted }
        }
        return index
    }

    /// Empty unless the policy uses the rule, so a workspace without one never reads
    /// `computers`. A snapshot that cannot be read as a list of computers is logged.
    static func index(dataDir: URL, for policy: SecurityControlPolicy) -> [String: Bool] {
        guard policy.usesHardwareRule else { return [:] }
        let dir = dataDir.appendingPathComponent("computers", isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: dir) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            AppLogger.report.warning("""
                Hardware encryption: could not read \(url.lastPathComponent, privacy: .public) \
                as a list of computers, so the FileVault hardware rule is not applied
                """)
            return [:]
        }
        return index(computers: items)
    }

    /// By serial when the row has one (a serial the index lacks is nil, never a guess by
    /// name); by name only for a row with no serial.
    static func lookup(serial: String?, name: String?, in index: [String: Bool]) -> Bool? {
        if let serial = serialKey(serial) { return index["s:" + serial] }
        guard let name = nameKey(name) else { return nil }
        return index["n:" + name]
    }

    private static func nameKey(_ name: String?) -> String? {
        let key = trimmed(name).lowercased()
        return key.isEmpty ? nil : key
    }

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A JSON Bool or NSNumber, or the text "true" or "false".
    private static func boolean(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: flag
        case let text as String: ["true": true, "false": false][trimmed(text).lowercased()]
        default: nil
        }
    }
}
