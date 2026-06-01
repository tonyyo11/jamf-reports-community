import Foundation

// MARK: - HtmlSectionFormatters

/// Shared HTML fragment helpers used by the 14 new section renderers in
/// `HtmlReport+Sections.swift`. All functions are `nonisolated` statics so they
/// can be called from pure renderer functions without actor hopping.
///
/// Security contract: every piece of user-controlled data **must** pass through
/// `escapeHTML(_:)` before interpolation. Functions in this file follow that
/// contract; callers must not bypass it.
enum HtmlSectionFormatters {

    // MARK: - Escape

    /// Escape a string for safe inclusion in HTML text content or attribute values.
    ///
    /// This is the only approved path for interpolating user-controlled data into
    /// HTML. Strings destined for a `<script>` block must use `HtmlReport.jsonArray`
    /// instead — HTML escaping is wrong in JavaScript context.
    ///
    /// Rejects strings starting with a URL scheme that can execute script (e.g.
    /// `javascript:`, `vbscript:`, or `data:` variants that load HTML/JS) by
    /// returning the literal text `[blocked]`. Control characters (including the
    /// null-byte bypass `java\0script:`) are stripped before scheme matching so
    /// `\0`-laced strings cannot slip past the prefix check.
    ///
    /// Strings destined for a `<script>` block must use `HtmlReport.jsonArray`
    /// instead — HTML escaping is wrong in JavaScript context.
    nonisolated static func escapeHTML(_ raw: String) -> String {
        // Strip control characters first so null-byte / tab bypasses cannot
        // reorder the scheme check (e.g. "java\0script:alert(1)").
        let stripped = String(raw.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r")
                && scalar.value != 0x7F
        })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let blockedPrefixes = [
            "javascript:",
            "vbscript:",
            "data:text/html",
            "data:text/javascript",
            "data:application/javascript",
            "data:application/x-javascript",
        ]
        if blockedPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return "[blocked]"
        }
        return stripped
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Table

    /// Render a standard `data-table` with a `<thead>` row and zero or more body rows.
    ///
    /// All header and cell values are escaped through `escapeHTML`.
    nonisolated static func renderTable(headers: [String], rows: [[String]]) -> String {
        let thCells = headers.map { "<th>\(escapeHTML($0))</th>" }.joined()
        let bodyRows = rows.map { cells -> String in
            let tds = cells.map { "<td>\(escapeHTML($0))</td>" }.joined()
            return "<tr>\(tds)</tr>"
        }.joined(separator: "\n")
        return """
        <table class="data-table">
          <thead><tr>\(thCells)</tr></thead>
          <tbody>\(bodyRows)</tbody>
        </table>
        """
    }

    // MARK: - Card grid

    /// A single count-style card: a large accent-colored value, a label, and an
    /// optional sub-label in muted text.
    struct SectionCard: Sendable {
        let name: String
        let value: String
        let sublabel: String?

        init(name: String, value: String, sublabel: String? = nil) {
            self.name = name
            self.value = value
            self.sublabel = sublabel
        }
    }

    /// Render a flex-wrapped row of `count-card` tiles from `SectionCard` values.
    nonisolated static func renderCardGrid(cards: [SectionCard]) -> String {
        guard !cards.isEmpty else { return "" }
        let cardHTML = cards.map { card -> String in
            let sub = card.sublabel.map {
                "<div class=\"count-sublabel\">\(escapeHTML($0))</div>"
            } ?? ""
            return """
            <div class="count-card">
              <div class="count-value">\(escapeHTML(card.value))</div>
              <div class="count-label">\(escapeHTML(card.name))</div>
              \(sub)
            </div>
            """
        }.joined(separator: "\n")
        return "<div class=\"count-cards\">\n\(cardHTML)\n</div>"
    }

    // MARK: - Percent bar

    /// Render an inline CSS horizontal percent bar for a labeled metric.
    ///
    /// The bar uses `--accent` for fill. `fraction` is clamped to [0, 1].
    nonisolated static func renderPercentBar(label: String, fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        let pct = Int((clamped * 100).rounded())
        let label64 = escapeHTML(label)
        return """
        <div class="pct-bar-row" role="meter" aria-label="\(label64): \(pct)%"
             aria-valuenow="\(pct)" aria-valuemin="0" aria-valuemax="100">
          <span class="pct-bar-label">\(label64)</span>
          <div class="pct-bar-track">
            <div class="pct-bar-fill" style="width:\(pct)%" aria-hidden="true"></div>
          </div>
          <span class="pct-bar-value">\(pct)%</span>
        </div>
        """
    }

    // MARK: - Severity pill

    /// Map a severity string to a CSS class and render a `<span class="sev-pill …">`.
    ///
    /// Maps "critical"→`sev-critical`, "high"→`sev-high`, "error"→`sev-error`,
    /// "medium"/"moderate"→`sev-medium`, "warning"/"warn"→`sev-warn`,
    /// "info"/"low"→`sev-info`.  All others get `sev-unknown`.
    nonisolated static func renderSeverityPill(_ severity: String) -> String {
        let cls: String
        switch severity.lowercased() {
        case "critical":                cls = "sev-critical"
        case "high":                    cls = "sev-high"
        case "error":                   cls = "sev-error"
        case "medium", "moderate":      cls = "sev-medium"
        case "warning", "warn":         cls = "sev-warn"
        case "info", "low":             cls = "sev-info"
        default:                        cls = "sev-unknown"
        }
        return "<span class=\"sev-pill \(cls)\">\(escapeHTML(severity))</span>"
    }

    // MARK: - List

    /// Render an unordered list from the given items. Empty returns `""`.
    nonisolated static func renderList(items: [String]) -> String {
        guard !items.isEmpty else { return "" }
        let lis = items.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n")
        return "<ul class=\"section-list\">\n\(lis)\n</ul>"
    }

    // MARK: - Empty state

    /// Render the canonical empty-state paragraph for a section.
    ///
    /// `reason` describes why data is absent and how to populate it.
    /// The paragraph uses class `empty` matching the spec.
    nonisolated static func emptyState(_ reason: String) -> String {
        "<p class=\"empty\">\(escapeHTML(reason))</p>"
    }

    /// Render a placeholder `<section>` block for sections whose required snapshot
    /// is absent. Used as the return value from section builders when data is missing,
    /// so the generated report always shows every requested section rather than
    /// silently omitting it.
    ///
    /// - Parameters:
    ///   - title: Human-readable section heading (HTML-escaped before output).
    ///   - dataKind: The snapshot kind name the section needs, e.g. `"patch-device-failures"`.
    nonisolated static func emptySection(title: String, dataKind: String) -> String {
        """
        <section class="content-section empty-section">
          <h2>\(escapeHTML(title))</h2>
          <p class="empty-note">No data available — run Collect to fetch \
        '\(escapeHTML(dataKind))' from Jamf Pro.</p>
        </section>
        """
    }

    // MARK: - CSS additions

    /// CSS snippet appended to `HtmlReport.buildCSS` for new section elements.
    /// Not called directly — `HtmlReport+Sections` appends this via the
    /// `additionalCSS` property.
    static let additionalCSS: String = """
    /* HtmlSectionFormatters additions */
    .pct-bar-row { display: flex; align-items: center; gap: 0.6rem;
                   margin: 0.35rem 0; font-size: 0.85rem; }
    .pct-bar-label { min-width: 140px; color: var(--subtext); }
    .pct-bar-track { flex: 1; height: 10px; background: var(--border);
                     border-radius: 5px; overflow: hidden; }
    .pct-bar-fill  { height: 100%; background: var(--accent); border-radius: 5px; }
    .pct-bar-value { min-width: 3.5rem; text-align: right; }
    .sev-pill { display: inline-block; padding: 0.15em 0.55em; border-radius: 4px;
                font-size: 0.75rem; font-weight: 600; letter-spacing: 0.03em; }
    .sev-critical { background: #8b0000; color: #fff; }
    .sev-high     { background: #c62828; color: #fff; }
    .sev-error    { background: #c62828; color: #fff; }
    .sev-medium   { background: #e65100; color: #fff; }
    .sev-warn     { background: #f9a825; color: #000; }
    .sev-info     { background: #1565c0; color: #fff; }
    .sev-unknown  { background: var(--border); color: var(--text); }
    [data-theme="dark"] .sev-critical { background: #ff1744; }
    [data-theme="dark"] .sev-high     { background: #ff5252; }
    [data-theme="dark"] .sev-error    { background: #ff5252; }
    [data-theme="dark"] .sev-medium   { background: #ff9800; }
    [data-theme="dark"] .sev-warn     { background: #ffd740; color: #000; }
    [data-theme="dark"] .sev-info     { background: #448aff; }
    .section-list { padding-left: 1.5rem; font-size: 0.9rem; }
    .section-list li { margin-bottom: 0.25rem; }
    .count-sublabel { font-size: 0.75rem; color: var(--subtext); margin-top: 0.15rem; }
    p.empty { color: var(--subtext); font-size: 0.85rem; padding: 0.5rem 0; font-style: italic; }
    .svg-bar-chart { display: block; width: 100%; max-width: 640px; height: auto; }
    .cohort-bar-section { display: flex; flex-direction: column; gap: 0.5rem; margin-top: 0.5rem; }
    .cohort-bar-row { display: flex; align-items: center; gap: 0.75rem; font-size: 0.85rem; }
    .cohort-bar-key { min-width: 6rem; color: var(--subtext); }
    .cohort-bar-bg  { flex: 1; height: 16px; background: var(--border);
                      border-radius: 3px; overflow: hidden; }
    .cohort-bar-fill { height: 100%; background: var(--accent); border-radius: 3px; }
    .cohort-bar-n   { min-width: 3rem; text-align: right; }
    /* Cleanup Analysis tab strip */
    .cleanup-tabs { display: flex; flex-wrap: wrap; gap: 0.4rem; margin-bottom: 0.75rem;
                    border-bottom: 1px solid var(--border); padding-bottom: 0.4rem; }
    .cleanup-tab { background: none; border: 1px solid var(--border); border-radius: 6px 6px 0 0;
                   padding: 0.35rem 0.75rem; font-size: 0.85rem; cursor: pointer; color: var(--text); }
    .cleanup-tab.active { background: var(--accent); color: #fff; border-color: var(--accent); }
    .cleanup-badge { display: inline-block; background: var(--bg); color: var(--subtext);
                     font-size: 0.72rem; border-radius: 10px; padding: 0 0.4em;
                     margin-left: 0.3em; }
    .cleanup-tab.active .cleanup-badge { background: rgba(255,255,255,0.25); color: #fff; }
    .cleanup-pane { display: none; }
    .cleanup-pane.active { display: block; }
    .cleanup-note { font-size: 0.8rem; color: var(--subtext); margin-bottom: 0.5rem; }
    .cleanup-ok { color: var(--green); font-size: 0.9rem; padding: 0.4rem 0; }
    /* Timeline section */
    .timeline-note { font-size: 0.8rem; color: var(--subtext); margin-bottom: 0.75rem; }
    """
}
