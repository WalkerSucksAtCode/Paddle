import Foundation

/// Saved browsing session, restored at launch. Tabs come back asleep except the selected one,
/// so restoring 50 tabs costs one web process, not 50.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var windows: [WindowRecord]

    public init(windows: [WindowRecord]) {
        self.windows = windows
    }
}

public struct WindowRecord: Codable, Sendable, Equatable {
    public var tabs: [TabRecord]
    public var selectedIndex: Int
    /// `NSStringFromRect` form of the window frame.
    public var frame: String?

    public init(tabs: [TabRecord], selectedIndex: Int, frame: String? = nil) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.frame = frame
    }
}

public struct TabRecord: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var isPinned: Bool
    /// WebKit's opaque back/forward state (`WKWebView.interactionState`).
    public var interactionState: Data?

    public init(url: String, title: String, isPinned: Bool = false, interactionState: Data? = nil) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.interactionState = interactionState
    }
}
