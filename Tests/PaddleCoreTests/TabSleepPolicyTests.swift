import Foundation
@testable import PaddleCore
import Testing

struct TabSleepPolicyTests {
    let now = Date(timeIntervalSince1970: 100_000)

    func tab(_ minutesAgo: Double, awake: Bool = true, selected: Bool = false, pinned: Bool = false, busy: Bool = false) -> TabSnapshot {
        TabSnapshot(id: UUID(), lastActive: now.addingTimeInterval(-minutesAgo * 60), isAwake: awake, isSelected: selected, isPinned: pinned, isBusy: busy)
    }

    @Test func sleepsIdleBackgroundTabsOnly() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false)
        let old = tab(45)
        let recent = tab(5)
        let selectedOld = tab(90, selected: true)
        let busyOld = tab(90, busy: true)
        let pinnedOld = tab(90, pinned: true)
        let asleep = tab(90, awake: false)
        let result = policy.tabsToSleep([old, recent, selectedOld, busyOld, pinnedOld, asleep], now: now)
        #expect(result == [old.id])
    }

    @Test func capSleepsLeastRecentlyUsedFirst() {
        let policy = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 2, sleepPinnedTabs: false)
        let a = tab(1, selected: true), b = tab(2), c = tab(3), d = tab(4)
        #expect(policy.tabsToSleep([a, b, c, d], now: now) == [d.id, c.id])
    }

    @Test func capCountsIdleSleepsFirst() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 2, sleepPinnedTabs: false)
        let a = tab(1, selected: true), b = tab(2), c = tab(60)
        #expect(policy.tabsToSleep([a, b, c], now: now) == [c.id])
    }

    @Test func memoryPressureSleepsEverythingEligible() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 10, sleepPinnedTabs: true)
        let a = tab(1, selected: true), b = tab(1), c = tab(2, pinned: true), d = tab(3, busy: true)
        #expect(policy.tabsToSleep([a, b, c, d], now: now, memoryPressure: true) == [c.id, b.id])
    }
}
