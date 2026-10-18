import AppKit
import PaddleCore
import SwiftUI

/// The content area of a multi view: each tab's page in its pane of the layout (`PaneLayout.frames`) under the pane's
/// own toolbar (`PaneBar`), dividers between them, a ring on the focused one, and where a dragged tab would land. When a pane would be smaller than `minimumPane`, only the focused one
/// shows (the layout is kept).
struct MultiPanes<Pane: View>: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    /// The selected tab: one of the view's.
    let focused: Tab
    let pane: (Tab, Bool) -> Pane
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = split.layout.frames(in: rect, gap: PaneMetrics.gap)
            let narrow = PaneMetrics.isNarrow(frames)
            let shown = model.panes(of: split)
            ZStack(alignment: .topLeading) {
                if narrow {
                    PaneFrame(model: model, tab: focused, focused: true, ring: false, content: pane(focused, true))
                        .id(focused.id)
                        .frame(width: rect.width, height: rect.height)
                } else {
                    // The gaps are real chrome between the pages: a thin line drawn over a page vanished on light pages
                    // in dark mode (measured all white).
                    ForEach(shown, id: \.id) { tab in
                        let frame = frames[tab.id.uuidString] ?? .zero
                        PaneFrame(model: model, tab: tab, focused: tab === focused, ring: true, content: pane(tab, tab === focused))
                            .id(tab.id)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            // Its address suggestions hang over the panes below.
                            .zIndex(model.editingPaneID == tab.id ? 1 : 0)
                    }
                    ForEach(split.layout.dividers(in: rect, gap: PaneMetrics.gap), id: \.path) { divider in
                        PaneDividerView(model: model, split: split, divider: divider)
                            .frame(width: divider.frame.width, height: divider.frame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
                PaneDropHighlight(model: model, frames: narrow ? [focused.id.uuidString: rect] : frames)
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .background(theme?.toolbar ?? Color(nsColor: .windowBackgroundColor))
            .coordinateSpace(.named("paneArea"))
            // Where clicks focus a pane and drags drop: the model lays the panes out in this (`paneFrames`).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.paneArea = $0 }
        }
    }
}

/// Multi view sizes shared by the content area and the model.
enum PaneMetrics {
    /// The gap of chrome between panes, which is also the divider's hit area.
    static let gap: CGFloat = 6
    /// The height of a pane's own toolbar (`PaneBar`).
    static let barHeight: CGFloat = 30
    static let minimumPane = CGSize(width: 260, height: 160)

    /// A pane would be under `minimumPane`, so only the focused one shows.
    static func isNarrow(_ frames: [String: CGRect]) -> Bool {
        frames.values.contains { $0.width < minimumPane.width || $0.height < minimumPane.height }
    }
}

/// One pane: its bar over the page, and the focused pane's ring.
private struct PaneFrame<Content: View>: View {
    let model: BrowserModel
    let tab: Tab
    let focused: Bool
    let ring: Bool
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(model: model, tab: tab, focused: focused)
                // Over the page, so its suggestions show on top of it.
                .zIndex(1)
            content
        }
        // Inside the pane's frame, by brightness alone: a dark ring with a light one inside it, so it shows on light
        // and dark pages alike (a single translucent line vanished on light pages in dark mode).
        .overlay {
            if focused && ring {
                ZStack {
                    Rectangle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2)
                    Rectangle().inset(by: 2).strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(focused ? "Focused pane, \(tab.displayTitle)" : "Pane, \(tab.displayTitle)")
    }
}

/// A pane's own toolbar: the site icon (drag it to move the pane), back, forward, reload, an address field that
/// navigates this pane, and × (Remove from View). Typing in the field focuses the pane; Return goes there through the
/// window's address handling (search, typed addresses, settings links). ⌘L lands in the focused pane's field.
private struct PaneBar: View {
    let model: BrowserModel
    let tab: Tab
    let focused: Bool
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(\.chromeTheme) private var theme

    private var shownAddress: String { tab.url.map(BrowserModel.displayString) ?? "" }

    var body: some View {
        HStack(spacing: 2) {
            FaviconView(url: tab.url, size: 12)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .help("Drag to move this pane")
                .modifier(TabDrag(tab: tab, enabled: true, strip: false))
            button("chevron.left", "Back", enabled: tab.canGoBack) { tab.webView?.goBack() }
            button("chevron.right", "Forward", enabled: tab.canGoForward) { tab.webView?.goForward() }
            button(tab.isLoading ? "xmark" : "arrow.clockwise", tab.isLoading ? "Stop" : "Reload", enabled: tab.url != nil && tab.settingsPane == nil) {
                if tab.isLoading { tab.webView?.stopLoading() } else { tab.reload() }
            }
            TextField("Address", text: $draft, prompt: Text("Search or enter address"))
                .textFieldStyle(.plain)
                .chromeFont(size: 12)
                .lineLimit(1)
                .focused($editing)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(editing ? 0.10 : 0.06)))
                .onSubmit {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if model.selectedID != tab.id { model.select(tab, focusPage: false) }
                    // The highlighted suggestion (the top row is what was typed), as in the window's field.
                    if model.suggestions.isVisible, let row = model.suggestions.highlightedRow {
                        model.open(row)
                    } else {
                        model.navigate(text)
                    }
                    model.suggestions.dismiss()
                    editing = false
                }
                .onChange(of: editing) { _, now in
                    if now {
                        // The keyboard stays in this field: selecting a tab otherwise hands it to the page.
                        if model.selectedID != tab.id { model.select(tab, focusPage: false) }
                        model.editingPaneID = tab.id
                        DispatchQueue.main.async { if editing { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
                    } else {
                        if model.editingPaneID == tab.id {
                            model.editingPaneID = nil
                            model.suggestions.dismiss()
                        }
                        draft = shownAddress
                    }
                }
                // Typing shows the window's suggestions under this field: open tabs, history, search phrases.
                .onChange(of: draft) { _, text in
                    if editing, text != shownAddress { model.suggestions.update(for: text, in: model) }
                }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onChange(of: shownAddress) { _, new in if !editing { draft = new } }
                .onChange(of: model.paneAddressFocusRequest) { if focused { editing = true } }
                .onAppear { draft = shownAddress }
                // The first Escape closes the suggestions, the next gives up the edit.
                .onExitCommand {
                    if model.suggestions.isVisible, model.editingPaneID == tab.id {
                        model.suggestions.dismiss()
                        return
                    }
                    draft = shownAddress
                    editing = false
                }
                .overlay(alignment: .topLeading) {
                    if editing, model.editingPaneID == tab.id, model.suggestions.isVisible {
                        SuggestionList(suggestions: model.suggestions) { row in
                            model.open(row)
                            model.suggestions.dismiss()
                            editing = false
                        }
                        .systemText()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 340, alignment: .top)
                        .offset(y: 26)
                    }
                }
                .accessibilityLabel("Address of \(tab.displayTitle)")
                .padding(.horizontal, 4)
            Button {
                model.removeFromView(tab)
            } label: {
                Image(systemName: "xmark").chromeFont(size: 9, weight: .semibold)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from View: the tab stays, in the view's menu in the strip")
            .accessibilityLabel("Remove \(tab.displayTitle) from the view")
        }
        .padding(.horizontal, 4)
        .frame(height: PaneMetrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(theme?.toolbar ?? Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            TabProgressBar(tab: tab, accent: theme?.accent ?? Color.accentColor, reducesMotion: AppModel.shared.reducesMotion)
        }
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard model.suggestions.isVisible, model.editingPaneID == tab.id else { return .ignored }
        model.suggestions.moveHighlight(by: delta)
        return .handled
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .chromeFont(size: 11, weight: .medium)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel("\(help), \(tab.displayTitle)")
    }
}

/// The gap between two panes: a grip in the middle, a resize cursor, drag to move, double-click to even out.
private struct PaneDividerView: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    let divider: PaneDivider

    private var horizontal: Bool { divider.axis == .horizontal }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(Capsule().fill(Color.secondary.opacity(0.7)).frame(width: horizontal ? 2 : 28, height: horizontal ? 28 : 2))
            .contentShape(Rectangle())
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("paneArea")).onChanged { value in
                    model.setSplitRatio(PaneLayout.ratio(dragging: divider, to: value.location), at: divider.path, for: split)
                }
            )
            .onTapGesture(count: 2) { model.setSplitRatio(0.5, at: divider.path, for: split) }
            .accessibilityElement()
            .accessibilityLabel(horizontal ? "Divider between side-by-side panes" : "Divider between stacked panes")
            .accessibilityAdjustableAction { direction in
                guard let ratio = ratio else { return }
                model.setSplitRatio(ratio + (direction == .increment ? 0.05 : -0.05), at: divider.path, for: split)
            }
            .accessibilityValue(ratio.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }

    /// The divider's split's current ratio.
    private var ratio: Double? {
        var node = split.layout.root
        for step in divider.path {
            guard case .split(_, _, let a, let b) = node else { return nil }
            node = step == 0 ? a : b
        }
        guard case .split(_, let ratio, _, _) = node else { return nil }
        return ratio
    }
}

/// Where a tab dragged over the content area would land (`BrowserModel.paneDropHint`): the half of the pane it takes,
/// or the whole pane for a swap or replace. `frames` are the panes in the content area's own coordinates.
struct PaneDropHighlight: View {
    let model: BrowserModel
    let frames: [String: CGRect]
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        if let hint = model.paneDropHint, let frame = frames[hint.target.uuidString] {
            let rect = Self.rect(of: frame, edge: hint.edge)
            RoundedRectangle(cornerRadius: 6)
                .fill((theme?.accent ?? Color.accentColor).opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme?.accent ?? Color.accentColor, lineWidth: 2))
                .frame(width: rect.width - 8, height: rect.height - 8)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    static func rect(of frame: CGRect, edge: PaneEdge?) -> CGRect {
        switch edge {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case nil: frame
        }
    }
}

/// A single page's content area as a drop target: its frame for the drag controller and the drop highlight.
struct SinglePaneTarget: ViewModifier {
    let model: BrowserModel

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    if let selected = model.selectedTab {
                        PaneDropHighlight(model: model, frames: [selected.id.uuidString: CGRect(origin: .zero, size: geometry.size)])
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.paneArea = $0 }
        }
    }
}
