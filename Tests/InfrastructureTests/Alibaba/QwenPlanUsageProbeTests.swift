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
}
