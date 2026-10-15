import AppKit
import SwiftUI

/// One open tab in the search list, copied out so rows hold no `Tab` and never touch a web view.
private struct TabSearchEntry: Identifiable {
    let id: UUID
    let title: String
    let url: URL?
    let detail: String
    let lastActive: Date?
    let model: BrowserModel
    let tab: Tab
}

/// The popover behind Search Tabs… (Shift-Cmd-A): every open tab of the same kind of window, filtered as you type.
struct TabSearchView: View {
    let model: BrowserModel
    @State private var query = ""
    @State private var highlighted: UUID?
    @FocusState private var focused: Bool
    @Environment(\.chromeScale) private var scale

    private var entries: [TabSearchEntry] {
        var result: [TabSearchEntry] = []
        for controller in AppModel.shared.windows where controller.model.isPrivate == model.isPrivate {
            let other = controller.model !== model
            let several = controller.model.spaces.count > 1
            for tab in controller.model.allTabs {
                var parts = [tab.settingsPane != nil ? "Settings" : (tab.url?.host() ?? "")]
                if several { parts.append(controller.model.space(of: tab).name) }
                if other { parts.append("Other window") }
                if tab.isAsleep { parts.append("Asleep") }
                result.append(TabSearchEntry(
                    id: tab.id, title: tab.displayTitle, url: tab.url,
                    detail: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                    lastActive: tab.lastActive, model: controller.model, tab: tab))
            }
        }
        result.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return result }
        return result.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.url?.absoluteString.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        let shown = entries
        VStack(spacing: 0) {
            TextField("Search tabs", text: $query)
                .textFieldStyle(.plain)
                .chromeFont(size: 14)
                .padding(10)
                .focused($focused)
                .accessibilityLabel("Search tabs")
                .onKeyPress(.downArrow) { move(1, in: shown); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: shown); return .handled }
                .onKeyPress(.return) {
                    if let entry = shown.first(where: { $0.id == highlighted }) ?? shown.first { open(entry) }
                    return .handled
                }
                .onKeyPress(.escape) { model.tabSearchVisible = false; return .handled }
            Divider()
            if shown.isEmpty {
                Text("No matching tabs")
                    .chromeFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { entry in
                                row(entry, isHighlighted: (shown.first { $0.id == highlighted } ?? shown.first)?.id == entry.id)
                                    .id(entry.id)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 360 * scale)
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 420 * scale)
        .onAppear {
            focused = true
        }
        .onChange(of: query) { _, _ in highlighted = nil }
    }

    private func row(_ entry: TabSearchEntry, isHighlighted: Bool) -> some View {
        Button { open(entry) } label: {
            HStack(spacing: 8) {
                FaviconView(url: entry.url, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).chromeFont(size: 13).lineLimit(1)
                    if !entry.detail.isEmpty {
                        Text(entry.detail).chromeFont(size: 11).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Color.primary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.detail.isEmpty ? entry.title : "\(entry.title), \(entry.detail)")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private func move(_ step: Int, in shown: [TabSearchEntry]) {
        guard !shown.isEmpty else { return }
        let current = shown.firstIndex { $0.id == (highlighted ?? shown.first?.id) } ?? 0
        highlighted = shown[min(max(current + step, 0), shown.count - 1)].id
    }

    private func open(_ entry: TabSearchEntry) {
        model.tabSearchVisible = false
        entry.model.select(entry.tab)
        entry.model.controller?.window?.makeKeyAndOrderFront(nil)
    }
}

extension View {
    /// Attaches the Search Tabs popover to this view: the strip's leading inset, or the sidebar's top row.
    func tabSearchPopover(model: BrowserModel) -> some View {
        popover(isPresented: Bindable(model).tabSearchVisible, arrowEdge: .bottom) { TabSearchView(model: model).systemText() }
    }
}
