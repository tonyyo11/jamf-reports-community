import XCTest
@testable import JamfReports

/// A tile that opens Computers opens it on the Macs its number counts (QoL wave, fleet screens).
@MainActor
final class QolFleetDrillDownTests: XCTestCase {
    private let policy = SecurityControlPolicy.default
    private let rule = StaleRule(days: 30)

    /// Macs whose four controls all read on or off, so the tile's share and the filter agree.
    private func measuredFleet() -> [DeviceInventoryRecord] {
        (0..<40).map { i in
            var record = DeviceInventoryRecord.empty(id: "serial:Q\(i)", source: "computers.json")
            record.name = "Mac-\(i)"
            record.serial = "Q\(i)"
            record.fileVault = i % 7 == 0 ? "Not Encrypted" : "Encrypted"
            record.sip = i % 11 == 0 ? "Disabled" : "Enabled"
            record.firewall = i % 5 == 0 ? "Disabled" : "Enabled"
            record.gatekeeper = i % 13 == 0 ? "Disabled" : "Enabled"
            return record
        }
    }

    private func rows(
        _ devices: [DeviceInventoryRecord], _ filter: DevicesView.DeviceFilter
    ) -> [DeviceSortRow] {
        DevicesView.buildRows(
            devices: devices, query: "", osFilter: nil, filter: filter,
            sortOrder: [KeyPathComparator(\DeviceSortRow.device.displayName)], policy: policy,
            staleRule: rule, contactGapDays: 14, searchableText: { $0.searchableText },
            risk: { RiskScoringService.risk(for: $0, policy: self.policy, staleRule: self.rule) })
    }

    /// The Security Posture tile shows the share with the control on; its destination lists the
    /// rest, so on plus rows is the whole fleet.
    func testEachControlFilterListsExactlyTheMacsTheTileCountsAsNotOn() {
        let devices = measuredFleet()
        for control in SecurityControl.allCases {
            let on = devices.filter { device in
                let raw = switch control {
                case .fileVault: device.fileVault
                case .sip: device.sip
                case .firewall: device.firewall
                case .gatekeeper: device.gatekeeper
                }
                return policy.reading(raw, for: control) == true
            }.count
            let counts = SecurityFleetCounts.build(
                totalDevices: devices.count, onCounts: [control: on], devices: [],
                hardware: [:], policy: policy)
            let shown = rows(devices, .off(control)).count
            let tile = counts.controls[control]
            XCTAssertEqual(shown, (tile?.fail ?? 0) + (tile?.warning ?? 0), "\(control)")
            XCTAssertEqual(shown, devices.count - on, "\(control)")
            XCTAssertGreaterThan(shown, 0)
        }
    }

    func testAValueJamfDidNotCollectIsNotListedAsOff() {
        var record = DeviceInventoryRecord.empty(id: "serial:N", source: "computers.json")
        record.fileVault = "Not Collected"
        record.sip = ""
        for control in SecurityControl.allCases {
            XCTAssertTrue(rows([record], .off(control)).isEmpty, "\(control)")
        }
    }

    func testControlFiltersAreChipsNotSegmentsAndRoundTrip() {
        let controls = SecurityControl.allCases.map(DevicesView.DeviceFilter.off)
        XCTAssertEqual(controls.compactMap(\.offControl), SecurityControl.allCases)
        XCTAssertTrue(Set(controls).isDisjoint(with: DevicesView.DeviceFilter.segments))
        for filter in controls {
            XCTAssertEqual(DevicesView.DeviceFilter(deepLink: filter.rawValue), filter)
            XCTAssertEqual(filter.navigationUserInfo()["tab"], Tab.devices.rawValue)
        }
    }

    func testMetricDrillDownButtonsNameTheirFilter() {
        let fileVault = OverviewView.relatedDestinations(for: .fileVault)
        XCTAssertEqual(fileVault.map(\.filter), [.fileVaultOff])
        XCTAssertEqual(fileVault.first?.title, "Computers: FileVault off")
        XCTAssertEqual(OverviewView.relatedDestinations(for: .stale).first?.filter, .stale)
        XCTAssertEqual(OverviewView.relatedDestinations(for: .patch).first?.filter, .patch)
        XCTAssertEqual(OverviewView.relatedDestinations(for: .osCurrent).first?.title, "Computers")
        for metric in TrendSeries.Metric.allCases + TrendSeries.Metric.mobileMetrics {
            for destination in OverviewView.relatedDestinations(for: metric) {
                XCTAssertEqual(destination.userInfo["tab"], destination.tab.rawValue)
                if destination.filter == nil {
                    XCTAssertNil(destination.userInfo[DevicesView.DeviceFilter.userInfoKey])
                }
            }
        }
    }
}
