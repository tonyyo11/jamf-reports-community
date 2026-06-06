import Foundation

// MARK: - Managed automation wiring

extension WorkspaceStore {

    /// Reconcile the managed-automation LaunchAgents from the saved
    /// `AutomationPolicy`. Called once from the root view's `.task`.
    ///
    /// No-ops in demo mode. Safe to call when automation is unmanaged: the
    /// reconcile plan is then empty for a user who never opted in, and tears
    /// down any leftover managed agents if the operator turned the policy off.
    func reconcileManagedAutomation() async {
        guard !demoMode else { return }
        await ManagedAutomation.reconcile(policy: AutomationPolicy.current())
    }
}
