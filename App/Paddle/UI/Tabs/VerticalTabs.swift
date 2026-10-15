import AppKit
import PaddleCore
import SwiftUI

/// Sizes and UserDefaults keys of the vertical tabs sidebar. Width and collapsed state are shared by every window.
enum SidebarMetrics {
    static let widthKey = "verticalTabsWidth"
    static let collapsedKey = "verticalTabsCollapsed"
    static let defaultWidth = 240.0
    static let minWidth = 170.0
    static let maxWidth = 420.0
    static let collapsedWidth = 52.0
    /// Room for the traffic lights.
    static let trafficLightInset = 78.0

    static func clamped(_ width: Double) -> Double { min(maxWidth, max(minWidth, width)) }
}

/// The tabs as a column beside the page: pinned tabs as a grid of tiles, then the other tabs and groups as a list.
struct VerticalTabsSidebar: View {
    @Bindable var model: BrowserModel
    /// Full screen has no traffic lights, so the top row needs no room for them.
    var fullScreen = false
    @AppStorage(SidebarMetrics.widthKey) private var storedWidth = SidebarMetrics.defaultWidth
    @AppStorage(SidebarMetrics.collapsedKey) private var collapsed = false
    @State private var dragStartWidth: Double?
    @Namespace private var rotor
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeReducesMotion) private var reducesMotion

    /// One row of the list: a group's header or a tab (with its group, looked up once for the whole list).
    private enum Item: Identifiable {
        case group(TabGroup, count: Int)
        case tab(Tab, group: TabGroup?)

        var id: UUID {
            switch self {
            case .group(let group, _): group.id
            case .tab(let tab, _): tab.id
            }
        }
    }

    /// The unpinned tabs in order, a header before each group's first tab and none of a collapsed group's tabs.
    private func listItems() -> [Item] {
        let groupsByID = Dictionary(model.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [UUID: Int] = [:]
        for tab in model.tabs { if let id = tab.groupID { counts[id, default: 0] += 1 } }
        var items: [Item] = []
        var lastGroup: UUID?
        for tab in model.tabs where !tab.isPinned {
            if let id = tab.groupID, let group = groupsByID[id] {
                if id != lastGroup { items.append(.group(group, count: counts[id] ?? 0)) }
                if !group.isCollapsed { items.append(.tab(tab, group: group)) }
            } else {
                items.append(.tab(tab, group: nil))
            }
            lastGroup = tab.groupID
        }
        return items
    }

    var body: some View {
        let pinned = model.tabs.filter(\.isPinned)
        let items = listItems()
        VStack(spacing: 0) {
            topRow
            if collapsed {
                VStack(spacing: 2) {
                    collapseButton
                    newTabButton
                }
                .padding(.bottom, 4)
            }
            VStack(spacing: 0) {
                if !pinned.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44 * scale), spacing: 4)], spacing: 4) {
                        ForEach(pinned) { tab in
                            PinnedTile(tab: tab, model: model, isRenaming: model.renamingTabID == tab.id, iconsOnly: collapsed)
                                .accessibilityRotorEntry(id: tab.id, in: rotor)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    if !items.isEmpty { Divider().padding(.horizontal, 8) }
                }
                list(items)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
            // VoiceOver's rotor lists the tabs with their state, as the strip's does.
            .accessibilityRotor("Tabs") {
                ForEach(pinned.map { (tab: $0, group: nil as TabGroup?) } + items.compactMap { if case .tab(let tab, let group) = $0 { (tab: tab, group: group) } else { nil } }, id: \.tab.id) { entry in
                    AccessibilityRotorEntry(Text(TabButton.spokenEntry(entry.tab, selected: model.selectedID == entry.tab.id, group: entry.group)), id: entry.tab.id, in: rotor)
                }
            }
        }
        .frame(width: collapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.clamped(storedWidth))
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { resizeHandle }
    }

    // MARK: Top row

    /// The title-bar row: room for the traffic lights, then empty space that drags the window, and the two buttons.
    /// Collapsed, the sidebar is narrower than the traffic lights, which then overhang into the toolbar's row.
    private var topRow: some View {
        HStack(spacing: 0) {
            if !collapsed {
                if !fullScreen { Color.clear.frame(width: SidebarMetrics.trafficLightInset) }
                Spacer(minLength: 0)
                collapseButton
                newTabButton
                    .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(WindowDragArea())
        .tabSearchPopover(model: model)
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(collapsed ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityLabel(collapsed ? "Expand Sidebar" : "Collapse Sidebar")
    }

    private var newTabButton: some View {
        Button {
            model.openNewTabPage()
        } label: {
            Image(systemName: "plus")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }

    // MARK: List

    private func list(_ items: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        switch item {
                        case .group(let group, let count):
                            SidebarGroupHeader(group: group, count: count, model: model, iconsOnly: collapsed)
                                .id(item.id)
                        case .tab(let tab, let group):
                            SidebarTabRow(tab: tab, model: model, group: group, isRenaming: model.renamingTabID == tab.id, iconsOnly: collapsed)
                                .id(item.id)
                                .accessibilityRotorEntry(id: tab.id, in: rotor)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(WindowDragArea())
            }
            .scrollBounceBehavior(.basedOnSize)
            // With more tabs than fit, keep the selected one on screen (Ctrl-Tab, Cmd-9, new tabs).
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(reducesMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    // MARK: Resizing

    /// An invisible strip on the trailing edge: drag to resize.
    @ViewBuilder
    private var resizeHandle: some View {
        if !collapsed {
            Color.clear
                .frame(width: 6)
                .contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartWidth ?? SidebarMetrics.clamped(storedWidth)
                            dragStartWidth = start
                            storedWidth = SidebarMetrics.clamped(start + value.translation.width)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Icon

/// The tab's state icon: loading, camera or microphone, Settings gear, asleep, else its favicon. The same choice as the strip.
private struct TabStateIcon: View {
    let tab: Tab
    var size: CGFloat = 14
    /// Show the audio state as a small speaker on the icon (pinned tiles and the collapsed list have no room for a button).
    var audioBadge = false

    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    var body: some View {
        Group {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.isCapturing {
                Image(systemName: "video.fill")
            } else if tab.settingsPane != nil {
                Image(systemName: "gearshape")
            } else if !tab.isAwake {
                Glyph(name: "surf-tab-sleep")
            } else {
                FaviconView(url: tab.url, fallback: tab.isPinned ? "pin.fill" : "globe", size: size)
            }
        }
        .chromeFont(size: size - 3)
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if audioBadge, audio != .none {
                Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .chromeFont(size: 7, weight: .bold)
                    .foregroundStyle(.secondary)
                    .padding(1)
                    .background(Circle().fill(.background))
                    .offset(x: 5, y: 4)
                    .accessibilityLabel(audio == .muted ? "Muted" : "Playing audio")
            }
        }
    }
}

/// What tabs in the sidebar share: selection, drag and drop, middle click, the menu, the tooltip and VoiceOver.
private struct SidebarTabBehavior: ViewModifier {
    let tab: Tab
    let model: BrowserModel
    let group: TabGroup?
    let isRenaming: Bool
    /// The rename field is inline (a list row); otherwise it is in a popover.
    let inlineRename: Bool
    let tooltip: String
    let onHover: (Bool) -> Void

    private var isSelected: Bool { model.selectedID == tab.id }
    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            // A middle click closes the tab, as in other browsers.
            .overlay(MiddleClickCatcher { model.close(tab) })
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                if isRenaming { return .ignored }
                model.select(tab)
                return .handled
            }
            .accessibilityElement(children: isRenaming && inlineRename ? .contain : .ignore)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(spokenValue)
            .accessibilityAddTraits(isRenaming && inlineRename ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab) }
            .accessibilityAction(named: "Close Tab") { model.close(tab) }
            .accessibilityAction(named: tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
            .accessibilityAction(named: tab.isMuted ? "Unmute Tab" : "Mute Tab") {
                if Tab.supportsMuting { model.toggleMute(tab) }
            }
            .onHover(perform: onHover)
            .help(tooltip)
            .modifier(TabDrag(id: tab.id.uuidString, enabled: !isRenaming))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)),
                      let dragged = model.tabs.first(where: { $0.id == id }) else { return false }
                return model.move(dragged, onto: tab)
            }
            .contextMenu { TabContextMenu(tab: tab, model: model) }
            // Without room for a field the name is edited in a popover; closing it hands the keyboard back to the page.
            .popover(isPresented: Binding(
                get: { !inlineRename && isRenaming },
                set: { if !$0, model.renamingTabID == tab.id { model.renamingTabID = nil } }
            ), arrowEdge: .trailing) {
                TabRenameField(tab: tab, model: model)
                    .systemText()
                    .padding(8)
                    .frame(width: 220)
            }
            .onChange(of: isRenaming) { was, now in
                guard was, !now, !inlineRename else { return }
                DispatchQueue.main.async { model.controller?.focusWebView() }
            }
    }

    private var spokenValue: String {
        let state = TabButton.spokenState(tab, audio: audio)
        guard let group else { return state }
        let name = group.name.isEmpty ? "Unnamed" : group.name
        return state.isEmpty ? "in group \(name)" : "\(state), in group \(name)"
    }
}

/// The selected tab is brighter than the sidebar in both appearances, with an edge, so it stands out by brightness alone.
/// With `highContrast` the fill and edge are stronger, still by brightness only.
/// A theme's selected-tab color replaces the fill; the edge and the washes come from its text color.
private func sidebarBackground(selected: Bool, hovering: Bool, radius: CGFloat, highContrast: Bool, theme: ResolvedChromeTheme?, selectedFill: Double = 0.14, idleFill: Double = 0, hoverFill: Double = 0.06) -> some View {
    let ink: Color = theme?.text ?? .primary
    return RoundedRectangle(cornerRadius: radius)
        .fill(selected ? (theme?.selectedTab ?? ink.opacity(highContrast ? 0.36 : selectedFill)) : ink.opacity(hovering ? hoverFill : idleFill))
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(ink.opacity(selected ? (highContrast ? 0.55 : 0.25) : 0), lineWidth: highContrast ? 1.5 : 1)
        }
}

// MARK: - Pinned tile

/// A pinned tab: a square tile with its icon.
private struct PinnedTile: View {
    let tab: Tab
    let model: BrowserModel
    let isRenaming: Bool
    let iconsOnly: Bool
    @State private var hovering = false
    @State private var hoverMemory: (bytes: UInt64, shared: Bool)?
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeHighContrastTabs) private var highContrast
    @Environment(\.chromeTheme) private var theme

    private var isSelected: Bool { model.selectedID == tab.id }
    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    var body: some View {
        TabStateIcon(tab: tab, size: 16, audioBadge: true)
            .frame(width: 44 * scale, height: 36 * scale)
            .background(sidebarBackground(selected: isSelected, hovering: hovering, radius: 8, highContrast: highContrast, theme: theme, selectedFill: 0.20, idleFill: 0.05, hoverFill: 0.10))
            .modifier(SidebarTabBehavior(
                tab: tab, model: model, group: nil, isRenaming: isRenaming, inlineRename: false,
                tooltip: TabButton.tooltip(tab, audio: audio, memory: hoverMemory)
            ) { inside in
                hovering = inside
                if inside { hoverMemory = tab.memoryBytes.map { ($0, tab.sharesProcess) } }
            })
    }
}

// MARK: - Tab row

/// An unpinned tab: icon, title, speaker and close button. Collapsed to its icon when the sidebar is.
private struct SidebarTabRow: View {
    let tab: Tab
    let model: BrowserModel
    /// Read once by the list so an unrelated change to `groups` or `renamingTabID` doesn't redraw every row.
    let group: TabGroup?
    let isRenaming: Bool
    let iconsOnly: Bool
    @State private var hovering = false
    @State private var hoverMemory: (bytes: UInt64, shared: Bool)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeHighContrastTabs) private var highContrast
    @Environment(\.chromeTheme) private var theme

    private var isSelected: Bool { model.selectedID == tab.id }
    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    var body: some View {
        HStack(spacing: 8) {
            TabStateIcon(tab: tab, audioBadge: iconsOnly)
            if !iconsOnly {
                if isRenaming {
                    TabRenameField(tab: tab, model: model)
                } else {
                    Text(tab.displayTitle)
                        .chromeFont(size: 12.5, weight: highContrast && isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(!tab.isAsleep || isSelected ? .primary : .secondary)
                        // Alongside the row's own click, so a single click still selects at once.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.select(tab)
                            model.renamingTabID = tab.id
                        })
                }
                Spacer(minLength: 0)
                if audio != .none {
                    Button {
                        model.toggleMute(tab)
                    } label: {
                        Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .chromeFont(size: 10)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!Tab.supportsMuting)
                    .help(audio == .muted ? "Unmute Tab" : "Mute Tab")
                    .accessibilityLabel(audio == .muted ? "Unmute Tab" : "Mute Tab")
                }
                let closeShown = hovering || isSelected
                Button {
                    model.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .chromeFont(size: 9, weight: .bold)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
                .opacity(closeShown ? 1 : 0)
                .allowsHitTesting(closeShown)
                .accessibilityHidden(!closeShown)
            }
        }
        .padding(.horizontal, iconsOnly ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: iconsOnly ? .center : .leading)
        .frame(height: 30 * scale)
        .background(sidebarBackground(selected: isSelected, hovering: hovering, radius: 7, highContrast: highContrast, theme: theme))
        // A grouped tab carries its group's colour along its leading edge, so the group's extent shows.
        .overlay(alignment: .leading) {
            if let group {
                // 3 pt with a faint edge: the lightest fills (yellow, pink, cyan) alone are under 3:1 against the sidebar.
                Rectangle().fill(group.color.fill(scheme)).frame(width: 3)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                    .padding(.vertical, 3)
            }
        }
        .padding(.leading, group != nil && !iconsOnly ? 10 : 0)
        .modifier(SidebarTabBehavior(
            tab: tab, model: model, group: group, isRenaming: isRenaming, inlineRename: !iconsOnly,
            tooltip: TabButton.tooltip(tab, audio: audio, memory: hoverMemory)
        ) { inside in
            hovering = inside
            if inside { hoverMemory = tab.memoryBytes.map { ($0, tab.sharesProcess) } }
        })
    }
}

// MARK: - Group header

/// A group's header: a dot in its colour, name, tab count and a chevron. Click collapses or expands the group.
/// Collapsed to a thin bar in the group's colour when the sidebar is.
private struct SidebarGroupHeader: View {
    let group: TabGroup
    let count: Int
    let model: BrowserModel
    let iconsOnly: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chromeScale) private var scale
    @State private var hovering = false

    private var isRenaming: Bool { model.renamingGroupID == group.id }
    private var name: String { group.name.isEmpty ? "Unnamed" : group.name }

    var body: some View {
        Group {
            if iconsOnly {
                Rectangle().fill(group.color.fill(scheme))
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                    .frame(height: 4)
                    .padding(.horizontal, 4)
                    .frame(height: 14)
                    .popover(isPresented: Binding(
                        get: { isRenaming },
                        set: { if !$0, model.renamingGroupID == group.id { model.renamingGroupID = nil } }
                    ), arrowEdge: .trailing) {
                        GroupNameField(group: group, model: model)
                            .systemText()
                            .padding(8)
                            .frame(width: 200)
                    }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(group.color.fill(scheme))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                    if isRenaming {
                        GroupNameField(group: group, model: model)
                    } else {
                        Text(name)
                            .chromeFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("\(count)")
                            .chromeFont(size: 11)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .chromeFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .padding(.horizontal, 8)
                .frame(height: 26 * scale)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isRenaming { model.toggleCollapsed(group) } }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)),
                  let dragged = model.tabs.first(where: { $0.id == id }), !dragged.isPinned else { return false }
            model.add(dragged, to: group)
            return true
        }
        // While renaming, the text field is what VoiceOver reaches.
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(TabGroupLabel.spokenLabel(group, count: count))
        .accessibilityAddTraits(isRenaming ? [] : .isButton)
        .accessibilityAction { model.toggleCollapsed(group) }
        .accessibilityAction(named: "Rename Group") { model.renamingGroupID = group.id }
        .help(iconsOnly ? "\(name), \(count) \(count == 1 ? "tab" : "tabs")" : group.isCollapsed ? "Click to show the group's tabs" : "Click to collapse the group")
        .contextMenu { TabGroupContextMenu(group: group, model: model) }
    }
}

/// The text field for renaming a group. Return or focus loss keeps the edited name; Escape cancels.
private struct GroupNameField: View {
    let group: TabGroup
    let model: BrowserModel
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Group name", text: $draft, selection: $selection)
            .textFieldStyle(.plain)
            .chromeFont(size: 12, weight: .semibold)
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.escape) {
                model.renamingGroupID = nil
                return .handled
            }
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
            }
            .onAppear {
                draft = group.name
                // Next turn, so a click's own focus change can't take it straight back.
                DispatchQueue.main.async {
                    focused = true
                    selection = TextSelection(range: draft.startIndex..<draft.endIndex)
                }
            }
    }

    /// Escape clears `renamingGroupID` first, so it never lands here.
    private func commit() {
        guard model.renamingGroupID == group.id else { return }
        model.renameGroup(group, to: draft)
        model.renamingGroupID = nil
    }
}
