import Foundation

/// Coordination for a workspace that more than one Mac writes to.
///
/// When a team points several machines at the same synced folder, two things
/// go wrong without help: both collect the same day's inventory (doubling API
/// load and racing to write the same summary), and each reports success for
/// work the other did. The guards here are:
///
/// - **Freshness.** Before a collect, if a *different* host already collected
///   inside the configured interval, skip and say who did it. Same-host repeats
///   stay governed by the existing once-per-day guard.
/// - **Claims.** A short advisory lease naming the host, operation and expiry,
///   so a second machine starting a long collect can see one already running.
///
/// **A claim is advisory, not a lock.** A sync provider propagates the file on
/// its own schedule, so two machines starting within seconds of each other can
/// both believe they hold it. That is tolerable because nothing downstream
/// depends on mutual exclusion for correctness: snapshot writes are additive
/// and uniquely stamped, and every reader orders by the timestamp in the
/// filename rather than by an mtime the provider rewrites. The claim exists to
/// stop the common case — two scheduled runs an hour apart, or an operator
/// hitting Refresh while a teammate's LaunchAgent is mid-collect.
enum SharedWorkspace {

    // MARK: - Host identity

    /// Identifies the machine that wrote something. Hostnames alone are not
    /// enough — they collide on imaged fleets and change when a user renames
    /// their Mac — so the stable hardware UUID is the identity and the name is
    /// only ever display text.
    struct Host: Codable, Sendable, Equatable {
        let id: String
        let name: String

        /// Short display form for logs and Doctor rows.
        var display: String { name.isEmpty ? String(id.prefix(8)) : name }
    }

    /// This machine. Resolved once; the hardware UUID does not change at runtime.
    static let currentHost: Host = {
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        let identifier: String
        if gethostuuid(&uuid, &timeout) == 0 {
            identifier = UUID(uuid: uuid).uuidString
        } else {
            // gethostuuid can fail under sandboxing. Fall back to the hostname
            // so coordination degrades to "named machines" rather than off.
            identifier = ProcessInfo.processInfo.hostName
        }
        return Host(id: identifier, name: ProcessInfo.processInfo.hostName)
    }()

    /// App version for the audit fields below.
    ///
    /// Deliberately reads Info.plist rather than `AppVersionState`, which is
    /// MainActor-isolated: claims and activity are written from the collect
    /// task, off the main actor. Falls back to "unknown" in test and CLI
    /// contexts where no bundle version exists.
    static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }()

    // MARK: - Claim

    /// A lease recorded at `<workspace>/automation/.workspace-claim.json`.
    struct Claim: Codable, Sendable, Equatable {
        let host: Host
        let operation: String
        let startedAt: Date
        let expiresAt: Date
        let pid: Int32
        let appVersion: String

        /// Expiry, bounded by how long a claim is ever allowed to last.
        ///
        /// `expiresAt` is read from a file anyone with folder access can write,
        /// so an `expiresAt` of 9999 would otherwise block every scheduled run
        /// on every other Mac forever. Honouring at most `maxTTL` past the
        /// recorded start keeps a bad or clock-skewed file self-healing.
        func effectiveExpiry(maxTTL: TimeInterval) -> Date {
            min(expiresAt, startedAt.addingTimeInterval(maxTTL))
        }

        func isExpired(at now: Date, maxTTL: TimeInterval = Claim.absoluteMaxTTL) -> Bool {
            effectiveExpiry(maxTTL: maxTTL) <= now
        }

        /// Ceiling on any claim, matching `SharedWorkspaceConfig.claimTTL`'s
        /// own upper clamp of 720 minutes.
        static let absoluteMaxTTL: TimeInterval = 720 * 60
    }

    enum ClaimDecision: Sendable, Equatable {
        /// No live claim, or the existing one is ours to refresh.
        case acquire
        /// Another host's lease lapsed; taking it over is how a crashed or
        /// powered-off machine stops blocking the folder forever.
        case takeOverExpired(Claim)
        /// Another host holds a live lease.
        case blocked(Claim)
    }

    /// Pure claim arbitration. `existing` is whatever is on disk (nil when the
    /// file is absent or unreadable — an unreadable claim must never block).
    static func decide(existing: Claim?, me: Host, now: Date) -> ClaimDecision {
        guard let existing else { return .acquire }
        if existing.host.id == me.id { return .acquire }
        if existing.isExpired(at: now) { return .takeOverExpired(existing) }
        return .blocked(existing)
    }

    // MARK: - Freshness

    /// What a collect should do given the last recorded collect in the folder.
    enum Freshness: Sendable, Equatable {
        case proceed
        /// A different host collected inside the interval. Carries the host and
        /// time so the caller can say *who*, which is the difference between a
        /// useful skip message and a confusing one.
        case skipCollectedElsewhere(host: Host, at: Date)
    }

    /// How far ahead of this machine another's timestamp may be and still be
    /// believed. Shared with `ConfigDoctorService`'s clock-skew row so the
    /// warning an operator reads matches the threshold the logic applies.
    static let clockSkewTolerance: TimeInterval = 300

    /// Decide whether to collect.
    ///
    /// Only *other* hosts gate here. A repeat on this machine is already
    /// handled by the once-per-day guard in `ReportEngine.collect`, and
    /// double-gating it would break `force: true` refreshes.
    static func freshness(
        lastCollectHost: Host?,
        lastCollectAt: Date?,
        me: Host,
        minInterval: TimeInterval,
        now: Date
    ) -> Freshness {
        guard minInterval > 0,
              let host = lastCollectHost,
              let at = lastCollectAt,
              host.id != me.id else {
            return .proceed
        }
        // A timestamp beyond ordinary clock skew is not usable data: we cannot
        // tell when that collect really happened, and a value far enough ahead
        // would otherwise read as "just collected" on every future run and stand
        // this Mac down permanently — an absence of runs, not a visible failure.
        //
        // So it fails toward collecting. A redundant collect costs one round of
        // API calls; never collecting costs the history. Config Doctor reports
        // the skew separately, using the same tolerance, so the operator learns
        // why their machine is collecting more than expected.
        //
        // Inside the tolerance the age is slightly negative, which is below any
        // positive interval and correctly reads as recent — no branch needed.
        guard at.timeIntervalSince(now) <= clockSkewTolerance else { return .proceed }
        guard now.timeIntervalSince(at) < minInterval else { return .proceed }
        return .skipCollectedElsewhere(host: host, at: at)
    }

    // MARK: - IO

    /// What one machine last did in this workspace.
    ///
    /// Recorded as `automation/hosts/<host-id>.json` — one file per machine,
    /// never a single shared file. Two Macs therefore never write the same
    /// path, so this state cannot generate the sync-conflict copies that a
    /// shared "last run" file would produce on every overlapping run.
    struct HostActivity: Codable, Sendable, Equatable {
        let host: Host
        var lastCollectAt: Date?
        var appVersion: String
    }

    private static let claimFilename = ".workspace-claim.json"

    private static func claimURL(profile: String) -> URL? {
        ProfileService.workspaceURL(for: profile)?
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent(claimFilename)
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()

    /// Largest coordination file worth reading. These structs serialise to a
    /// few hundred bytes; anything past this is corrupt or hostile, and the
    /// files live in a folder the design explicitly shares with other people.
    /// Mirrors the existing caps in `LaunchAgentService` and
    /// `DeviceInventoryService`.
    private static let maxCoordinationFileBytes = 64 * 1024

    /// Read a coordination file, refusing anything implausibly large.
    private static func readBounded(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxCoordinationFileBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Read the current claim. Returns nil when absent or unparseable — a
    /// corrupt claim must not wedge the folder shut.
    static func readClaim(profile: String) -> Claim? {
        guard let url = claimURL(profile: profile),
              let data = readBounded(url) else { return nil }
        return try? coder.decoder.decode(Claim.self, from: data)
    }

    /// Attempt to claim the workspace for `operation`.
    ///
    /// Returns the decision made. On `.acquire` / `.takeOverExpired` the claim
    /// file is rewritten to name this host; on `.blocked` nothing is written.
    /// A write failure is logged and reported as acquired: coordination is a
    /// convenience, and failing to write a lease must not stop an operator
    /// collecting their own fleet.
    @discardableResult
    static func acquire(
        profile: String,
        operation: String,
        ttl: TimeInterval,
        now: Date = Date()
    ) -> ClaimDecision {
        let decision = decide(existing: readClaim(profile: profile), me: currentHost, now: now)
        if case .blocked = decision { return decision }

        let claim = Claim(
            host: currentHost,
            operation: operation,
            startedAt: now,
            expiresAt: now.addingTimeInterval(max(60, ttl)),
            pid: ProcessInfo.processInfo.processIdentifier,
            appVersion: appVersion
        )
        write(claim, profile: profile)
        return decision
    }

    /// Drop this machine's claim. Never removes another host's — a run that
    /// was blocked and returned early must not clear the lease it respected.
    static func release(profile: String) {
        guard let url = claimURL(profile: profile) else { return }
        guard let existing = readClaim(profile: profile),
              existing.host.id == currentHost.id else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func write(_ claim: Claim, profile: String) {
        guard let url = claimURL(profile: profile) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try coder.encoder.encode(claim)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.collect.warning(
                "workspace claim not written: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Per-host activity

    private static func hostsDir(profile: String) -> URL? {
        ProfileService.workspaceURL(for: profile)?
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("hosts", isDirectory: true)
    }

    /// Filename-safe form of a host id. The hardware UUID is already safe; the
    /// hostname fallback is not (it can contain `/` in pathological cases).
    private static func fileStem(for host: Host) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = host.id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).lowercased()
    }

    /// Record that this machine collected successfully.
    /// Best-effort: a failure to write leaves coordination less informed but
    /// never fails the run that produced real data.
    static func recordActivity(profile: String, now: Date = Date()) {
        guard let dir = hostsDir(profile: profile) else { return }
        let url = dir.appendingPathComponent("\(fileStem(for: currentHost)).json")

        var activity = readBounded(url)
            .flatMap { try? coder.decoder.decode(HostActivity.self, from: $0) }
            ?? HostActivity(host: currentHost, lastCollectAt: nil, appVersion: appVersion)
        activity.lastCollectAt = now
        activity.appVersion = appVersion

        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try coder.encoder.encode(activity).write(to: url, options: .atomic)
        } catch {
            AppLogger.collect.warning(
                "host activity not recorded: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Machines other than this one that have written here.
    /// Unreadable entries are skipped rather than failing the scan.
    static func otherHosts(profile: String) -> [HostActivity] {
        guard let dir = hostsDir(profile: profile),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                readBounded(url)
                    .flatMap { try? coder.decoder.decode(HostActivity.self, from: $0) }
            }
            .filter { $0.host.id != currentHost.id }
    }

    /// The most recent collect by any machine other than this one.
    static func newestOtherCollect(profile: String) -> (host: Host, at: Date)? {
        otherHosts(profile: profile)
            .compactMap { activity in activity.lastCollectAt.map { (activity.host, $0) } }
            .max { $0.1 < $1.1 }
    }
}
