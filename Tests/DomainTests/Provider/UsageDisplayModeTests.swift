import Testing
@testable import Domain

@Suite
struct UsageDisplayModeTests {

    // MARK: - Display Label

    @Test
    func `remaining mode has Remaining label`() {
        // Given
        let mode = UsageDisplayMode.remaining

        // When & Then
        #expect(mode.displayLabel == "Remaining")
    }

    @Test
    func `used mode has Used label`() {
        // Given
        let mode = UsageDisplayMode.used

        // When & Then
        #expect(mode.displayLabel == "Used")
    }

    // MARK: - Raw Value Persistence

    @Test
    func `remaining mode has remaining raw value`() {
        #expect(UsageDisplayMode.remaining.rawValue == "remaining")
    }

    @Test
    func `used mode has used raw value`() {
        #expect(UsageDisplayMode.used.rawValue == "used")
    }

    @Test
    func `can be created from raw value`() {
        #expect(UsageDisplayMode(rawValue: "remaining") == .remaining)
        #expect(UsageDisplayMode(rawValue: "used") == .used)
        #expect(UsageDisplayMode(rawValue: "invalid") == nil)
    }
}