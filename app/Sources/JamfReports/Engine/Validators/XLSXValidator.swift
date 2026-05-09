import Foundation
import ZIPFoundation

// MARK: - XLSXValidator

/// Validates a generated `.xlsx` file for structural integrity.
///
/// Checks performed:
/// - File is a valid ZIP archive (OOXML is a ZIP container).
/// - Required OOXML entries exist: `[Content_Types].xml`, `xl/workbook.xml`,
///   at least one `xl/worksheets/sheet*.xml`.
/// - Sheet count ≥ 1.
/// - Each sheet has ≥ 1 row element.
/// - No cells contain Excel error literals: `#REF!`, `#NAME?`, `#DIV/0!`,
///   `#VALUE!`, `#NULL!`, `#N/A`.
public struct XLSXValidator: Sendable {

    public init() {}

    /// Validate the XLSX file at `url`.
    ///
    /// - Parameter url: Path to a `.xlsx` file.
    /// - Returns: A `ValidationReport`.
    /// - Throws: `XLSXValidatorError` when the file cannot be opened.
    public func validate(at url: URL) throws -> ValidationReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XLSXValidatorError.notFound(url.path)
        }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw XLSXValidatorError.notZIP(url.path)
        }

        var issues: [ValidationReport.Issue] = []
        var warnings: [String] = []

        // 1. Required top-level entries.
        let required = ["[Content_Types].xml", "xl/workbook.xml"]
        for entry in required {
            if archive[entry] == nil {
                issues.append(.init(
                    severity: .error,
                    message: "Missing required OOXML entry: \(entry)",
                    location: entry
                ))
            }
        }

        // 2. Enumerate worksheet entries.
        var sheetEntries: [String] = []
        for entry in archive {
            let name = entry.path
            if name.hasPrefix("xl/worksheets/") && name.hasSuffix(".xml") {
                sheetEntries.append(name)
            }
        }

        if sheetEntries.isEmpty {
            issues.append(.init(
                severity: .error,
                message: "No worksheet entries found (xl/worksheets/sheet*.xml)",
                location: "xl/worksheets/"
            ))
        }

        // 3. Check each sheet for ≥ 1 row and absence of error literals.
        let errorLiterals = ["#REF!", "#NAME?", "#DIV/0!", "#VALUE!", "#NULL!", "#N/A"]
        for sheetPath in sheetEntries {
            guard let entry = archive[sheetPath] else { continue }
            var xmlData = Data()
            do {
                _ = try archive.extract(entry) { chunk in xmlData.append(chunk) }
            } catch {
                warnings.append("Could not extract \(sheetPath): \(error.localizedDescription)")
                continue
            }

            guard let xml = String(data: xmlData, encoding: .utf8) else {
                warnings.append("Non-UTF8 content in \(sheetPath)")
                continue
            }

            // Row count — check for at least one <row element between <sheetData> and </sheetData>.
            // NSRegularExpression with multiline flag handles large sheets split across lines.
            let hasRow: Bool = {
                let pattern = "<sheetData>[\\s\\S]*?<row[\\s>][\\s\\S]*?</sheetData>"
                guard let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive]
                ) else { return false }
                let nsRange = NSRange(xml.startIndex..., in: xml)
                return regex.firstMatch(in: xml, range: nsRange) != nil
            }()
            if !hasRow {
                issues.append(.init(
                    severity: .error,
                    message: "Sheet '\(sheetPath)' contains no rows",
                    location: sheetPath
                ))
            }

            // Error literal scan.
            for literal in errorLiterals {
                if xml.contains(literal) {
                    issues.append(.init(
                        severity: .error,
                        message: "Sheet '\(sheetPath)' contains error literal '\(literal)'",
                        location: sheetPath
                    ))
                }
            }
        }

        let isValid = issues.filter { $0.severity == .error }.isEmpty
        return ValidationReport(isValid: isValid, issues: issues, warnings: warnings)
    }
}

// MARK: - Errors

public enum XLSXValidatorError: Error, LocalizedError {
    case notFound(String)
    case notZIP(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "File not found: \(path)"
        case .notZIP(let path): return "File is not a valid ZIP/XLSX archive: \(path)"
        }
    }
}
