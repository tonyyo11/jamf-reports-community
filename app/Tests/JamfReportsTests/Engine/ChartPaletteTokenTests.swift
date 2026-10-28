import AppKit
import SwiftUI
import XCTest
@testable import JamfReports

@MainActor
final class ChartPaletteTokenTests: XCTestCase {
    private func hex(_ color: Color) -> UInt32 {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    func testSupervisionDonutUsesTheValidatedPair() {
        typealias Role = MobileFleetService.SupervisionRole
        XCTAssertEqual(hex(MobileFleetView.supervisionColor(for: Role.supervised)), 0x3987E5)
        XCTAssertEqual(hex(MobileFleetView.supervisionColor(for: Role.unsupervised)), 0xD95926)
        XCTAssertEqual(hex(MobileFleetView.supervisionColor(for: Role.unmanaged)), 0x8E8E93)
    }

    func testSeverityLowUsesTheBrightTeal() {
        XCTAssertEqual(hex(Theme.Severity.low.inApp), 0x4FAAAA)
    }
}
