import Foundation

// MARK: - HtmlReport+SecurityGaps
//
// The Macs behind the P0 figure, so the "Needs attention" line that counts them lands on a
// list of them. P0 is FileVault, SIP and Firewall at `fail` under the workspace's
// `security_policy`; a Mac is listed through the same verdict `SecurityFleetCounts` grades
// with, hardware rule included.

extension HtmlReport {

    /// The Macs whose device row fails FileVault, SIP or Firewall.
    struct P0Gaps: Equatable {
        struct Mac: Equatable {
            let name: String
            let serial: String
            let controls: [SecurityControl]
        }

        var macs: [Mac] = []
        /// Device rows in the security report; zero when the report carries none.
        var deviceRows = 0

        /// Gaps the rows name: one per Mac and failing control, as the P0 figure counts them.
        var listedGaps: Int { macs.reduce(0) { $0 + $1.controls.count } }

        static let controls: [SecurityControl] = [.fileVault, .sip, .firewall]

        static func build(
            items: [SecurityReportItem], hardware: [String: Bool],
            policy: SecurityControlPolicy
        ) -> P0Gaps {
            var gaps = P0Gaps()
            for case .device(let device) in items {
                gaps.deviceRows += 1
                let failing = controls.filter { control in
                    policy.verdict(
                        for: control, reading: device.reading(of: control, policy: policy),
                        hardwareEncrypted: HardwareEncryption.lookup(
                            serial: device.serial, name: device.name, in: hardware)) == .fail
                }
                guard !failing.isEmpty else { continue }
                gaps.macs.append(Mac(
                    name: device.name ?? "", serial: device.serial ?? "", controls: failing))
            }
            gaps.macs.sort {
                $0.controls.count != $1.controls.count
                    ? $0.controls.count > $1.controls.count
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return gaps
        }
    }

    private static func shortName(_ control: SecurityControl) -> String {
        control == .sip ? "SIP" : control.displayName
    }

    /// The table under the security tiles: Device, Serial and the controls that fail, with a
    /// line that says how much of `p0` (the figure on the tile) the rows account for. Empty
    /// when the report has no device rows.
    func buildP0GapTable(_ gaps: P0Gaps, p0: Int?) -> String {
        let f = HtmlSectionFormatters.self
        guard gaps.deviceRows > 0 else { return "" }
        func note(_ text: String) -> String {
            "\n<p class=\"block-note\">\(f.escapeHTML(text))</p>"
        }
        guard !gaps.macs.isEmpty else {
            guard let p0, p0 > 0 else { return "" }
            return note("The device rows name none of the \(f.plural(p0, "P0 gap")).")
        }
        let listed = gaps.listedGaps
        let macs = f.plural(gaps.macs.count, "Mac")
        let summary: String
        switch p0 {
        case .some(let total) where total > listed:
            summary = "\(listed) of \(f.plural(total, "P0 gap")) listed, on \(macs). "
                + "The device rows do not name the rest."
        case .some(let total) where total < listed:
            summary = "\(f.plural(listed, "P0 gap")) on \(macs) in the device rows; "
                + "the P0 figure is \(total)."
        default:
            summary = "All \(f.plural(listed, "P0 gap")) listed, on \(macs)."
        }
        let rows = gaps.macs.map {
            [$0.name, $0.serial, $0.controls.map(Self.shortName).joined(separator: ", ")]
        }
        return note(summary + " A Mac that fails two controls counts twice.")
            + "\n" + f.renderCappedTable(
                headers: ["Device", "Serial", "Failing controls"], rows: rows,
                maxRows: f.maxInterventionRows, expanded: expandAll)
    }
}
