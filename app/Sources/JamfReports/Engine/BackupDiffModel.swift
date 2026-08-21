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

    /// One changed object as reported by jamf-cli, reduced to its leaf changes.
    struct Item: Equatable, Sendable {
        let resource: String
        let name: String
        let field: String
        let change: String
        let changes: [Change]
        /// True when the leaf diff hit `maxChangesPerItem` and was cut short.
        let truncated: Bool
        /// True when a side could not be parsed as JSON, so `changes` is a
        /// whole-value replacement rather than a leaf diff.
        let opaque: Bool
    }

    /// Objects sharing a resource, change verb, and identical leaf changes.
    struct Group: Identifiable, Equatable, Sendable {
        let resource: String
        let change: String
        let changes: [Change]
        let names: [String]
        let truncated: Bool
        let opaque: Bool
        var id: String { "\(resource)|\(change)|\(names.first ?? "")|\(changes.count)|\(changes.first?.path ?? "")" }
    }

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
            let (changes, truncated, opaque) = leafChanges(old: old, new: new)
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
        new: String?
    ) -> (changes: [Change], truncated: Bool, opaque: Bool) {
        let oldObject = old.flatMap(jsonObject)
        let newObject = new.flatMap(jsonObject)
        guard let oldObject, let newObject else {
            // One or both sides aren't JSON — report the field as replaced
            // rather than inventing a structural diff.
            if old == new { return ([], false, true) }
            return ([Change(path: "", old: old, new: new)], false, true)
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
                    out.append(Change(path: "\(childPath) removed", old: label(o), new: nil))
                case let (.none, .some(n)):
                    out.append(Change(path: "\(childPath) added", old: nil, new: label(n)))
                case (.none, .none):
                    continue
                }
            }

        case let (oldArray as [Any], newArray as [Any]):
            let oldCanon = oldArray.map(canonical)
            let newCanon = newArray.map(canonical)
            let added = multisetSubtract(newCanon, oldCanon)
            let removed = multisetSubtract(oldCanon, newCanon)
            if !added.isEmpty {
                out.append(Change(
                    path: "\(path.isEmpty ? "items" : path) added",
                    old: nil,
                    new: summarize(added, from: newArray, canon: newCanon)
                ))
            }
            if !removed.isEmpty {
                out.append(Change(
                    path: "\(path.isEmpty ? "items" : path) removed",
                    old: summarize(removed, from: oldArray, canon: oldCanon),
                    new: nil
                ))
            }

        default:
            let o = label(old)
            let n = label(new)
            if o != n {
                out.append(Change(path: path.isEmpty ? "(value)" : path, old: o, new: n))
            }
        }
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
    private static func summarize(_ picked: [String], from source: [Any], canon: [String]) -> String {
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
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return String(describing: value)
    }

    // MARK: - Grouping

    /// Collapse objects whose leaf changes are identical. Ordered by descending
    /// group size so the widest change reads first.
    static func group(_ items: [Item]) -> [Group] {
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
                names: members.map(\.name).sorted(),
                truncated: first.truncated,
                opaque: first.opaque
            )
        }
        .sorted { $0.names.count > $1.names.count }
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
                let path = change.path.isEmpty ? "(value)" : change.path
                lines.append("    \(path): \(change.old ?? "—") → \(change.new ?? "—")")
            }
            if group.truncated { lines.append("    … more changes not shown") }
            lines.append("    objects: \(group.names.joined(separator: ", "))")
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
