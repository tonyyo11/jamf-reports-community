import CryptoKit
import Foundation

extension SecurityControlPolicy {
    /// What decided FileVault's verdicts, so stored FileVault change counts say which rule
    /// they were taken under: 8 hex of SHA-256 of "level|on|off|hardware level".
    var fileVaultFingerprint: String {
        func values(_ set: Set<String>?) -> String { (set ?? []).sorted().joined(separator: ",") }
        let text = [level(for: .fileVault).rawValue, values(onValues[.fileVault]),
                    values(offValues[.fileVault]), fileVaultOffHardwareEncrypted?.rawValue ?? "-"]
            .joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }
}
