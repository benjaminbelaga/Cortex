import Testing
import Foundation
@testable import Infrastructure

@Suite
struct TerminalThemeGeneratorTests {

    static let darkScheme = TerminalColorScheme(
        name: "Dracula",
        background: .init(red: 0.157, green: 0.165, blue: 0.212),
        foreground: .init(red: 0.973, green: 0.973, blue: 0.949),
        boldText: .init(red: 0.973, green: 0.973, blue: 0.949),
        cursor: .init(red: 0.973, green: 0.973, blue: 0.949),
        selection: .init(red: 0.267, green: 0.278, blue: 0.353),
        selectionText: .init(red: 1.0, green: 1.0, blue: 1.0),
        ansiColors: [
            .init(red: 0.129, green: 0.133, blue: 0.173),
            .init(red: 1.0, green: 0.333, blue: 0.333),
            .init(red: 0.314, green: 0.980, blue: 0.482),
            .init(red: 0.945, green: 0.980, blue: 0.549),
            .init(red: 0.741, green: 0.576, blue: 0.976),
            .init(red: 1.0, green: 0.475, blue: 0.776),
            .init(red: 0.545, green: 0.914, blue: 0.992),
            .init(red: 0.973, green: 0.973, blue: 0.949),
            .init(red: 0.384, green: 0.447, blue: 0.643),
            .init(red: 1.0, green: 0.431, blue: 0.431),
            .init(red: 0.412, green: 1.0, blue: 0.580),
            .init(red: 1.0, green: 1.0, blue: 0.647),
            .init(red: 0.839, green: 0.675, blue: 1.0),
            .init(red: 1.0, green: 0.573, blue: 0.875),
            .init(red: 0.643, green: 1.0, blue: 1.0),
            .init(red: 1.0, green: 1.0, blue: 1.0),
        ]
    )

    @Test func `generates theme properties from dark scheme`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(props.id == "imported-dracula")
        #expect(props.displayName == "Dracula")
        #expect(props.isDark)
    }

    @Test func `maps ANSI red to statusCritical`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(abs(props.statusCritical.red - 1.0) < 0.001)
        #expect(abs(props.statusCritical.green - 0.333) < 0.001)
    }

    @Test func `maps ANSI green to statusHealthy`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(abs(props.statusHealthy.red - 0.314) < 0.001)
        #expect(abs(props.statusHealthy.green - 0.980) < 0.001)
    }

    @Test func `maps ANSI yellow to statusWarning`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(abs(props.statusWarning.red - 0.945) < 0.001)
    }

    @Test func `maps ANSI cyan to accentPrimary`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(abs(props.accentPrimary.red - 0.545) < 0.001)
        #expect(abs(props.accentPrimary.green - 0.914) < 0.001)
    }

    @Test func `maps foreground to textPrimary`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(abs(props.textPrimary.red - 0.973) < 0.001)
    }

    @Test func `derives card background from background lightened`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(props.cardBackground.luminance > Self.darkScheme.background.luminance)
    }

    @Test func `uses selection for progressTrack when available`() {
        let props = TerminalThemeGenerator.generate(from: Self.darkScheme)
        #expect(abs(props.progressTrack.red - 0.267) < 0.001)
    }

    @Test func `handles scheme without optional colors`() {
        let scheme = TerminalColorScheme(
            name: "Minimal",
            background: .init(red: 0.0, green: 0.0, blue: 0.0),
            foreground: .init(red: 1.0, green: 1.0, blue: 1.0),
            boldText: nil,
            cursor: nil,
            selection: nil,
            selectionText: nil,
            ansiColors: (0..<16).map { _ in .init(red: 0.5, green: 0.5, blue: 0.5) }
        )
        let props = TerminalThemeGenerator.generate(from: scheme)
        #expect(abs(props.textPrimary.red - 1.0) < 0.001)
        #expect(props.progressTrack.luminance > scheme.background.luminance)
    }
}
