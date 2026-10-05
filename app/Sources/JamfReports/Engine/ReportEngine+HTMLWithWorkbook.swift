import Foundation

/// `html.with_workbook`: the HTML report written beside every report workbook. One function
/// does the step, and every path that writes a profile's workbook calls it: the GUI generates
/// (`CLIBridge.generate`), the scheduled run and the included CLI's `generate`.
extension ReportEngine {

    /// Marks the `[warn]` line for a companion HTML that was not written.
    static let htmlWithWorkbookFailureMarker = "[warn] HTML report not written: "

    /// The HTML report's place for a workbook: the workbook's own name with `.html`, so the pair
    /// share a stem (`report_prod_2026-10-04_091500.xlsx` and `.html`), which is also how
    /// `jamf-reports html` and the Generate sheet's HTML-only run name it when no file is given.
    static func htmlURL(besideWorkbook workbookURL: URL) -> URL {
        workbookURL.deletingPathExtension().appendingPathExtension("html")
    }

    /// Writes the HTML report beside `workbookURL`, with `template`'s HTML sections, when
    /// `html.with_workbook` is on. Returns the file written, nil when the option is off or the
    /// HTML could not be written.
    ///
    /// The workbook is already on disk when this runs, so a failure here is one `[warn]` line
    /// and never an error: not `[partial]`, which Run History reads as Partial and the tick
    /// answers with a same-day retry that cannot help.
    @discardableResult
    func writeHTMLWithWorkbook(
        besideWorkbook workbookURL: URL,
        template: any ReportTemplate,
        aiNarrative: String? = nil,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async -> URL? {
        guard config.html?.writesWithWorkbook == true else { return nil }
        let htmlURL = Self.htmlURL(besideWorkbook: workbookURL)
        do {
            try await Self.generateHTML(
                config: config, dataDir: dataDir, outputURL: htmlURL, template: template,
                aiNarrative: aiNarrative, onLine: onLine)
        } catch {
            let reason = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            let message = Self.htmlWithWorkbookFailureMarker + reason
            AppLogger.report.warning("\(message, privacy: .private)")
            if let onLine {
                onLine(.init(timestamp: Date(), level: .warn, text: message))
            } else {
                print(message)
            }
            return nil
        }
        onLine?(.init(timestamp: Date(), level: .ok,
                      text: "[ok] HTML report written: \(htmlURL.lastPathComponent)"))
        return htmlURL
    }
}
