import Foundation
import Testing
@testable import Infrastructure
import Domain

@Suite struct OllamaCloudUsageProbeTests {
    @Test func consumedFractionsBecomeRemainingPercent() throws {
        let json = #"{"limits":{"session":{"usage":0.25,"models":[]},"weekly":{"usage":0.6,"models":[]}},"activity":{"cost":"0.00000"}}"#
        let value = try OllamaCloudUsageProbe.parseResponse(Data(json.utf8))
        #expect(value.providerId == "ollama")
        #expect(value.quotas.map(\.quotaType) == [.session, .weekly])
        #expect(value.quotas[0].percentRemaining == 75)
        #expect(value.quotas[1].percentRemaining == 40)
    }

    @Test func monthlyOnlyEditionHasNoInventedWindowsOrResets() throws {
        let json = #"{"limits":{"monthly":{"usage":1,"models":[{"name":"glm-5.3","request_count":3}]}}}"#
        let value = try OllamaCloudUsageProbe.parseResponse(Data(json.utf8))
        #expect(value.quotas.count == 1)
        #expect(value.quotas[0].quotaType == .timeLimit("Monthly"))
        #expect(value.quotas[0].percentRemaining == 0)
        #expect(value.quotas[0].resetsAt == nil)
    }

    @Test func missingLimitsIsAParseFailure() {
        #expect(throws: (any Error).self) { try OllamaCloudUsageProbe.parseResponse(Data(#"{"activity":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try OllamaCloudUsageProbe.parseResponse(Data(#"{"limits":{}}"#.utf8)) }
    }
}
