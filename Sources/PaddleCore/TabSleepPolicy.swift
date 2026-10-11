import Foundation

/// What the sleep policy needs to know about one tab.
public struct TabSnapshot: Sendable, Equatable {
    public var id: UUID
    public var lastActive: Date
    public var isAwake: Bool
    public var isSelected: Bool
    public var isPinned: Bool
    /// Playing audio or video, or using the camera or microphone. Never put to sleep.
    public var isBusy: Bool

    public init(id: UUID, lastActive: Date, isAwake: Bool, isSelected: Bool, isPinned: Bool, isBusy: Bool) {
        self.id = id
        self.lastActive = lastActive
        self.isAwake = isAwake
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.isBusy = isBusy
    }
}

/// Decides which background tabs to put to sleep. A sleeping tab keeps its URL and back/forward history
/// but has no web view, so its web content process exits and its memory is returned.
public struct TabSleepPolicy: Sendable, Equatable {
    public var sleepAfter: TimeInterval
    public var maxAwakeTabs: Int
    public var sleepPinnedTabs: Bool

    public init(sleepAfter: TimeInterval, maxAwakeTabs: Int, sleepPinnedTabs: Bool) {
        self.sleepAfter = sleepAfter
        self.maxAwakeTabs = maxAwakeTabs
        self.sleepPinnedTabs = sleepPinnedTabs
    }

    public init(config: PaddleConfig) {
        self.init(
            sleepAfter: config.tabSleepAfterMinutes * 60,
            maxAwakeTabs: config.maxAwakeTabs,
            sleepPinnedTabs: config.sleepPinnedTabs
        )
    }

    /// Tabs to put to sleep now, least recently used first.
    /// - Parameter memoryPressure: the system reported memory pressure; every eligible tab sleeps.
    public func tabsToSleep(_ tabs: [TabSnapshot], now: Date, memoryPressure: Bool = false) -> [UUID] {
        let eligible = tabs
            .filter { $0.isAwake && !$0.isSelected && !$0.isBusy && (sleepPinnedTabs || !$0.isPinned) }
            .sorted { $0.lastActive < $1.lastActive }

        if memoryPressure { return eligible.map(\.id) }

        var chosen: [UUID] = []
        var chosenSet: Set<UUID> = []
        if sleepAfter > 0 {
            for tab in eligible where now.timeIntervalSince(tab.lastActive) >= sleepAfter {
                chosen.append(tab.id)
                chosenSet.insert(tab.id)
            }
        }

        if maxAwakeTabs > 0 {
            var awake = tabs.filter(\.isAwake).count - chosen.count
            for tab in eligible where awake > maxAwakeTabs && !chosenSet.contains(tab.id) {
                chosen.append(tab.id)
                chosenSet.insert(tab.id)
                awake -= 1
            }
        }

        let order = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($1.id, $0) })
        return chosen.sorted { order[$0, default: 0] < order[$1, default: 0] }
    }
}
