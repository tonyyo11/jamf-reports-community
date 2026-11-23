import Foundation

/// A finite number as a whole Int; nil for NaN, infinity and anything outside Int's range,
/// which a peer-written snapshot can carry and `Int(_:)` would trap on.
func wholeInt(_ value: Double) -> Int? {
    value.isFinite ? Int(exactly: value.rounded()) : nil
}

/// A JSON number or numeric string as an Int; nil for anything else. The one reader for the
/// report engine's `[String: Any]` snapshots.
func asInt(_ value: Any?) -> Int? {
    switch value {
    case let n as Int: return n
    case let d as Double: return Int(exactly: d.rounded())
    case let s as String: return Int(s)
    case let n as NSNumber: return n.intValue
    default: return nil
    }
}
