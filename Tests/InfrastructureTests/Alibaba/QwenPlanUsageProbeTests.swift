import Foundation
import Testing
@testable import Infrastructure
import Domain

@Suite struct QwenPlanUsageProbeTests {
    @Test func fractionsAndMillisecondsMatchOfficialCLI() throws {
        let value = try QwenPlanUsageProbe.parse(Data(#"{"per5HourPercentage":0.25,"per5HourResetTime":1800000000000,"per1WeekPercentage":0.6}"#.utf8))
        #expect(value.quotas.count == 2)
        #expect(value.quotas[0].percentRemaining == 75)
        #expect(value.quotas[0].resetsAt == Date(timeIntervalSince1970: 1800000000))
        #expect(value.quotas[1].percentRemaining == 40)
    }
    @Test func absentWindowIsNotInvented() throws {
        let value = try QwenPlanUsageProbe.parse(Data(#"{"per1WeekPercentage":0.5}"#.utf8))
        #expect(value.quotas.count == 1)
        #expect(value.quotas[0].quotaType == .weekly)
        #expect(throws: (any Error).self) { try QwenPlanUsageProbe.parse(Data("{}".utf8)) }
    }
    @Test func monthlyEditionReadsMonthlyWindowWithoutWeekly() throws {
        let value = try QwenPlanUsageProbe.parse(Data(#"{"per5HourPercentage":0.1,"per1MonthPercentage":0.3}"#.utf8))
        #expect(value.quotas.map(\.quotaType) == [.session, .timeLimit("Monthly")])
        #expect(value.quotas[1].percentRemaining == 70)
    }

    @Test func consoleGatewayEnvelopeIsUnwrapped() throws {
        // Real `bl console call --output json` shape: data.DataV2.data.data.<win>.
        let json = #"{"code":"200","data":{"DataV2":{"ret":["SUCCESS"],"data":{"msg":"Success.","code":"SUCCESS","data":{"per1MonthPercentage":3.1283108877777782e-06,"per1MonthResetTime":1792252800000}}}}}"#
        let value = try QwenPlanUsageProbe.parse(Data(json.utf8))
        #expect(value.quotas.count == 1)
        #expect(value.quotas[0].quotaType == .timeLimit("Monthly"))
        #expect(value.quotas[0].percentRemaining > 99.9)
        #expect(value.quotas[0].resetsAt == Date(timeIntervalSince1970: 1792252800))
    }
}
