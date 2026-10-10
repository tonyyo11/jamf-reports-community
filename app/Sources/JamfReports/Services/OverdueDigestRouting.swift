import Foundation

/// Which webhook receives which overdue schedules in the headless digest. One tick
/// evaluates every profile, so each profile's issues go to that profile's own
/// `notify:` webhook and a fleet-wide (`isMulti`) issue goes to every usable one.
/// Issues for a profile with no usable webhook are returned for logging, never
/// posted to another profile's channel.
enum OverdueDigestRouting {
    /// One profile's webhook and whether its once-per-day marker is already stamped.
    struct Target: Sendable {
        let profile: String
        let notify: NotifyConfig?
        let sentToday: Bool
    }

    struct Batch: Sendable {
        let profile: String
        let issues: [AutomationHealthIssue]
    }

    struct Routing: Sendable {
        let batches: [Batch]
        /// Overdue issues no usable webhook can carry.
        let undeliverable: [AutomationHealthIssue]
    }

    nonisolated static func route(
        overdue: [AutomationHealthIssue], targets: [Target]
    ) -> Routing {
        let usable = targets.filter { $0.notify?.isUsable == true }
        let usableProfiles = Set(usable.map(\.profile))
        let batches = usable.filter { !$0.sentToday }.compactMap { target -> Batch? in
            let issues = overdue.filter { $0.isMulti || $0.profile == target.profile }
            return issues.isEmpty ? nil : Batch(profile: target.profile, issues: issues)
        }
        let undeliverable = overdue.filter { issue in
            issue.isMulti ? usable.isEmpty : !usableProfiles.contains(issue.profile)
        }
        return Routing(batches: batches, undeliverable: undeliverable)
    }
}
