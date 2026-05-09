import Foundation

// MARK: - PNGValidator

/// Validates a PNG image file for structural integrity and non-trivial content.
///
/// Checks performed:
/// - PNG signature bytes (`89 50 4E 47 0D 0A 1A 0A`).
/// - IHDR chunk: width × height both > 0 and ≤ 8192 each.
/// - File terminates with an IEND chunk.
/// - Total declared pixel count > 0 (rejects zero-size images).
public struct PNGValidator: Sendable {

    /// Maximum sane image dimension (8192 × 8192 = 64 MP).
    public static let maxDimension: UInt32 = 8192

    public init() {}

    /// Validate the PNG file at `url`.
    ///
    /// - Parameter url: Path to a `.png` file on disk.
    /// - Returns: A `ValidationReport`.
    /// - Throws: `PNGValidatorError` when the file cannot be read.
    public func validate(at url: URL) throws -> ValidationReport {
        guard let data = try? Data(contentsOf: url) else {
            throw PNGValidatorError.unreadable(url.path)
        }
        return validateData(data)
    }

    /// Validate raw PNG bytes — useful in tests without writing to disk.
    public func validateData(_ data: Data) -> ValidationReport {
        var issues: [ValidationReport.Issue] = []
        let warnings: [String] = []

        // 1. Signature check (8 bytes).
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 8 else {
            return ValidationReport(isValid: false, issues: [
                .init(severity: .error, message: "File too small to be a PNG (\(data.count) bytes)")
            ])
        }
        let header = [UInt8](data.prefix(8))
        if header != signature {
            issues.append(.init(
                severity: .error,
                message: "Invalid PNG signature",
                location: "offset 0"
            ))
            // If signature is wrong the rest of the parsing is unreliable.
            return ValidationReport(isValid: false, issues: issues, warnings: warnings)
        }

        // 2. IHDR chunk (must be first chunk after signature).
        // Structure: 4-byte length | 4-byte type | data | 4-byte CRC
        guard data.count >= 8 + 4 + 4 + 13 else {
            issues.append(.init(severity: .error, message: "File too small to contain IHDR chunk"))
            return ValidationReport(isValid: false, issues: issues, warnings: warnings)
        }
        let ihdrLength = readUInt32(data, offset: 8)
        let ihdrType = String(bytes: data[12..<16], encoding: .ascii) ?? ""
        if ihdrType != "IHDR" || ihdrLength < 13 {
            issues.append(.init(
                severity: .error,
                message: "First chunk is not IHDR (found '\(ihdrType)')",
                location: "offset 12"
            ))
        } else {
            let width = readUInt32(data, offset: 16)
            let height = readUInt32(data, offset: 20)

            if width == 0 || height == 0 {
                issues.append(.init(
                    severity: .error,
                    message: "IHDR declares zero dimension: \(width)×\(height)",
                    location: "IHDR"
                ))
            }
            if width > Self.maxDimension || height > Self.maxDimension {
                issues.append(.init(
                    severity: .error,
                    message: "IHDR dimension exceeds maximum (\(width)×\(height), max \(Self.maxDimension))",
                    location: "IHDR"
                ))
            }
            if width > 0 && height > 0 && width <= Self.maxDimension && height <= Self.maxDimension {
                // Pixel count sanity
                let pixels = UInt64(width) * UInt64(height)
                if pixels == 0 {
                    issues.append(.init(severity: .error, message: "Zero pixel count"))
                }
            }
        }

        // 3. IEND chunk must be present somewhere near the end.
        if !containsIEND(data) {
            issues.append(.init(
                severity: .error,
                message: "IEND chunk not found — file may be truncated",
                location: "EOF"
            ))
        }

        let isValid = issues.filter { $0.severity == .error }.isEmpty
        return ValidationReport(isValid: isValid, issues: issues, warnings: warnings)
    }

    // MARK: - Helpers

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private func containsIEND(_ data: Data) -> Bool {
        // Full 12-byte IEND chunk: 4-byte length (0x00000000) + type IEND + CRC 0xAE426082.
        // The CRC of an empty IEND data field is always 0xAE426082 per the PNG spec.
        let iendChunk: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,  // length = 0
            0x49, 0x45, 0x4E, 0x44,  // "IEND"
            0xAE, 0x42, 0x60, 0x82,  // CRC
        ]
        guard data.count >= 12 else { return false }
        // Scan last 256 bytes for efficiency; IEND is always at the very end.
        let scanStart = max(0, data.count - 256)
        let region = [UInt8](data[scanStart...])
        let target = iendChunk
        guard region.count >= 12 else { return false }
        for i in 0...(region.count - 12) {
            if region[i..<(i + 12)].elementsEqual(target) {
                return true
            }
        }
        return false
    }
}

// MARK: - Errors

public enum PNGValidatorError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Cannot read PNG file at \(path)"
        }
    }
}
