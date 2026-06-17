import SwiftUI

// Liquid Glass seam. The single place the app decides "real glass vs. Material
// fallback", so no other view carries an availability check.
//
// TOOLCHAIN: the glass branch references `glassEffect`/`Glass`, which exist only
// in the macOS 26 SDK (Xcode 26 / Swift 6.2). `#available` gates runtime, not
// symbol existence — so the glass code is also wrapped in `#if compiler(>=6.2)`
// to keep this file compiling on the Xcode 16.4 floor (Swift 6.1, macOS 15 SDK),
// where those symbols are absent. On the older toolchain only the Material
// fallback is compiled; on 26+ both paths compile and `#available` picks glass
// at runtime. Deployment target stays .macOS(.v14).

// MARK: - Public API

extension View {
    /// Liquid Glass on macOS 26+, Material (or a solid surface under Reduce
    /// Transparency) everywhere else. The one seam every glass surface routes
    /// through. Apply after layout/appearance modifiers.
    ///
    /// - Parameters:
    ///   - shape: surface outline; keep related elements on the same shape.
    ///   - tint: optional brand tint (used sparingly — e.g. the Schedules
    ///     next-up callout). Nil keeps neutral glass.
    ///   - interactive: set only on elements that respond to pointer/touch.
    ///   - border: hairline color for the non-glass fallback overlay.
    func appGlass(
        in shape: GlassShape = .rect(cornerRadius: Theme.Metrics.largeCardRadius),
        tint: Color? = nil,
        interactive: Bool = false,
        border: Color = Theme.Colors.hairlineStrong
    ) -> some View {
        modifier(AppGlass(shape: shape, tint: tint, interactive: interactive, border: border))
    }
}

/// Shared shape vocabulary for glass surfaces. Using the same case across
/// related elements keeps them visually cohesive (and lets a future
/// `GlassEffectContainer` blend them).
enum GlassShape {
    case rect(cornerRadius: CGFloat)
    case capsule
    case circle

    var anyShape: AnyShape {
        switch self {
        case let .rect(cornerRadius):
            AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .capsule:
            AnyShape(Capsule(style: .continuous))
        case .circle:
            AnyShape(Circle())
        }
    }

    /// Inset hairline overlay for the non-glass fallback. Uses `.strokeBorder`
    /// (not `.stroke`) on the concrete InsettableShape so the macOS 14/15
    /// rendering is identical to the pre-seam GlassPane/StatusBar — AnyShape is
    /// not InsettableShape, so the concrete type is required here.
    @ViewBuilder
    func strokeOverlay(_ color: Color, lineWidth: CGFloat) -> some View {
        switch self {
        case let .rect(cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: lineWidth)
        case .capsule:
            Capsule(style: .continuous).strokeBorder(color, lineWidth: lineWidth)
        case .circle:
            Circle().strokeBorder(color, lineWidth: lineWidth)
        }
    }
}

// MARK: - Implementation

private struct AppGlass: ViewModifier {
    let shape: GlassShape
    let tint: Color?
    let interactive: Bool
    let border: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        // Reduce Transparency wins even on 26: Apple's guidance is to drop glass
        // for a solid surface when the user asks for it.
        #if compiler(>=6.2)
        if #available(macOS 26, *), !reduceTransparency {
            content.modifier(NativeGlass(shape: shape, tint: tint, interactive: interactive))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background(
                reduceTransparency
                    ? AnyShapeStyle(Theme.Colors.winBG2)
                    : AnyShapeStyle(.regularMaterial),
                in: shape.anyShape
            )
            .overlay(
                shape.strokeOverlay(
                    reduceTransparency ? Theme.Colors.hairlineStrong : border,
                    lineWidth: 0.5
                )
            )
    }
}

#if compiler(>=6.2)
@available(macOS 26, *)
private struct NativeGlass: ViewModifier {
    let shape: GlassShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return content.glassEffect(glass, in: shape.anyShape)
    }
}
#endif
