import Foundation

/// Which webhook receives which overdue schedules in the headless digest. One tick
/// evaluates every profile, so each profile's issues go to that profile's own
/// `notify:` webhook and a fleet-wide (`isMulti`) issue goes to every usable one.
/// Profiles that share one webhook URL get a single card. Issues for a looked-up
/// profile with no usable webhook are returned for logging, never posted to
/// another profile's channel.
enum OverdueDigestRouting {
    /// One profile with a usable webhook, its workspace, and whether its
    /// once-per-day marker is already stamped.
    struct Target: Sendable {
        let profile: String
        let notify: NotifyConfig
        let workspace: URL
        let sentToday: Bool
    }

    /// One card: the profiles that share its webhook and their combined issues.
    struct Batch: Sendable {
        let targets: [Target]
        /// The group's webhook; `minimal` detail wins if any member asks for it.
        let notify: NotifyConfig
        let issues: [AutomationHealthIssue]
        var profiles: [String] { targets.map(\.profile) }
    }

    struct Routing: Sendable {
        let batches: [Batch]
        /// Overdue issues of a looked-up profile that no usable webhook can carry.
        let undeliverable: [AutomationHealthIssue]
    }

    /// `runProfiles` are the profiles this run looked up; an issue owned by any
    /// other profile belongs to that profile's own run and is dropped silently.
    nonisolated static func route(
        overdue: [AutomationHealthIssue], targets: [Target], runProfiles: [String]
    ) -> Routing {
        let inScope = Set(runProfiles)
        let scoped = overdue.filter { $0.isMulti || inScope.contains($0.profile) }
        let targetProfiles = Set(targets.map(\.profile))

        var groups: [(url: String, targets: [Target])] = []
        for target in targets where !target.sentToday {
            let url = target.notify.resolvedURL
            if let index = groups.firstIndex(where: { $0.url == url }) {
                groups[index].targets.append(target)
            } else {
                groups.append((url, [target]))
            }
        }
        let batches = groups.compactMap { group -> Batch? in
            let members = Set(group.targets.map(\.profile))
            let issues = scoped.filter { $0.isMulti || members.contains($0.profile) }
            guard !issues.isEmpty else { return nil }
            var notify = group.targets[0].notify
            if group.targets.contains(where: { $0.notify.resolvedDetail == .minimal }) {
                notify.detail = NotifyConfig.Detail.minimal.rawValue
            }
            return Batch(targets: group.targets, notify: notify, issues: issues)
        }
        let undeliverable = scoped.filter { issue in
            issue.isMulti ? targets.isEmpty : !targetProfiles.contains(issue.profile)
        }
        return Routing(batches: batches, undeliverable: undeliverable)
    }
}
