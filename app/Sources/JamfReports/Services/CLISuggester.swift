import Foundation

/// Pure helpers that suggest wizard defaults from jamf-cli tenant data.
///
/// All functions are `nonisolated` and pure — no I/O, no side effects.
/// Callers must provide the data (from cached jamf-cli results).
enum CLISuggester {

    struct ThresholdRecommendation: Sendable {
        let warning: Int
        let critical: Int
        let staleDays: Int
    }

    /// Suggest stale device threshold from device lastContact distribution.
    /// Uses median + 1.5 × MAD (Median Absolute Deviation), clamped 7–90 days.
    nonisolated static func suggestStaleDays(from devices: [DeviceInventoryRecord]) -> Int {
        let contactDays = devices.compactMap(\.daysSinceContact)
        guard !contactDays.isEmpty else { return 30 }

        let sorted = contactDays.sorted()
        let median = sorted[sorted.count / 2]

        // Calculate MAD: median of absolute deviations from median
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]

        // Median + 1.5 × MAD is a robust outlier threshold
        let suggested = median + Int(1.5 * Double(mad))

        // Clamp to reasonable bounds
        return max(7, min(90, suggested))
    }

    /// Filter EAs by template-relevant keywords and common patterns.
    nonisolated static func suggestEAs(
        from listing: [ExtensionAttribute],
        template: any ReportTemplate
    ) -> [ExtensionAttribute] {
        let keywords = TemplateApplier.eaKeywords(for: template)
        guard !keywords.isEmpty else { return listing }

        return listing.filter { ea in
            let name = (ea.name ?? "").lowercased()
            let desc = (ea.description ?? "").lowercased()
            let searchText = "\(name) \(desc)"

            // Match any template keyword
            return keywords.contains { keyword in
                searchText.contains(keyword.lowercased())
            }
        }
    }

    /// Get template-specific threshold defaults.
    nonisolated static func suggestThresholds(for template: any ReportTemplate) -> ThresholdRecommendation {
        let (warning, critical) = TemplateApplier.recommendedThresholds(for: template)
        let staleDays = TemplateApplier.recommendedStaleDays(for: template)

        return ThresholdRecommendation(
            warning: warning,
            critical: critical,
            staleDays: staleDays
        )
    }

    /// Score an EA for template relevance (0.0 = no match, 1.0 = perfect match).
    /// Used internally by suggestion algorithms.
    nonisolated private static func relevanceScore(
        for ea: ExtensionAttribute,
        template: any ReportTemplate
    ) -> Double {
        let keywords = TemplateApplier.eaKeywords(for: template)
        guard !keywords.isEmpty else { return 0.0 }

        let name = (ea.name ?? "").lowercased()
        let desc = (ea.description ?? "").lowercased()
        let searchText = "\(name) \(desc)"

        let matches = keywords.filter { keyword in
            searchText.contains(keyword.lowercased())
        }

        // Weight by match count and position (name matches score higher)
        var score = Double(matches.count) / Double(keywords.count)

        // Boost if keyword appears in name (more relevant than description)
        let nameMatches = keywords.filter { name.contains($0.lowercased()) }
        if !nameMatches.isEmpty {
            score += 0.3
        }

        return min(1.0, score)
    }

    // MARK: - Exceptions Suggestion

    /// Draft exception generated from audit findings for operator review.
    /// Not a ConfigException — this is a proposal the operator can accept/edit/reject.
    struct DraftException: Identifiable, Sendable, Equatable {
        let draftId: String
        let description: String
        let linkedFinding: String?
        let proposedSignedOffBy: String
        let proposedSignedOffDate: String
        let severity: String

        let id: UUID = UUID()

        static func == (lhs: DraftException, rhs: DraftException) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Suggest exceptions from audit findings for high/medium severity issues.
    /// Groups findings by category + rule_id and creates one draft per group.
    /// Only findings with severity `high` or `medium` qualify — low/info skipped.
    nonisolated static func suggestExceptions(
        from findings: [AuditFinding],
        operatorName: String
    ) -> [DraftException] {
        let qualifiedFindings = findings.filter { finding in
            let severity = finding.severity.lowercased()
            return severity == "high" || severity == "medium" || severity == "critical" || severity == "warning"
        }

        // Group by category + rule name (using driftKey which combines them)
        let grouped = Dictionary(grouping: qualifiedFindings) { $0.driftKey }

        let today = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayString = formatter.string(from: today)

        var drafts: [DraftException] = []
        var categoryCounters: [String: Int] = [:]

        // Sort by severity (desc), category (asc), name (asc)
        let sortedGroups = grouped.sorted { lhs, rhs in
            let lhsFinding = lhs.value.first!
            let rhsFinding = rhs.value.first!

            // Severity order: critical > high > warning > medium
            let severityOrder = ["critical": 0, "high": 1, "warning": 2, "medium": 3]
            let lhsOrder = severityOrder[lhsFinding.severity.lowercased()] ?? 99
            let rhsOrder = severityOrder[rhsFinding.severity.lowercased()] ?? 99

            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhsFinding.category != rhsFinding.category {
                return lhsFinding.category < rhsFinding.category
            }
            return lhsFinding.name < rhsFinding.name
        }

        for (_, findingsGroup) in sortedGroups {
            guard let representative = findingsGroup.first else { continue }

            let category = representative.category.trimmingCharacters(in: .whitespaces)
            let counter = categoryCounters[category, default: 0] + 1
            categoryCounters[category] = counter

            // Generate ID: <framework>-<rule_id>-<3-digit counter>
            let framework = category.uppercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .prefix(8)
            let ruleSuffix = representative.name
                .uppercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .prefix(8)
            let id = "\(framework)-\(ruleSuffix)-\(String(format: "%03d", counter))"

            // Truncate description to 240 chars with ellipsis
            let description: String
            let fullDesc = representative.recommendation.trimmingCharacters(in: .whitespaces)
            if fullDesc.count > 240 {
                description = String(fullDesc.prefix(237)) + "..."
            } else {
                description = fullDesc
            }

            // Linked finding is category.name format
            let linkedFinding = "\(representative.category).\(representative.name)"

            let draft = DraftException(
                draftId: id,
                description: description,
                linkedFinding: linkedFinding,
                proposedSignedOffBy: operatorName,
                proposedSignedOffDate: todayString,
                severity: representative.severity
            )
            drafts.append(draft)
        }

        return drafts
    }
}