import Testing
@testable import Domain

struct APIKeyPasteParserTests {
    private let k1 = "oc_sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1"
    private let k2 = "oc_sBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2"

    @Test func parsesLabelledPairs() {
        let entries = APIKeyPasteParser.parse("Workspace objects\n\(k1)\n\nWorkspace interwave\n\(k2)\n")
        #expect(entries == [.init(label: "Objects", key: k1, providerHint: "opencode-go"),
                           .init(label: "Interwave", key: k2, providerHint: "opencode-go")])
    }

    @Test func loneKeyUsesFallbackLabel() {
        #expect(APIKeyPasteParser.parse(k1, fallbackLabel: "Studio") == [.init(label: "Studio", key: k1, providerHint: "opencode-go")])
    }

    @Test func loneKeyWithoutLabelIsIgnored() {
        #expect(APIKeyPasteParser.parse(k1).isEmpty)
    }

    @Test func proseAndMaskedKeysAreNotKeys() {
        #expect(APIKeyPasteParser.parse("Je colle ma clé ici\noc_s****masked****************").isEmpty)
    }

    // The RTF Ben pasted on 2026-09-25 (labels, blank lines, trailing spaces).
    // Synthetic fixture only — never a real key (gitleaks gate, rules fixture).
    private let ollamaKey = "00000000000000000000000000000000.abcdefghijklmnopqrst"

    @Test func parsesOllamaCloudKeyShape() {
        let entries = APIKeyPasteParser.parse("OLLAMA 2nd account \n\n\(ollamaKey)")
        #expect(entries == [.init(label: "OLLAMA 2nd account", key: ollamaKey, providerHint: "ollama")])
    }

    @Test func hintsByShape() {
        let text = "Workspace objects\n\(k1)\n\nOLLAMA 2nd account\n\(ollamaKey)"
        let entries = APIKeyPasteParser.parse(text)
        #expect(entries.map(\.providerHint) == ["opencode-go", "ollama"])
        #expect(entries.map(\.key) == [k1, ollamaKey])
    }

    @Test func genericSecretHasNoHint() {
        let entries = APIKeyPasteParser.parse("Mon secret\nsk-\(String(repeating: "a", count: 40))")
        #expect(entries.first?.providerHint == nil)
    }

    @Test func ollamaShapeEdgeCases() {
        // Wrong hex length, non-hex prefix, short body are all rejected.
        #expect(!APIKeyPasteParser.isOllamaCloudKey("000000000000000000000000000000000.abcdefghijklmnopqrst"))
        #expect(!APIKeyPasteParser.isOllamaCloudKey("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.abcdefghijklmnopqrst"))
        #expect(!APIKeyPasteParser.isOllamaCloudKey("00000000000000000000000000000000.short"))
        #expect(APIKeyPasteParser.isOllamaCloudKey(ollamaKey))
    }
}
