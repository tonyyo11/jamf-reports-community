import Foundation
import WebKit

// MARK: - PDFExporter

/// Converts HTML content to a paginated PDF using WKWebView.
///
/// Must run on the main actor — WKWebView is a UIKit/AppKit-backed view
/// and is not safe to use off the main thread.
///
/// Usage:
/// ```swift
/// try await PDFExporter.export(htmlString: myHTML, to: outputURL)
/// ```
@MainActor
final class PDFExporter {

    // MARK: - Errors

    enum PDFExportError: Error, LocalizedError {
        case loadFailed(String)
        case renderFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .loadFailed(let detail):
                return "PDF export failed during HTML load: \(detail)"
            case .renderFailed(let detail):
                return "PDF export failed during render: \(detail)"
            case .timeout:
                return "PDF export timed out waiting for WKWebView to finish loading."
            }
        }
    }

    // MARK: - Public API

    /// Export an HTML string to a PDF file at `outputURL`.
    ///
    /// - Parameters:
    ///   - htmlString: Complete HTML document content.
    ///   - outputURL: Destination file URL. Parent directory is created if absent.
    ///   - paperSize: PDF page size in points. Defaults to US Letter (8.5×11 in at 72 dpi).
    static func export(
        htmlString: String,
        to outputURL: URL,
        paperSize: CGSize = CGSize(width: 612, height: 792)
    ) async throws {
        let coordinator = Coordinator(paperSize: paperSize)
        let prepared = preparedHTMLForPDF(htmlString)
        let data = try await coordinator.render(htmlString: prepared, baseURL: nil)
        try writePDF(data: data, to: outputURL)
    }

    /// Export HTML from a file URL to a PDF file at `outputURL`.
    ///
    /// - Parameters:
    ///   - htmlURL: Source `.html` file URL.
    ///   - outputURL: Destination file URL. Parent directory is created if absent.
    ///   - paperSize: PDF page size in points. Defaults to US Letter.
    static func export(
        htmlURL: URL,
        to outputURL: URL,
        paperSize: CGSize = CGSize(width: 612, height: 792)
    ) async throws {
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let coordinator = Coordinator(paperSize: paperSize)
        // P9-A-04: do not pass `baseURL: htmlURL`. With JS disabled the WKWebView
        // does not need to resolve same-origin asset paths from the source file,
        // and a `baseURL` lets the renderer attempt subresource loads (favicon,
        // CSS imports) against the user's filesystem. Fail closed instead.
        let prepared = preparedHTMLForPDF(html)
        let data = try await coordinator.render(htmlString: prepared, baseURL: nil)
        try writePDF(data: data, to: outputURL)
    }

    // MARK: - Private helpers

    /// P9-A-04: inject a CSS rule that hides Chart.js canvases (which require JS)
    /// and shows a plain-text fallback in their place. The HTML report still
    /// renders charts in the browser; only the PDF render replaces them with the
    /// fallback. Done as a string transform (not a DOM rewrite) so we keep the
    /// renderer fully synchronous and JS-free.
    static func preparedHTMLForPDF(_ html: String) -> String {
        let injection = """
        <style>
        /* PDF safety: JavaScript is disabled in the PDF renderer (P9-A-04),
           so Chart.js canvases stay blank. Replace them with a fallback note. */
        .chart-container canvas, .chart-card canvas { display: none !important; }
        .chart-card::after, .chart-container::after {
          content: "Chart unavailable in PDF — see HTML report.";
          display: block; padding: 1.5rem 1rem; text-align: center;
          color: #555; font-style: italic; font-size: 0.9rem;
        }
        </style>
        """
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: headEnd, with: injection + "</head>")
        }
        // No <head>: prepend a minimal head so the rule still applies.
        return "<head>\(injection)</head>" + html
    }

    private static func writePDF(data: Data, to outputURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }
}

// MARK: - Coordinator

/// Internal actor that owns the WKWebView lifecycle for a single export operation.
///
/// The webview must be retained for the full load+render cycle; storing it as a
/// property here prevents it from being deallocated while the continuation is live.
@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate {

    private let paperSize: CGSize
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?

    // 10-second guard against WKWebView load hangs (e.g., CDN fetch in a test context).
    private var timeoutTask: Task<Void, Never>?

    init(paperSize: CGSize) {
        self.paperSize = paperSize
    }

    /// Load `htmlString` and produce PDF data via `WKWebView.createPDF`.
    func render(htmlString: String, baseURL: URL?) async throws -> Data {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: PDFExporter.PDFExportError.renderFailed("coordinator deallocated"))
                return
            }
            self.continuation = continuation

            // P9-A-04: harden the renderer against script execution and
            // arbitrary subresource loads. The PDF surface only needs to
            // rasterize static HTML/CSS — it does not need to execute any
            // JavaScript or fetch any remote assets. Disable JS at both the
            // legacy preferences level and the modern per-page preferences,
            // and refuse every URL scheme except `about:` and `data:` so a
            // malicious HTML payload cannot trigger network or filesystem reads.
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = false
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences = prefs
            // Navigation delegate cancels every navigation other than the
            // initial loadHTMLString (about:blank). Combined with JS disabled
            // and a nil baseURL, this prevents the renderer from issuing any
            // network or filesystem requests.
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                               configuration: config)
            wv.navigationDelegate = self
            self.webView = wv

            // Arm timeout before kicking off load.
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.failWithTimeout()
            }

            wv.loadHTMLString(htmlString, baseURL: baseURL)
        }
    }

    private func failWithTimeout() {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(throwing: PDFExporter.PDFExportError.timeout)
    }

    // MARK: - WKNavigationDelegate

    /// P9-A-04: allow only the initial `loadHTMLString` navigation. Any other
    /// navigation (HTTP fetch, file:// load, redirect chain) is cancelled. The
    /// initial load shows up with `navigationType == .other` and a URL of
    /// `about:blank` because no `baseURL` is set.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme.isEmpty {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Cancel timeout and take sole ownership of the continuation before invoking
        // createPDF. This prevents the timeout Task from resuming the continuation a
        // second time if createPDF takes longer than expected.
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let captured = continuation else { return }
        self.continuation = nil

        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = CGRect(origin: .zero, size: paperSize)

        webView.createPDF(configuration: pdfConfig) { [weak self] result in
            self?.webView?.navigationDelegate = nil
            self?.webView = nil
            switch result {
            case .success(let data):
                captured.resume(returning: data)
            case .failure(let error):
                captured.resume(throwing: PDFExporter.PDFExportError.renderFailed(error.localizedDescription))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let captured = continuation else { return }
        self.continuation = nil
        webView.navigationDelegate = nil
        self.webView = nil
        captured.resume(throwing: PDFExporter.PDFExportError.loadFailed(error.localizedDescription))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let captured = continuation else { return }
        self.continuation = nil
        webView.navigationDelegate = nil
        self.webView = nil
        captured.resume(throwing: PDFExporter.PDFExportError.loadFailed(error.localizedDescription))
    }
}
