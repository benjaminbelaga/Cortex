import Foundation
import Domain

/// Test-host isolation: importing the app must never migrate or poll a developer's accounts.
public enum CortexRuntime {
    public static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    public static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cortex-tests-\(UUID().uuidString)")
    public static var defaults: UserDefaults {
        isTesting ? UserDefaults(suiteName: testDirectory.lastPathComponent)! : .standard
    }
    public static let credentials: any CredentialRepository = isTesting
        ? EphemeralCredentials() : KeychainCredentialRepository.shared
}

private final class EphemeralCredentials: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func save(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func get(forKey key: String) -> String? { lock.withLock { values[key] } }
    func delete(forKey key: String) -> Bool { lock.withLock { values[key] = nil }; return true }
    func exists(forKey key: String) -> Bool { get(forKey: key) != nil }
}
