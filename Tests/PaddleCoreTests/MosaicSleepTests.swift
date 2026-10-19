import Foundation
@testable import PaddleCore
import Testing

struct MosaicSleepTests {
    private let now = Date(timeIntervalSince1970: 100_000)
    private let mosaic = UUID()

    private func tab(_ minutesAgo: Double, mosaic: UUID? = nil, busy: Bool = false, selected: Bool = false, guards: Bool = false) -> TabSnapshot {
        TabSnapshot(
            id: UUID(), lastActive: now.addingTimeInterval(-minutesAgo * 60), isAwake: true, isSelected: selected,
            isPinned: false, isBusy: busy, guardsUnload: guards, mosaic: mosaic
        )
    }

    private func decide(_ policy: TabSleepPolicy, _ tabs: [TabSnapshot], pressure: Bool = false) -> (sleep: Set<UUID>, freeze: Set<UUID>) {
        let result = policy.decide([(policy, tabs)], now: now, memoryPressure: pressure)
        return (Set(result.sleep), Set(result.freeze))
    }

    @Test func mosaicPanesFollowTheirOwnTimers() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 2 * 60,
                                    mosaicSleepAfter: 0, mosaicFreezeAfter: 15 * 60)
        let plain = tab(5)
        let a = tab(5, mosaic: mosaic), b = tab(5, mosaic: mosaic)
        let old = tab(40, mosaic: UUID())
        let result = decide(policy, [plain, a, b, old])
        #expect(result.freeze.contains(plain.id))
        #expect(!result.freeze.contains(a.id) && !result.freeze.contains(b.id))
        // Mosaic sleep is off (0), so the 40-minute-old Mosaic only freezes.
        #expect(result.sleep.isEmpty && result.freeze.contains(old.id))
        // nil follows the tab values.
        let follows = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 2 * 60)
        #expect(decide(follows, [a, b]).freeze == [a.id, b.id])
    }

    @Test func aMosaicSharesItsNewestClockAndGoesAsOne() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 0)
        let stale = tab(45, mosaic: mosaic), fresh = tab(10, mosaic: mosaic)
        #expect(decide(policy, [stale, fresh]).sleep.isEmpty, "the newest pane's clock holds both")
        let both = [tab(45, mosaic: mosaic), tab(35, mosaic: mosaic)]
        #expect(decide(policy, both).sleep == Set(both.map(\.id)))
    }

    @Test func onePaneThatMustStayHoldsTheWholeMosaic() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 2 * 60)
        let playing = tab(45, mosaic: mosaic, busy: true), idle = tab(45, mosaic: mosaic)
        let result = decide(policy, [playing, idle])
        #expect(result.sleep.isEmpty && result.freeze.isEmpty)
        // Unsaved changes hold sleep but not freezing; memory pressure ignores them.
        let guarded = tab(45, mosaic: mosaic, guards: true), other = tab(45, mosaic: mosaic)
        let held = decide(policy, [guarded, other])
        #expect(held.sleep.isEmpty && held.freeze == [guarded.id, other.id])
        #expect(decide(policy, [guarded, other], pressure: true).sleep == [guarded.id, other.id])
    }

    @Test func theAwakeCapTakesAWholeMosaic() {
        let policy = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 2, sleepPinnedTabs: false)
        let shown = tab(0, selected: true)
        let a = tab(20, mosaic: mosaic), b = tab(20, mosaic: mosaic)
        let other = tab(5)
        let sleep = decide(policy, [shown, a, b, other]).sleep
        #expect(sleep.contains(a.id) && sleep.contains(b.id) && !sleep.contains(shown.id))
    }

    @Test func constrainedPowerTightensAnOwnMosaicTimerButKeepsOffOff() {
        let own = TabSleepPolicy(sleepAfter: 60 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, mosaicSleepAfter: 90 * 60)
        let hot = PowerConditions(lowPowerMode: true, thermal: .nominal)
        #expect(own.adjusted(for: hot).mosaicSleepAfter == TabSleepPolicy.constrainedSleepAfter)
        let off = TabSleepPolicy(sleepAfter: 60 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, mosaicSleepAfter: 0)
        #expect(off.adjusted(for: hot).mosaicSleepAfter == 0)
    }

    @Test func mosaicBackgroundKeysDecode() throws {
        let d = PaddleConfig()
        #expect(d.mosaicStaysReady && d.mosaicFreezeAfterMinutes == nil && d.mosaicSleepAfterMinutes == nil)
        let c = try PaddleConfig.decode(Data(#"{"mosaicStaysReady": false, "mosaicFreezeAfterMinutes": 15, "mosaicSleepAfterMinutes": 0}"#.utf8))
        #expect(!c.mosaicStaysReady && c.mosaicFreezeAfterMinutes == 15 && c.mosaicSleepAfterMinutes == 0)
        let policy = TabSleepPolicy(config: c)
        #expect(policy.mosaicFreezeAfter == 15 * 60 && policy.mosaicSleepAfter == 0)
        #expect(!ConfigValidator.issues(PaddleConfig(mosaicSleepAfterMinutes: -1), actionNames: []).filter { $0.key == .mosaicSleepAfterMinutes }.isEmpty)
    }
}
