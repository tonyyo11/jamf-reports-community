import Foundation

/// The HTML report's jamf-cli dashboard section: the newest `dashboard` snapshot, a
/// whole page jamf-cli wrote, shown inside the report in a sandboxed frame.
///
/// The frame gets scripts but no same-origin access, so the page cannot reach the
/// report or its file. Its own script touches no storage, so the sandbox costs it
/// nothing. Four things are added to the page before it is embedded:
/// - A content-security policy, so the page's scripts cannot make requests either.
/// - CSS that shows every section card and fills every ring. jamf-cli reveals both by
///   animation, and its own print styles switch animations off without restoring
///   them, which leaves the cards invisible and the rings empty. It also hides the
///   page's theme switch, since the report's switch drives the frame.
/// - A script that posts the page's height, so the report can size the frame. The
///   report cannot measure a frame in another origin itself.
/// - A script that takes the report's theme. The report is light unless the reader
///   picks dark, while the page follows the Mac's appearance, so without it a Mac in
///   dark mode shows a dark page inside a light report.
///
/// The page keeps its own filters, collapsible sections and timestamps.
///
/// The PDF export prints a one-line note instead, because a frame does not break
/// across printed pages.
extension HtmlReport {

    /// What the report can do with the newest `dashboard` snapshot.
    enum DashboardState {
        /// The frame's section markup.
        case embedded(String)
        /// A note's markup: a page is collected but too large to embed.
        case notEmbedded(String)
        /// No page to show. The reason goes in the appendix; nil when the template has none.
        case absent(String?)

        /// True when the page itself is in the report, so the sections it repeats can leave.
        var isEmbedded: Bool {
            if case .embedded = self { return true }
            return false
        }
    }

    /// Largest page embedded. A fast-tier page is tens of kilobytes, so this only
    /// stops an unusual page from swelling every report generated from the workspace.
    static let maxEmbeddedDashboardBytes = 4_000_000

    /// The report's policy, which the dashboard frame inherits and also carries itself. The
    /// frame's page runs scripts, so this keeps it from reaching anything outside itself: no
    /// requests, no frames, no fonts, images only as `data:` URIs. jamf-cli's page is one
    /// inline `<style>` and `<script>` with inline handlers and no resources. `default-src`
    /// does not cover `base-uri` or `form-action`, so a `<base>` or a form could still
    /// redirect relative URLs or submit data out of the report.
    static let reportContentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
        + "img-src data:; base-uri 'none'; form-action 'none'"

    /// The policy as a meta tag. It only governs what follows it, so it comes first.
    static let reportContentSecurityPolicyMeta =
        "<meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"\(reportContentSecurityPolicy)\">"

    /// Shows the cards and rings without their animation (jamf-cli's
    /// `dashboard_html.go`: `.section` starts at opacity 0 and `.ring` at `--rv: 0`),
    /// and hides the page's theme switch, which the report's switch replaces.
    static let dashboardEmbedStyle: String =
        ".section{opacity:1!important;animation:none!important}"
        + ".ring{--rv:var(--v)!important;animation:none!important}"
        + ".theme-toggle{display:none!important}"

    /// Posts the height of the page's body to the report, which checks the message came
    /// from this frame before using it. The body, not the document: a document is never
    /// shorter than its frame, so measuring it fed the frame's height back in and the
    /// frame grew on every resize. A ResizeObserver catches a section collapsing or
    /// expanding, which resizes nothing else.
    static let dashboardHeightScript: String =
        "(function(){function h(){try{var b=document.body;if(!b){return;}"
        + "var s=getComputedStyle(b);var v=b.getBoundingClientRect().height"
        + "+(parseFloat(s.marginTop)||0)+(parseFloat(s.marginBottom)||0);"
        + "parent.postMessage({jrcDashboardHeight:Math.ceil(v)},\"*\")}catch(e){}}"
        + "window.addEventListener(\"load\",function(){h();if(window.ResizeObserver){"
        + "new ResizeObserver(h).observe(document.body);}});"
        + "window.addEventListener(\"resize\",h);})();"

    /// Starts the page light, the report's default, then takes whatever theme the
    /// report sends. The page keys its dark palette on `data-theme` ahead of the Mac's
    /// appearance, so setting it wins either way.
    static let dashboardThemeScript: String =
        "(function(){var d=document.documentElement;d.setAttribute(\"data-theme\",\"light\");"
        + "window.addEventListener(\"message\",function(e){"
        + "if(e.source!==parent||!e.data){return;}var t=e.data.jrcTheme;"
        + "if(t===\"light\"||t===\"dark\"){d.setAttribute(\"data-theme\",t);}});})();"

    /// The newest dashboard snapshot, as the report can use it.
    func dashboardState() -> DashboardState {
        let dir = dataDir.appendingPathComponent(ReportEngine.dashboardKind, isDirectory: true)
        guard let url = FileManager.newestHTMLSnapshot(in: dir),
              let data = try? Data(contentsOf: url) else {
            return .absent("not collected yet; with jamf-cli 1.31.0 or later, collect saves "
                + "jamf-cli's dashboard every two days")
        }
        let collected = FileManager.snapshotDate(of: url).map(Self.dashboardDateText)
            ?? "on an unknown date"
        guard data.count <= Self.maxEmbeddedDashboardBytes else {
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(data.count), countStyle: .file)
            return .notEmbedded(Self.dashboardNoteSection(
                "The dashboard collected \(collected) is \(size), too large to embed. Open "
                    + "\(url.lastPathComponent) from the jamf-cli-data/dashboard folder."))
        }
        let page = Self.dashboardPageForEmbedding(String(decoding: data, as: UTF8.self))
        let srcdoc = HtmlSectionFormatters.escapeHTML(page)
        let caption = HtmlSectionFormatters.escapeHTML(
            "From jamf-cli's dashboard command, collected \(collected). It covers Jamf Pro and, "
                + "where this profile reaches them, the Jamf Platform API, Jamf Protect and "
                + "Jamf Security Cloud.")
        // The border sits on a wrapper so the frame's height is all page under any box
        // model, and nothing is styled inline, so the print rule can hide the frame.
        return .embedded("""
        <details class="group dashboard" id="jamf-dashboard" open>
          <summary><span class="grp-title">Jamf Fleet Dashboard</span></summary>
          <div class="group-body">
          <style>
            #jamf-dashboard .jrc-dashboard-wrap {
              border: 1px solid rgba(127,127,127,0.35); border-radius: 8px; overflow: hidden;
            }
            #jrc-dashboard-frame { display: block; width: 100%; height: 1200px; border: 0; }
            #jamf-dashboard .jrc-dashboard-print-note { display: none; }
            @media print {
              #jamf-dashboard .jrc-dashboard-wrap { display: none !important; }
              #jamf-dashboard .jrc-dashboard-print-note { display: block; }
            }
          </style>
          <p class="note">\(caption)</p>
          <div class="jrc-dashboard-wrap"><iframe id="jrc-dashboard-frame" \
        title="Jamf fleet dashboard from jamf-cli" sandbox="allow-scripts" \
        referrerpolicy="no-referrer" srcdoc="\(srcdoc)"></iframe></div>
          <p class="note jrc-dashboard-print-note">The Jamf fleet dashboard is interactive; \
        open the HTML version of this report to see it.</p>
          <script>
          (function () {
            var frame = document.getElementById("jrc-dashboard-frame");
            if (!frame) { return; }
            window.addEventListener("message", function (event) {
              if (event.source !== frame.contentWindow || !event.data) { return; }
              var height = event.data.jrcDashboardHeight;
              if (typeof height !== "number" || !isFinite(height)) { return; }
              var clamped = Math.max(400, Math.min(Math.ceil(height), 40000));
              if (Math.abs(frame.clientHeight - clamped) > 2) {
                frame.style.height = clamped + "px";
              }
            });
            function sendTheme() {
              var dark = document.documentElement.getAttribute("data-theme") === "dark";
              try {
                frame.contentWindow.postMessage({ jrcTheme: dark ? "dark" : "light" }, "*");
              } catch (e) {}
            }
            frame.addEventListener("load", sendTheme);
            if (window.MutationObserver) {
              new MutationObserver(sendTheme).observe(document.documentElement,
                { attributes: true, attributeFilter: ["data-theme"] });
            }
          })();
          </script>
          </div>
        </details>
        """)
    }

    /// `page` behind the content-security policy and the embed style and the height and
    /// theme scripts at the end of its head. The policy is a prefix at byte 0, since a meta
    /// policy ignores what precedes it and a regex for the head can be fooled by `<head>`
    /// inside a comment or after a script; `<!DOCTYPE html>` keeps `document.doctype`, as
    /// the page's own is dropped once the prefix opens the head. A page with no head gets
    /// one first.
    static func dashboardPageForEmbedding(_ page: String) -> String {
        let addition = "<style id=\"jrc-embed\">\(dashboardEmbedStyle)</style>"
            + "<script id=\"jrc-embed-height\">\(dashboardHeightScript)</script>"
            + "<script id=\"jrc-embed-theme\">\(dashboardThemeScript)</script>"
        let prefix = "<!DOCTYPE html>" + reportContentSecurityPolicyMeta
        // `(?=[\s/>])` keeps `<header>` from passing for the head.
        guard let open = page.range(
            of: "<head(?=[\\s/>])[^>]*>", options: [.regularExpression, .caseInsensitive]
        ) else {
            return prefix + "<head>" + addition + "</head>" + page
        }
        let close = page.range(
            of: "</head>", options: .caseInsensitive, range: open.upperBound..<page.endIndex)
        let insideEnd = close?.lowerBound ?? open.upperBound
        return prefix + String(page[..<insideEnd]) + addition + String(page[insideEnd...])
    }

    private static func dashboardNoteSection(_ note: String) -> String {
        """
        <details class="group dashboard" id="jamf-dashboard" open>
          <summary><span class="grp-title">Jamf Fleet Dashboard</span></summary>
          <div class="group-body">
            <p class="note">\(HtmlSectionFormatters.escapeHTML(note))</p>
          </div>
        </details>
        """
    }

    private static func dashboardDateText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "on " + fmt.string(from: date)
    }
}
