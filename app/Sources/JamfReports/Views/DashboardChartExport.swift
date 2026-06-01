import SwiftUI
import AppKit

/// Shared PNG export plumbing for the v3.5-port dashboards. Each chart card
/// renders its primary visual into a fixed 848×448 light-mode canvas with a
/// consistent title / subtitle / footnote frame, then `ImageRenderer` writes
/// the PNG to a user-chosen file via `NSSavePanel`.
///
/// Kept separate from `ChartExportView` in `TrendsView.swift` so this helper
/// can evolve without changing the TrendsView export pipeline. The visual
/// framing matches `ChartExportView` (same canvas size, same neutral
/// background, same serif title + monospaced kicker + footnote) so exports
/// across the app look like they came from the same template.
@MainActor
enum DashboardChartExport {

    /// Distinguishes the two failure modes so callers can give the user an
    /// accurate explanation. Render failures point at the SwiftUI/ImageRenderer
    /// path (rare; usually a SwiftUI/AppKit bug). Write failures are common
    /// (permissions, full disk, removable media ejected).
    enum ExportError: Error {
        case renderFailed
        case writeFailed(underlying: Error)

        var userMessage: String {
            switch self {
            case .renderFailed:
                return "Could not render the chart for export."
            case .writeFailed(let error):
                return "Could not save PNG: \(error.localizedDescription)"
            }
        }
    }

    /// Present an `NSSavePanel`, render `content` at 848×448 light-mode, and
    /// write a PNG to the chosen path.
    ///
    /// Returns:
    /// - `nil` when the user cancelled the save panel (no toast needed).
    /// - `.success(url)` after the PNG was written.
    /// - `.failure(error)` if render or write failed; the caller is
    ///   responsible for surfacing the message via `Toast`/alert.
    @discardableResult
    static func run<Content: View>(
        title: String,
        subtitle: String? = nil,
        footnote: String? = nil,
        suggestedFilename: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> Result<URL, ExportError>? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFilename
        panel.title = "Export Chart as PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let exportView = DashboardExportCanvas(
            title: title,
            subtitle: subtitle,
            footnote: footnote,
            content: content
        )
        let renderer = ImageRenderer(content: exportView)
        renderer.scale = 2.0

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            AppLogger.ui.error(
                "DashboardChartExport: render pipeline returned nil for '\(title, privacy: .public)'"
            )
            return .failure(.renderFailed)
        }

        do {
            try pngData.write(to: url)
            return .success(url)
        } catch {
            AppLogger.ui.error(
                "DashboardChartExport: write failed for chart '\(title, privacy: .public)' — \(error.localizedDescription, privacy: .private)"
            )
            return .failure(.writeFailed(underlying: error))
        }
    }

    /// Variant for views that already supply their own title/footer framing
    /// (e.g. `BarChartExportView` in `ExtensionAttributesView`). The runner
    /// still wraps the content in a fixed 848×448 light-mode canvas so every
    /// exported PNG has the same dimensions. Used when the dashboard's chart
    /// is rich enough to design its own frame; for plain charts use `run(...)`
    /// and let `DashboardExportCanvas` provide the title/subtitle/footnote.
    @discardableResult
    static func render<Content: View>(
        suggestedFilename: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> Result<URL, ExportError>? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFilename
        panel.title = "Export Chart as PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let framed = content()
            .frame(width: 848, height: 448)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large) // pin DynamicTypeSize so PNG exports stay deterministic regardless of OS accessibility settings
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2.0

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            AppLogger.ui.error(
                "DashboardChartExport.render: render pipeline returned nil for '\(suggestedFilename, privacy: .public)'"
            )
            return .failure(.renderFailed)
        }

        do {
            try pngData.write(to: url)
            return .success(url)
        } catch {
            AppLogger.ui.error(
                "DashboardChartExport.render: write failed for '\(suggestedFilename, privacy: .public)' — \(error.localizedDescription, privacy: .private)"
            )
            return .failure(.writeFailed(underlying: error))
        }
    }

    /// Shared `DateFormatter` for filename date stamps. Static let on a
    /// `@MainActor` enum — safe under Swift 6 strict concurrency because all
    /// callers are already on the main actor.
    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Sanitize an arbitrary string into a safe filename component. Replaces
    /// any character outside `[A-Za-z0-9._-]` with a hyphen, collapses runs
    /// of consecutive hyphens, and strips leading/trailing hyphens.
    private static func sanitize(_ raw: String) -> String {
        var result = raw.unicodeScalars.map { scalar in
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" {
                return String(c)
            }
            return "-"
        }.joined()
        // Collapse repeated hyphens.
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        // Trim leading/trailing hyphens.
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result
    }

    /// Build a PNG filename prefilled with profile, label, and today's date.
    ///
    /// Format: `"<profile>-<label>-<yyyy-MM-dd>.png"`. If the sanitized
    /// profile is empty the profile segment is omitted:
    /// `"<label>-<yyyy-MM-dd>.png"`.
    ///
    /// Both `profile` and `label` are sanitized: characters outside
    /// `[A-Za-z0-9._-]` become hyphens, consecutive hyphens collapse, and
    /// leading/trailing hyphens are stripped.
    static func filename(for label: String, profile: String) -> String {
        let sanitizedProfile = sanitize(profile)
        let sanitizedLabel = sanitize(label)
        let dateStr = dateStampFormatter.string(from: Date())
        if sanitizedProfile.isEmpty {
            return "\(sanitizedLabel)-\(dateStr).png"
        }
        return "\(sanitizedProfile)-\(sanitizedLabel)-\(dateStr).png"
    }
}

/// Shared export header used by both `DashboardExportCanvas` and other custom
/// export views like `BarChartExportView`. Provides consistent title typography
/// across all export templates.
public struct DashboardExportHeader: View {
    let title: String
    let subtitle: String?
    let headerTrailing: AnyView?

    public init(title: String, subtitle: String? = nil, headerTrailing: (() -> AnyView)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.headerTrailing = headerTrailing?()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle.uppercased())
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color(hex: 0x64748B))
                }
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: 0x111827))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            headerTrailing
        }
    }
}

/// Fixed-size light-mode canvas used by `DashboardChartExport.run`. Stands
/// alone — no environment dependencies — so it renders correctly off-screen
/// under `ImageRenderer`.
private struct DashboardExportCanvas<Content: View>: View {
    let title: String
    let subtitle: String?
    let footnote: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardExportHeader(title: title, subtitle: subtitle)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(footnote ?? "Source: jamf-cli snapshots · Generated \(Self.timestamp())")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x64748B))
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 848, height: 448)
        .background(Color(hex: 0xF8FAFC))
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large) // pin DynamicTypeSize so PNG exports stay deterministic regardless of OS accessibility settings
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
