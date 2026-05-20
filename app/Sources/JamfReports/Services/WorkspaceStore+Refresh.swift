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

    // MARK: Public trigger

    /// Fire a `.refresh`-tier refresh for `profile`, subject to coordinator
    /// backoff/coalescing.
    ///
    /// No-ops when demo mode is active or the profile slug is invalid.
    func triggerRefresh(for profileSlug: String) {
        guard !demoMode, profileSlug != "demo" else { return }
        guard ProfileService.isValid(profileSlug) else { return }
        coordinator.refreshIfStale(profile: profileSlug, tier: .refresh)
    }

    /// Fire a debounced `.refresh`-tier check after a profile switch.
    ///
    /// Routed through `RefreshCoordinator.observeProfileSwitch` (500 ms
    /// debounce) so cycling the sidebar chip through several profiles
    /// doesn't spawn a refresh per intermediate selection. No-ops in demo
    /// mode — `observeProfileSwitch` itself has no demo guard, so the
    /// check lives here at the WorkspaceStore boundary.
    func observeProfileSwitchRefresh(for profileSlug: String) {
        guard !demoMode, profileSlug != "demo" else { return }
        guard ProfileService.isValid(profileSlug) else { return }
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
             .securityPosture, .compliancePosture, .patch, .updates,
             .policyProfile, .extensionAttributes,
             .outreach, .protectDashboard, .mobileFleet:
            return true
        case .schedules, .runs, .config, .customize, .sources, .backups, .settings, .onboarding:
            return false
        }
    }
}
