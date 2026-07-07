import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import JamfReports

/// Opt-in visual-inspection harness — NOT a pixel-assertion snapshot test.
///
/// Renders a curated set of `Theme` components to PNG files on disk so a
/// reviewer (human or an image-capable agent) can eyeball them without
/// building/launching the full app. Every test is a no-op unless
/// `JRC_RENDER_PREVIEWS=1` is set, so this never affects CI or a normal
/// `swift test` run.
///
/// Output directory: `JRC_PREVIEW_OUT` env var, else
/// `NSTemporaryDirectory()/jrc-previews`. Each render prints its full path so
/// the invoking process can collect the files.
@MainActor
final class PreviewSnapshotTests: XCTestCase {

    // MARK: - Harness

    private static var outputDir: URL {
        let base = ProcessInfo.processInfo.environment["JRC_PREVIEW_OUT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("jrc-previews")
        return URL(fileURLWithPath: base, isDirectory: true)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_RENDER_PREVIEWS"] == "1",
            "preview rendering is opt-in"
        )
        try FileManager.default.createDirectory(
            at: Self.outputDir, withIntermediateDirectories: true
        )
    }

    /// Wraps `view` in the same fixed-width dark-mode container the app's
    /// screens render inside (`Theme.Colors.winBG` background, 16pt padding),
    /// renders it via `ImageRenderer` at 2x scale, and writes a PNG named
    /// `<name>.png` under `Self.outputDir`. Prints the full path on success.
    private func render(_ view: some View, name: String, width: CGFloat) throws {
        let framed = view
            .frame(width: width)
            .padding(16)
            .background(Theme.Colors.winBG)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage else {
            XCTFail("\(name): ImageRenderer produced no NSImage")
            return
        }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("\(name): could not obtain CGImage from rendered NSImage")
            return
        }
        XCTAssertNotNil(cgImage, "\(name): rendered image is nil")

        let url = Self.outputDir.appendingPathComponent("\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            XCTFail("\(name): could not create PNG destination at \(url.path)")
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            XCTFail("\(name): CGImageDestinationFinalize failed for \(url.path)")
            return
        }
        print("PreviewSnapshotTests: wrote \(url.path)")
    }

    /// `PageScaffold.minSupportedWidth` (Theme/PageScaffold.swift:26) — the
    /// narrowest content width the dashboards must render without clipping.
    // PageScaffold is generic over Content, so the static needs a concrete
    // parameterization to be referenced from here.
    private static let narrowWidth: CGFloat = PageScaffold<EmptyView>.minSupportedWidth
    private static let wideWidth: CGFloat = 760

    private static let widths: [(CGFloat, String)] = [
        (narrowWidth, "\(Int(narrowWidth))"),
        (wideWidth, "\(Int(wideWidth))"),
    ]

    // MARK: - InlineBanner

    /// `InlineBanner<Content>.init(icon:tone:action:content:)` — three tones,
    /// one with a trailing `InlineBannerAction`.
    func testInlineBannerVariants() throws {
        for (width, label) in Self.widths {
            try render(
                InlineBanner(
                    icon: "clock.badge.exclamationmark",
                    tone: .warn,
                    action: InlineBannerAction(
                        label: "Collect now", icon: "arrow.down.circle",
                        handler: {}
                    )
                ) {
                    Text("Stale data — last collected 3 days ago")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.warn)
                },
                name: "inlinebanner-warn-\(label)",
                width: width
            )

            try render(
                InlineBanner(icon: "xmark.octagon.fill", tone: .danger, action: nil) {
                    Text("Collect failed — jamf-cli exited with code 3 (unauthorized)")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.danger)
                },
                name: "inlinebanner-danger-\(label)",
                width: width
            )

            try render(
                InlineBanner(icon: "info.circle", tone: .info, action: nil) {
                    Text("This screen renders the once-a-day summary digest, not live inventory.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.goldBright)
                },
                name: "inlinebanner-info-\(label)",
                width: width
            )
        }
    }

    // MARK: - StaleDataBanner

    /// `StaleDataBanner.init(source:onCollect:isCollecting:)` — `.stale(at:)`
    /// with a Collect-now action, matching the banner's default banner-visible
    /// state used across dashboards.
    func testStaleDataBannerVariants() throws {
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        for (width, label) in Self.widths {
            try render(
                StaleDataBanner(source: .stale(at: threeDaysAgo), onCollect: {}),
                name: "staledatabanner-stale-\(label)",
                width: width
            )
        }
    }

    // MARK: - FreshnessChipRow

    /// `FreshnessChipRow.init(sourceDates:now:withinHours:)` — one fresh
    /// (2h ago), one warn-stale (4d ago), one old (20d ago), pinned to a fixed
    /// `now` for deterministic rendering.
    func testFreshnessChipRowVariants() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed reference instant
        let sourceDates: [String: Date] = [
            "computers": now.addingTimeInterval(-2 * 3600),
            "patch-status": now.addingTimeInterval(-4 * 24 * 3600),
            "ea-results": now.addingTimeInterval(-20 * 24 * 3600),
        ]
        for (width, label) in Self.widths {
            try render(
                FreshnessChipRow(sourceDates: sourceDates, now: now),
                name: "freshnesschiprow-\(label)",
                width: width
            )
        }
    }

    // MARK: - ProvenanceBadge

    /// `ProvenanceBadge.init(asOf:sources:)` — clean (all-live) and degraded
    /// (2 cached, 1 absent) variants.
    func testProvenanceBadgeVariants() throws {
        for (width, label) in Self.widths {
            try render(
                ProvenanceBadge(
                    asOf: "2026-07-06",
                    sources: ["computers": "live", "patch-status": "live", "ea-results": "live"]
                ),
                name: "provenancebadge-clean-\(label)",
                width: width
            )

            try render(
                ProvenanceBadge(
                    asOf: "2026-07-06",
                    sources: [
                        "computers": "cache",
                        "patch-status": "cache",
                        "ea-results": "absent",
                    ]
                ),
                name: "provenancebadge-degraded-\(label)",
                width: width
            )
        }
    }

    // MARK: - ErrorStateView

    /// `ErrorStateView.init(title:message:commands:systemImage:retry:)` inside
    /// `Card(padding: 24)` — the posture-screen treatment
    /// (SecurityPostureService/CompliancePostureService `loadError` surfacing).
    func testErrorStateViewInCard() throws {
        for (width, label) in Self.widths {
            try render(
                Card(padding: 24) {
                    ErrorStateView(
                        title: "Couldn't read the security snapshot",
                        message: "The cached security-report file is corrupt or unreadable.",
                        commands: ["jamf-cli pro report security --output json"],
                        retry: {}
                    )
                },
                name: "errorstateview-card-\(label)",
                width: width
            )
        }
    }

    // MARK: - EmptyStateView

    /// `EmptyStateView.init(systemImage:title:message:commands:primaryAction:)`
    /// inside `Card(padding: 24)`, for visual comparison against `ErrorStateView`.
    func testEmptyStateViewInCard() throws {
        for (width, label) in Self.widths {
            try render(
                Card(padding: 24) {
                    EmptyStateView(
                        systemImage: "desktopcomputer.and.arrow.down",
                        title: "No device inventory yet",
                        message: "Run Generate Report to populate this screen.",
                        primaryAction: EmptyStateAction(
                            label: "Go to Overview", icon: "house", action: {}
                        )
                    )
                },
                name: "emptystateview-card-\(label)",
                width: width
            )
        }
    }
}
