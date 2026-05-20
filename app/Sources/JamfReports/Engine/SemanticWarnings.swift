import Foundation

// MARK: - SemanticWarnings

/// Column-name sanity checks mirroring the Python `_semantic_warnings` function (line 2147).
///
/// Each check is independent. Returns a list of human-readable warning strings.
/// Empty list means no warnings.
enum SemanticWarnings {

    // MARK: - Public API

    /// Run all five semantic checks against the config and sample rows.
    ///
    /// - Parameters:
    ///   - config: Decoded report config.
    ///   - sampleRows: First 50 rows of the CSV (or fewer).
    /// - Returns: List of warning strings (may be empty).
    static func check(config: ReportConfig, sampleRows: [CSVRow]) -> [String] {
        var warnings: [String] = []
        checkManagerColumn(config: config, rows: sampleRows, into: &warnings)
        checkDiskPercentColumn(config: config, into: &warnings)
        checkSecureBootColumn(config: config, into: &warnings)
        checkBootstrapTokenColumn(config: config, into: &warnings)
        checkDateColumnsForFutureDates(config: config, rows: sampleRows, into: &warnings)
        return warnings
    }

    // MARK: - Check 1: manager column

    private static func checkManagerColumn(
        config: ReportConfig,
        rows: [CSVRow],
        into warnings: inout [String]
    ) {
        guard let colName = config.columns?.manager,
              !colName.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let normalized = colName.lowercased()
        // Match "Managed", "Management Status", etc. but not "Manager".
        let hasManagedVariant = normalized.contains("managed") || normalized.contains("management")
        if hasManagedVariant && !normalized.contains("manager") {
            warnings.append(
                "columns.manager points to a management-state column. " +
                "Use a real manager EA or leave it blank."
            )
            return
        }

        // Check sample values: if all non-empty values are "managed"/"unmanaged", warn.
        let sampleValues = rows.compactMap { $0[colName] }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(10)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        guard !sampleValues.isEmpty else { return }
        let managementValues: Set<String> = ["managed", "unmanaged"]
        if sampleValues.allSatisfy({ managementValues.contains($0) }) {
            warnings.append(
                "columns.manager sample values look like Jamf management status, not a person's manager."
            )
        }
    }

    // MARK: - Check 2: disk_percent_full

    private static func checkDiskPercentColumn(
        config: ReportConfig,
        into warnings: inout [String]
    ) {
        guard let colName = config.columns?.diskPercentFull,
              !colName.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let normalized = colName.lowercased()
        if normalized.contains("available mb") ||
           normalized.contains("capacity mb") ||
           normalized.contains("free mb") {
            warnings.append(
                "columns.disk_percent_full should point to a percentage-used column, " +
                "not MB available/capacity."
            )
        }
    }

    // MARK: - Check 3: secure_boot

    private static func checkSecureBootColumn(
        config: ReportConfig,
        into warnings: inout [String]
    ) {
        guard let colName = config.columns?.secureBoot,
              !colName.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if colName.lowercased().contains("external boot") {
            warnings.append(
                "columns.secure_boot points to External Boot Level. " +
                "Use Secure Boot Level instead."
            )
        }
    }

    // MARK: - Check 4: bootstrap_token

    private static func checkBootstrapTokenColumn(
        config: ReportConfig,
        into warnings: inout [String]
    ) {
        guard let colName = config.columns?.bootstrapToken,
              !colName.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if colName.lowercased().contains("allowed") {
            warnings.append(
                "columns.bootstrap_token points to Bootstrap Token Allowed. " +
                "Use Bootstrap Token Escrowed for compliance tracking."
            )
        }
    }

    // MARK: - Check 5: date columns with far-future values

    private static let futureLimitYears: Double = 20
    private static let secondsPerYear: Double = 365.25 * 24 * 3600

    private static func checkDateColumnsForFutureDates(
        config: ReportConfig,
        rows: [CSVRow],
        into warnings: inout [String]
    ) {
        let fields: [(String, String?)] = [
            ("mdm_expiry", config.columns?.mdmExpiry),
            ("last_enrollment", config.columns?.lastEnrollment),
            ("last_checkin", config.columns?.lastCheckin),
        ]
        let cutoff = Date().addingTimeInterval(futureLimitYears * secondsPerYear)
        let parser = DateParser()

        for (fieldName, colName) in fields {
            guard let colName, !colName.isEmpty else { continue }
            let sample = rows.compactMap { $0[colName] }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(30)
            var futureCount = 0
            for raw in sample {
                if let date = parser.parse(raw), date > cutoff {
                    futureCount += 1
                }
            }
            if futureCount > 0 {
                warnings.append(
                    "columns.\(fieldName) ('\(colName)') has \(futureCount) value(s) more than " +
                    "20 years in the future — verify the column mapping or check for data quality " +
                    "issues (clock drift, test devices)."
                )
            }
        }
    }
}
