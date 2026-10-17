import Foundation

/// What the sleep policy needs to know about one tab.
public struct TabSnapshot: Sendable, Equatable {
    public var id: UUID
    public var lastActive: Date
    public var isAwake: Bool
    public var isSelected: Bool
    public var isPinned: Bool
    /// Audio, video, camera or mic. Never put to sleep.
    public var isBusy: Bool
    /// When this tab's process started using at least the CPU limit without a break; nil when under it or unknown.
    public var cpuBusySince: Date?
    /// Frozen: its page is kept but not running (see `TabSleepPolicy.tabsToFreeze`). Still awake.
    public var isFrozen: Bool
    /// Physical footprint of this tab's own WebContent process, in bytes. 0 when unknown, or when another tab shares
    /// the process (sleeping this tab would not end it). Memory pressure discards the largest of these first.
    public var footprint: UInt64
    /// Uploading a file. Never frozen, and never put to sleep except under memory pressure.
    public var isUploading: Bool
    /// The page asks before it is left (unsaved changes). Freezing keeps the page, so it may freeze; it doesn't sleep on
    /// the idle or CPU rules, which would lose the changes. The awake-tab cap and memory pressure still apply.
    public var guardsUnload: Bool
    /// A site that should keep running: allowed to notify, or set to never freeze. Not frozen, and not put to sleep for
    /// being idle; the CPU rule, the cap and memory pressure still apply.
    public var staysLive: Bool

    public init(
        id: UUID, lastActive: Date, isAwake: Bool, isSelected: Bool, isPinned: Bool, isBusy: Bool, cpuBusySince: Date? = nil,
        isFrozen: Bool = false, footprint: UInt64 = 0, isUploading: Bool = false, guardsUnload: Bool = false,
        staysLive: Bool = false
    ) {
        self.id = id
        self.lastActive = lastActive
        self.isAwake = isAwake
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.isBusy = isBusy
        self.cpuBusySince = cpuBusySince
        self.isFrozen = isFrozen
        self.footprint = footprint
        self.isUploading = isUploading
        self.guardsUnload = guardsUnload
        self.staysLive = staysLive
    }
}

/// Decides which background tabs to freeze and which to put to sleep. A frozen tab keeps its page in memory but
/// stops running it, and shows again without a reload. A sleeping tab keeps its URL and back/forward history
/// but has no web view, so its web content process exits and its memory is returned.
public struct TabSleepPolicy: Sendable, Equatable {
    public var sleepAfter: TimeInterval
    public var maxAwakeTabs: Int
    public var sleepPinnedTabs: Bool
    /// Percent of one CPU core a background tab's process must keep busy to sleep; 0 turns CPU-based sleeping off.
    public var cpuPercent: Double
    /// Idle time after which a background tab is frozen; 0 turns freezing off.
    public var freezeAfter: TimeInterval

    /// How long a tab must stay at `cpuPercent` before it sleeps. A short burst (a download, a build step) doesn't
    /// count, and the sweep that checks this runs once a minute.
    public static let cpuSustain: TimeInterval = 3 * 60

    public init(
        sleepAfter: TimeInterval, maxAwakeTabs: Int, sleepPinnedTabs: Bool, cpuPercent: Double = 0, freezeAfter: TimeInterval = 0
    ) {
        self.sleepAfter = sleepAfter
        self.maxAwakeTabs = maxAwakeTabs
        self.sleepPinnedTabs = sleepPinnedTabs
        self.cpuPercent = cpuPercent
        self.freezeAfter = freezeAfter
    }

    public init(config: PaddleConfig) {
        self.init(
            sleepAfter: config.tabSleepAfterMinutes * 60,
            maxAwakeTabs: config.maxAwakeTabs,
            sleepPinnedTabs: config.sleepPinnedTabs,
            cpuPercent: Double(config.cpuSleepPercent),
            freezeAfter: config.tabFreezeAfterMinutes * 60
        )
    }

    /// Background tabs to freeze now, least recently used first. Freeze is the first stage: the tab stays
    /// awake and keeps its page, so `tabsToSleep` can still sleep it later. Same protections as sleep: never
    /// selected, never busy, uploading or staying live, never pinned unless `sleepPinnedTabs`. Only tabs idle for
    /// `freezeAfter`.
    /// Tabs in `discard` are skipped because the caller is about to sleep them.
    /// - Parameter discard: the tabs `tabsToSleep` chose for this sweep.
    public func tabsToFreeze(_ tabs: [TabSnapshot], now: Date, excluding discard: Set<UUID>) -> [UUID] {
        guard freezeAfter > 0 else { return [] }
        return tabs
            .filter {
                $0.isAwake && !$0.isFrozen && !$0.isSelected && !$0.isBusy && !$0.isUploading && !$0.staysLive
                    && (sleepPinnedTabs || !$0.isPinned) && !discard.contains($0.id)
                    && now.timeIntervalSince($0.lastActive) >= freezeAfter
            }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.id)
    }

    /// Tabs to put to sleep now. A frozen tab is awake, so it is eligible like any other. Outside memory pressure an
    /// uploading tab never sleeps, a tab guarding unsaved changes skips the idle and CPU rules, and a live site skips
    /// the idle rule.
    /// Idle, CPU and cap victims stay least-recently-used, so the tab you just left is the one the cap keeps.
    /// - Parameter memoryPressure: the system reported memory pressure; every eligible tab sleeps, largest footprint
    ///   first (an unknown or shared footprint sorts with the oldest).
    public func tabsToSleep(_ tabs: [TabSnapshot], now: Date, memoryPressure: Bool = false) -> [UUID] {
        let eligible = tabs
            .filter { $0.isAwake && !$0.isSelected && !$0.isBusy && (sleepPinnedTabs || !$0.isPinned) }
            .sorted { $0.lastActive < $1.lastActive }

        if memoryPressure {
            return eligible.sorted { a, b in
                if a.footprint != b.footprint { return a.footprint > b.footprint }
                return a.lastActive < b.lastActive
            }.map(\.id)
        }

        let working = eligible.filter { !$0.isUploading }
        var chosen: [UUID] = []
        var chosenSet: Set<UUID> = []
        if sleepAfter > 0 {
            for tab in working where !tab.guardsUnload && !tab.staysLive && now.timeIntervalSince(tab.lastActive) >= sleepAfter {
                chosen.append(tab.id)
                chosenSet.insert(tab.id)
            }
        }

        if cpuPercent > 0 {
            for tab in working where !tab.guardsUnload && !chosenSet.contains(tab.id) {
                guard let busySince = tab.cpuBusySince, now.timeIntervalSince(busySince) >= Self.cpuSustain else { continue }
                chosen.append(tab.id)
                chosenSet.insert(tab.id)
            }
        }

        if maxAwakeTabs > 0 {
            var awake = tabs.filter(\.isAwake).count - chosen.count
            for tab in working where awake > maxAwakeTabs && !chosenSet.contains(tab.id) {
                chosen.append(tab.id)
                chosenSet.insert(tab.id)
                awake -= 1
            }
        }

        let order = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($1.id, $0) })
        return chosen.sorted { order[$0, default: 0] < order[$1, default: 0] }
    }
}

/// Per-tab CPU use between sleep sweeps, from each tab's WebContent process CPU time.
public struct CPUUsageTracker: Sendable {
    /// The last sample of one tab, and when its sustained use began (nil while under the limit).
    private struct Record {
        var pid: Int32
        var cpuSeconds: TimeInterval
        var sampledAt: Date
        var busySince: Date?
    }

    private var records: [UUID: Record] = [:]

    public init() {}

    /// Records `cpuSeconds` (user + system CPU time of the tab's process, `pid`) at `now`. Returns the share of one core
    /// used since the previous sample of the same tab and pid (1.0 = one full core), or nil for a first sample.
    /// A changed pid, or a nil `cpuSeconds`, restarts the tab. Maintains busySince: set to the previous sample's
    /// time when usage first reaches `limit` (a fraction, e.g. 0.3), kept while it stays at or above, cleared below it.
    public mutating func record(_ id: UUID, pid: Int32, cpuSeconds: TimeInterval?, at now: Date, limit: Double) -> Double? {
        guard let cpuSeconds else {
            records[id] = nil
            return nil
        }
        guard let previous = records[id], previous.pid == pid, cpuSeconds >= previous.cpuSeconds else {
            // A new process, or CPU time that went backwards (the process was replaced): this sample starts over.
            records[id] = Record(pid: pid, cpuSeconds: cpuSeconds, sampledAt: now, busySince: nil)
            return nil
        }
        // No forward time, no rate. The old sample stays, so the next one still measures from its own time.
        let wall = now.timeIntervalSince(previous.sampledAt)
        guard wall > 0 else { return nil }
        let share = (cpuSeconds - previous.cpuSeconds) / wall
        let busySince: Date? = share >= limit ? (previous.busySince ?? previous.sampledAt) : nil
        records[id] = Record(pid: pid, cpuSeconds: cpuSeconds, sampledAt: now, busySince: busySince)
        return share
    }

    /// When the tab's sustained use began (see `record`); nil while it is under the limit, or unknown.
    public func busySince(_ id: UUID) -> Date? { records[id]?.busySince }

    /// Forgets a tab (it was selected, is playing media, slept, or closed): its clock restarts from the next sample.
    public mutating func reset(_ id: UUID) { records[id] = nil }

    /// Forgets every tab not in `ids`.
    public mutating func retain(_ ids: Set<UUID>) { records = records.filter { ids.contains($0.key) } }
}

/// The Mac's power situation as the sleep policy sees it: Low Power Mode and the thermal state
/// (`ProcessInfo.isLowPowerModeEnabled`, `ProcessInfo.thermalState`).
public struct PowerConditions: Sendable, Equatable {
    public enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical

        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public var lowPowerMode: Bool
    public var thermal: Thermal

    public init(lowPowerMode: Bool = false, thermal: Thermal = .nominal) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }

    public static let normal = PowerConditions()

    /// Low Power Mode, or a thermal state of serious or worse: the policy trades tabs staying loaded for power.
    public var isConstrained: Bool { lowPowerMode || thermal >= .serious }

    /// "Low Power Mode", "the Mac running hot", or both; nil when not constrained.
    public var reason: String? {
        var reasons: [String] = []
        if lowPowerMode { reasons.append("Low Power Mode") }
        if thermal >= .serious { reasons.append(thermal == .critical ? "the Mac running very hot" : "the Mac running hot") }
        return reasons.isEmpty ? nil : reasons.joined(separator: " and ")
    }
}

extension TabSleepPolicy {
    /// Idle limit and awake-tab cap while power is constrained (`PowerConditions.isConstrained`).
    public static let constrainedSleepAfter: TimeInterval = 5 * 60
    public static let criticalSleepAfter: TimeInterval = 60
    public static let criticalMaxAwakeTabs = 2

    /// The policy for `power`. Outside constrained states it is self, the user's values. When constrained, tabs
    /// sleep sooner and fewer stay awake, never looser than the user's own values:
    /// - Low Power Mode or serious heat: idle sleep after at most 5 minutes; the cap halved (rounded up, at least 2).
    /// - Critical heat: idle sleep after at most 1 minute; at most 2 tabs awake.
    /// A value the user turned off (0) stays off: Paddle doesn't start sleeping tabs the user asked it never to.
    public func adjusted(for power: PowerConditions) -> TabSleepPolicy {
        guard power.isConstrained else { return self }
        var policy = self
        let critical = power.thermal == .critical
        if sleepAfter > 0 {
            policy.sleepAfter = min(sleepAfter, critical ? Self.criticalSleepAfter : Self.constrainedSleepAfter)
        }
        if maxAwakeTabs > 0 {
            let lowered = critical ? Self.criticalMaxAwakeTabs : max(2, (maxAwakeTabs + 1) / 2)
            policy.maxAwakeTabs = min(maxAwakeTabs, lowered)
        }
        return policy
    }
}
