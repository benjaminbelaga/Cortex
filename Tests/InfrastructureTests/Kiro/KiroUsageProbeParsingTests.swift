import Testing
@testable import Infrastructure
@testable import Domain

@Suite("KiroUsageProbe Parsing Tests")
struct KiroUsageProbeParsingTests {
    
    @Test
    func `parse normal output with both bonus and regular credits`() throws {
        let output = """
        Estimated Usage | resets on 03/01 | KIRO FREE
        
        🎁 Bonus credits: 122.54/500 credits used, expires in 29 days
        
        Credits (0.00 of 50 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 0%
        """
        
        let snapshot = try KiroUsageProbe.parse(output)
        
        #expect(snapshot.providerId == "kiro")
        #expect(snapshot.quotas.count == 2)
        
        // Bonus credits (weekly)
        let bonus = snapshot.quotas.first { $0.quotaType == .weekly }
        #expect(bonus != nil)
        if let bonus = bonus {
            #expect(abs(bonus.percentRemaining - 75.492) < 0.01)
            #expect(bonus.resetsAt != nil)
            #expect(bonus.resetText == "Expires in 29 days")
        }
        
        // Regular credits (monthly)
        let regular = snapshot.quotas.first { $0.quotaType == .timeLimit("Monthly") }
        #expect(regular != nil)
        if let regular = regular {
            #expect(abs(regular.percentRemaining - 100.0) < 0.01)
            #expect(regular.resetsAt != nil)
            #expect(regular.resetText == "Resets on 03/01")
        }
    }
    
    @Test
    func `parse bonus credits only`() throws {
        let output = """
        🎁 Bonus credits: 250.0/500 credits used, expires in 15 days
        """
        
        let snapshot = try KiroUsageProbe.parse(output)
        
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].quotaType == .weekly)
        #expect(abs(snapshot.quotas[0].percentRemaining - 50.0) < 0.01)
    }
    
    @Test
    func `parse regular credits only`() throws {
        let output = """
        Credits (25.0 of 50 covered in plan)
        resets on 03/15
        """
        
        let snapshot = try KiroUsageProbe.parse(output)
        
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].quotaType == .timeLimit("Monthly"))
        #expect(abs(snapshot.quotas[0].percentRemaining - 50.0) < 0.01)
    }
    
    @Test
    func `parse empty output throws error`() {
        let output = ""
        
        #expect(throws: ProbeError.self) {
            try KiroUsageProbe.parse(output)
        }
    }
    
    @Test
    func `parse malformed output throws error`() {
        let output = "Some random text without quota data"
        
        #expect(throws: ProbeError.self) {
            try KiroUsageProbe.parse(output)
        }
    }
    
    @Test
    func `parse zero total credits throws error`() {
        let output = """
        🎁 Bonus credits: 0.0/0 credits used, expires in 10 days
        Credits (0.00 of 0 covered in plan)
        """
        
        // Should not crash with division by zero
        // Should skip quotas with zero total
        #expect(throws: ProbeError.self) {
            try KiroUsageProbe.parse(output)
        }
    }
    
    @Test
    func `parse without reset info`() throws {
        let output = """
        🎁 Bonus credits: 100.0/500 credits used
        Credits (10.0 of 50 covered in plan)
        """
        
        let snapshot = try KiroUsageProbe.parse(output)
        
        #expect(snapshot.quotas.count == 2)
        
        // Both should have nil resetsAt and resetText
        for quota in snapshot.quotas {
            #expect(quota.resetsAt == nil)
            #expect(quota.resetText == nil)
        }
    }
    
    @Test
    func `parse with ANSI escape codes`() throws {
        let output = """
        \u{001B}[38;5;141mEstimated Usage\u{001B}[0m | resets on 03/01 | \u{001B}[38;5;141mKIRO FREE\u{001B}[0m
        
        \u{001B}[1m🎁 Bonus credits:\u{001B}[0m \u{001B}[1m122.54/500\u{001B}[0m credits used, expires in \u{001B}[1m29\u{001B}[0m days
        
        \u{001B}[1mCredits\u{001B}[0m (0.00 of 50 covered in plan)
        """
        
        let snapshot = try KiroUsageProbe.parse(output)
        
        #expect(snapshot.quotas.count == 2)
        #expect(abs(snapshot.quotas[0].percentRemaining - 75.492) < 0.01)
        #expect(abs(snapshot.quotas[1].percentRemaining - 100.0) < 0.01)
    }
}
