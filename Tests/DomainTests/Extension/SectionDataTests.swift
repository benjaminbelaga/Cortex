import Foundation
import Testing
@testable import Domain

@Suite
struct SectionDataTests {
    // MARK: - Quota Grid Parsing

    @Test
    func `parses quota grid data from JSON`() throws {
        let json = """
        {
            "quotas": [
                {
                    "type": "session",
                    "percentRemaining": 97.0,
                    "resetsAt": "2026-03-17T18:00:00Z"
                },
                {
                    "type": "weekly",
                    "percentRemaining": 69.0
                }
            ]
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .quotaGrid, providerId: "test")

        guard case .quotas(let quotas) = data else {
            Issue.record("Expected .quotas case")
            return
        }

        #expect(quotas.count == 2)
        #expect(quotas[0].quotaType == .session)
        #expect(quotas[0].percentRemaining == 97.0)
        #expect(quotas[0].resetsAt != nil)
        #expect(quotas[0].providerId == "test")
        #expect(quotas[1].quotaType == .weekly)
        #expect(quotas[1].percentRemaining == 69.0)
    }

    @Test
    func `parses model-specific quota type`() throws {
        let json = """
        {
            "quotas": [
                {
                    "type": "model:sonnet",
                    "percentRemaining": 99.0
                }
            ]
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .quotaGrid, providerId: "test")

        guard case .quotas(let quotas) = data else {
            Issue.record("Expected .quotas case")
            return
        }

        #expect(quotas[0].quotaType == .modelSpecific("sonnet"))
    }

    @Test
    func `parses quota with dollar remaining`() throws {
        let json = """
        {
            "quotas": [
                {
                    "type": "weekly",
                    "percentRemaining": 85.0,
                    "dollarRemaining": 50.00
                }
            ]
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .quotaGrid, providerId: "test")

        guard case .quotas(let quotas) = data else {
            Issue.record("Expected .quotas case")
            return
        }

        #expect(quotas[0].dollarRemaining == Decimal(50))
    }

    // MARK: - Metrics Row Parsing

    @Test
    func `parses metrics row data from JSON`() throws {
        let json = """
        {
            "metrics": [
                {
                    "label": "Cost Usage",
                    "value": "$10.26",
                    "unit": "Spent",
                    "icon": "dollarsign.circle.fill",
                    "color": "#FFEB3B",
                    "progress": 0.82,
                    "delta": {
                        "vs": "Mar 16",
                        "value": "-$701.58",
                        "percent": 98.6
                    }
                },
                {
                    "label": "Token Usage",
                    "value": "8.3M",
                    "unit": "Tokens"
                }
            ]
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .metricsRow, providerId: "test")

        guard case .metrics(let metrics) = data else {
            Issue.record("Expected .metrics case")
            return
        }

        #expect(metrics.count == 2)
        #expect(metrics[0].label == "Cost Usage")
        #expect(metrics[0].value == "$10.26")
        #expect(metrics[0].delta?.percent == 98.6)
        #expect(metrics[1].label == "Token Usage")
        #expect(metrics[1].delta == nil)
    }

    // MARK: - Status Banner Parsing

    @Test
    func `parses status banner data from JSON`() throws {
        let json = """
        {
            "status": {
                "text": "Claude Code Active",
                "level": "healthy"
            }
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .statusBanner, providerId: "test")

        guard case .status(let info) = data else {
            Issue.record("Expected .status case")
            return
        }

        #expect(info.text == "Claude Code Active")
        #expect(info.level == .healthy)
    }

    @Test
    func `parses all status levels`() throws {
        let levels: [(String, StatusLevel)] = [
            ("healthy", .healthy),
            ("warning", .warning),
            ("critical", .critical),
            ("inactive", .inactive),
        ]

        for (jsonValue, expected) in levels {
            let json = """
            {
                "status": {
                    "text": "test",
                    "level": "\(jsonValue)"
                }
            }
            """

            let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .statusBanner, providerId: "test")

            guard case .status(let info) = data else {
                Issue.record("Expected .status case")
                return
            }

            #expect(info.level == expected, "Expected \(expected) for '\(jsonValue)'")
        }
    }

    // MARK: - Cost Usage Parsing

    @Test
    func `parses cost usage data from JSON`() throws {
        let json = """
        {
            "costUsage": {
                "totalCost": 10.26,
                "apiDuration": 454.0,
                "wallDuration": 23600.0,
                "linesAdded": 150,
                "linesRemoved": 42
            }
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .costUsage, providerId: "test")

        guard case .cost(let cost) = data else {
            Issue.record("Expected .cost case")
            return
        }

        #expect(cost.totalCost == Decimal(string: "10.26"))
        #expect(cost.apiDuration == 454.0)
        #expect(cost.wallDuration == 23600.0)
        #expect(cost.linesAdded == 150)
        #expect(cost.linesRemoved == 42)
        #expect(cost.providerId == "test")
    }

    // MARK: - Daily Usage Parsing

    @Test
    func `parses daily usage data from JSON`() throws {
        let json = """
        {
            "dailyUsage": {
                "today": {
                    "totalCost": 10.26,
                    "totalTokens": 8300000,
                    "workingTime": 454.0,
                    "date": "2026-03-17"
                },
                "previous": {
                    "totalCost": 711.84,
                    "totalTokens": 8693000,
                    "workingTime": 42514.0,
                    "date": "2026-03-16"
                }
            }
        }
        """

        let data = try SectionData.decode(from: json.data(using: .utf8)!, type: .dailyUsage, providerId: "test")

        guard case .daily(let report) = data else {
            Issue.record("Expected .daily case")
            return
        }

        #expect(report.today.totalCost == Decimal(string: "10.26"))
        #expect(report.today.totalTokens == 8_300_000)
        #expect(report.today.workingTime == 454.0)
        #expect(report.previous.totalCost == Decimal(string: "711.84"))
    }

    // MARK: - Error Cases

    @Test
    func `throws on mismatched section type and data`() {
        let json = """
        {
            "quotas": [{"type": "session", "percentRemaining": 50}]
        }
        """

        #expect(throws: SectionDataError.self) {
            try SectionData.decode(from: json.data(using: .utf8)!, type: .metricsRow, providerId: "test")
        }
    }

    @Test
    func `throws on invalid JSON`() {
        let json = "not valid json"

        #expect(throws: (any Error).self) {
            try SectionData.decode(from: json.data(using: .utf8)!, type: .quotaGrid, providerId: "test")
        }
    }
}
