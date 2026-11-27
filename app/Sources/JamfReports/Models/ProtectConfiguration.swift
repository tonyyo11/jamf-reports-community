import Foundation

/// How many Protect plans have no USB control set and no prevent list. Neutral counts: whether a
/// plan needs either is the organization's call.
struct ProtectConfiguration: Sendable, Equatable {
    /// Nil when no plan's value could be read.
    let noUSBControl: MobileSummary.Share?
    /// Nil when jamf-cli did not report prevent lists (before 1.37 no plan row carries the key).
    let noPreventList: MobileSummary.Share?

    /// Nil with no plans. A plan whose value is not text is left out of that count.
    static func counts(plans: [ProtectPlanRow]) -> ProtectConfiguration? {
        guard !plans.isEmpty else { return nil }
        let reportsPreventList = plans.contains { $0.preventListSets != .absent }
        return ProtectConfiguration(
            noUSBControl: share(plans.map(\.usbControlSet)),
            noPreventList: reportsPreventList ? share(plans.map(\.preventListSets)) : nil)
    }

    private static func share(_ references: [PlanReference]) -> MobileSummary.Share? {
        var met = 0, of = 0
        for reference in references {
            switch reference {
            case .absent: met += 1; of += 1
            case .names(let names):
                of += 1
                if names.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { met += 1 }
            case .unreadable: break
            }
        }
        return of > 0 ? .init(met: met, of: of) : nil
    }

    /// Report rows (English): label and "N of M" or why it is not reported.
    var reportRows: [(String, String)] {
        [("Plans with no USB control set",
          noUSBControl.map { "\($0.met) of \($0.of)" } ?? Self.unreadableNote),
         ("Plans with no prevent list",
          noPreventList.map { "\($0.met) of \($0.of)" } ?? Self.notReportedNote)]
    }

    static let notReportedNote = "Not reported by this jamf-cli (needs 1.37 or later)"
    static let unreadableNote = "Could not be read"
}
