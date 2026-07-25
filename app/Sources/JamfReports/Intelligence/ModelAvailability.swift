import Foundation

/// App-facing availability state for the on-device / Private Cloud Compute
/// intelligence layer. Collapses three separate checks into one renderable
/// value: the compile-time gate (`compiler(>=6.4)`), the runtime `@available`
/// check (macOS 27), and — once inside the gate — the concrete model's own
/// `availability` enum (`SystemLanguageModel` / `PrivateCloudComputeLanguageModel`).
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
    /// Private Cloud Compute is selected but the system isn't ready for it.
    case pccSystemNotReady
    /// Private Cloud Compute needs the `private-cloud-compute` entitlement, which
    /// this build doesn't carry — constructing the PCC model without it traps, so
    /// the app reports this state instead of ever creating the model.
    case pccEntitlementMissing
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
        case .pccSystemNotReady:
            return "Private Cloud Compute isn't ready on this system."
        case .pccEntitlementMissing:
            return "Private Cloud Compute requires an Apple-granted entitlement this build doesn't "
                + "include. Set tier: on_device in this profile's config.yaml to use on-device insights."
        case .unknown(let detail):
            return "Intelligence is unavailable: \(detail)"
        }
    }
}

#if canImport(FoundationModels) && compiler(>=6.4)   // 6.4 ships with Xcode 27 only
import FoundationModels

@available(macOS 27, *)
extension ModelAvailability {
    /// Maps the live `SystemLanguageModel` / `PrivateCloudComputeLanguageModel`
    /// availability into the plain enum. Only compiled under Xcode 27; the
    /// ungated `current(for:)` below routes here at runtime on macOS 27.
    ///
    /// Probes the config's RESOLVED generator kind (`GeneratorKind.select`), not
    /// the raw tier — so a `lock_on_device` config resolves to `.onDevice` and
    /// `PrivateCloudComputeLanguageModel` is never constructed under a lock, even
    /// for an availability read (defense in depth for the lock guarantee).
    static func resolve(for config: AIConfig) -> ModelAvailability {
        switch GeneratorKind.select(config: config) {
        case .privateCloudCompute:
            // Constructing PrivateCloudComputeLanguageModel without the entitlement
            // is a fatalError — probe the entitlement BEFORE creating the model.
            guard PCCEntitlement.isPresent else { return .pccEntitlementMissing }
            let pcc = PrivateCloudComputeLanguageModel()
            return mapPCC(pcc.availability)

        case .onDevice, .external:
            // Locked configs resolve to `.onDevice` here, so the PCC type is
            // never constructed under a lock. `.external` (not UI-selectable and
            // stubbed by the factory) harmlessly reports on-device readiness.
            return map(SystemLanguageModel.default.availability)
        }
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

    /// Map `PrivateCloudComputeLanguageModel.Availability` (two unavailable
    /// reasons: `.deviceNotEligible` and `.systemNotReady`).
    static func mapPCC(_ availability: PrivateCloudComputeLanguageModel.Availability) -> ModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .systemNotReady: return .pccSystemNotReady
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
    /// on macOS 27 hardware it maps the live model availability via `resolve(for:)`,
    /// probing the config's resolved generator kind (honoring `lock_on_device`).
    static func current(for config: AIConfig) -> ModelAvailability {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, *) {
            return resolve(for: config)
        }
        #endif
        return .requiresMacOS27
    }
}
