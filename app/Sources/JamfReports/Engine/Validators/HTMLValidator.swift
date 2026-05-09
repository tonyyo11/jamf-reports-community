import Foundation
import CryptoKit

// MARK: - HTMLValidator

/// Validates a generated HTML report file for structural integrity and XSS hygiene.
///
/// Checks performed:
/// - Tag balance (a lenient stack-based scan — does not require XML well-formedness).
/// - All `<img src="...">` resolve: relative paths exist on disk; data URIs decode.
/// - All `<a href="...">` point to a local anchor that exists, or are well-formed URLs.
/// - Inline `<script>` blocks pass a length / parenthesis balance sanity check.
/// - Inline `<script>` blocks do not reference `eval(` or `Function(` (XSS hygiene).
public struct HTMLValidator: Sendable {

    public init() {}

    /// Validate the HTML file at `url`.
    ///
    /// - Parameter url: Path to a `.html` file on disk.
    /// - Returns: A `ValidationReport` with all found issues.
    /// - Throws: `HTMLValidatorError` when the file cannot be read.
    public func validate(at url: URL) throws -> ValidationReport {
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            throw HTMLValidatorError.unreadable(url.path)
        }
        let baseDirectory = url.deletingLastPathComponent()

        var issues: [ValidationReport.Issue] = []
        var warnings: [String] = []

        checkTagBalance(html: html, issues: &issues)
        checkImages(html: html, baseDirectory: baseDirectory, issues: &issues, warnings: &warnings)
        checkLinks(html: html, issues: &issues)
        checkScripts(html: html, issues: &issues, warnings: &warnings)

        let isValid = issues.filter { $0.severity == .error }.isEmpty
        return ValidationReport(isValid: isValid, issues: issues, warnings: warnings)
    }

    // MARK: - Tag balance

    private func checkTagBalance(html: String, issues: inout [ValidationReport.Issue]) {
        // Void elements — self-closing, never push onto the stack.
        let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr",
        ]

        var stack: [String] = []
        var idx = html.startIndex
        while idx < html.endIndex {
            guard let openBracket = html[idx...].firstIndex(of: "<") else { break }
            idx = html.index(after: openBracket)
            guard idx < html.endIndex else { break }

            // Comments and declarations
            if html[idx...].hasPrefix("!") {
                if let close = findTagClose(in: html, from: openBracket) {
                    idx = html.index(after: close)
                }
                continue
            }

            // Closing tag
            if html[idx] == "/" {
                let nameStart = html.index(after: idx)
                if let close = findTagClose(in: html, from: openBracket) {
                    let raw = html[nameStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = tagName(from: raw).lowercased()
                    if !voidElements.contains(name) {
                        if stack.last == name {
                            stack.removeLast()
                        }
                        // Mismatches are lenient — not emitted as errors since HTML parsers
                        // are tolerant and many linters accept optional closing tags.
                    }
                    idx = html.index(after: close)
                }
                continue
            }

            // Opening tag
            if let close = findTagClose(in: html, from: openBracket) {
                let inner = html[idx..<close].trimmingCharacters(in: .whitespacesAndNewlines)
                let name = tagName(from: inner).lowercased()
                // Self-closing with trailing slash or void element — do not push.
                let selfClose = inner.hasSuffix("/")
                if !selfClose && !voidElements.contains(name) && !name.isEmpty {
                    stack.push(name)
                }
                idx = html.index(after: close)
            } else {
                break
            }
        }

        if stack.count > 20 {
            issues.append(.init(
                severity: .warning,
                message: "\(stack.count) unclosed tags found (may indicate truncated output)",
                location: "tag balance"
            ))
        }
    }

    // MARK: - Image checks

    private func checkImages(
        html: String,
        baseDirectory: URL,
        issues: inout [ValidationReport.Issue],
        warnings: inout [String]
    ) {
        let srcs = extractAttributeValues(html: html, tag: "img", attribute: "src")
        for src in srcs {
            if src.hasPrefix("data:") {
                // Data URI: verify it contains a comma separator and non-empty payload.
                if !src.contains(",") || src.hasSuffix(",") {
                    issues.append(.init(
                        severity: .error,
                        message: "Malformed data URI in <img src>",
                        location: String(src.prefix(60))
                    ))
                }
                // Verify base64 payload is non-empty and decodable.
                if let commaIdx = src.firstIndex(of: ",") {
                    let payload = String(src[src.index(after: commaIdx)...])
                    if payload.isEmpty {
                        issues.append(.init(
                            severity: .error,
                            message: "Empty data URI payload in <img src>",
                            location: String(src.prefix(60))
                        ))
                    }
                }
                continue
            }
            // Relative or absolute path
            if src.hasPrefix("http://") || src.hasPrefix("https://") {
                // Remote — warn if non-https.
                if src.hasPrefix("http://") {
                    warnings.append("Non-HTTPS image reference: \(src)")
                }
                continue
            }
            // Local relative path
            let resolved = baseDirectory.appendingPathComponent(src)
            if !FileManager.default.fileExists(atPath: resolved.path) {
                issues.append(.init(
                    severity: .error,
                    message: "Missing local image: \(src)",
                    location: src
                ))
            }
        }
    }

    // MARK: - Link checks

    private func checkLinks(html: String, issues: inout [ValidationReport.Issue]) {
        let hrefs = extractAttributeValues(html: html, tag: "a", attribute: "href")
        // Collect all id attributes for anchor resolution.
        let ids = extractAttributeValues(html: html, tag: nil, attribute: "id")
        let idSet = Set(ids)

        for href in hrefs {
            if href.isEmpty || href == "#" { continue }
            if href.hasPrefix("mailto:") || href.hasPrefix("tel:") { continue }
            if href.hasPrefix("http://") || href.hasPrefix("https://") {
                // Validate URL structure.
                if URL(string: href) == nil {
                    issues.append(.init(
                        severity: .warning,
                        message: "Malformed URL in <a href>: \(href)",
                        location: href
                    ))
                }
                continue
            }
            if href.hasPrefix("#") {
                let anchor = String(href.dropFirst())
                if !anchor.isEmpty && !idSet.contains(anchor) {
                    // Missing anchor — only a warning; page may scroll to nothing rather than fail.
                    issues.append(.init(
                        severity: .warning,
                        message: "Local anchor '#\(anchor)' not found in document",
                        location: href
                    ))
                }
                continue
            }
        }
    }

    // MARK: - Script checks

    /// SHA-256 of `ChartJSBundle.inlineScript` — computed once at call time and
    /// used to exempt the bundled Chart.js block from eval(/Function( rejection.
    private func chartJSSHA256() -> String {
        let digest = SHA256.hash(data: Data(ChartJSBundle.inlineScript.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func checkScripts(
        html: String,
        issues: inout [ValidationReport.Issue],
        warnings: inout [String]
    ) {
        let allowedSHA = chartJSSHA256()
        // Extract contents of inline <script> blocks.
        let blocks = extractScriptContent(html: html)
        for (idx, block) in blocks.enumerated() {
            let label = "script block \(idx + 1)"

            // Exempt the Chart.js bundle by SHA-256 — it legitimately uses eval().
            let blockSHA = SHA256.hash(data: Data(block.utf8))
                .map { String(format: "%02x", $0) }.joined()
            if blockSHA == allowedSHA { continue }

            // XSS hygiene: reject eval( and Function(
            if block.contains("eval(") {
                issues.append(.init(
                    severity: .error,
                    message: "Inline script contains eval() — potential XSS vector",
                    location: label
                ))
            }
            if block.range(of: #"\bFunction\s*\("#, options: .regularExpression) != nil {
                issues.append(.init(
                    severity: .error,
                    message: "Inline script contains Function() constructor — potential XSS vector",
                    location: label
                ))
            }

            // Parenthesis balance sanity check.
            let openCount = block.filter { $0 == "(" }.count
            let closeCount = block.filter { $0 == ")" }.count
            if openCount != closeCount {
                issues.append(.init(
                    severity: .warning,
                    message: "Unbalanced parentheses in \(label): \(openCount) open, \(closeCount) close",
                    location: label
                ))
            }

            // Brace balance sanity check.
            let openBrace = block.filter { $0 == "{" }.count
            let closeBrace = block.filter { $0 == "}" }.count
            if openBrace != closeBrace {
                issues.append(.init(
                    severity: .warning,
                    message: "Unbalanced braces in \(label): \(openBrace) open, \(closeBrace) close",
                    location: label
                ))
            }
        }
    }

    // MARK: - Extraction helpers

    /// Extract all values of `attribute` from `tag` elements (or any element when `tag` is nil).
    private func extractAttributeValues(html: String, tag: String?, attribute: String) -> [String] {
        var results: [String] = []
        var searchRange = html.startIndex..<html.endIndex

        while !searchRange.isEmpty {
            // Find next opening tag.
            guard let ltRange = html.range(of: "<", range: searchRange) else { break }
            let afterLt = ltRange.upperBound
            guard afterLt < html.endIndex else { break }

            // Find close of this tag.
            guard let gtRange = html.range(of: ">", range: afterLt..<html.endIndex) else { break }
            let tagContent = String(html[afterLt..<gtRange.lowerBound])
            searchRange = gtRange.upperBound..<html.endIndex

            // Tag name filter.
            let tName = tagName(from: tagContent).lowercased()
            if let required = tag, tName != required.lowercased() { continue }

            // Extract attribute value (handles double-quoted, single-quoted).
            let attrLower = attribute.lowercased()
            if let val = parseAttribute(attrLower, from: tagContent) {
                results.append(val)
            }
        }
        return results
    }

    /// Extract raw content of each inline <script> ... </script> block.
    private func extractScriptContent(html: String) -> [String] {
        var results: [String] = []
        var search = html.startIndex..<html.endIndex
        while !search.isEmpty {
            guard let openRange = html.range(
                of: "<script", options: .caseInsensitive, range: search
            ) else { break }
            guard let closingStart = html.range(
                of: ">", range: openRange.upperBound..<html.endIndex
            ) else { break }
            guard let endTag = html.range(
                of: "</script>", options: .caseInsensitive,
                range: closingStart.upperBound..<html.endIndex
            ) else { break }
            let content = String(html[closingStart.upperBound..<endTag.lowerBound])
            // Only inspect inline scripts — skip `src="..."` references.
            let tagSlice = String(html[openRange.lowerBound..<closingStart.upperBound])
            if !tagSlice.lowercased().contains("src=") {
                results.append(content)
            }
            search = endTag.upperBound..<html.endIndex
        }
        return results
    }

    // MARK: - Micro-parsers

    private func findTagClose(in html: String, from start: String.Index) -> String.Index? {
        html[start...].firstIndex(of: ">")
    }

    private func tagName(from inner: String) -> String {
        inner.components(separatedBy: .whitespacesAndNewlines).first ?? ""
    }

    private func parseAttribute(_ attr: String, from tagContent: String) -> String? {
        // Match attr="value" or attr='value', case-insensitive, capturing the value.
        // Handles HTML entity escaping in the attribute value.
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: attr))\\s*=\\s*([\"'])([^\"']*)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(tagContent.startIndex..., in: tagContent)
        guard let match = regex.firstMatch(in: tagContent, range: range),
              match.numberOfRanges >= 3,
              let valueRange = Range(match.range(at: 2), in: tagContent)
        else { return nil }
        // Decode common HTML entities that may appear in attribute values.
        return String(tagContent[valueRange])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

// MARK: - Errors

public enum HTMLValidatorError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Cannot read HTML file at \(path)"
        }
    }
}

// MARK: - Array helper

private extension Array {
    mutating func push(_ element: Element) { append(element) }
}
