import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite
struct AntigravityUsageProbeParsingTests {

    // MARK: - Sample Data

    static let sampleUserStatusResponse = """
    {
      "userStatus": {
        "email": "user@example.com",
        "cascadeModelConfigData": {
          "clientModelConfigs": [
            {
              "label": "Claude Sonnet",
              "modelOrAlias": { "model": "claude-sonnet-4" },
              "quotaInfo": { "remainingFraction": 0.75, "resetTime": "2025-01-01T00:00:00Z" }
            },
            {
              "label": "Gemini Pro",
              "modelOrAlias": { "model": "gemini-pro" },
              "quotaInfo": { "remainingFraction": 0.50, "resetTime": "1735689600" }
            }
          ]
        }
      }
    }
    """

    static let sampleCommandModelResponse = """
    {
      "clientModelConfigs": [
        {
          "label": "Claude Opus",
          "modelOrAlias": { "model": "claude-opus-4" },
          "quotaInfo": { "remainingFraction": 0.25, "resetTime": "2025-01-02T12:00:00Z" }
        }
      ]
    }
    """

    // MARK: - UserStatus Parsing Tests

    @Test
    func `parses model quota into UsageQuota`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.quotas[0].quotaType == .modelSpecific("Claude Sonnet"))
        #expect(snapshot.quotas[1].quotaType == .modelSpecific("Gemini Pro"))
    }

    @Test
    func `maps remainingFraction to percentRemaining`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        #expect(snapshot.quotas[0].percentRemaining == 75.0)
        #expect(snapshot.quotas[1].percentRemaining == 50.0)
    }

    @Test
    func `parses ISO-8601 resetTime to Date`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        let expectedDate = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")
        #expect(snapshot.quotas[0].resetsAt == expectedDate)
    }

    @Test
    func `parses epoch seconds resetTime to Date`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        let expectedDate = Date(timeIntervalSince1970: 1735689600)
        #expect(snapshot.quotas[1].resetsAt == expectedDate)
    }

    @Test
    func `creates modelSpecific QuotaType from label`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        if case .modelSpecific(let name) = snapshot.quotas[0].quotaType {
            #expect(name == "Claude Sonnet")
        } else {
            Issue.record("Expected modelSpecific quota type")
        }
    }

    @Test
    func `extracts account email from userStatus`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        #expect(snapshot.accountEmail == "user@example.com")
    }

    @Test
    func `handles missing quotaInfo gracefully`() throws {
        // Given
        let responseWithMissingQuota = """
        {
          "userStatus": {
            "email": "user@example.com",
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Claude Sonnet",
                  "modelOrAlias": { "model": "claude-sonnet-4" },
                  "quotaInfo": { "remainingFraction": 0.75 }
                },
                {
                  "label": "No Quota Model",
                  "modelOrAlias": { "model": "no-quota" }
                }
              ]
            }
          }
        }
        """
        let data = Data(responseWithMissingQuota.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then - models without quotaInfo should be skipped
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].quotaType == .modelSpecific("Claude Sonnet"))
    }

    @Test
    func `treats quotaInfo with only resetTime as zero percent remaining`() throws {
        // Given - Gemini 3 Flash has quotaInfo with resetTime but no remainingFraction
        let responseWithResetTimeOnly = """
        {
          "userStatus": {
            "email": "user@example.com",
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Claude Sonnet",
                  "modelOrAlias": { "model": "claude-sonnet-4" },
                  "quotaInfo": { "remainingFraction": 0.75, "resetTime": "2025-01-01T00:00:00Z" }
                },
                {
                  "label": "Gemini 3 Flash",
                  "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M18" },
                  "quotaInfo": { "resetTime": "2025-12-29T14:01:29Z" }
                }
              ]
            }
          }
        }
        """
        let data = Data(responseWithResetTimeOnly.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then - model with only resetTime should be included with 0% remaining
        #expect(snapshot.quotas.count == 2)

        let geminiQuota = snapshot.quotas.first { $0.quotaType == .modelSpecific("Gemini 3 Flash") }
        #expect(geminiQuota != nil)
        #expect(geminiQuota?.percentRemaining == 0.0)

        let expectedResetTime = ISO8601DateFormatter().date(from: "2025-12-29T14:01:29Z")
        #expect(geminiQuota?.resetsAt == expectedResetTime)
    }

    @Test
    func `returns all models as separate UsageQuota entries`() throws {
        // Given
        let responseWithManyModels = """
        {
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                { "label": "Model A", "modelOrAlias": { "model": "a" }, "quotaInfo": { "remainingFraction": 0.9 } },
                { "label": "Model B", "modelOrAlias": { "model": "b" }, "quotaInfo": { "remainingFraction": 0.8 } },
                { "label": "Model C", "modelOrAlias": { "model": "c" }, "quotaInfo": { "remainingFraction": 0.7 } },
                { "label": "Model D", "modelOrAlias": { "model": "d" }, "quotaInfo": { "remainingFraction": 0.6 } }
              ]
            }
          }
        }
        """
        let data = Data(responseWithManyModels.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then - all 4 models should be included
        #expect(snapshot.quotas.count == 4)
        #expect(snapshot.quotas.map { $0.percentRemaining } == [90, 80, 70, 60])
    }

    @Test
    func `sets providerId correctly`() throws {
        // Given
        let data = Data(Self.sampleUserStatusResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")

        // Then
        #expect(snapshot.providerId == "antigravity")
        #expect(snapshot.quotas.allSatisfy { $0.providerId == "antigravity" })
    }

    // MARK: - CommandModel Parsing Tests (Fallback)

    @Test
    func `parses command model response as fallback`() throws {
        // Given
        let data = Data(Self.sampleCommandModelResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseCommandModelResponse(data, providerId: "antigravity")

        // Then
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].percentRemaining == 25.0)
        #expect(snapshot.quotas[0].quotaType == .modelSpecific("Claude Opus"))
    }

    @Test
    func `command model response has no account email`() throws {
        // Given
        let data = Data(Self.sampleCommandModelResponse.utf8)

        // When
        let snapshot = try AntigravityUsageProbe.parseCommandModelResponse(data, providerId: "antigravity")

        // Then
        #expect(snapshot.accountEmail == nil)
    }

    // MARK: - Error Handling Tests

    @Test
    func `throws parseFailed for invalid JSON`() throws {
        // Given
        let invalidData = Data("not json".utf8)

        // When/Then
        #expect(throws: ProbeError.self) {
            try AntigravityUsageProbe.parseUserStatusResponse(invalidData, providerId: "antigravity")
        }
    }

    @Test
    func `throws parseFailed when no model configs found`() throws {
        // Given
        let emptyResponse = """
        {
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": []
            }
          }
        }
        """
        let data = Data(emptyResponse.utf8)

        // When/Then
        #expect(throws: ProbeError.self) {
            try AntigravityUsageProbe.parseUserStatusResponse(data, providerId: "antigravity")
        }
    }
}
