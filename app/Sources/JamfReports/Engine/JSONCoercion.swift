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

/// A count from a snapshot: a JSON number (never a boolean) that is whole and not negative.
/// Anything else is nil, so a peer-written -3, 2.7 or 1e30 is unreadable, not a count.
func wholeCount(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let double = number.doubleValue
    guard double == double.rounded(), let whole = wholeInt(double), whole >= 0 else { return nil }
    return whole
}
