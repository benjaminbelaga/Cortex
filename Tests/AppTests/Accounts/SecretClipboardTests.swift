import AppKit
import Testing
@testable import Cortex

@Suite("Secret clipboard") @MainActor
struct SecretClipboardTests {
    private func tempPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("test.secret.clipboard.\(UUID().uuidString)"))
    }

    @Test func copyMarksConcealedAndClearsAfterDelay() async throws {
        let pasteboard = tempPasteboard()
        SecretClipboard.copy("fixture-secret", to: pasteboard, clearAfter: 0.05)
        #expect(pasteboard.string(forType: .string) == "fixture-secret")
        #expect(pasteboard.types?.contains(SecretClipboard.concealedType) == true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func anUnrelatedCopyKeepsTheNewValue() async throws {
        let pasteboard = tempPasteboard()
        SecretClipboard.copy("fixture-secret", to: pasteboard, clearAfter: 0.05)
        pasteboard.clearContents()
        pasteboard.setString("operator-value", forType: .string)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pasteboard.string(forType: .string) == "operator-value")
    }

    @Test func emptyValueIsIgnored() {
        let pasteboard = tempPasteboard()
        pasteboard.setString("keep-me", forType: .string)
        SecretClipboard.copy("", to: pasteboard, clearAfter: 60)
        #expect(pasteboard.string(forType: .string) == "keep-me")
    }
}
