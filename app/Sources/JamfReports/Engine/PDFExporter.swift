import AppKit
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
                return "PDF export timed out while WKWebView loaded or printed the report."
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
        let data = try await coordinator.render(htmlString: htmlString, baseURL: nil)
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
        let data = try await coordinator.render(htmlString: html, baseURL: nil)
        try writePDF(data: data, to: outputURL)
    }

    // MARK: - Private helpers

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

/// Owns the WKWebView for one export: loads the HTML, then prints it to a PDF file through
/// WebKit's print operation, which paginates the whole document and applies the page's print
/// CSS and page breaks. (`createPDF` captures one rect, which held only the first page.)
///
/// The webview and its window must be retained for the full load and print cycle.
@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate {

    /// Margin on every side of a page: half an inch.
    static let pageMargin: CGFloat = 36
    static let loadTimeout: Duration = .seconds(10)
    static let printTimeout: Duration = .seconds(120)

    private let paperSize: CGSize
    private let printURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("jamf_report_print_\(UUID().uuidString).pdf")
    private var webView: WKWebView?
    /// WebKit runs a WKWebView print operation only modally for a window. It is never shown.
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(paperSize: CGSize) {
        self.paperSize = paperSize
    }

    /// Load `htmlString` and print it to PDF data.
    func render(htmlString: String, baseURL: URL?) async throws -> Data {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: PDFExporter.PDFExportError.renderFailed("coordinator deallocated"))
                return
            }
            self.continuation = continuation

            // P9-A-04: the PDF surface only rasterizes the report's own static
            // HTML/CSS, so JavaScript is off at the per-page preferences level
            // and the navigation delegate below cancels every navigation other
            // than the initial about:blank load. Subresource loads (an absolute
            // <img src> or CSS url()) are not navigations and are not filtered;
            // the report escapes every inserted value and loads nothing remote,
            // which is what keeps the renderer offline.
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = false
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences = prefs
            // The report's bars and severity pills are backgrounds, which printing leaves out
            // by default.
            config.preferences.shouldPrintBackgrounds = true
            // The delegate allows only `about:` (the initial loadHTMLString) and
            // cancels the rest; with JS off and a nil baseURL, nothing in the
            // report can navigate the view anywhere.
            let frame = CGRect(origin: .zero, size: paperSize)
            let wv = WKWebView(frame: frame, configuration: config)
            wv.navigationDelegate = self
            let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = wv
            self.webView = wv
            self.window = window

            self.arm(Self.loadTimeout)
            wv.loadHTMLString(htmlString, baseURL: baseURL)
        }
    }

    /// Fails the export with `.timeout` after `limit`, replacing any earlier limit.
    private func arm(_ limit: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(PDFExporter.PDFExportError.timeout))
        }
    }

    /// Resumes the caller once; a later call (a print finishing after its timeout) does nothing.
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
        try? FileManager.default.removeItem(at: printURL)
        continuation.resume(with: result)
    }

    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = paperSize
        info.topMargin = Self.pageMargin
        info.bottomMargin = Self.pageMargin
        info.leftMargin = Self.pageMargin
        info.rightMargin = Self.pageMargin
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = printURL
        return info
    }

    /// AppKit calls this on the print operation's own thread, not the main one.
    @objc private nonisolated func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in self?.printFinished(success: success) }
    }

    private func printFinished(success: Bool) {
        guard success else {
            finish(.failure(PDFExporter.PDFExportError.renderFailed(
                "the print operation did not complete")))
            return
        }
        do {
            finish(.success(try Data(contentsOf: printURL)))
        } catch {
            finish(.failure(PDFExporter.PDFExportError.renderFailed(
                "no PDF at \(printURL.lastPathComponent): \(error.localizedDescription)")))
        }
    }

    // MARK: - WKNavigationDelegate

    /// P9-A-04: allow only the initial `loadHTMLString` navigation. Any other
    /// navigation (HTTP fetch, file:// load, redirect chain) is cancelled. The
    /// initial load shows up with `navigationType == .other` and a URL of
    /// `about:blank` because no `baseURL` is set.
    ///
    /// Signature note: `WKNavigationDelegate`'s optional requirement is
    /// `@MainActor @Sendable` for the `decisionHandler` closure under
    /// Swift 6 strict concurrency. Match it exactly to silence the
    /// "nearly matches optional requirement" warning (S-05).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
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
        guard continuation != nil, let window else { return }
        arm(Self.printTimeout)
        let operation = webView.printOperation(with: printInfo())
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.runModal(
            for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(PDFExporter.PDFExportError.loadFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(PDFExporter.PDFExportError.loadFailed(error.localizedDescription)))
    }
}
