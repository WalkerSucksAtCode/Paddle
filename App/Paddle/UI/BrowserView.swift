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
            if model.findVisible {
                FindBar(model: model)
            }
            Divider()
            content
        }
        .background(.bar)
        .ignoresSafeArea(.container, edges: .top)
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
                            }
                        }
                        .padding(.vertical, 5)
                        // Space after the last tab drags the window too.
                        .frame(minWidth: max(0, geometry.size.width - leadingInset - 36), alignment: .leading)
                        .background(WindowDragArea())
                    }
                    .scrollBounceBehavior(.basedOnSize)
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

    private var isSelected: Bool { model.selectedID == tab.id }

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
        .onHover { hovering = $0 }
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
                Image(systemName: "moon.zzz")
            } else {
                FaviconView(url: tab.url, fallback: tab.isPinned ? "pin.fill" : "globe")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14)
    }

    private var tooltip: String {
        var lines = [tab.displayTitle]
        if let url = tab.url { lines.append(url.absoluteString) }
        if !tab.isAwake {
            lines.append("Asleep: no memory used. Click to wake.")
        } else if let bytes = tab.memoryBytes {
            lines.append("Memory: \(ProcessMemory.format(bytes))\(tab.sharesProcess ? " (shared with other tabs from this site)" : "")")
        }
        return lines.joined(separator: "\n")
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
    @State private var showActivity = false
    @State private var showDownloads = false

    private var tab: Tab? { model.selectedTab }

    var body: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", help: "Back", enabled: tab?.canGoBack == true) { tab?.webView?.goBack() }
            iconButton("chevron.right", help: "Forward", enabled: tab?.canGoForward == true) { tab?.webView?.goForward() }
            iconButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: tab?.isLoading == true ? "Stop" : "Reload", enabled: tab?.url != nil) {
                if tab?.isLoading == true { tab?.webView?.stopLoading() } else { tab?.webView?.reload() }
            }
            addressField
                .padding(.horizontal, 4)
            if app.config.showTabMemory {
                memoryButton
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
                    Image(systemName: bookmarked ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(bookmarked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(bookmarked ? "Remove Bookmark" : "Bookmark This Page (⌘D)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
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

    private var addressIcon: String {
        guard let url = tab?.url, !addressFocused else { return "magnifyingglass" }
        switch url.scheme {
        case "https": return tab?.isSecure == true ? "lock.fill" : "lock.open"
        case "http": return "exclamationmark.triangle"
        default: return "magnifyingglass"
        }
    }

    private var memoryButton: some View {
        Button {
            showActivity.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                Text(memoryLabel)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Memory: this tab · all tabs. Click for details.")
        .popover(isPresented: $showActivity, arrowEdge: .bottom) {
            ActivityView(app: app)
        }
    }

    private var memoryLabel: String {
        let current = tab?.memoryBytes.map(ProcessMemory.format) ?? "–"
        return "\(current) · \(ProcessMemory.format(app.totalWebMemory))"
    }

    private var downloadsButton: some View {
        Button {
            showDownloads.toggle()
        } label: {
            Image(systemName: app.downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Downloads")
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
    }
}

// MARK: - Find

private struct FindBar: View {
    @Bindable var model: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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
            Button { model.find() } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
            Spacer()
            Button("Done") { model.hideFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
        .onChange(of: model.findText) { model.find() }
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
