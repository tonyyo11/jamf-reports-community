import Foundation

/// The HTML report's jamf-cli dashboard section: the newest `dashboard` snapshot, a
/// whole page jamf-cli wrote, shown inside the report in a sandboxed frame.
///
/// The frame gets scripts but no same-origin access, so the page cannot reach the
/// report or its file. Its own script touches no storage, so the sandbox costs it
/// nothing. Three things are added to the page before it is embedded:
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

    /// Largest page embedded. A fast-tier page is tens of kilobytes, so this only
    /// stops an unusual page from swelling every report generated from the workspace.
    static let maxEmbeddedDashboardBytes = 4_000_000

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

    func buildJamfDashboardSection() -> String {
        let dir = dataDir.appendingPathComponent(ReportEngine.dashboardKind, isDirectory: true)
        guard let url = FileManager.newestHTMLSnapshot(in: dir),
              let data = try? Data(contentsOf: url) else {
            return Self.dashboardNoteSection(
                "Not collected yet. With jamf-cli 1.31.0 or later, collect saves jamf-cli's "
                    + "dashboard every two days.")
        }
        let collected = FileManager.snapshotDate(of: url).map(Self.dashboardDateText)
            ?? "on an unknown date"
        guard data.count <= Self.maxEmbeddedDashboardBytes else {
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(data.count), countStyle: .file)
            return Self.dashboardNoteSection(
                "The dashboard collected \(collected) is \(size), too large to embed. Open "
                    + "\(url.lastPathComponent) from the jamf-cli-data/dashboard folder.")
        }
        let page = Self.dashboardPageForEmbedding(String(decoding: data, as: UTF8.self))
        let srcdoc = HtmlSectionFormatters.escapeHTML(page)
        let caption = HtmlSectionFormatters.escapeHTML(
            "From jamf-cli's dashboard command, collected \(collected). It covers Jamf Pro and, "
                + "where this profile reaches them, the Jamf Platform API, Jamf Protect and "
                + "Jamf Security Cloud.")
        // The border sits on a wrapper so the frame's height is all page under any box
        // model, and nothing is styled inline, so the print rule can hide the frame.
        return """
        <div class="section" id="jamf-dashboard">
          <h2>Jamf Fleet Dashboard</h2>
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
        """
    }

    /// `page` with the embed style and the height and theme scripts added at the end of
    /// its `<head>`, or at the start when it has none.
    static func dashboardPageForEmbedding(_ page: String) -> String {
        let addition = "<style id=\"jrc-embed\">\(dashboardEmbedStyle)</style>"
            + "<script id=\"jrc-embed-height\">\(dashboardHeightScript)</script>"
            + "<script id=\"jrc-embed-theme\">\(dashboardThemeScript)</script>"
        guard let head = page.range(of: "</head>", options: .caseInsensitive) else {
            return addition + page
        }
        var out = page
        out.insert(contentsOf: addition, at: head.lowerBound)
        return out
    }

    private static func dashboardNoteSection(_ note: String) -> String {
        "<div class=\"section\" id=\"jamf-dashboard\"><h2>Jamf Fleet Dashboard</h2>"
            + "<p class=\"note\">\(HtmlSectionFormatters.escapeHTML(note))</p></div>"
    }

    private static func dashboardDateText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "on " + fmt.string(from: date)
    }
}
