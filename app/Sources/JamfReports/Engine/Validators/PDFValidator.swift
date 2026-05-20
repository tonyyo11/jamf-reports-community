import Foundation
import PDFKit

// MARK: - PDFValidator

/// Validates a generated `.pdf` file for structural integrity.
///
/// Checks performed:
/// - File begins with `%PDF-` header.
/// - File ends with `%%EOF` marker.
/// - `PDFKit.PDFDocument` opens the file successfully.
/// - Document contains ≥ 1 page.
public struct PDFValidator: Sendable {

    public init() {}

    /// Validate the PDF file at `url`.
    ///
    /// - Parameter url: Path to a `.pdf` file on disk.
    /// - Returns: A `ValidationReport`.
    /// - Throws: `PDFValidatorError` when the file cannot be read.
    public func validate(at url: URL) throws -> ValidationReport {
        guard let data = try? Data(contentsOf: url) else {
            throw PDFValidatorError.unreadable(url.path)
        }
        return validateData(data, url: url)
    }

    /// Validate raw PDF bytes — accepts a URL for PDFKit loading.
    func validateData(_ data: Data, url: URL?) -> ValidationReport {
        var issues: [ValidationReport.Issue] = []
        var warnings: [String] = []

        // 1. Header check.
        let headerBytes = [UInt8](data.prefix(5))
        let headerStr = String(bytes: headerBytes, encoding: .ascii) ?? ""
        if !headerStr.hasPrefix("%PDF-") {
            issues.append(.init(
                severity: .error,
                message: "File does not begin with '%PDF-' (found '\(headerStr)')",
                location: "offset 0"
            ))
        }

        // 2. EOF marker check.
        // Look in last 1024 bytes to allow for trailing whitespace / linearization.
        let tailStart = max(0, data.count - 1024)
        let tail = [UInt8](data[tailStart...])
        let tailStr = String(bytes: tail, encoding: .ascii) ?? ""
        if !tailStr.contains("%%EOF") {
            issues.append(.init(
                severity: .error,
                message: "%%EOF marker not found near end of file",
                location: "EOF"
            ))
        }

        // 3–4. PDFKit document load + page count.
        // Resolve a file URL — PDFDocument requires a file:// URL.
        let loadURL: URL
        if let provided = url {
            loadURL = provided
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdfvalidator_\(UUID().uuidString).pdf")
            try? data.write(to: tmp)
            loadURL = tmp
        }

        if let doc = PDFDocument(url: loadURL) {
            if doc.pageCount < 1 {
                issues.append(.init(
                    severity: .error,
                    message: "PDFKit reports 0 pages",
                    location: "document"
                ))
            }
            if doc.pageCount == 0 {
                warnings.append("PDF opened but contains no pages")
            }
        } else {
            issues.append(.init(
                severity: .error,
                message: "PDFKit could not open the document",
                location: loadURL.path
            ))
        }

        let isValid = issues.filter { $0.severity == .error }.isEmpty
        return ValidationReport(isValid: isValid, issues: issues, warnings: warnings)
    }
}

// MARK: - Errors

public enum PDFValidatorError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Cannot read PDF file at \(path)"
        }
    }
}
