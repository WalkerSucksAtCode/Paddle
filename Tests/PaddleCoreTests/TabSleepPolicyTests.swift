import Foundation
@testable import PaddleCore
import Testing

struct TabSleepPolicyTests {
    let now = Date(timeIntervalSince1970: 100_000)

    func tab(
        _ minutesAgo: Double, awake: Bool = true, selected: Bool = false, pinned: Bool = false, busy: Bool = false,
        cpuBusyMinutes: Double? = nil, frozen: Bool = false
    ) -> TabSnapshot {
        TabSnapshot(
            id: UUID(), lastActive: now.addingTimeInterval(-minutesAgo * 60), isAwake: awake, isSelected: selected,
            isPinned: pinned, isBusy: busy, cpuBusySince: cpuBusyMinutes.map { now.addingTimeInterval(-$0 * 60) },
            isFrozen: frozen
        )
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

    @Test func memoryPressureDiscardsTheLargestProcessFirst() {
        let policy = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: false)
        var recentHeavy = tab(1)
        recentHeavy.footprint = 900
        var olderLight = tab(10)
        olderLight.footprint = 20
        let selected = tab(0, selected: true)
        #expect(policy.tabsToSleep([olderLight, recentHeavy, selected], now: now, memoryPressure: true) == [recentHeavy.id, olderLight.id])
    }

    // MARK: - Freeze

    /// Freezing on at 5 minutes, sleep and the cap off, so only the freeze rule is under test.
    private let freezeOnly = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 5 * 60)

    @Test func freezesBackgroundTabsIdleForFreezeAfter() {
        let idle = tab(6), justUnder = tab(4.9)
        #expect(freezeOnly.tabsToFreeze([justUnder, idle], now: now, excluding: []) == [idle.id])
        #expect(freezeOnly.tabsToFreeze([tab(5)], now: now, excluding: []).count == 1)
    }

    @Test func freezeAfterZeroNeverFreezes() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 0)
        #expect(policy.tabsToFreeze([tab(600)], now: now, excluding: []).isEmpty)
    }

    @Test func freezeSkipsSelectedBusyPinnedFrozenAndAsleepTabs() {
        let selected = tab(60, selected: true), busy = tab(60, busy: true), pinned = tab(60, pinned: true)
        let frozen = tab(60, frozen: true), asleep = tab(60, awake: false), ok = tab(60)
        let result = freezeOnly.tabsToFreeze([selected, busy, pinned, frozen, asleep, ok], now: now, excluding: [])
        #expect(result == [ok.id])
    }

    @Test func freezeIncludesPinnedTabsOnlyWhenSleepPinnedTabs() {
        let pinned = tab(60, pinned: true)
        #expect(freezeOnly.tabsToFreeze([pinned], now: now, excluding: []).isEmpty)
        let policy = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: true, freezeAfter: 5 * 60)
        #expect(policy.tabsToFreeze([pinned], now: now, excluding: []) == [pinned.id])
    }

    @Test func freezeLeavesOutTabsBeingDiscarded() {
        let discarded = tab(60), kept = tab(30)
        #expect(freezeOnly.tabsToFreeze([discarded, kept], now: now, excluding: [discarded.id]) == [kept.id])
    }

    @Test func freezeIsLeastRecentlyUsedFirst() {
        let a = tab(10), b = tab(20), c = tab(7)
        #expect(freezeOnly.tabsToFreeze([a, b, c], now: now, excluding: []) == [b.id, a.id, c.id])
    }

    @Test func frozenTabPastSleepAfterIsStillDiscarded() {
        let policy = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 0, sleepPinnedTabs: false, freezeAfter: 5 * 60)
        let frozenOld = tab(45, frozen: true)
        #expect(policy.tabsToSleep([frozenOld], now: now) == [frozenOld.id])
    }

    @Test func freezeAfterFromConfig() {
        var config = PaddleConfig()
        #expect(TabSleepPolicy(config: config).freezeAfter == 2 * 60)
        config.tabFreezeAfterMinutes = 0
        #expect(TabSleepPolicy(config: config).freezeAfter == 0)
    }

    // MARK: - CPU

    /// Idle sleep and the cap off, so only the CPU rule can sleep these tabs.
    private let cpuOnly = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: false, cpuPercent: 30)

    @Test func tabBusyForThreeMinutesSleeps() {
        let recent = tab(1, cpuBusyMinutes: 3), older = tab(2, cpuBusyMinutes: 10)
        #expect(cpuOnly.tabsToSleep([recent, older], now: now) == [older.id, recent.id])
    }

    @Test func tabBusyForTwoMinutesStaysAwake() {
        #expect(cpuOnly.tabsToSleep([tab(1, cpuBusyMinutes: 2)], now: now).isEmpty)
        #expect(cpuOnly.tabsToSleep([tab(1)], now: now).isEmpty)
    }

    @Test func cpuRuleSkipsSelectedPlayingAndPinnedTabs() {
        let selected = tab(1, selected: true, cpuBusyMinutes: 5)
        let playing = tab(1, busy: true, cpuBusyMinutes: 5)
        let pinned = tab(1, pinned: true, cpuBusyMinutes: 5)
        #expect(cpuOnly.tabsToSleep([selected, playing, pinned], now: now).isEmpty)
        // Pinned tabs may sleep once sleepPinnedTabs allows it; the others stay put either way.
        let pinnedAllowed = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: true, cpuPercent: 30)
        #expect(pinnedAllowed.tabsToSleep([selected, playing, pinned], now: now) == [pinned.id])
    }

    @Test func zeroPercentNeverSleepsForCPU() {
        let off = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: false, cpuPercent: 0)
        #expect(off.tabsToSleep([tab(1, cpuBusyMinutes: 30)], now: now).isEmpty)
    }

    @Test func configCarriesCPUPercent() {
        var config = PaddleConfig()
        config.cpuSleepPercent = 50
        #expect(TabSleepPolicy(config: config).cpuPercent == 50)
        #expect(TabSleepPolicy(config: config).adjusted(for: PowerConditions(lowPowerMode: true)).cpuPercent == 50)
    }

    // MARK: - Power

    private let configured = TabSleepPolicy(sleepAfter: 30 * 60, maxAwakeTabs: 10, sleepPinnedTabs: false)

    @Test func normalPowerKeepsTheUsersValues() {
        #expect(configured.adjusted(for: .normal) == configured)
        #expect(configured.adjusted(for: PowerConditions(thermal: .fair)) == configured)
    }

    @Test func lowPowerModeOrSeriousHeatSleepsSoonerWithFewerAwake() {
        for power in [PowerConditions(lowPowerMode: true), PowerConditions(thermal: .serious)] {
            let policy = configured.adjusted(for: power)
            #expect(policy.sleepAfter == 5 * 60)
            #expect(policy.maxAwakeTabs == 5)
            #expect(policy.sleepPinnedTabs == configured.sleepPinnedTabs)
        }
        // A tab idle for 10 minutes sleeps under Low Power Mode, not otherwise.
        let a = tab(1, selected: true), b = tab(10)
        #expect(configured.tabsToSleep([a, b], now: now).isEmpty)
        #expect(configured.adjusted(for: PowerConditions(lowPowerMode: true)).tabsToSleep([a, b], now: now) == [b.id])
    }

    @Test func criticalHeatIsStricter() {
        let policy = configured.adjusted(for: PowerConditions(lowPowerMode: true, thermal: .critical))
        #expect(policy.sleepAfter == 60)
        #expect(policy.maxAwakeTabs == 2)
    }

    @Test func neverLooserThanTheUsersOwnValues() {
        let strict = TabSleepPolicy(sleepAfter: 2 * 60, maxAwakeTabs: 3, sleepPinnedTabs: true)
        let adjusted = strict.adjusted(for: PowerConditions(lowPowerMode: true))
        #expect(adjusted.sleepAfter == 2 * 60)
        #expect(adjusted.maxAwakeTabs == 2)
        #expect(TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 1, sleepPinnedTabs: false).adjusted(for: PowerConditions(lowPowerMode: true)).maxAwakeTabs == 1)
    }

    @Test func settingsTheUserTurnedOffStayOff() {
        let off = TabSleepPolicy(sleepAfter: 0, maxAwakeTabs: 0, sleepPinnedTabs: false)
        #expect(off.adjusted(for: PowerConditions(lowPowerMode: true, thermal: .critical)) == off)
    }

    @Test func reasonNamesWhatConstrainsPower() {
        #expect(PowerConditions.normal.reason == nil)
        #expect(PowerConditions(lowPowerMode: true).reason == "Low Power Mode")
        #expect(PowerConditions(lowPowerMode: true, thermal: .serious).reason == "Low Power Mode and the Mac running hot")
        #expect(PowerConditions(thermal: .critical).reason == "the Mac running very hot")
    }
}

struct CPUUsageTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let id = UUID()
    let limit = 0.3

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func firstSampleHasNoShare() {
        var tracker = CPUUsageTracker()
        #expect(tracker.record(id, pid: 1, cpuSeconds: 10, at: t0, limit: limit) == nil)
    }

    @Test func shareIsCPUSecondsOverWallSeconds() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 30, at: at(60), limit: limit) == 0.5)
    }

    @Test func busySinceIsThePreviousSampleWhileUseStaysAboveTheLimit() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 30, at: at(60), limit: limit)
        #expect(tracker.busySince(id) == t0)
        _ = tracker.record(id, pid: 1, cpuSeconds: 60, at: at(120), limit: limit)
        #expect(tracker.busySince(id) == t0)
        _ = tracker.record(id, pid: 1, cpuSeconds: 61, at: at(180), limit: limit)
        #expect(tracker.busySince(id) == nil)
    }

    @Test func busySinceStartsAtTheSampleBeforeTheFirstBusyOne() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 1, at: at(60), limit: limit)
        #expect(tracker.busySince(id) == nil)
        _ = tracker.record(id, pid: 1, cpuSeconds: 31, at: at(120), limit: limit)
        #expect(tracker.busySince(id) == at(60))
    }

    @Test func changedPidRestartsTheTab() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 30, at: at(60), limit: limit)
        #expect(tracker.record(id, pid: 2, cpuSeconds: 5, at: at(120), limit: limit) == nil)
        #expect(tracker.busySince(id) == nil)
        #expect(tracker.record(id, pid: 2, cpuSeconds: 35, at: at(180), limit: limit) == 0.5)
    }

    @Test func missingCPUTimeRestartsTheTab() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 30, at: at(60), limit: limit)
        #expect(tracker.record(id, pid: 1, cpuSeconds: nil, at: at(120), limit: limit) == nil)
        #expect(tracker.busySince(id) == nil)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 40, at: at(180), limit: limit) == nil)
    }

    @Test func cpuTimeGoingBackwardsRestartsTheTab() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 100, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 130, at: at(60), limit: limit)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 50, at: at(120), limit: limit) == nil)
        #expect(tracker.busySince(id) == nil)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 80, at: at(180), limit: limit) == 0.5)
    }

    @Test func noForwardTimeGivesNoShareAndKeepsTheOldSample() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 30, at: at(60), limit: limit)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 40, at: at(60), limit: limit) == nil)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 45, at: at(30), limit: limit) == nil)
        // Measured from the t0 + 60 s sample (30 s CPU), not from the discarded ones.
        #expect(tracker.record(id, pid: 1, cpuSeconds: 60, at: at(120), limit: limit) == 0.5)
    }

    @Test func resetRestartsTheClock() {
        var tracker = CPUUsageTracker()
        _ = tracker.record(id, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
        _ = tracker.record(id, pid: 1, cpuSeconds: 30, at: at(60), limit: limit)
        tracker.reset(id)
        #expect(tracker.busySince(id) == nil)
        #expect(tracker.record(id, pid: 1, cpuSeconds: 60, at: at(120), limit: limit) == nil)
    }

    @Test func retainForgetsTabsNotKept() {
        var tracker = CPUUsageTracker()
        let other = UUID()
        for tab in [id, other] {
            _ = tracker.record(tab, pid: 1, cpuSeconds: 0, at: t0, limit: limit)
            _ = tracker.record(tab, pid: 1, cpuSeconds: 30, at: at(60), limit: limit)
        }
        tracker.retain([id])
        #expect(tracker.busySince(id) == t0)
        #expect(tracker.busySince(other) == nil)
        #expect(tracker.record(other, pid: 1, cpuSeconds: 60, at: at(120), limit: limit) == nil)
    }
}
