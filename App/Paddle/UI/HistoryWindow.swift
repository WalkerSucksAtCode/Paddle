import AppKit
import PaddleCore
import SwiftUI

/// History > Show All History: every visit, newest first, grouped by day and searchable.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: HistoryWindowController?

    static func show() {
        let controller = shared ?? HistoryWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: HistoryView(app: AppModel.shared))
        // Only a minimum from SwiftUI; otherwise the window shrinks to the list's ideal height.
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(NSSize(width: 640, height: 560))
        window.setFrameAutosaveName("PaddleHistory")
        if !window.setFrameUsingName("PaddleHistory") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Closing drops the window and its list; the next Show All History starts fresh.
    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

private struct HistoryView: View {
    let app: AppModel
    @State private var query = ""
    @State private var visits: [HistoryVisit] = []
    @State private var limit = 300
    @State private var selection: Set<Int64> = []
    @State private var pageCount = 0

    private struct Day: Identifiable {
        var id: Date
        var title: String
        var visits: [HistoryVisit]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search History", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Clear History…") { ClearHistoryPrompt.run(for: NSApp.keyWindow) }
            }
            .padding(10)
            Divider()
            if app.history == nil {
                ContentUnavailableView("History is off", systemImage: "clock", description: Text("historyDays is 0 in config.json."))
                    .frame(maxHeight: .infinity)
            } else if visits.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No history yet" : "No matches", systemImage: "clock")
                    .frame(maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            Text("\(pageCount.formatted()) pages")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(minWidth: 420, minHeight: 300)
        .task(id: "\(query)|\(limit)|\(app.historyGeneration)") { reload() }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(days) { day in
                Section(day.title) {
                    ForEach(day.visits) { visit in
                        row(visit).tag(visit.id)
                    }
                }
            }
            if visits.count >= limit {
                Button("Show More") { limit += 300 }
                    .buttonStyle(.link)
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("Open") { open(ids, newTab: false) }
            Button("Open in New Tab") { open(ids, newTab: true) }
            Button("Copy Link") { copy(ids) }
            Divider()
            Button("Delete from History") { delete(ids) }
        } primaryAction: { ids in
            open(ids, newTab: false)
        }
        .onDeleteCommand { delete(selection) }
    }

    private func row(_ visit: HistoryVisit) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? SuggestionRanker.displayURL(visit.url) : visit.title)
                    .lineLimit(1)
                Text(SuggestionRanker.displayURL(visit.url))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(visit.date, format: .dateTime.hour().minute())
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(visit.url)
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visits) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            }
            return Day(id: day, title: title, visits: grouped[day] ?? [])
        }
    }

    private func reload() {
        guard let history = app.history else {
            visits = []
            pageCount = 0
            return
        }
        visits = (try? history.visits(matching: query, limit: limit)) ?? []
        pageCount = history.pageCount
    }

    private func urls(_ ids: Set<Int64>) -> [URL] {
        visits.filter { ids.contains($0.id) }.compactMap { URL(string: $0.url) }
    }

    private func open(_ ids: Set<Int64>, newTab: Bool) {
        let urls = urls(ids)
        for (index, url) in urls.enumerated() {
            AppModel.shared.openFromHistory(url, newTab: newTab || index > 0)
        }
    }

    private func copy(_ ids: Set<Int64>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls(ids).map(\.absoluteString).joined(separator: "\n"), forType: .string)
    }

    private func delete(_ ids: Set<Int64>) {
        for url in Set(visits.filter { ids.contains($0.id) }.map(\.url)) {
            AppModel.shared.removeFromHistory(url)
        }
        selection = []
    }
}

/// History > Clear History…: the last hour, today, today and yesterday, or everything.
enum ClearHistoryPrompt {
    private static let choices: [(title: String, since: () -> Date?)] = [
        ("the last hour", { Date().addingTimeInterval(-3600) }),
        ("today", { Calendar.current.startOfDay(for: Date()) }),
        ("today and yesterday", { Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())) }),
        ("all history", { nil }),
    ]

    static func run(for window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Removes the pages you visited from Paddle's history and forgets recently closed tabs. Cookies, logins and open tabs stay."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: choices.map(\.title))
        popup.selectItem(at: 1)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            AppModel.shared.clearHistory(since: choices[popup.indexOfSelectedItem].since())
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// Fills the History menu with recently visited pages each time it opens (not on every key press,
/// which is when `menuNeedsUpdate` would run).
final class HistoryMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = HistoryMenuDelegate()
    private static let recentTag = 7_001
    private static let recentCount = 15

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.recentTag }.forEach(menu.removeItem)
        guard let anchor = menu.items.firstIndex(where: { $0.identifier?.rawValue == "showHistory" }),
              let pages = try? AppModel.shared.history?.recentPages(limit: Self.recentCount), !pages.isEmpty else { return }
        var index = anchor + 1
        let separator = NSMenuItem.separator()
        separator.tag = Self.recentTag
        menu.insertItem(separator, at: index)
        for page in pages {
            index += 1
            let title = page.title.isEmpty ? SuggestionRanker.displayURL(page.url) : page.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(AppDelegate.paddleOpenHistoryItem(_:)), keyEquivalent: "")
            item.target = NSApp.delegate
            item.representedObject = page.url
            item.toolTip = page.url
            item.tag = Self.recentTag
            menu.insertItem(item, at: index)
        }
    }
}
