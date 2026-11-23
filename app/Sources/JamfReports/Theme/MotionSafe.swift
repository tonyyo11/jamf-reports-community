import AppKit
import SwiftUI

// One place that turns an animation off under System Settings > Accessibility > Display >
// Reduce motion, so a screen never decides that for itself.

extension Animation {
    /// `animation`, or nil (no animation) when the person asked for reduced motion.
    nonisolated static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct MotionSafeAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(Animation.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `animation(_:value:)` that stays still under Reduce Motion.
    func motionSafeAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }
}

/// `withAnimation` that stays still under Reduce Motion. It reads the system setting when the
/// event fires, so it needs no environment value.
@MainActor
func withMotionSafeAnimation<Result>(
    _ animation: Animation? = .default, _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(
        Animation.resolved(
            animation, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
        body)
}
