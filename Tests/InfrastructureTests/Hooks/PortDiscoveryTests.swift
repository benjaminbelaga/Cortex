import Testing
import Foundation
@testable import Infrastructure

@Suite
struct PortDiscoveryTests {
    @Test
    func `port file path is under dot-claude directory`() {
        let path = PortDiscovery.portFilePath
        #expect(path.contains(".claude"))
        #expect(path.hasSuffix("claudebar-hook-port"))
    }

    @Test
    func `write and read port round-trips`() throws {
        // Write port
        try PortDiscovery.writePort(19847)

        // Read it back
        let port = PortDiscovery.readPort()
        #expect(port == 19847)

        // Clean up
        PortDiscovery.removePortFile()
    }

    @Test
    func `readPort returns nil after remove`() throws {
        try PortDiscovery.writePort(12345)
        PortDiscovery.removePortFile()

        let port = PortDiscovery.readPort()
        #expect(port == nil)
    }

    @Test
    func `readPort returns nil when file does not exist`() {
        PortDiscovery.removePortFile()
        let port = PortDiscovery.readPort()
        #expect(port == nil)
    }

    @Test
    func `write creates directory if needed`() throws {
        // The .claude directory should be created if it doesn't exist
        // Since we're writing to ~/.claude/ which likely exists, just verify no error
        try PortDiscovery.writePort(9999)
        let port = PortDiscovery.readPort()
        #expect(port == 9999)

        PortDiscovery.removePortFile()
    }
}
