import Testing
import Foundation
@testable import Domain

@Suite
struct RefreshIntervalTests {
    /// Each cadence exposes its poll interval in seconds, and `.off` has none.
    @Test
    func `seconds maps each option onto its poll interval`() {
        #expect(RefreshInterval.off.seconds == nil)
        #expect(RefreshInterval.oneMinute.seconds == 60)
        #expect(RefreshInterval.twoMinutes.seconds == 120)
        #expect(RefreshInterval.fiveMinutes.seconds == 300)
        #expect(RefreshInterval.tenMinutes.seconds == 600)
        #expect(RefreshInterval.fifteenMinutes.seconds == 900)
    }

    /// Only `.off` disables background refresh; every timed option enables it.
    @Test
    func `isEnabled is false only for off`() {
        #expect(RefreshInterval.off.isEnabled == false)
        #expect(RefreshInterval.oneMinute.isEnabled == true)
        #expect(RefreshInterval.twoMinutes.isEnabled == true)
        #expect(RefreshInterval.fiveMinutes.isEnabled == true)
        #expect(RefreshInterval.tenMinutes.isEnabled == true)
        #expect(RefreshInterval.fifteenMinutes.isEnabled == true)
    }

    /// Each option's picker label matches the exact copy shown in Settings.
    @Test
    func `label matches the picker copy`() {
        #expect(RefreshInterval.off.label == "Off")
        #expect(RefreshInterval.oneMinute.label == "1 min")
        #expect(RefreshInterval.twoMinutes.label == "2 min")
        #expect(RefreshInterval.fiveMinutes.label == "5 min")
        #expect(RefreshInterval.tenMinutes.label == "10 min")
        #expect(RefreshInterval.fifteenMinutes.label == "15 min")
    }

    /// A disabled legacy `backgroundSyncEnabled` flag migrates to `.off`
    /// regardless of the stored interval.
    @Test
    func `migrating returns off when background sync is disabled`() {
        #expect(RefreshInterval.migrating(enabled: false, storedSeconds: 60) == .off)
        #expect(RefreshInterval.migrating(enabled: false, storedSeconds: 900) == .off)
    }

    /// An enabled legacy interval snaps to the nearest supported option, with
    /// retired and below-floor values rounding up to the 1-minute floor.
    @Test
    func `migrating snaps a stored interval to the nearest supported option`() {
        // Retired 30s and below-floor values snap up to 1 minute.
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 30) == .oneMinute)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 60) == .oneMinute)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 120) == .twoMinutes)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 300) == .fiveMinutes)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 600) == .tenMinutes)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 700) == .tenMinutes)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 900) == .fifteenMinutes)
    }

    /// The persisted default cadence maps to the explicit 2-minute option.
    @Test
    func `migrating maps the default 120s cadence to two minutes`() {
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 120) == .twoMinutes)
    }

    /// `allCases` is ordered exactly as the segmented picker renders the options.
    @Test
    func `allCases lists the options in picker order`() {
        #expect(RefreshInterval.allCases == [.off, .oneMinute, .twoMinutes, .fiveMinutes, .tenMinutes, .fifteenMinutes])
    }
}
