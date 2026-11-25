import Foundation

/// Allow-list reductions for the deployment-health kinds: only the keys a reader uses reach
/// disk, each only with the JSON type the command prints.
enum DeploymentSourceReduction {

    private enum Field { case string, bool, wholeNumber }

    /// Kept keys per kind; a nested object is a dotted path.
    private static let keptFields: [String: [String: Field]] = [
        "app-installers-deployments": [
            "id": .string, "name": .string, "enabled": .bool, "updateBehavior": .string,
            "app.latestVersion": .string, "app.deployedVersion": .string,
            "computerStatuses.installed": .wholeNumber,
            "computerStatuses.available": .wholeNumber,
            "computerStatuses.inProgress": .wholeNumber,
            "computerStatuses.failed": .wholeNumber,
            "computerStatuses.unqualified": .wholeNumber,
        ],
        "patch-policies": [
            "id": .string, "policyName": .string, "policyEnabled": .bool,
            "policyTargetVersion": .string, "softwareTitle": .string,
            "softwareTitleConfigurationId": .string,
            "completed": .wholeNumber, "deferred": .wholeNumber,
            "failed": .wholeNumber, "pending": .wholeNumber,
        ],
    ]

    /// The saved list for `kind`, or nil when `payload` is not a list of objects, so nothing
    /// is saved on a guess. jamf-cli's `null` for an empty list saves as `[]`.
    static func reduce(kind: String, payload: Data) -> Data? {
        guard let fields = keptFields[kind],
              let object = try? JSONSerialization.jsonObject(
                  with: payload, options: [.fragmentsAllowed]),
              let rows = ReportEngine.listRows(of: object) else { return nil }
        var kept: [[String: Any]] = []
        for row in rows {
            guard let row = row as? [String: Any] else { return nil }
            kept.append(reduced(row, fields: fields))
        }
        return try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
    }

    private static func reduced(_ row: [String: Any], fields: [String: Field]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (path, field) in fields {
            let parts = path.split(separator: ".").map(String.init)
            var node: Any? = row
            for part in parts { node = (node as? [String: Any])?[part] }
            guard let value = node.flatMap({ typed($0, as: field) }) else { continue }
            if parts.count == 1 {
                out[parts[0]] = value
            } else {
                var nested = out[parts[0]] as? [String: Any] ?? [:]
                nested[parts[1]] = value
                out[parts[0]] = nested
            }
        }
        return out
    }

    /// `value` when it is the JSON type `field` asks for. JSONSerialization hands booleans and
    /// numbers back as `NSNumber`, so a boolean is told apart by its CFBoolean type.
    private static func typed(_ value: Any, as field: Field) -> Any? {
        switch field {
        case .string:
            return value as? String
        case .bool:
            guard let number = value as? NSNumber, isBoolean(number) else { return nil }
            return number.boolValue
        case .wholeNumber:
            guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
            let double = number.doubleValue
            // A status count is never negative; one that is reads as not reported.
            guard double.isFinite, double == double.rounded(), double >= 0,
                  double <= Double(Int.max / 2) else { return nil }
            return Int(double)
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
