import AppKit
import PaddleCore
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let app: AppModel

    /// The strip under the toolbar for config.json: a file that doesn't parse, else the values that fell back to
    /// their defaults (at most three paths named).
    private var configNotice: String? {
        if let error = app.configError { return error }
        let warnings = app.configWarnings
        guard !warnings.isEmpty else { return nil }
        let paths = warnings.prefix(3).map { $0.path.joined(separator: ".") }.joined(separator: ", ")
        let more = warnings.count > 3 ? ", …" : ""
        return "config.json: \(app.configWarningPhrase) (\(paths)\(more)). Settings > Advanced lists them."
    }

    /// The strip under the config notice for themes: the first problem, and how many more.
    private var themeNotice: String? {
        let warnings = app.themeWarnings
        guard let first = warnings.first else { return nil }
        let more = warnings.count > 1 ? " (\(warnings.count - 1) more problems)" : ""
        return "Theme: \(first)\(more). Settings > Appearance lists them."
    }

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SidebarMetrics.collapsedKey) private var sidebarCollapsed = false
    @State private var fullScreen = false
    private var vertical: Bool { app.config.tabLayout == .vertical }

    var body: some View {
        let theme = ResolvedChromeTheme(app: app, dark: colorScheme == .dark, spaceTint: model.activeSpace.tint)
        Group {
            if vertical {
                HStack(spacing: 0) {
                    VerticalTabsSidebar(model: model, fullScreen: fullScreen)
                        .chromeSurface(.tabStrip)
                    Divider()
                    page
                }
            } else {
                VStack(spacing: 0) {
                    TabStrip(model: model)
                        .frame(height: 38)
                        .chromeSurface(.tabStrip)
                    page
                }
            }
        }
        .background {
            if app.reducesTransparency { Color(nsColor: .windowBackgroundColor) } else { Rectangle().fill(.bar) }
        }
        .environment(\.chromeScale, app.chromeScale)
        .environment(\.chromeHighContrastTabs, app.config.highContrastTabs)
        .environment(\.chromeReducesMotion, app.reducesMotion)
        .environment(\.chromeReducesTransparency, app.reducesTransparency)
        .environment(\.chromeTheme, theme)
        .tint(theme?.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.windowTitle, initial: true) { _, title in model.controller?.window?.title = title }
        // The switch rebuilds the chrome and moves the content under a new parent. A split's outgoing panes can take
        // the pages back as they leave, so both sides take them again once the switch has settled (as `settleSplit`
        // does). Then the keyboard goes back to the page, only in the window being worked in: the others may hold a
        // half-typed address.
        .onChange(of: vertical) { _, _ in
            DispatchQueue.main.async {
                if model.visibleTabs.count == 2 { for tab in model.visibleTabs { tab.generation += 1 } }
                guard model.controller?.window?.isKeyWindow == true else { return }
                model.controller?.focusWebView()
            }
        }
        .onAppear { fullScreen = model.controller?.window?.styleMask.contains(.fullScreen) == true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === model.controller?.window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === model.controller?.window { fullScreen = false }
        }
    }

    /// Everything beside or under the tabs: toolbar, bookmarks bar, notices, find bar and the page.
    @ViewBuilder
    private var page: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
            NavigationBar(model: model, app: app)
                // A collapsed sidebar is narrower than the traffic lights, which overhang into this row.
                .padding(.leading, vertical && sidebarCollapsed && !fullScreen ? SidebarMetrics.trafficLightInset - SidebarMetrics.collapsedWidth : 0)
                // The suggestion dropdown hangs below the bar, over the page and the bookmarks bar.
                .zIndex(1)
            // An empty bar takes a row for nothing; ⌘D fills it and it appears.
            if app.showBookmarksBar, !app.bookmarks.tree.bar.isEmpty {
                BookmarksBar(app: app)
            }
            if let notice = configNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .chromeFont(size: 11)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if let notice = themeNotice {
                Label(notice, systemImage: "paintpalette")
                    .chromeFont(size: 11)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if let host = model.extensionHost, let banner = host.bannerText {
                HStack(alignment: .top, spacing: 8) {
                    Label(banner, systemImage: "puzzlepiece.extension")
                        .chromeFont(size: 11)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        host.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .chromeFont(size: 9, weight: .bold)
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
            // A Chrome Web Store or addons.mozilla.org detail page: offer to install it. Paddle's own bar; nothing runs in the page.
            if let tab = model.selectedTab, let url = tab.url, let link = StoreLink.isStoreDetailPage(url) {
                StoreInstallBar(link: link, pageTitle: tab.title, model: model)
            }
            if model.findVisible, model.selectedTab?.settingsPane == nil {
                FindBar(model: model)
            }
            }
            // The suggestion dropdown hangs below this block, over the page.
            .chromeSurface(.toolbar)
            .zIndex(1)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            splitOrSingle
        }
        // The page that moved between hosts takes its container back once the switch has settled (as Responsive
        // Design Mode does), so neither side is left blank when a split starts or ends. On the Group, which outlives
        // the branch change.
        .onChange(of: model.visibleTabs.map(\.id)) { old, new in settleSplit(old: old, new: new) }
        // Over the content only (both sides of a split), not the tab strip or toolbar.
        .overlay { LinkPreviewOverlay(model: model) }
    }

    @ViewBuilder
    private var splitOrSingle: some View {
        if let selected = model.selectedTab, let split = model.split(of: selected), let partner = model.partner(of: selected) {
            let selectedIsLeft = split.leftID == selected.id
            SplitPanes(model: model, split: split, left: selectedIsLeft ? selected : partner, right: selectedIsLeft ? partner : selected,
                       focused: selected) { tab, focused in
                pane(tab, focused: focused)
            }
        } else {
            pane(model.selectedTab, focused: true)
        }
    }

    private func settleSplit(old: [UUID], new: [UUID]) {
        guard old.count == 2 || new.count == 2 else { return }
        DispatchQueue.main.async {
            for tab in model.visibleTabs { tab.generation += 1 }
        }
    }

    /// What one tab shows in the content area (the whole area, or one side of a split). Only the focused side gets
    /// Responsive Design Mode and takes the keyboard.
    @ViewBuilder
    private func pane(_ tab: Tab?, focused: Bool) -> some View {
        if let tab, tab.settingsPane != nil {
            SettingsTabView(tab: tab, browser: model)
                .id(tab.id)
        } else if let tab, let blocked = tab.httpsOnlyBlocked {
            HTTPSOnlyNotice(tab: tab, url: blocked)
                .id(blocked)
        } else if let tab, let article = tab.readerArticle {
            ReaderView(tab: tab, article: article)
                .id(tab.id)
        } else if let tab, tab.url != nil {
            if tab.responsive != nil, focused {
                ResponsivePage(tab: tab)
            } else {
                WebContainer(tab: tab, generation: tab.generation, takesKeyboard: focused)
                    // Not under a link preview: the page there still gets mouse moves through the card (tracking
                    // areas ignore what covers them), so its bubble would name a link the pointer isn't on. The
                    // card shows the preview's own.
                    .overlay(alignment: .bottomLeading) { if model.preview == nil { LinkStatusBubble(tab: tab) } }
                    .overlay(alignment: .bottom) {
                        if tab.isPDF {
                            PDFToolbarHUD(tab: tab, model: model)
                                .padding(.bottom, 16)
                        }
                    }
            }
        } else {
            NewTabPage(model: model, app: app)
        }
    }
}

// MARK: - Link status

/// The address of the link under the pointer. A separate view so hovering redraws only this.
struct LinkStatusBubble: View {
    let tab: Tab

    var body: some View {
        if let link = tab.hoveredLink {
            GeometryReader { geometry in
                Text(link.absoluteString)
                    .chromeFont(size: 11)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    // Background before the width cap, so the bubble fits a short address instead of spanning 60 %.
                    .chromeMaterial(in: UnevenRoundedRectangle(topTrailingRadius: 6))
                    .overlay(UnevenRoundedRectangle(topTrailingRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(maxWidth: geometry.size.width * 0.6, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Memory readout

/// The toolbar's memory readout: all of Paddle (this tab's share in the tooltip), and the Activity popover. Its own view so a new
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
                // The widest label, hidden, holds the width: the readout neither truncates nor shifts as it changes.
                ZStack(alignment: .trailing) {
                    Text("8888 MB").hidden().accessibilityHidden(true)
                    Text(label)
                }
            }
            .chromeFont(size: 11, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .accessibilityLabel("Memory")
        .accessibilityValue(spokenLabel)
        .accessibilityHint("Shows memory and activity details.")
        .popover(isPresented: $showActivity, arrowEdge: .bottom) {
            ActivityView(app: app, browser: model).systemText()
        }
    }

    private var label: String { ProcessMemory.format(app.totalWebMemory) }

    private var tooltip: String {
        let total = "Paddle is using \(ProcessMemory.format(app.totalWebMemory))"
        guard let current = model.selectedTab?.memoryBytes.map(ProcessMemory.format) else { return total + ". Click for details." }
        return total + ", this tab \(current). Click for details."
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
    @Environment(\.chromeTheme) private var theme
    @State private var addressSelection: TextSelection?
    /// Set while Paddle itself writes an inline completion, so that edit isn't treated as typing.
    @State private var applyingCompletion = false
    @State private var showSecurityPopover = false

    private var tab: Tab? { model.selectedTab }

    var body: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", help: "Back", enabled: tab?.canGoBack == true) { tab?.webView?.goBack() }
            iconButton("chevron.right", help: "Forward", enabled: tab?.canGoForward == true) { tab?.webView?.goForward() }
            iconButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: tab?.isLoading == true ? "Stop" : "Reload", enabled: tab?.url != nil && tab?.settingsPane == nil) {
                if tab?.isLoading == true { tab?.webView?.stopLoading() } else { tab?.reload() }
            }
            if model.isPrivate {
                Label("Private", systemImage: "eye.slash")
                    .chromeFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .help("Private window: no history, no saved session, and cookies and site data are forgotten when the last private window closes.")
            }
            if !model.isPrivate, app.profiles.hasSeveral {
                let profile = app.profiles.profile(id: model.profileID)
                Label(profile.name, systemImage: profile.symbol.sfSymbol)
                    .chromeFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .help("Profile: \(profile.name)")
            }
            BridgeIndicator()
            addressField
                .padding(.horizontal, 4)
                .frame(minWidth: 140)
            HStack(spacing: 2) {
                MediaControlsButton(app: app, model: model)
                if model.extensionsAllowed, let host = model.extensionHost {
                    ExtensionToolbar(host: host, model: model, tab: tab, isPrivate: model.isPrivate, placements: app.config.extensionToolbar)
                }
                if !app.downloads.items.isEmpty {
                    downloadsButton
                }
            }
            .fixedSize()
            if app.config.showTabMemory {
                MemoryButton(app: app, model: model)
                    .fixedSize()
                    .padding(.leading, 4)
            }
            ToolbarMenuButton(model: model)
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) { progressBar }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            securityIcon
            TextField("Search or enter address", text: $model.addressText, selection: $addressSelection)
                .textFieldStyle(.plain)
                .chromeFont(size: 13)
                // Clear text, not removed, behind the site name: a click still lands in the field and edits the whole
                // address. Not opacity 0, which also drops the field from accessibility.
                .foregroundStyle(siteOnly == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                .overlay(alignment: .leading) {
                    if let siteOnly {
                        Text(siteOnly)
                            .chromeFont(size: 13)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
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
            if let tab, (tab.isReaderAvailable || tab.readerArticle != nil), !addressFocused {
                Button {
                    tab.toggleReaderMode()
                } label: {
                    Image(systemName: tab.readerArticle != nil ? "doc.plaintext.fill" : "doc.plaintext")
                        .chromeFont(size: 12)
                        .foregroundStyle(tab.readerArticle != nil ? (theme?.accent ?? Color.accentColor) : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tab.readerArticle != nil ? "Hide Reader (⇧⌘R)" : "Show Reader (⇧⌘R)")
                .accessibilityLabel("Reader Mode")
            }
            if let tab, tab.url != nil, !tab.isPDF, !addressFocused {
                Button {
                    tab.showTranslatePopover.toggle()
                } label: {
                    Image(systemName: "translate")
                        .chromeFont(size: 12)
                        .foregroundStyle(tab.url?.host?.contains("translate.goog") == true ? (theme?.accent ?? Color.accentColor) : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Translate Page…")
                .accessibilityLabel("Translate Page")
                .popover(isPresented: Bindable(tab).showTranslatePopover, arrowEdge: .bottom) {
                    TranslatePopover(tab: tab, model: model)
                }
            }
            if let tab, tab.isPDF, !addressFocused {
                Button {
                    model.controller?.paddleOpenInPreview(nil)
                } label: {
                    Text("PDF")
                        .chromeFont(size: 10, weight: .bold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(theme?.accent?.opacity(0.18) ?? Color.accentColor.opacity(0.18)))
                        .foregroundStyle(theme?.accent ?? Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Open in Preview.app")
                .accessibilityLabel("PDF Document")
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.addressFieldFrame = $0 }
        .overlay(alignment: .topLeading) {
            if model.suggestions.isVisible {
                SuggestionList(suggestions: model.suggestions) { model.open($0) }
                    .systemText()
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.suggestionsFrame = $0 }
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

    /// The site shown in place of the address while the field isn't being edited (`showFullAddress` off): a web
    /// page's host without "www.". Nil shows the whole address: other schemes, or the setting on.
    private var siteOnly: String? {
        guard !addressFocused, !app.config.showFullAddress, let url = tab?.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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

    @ViewBuilder
    private var securityIcon: some View {
        let isWeb = tab?.url.flatMap { $0.scheme?.lowercased() }.map { $0 == "http" || $0 == "https" } ?? false
        if isWeb && !addressFocused {
            Button {
                showSecurityPopover.toggle()
            } label: {
                Image(systemName: addressIcon)
                    .chromeFont(size: 11)
                    .foregroundStyle(securityIconColor)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection security and site settings")
            .accessibilityValue(securityDescription ?? "")
            .help(securityDescription ?? "Connection security and permissions")
            .popover(isPresented: $showSecurityPopover, arrowEdge: .bottom) {
                if let tab {
                    SiteSecurityView(tab: tab, model: model, app: app)
                        .systemText()
                }
            }
        } else {
            Image(systemName: addressIcon)
                .chromeFont(size: 11)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityLabel("Connection")
                .accessibilityValue(securityDescription ?? "")
                .accessibilityHidden(securityDescription == nil)
                .help(securityDescription ?? "")
        }
    }

    private var securityIconColor: Color {
        guard let url = tab?.url else { return .secondary }
        switch url.scheme?.lowercased() {
        case "https": return tab?.isSecure == true ? .secondary : .orange
        case "http": return .red
        default: return .secondary
        }
    }

    private var downloadsButton: some View {
        Button {
            model.downloadsVisible.toggle()
        } label: {
            Glyph(name: "surf-download", size: 16, active: app.downloads.activeCount > 0)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $model.downloadsVisible, arrowEdge: .bottom) {
            DownloadsView(store: app.downloads).systemText()
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let tab, tab.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(theme?.accent ?? Color.accentColor)
                    .frame(width: geometry.size.width * max(0.05, tab.progress), height: 2)
                    .animation(app.reducesMotion ? nil : .easeOut(duration: 0.2), value: tab.progress)
            }
            .frame(height: 2)
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .chromeFont(size: 13, weight: .medium)
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
    @Environment(\.chromeScale) private var scale
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
                Text("Not found").chromeFont(size: 11).foregroundStyle(.secondary)
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
        .chromeFont(size: 13)
        .padding(.horizontal, 12)
        .frame(height: 32 * scale)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
        .onChange(of: model.findText) { model.find() }
        // Each search that finds nothing is announced, not only the first.
        .onChange(of: model.findNoMatch) { _, noMatch in
            if noMatch { AccessibilityNotification.Announcement("Not found").post() }
        }
    }
}
