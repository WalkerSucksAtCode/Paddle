import AppKit
import PaddleCore
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
                .frame(height: 38)
            NavigationBar(model: model, app: app)
                // The suggestion dropdown hangs below the bar, over the page and the bookmarks bar.
                .zIndex(1)
            if app.showBookmarksBar {
                BookmarksBar(app: app)
            }
            if let error = app.configError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if let banner = app.extensions.bannerText {
                HStack(alignment: .top, spacing: 8) {
                    Label(banner, systemImage: "puzzlepiece.extension")
                        .font(.system(size: 11))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        app.extensions.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            // A Chrome Web Store detail page: offer to install it. Paddle's own bar; nothing runs in the page.
            if let tab = model.selectedTab, let url = tab.url, case .chromeWebStore(let id)? = StoreLink.isStoreDetailPage(url) {
                StoreInstallBar(id: id, pageTitle: tab.title, model: model)
            }
            if model.findVisible {
                FindBar(model: model)
            }
            Divider()
            content
        }
        .background(.bar)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.windowTitle, initial: true) { _, title in model.controller?.window?.title = title }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.selectedTab, tab.url != nil {
            WebContainer(tab: tab, generation: tab.generation)
        } else {
            StartPage()
        }
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @Bindable var model: BrowserModel
    @Namespace private var rotor

    /// Room for the traffic lights.
    private let leadingInset: CGFloat = 78
    private let pinnedWidth: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let pinnedCount = CGFloat(model.tabs.filter(\.isPinned).count)
            let unpinnedCount = CGFloat(model.tabs.count) - pinnedCount
            let available = geometry.size.width - leadingInset - 44 - pinnedCount * (pinnedWidth + 2)
            let width = unpinnedCount == 0 ? 0 : min(240, max(110, available / unpinnedCount - 2))

            HStack(spacing: 0) {
                Color.clear.frame(width: leadingInset)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { tab in
                                TabButton(tab: tab, model: model, width: tab.isPinned ? pinnedWidth : width)
                                    .accessibilityRotorEntry(id: tab.id, in: rotor)
                            }
                        }
                        .padding(.vertical, 5)
                        // Space after the last tab drags the window too.
                        .frame(minWidth: max(0, geometry.size.width - leadingInset - 36), alignment: .leading)
                        .background(WindowDragArea())
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tabs")
                    // VoiceOver's rotor lists the tabs with their state ("selected", "asleep", "muted").
                    .accessibilityRotor("Tabs") {
                        ForEach(model.tabs) { tab in
                            AccessibilityRotorEntry(Text(TabButton.spokenEntry(tab, selected: model.selectedID == tab.id)), id: tab.id, in: rotor)
                        }
                    }
                    // With more tabs than fit, keep the selected one on screen (Ctrl-Tab, Cmd-9, new tabs).
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
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
                .padding(.trailing, 8)
            }
            .background(WindowDragArea())
        }
    }
}

/// Empty tab-strip space acts as the title bar: drag to move the window, double-click to zoom or minimize
/// (whichever System Settings > Desktop & Dock chooses). Browser windows are not movable by the window server
/// (see `BrowserWindowController.init`), so this is the only place a window drag starts.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct TabButton: View {
    let tab: Tab
    let model: BrowserModel
    let width: CGFloat
    @State private var hovering = false
    /// The tab's memory when the pointer arrived, for the tooltip. Read in the hover handler rather than in
    /// `body`, so a new sample doesn't redraw every tab button.
    @State private var hoverMemory: (bytes: UInt64, shared: Bool)?

    private var isSelected: Bool { model.selectedID == tab.id }
    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    var body: some View {
        HStack(spacing: 6) {
            icon
            if !tab.isPinned {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tab.isAwake || isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
                if audio != .none {
                    Button {
                        model.toggleMute(tab)
                    } label: {
                        Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!Tab.supportsMuting)
                    .help(audio == .muted ? "Unmute Tab" : "Mute Tab")
                    .accessibilityLabel(audio == .muted ? "Unmute Tab" : "Mute Tab")
                }
                if hovering || isSelected {
                    Button {
                        model.close(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
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
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0)))
                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        // With keyboard navigation on (System Settings > Keyboard), Tab reaches each tab; Space or Return selects it.
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            model.select(tab)
            return .handled
        }
        // One element for VoiceOver: the title, its state as the value, and the tab's actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(Self.spokenState(tab, audio: audio))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(tab) }
        .accessibilityAction(named: "Close Tab") { model.close(tab) }
        .accessibilityAction(named: tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
        .accessibilityAction(named: tab.isMuted ? "Unmute Tab" : "Mute Tab") {
            if Tab.supportsMuting { model.toggleMute(tab) }
        }
        .onHover { inside in
            hovering = inside
            if inside { hoverMemory = tab.memoryBytes.map { ($0, tab.sharesProcess) } }
        }
        .help(tooltip)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)),
                  let dragged = model.tabs.first(where: { $0.id == id }) else { return false }
            return model.move(dragged, onto: tab)
        }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
            Button("Duplicate Tab") { model.duplicate(tab) }
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { model.toggleMute(tab) }
                .disabled(!Tab.supportsMuting)
            Button("Put Tab to Sleep") { model.sleep(tab) }
                .disabled(!tab.isAwake || isSelected)
            Divider()
            Button("Close Tab") { model.close(tab) }
            Button("Close Other Tabs") { model.closeOthers(tab) }
        }
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.isCapturing {
                Image(systemName: "video.fill")
            } else if !tab.isAwake {
                Glyph(name: "surf-tab-sleep")
            } else {
                FaviconView(url: tab.url, fallback: tab.isPinned ? "pin.fill" : "globe")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14)
        // Pinned tabs have no room for a button: a small speaker on the icon; mute from the context menu.
        .overlay(alignment: .bottomTrailing) {
            if tab.isPinned, audio != .none {
                Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7, weight: .bold))
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
        if !tab.isAwake { parts.append("asleep") }
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
    static func spokenEntry(_ tab: Tab, selected: Bool) -> String {
        let audio = AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted)
        let state = [selected ? "selected" : "", spokenState(tab, audio: audio)].filter { !$0.isEmpty }
        return ([tab.displayTitle] + state).joined(separator: ", ")
    }

    private var tooltip: String {
        var lines = [tab.displayTitle]
        if let url = tab.url { lines.append(url.absoluteString) }
        switch audio {
        case .playing: lines.append("Playing audio")
        case .muted: lines.append("Muted")
        case .none: break
        }
        if !tab.isAwake {
            lines.append("Asleep: no memory used. Click to wake.")
        } else if let hoverMemory {
            lines.append("Memory: \(ProcessMemory.format(hoverMemory.bytes))\(hoverMemory.shared ? " (shared with other tabs from this site)" : "")")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Memory readout

/// The toolbar's memory readout: this tab · all of Paddle, and the Activity popover. Its own view so a new
/// sample redraws only this label, not the address field and the rest of the toolbar.
private struct MemoryButton: View {
    let app: AppModel
    let model: BrowserModel
    @State private var showActivity = false

    var body: some View {
        Button {
            showActivity.toggle()
        } label: {
            HStack(spacing: 4) {
                Glyph(name: "surf-memory")
                Text(label)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Memory: this tab · all of Paddle. Click for details.")
        .accessibilityLabel("Memory")
        .accessibilityValue(spokenLabel)
        .accessibilityHint("Shows memory and activity details.")
        .popover(isPresented: $showActivity, arrowEdge: .bottom) {
            ActivityView(app: app, browser: model)
        }
    }

    private var label: String {
        let current = model.selectedTab?.memoryBytes.map(ProcessMemory.format) ?? "–"
        return "\(current) · \(ProcessMemory.format(app.totalWebMemory))"
    }

    private var spokenLabel: String {
        let total = "all of Paddle \(ProcessMemory.format(app.totalWebMemory))"
        guard let current = model.selectedTab?.memoryBytes.map(ProcessMemory.format) else { return total }
        return "this tab \(current), \(total)"
    }
}

// MARK: - Navigation bar

private struct NavigationBar: View {
    @Bindable var model: BrowserModel
    let app: AppModel
    @FocusState private var addressFocused: Bool
    @State private var addressSelection: TextSelection?
    /// Set while Paddle itself writes an inline completion, so that edit isn't treated as typing.
    @State private var applyingCompletion = false
    @State private var showDownloads = false

    private var tab: Tab? { model.selectedTab }

    var body: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", help: "Back", enabled: tab?.canGoBack == true) { tab?.webView?.goBack() }
            iconButton("chevron.right", help: "Forward", enabled: tab?.canGoForward == true) { tab?.webView?.goForward() }
            iconButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: tab?.isLoading == true ? "Stop" : "Reload", enabled: tab?.url != nil) {
                if tab?.isLoading == true { tab?.webView?.stopLoading() } else { tab?.webView?.reload() }
            }
            if model.isPrivate {
                Label("Private", systemImage: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .help("Private window: no history, no saved session, and cookies and site data are forgotten when the last private window closes.")
            }
            addressField
                .padding(.horizontal, 4)
            if model.extensionsAllowed {
                ExtensionToolbar(host: app.extensions, tab: tab)
            }
            if app.config.showTabMemory {
                MemoryButton(app: app, model: model)
            }
            if !app.downloads.items.isEmpty {
                downloadsButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) { progressBar }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: addressIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityLabel("Connection")
                .accessibilityValue(securityDescription ?? "")
                .accessibilityHidden(securityDescription == nil)
                .help(securityDescription ?? "")
            TextField("Search or enter address", text: $model.addressText, selection: $addressSelection)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit { model.submitAddress() }
                .onChange(of: model.addressText) { old, new in
                    if applyingCompletion {
                        applyingCompletion = false
                        return
                    }
                    guard let completed = model.addressEdited(from: old, to: new) else { return }
                    // Show the completed host with the added part selected, so typing on replaces it.
                    applyingCompletion = true
                    model.addressText = completed.text
                    addressSelection = TextSelection(range: completed.typedEnd..<completed.text.endIndex)
                }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onExitCommand {
                    // First Escape closes the suggestions, the next one gives up editing.
                    if model.suggestions.isVisible {
                        model.suggestions.dismiss()
                        return
                    }
                    // Really leave the field (also with no page showing); onChange(addressFocused) resyncs.
                    addressFocused = false
                    model.controller?.focusWebView()
                }
            if let url = tab?.url, HistoryStore.isRecordable(url), !addressFocused {
                let bookmarked = app.bookmarks.isBookmarked(url)
                Button {
                    app.bookmarks.toggle(url: url, title: tab?.title ?? "")
                } label: {
                    Glyph(name: "surf-star", active: bookmarked)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(bookmarked ? "Remove Bookmark" : "Bookmark This Page (⌘D)")
                .accessibilityLabel(bookmarked ? "Remove Bookmark" : "Bookmark This Page")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        // Private windows: a faint indigo field (with the "Private" label beside it, not color alone).
        .background(RoundedRectangle(cornerRadius: 8).fill(model.isPrivate ? Color.indigo.opacity(0.16) : Color.primary.opacity(0.07)))
        .overlay(alignment: .topLeading) {
            if model.suggestions.isVisible {
                SuggestionList(suggestions: model.suggestions) { model.open($0) }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .offset(y: 32)
            }
        }
        .onChange(of: addressFocused) { _, focused in
            model.isEditingAddress = focused
            if !focused {
                model.suggestions.dismiss()
                model.syncAddress()
            }
        }
        .onChange(of: model.focusAddressRequest) {
            addressFocused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard model.suggestions.isVisible else { return .ignored }
        model.suggestions.moveHighlight(by: delta)
        return .handled
    }

    /// What the address icon means, for VoiceOver and the tooltip; nil while it is only the search glass.
    private var securityDescription: String? {
        guard let url = tab?.url, !addressFocused else { return nil }
        switch url.scheme {
        case "https": return tab?.isSecure == true ? "Secure" : "Not fully secure: some of this page isn't encrypted"
        case "http": return "Not secure: this page isn't encrypted"
        default: return nil
        }
    }

    private var addressIcon: String {
        guard let url = tab?.url, !addressFocused else { return "magnifyingglass" }
        switch url.scheme {
        case "https": return tab?.isSecure == true ? "lock.fill" : "lock.open"
        case "http": return "exclamationmark.triangle"
        default: return "magnifyingglass"
        }
    }

    private var downloadsButton: some View {
        Button {
            showDownloads.toggle()
        } label: {
            Glyph(name: "surf-download", size: 16, active: app.downloads.activeCount > 0)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $showDownloads, arrowEdge: .bottom) {
            DownloadsView(store: app.downloads)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let tab, tab.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * max(0.05, tab.progress), height: 2)
                    .animation(.easeOut(duration: 0.2), value: tab.progress)
            }
            .frame(height: 2)
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Find

private struct FindBar: View {
    @Bindable var model: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find on page", text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($focused)
                .onSubmit { model.find() }
                .onExitCommand { model.hideFind() }
            if model.findNoMatch {
                Text("Not found").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { model.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)")
                .accessibilityLabel("Previous Match")
            Button { model.find() } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
                .accessibilityLabel("Next Match")
            Spacer()
            Button("Done") { model.hideFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
        .onChange(of: model.findText) { model.find() }
        // Each search that finds nothing is announced, not only the first.
        .onChange(of: model.findNoMatch) { _, noMatch in
            if noMatch { AccessibilityNotification.Announcement("Not found").post() }
        }
    }
}

// MARK: - Start page

private struct StartPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Paddle")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Type an address or search in the bar above.")
                .foregroundStyle(.secondary)
            Button("Customize Paddle…") {
                NSWorkspace.shared.open(Paths.support)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
