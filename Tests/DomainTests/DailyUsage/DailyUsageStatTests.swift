import Foundation
import Testing
@testable import Domain

@Suite
struct DailyUsageStatTests {
    @Test func `formats cost as USD currency`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 14.26,
            totalTokens: 0,
            workingTime: 0,
            sessionCount: 0
        )
        #expect(stat.formattedCost == "$14.26")
    }

    @Test func `formats zero cost`() {
        let stat = DailyUsageStat.empty(for: Date())
        #expect(stat.formattedCost == "$0.00")
    }

    @Test func `formats large token count as millions`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 19_498_439,
            workingTime: 0,
            sessionCount: 0
        )
        #expect(stat.formattedTokens == "19.5M")
    }

    @Test func `formats medium token count as thousands`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 1_200,
            workingTime: 0,
            sessionCount: 0
        )
        #expect(stat.formattedTokens == "1.2K")
    }

    @Test func `formats small token count as raw number`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 500,
            workingTime: 0,
            sessionCount: 0
        )
        #expect(stat.formattedTokens == "500")
    }

    @Test func `formats working time with hours and minutes`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 0,
            workingTime: 80160, // 22h 16m
            sessionCount: 0
        )
        #expect(stat.formattedWorkingTime == "22h 16m")
    }

    @Test func `formats working time with minutes and seconds only`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 0,
            workingTime: 330, // 5m 30s
            sessionCount: 0
        )
        #expect(stat.formattedWorkingTime == "5m 30s")
    }

    @Test func `empty stat has all zeros`() {
        let stat = DailyUsageStat.empty(for: Date())
        #expect(stat.isEmpty)
        #expect(stat.totalCost == 0)
        #expect(stat.totalTokens == 0)
        #expect(stat.workingTime == 0)
    }

    @Test func `non-empty stat with tokens is not empty`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 100,
            workingTime: 0,
            sessionCount: 1
        )
        #expect(!stat.isEmpty)
    }

    // MARK: - Cache

    @Test func `totalTokensWithCache sums all token types`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 1_500,
            workingTime: 0,
            sessionCount: 0,
            inputTokens: 1_000,
            outputTokens: 500,
            cacheCreationTokens: 2_000,
            cacheReadTokens: 8_000,
            cachedSavings: 0
        )
        #expect(stat.totalTokensWithCache == 11_500)
    }

    @Test func `cacheHitRate is cache_read divided by cache_read plus input`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 1_500,
            workingTime: 0,
            sessionCount: 0,
            inputTokens: 1_000,
            outputTokens: 500,
            cacheCreationTokens: 0,
            cacheReadTokens: 9_000,
            cachedSavings: 0
        )
        // 9000 / (9000 + 1000) = 0.9
        #expect(stat.cacheHitRate == 0.9)
    }

    @Test func `cacheHitRate is zero when no input or cache reads`() {
        let stat = DailyUsageStat.empty(for: Date())
        #expect(stat.cacheHitRate == 0)
    }

    @Test func `formattedHitRate displays as percentage`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 0,
            workingTime: 0,
            sessionCount: 0,
            inputTokens: 1_000,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 9_000,
            cachedSavings: 0
        )
        #expect(stat.formattedHitRate == "90.0%")
    }

    @Test func `formattedSavings shows USD amount`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 0,
            workingTime: 0,
            sessionCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            cachedSavings: Decimal(string: "412.30")!
        )
        #expect(stat.formattedSavings == "$412.30")
    }

    @Test func `formattedCacheTokens sums creation and read with M suffix`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 0,
            totalTokens: 0,
            workingTime: 0,
            sessionCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 12_000_000,
            cacheReadTokens: 25_000_000,
            cachedSavings: 0
        )
        #expect(stat.formattedCacheTokens == "37.0M")
    }

    @Test func `existing init still works without cache fields`() {
        let stat = DailyUsageStat(
            date: Date(),
            totalCost: 5,
            totalTokens: 100,
            workingTime: 60,
            sessionCount: 1
        )
        #expect(stat.cacheReadTokens == 0)
        #expect(stat.cacheCreationTokens == 0)
        #expect(stat.cacheHitRate == 0)
        #expect(stat.cachedSavings == 0)
    }
}
