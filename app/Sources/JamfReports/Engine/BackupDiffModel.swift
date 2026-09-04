import Foundation

/// Collapses `jamf-cli pro diff --output json` into what actually changed.
///
/// jamf-cli reports one entry per changed object and names the changed
/// *top-level field*, but dumps that field's entire value as a JSON string on
/// both sides. In practice a single leaf differs inside a multi-kilobyte blob
/// — measured against a real pair of backups, one entry carried one changed
/// key out of thirty-two. Rendering the raw entries is why the diff sheet
/// reads as a wall of JSON.
///
/// This does two reductions, both deterministic:
///
/// 1. **Leaf diff** — decode both sides and report only the leaf paths whose
///    values differ (`used_vpp_licenses: 667 → 660`).
/// 2. **Grouping** — objects whose change is byte-identical collapse into one
///    row ("47 objects, same change"), which is the common case when a fleet-
///    wide counter moves.
///
/// Deliberately not an AI summary: these are numbers an operator acts on, and
/// exactness matters more than prose. It also keeps the feature working on
/// every supported macOS with no model available.
enum BackupDiffModel {

    /// One leaf-level difference inside a changed field.
    struct Change: Equatable, Hashable, Sendable {
        let path: String
        let old: String?
        let new: String?
    }

    /// A set of objects whose change is identical, inside a group whose members
    /// changed the SAME FIELD but to different values.
    struct Variant: Equatable, Sendable {
        let names: [String]
        let changes: [Change]
    }

    /// One changed object as reported by jamf-cli, reduced to its leaf changes.
    struct Item: Equatable, Sendable {
        let resource: String
        let name: String
        let field: String
        let change: String
        let changes: [Change]
        /// True when the leaf diff hit `maxChangesPerItem` and was cut short.
        let truncated: Bool
        /// True only when a value was replaced wholesale AND is too long to read
        /// as a before/after pair. A short scalar swap is a perfectly legible
        /// change and must NOT be labelled opaque — saying "not structured JSON"
        /// there leaks an implementation detail and tells the reader nothing.
        let opaque: Bool
    }

    /// Objects sharing a resource, change verb, and identical leaf changes.
    struct Group: Identifiable, Equatable, Sendable {
        let resource: String
        let change: String
        /// Changes shared by every member. Empty when members changed the same
        /// field to DIFFERENT values — see `variants`.
        let changes: [Change]
        /// Populated only when members differ: one entry per distinct value.
        /// Lets six titles that each gained a different version read as one card
        /// with six lines instead of six near-identical cards.
        let variants: [Variant]
        let names: [String]
        let truncated: Bool
        let opaque: Bool
        /// Field paths every member touched, used as the card's subheading when
        /// the values differ.
        let fields: [String]
        var id: String {
            let fieldList = fields.joined(separator: ",")
            return "\(resource)|\(change)|\(names.first ?? "")|\(fieldList)|\(names.count)"
        }
    }

    /// Values longer than this are reported as an opaque replacement rather than
    /// printed as a before/after pair.
    static let opaqueValueLength = 120

    /// Cap on leaf changes reported per object. A genuinely large rewrite
    /// (a replaced script body) would otherwise reproduce the wall of JSON
    /// this type exists to avoid.
    static let maxChangesPerItem = 25

    // MARK: - Parsing

    private struct RawEntry: Decodable {
        let change: String?
        let field: String?
        let name: String?
        let resource: String?
        let oldValue: JSONAny?
        let newValue: JSONAny?

        enum CodingKeys: String, CodingKey {
            case change, field, name, resource
            case oldValue = "old_value"
            case newValue = "new_value"
        }
    }

    /// Minimal any-JSON box: jamf-cli sends `old_value`/`new_value` as a JSON
    /// *string* today, but a number or object would otherwise abort the decode
    /// of the whole diff.
    private struct JSONAny: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { text = nil }
            else if let s = try? c.decode(String.self) { text = s }
            else if let b = try? c.decode(Bool.self) { text = String(b) }
            else if let i = try? c.decode(Int.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(d) }
            else { text = nil }
        }
    }

    /// Decode a diff payload. Returns nil when the payload is not the expected
    /// JSON array, so the caller can fall back to showing raw output rather
    /// than claiming there were no changes.
    static func parse(_ data: Data) -> [Item]? {
        guard let entries = try? JSONDecoder().decode([RawEntry].self, from: data) else {
            return nil
        }
        return entries.map { entry in
            let old = entry.oldValue?.text
            let new = entry.newValue?.text
            let verb = entry.change ?? "modified"
            let (changes, truncated, opaque) = leafChanges(old: old, new: new, change: verb)
            return Item(
                resource: entry.resource ?? "unknown",
                name: entry.name ?? "(unnamed)",
                field: entry.field ?? "",
                change: entry.change ?? "modified",
                changes: changes,
                truncated: truncated,
                opaque: opaque
            )
        }
    }

    // MARK: - Leaf diffing

    /// Leaf-level differences between two JSON-encoded field values.
    /// Falls back to a single whole-value change when either side is not JSON.
    static func leafChanges(
        old: String?,
        new: String?,
        change: String = "modified"
    ) -> (changes: [Change], truncated: Bool, opaque: Bool) {
        // For an added or removed object there is no before/after to diff — the
        // object's existence IS the change, and its name (rendered by the caller)
        // is the useful detail. Reporting a "replacement" here produced rows that
        // stated nothing at all.
        guard change.lowercased() == "modified" else { return ([], false, false) }

        let oldObject = old.flatMap(jsonObject)
        let newObject = new.flatMap(jsonObject)
        guard let oldObject, let newObject else {
            // One or both sides aren't JSON — report the field as replaced
            // rather than inventing a structural diff.
            if old == new { return ([], false, false) }
            let longest = max(old?.count ?? 0, new?.count ?? 0)
            return ([Change(path: "", old: old, new: new)], false, longest > opaqueValueLength)
        }
        var collected: [Change] = []
        diff(oldObject, newObject, path: "", into: &collected)
        collected.sort { $0.path < $1.path }
        let truncated = collected.count > maxChangesPerItem
        return (Array(collected.prefix(maxChangesPerItem)), truncated, false)
    }

    private static func jsonObject(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Recursive two-sided diff.
    ///
    /// Arrays are compared as MULTISETS, never by index. Jamf's version lists
    /// are newest-first, so a single new release prepends an element and shifts
    /// every index below it — an index-wise diff reported one added version as
    /// four hundred modified ones. Comparing membership reports the one real
    /// change and says nothing about the rest.
    private static func diff(_ old: Any, _ new: Any, path: String, into out: inout [Change]) {
        switch (old, new) {
        case let (oldDict as [String: Any], newDict as [String: Any]):
            let keys = Set(oldDict.keys).union(newDict.keys).sorted()
            for key in keys {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                switch (oldDict[key], newDict[key]) {
                case let (.some(o), .some(n)):
                    diff(o, n, path: childPath, into: &out)
                case let (.some(o), .none):
                    let sensitive = isSensitiveLeafKey(childPath)
                    out.append(Change(
                        path: "\(childPath) removed",
                        old: sensitive ? redactedPlaceholder : label(o), new: nil
                    ))
                case let (.none, .some(n)):
                    let sensitive = isSensitiveLeafKey(childPath)
                    out.append(Change(
                        path: "\(childPath) added",
                        old: nil, new: sensitive ? redactedPlaceholder : label(n)
                    ))
                case (.none, .none):
                    continue
                }
            }

        case let (oldArray as [Any], newArray as [Any]):
            let oldCanon = oldArray.map(canonical)
            let newCanon = newArray.map(canonical)
            let added = multisetSubtract(newCanon, oldCanon)
            let removed = multisetSubtract(oldCanon, newCanon)
            // The array's own field name decides sensitivity — elements are
            // opaque blobs to `summarize`/`label`, which falls back to a raw
            // JSON snippet for a dict with no name/version/id, so a redacted
            // field must never reach `summarize` at all.
            let sensitive = isSensitiveLeafKey(path)
            let itemsPath = path.isEmpty ? "items" : path
            if !added.isEmpty {
                let value = sensitive
                    ? redactedPlaceholder : summarize(added, from: newArray, canon: newCanon)
                out.append(Change(path: "\(itemsPath) added", old: nil, new: value))
            }
            if !removed.isEmpty {
                let value = sensitive
                    ? redactedPlaceholder : summarize(removed, from: oldArray, canon: oldCanon)
                out.append(Change(path: "\(itemsPath) removed", old: value, new: nil))
            }

        default:
            let o = label(old)
            let n = label(new)
            if o != n {
                let renderedPath = path.isEmpty ? "(value)" : path
                if isSensitiveLeafKey(path) {
                    out.append(Change(
                        path: renderedPath, old: redactedPlaceholder, new: redactedPlaceholder
                    ))
                } else {
                    out.append(Change(path: renderedPath, old: o, new: n))
                }
            }
        }
    }

    /// Rendered in place of a secret's actual value — the change is still
    /// reported (a credential rotating is real signal), the value never is.
    private static let redactedPlaceholder = "<redacted>"

    /// A JSON key that carries a secret: the credential-shaped keys the
    /// diagnostic bundle already redacts, plus a suffix catch-all for
    /// compound names (`wifi_password`, `vpn-secret`, `auth_token`,
    /// `network_psk`) that would not otherwise be listed.
    private static let sensitiveKeySuffixes = ["password", "secret", "token", "psk"]

    /// A leaf whose normalised name ends in "key" but is a real, non-secret
    /// field — `product_key` is a genuine `update-status --scan-failures`
    /// column, and a bare `key` is too ambiguous to redact on its own.
    private static let keySuffixExclusions: Set<String> = ["key", "product_key"]

    /// True when the last dot-separated component of `path` looks like it
    /// holds a secret, matched case-insensitively with `-`/`_` normalised.
    /// A trailing "key" only counts as a compound, credential-shaped form
    /// (`api_key`, `encryption_key`) — never a bare `key` leaf, and never one
    /// of `keySuffixExclusions`.
    private static func isSensitiveLeafKey(_ path: String) -> Bool {
        guard let last = path.split(separator: ".").last else { return false }
        let normalized = last.lowercased().replacingOccurrences(of: "-", with: "_")
        if DiagnosticRedactor.sensitiveJSONKeys.contains(normalized) { return true }
        if sensitiveKeySuffixes.contains(where: { normalized.hasSuffix($0) }) { return true }
        guard !keySuffixExclusions.contains(normalized) else { return false }
        return normalized.hasSuffix("_key")
    }

    /// Elements of `lhs` not matched by `rhs`, preserving duplicates.
    private static func multisetSubtract(_ lhs: [String], _ rhs: [String]) -> [String] {
        var remaining: [String: Int] = [:]
        for item in rhs { remaining[item, default: 0] += 1 }
        var result: [String] = []
        for item in lhs {
            if let count = remaining[item], count > 0 {
                remaining[item] = count - 1
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// "4: 26.139.0720.0007, 26.134.0713.0007, 26.134.0713.0004 …"
    private static func summarize(
        _ picked: [String], from source: [Any], canon: [String]
    ) -> String {
        let labels = picked.prefix(3).map { needle -> String in
            guard let index = canon.firstIndex(of: needle) else { return needle }
            return label(source[index])
        }
        let ellipsis = picked.count > 3 ? " …" : ""
        return "\(picked.count): \(labels.joined(separator: ", "))\(ellipsis)"
    }

    /// Stable serialization used for multiset membership.
    private static func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(
                  withJSONObject: [value], options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    /// Short human label for a value: prefer an identifying scalar field when
    /// the value is an object, so an added array element reads as a version or
    /// a name rather than a wall of JSON.
    private static func label(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let dict = value as? [String: Any] {
            for key in ["software_version", "version", "name", "displayName", "id"] {
                if let found = dict[key], !(found is [String: Any]), !(found is [Any]) {
                    return label(found)
                }
            }
            return String(canonical(value).prefix(60))
        }
        if let array = value as? [Any] { return "\(array.count) item(s)" }
        if let number = value as? NSNumber {
            // Bools bridge to NSNumber; render them as true/false, not 1/0.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }

    // MARK: - Grouping

    /// Collapse objects into cards, in two tiers.
    ///
    /// Tier 1 merges objects whose leaf changes are byte-identical — the common
    /// case when a fleet-wide counter moves, so fifty apps read as one line.
    ///
    /// Tier 2 then merges the CARDS that touched the same field but landed on
    /// different values. Without it, six patch titles that each gained a
    /// different version rendered as six near-identical cards; now they are one
    /// card with six lines. Ordered by descending object count so the widest
    /// change reads first.
    static func group(_ items: [Item]) -> [Group] {
        let tier1 = groupByIdenticalChange(items)
        return mergeByField(tier1).sorted { $0.names.count > $1.names.count }
    }

    private static func groupByIdenticalChange(_ items: [Item]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let key = signature(item)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.compactMap { key -> Group? in
            guard let members = buckets[key], let first = members.first else { return nil }
            return Group(
                resource: first.resource,
                change: first.change,
                changes: first.changes,
                variants: [],
                names: members.map(\.name).sorted(),
                truncated: first.truncated,
                opaque: first.opaque,
                fields: first.changes.map(\.path)
            )
        }
    }

    /// Merge tier-1 groups that share (resource, change, field paths). A bucket
    /// of one is passed through untouched, so a group whose members really do
    /// share a value keeps rendering as "N objects, one change".
    private static func mergeByField(_ groups: [Group]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [Group]] = [:]
        for group in groups {
            let fieldList = group.fields.joined(separator: "\u{1E}")
            let key = "\(group.resource)\u{1D}\(group.change)\u{1D}\(fieldList)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(group)
        }
        return order.compactMap { key -> Group? in
            guard let bucket = buckets[key], let first = bucket.first else { return nil }
            guard bucket.count > 1 else { return first }
            return Group(
                resource: first.resource,
                change: first.change,
                changes: [],
                variants: bucket.map { Variant(names: $0.names, changes: $0.changes) },
                names: bucket.flatMap(\.names).sorted(),
                truncated: bucket.contains { $0.truncated },
                opaque: bucket.allSatisfy { $0.opaque },
                fields: first.fields
            )
        }
    }

    private static func signature(_ item: Item) -> String {
        let body = item.changes
            .map { "\($0.path)\u{1F}\($0.old ?? "")\u{1F}\($0.new ?? "")" }
            .joined(separator: "\u{1E}")
        return "\(item.resource)\u{1D}\(item.change)\u{1D}\(body)"
    }

    /// One-line headline for the whole diff, e.g. "10 changes across 2 resources".
    static func headline(_ items: [Item]) -> String {
        guard !items.isEmpty else { return "No differences" }
        let resources = Set(items.map(\.resource)).count
        let objects = items.count == 1 ? "1 object" : "\(items.count) objects"
        let scope = resources == 1 ? "1 resource" : "\(resources) resources"
        return "\(objects) changed across \(scope)"
    }

    /// Plain-text rendering of the collapsed diff, for the Copy button.
    static func plainText(_ groups: [Group]) -> String {
        groups.map { group in
            var lines = ["\(group.resource) · \(group.change) · \(group.names.count) object(s)"]
            for change in group.changes {
                lines.append("    \(describe(change))")
            }
            for variant in group.variants {
                let detail = variant.changes.map(describe).joined(separator: "; ")
                lines.append("    \(variant.names.joined(separator: ", ")): \(detail)")
            }
            if group.truncated { lines.append("    … more changes not shown") }
            if group.changes.isEmpty && group.variants.isEmpty {
                lines.append("    objects: \(group.names.joined(separator: ", "))")
            } else if group.variants.isEmpty {
                lines.append("    objects: \(group.names.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func describe(_ change: Change) -> String {
        let path = change.path.isEmpty ? "(value)" : change.path
        return "\(path): \(change.old ?? "—") → \(change.new ?? "—")"
    }
}
