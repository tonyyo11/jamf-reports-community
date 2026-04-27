import Foundation

@MainActor
final class JamfCLIInstaller {
    private let bridge = CLIBridge()
    private var versionChecked = false
    private var cachedVersion: String?

    var isInstalled: Bool {
        bridge.locate("jamf-cli") != nil
    }

    var installedVersion: String? {
        if versionChecked { return cachedVersion }
        versionChecked = true

        cachedVersion = Self.installedVersion()
        return cachedVersion
    }

    static func installedPath() -> String? {
        ExecutableLocator.locate("jamf-cli")?.path
    }

    static func installedVersion() -> String? {
        guard let binary = ExecutableLocator.locate("jamf-cli") else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        let text = [
            String(data: out, encoding: .utf8),
            String(data: err, encoding: .utf8),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        return parseVersion(from: text)
    }

    func brewInstallCommand() -> String {
        "brew install macadmins/tap/jamf-cli"
    }

    private static func parseVersion(from text: String) -> String? {
        let pattern = #"\d+(?:\.\d+)+(?:[-+][A-Za-z0-9.]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let versionRange = Range(match.range, in: text)
        else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(text[versionRange])
    }
}
