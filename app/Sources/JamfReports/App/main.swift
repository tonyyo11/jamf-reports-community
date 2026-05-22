import Foundation
import SwiftUI

// MARK: - Headless scheduled-run dispatch
//
// When the LaunchAgent invokes the app with --scheduled-run --profile <slug>,
// run collect + generate synchronously via a detached Task and exit without
// launching the GUI. This replaces the former jamf-cli-only ProgramArguments
// that only collected data and never ran generate.
//
// When --all-profiles is also present, discover all local profiles via
// ProfileService.discoverLocal() and run the cycle for each in sequence.

@Sendable
private func scheduledRunSingle(
    profile: String,
    mode: Schedule.RunMode,
    tiers: Set<CollectionTier>?,
    verbose: Bool
) async -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(profile)'\n", stderr)
        return 1
    }
    guard let workspace = ProfileService.workspaceURL(for: profile) else {
        fputs("[error] No workspace for profile '\(profile)'\n", stderr)
        return 1
    }

    let onLine: @Sendable (CLIBridge.LogLine) -> Void = { line in
        if verbose || line.level != .info {
            print(line.text)
        }
    }

    // PR-21: csv-assisted hard-fails when csv-inbox/ is empty. Resolve up
    // front so we don't run an expensive collect just to fail at generate.
    let resolvedCSV: URL?
    if mode == .csvAssisted {
        guard let csv = CLIBridge.newestCSV(in: profile) else {
            fputs("[error] csv-assisted requires a CSV in csv-inbox/ — none found for '\(profile)'\n", stderr)
            return 1
        }
        resolvedCSV = csv
    } else if mode == .jamfCLIFull {
        resolvedCSV = nil  // jamf-cli-full is the no-CSV path
    } else {
        resolvedCSV = nil
    }

    do {
        // jamf-cli-only generates from cache only — no collect, no fresh API calls.
        // The other three modes all need fresh snapshots.
        if mode != .jamfCLIOnly {
            // PR-23 T-20: the schedule's plist pins the tier set via
            // --tiers. When present, it wins — it's the operator's choice
            // (or the form's mode-derived default). When absent (pre-PR-23
            // plists, or any caller that doesn't pass tiers), fall back to
            // the mode default: snapshot-only → Refresh only (PR-22 T-10),
            // the generate modes → all tiers.
            let resolvedTiers = tiers ?? mode.defaultTiers
            try await ReportEngine.collect(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                tiers: resolvedTiers,
                onLine: onLine
            )
        }
        // snapshot-only stops after collect; summary.json is already written.
        if mode == .snapshotOnly {
            print("[ok] scheduled snapshot complete for '\(profile)' — Trends updated")
            return 0
        }

        let configURL = workspace.appendingPathComponent("config.yaml")
        let config = try ConfigLoader.load(from: configURL)
        let dataDir = try WorkspacePaths.dataDir(for: profile)
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outputURL = engine.resolveOutputURL(stem: "report", profile: profile)
        try await engine.generate(csvURL: resolvedCSV, outputURL: outputURL)
        print("[ok] scheduled run complete for '\(profile)': \(outputURL.lastPathComponent)")
        return 0
    } catch {
        fputs("[error] '\(profile)': \(error.localizedDescription)\n", stderr)
        return 1
    }
}

@Sendable
private func scheduledRun(profile: String) async -> Int32 {
    let args = CommandLine.arguments
    let verbose = args.contains("--verbose")
    let allProfiles = args.contains("--all-profiles")
    // Legacy plists (pre-PR-20) omit --mode; fall back to jamf-cli-only so the
    // existing behavior (collect + generate, no CSV) is preserved verbatim.
    let mode: Schedule.RunMode = {
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count else {
            return .jamfCLIOnly
        }
        return Schedule.RunMode(rawValue: args[idx + 1]) ?? .jamfCLIOnly
    }()

    // PR-23 T-20: --tiers <csv> pins the collect tier set. Absent (pre-PR-23
    // plists) → nil, and scheduledRunSingle falls back to the mode default.
    // Unknown tokens are dropped; an all-unknown CSV resolves to nil.
    let tiers: Set<CollectionTier>? = {
        guard let idx = args.firstIndex(of: "--tiers"), idx + 1 < args.count else {
            return nil
        }
        var parsed: Set<CollectionTier> = []
        for token in args[idx + 1].split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tier = CollectionTier(rawValue: trimmed) { parsed.insert(tier) }
        }
        return parsed.isEmpty ? nil : parsed
    }()

    if allProfiles {
        let profiles = ProfileService.discoverLocal()
        guard !profiles.isEmpty else {
            fputs("[error] --all-profiles: no local profiles found\n", stderr)
            return 1
        }
        var anyFailed = false
        for p in profiles {
            let code = await scheduledRunSingle(
                profile: p.name, mode: mode, tiers: tiers, verbose: verbose
            )
            if code != 0 { anyFailed = true }
        }
        return anyFailed ? 1 : 0
    }

    return await scheduledRunSingle(
        profile: profile, mode: mode, tiers: tiers, verbose: verbose
    )
}

// MARK: - check subcommand

@Sendable
private func runCheck(profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(profile)'\n", stderr)
        return 1
    }
    guard let workspace = ProfileService.workspaceURL(for: profile) else {
        fputs("[error] No workspace for profile '\(profile)'\n", stderr)
        return 1
    }
    let configURL = workspace.appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        fputs("[error] config.yaml not found at \(configURL.path)\n", stderr)
        return 1
    }
    do {
        let config = try ConfigLoader.load(from: configURL)
        let cliProfile = config.jamfCli?.resolvedProfile ?? profile
        print("[ok] config.yaml decoded successfully")
        print("[ok] jamf_cli.profile: \(cliProfile.isEmpty ? "(not set)" : cliProfile)")
        let dataDir = (try? WorkspacePaths.dataDir(for: profile)) ?? workspace
            .appendingPathComponent("jamf-cli-data")
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDir) {
            print("[warn] data_dir does not exist yet (no collect run): \(dataDir.path)")
        } else if !isDir.boolValue {
            fputs("[warn] data_dir path exists but is not a directory: \(dataDir.path)\n", stderr)
        } else {
            do {
                let snapshotCount = try FileManager.default.contentsOfDirectory(atPath: dataDir.path).count
                print("[ok] cached snapshots in data_dir: \(snapshotCount)")
            } catch {
                fputs("[warn] could not read data_dir: \(error.localizedDescription)\n", stderr)
            }
        }
        return 0
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
    }
}

// MARK: - school-check subcommand

@Sendable
private func runSchoolCheck(profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(profile)'\n", stderr)
        return 1
    }
    guard let workspace = ProfileService.workspaceURL(for: profile) else {
        fputs("[error] No workspace for profile '\(profile)'\n", stderr)
        return 1
    }
    let configURL = workspace.appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        fputs("[error] config.yaml not found at \(configURL.path)\n", stderr)
        return 1
    }
    do {
        _ = try ConfigLoader.load(from: configURL)
        print("[ok] config.yaml decoded successfully")
        let schoolSnapshotKinds = [
            "school-overview", "school-devices", "school-device-groups",
            "school-users", "school-classes", "school-apps",
            "school-profiles", "school-locations",
        ]
        if let dataDir = try? WorkspacePaths.dataDir(for: profile) {
            let fm = FileManager.default
            for kind in schoolSnapshotKinds {
                let kindDir = dataDir.appendingPathComponent(kind)
                let exists = fm.fileExists(atPath: kindDir.path)
                print("[\(exists ? "ok" : "miss")] snapshot \(kind): \(exists ? "present" : "missing")")
            }
        }
        return 0
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
    }
}

// MARK: - school-scaffold subcommand

private func runSchoolScaffold(csvPath: String, outPath: String) -> Int32 {
    let csvURL = URL(fileURLWithPath: csvPath)
    let outURL = URL(fileURLWithPath: outPath)
    guard FileManager.default.fileExists(atPath: csvURL.path) else {
        fputs("[error] CSV not found: \(csvPath)\n", stderr)
        return 1
    }
    guard let data = try? Data(contentsOf: csvURL),
          let text = String(data: data, encoding: .utf8) else {
        fputs("[error] Could not read CSV: \(csvPath)\n", stderr)
        return 1
    }
    // Parse header row (comma or semicolon delimited, matching Python _school_csv_load).
    let firstLine = text.components(separatedBy: "\n").first ?? ""
    let delimiter: Character = firstLine.contains(";") ? ";" : ","
    let headers = firstLine.components(separatedBy: String(delimiter))
        .map { $0.trimmingCharacters(in: .init(charactersIn: "\r\"\u{feff}")) }

    let mappings = schoolScaffoldMappings(from: headers)

    var lines = ["# config.yaml — Jamf School columns (appended by school-scaffold)", "school_columns:"]
    let orderedKeys = [
        "device_name", "serial_number", "operating_system", "last_checkin",
        "model", "managed", "supervised", "username", "email",
        "device_family", "asset_tag", "location",
    ]
    for key in orderedKeys {
        let value = mappings[key] ?? ""
        lines.append("  \(key): \"\(value)\"")
    }
    lines.append("")

    do {
        let fm = FileManager.default
        if fm.fileExists(atPath: outURL.path),
           let existing = try? String(contentsOf: outURL, encoding: .utf8) {
            let appended = existing.hasSuffix("\n") ? existing + lines.joined(separator: "\n")
                : existing + "\n" + lines.joined(separator: "\n")
            try appended.write(to: outURL, atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        }
        print("[ok] school_columns written to \(outURL.lastPathComponent)")
        return 0
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
    }
}

/// Fuzzy-match CSV headers to Jamf School logical field names.
/// Mirrors Python's `SCHOOL_COLUMN_HINTS` / `SCHOOL_COLUMN_EXCLUDES` logic.
private func schoolScaffoldMappings(from headers: [String]) -> [String: String] {
    // Each entry: logical key → hint substrings (case-insensitive contains).
    let hints: [String: [String]] = [
        "device_name":      ["device name", "name"],
        "serial_number":    ["serial"],
        "operating_system": ["operating system", "os version", "ios version", "ipados"],
        "last_checkin":     ["last check", "last inventory", "last contact", "last seen"],
        "model":            ["model"],
        "managed":          ["managed"],
        "supervised":       ["supervised"],
        "username":         ["username", "user name", "assigned user"],
        "email":            ["email"],
        "device_family":    ["device family", "device type", "type"],
        "asset_tag":        ["asset tag", "asset"],
        "location":         ["location"],
    ]
    // Substrings that must NOT match even if the hint fires.
    let excludes: [String: [String]] = [
        "device_name":  ["model", "type", "family"],
        "model":        ["model name"],
        "last_checkin": ["enrollment"],
    ]
    let lower = headers.map { $0.lowercased() }
    var result: [String: String] = [:]
    for (key, hintList) in hints {
        for hint in hintList {
            guard let idx = lower.firstIndex(where: { $0.contains(hint) }) else { continue }
            let candidate = lower[idx]
            let blocked = (excludes[key] ?? []).contains { candidate.contains($0) }
            if !blocked {
                result[key] = headers[idx]
                break
            }
        }
    }
    return result
}

// MARK: - Entry point

// Install uncaught-exception handler before any UI or CLI work. Crash logs land at
// ~/Library/Logs/JamfReports/crash_<timestamp>.log.
CrashReporter.install()

let cliArgs = CommandLine.arguments
if cliArgs.contains("--scheduled-run"),
   let profileIdx = cliArgs.firstIndex(of: "--profile"),
   profileIdx + 1 < cliArgs.count {
    let profile = cliArgs[profileIdx + 1]
    let code = Task.detached { await scheduledRun(profile: profile) }
    let exitCode = await code.value
    exit(exitCode)
} else if cliArgs.contains("check"),
          let profileIdx = cliArgs.firstIndex(of: "--profile"),
          profileIdx + 1 < cliArgs.count {
    let profile = cliArgs[profileIdx + 1]
    exit(runCheck(profile: profile))
} else if cliArgs.contains("school-check"),
          let profileIdx = cliArgs.firstIndex(of: "--profile"),
          profileIdx + 1 < cliArgs.count {
    let profile = cliArgs[profileIdx + 1]
    exit(runSchoolCheck(profile: profile))
} else if cliArgs.contains("school-scaffold"),
          let csvIdx = cliArgs.firstIndex(of: "--csv"),
          let outIdx = cliArgs.firstIndex(of: "--out"),
          csvIdx + 1 < cliArgs.count,
          outIdx + 1 < cliArgs.count {
    let csv = cliArgs[csvIdx + 1]
    let out = cliArgs[outIdx + 1]
    exit(runSchoolScaffold(csvPath: csv, outPath: out))
} else {
    JamfReportsApp.main()
}
