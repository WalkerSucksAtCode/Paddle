import Foundation

/// A section of Paddle's New Tab page. `newTabSections` in config.json lists them top to bottom by these names.
public enum NewTabSection: String, Sendable, CaseIterable, Identifiable {
    case pinned, frequent, notifications, news

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pinned: "Pinned sites"
        case .frequent: "Frequently visited"
        case .notifications: "Notifications"
        case .news: "News"
        }
    }

    /// The order to draw: `names` as written, with unknown names and repeats dropped, then any section the list
    /// leaves out in Paddle's default order, so every section always has a place.
    public static func order(_ names: [String]) -> [NewTabSection] {
        var seen: [NewTabSection] = []
        for name in names {
            guard let section = NewTabSection(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()),
                  !seen.contains(section) else { continue }
            seen.append(section)
        }
        return seen + allCases.filter { !seen.contains($0) }
    }
}

extension PaddleConfig {
    /// `newTabSections` as sections, each exactly once.
    public var newTabSectionOrder: [NewTabSection] { NewTabSection.order(newTabSections) }
}
