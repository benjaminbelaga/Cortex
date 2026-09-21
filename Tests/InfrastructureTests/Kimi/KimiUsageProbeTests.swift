import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("KimiUsageProbe Tests")
struct KimiUsageProbeTests {

    // MARK: - Test Helpers

    /// A mock token provider for testing
    private struct MockTokenProvider: KimiTokenProviding {
        let token: String?

        func resolveToken() throws -> String {
            guard let token else {
                throw ProbeError.authenticationRequired
            }
            return token
        }
    }

    private func makeSuccessResponse(json: String) -> (Data, URLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://www.kimi.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    private func makeErrorResponse(statusCode: Int) -> (Data, URLResponse) {
        let data = Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://www.kimi.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    private static let validResponseJSON = """
    {
        "usages": [{
            "scope": "FEATURE_CODING",
            "detail": {
                "limit": "2048",
                "used": "214",
                "remaining": "1834",
                "resetTime": "2025-06-09T00:00:00Z"
            },
            "limits": [{
                "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
                "detail": {
                    "limit": "200",
                    "used": "139",
                    "remaining": "61",
                    "resetTime": "2025-06-03T15:30:00Z"
                }
            }]
        }]
    }
    """

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when token is available`() async {
        let mockNetwork = MockNetworkClient()
        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when token is unavailable`() async {
        let mockNetwork = MockNetworkClient()
        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: nil)
        )

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Success Tests

    @Test
    func `probe returns correct UsageSnapshot on success`() async throws {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeSuccessResponse(json: Self.validResponseJSON)
        )

        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "kimi")
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.accountTier == .custom("Moderato"))

        // Weekly quota
        let weekly = snapshot.quota(for: .weekly)!
        #expect(weekly.percentRemaining > 89.5)
        #expect(weekly.percentRemaining < 89.6)

        // Session quota
        let session = snapshot.quota(for: .session)!
        #expect(session.percentRemaining == 30.5)
    }

    // MARK: - Probe Error Tests

    @Test
    func `probe throws authenticationRequired when token is unavailable`() async {
        let mockNetwork = MockNetworkClient()
        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: nil)
        )

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws authenticationRequired on 401`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeErrorResponse(statusCode: 401)
        )

        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws authenticationRequired on 403`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeErrorResponse(statusCode: 403)
        )

        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed on server error`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeErrorResponse(statusCode: 500)
        )

        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws parseFailed on malformed response`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeSuccessResponse(json: "{ invalid json }")
        )

        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws parseFailed when response lacks FEATURE_CODING scope`() async {
        let mockNetwork = MockNetworkClient()
        let json = """
        {
            "usages": [{
                "scope": "FEATURE_CHAT",
                "detail": {
                    "limit": "1000",
                    "used": "100",
                    "remaining": "900",
                    "resetTime": "2025-06-09T00:00:00Z"
                }
            }]
        }
        """

        given(mockNetwork).request(.any).willReturn(
            makeSuccessResponse(json: json)
        )

        let probe = KimiUsageProbe(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: ProbeError.self) {
            try await probe.probe()
        }
    }
}
