import AppKit
import Foundation

// MARK: - RefreshCoordinator wiring

/// Owns the `RefreshCoordinator` singleton and all call sites that fire into it.
///
/// Keeps `WorkspaceStore.swift` minimally edited: the store exposes `coordinator`
/// for the sidebar UI and calls `triggerRefresh()` from its two mutation points
/// (profile switch and app-foreground notification).
extension WorkspaceStore {

    // MARK: Coordinator accessor

    /// Shared coordinator for the process lifetime.
    ///
    /// Stored as an associated-object on self to avoid adding a stored property to
    /// the `@Observable` class (which would require modifying the primary file's
    /// observation tracking). The coordinator is created once and reused.
    var coordinator: RefreshCoordinator {
        if let existing = objc_getAssociatedObject(self, &WorkspaceStore.coordinatorKey)
            as? RefreshCoordinator
        {
            return existing
        }
        let new = RefreshCoordinator(bridge: CLIBridge())
        objc_setAssociatedObject(
            self,
            &WorkspaceStore.coordinatorKey,
            new,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return new
    }

    private static var coordinatorKey: UInt8 = 0
    private static var foregroundObserverKey: UInt8 = 0

    // MARK: Refresh gate

    /// Whether a background refresh may run for `profileSlug`.
    ///
    /// False in demo mode — the demo workspace has no real Jamf data to
    /// fetch — and false for slugs that fail the profile-name validator.
    /// `RefreshCoordinator` has no demo concept, so this gate lives at the
    /// `WorkspaceStore` boundary and both refresh entry points consult it.
    ///
    /// (There is deliberately no `profileSlug != "demo"` check: the demo
    /// profile is `DemoData.org.profile` ("meridian-prod"), not "demo", so
    /// such a literal never matched. `demoMode` is the real gate.)
    func canRefresh(profileSlug: String) -> Bool {
        !demoMode && ProfileService.isValid(profileSlug)
    }

    // MARK: Public trigger

    /// Fire a `.refresh`-tier refresh for `profile`, subject to coordinator
    /// backoff/coalescing. No-ops when `canRefresh` is false.
    func triggerRefresh(for profileSlug: String) {
        guard canRefresh(profileSlug: profileSlug) else { return }
        coordinator.refreshIfStale(profile: profileSlug, tier: .refresh)
    }

    /// Fire a debounced `.refresh`-tier check after a profile switch.
    ///
    /// Routed through `RefreshCoordinator.observeProfileSwitch` (500 ms
    /// debounce) so cycling the sidebar chip through several profiles
    /// doesn't spawn a refresh per intermediate selection. No-ops when
    /// `canRefresh` is false.
    func observeProfileSwitchRefresh(for profileSlug: String) {
        guard canRefresh(profileSlug: profileSlug) else { return }
        coordinator.observeProfileSwitch(profileSlug)
    }

    // MARK: App-foreground registration

    /// Register for `NSApplication.willBecomeActiveNotification` so the
    /// active profile's Refresh-tier data is re-checked when the app comes
    /// back to the foreground.
    ///
    /// Called once from the root view's `.task`. Genuinely idempotent: the
    /// observer token is stashed as an associated object and a second call
    /// returns early, so a shell re-mount cannot stack duplicate observers.
    func registerForegroundRefresh() {
        if objc_getAssociatedObject(self, &WorkspaceStore.foregroundObserverKey) != nil {
            return
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.triggerRefresh(for: self.profile)
            }
        }
        objc_setAssociatedObject(
            self,
            &WorkspaceStore.foregroundObserverKey,
            token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

// MARK: - Data-driven tab set

extension Tab {
    /// True when switching to this tab should trigger a `.refresh`-tier data refresh.
    ///
    /// Configuration and log surfaces are excluded: refreshing when the user
    /// navigates to Schedules or Runs would be noisy and misleading.
    var isDataDriven: Bool {
        switch self {
        case .overview, .fleet, .devices, .deviceLookup, .trends, .audit, .reports,
             .securityPosture, .compliancePosture, .complianceBenchmarks,
             .patch, .updates, .ddmBlueprints,
             .policyProfile, .extensionAttributes,
             .outreach, .protectDashboard, .mobileFleet, .groupInventory:
            return true
        case .schedules, .runs, .config, .customize, .sources, .backups, .settings, .onboarding:
            return false
        }
    }
}
