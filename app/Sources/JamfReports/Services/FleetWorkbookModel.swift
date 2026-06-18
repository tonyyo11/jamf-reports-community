import Foundation

/// Pure aggregator behind the consolidated fleet **workbook** (v2.4.0). Mirrors
/// `FleetRollup` (pure) → `FleetWorkbookEmitter` (IO), but produces the richer
/// model the multi-sheet xlsx needs: the universal aggregate, per-profile rows,
/// baseline-grouped mSCP bands, and a date-aligned trend.
///
/// Aggregation honesty: universal KPIs (device count, FileVault/SIP/Firewall/
/// Gatekeeper/Patch/OS-Current %, Security Score) are device-weighted across
/// profiles via `FleetRollup`. Compliance % and mSCP bands are baseline-dependent
/// — they are NOT blended into the universal aggregate; bands are summed only
/// within a shared baseline (`bandGroups`), never across different frameworks.
struct FleetWorkbookModel: Sendable, Equatable {

    let groupName: String
    let generatedAt: String
    /// Universal aggregate from `FleetRollup` (compliance excluded by design).
    let universal: [FleetRollup.Metric]
    let perProfile: [ProfileRow]
    /// mSCP bands grouped by baseline name; summed only within a shared baseline.
    let bandGroups: [BandGroup]
    /// Universal KPIs aggregated by date across the group's profiles.
    let trend: [TrendPoint]

    struct ProfileRow: Sendable, Equatable {
        let profile: String
        let devices: Int
        let fileVaultPct, sipPct, firewallPct, gatekeeperPct: Double?
        let patchPct, osCurrentPct, securityScore: Double?
        let staleCount: Int?
        /// Baseline names this profile reports (sorted `mscpBands` keys).
        let baselineNames: [String]
        /// This profile's own (baseline-dependent) compliance %.
        let compliancePct: Double?
        /// This profile's own per-baseline band split.
        let bands: [String: MSCPBandCounts]
    }

    struct BandGroup: Sendable, Equatable, Identifiable {
        let baseline: String
        /// Member profiles whose latest summary reports this baseline.
        let profiles: [String]
        /// Band counts summed across members (same baseline only).
        let bands: MSCPBandCounts
        /// Device-weighted compliance % across members.
        let compliancePct: Double?
        /// Band-over-time across members; empty unless ≥2 distinct dates exist.
        let series: [BandPoint]
        var id: String { baseline }
    }

    struct BandPoint: Sendable, Equatable {
        let date: String
        let bands: MSCPBandCounts
    }

    struct TrendPoint: Sendable, Equatable {
        let date: String
        let devices: Int
        let fileVaultPct, sipPct, firewallPct, gatekeeperPct: Double?
        let patchPct, osCurrentPct, securityScore: Double?
    }

    /// Build the model from each profile's summary list (oldest→newest, as
    /// `SummaryJSONParser.parseDirectory` returns). nil when no member profile
    /// has any data — matching `FleetReportEmitter`'s no-workbook behavior.
    static func build(
        groupName: String,
        summariesByProfile: [(profile: String, summaries: [DailySummary])],
        lookbackDays: Int,
        timestamp: String
    ) -> FleetWorkbookModel? {
        let members = summariesByProfile.filter { !$0.summaries.isEmpty }
        guard !members.isEmpty else { return nil }

        let latest: [(profile: String, summary: DailySummary)] = members.compactMap {
            guard let last = $0.summaries.last else { return nil }
            return (profile: $0.profile, summary: last)
        }
        let current = latest.map(\.summary)
        let previous = members.compactMap {
            FleetReportEmitter.priorSummary($0.summaries, lookbackDays: lookbackDays)
        }
        let universal = FleetRollup.compute(
            groupName: groupName, current: current, previous: previous
        ).metrics

        return FleetWorkbookModel(
            groupName: groupName,
            generatedAt: timestamp,
            universal: universal,
            perProfile: latest.map { profileRow(profile: $0.profile, latest: $0.summary) },
            bandGroups: bandGroups(members),
            trend: trend(members)
        )
    }

    // MARK: - Per-profile rows

    private static func profileRow(profile: String, latest: DailySummary) -> ProfileRow {
        let bands = latest.mscpBands ?? [:]
        return ProfileRow(
            profile: profile,
            devices: latest.totalDevices,
            fileVaultPct: latest.fileVaultPct,
            sipPct: latest.sipPct,
            firewallPct: latest.firewallPct,
            gatekeeperPct: latest.gatekeeperPct,
            patchPct: latest.patchPct,
            osCurrentPct: latest.osCurrentPct,
            securityScore: latest.securityScore,
            staleCount: latest.staleCount,
            baselineNames: bands.keys.sorted(),
            compliancePct: latest.compliancePct,
            bands: bands
        )
    }

    // MARK: - Baseline-grouped bands

    private static func bandGroups(
        _ members: [(profile: String, summaries: [DailySummary])]
    ) -> [BandGroup] {
        var membersByBaseline: [String: [(profile: String, latest: DailySummary)]] = [:]
        for entry in members {
            guard let latest = entry.summaries.last, let bands = latest.mscpBands else { continue }
            for baseline in bands.keys {
                membersByBaseline[baseline, default: []].append((entry.profile, latest))
            }
        }
        return membersByBaseline.keys.sorted().map { baseline in
            let group = membersByBaseline[baseline] ?? []
            let summed = group.reduce(MSCPBandCounts.zero) {
                $0.adding($1.latest.mscpBands?[baseline] ?? .zero)
            }
            return BandGroup(
                baseline: baseline,
                profiles: group.map(\.profile).sorted(),
                bands: summed,
                compliancePct: FleetRollup.deviceWeighted(group.map(\.latest), \.compliancePct),
                series: bandSeries(baseline: baseline, members: members)
            )
        }
    }

    /// Summed band distribution per date across members reporting this baseline.
    /// Empty unless ≥2 distinct dates exist (a single point isn't a trend).
    private static func bandSeries(
        baseline: String, members: [(profile: String, summaries: [DailySummary])]
    ) -> [BandPoint] {
        var byDate: [String: MSCPBandCounts] = [:]
        for entry in members {
            for summary in entry.summaries {
                guard let band = summary.mscpBands?[baseline] else { continue }
                byDate[summary.date] = (byDate[summary.date] ?? .zero).adding(band)
            }
        }
        guard byDate.count >= 2 else { return [] }
        return byDate.keys.sorted().map { BandPoint(date: $0, bands: byDate[$0] ?? .zero) }
    }

    // MARK: - Trend

    private static func trend(
        _ members: [(profile: String, summaries: [DailySummary])]
    ) -> [TrendPoint] {
        var byDate: [String: [DailySummary]] = [:]
        for entry in members {
            for summary in entry.summaries {
                byDate[summary.date, default: []].append(summary)
            }
        }
        return byDate.keys.sorted().map { date in
            let onDate = byDate[date] ?? []
            return TrendPoint(
                date: date,
                devices: onDate.reduce(0) { $0 + $1.totalDevices },
                fileVaultPct: FleetRollup.deviceWeighted(onDate, \.fileVaultPct),
                sipPct: FleetRollup.deviceWeighted(onDate, \.sipPct),
                firewallPct: FleetRollup.deviceWeighted(onDate, \.firewallPct),
                gatekeeperPct: FleetRollup.deviceWeighted(onDate, \.gatekeeperPct),
                patchPct: FleetRollup.deviceWeighted(onDate, \.patchPct),
                osCurrentPct: FleetRollup.deviceWeighted(onDate, \.osCurrentPct),
                securityScore: FleetRollup.deviceWeighted(onDate, \.securityScore)
            )
        }
    }
}

extension MSCPBandCounts {
    static let zero = MSCPBandCounts(pass: 0, low: 0, medLow: 0, medium: 0, high: 0, noData: 0)

    func adding(_ other: MSCPBandCounts) -> MSCPBandCounts {
        MSCPBandCounts(
            pass: pass + other.pass, low: low + other.low, medLow: medLow + other.medLow,
            medium: medium + other.medium, high: high + other.high, noData: noData + other.noData
        )
    }
}
