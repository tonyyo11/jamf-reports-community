import Foundation

/// App-facing availability state for the on-device intelligence layer.
/// Collapses three separate checks into one renderable value: the compile-time
/// gate (`compiler(>=6.4)`), the runtime `@available` check (macOS 27), and —
/// once inside the gate — `SystemLanguageModel`'s own `availability` enum.
///
/// This type and its `message`/`isReady` are UNGATED: they must compile and be
/// referenced on every OS version and toolchain, because the UI renders
/// `.requiresMacOS27` as a normal state on a macOS 26 host and the stub path
/// depends on the enum existing everywhere.
enum ModelAvailability: Sendable, Equatable {
    /// The model is available and ready to generate insights.
    case available
    /// This host/toolchain predates Foundation Models support (macOS < 27, or
    /// a Swift toolchain older than 6.4).
    case requiresMacOS27
    /// The AI block is present but `enabled: false`.
    case disabledByConfig
    /// The device hardware is not eligible for Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is not turned on in System Settings.
    case appleIntelligenceNotEnabled
    /// The model is still downloading / warming up.
    case modelNotReady
    /// An availability reason the app doesn't have a specific case for.
    case unknown(String)

    /// True only when insights can actually be generated right now.
    var isReady: Bool {
        if case .available = self { return true }
        return false
    }

    /// Short, user-facing explanation for the current state.
    var message: String {
        switch self {
        case .available:
            return "On-device intelligence is ready."
        case .requiresMacOS27:
            return "Requires macOS 27."
        case .disabledByConfig:
            return "AI insights are off. Enable them in this profile's config.yaml (ai: enabled)."
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use insights."
        case .modelNotReady:
            return "The on-device model is still preparing. Try again shortly."
        case .unknown(let detail):
            return "Intelligence is unavailable: \(detail)"
        }
    }
}

#if canImport(FoundationModels) && compiler(>=6.4)   // 6.4 ships with Xcode 27 only
import FoundationModels

@available(macOS 27, *)
extension ModelAvailability {
    /// Maps the live `SystemLanguageModel` availability into the plain enum.
    /// Only compiled under Xcode 27; the ungated `current(for:)` below routes
    /// here at runtime on macOS 27.
    ///
    /// One model, so no per-tier branch: `.external` is unbuilt and stubbed by
    /// the factory, and harmlessly reports on-device readiness here.
    static func resolve(for config: AIConfig) -> ModelAvailability {
        map(SystemLanguageModel.default.availability)
    }

    /// Map `SystemLanguageModel.Availability` into the portable enum.
    static func map(_ availability: SystemLanguageModel.Availability) -> ModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown("\(reason)")
            }
        @unknown default:
            return .unknown("\(availability)")
        }
    }
}
#endif

extension ModelAvailability {
    /// Whether this host/toolchain combination can EVER show intelligence
    /// features — independent of any `AIConfig`, and synchronous (no model
    /// construction, no I/O). False exactly when `current(for:)` would
    /// collapse to `.requiresMacOS27` regardless of config: macOS < 27, or a
    /// toolchain older than Swift 6.4. Views use this to decide whether an AI
    /// surface belongs in the layout at all, without waiting on a config load
    /// first — there's no flash of "unsupported" chrome before an async
    /// resolve completes, because there's nothing to await.
    static var platformSupported: Bool {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, *) { return true }
        #endif
        return false
    }

    /// Resolves the availability for a config across every toolchain. On the
    /// default toolchain (Swift < 6.4) or a host below macOS 27 the FoundationModels
    /// types don't exist, so this always returns `.requiresMacOS27`. Under Xcode 27
    /// on macOS 27 hardware it maps the live model availability via `resolve(for:)`.
    static func current(for config: AIConfig) -> ModelAvailability {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, *) {
            return resolve(for: config)
        }
        #endif
        return .requiresMacOS27
    }
}
