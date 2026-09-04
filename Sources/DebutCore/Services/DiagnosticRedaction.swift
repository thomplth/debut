import CryptoKit
import Foundation

/// Replaces window titles with a salted digest wherever they would outlive the
/// session or leave the machine.
///
/// Titles carry document names, browser tabs and channel names. The reconciler
/// only ever compares them for equality (`RuntimeWindowReconciler.recoveryMatches`),
/// so a digest keeps every grouping question answerable while the text itself
/// stops accumulating.
public struct DiagnosticRedactor: Sendable {
    public static let plaintextKey = "windowTitle"
    public static let hashedKey = "windowTitleHash"

    private let salt: String

    public init(salt: String) {
        self.salt = salt
    }

    /// Titles are low-entropy enough to recover from an unsalted digest by
    /// guessing, so the salt is what makes this more than an obfuscation.
    public func hashedTitle(_ title: String) -> String {
        guard !title.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data("\(salt)\u{0}\(title)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    public func redact(_ details: [String: String]) -> [String: String] {
        guard let title = details[Self.plaintextKey] else { return details }
        var redacted = details
        redacted.removeValue(forKey: Self.plaintextKey)
        redacted[Self.hashedKey] = hashedTitle(title)
        return redacted
    }

    /// Walks an assembled export payload. The durable log is written already
    /// hashed, so `hashedKey` passes through untouched rather than being
    /// digested twice into something that no longer groups with the snapshot.
    public func redactJSONObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, value) in dictionary {
                if key == Self.plaintextKey, let title = value as? String {
                    redacted[Self.hashedKey] = hashedTitle(title)
                } else {
                    redacted[key] = redactJSONObject(value)
                }
            }
            return redacted
        }
        if let array = object as? [Any] {
            return array.map { redactJSONObject($0) }
        }
        return object
    }
}

/// The salt lives in defaults rather than beside the logs, because the exporter
/// ships `settings.json` and the whole diagnostic directory. A salt travelling
/// with the digests it protects would defeat them.
public enum DiagnosticSalt {
    public static let defaultsKey = "diagnosticTitleSalt"

    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}
