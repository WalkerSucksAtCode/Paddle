import AppKit
import PaddleCore
import SwiftUI

struct TabStrip: View {
    @Bindable var model: BrowserModel
    @Namespace private var rotor
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeReducesMotion) private var reducesMotion

    /// Room for the traffic lights.
    private let leadingInset: CGFloat = 78
    private var pinnedWidth: CGFloat { 40 * scale }

    /// One thing in the strip: a group's label or a tab. The tabs of a collapsed group are left out.
    private struct StripItem: Identifiable {
        var group: TabGroup?
        var tab: Tab?
        var id: UUID { group?.id ?? tab?.id ?? UUID() }
    }

    /// The strip in order: a label before each group's first tab, and no tabs of collapsed groups.
    private var stripItems: [StripItem] {
        var items: [StripItem] = []
        var lastGroup: UUID?
        for tab in model.tabs {
            if let group = model.group(of: tab) {
                if group.id != lastGroup { items.append(StripItem(group: group)) }
                if !group.isCollapsed { items.append(StripItem(tab: tab)) }
            } else {
                items.append(StripItem(tab: tab))
            }
            lastGroup = tab.groupID
        }
        return items
    }

    private func labelWidth(_ group: TabGroup) -> CGFloat {
        TabGroupLabel.width(for: group, count: model.tabs(in: group).count, renaming: model.renamingGroupID == group.id, scale: scale)
    }

    var body: some View {
        GeometryReader { geometry in
            let items = stripItems
            let pinnedCount = CGFloat(model.tabs.filter(\.isPinned).count)
            let shownUnpinned = CGFloat(items.filter { $0.tab.map { !$0.isPinned } ?? false }.count)
            let labelsWidth = items.reduce(CGFloat(0)) { $0 + ($1.group.map(labelWidth) ?? 0) }
            let switcherWidth = model.spaces.count > 1 ? SpaceSwitcher.width * scale + 4 : 0
            let available = geometry.size.width - leadingInset - switcherWidth - 44 - pinnedCount * (pinnedWidth + 2) - labelsWidth - 2 * CGFloat(items.filter { $0.tab == nil }.count)
            let width = shownUnpinned == 0 ? 0 : min(240 * scale, max(TabButton.alwaysCloseWidth * scale, available / shownUnpinned - 2))
            let tabsWidth = pinnedCount * pinnedWidth + shownUnpinned * width + labelsWidth + 2 * max(0, CGFloat(items.count) - 1)

            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: leadingInset)
                        .tabSearchPopover(model: model)
                    if model.spaces.count > 1 {
                        SpaceSwitcher(model: model)
                            .padding(.trailing, 4)
                    }
                }
                .spaceEditPopover(model: model)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(items) { item in
                                if let group = item.group {
                                    TabGroupLabel(group: group, model: model)
                                } else if let tab = item.tab {
                                    TabButton(tab: tab, model: model, group: model.group(of: tab), isRenaming: model.renamingTabID == tab.id,
                                              width: tab.isPinned ? pinnedWidth : width)
                                        .accessibilityRotorEntry(id: tab.id, in: rotor)
                                        .transition(.opacity)
                                }
                            }
                        }
                        .padding(.vertical, 5)
                        .animation(reducesMotion ? nil : .easeOut(duration: 0.12), value: model.activeSpaceID)
                        .background(WindowDragArea())
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The tabs take their own width, so New Tab follows the last tab; the scroll view gets the rest.
                    .frame(width: min(tabsWidth, max(0, geometry.size.width - leadingInset - switcherWidth - 44)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tabs")
                    // VoiceOver's rotor lists the tabs with their state ("selected", "asleep", "muted").
                    .accessibilityRotor("Tabs") {
                        ForEach(items.compactMap(\.tab)) { tab in
                            AccessibilityRotorEntry(Text(TabButton.spokenEntry(tab, selected: model.selectedID == tab.id, group: model.group(of: tab))), id: tab.id, in: rotor)
                        }
                    }
                    // With more tabs than fit, keep the selected one on screen (Ctrl-Tab, Cmd-9, new tabs).
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(reducesMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
                Button {
                    model.openNewTabPage()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Tab")
                .accessibilityLabel("New Tab")
                .padding(.leading, 4)
                Spacer(minLength: 12)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .background(WindowDragArea())
        }
    }
}


/// The text field for renaming a tab, in the tab itself or (pinned tabs) in a popover. Return or focus loss keeps
/// the edited name (the page's title back when it is empty or unchanged from what was shown); Escape cancels.
struct TabRenameField: View {
    let tab: Tab
    let model: BrowserModel
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tab name", text: $draft, selection: $selection)
            .textFieldStyle(.plain)
            .chromeFont(size: 12)
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.escape) {
                model.renamingTabID = nil
                return .handled
            }
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
            }
            .onAppear {
                draft = tab.displayTitle
                // Next turn, so the click that started the rename can't take the focus straight back.
                DispatchQueue.main.async {
                    focused = true
                    selection = TextSelection(range: draft.startIndex..<draft.endIndex)
                }
            }
    }

    /// Escape clears `renamingTabID` first, so it never lands here.
    private func commit() {
        guard model.renamingTabID == tab.id else { return }
        if draft != tab.displayTitle { model.rename(tab, to: draft) }
        model.renamingTabID = nil
    }
}

struct TabButton: View {
    let tab: Tab
    let model: BrowserModel
    /// The tab's group and whether its title is being edited, read once by the strip so an unrelated change to
    /// `groups` or `renamingTabID` doesn't redraw every tab.
    let group: TabGroup?
    let isRenaming: Bool
    let width: CGFloat
    @State private var hovering = false
    /// The tab's memory when the pointer arrived, for the tooltip. Read in the hover handler rather than in
    /// `body`, so a new sample doesn't redraw every tab button.
    @State private var hoverMemory: (bytes: UInt64, shared: Bool)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeHighContrastTabs) private var highContrast
    @Environment(\.chromeTheme) private var theme

    private var isSelected: Bool { model.selectedID == tab.id }
    /// Shown now: the selected tab, or the other side of its split.
    private var isShown: Bool { isSelected || model.visibleTabs.contains { $0.id == tab.id } }
    /// From this width (at text size 100 %) every tab shows its close button.
    static let alwaysCloseWidth: CGFloat = 110
    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    var body: some View {
        HStack(spacing: 6) {
            icon
            if !tab.isPinned {
                if model.splitSide(of: tab) == .left, let other = model.partner(of: tab) {
                    Image(systemName: "rectangle.split.2x1")
                        .chromeFont(size: 10)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Split with \(other.displayTitle)")
                }
                if isRenaming {
                    TabRenameField(tab: tab, model: model)
                } else {
                    Text(tab.displayTitle)
                        .chromeFont(size: 12, weight: highContrast && isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(!tab.isAsleep || isSelected ? .primary : .secondary)
                        // A double-click renames (`TabDragController` sees it on the mouse-down). Not a SwiftUI
                        // double-tap gesture: that holds every single click on the title back by the double-click
                        // interval (measured: ~350 ms per switch).
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
                // Every tab wide enough for one shows its close button, not only the hovered one; a narrow tab keeps the
                // room for its title and shows it on hover or when selected.
                if AppModel.shared.config.alwaysShowTabCloseButtons || hovering || isSelected || width >= Self.alwaysCloseWidth * scale {
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
                }
            }
        }
        .padding(.horizontal, tab.isPinned ? 0 : 8)
        .frame(width: width, height: 28)
        // A pinned tab has no room for a field: its name is edited in a popover.
        .popover(isPresented: Binding(
            get: { tab.isPinned && isRenaming },
            set: { if !$0, model.renamingTabID == tab.id { model.renamingTabID = nil } }
        ), arrowEdge: .bottom) {
            TabRenameField(tab: tab, model: model)
                .systemText()
                .padding(8)
                .frame(width: 220)
        }
        // The pinned tab's name popover closing (commit or cancel) hands the keyboard back to the page.
        .onChange(of: isRenaming) { was, now in
            guard was, !now, tab.isPinned else { return }
            DispatchQueue.main.async { model.controller?.focusWebView() }
        }
        .background {
            // The selected tab is lighter than the strip in dark mode and darker in light mode, with an edge, so it
            // stands out by brightness alone: the window background colour it used before matched the strip.
            // A theme's selected-tab color replaces the fill; the edge and the hover wash come from its text color.
            let ink: Color = theme?.text ?? .primary
            RoundedRectangle(cornerRadius: 7)
                .fill(isShown ? (theme?.selectedTab ?? ink.opacity(highContrast ? 0.30 : 0.14)) : ink.opacity(hovering ? 0.06 : 0))
                .overlay {
                    // The other side of a shown split has a weaker edge than the focused one.
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(ink.opacity(isShown ? (highContrast ? 0.55 : 0.18) * (isSelected ? 1 : 0.5) : 0), lineWidth: highContrast ? 1.5 : 1)
                }
        }
        // A grouped tab carries its group's colour along the bottom edge, so the group's extent shows.
        .overlay(alignment: .bottom) {
            if let group {
                // 3 pt with a faint edge: the lightest fills (yellow, pink, cyan) alone are under 3:1 against the strip.
                Rectangle().fill(group.color.fill(scheme)).frame(height: 3)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                    .padding(.horizontal, 3)
            }
        }
        .splitBracket(model.splitSide(of: tab), vertical: false, ink: theme?.text ?? .primary)
        .contentShape(Rectangle())
        .onTapGesture {
            SwitchTrace.tapped(tab)
            model.select(tab)
        }
        // A middle click closes the tab, as in other browsers.
        .overlay(MiddleClickCatcher { model.close(tab) })
        // With keyboard navigation on (System Settings > Keyboard), Tab reaches each tab; Space or Return selects it.
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            if isRenaming { return .ignored }
            model.select(tab)
            return .handled
        }
        // One element for VoiceOver: the title, its state as the value, and the tab's actions.
        // While the title is a text field in the tab, VoiceOver reaches the field instead.
        .accessibilityElement(children: isRenaming && !tab.isPinned ? .contain : .ignore)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isRenaming && !tab.isPinned ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(tab) }
        .accessibilityAction(named: "Close Tab") { model.close(tab) }
        .accessibilityAction(named: tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
        .accessibilityAction(named: tab.isMuted ? "Unmute Tab" : "Mute Tab") {
            if Tab.supportsMuting { model.toggleMute(tab) }
        }
        .onHover { inside in
            hovering = inside
            model.pointerRests(on: tab, inside)
            if inside { hoverMemory = tab.memoryBytes.map { ($0, tab.sharesProcess) } }
        }
        .help(tooltip)
        .modifier(TabDrag(tab: tab, enabled: !isRenaming))
        .overlay { TabDropBar(tab: tab, model: model, vertical: false) }
        .contextMenu { TabContextMenu(tab: tab, model: model) }
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.isCapturing {
                Image(systemName: "video.fill")
            } else if tab.settingsPane != nil {
                Image(systemName: "gearshape")
            } else {
                FaviconView(url: tab.url, fallback: tab.isPinned ? "pin.fill" : "globe", dimmed: !tab.isAwake)
            }
        }
        .chromeFont(size: 11)
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14)
        // Pinned tabs have no room for a button: a small speaker on the icon; mute from the context menu.
        .overlay(alignment: .bottomTrailing) {
            if tab.isPinned, audio != .none {
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

    /// "Pinned, asleep, muted": the tab's state as VoiceOver's value. Selection is the trait, not part of it.
    static func spokenState(_ tab: Tab, audio: AudioIndicator) -> String {
        var parts: [String] = []
        if tab.isPinned { parts.append("pinned") }
        if tab.isAsleep { parts.append("asleep") }
        if tab.isFrozen { parts.append("frozen") }
        if tab.isLoading { parts.append("loading") }
        if tab.isCapturing { parts.append("using camera or microphone") }
        switch audio {
        case .playing: parts.append("playing audio")
        case .muted: parts.append("muted")
        case .none: break
        }
        return parts.joined(separator: ", ")
    }

    /// A rotor entry: the title, then "selected" and the state.
    static func spokenEntry(_ tab: Tab, selected: Bool, group: TabGroup? = nil) -> String {
        let audio = AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted)
        let grouped = group.map { "in group \($0.name.isEmpty ? "Unnamed" : $0.name)" } ?? ""
        let state = [selected ? "selected" : "", spokenState(tab, audio: audio), grouped].filter { !$0.isEmpty }
        return ([tab.displayTitle] + state).joined(separator: ", ")
    }

    /// The state, plus the group the tab is in.
    private var spokenValue: String {
        let state = model.spokenSplit(of: tab, after: Self.spokenState(tab, audio: audio))
        guard let group else { return state }
        let name = group.name.isEmpty ? "Unnamed" : group.name
        return state.isEmpty ? "in group \(name)" : "\(state), in group \(name)"
    }

    private var tooltip: String { Self.tooltip(tab, audio: audio, memory: hoverMemory) }

    /// The hover text: title, the page's title when renamed, address, audio, memory and sleep state. Shared with the sidebar.
    static func tooltip(_ tab: Tab, audio: AudioIndicator, memory: (bytes: UInt64, shared: Bool)?) -> String {
        var lines = [tab.displayTitle]
        if let custom = tab.customTitle, !custom.isEmpty { lines.append("Page: \(tab.title.isEmpty ? (tab.url?.host() ?? "") : tab.title)") }
        if let url = tab.url { lines.append(url.absoluteString) }
        switch audio {
        case .playing: lines.append("Playing audio")
        case .muted: lines.append("Muted")
        case .none: break
        }
        if tab.isAsleep {
            lines.append("Asleep: no memory used. Click to wake.")
        } else if let memory {
            lines.append("Memory: \(ProcessMemory.format(memory.bytes))\(memory.shared ? " (shared with other tabs from this site)" : "")")
        }
        if tab.isFrozen { lines.append("Frozen: paused, shows again without a reload.") }
        return lines.joined(separator: "\n")
    }
}
