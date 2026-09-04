import Foundation
import Testing
@testable import DebutCore

@Suite("DiagnosticRedaction")
struct DiagnosticRedactionTests {

    @Test("The same title under the same salt always hashes alike")
    func hashIsStable() {
        let redactor = DiagnosticRedactor(salt: "salt-a")
        #expect(redactor.hashedTitle("Inbox — Gmail") == redactor.hashedTitle("Inbox — Gmail"))
    }

    @Test("Different titles hash differently, so a log stays groupable")
    func distinctTitlesDiffer() {
        let redactor = DiagnosticRedactor(salt: "salt-a")
        #expect(redactor.hashedTitle("Inbox — Gmail") != redactor.hashedTitle("Drafts — Gmail"))
    }

    @Test("A per-install salt makes the same title unlinkable across installs")
    func saltSeparatesInstalls() {
        let a = DiagnosticRedactor(salt: "salt-a")
        let b = DiagnosticRedactor(salt: "salt-b")
        #expect(a.hashedTitle("Inbox — Gmail") != b.hashedTitle("Inbox — Gmail"))
    }

    @Test("An empty title stays empty rather than becoming a hash")
    func emptyTitleIsPreserved() {
        // "This window has no title" is diagnostic and carries nothing private,
        // so hashing it would only destroy a signal.
        #expect(DiagnosticRedactor(salt: "salt-a").hashedTitle("") == "")
    }

    @Test("Redacting details replaces the plaintext key outright")
    func detailsAreRedacted() {
        let redactor = DiagnosticRedactor(salt: "salt-a")
        let redacted = redactor.redact(["windowID": "42", "windowTitle": "Secret Plan.docx"])

        #expect(redacted["windowTitle"] == nil)
        #expect(redacted["windowID"] == "42")
        #expect(redacted["windowTitleHash"] == redactor.hashedTitle("Secret Plan.docx"))
    }

    @Test("Redaction reaches titles nested anywhere in an export payload")
    func nestedPayloadIsRedacted() {
        let redactor = DiagnosticRedactor(salt: "salt-a")
        let payload: [String: Any] = [
            "persisted": ["state": ["windows": [["windowTitle": "Secret Plan.docx"]]]],
            "runtime": ["windows": [["windowTitle": "Payroll.xlsx", "windowID": 7]]],
        ]

        let redacted = redactor.redactJSONObject(payload)
        let text = String(
            data: try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
            encoding: .utf8
        )!

        #expect(!text.contains("Secret Plan.docx"))
        #expect(!text.contains("Payroll.xlsx"))
        #expect(!text.contains("\"windowTitle\""))
        #expect(text.contains(redactor.hashedTitle("Secret Plan.docx")))
    }

    @Test("An already-hashed key is not hashed a second time")
    func hashedKeyPassesThrough() {
        // The durable log is written pre-hashed, so an export that walked it
        // again would double-hash and break grouping against the snapshot.
        let redactor = DiagnosticRedactor(salt: "salt-a")
        let hash = redactor.hashedTitle("Secret Plan.docx")
        let redacted = redactor.redactJSONObject(["windowTitleHash": hash]) as? [String: Any]

        #expect(redacted?["windowTitleHash"] as? String == hash)
    }

    @Test("The salt is generated once per install and then reused")
    func saltPersistsPerInstall() {
        let suiteName = "DebutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DiagnosticSalt.current(defaults: defaults)
        let second = DiagnosticSalt.current(defaults: defaults)

        #expect(!first.isEmpty)
        #expect(first == second)
    }
}
