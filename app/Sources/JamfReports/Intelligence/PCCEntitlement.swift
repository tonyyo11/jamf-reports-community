import Foundation
import Security

/// Whether the running process carries the `com.apple.developer.private-cloud-compute`
/// entitlement.
///
/// `PrivateCloudComputeLanguageModel` REQUIRES this entitlement: constructing that
/// type without it is a hard `fatalError` inside FoundationModels
/// (`PrivateCloudComputeLanguageModel.swift:1054`), NOT a catchable throw. So every
/// PCC construction site — the generator AND the availability probe — must check
/// this first and treat PCC as unavailable when it's absent, rather than crash.
///
/// A Developer ID build without the (Apple-granted, provisioned) entitlement returns
/// `false`. Enabling real PCC requires adding the entitlement to
/// `JamfReports.entitlements` plus a provisioning profile that grants it — a separate,
/// Apple-gated step (App Store distribution program; out of reach for a Developer
/// ID-distributed app). Ungated so it compiles on every toolchain and is testable.
///
/// `isPresent` is computed once and cached — a process's entitlements can't change
/// during its lifetime, and the UI (SettingsView) reads it on every body evaluation
/// of the AI Insights panel.
enum PCCEntitlement {
    static let key = "com.apple.developer.private-cloud-compute"

    static let isPresent: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool) == true
    }()
}
