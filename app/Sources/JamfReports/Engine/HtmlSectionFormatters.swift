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
    /// HTML. No report data goes into a `<script>` block, where HTML escaping would be
    /// the wrong escape.
    ///
    /// Rejects strings starting with a URL scheme that can execute script (e.g.
    /// `javascript:`, `vbscript:`, or `data:` variants that load HTML/JS) by
    /// returning the literal text `[blocked]`. Control characters (including the
    /// null-byte bypass `java\0script:`) are stripped before scheme matching, and
    /// embedded tab/CR/LF are removed for that check too (matching how WHATWG URL
    /// parsers read a URL) so `java\tscript:` cannot slip past the prefix check.
    nonisolated static func escapeHTML(_ raw: String) -> String {
        // Strip control characters first so null-byte / tab bypasses cannot
        // reorder the scheme check (e.g. "java\0script:alert(1)").
        let stripped = String(raw.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r")
                && scalar.value != 0x7F
        })
        // URL parsers strip tab/CR/LF anywhere, not just at the ends. `stripped`
        // itself is untouched so ordinary text still renders them.
        let schemeCheckCandidate = stripped
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let blockedPrefixes = [
            "javascript:",
            "vbscript:",
            "data:text/html",
            "data:text/javascript",
            "data:application/javascript",
            "data:application/x-javascript",
        ]
        if blockedPrefixes.contains(where: { schemeCheckCandidate.hasPrefix($0) }) {
            return "[blocked]"
        }
        return stripped
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// `raw` escaped, with a line-break opportunity after each `.`, `_` and `/` that has more
    /// text after it, so a long reverse-DNS or file-style name wraps at a separator instead of
    /// running out of its box or breaking mid-word.
    nonisolated static func escapeHTMLBreakable(_ raw: String) -> String {
        let characters = Array(escapeHTML(raw))
        var out = ""
        for (index, character) in characters.enumerated() {
            out.append(character)
            guard "._/".contains(character), index + 1 < characters.count,
                  characters[index + 1].isLetter || characters[index + 1].isNumber
            else { continue }
            out += "<wbr>"
        }
        return out
    }

    // MARK: - Counts

    /// "1 title", "2 titles": a count with its noun, regular plural.
    nonisolated static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: - Table

    /// Render a standard `data-table` with a `<thead>` row and zero or more body rows.
    ///
    /// All header and cell values are escaped through `escapeHTML`. `rowClasses`, when given,
    /// holds one CSS class (or nil) per row.
    nonisolated static func renderTable(
        headers: [String], rows: [[String]], rowClasses: [String?]? = nil
    ) -> String {
        let thCells = headers.map { "<th>\(escapeHTML($0))</th>" }.joined()
        let bodyRows = rows.enumerated().map { index, cells -> String in
            let tds = cells.map { "<td>\(escapeHTML($0))</td>" }.joined()
            let cls = rowClasses.flatMap { index < $0.count ? $0[index] : nil }
                .map { " class=\"\(escapeHTML($0))\"" } ?? ""
            return "<tr\(cls)>\(tds)</tr>"
        }.joined(separator: "\n")
        return """
        <table class="data-table">
          <thead><tr>\(thCells)</tr></thead>
          <tbody>\(bodyRows)</tbody>
        </table>
        """
    }

    /// Rows a list shows before the rest go behind "Show all".
    nonisolated static let visibleRowLimit = 10

    /// Rows a "Show all" block holds at most. A list longer than this says how many more
    /// the workbook has, so one report cannot swell without bound.
    nonisolated static let maxTableRows = 500

    /// Row caps for the lists that name Macs. The report is forwarded, so these hold the
    /// 2.8.3 limits instead of `maxTableRows`.
    nonisolated static let maxInterventionRows = 100
    nonisolated static let maxFailureRows = 25
    nonisolated static let maxNonCompliantRows = 10

    /// A table of the first `limit` rows and, when there are more, the rest inside a nested
    /// `<details>` headed "Show all N" (N is the full count). Every row up to `maxRows`
    /// stays in the file; past that the block reads "Show M of N" and a note gives the count
    /// the workbook holds.
    nonisolated static func renderCappedTable(
        headers: [String],
        rows: [[String]],
        rowClasses: [String?]? = nil,
        limit: Int = visibleRowLimit,
        maxRows: Int = maxTableRows,
        expanded: Bool = false
    ) -> String {
        let kept = Array(rows.prefix(maxRows))
        let classes = rowClasses.map { Array($0.prefix(kept.count)) }
        let omitted = rows.count - kept.count
        let more = omitted > 0
            ? "<p class=\"empty\">\(omitted) more rows are in the workbook.</p>" : ""
        guard kept.count > limit else {
            return renderTable(headers: headers, rows: kept, rowClasses: classes) + more
        }
        let head = renderTable(
            headers: headers, rows: Array(kept.prefix(limit)),
            rowClasses: classes.map { Array($0.prefix(limit)) })
        let rest = renderTable(
            headers: headers, rows: Array(kept.dropFirst(limit)),
            rowClasses: classes.map { Array($0.dropFirst(limit)) })
        let label = omitted > 0 ? "Show \(kept.count) of \(rows.count)" : "Show all \(rows.count)"
        return head + disclosure(label: label, body: rest + more, expanded: expanded)
    }

    /// Rows that are already markup (a `<tr>` each), capped like `renderCappedTable`.
    nonisolated static func renderCappedRows(
        headers: [String], rowHTML: [String], limit: Int = visibleRowLimit,
        expanded: Bool = false
    ) -> String {
        func table(_ rows: ArraySlice<String>) -> String {
            let th = headers.map { "<th>\(escapeHTML($0))</th>" }.joined()
            return "<table class=\"data-table\"><thead><tr>\(th)</tr></thead>"
                + "<tbody>\(rows.joined(separator: "\n"))</tbody></table>"
        }
        guard rowHTML.count > limit else { return table(rowHTML[...]) }
        return table(rowHTML.prefix(limit))
            + showAll(count: rowHTML.count, body: table(rowHTML.dropFirst(limit)),
                      expanded: expanded)
    }

    /// The nested block that holds a list's remaining rows.
    nonisolated static func showAll(count: Int, body: String, expanded: Bool) -> String {
        disclosure(label: "Show all \(count)", body: body, expanded: expanded)
    }

    /// A collapsed block inside a detail group, opened by its label. `expanded` renders it
    /// open, for the PDF export, whose renderer runs no script.
    nonisolated static func disclosure(label: String, body: String, expanded: Bool) -> String {
        """
        <details class="show-all"\(expanded ? " open" : "")>
          <summary>\(escapeHTML(label))</summary>
          \(body)
        </details>
        """
    }

    /// A titled block inside a detail group. `id` is the anchor "Needs attention" links to.
    nonisolated static func block(id: String, title: String, body: String) -> String {
        """
        <div class="block" id="\(escapeHTML(id))">
          <h3>\(escapeHTML(title))</h3>
          \(body)
        </div>
        """
    }

    /// Proportional bars, a label, a track and a count per row. The first `limit` show; the
    /// rest sit behind "Show all N".
    nonisolated static func renderBars(
        _ rows: [(label: String, count: Int)],
        limit: Int = visibleRowLimit,
        expanded: Bool = false
    ) -> String {
        let peak = max(rows.map(\.count).max() ?? 1, 1)
        return renderBarRows(rows.map { row in
            BarRow(label: row.label, fill: Double(row.count) / Double(peak) * 100,
                   value: "\(row.count)",
                   spoken: row.count == 1 ? "1 device" : "\(row.count) devices")
        }, limit: limit, expanded: expanded)
    }

    /// Shares as bars on a fixed 0–100% track, so equal shares draw equal lengths whatever
    /// the other rows hold. A share outside 0–100, or not a number, is held to the track.
    nonisolated static func renderPercentBars(
        _ rows: [(label: String, pct: Double)],
        limit: Int = visibleRowLimit,
        expanded: Bool = false
    ) -> String {
        renderBarRows(rows.map { row in
            let pct = row.pct.isFinite ? min(max(row.pct, 0), 100) : 0
            let text = pct == pct.rounded() ? "\(Int(pct))%" : String(format: "%.1f%%", pct)
            return BarRow(label: row.label, fill: pct, value: text, spoken: text)
        }, limit: limit, expanded: expanded)
    }

    private struct BarRow {
        let label: String
        /// Bar length, 0–100.
        let fill: Double
        let value: String
        let spoken: String
    }

    private nonisolated static func renderBarRows(
        _ rows: [BarRow], limit: Int, expanded: Bool
    ) -> String {
        func bars(_ slice: ArraySlice<BarRow>) -> String {
            let html = slice.map { row -> String in
                let width = Int(min(max(row.fill, 0), 100).rounded())
                let key = escapeHTML(row.label)
                return """
                <div class="cohort-bar-row">
                  <span class="cohort-bar-key">\(key)</span>
                  <div class="cohort-bar-bg">
                    <div class="cohort-bar-fill" style="width:\(width)%"
                         aria-label="\(key): \(escapeHTML(row.spoken))"></div>
                  </div>
                  <span class="cohort-bar-n">\(escapeHTML(row.value))</span>
                </div>
                """
            }.joined(separator: "\n")
            return "<div class=\"cohort-bar-section\">\(html)</div>"
        }
        guard rows.count > limit else { return bars(rows[...]) }
        return bars(rows.prefix(limit))
            + showAll(count: rows.count, body: bars(rows.dropFirst(limit)), expanded: expanded)
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
        case "info", "informational", "low":
                                        cls = "sev-info"
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

    /// A list of the first `limit` items and, when there are more, the rest behind "Show all N".
    nonisolated static func renderCappedList(
        items: [String], limit: Int = visibleRowLimit, expanded: Bool = false
    ) -> String {
        guard items.count > limit else { return renderList(items: items) }
        return renderList(items: Array(items.prefix(limit)))
            + showAll(count: items.count, body: renderList(items: Array(items.dropFirst(limit))),
                      expanded: expanded)
    }

    // MARK: - Empty state

    /// Render the canonical empty-state paragraph for a section.
    ///
    /// `reason` describes why data is absent and how to populate it.
    /// The paragraph uses class `empty` matching the spec.
    nonisolated static func emptyState(_ reason: String) -> String {
        "<p class=\"empty\">\(escapeHTML(reason))</p>"
    }

    // MARK: - CSS additions

    /// CSS snippet appended to `HtmlReport.buildCSS` for new section elements.
    /// Not called directly — `HtmlReport+Sections` appends this via the
    /// `additionalCSS` property.
    static let additionalCSS: String = """
    /* HtmlSectionFormatters additions */
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
