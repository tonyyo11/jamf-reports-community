import Foundation

/// The pure half of Add environments: reading the pasted lines, naming each jamf-cli profile
/// and refusing a name that cannot be used. No I/O, so the rules are tested without jamf-cli.
enum ConnectionEnvironments {
    struct Entry: Equatable, Sendable {
        var scopeID: String
        var label: String
    }

    enum Refusal: Equatable, Sendable {
        case invalidID
        case duplicateID
        case alreadyInConnection(profile: String)
        case invalidName
        case profileExists(String)
        /// Differs from an existing profile or workspace only by letter case, so the two would
        /// share a folder on a case-insensitive volume.
        case caseVariant(of: String)
        case duplicateName

        var message: String {
            switch self {
            case .invalidID:
                "The ID must be letters, digits, hyphens, underscores or dots, with no spaces."
            case .duplicateID:
                L("This ID is listed more than once.")
            case .alreadyInConnection(let profile):
                L("This ID is already in the connection, as profile \(profile).")
            case .invalidName:
                L("The name made from this label is not a usable profile name.")
            case .profileExists(let name):
                L("A jamf-cli profile named \(name) already exists and was not made by this app's Add environments, or it is in use (it is in a connection, has a workspace, or is not a Platform profile). Registering it would overwrite its credentials. Pick another label.")
            case .caseVariant(let existing):
                L("A name that differs from \(existing) only by letter case would share its folder. Pick another label.")
            case .duplicateName:
                L("Another line makes the same profile name. Pick another label.")
            }
        }
    }

    struct Planned: Equatable, Sendable {
        var entry: Entry
        var profile: String
        var refusal: Refusal?
        /// The profile is already in jamf-cli from an earlier attempt of this app that did not
        /// finish, so `config add-profile` overwrites it.
        var reRegisters = false

        /// The line the sheet shows before a run.
        var previewText: String {
            if let refusal { return refusal.message }
            return reRegisters
                ? L("Profile \(profile) (left in jamf-cli by an earlier attempt; registered again)")
                : L("Profile \(profile)")
        }
    }

    /// Longest slug taken from the connection name or a label.
    static let maxSlugLength = 40

    /// One entry per line: the ID, then an optional label after spaces, a tab or a comma. Blank
    /// lines and lines starting with `#` are skipped. A line with no label is called
    /// "Environment N", N counting from `firstNumber` over the lines that hold an ID.
    static func parse(_ text: String, firstNumber: Int = 1) -> [Entry] {
        var entries: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let separators: Set<Character> = [" ", "\t", ","]
            let end = line.firstIndex { separators.contains($0) } ?? line.endIndex
            let id = String(line[..<end])
            let label = line[end...].trimmingCharacters(
                in: CharacterSet(charactersIn: " \t,").union(.whitespacesAndNewlines))
            entries.append(.init(
                scopeID: id,
                label: label.isEmpty ? "Environment \(firstNumber + entries.count)" : label))
        }
        return entries
    }

    /// Lowercase ASCII letters and digits joined by single hyphens; empty when nothing is left.
    static func slug(_ value: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in value.lowercased().unicodeScalars {
            let isAlnum = (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isAlnum {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return String(out.prefix(maxSlugLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `<connection>-<label>`, each part slugged.
    static func profileName(connection: String, label: String) -> String {
        let first = slug(connection)
        let second = slug(label)
        return "\(first.isEmpty ? "connection" : first)-\(second.isEmpty ? "environment" : second)"
    }

    /// An ID is passed to jamf-cli as a flag value, so one that could read as a flag, or holds
    /// anything but the characters an ID uses, is refused.
    static func isUsableID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first != "-" else { return false }
        return id.unicodeScalars.allSatisfy {
            ($0.value < 0x80 && CharacterSet.alphanumerics.contains($0))
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// Decides each entry's profile name and whether it may be registered. `existingProfiles` is
    /// every jamf-cli profile; `workspaceConflict` names an existing workspace that differs
    /// from a name only by case. `canReRegister` says an existing profile is a leftover of an
    /// earlier attempt of this app (recorded by it, in no connection, no workspace folder), so
    /// the same label may try again.
    static func plan(
        entries: [Entry], connection: Connection, existingProfiles: [String],
        workspaceConflict: (String) -> String? = { _ in nil },
        canReRegister: (String) -> Bool = { _ in false }
    ) -> [Planned] {
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        return entries.map { entry in
            let profile = profileName(connection: connection.name, label: entry.label)
            var planned = Planned(entry: entry, profile: profile, refusal: nil)
            if !isUsableID(entry.scopeID) {
                planned.refusal = .invalidID
            } else if !seenIDs.insert(entry.scopeID).inserted {
                planned.refusal = .duplicateID
            } else if let member = connection.members.first(
                where: { $0.scopeID == entry.scopeID }
            ) {
                planned.refusal = .alreadyInConnection(profile: member.profile)
            } else if !ProfileService.isValid(profile) {
                planned.refusal = .invalidName
            } else if existingProfiles.contains(profile) && !canReRegister(profile) {
                planned.refusal = .profileExists(profile)
            } else if let variant = existingProfiles.first(where: {
                $0 != profile && ProfileName.folderKey($0) == ProfileName.folderKey(profile)
            }) ?? workspaceConflict(profile) {
                planned.refusal = .caseVariant(of: variant)
            } else if !seenNames.insert(ProfileName.folderKey(profile)).inserted {
                planned.refusal = .duplicateName
            } else {
                planned.reRegisters = existingProfiles.contains(profile)
            }
            return planned
        }
    }
}
