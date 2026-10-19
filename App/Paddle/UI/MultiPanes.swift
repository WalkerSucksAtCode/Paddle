import AppKit
import PaddleCore
import SwiftUI

/// The content area of a Mosaic: each tab's page in its pane of the layout (`PaneLayout.frames`) under the pane's
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
            // While a tab is dragged over the panes, the layout its drop would make: the panes move aside for it.
            let preview = model.paneDragPreview(for: split)
            let layout = preview ?? split.layout
            var frames = layout.frames(in: rect, gap: PaneMetrics.gap)
            let narrow = PaneMetrics.isNarrow(split.layout.frames(in: rect, gap: PaneMetrics.gap))
            let shown = model.panes(of: split)
            let dragged = preview == nil ? nil : model.paneDragTabID
            // Zoom Pane: the focused pane over the whole area, the others kept (hidden) in their places.
            let zoomed = preview == nil && model.zoomedPaneID == focused.id ? focused.id : nil
            let _ = zoomed.map { frames[$0.uuidString] = rect }
            ZStack(alignment: .topLeading) {
                if narrow {
                    PaneFrame(model: model, tab: focused, focused: true, ring: false, size: rect.size, content: pane(focused, true))
                        .id(focused.id)
                        .frame(width: rect.width, height: rect.height)
                } else {
                    // The gaps are real chrome between the pages: a thin line drawn over a page vanished on light pages
                    // in dark mode (measured all white).
                    ForEach(shown, id: \.id) { tab in
                        let frame = frames[tab.id.uuidString] ?? .zero
                        PaneFrame(model: model, tab: tab, focused: tab === focused, ring: true, size: frame.size, content: pane(tab, tab === focused))
                            .id(tab.id)
                            // The pane on the move fades back under its landing highlight; a zoomed pane hides the rest.
                            .opacity(tab.id == dragged ? 0.35 : zoomed == nil || zoomed == tab.id ? 1 : 0)
                            .allowsHitTesting(zoomed == nil || zoomed == tab.id)
                            // The card's edges spring to the new frame; the page inside is already at its new size, so
                            // it is uncovered or cut off rather than stretched.
                            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                            // Not while its address suggestions show: they may hang out of a narrow pane.
                            .modifier(PaneClip(active: model.editingPaneID != tab.id))
                            .position(x: frame.midX, y: frame.midY)
                            // Its address suggestions hang over the panes below; a zoomed pane is over the others.
                            .zIndex(model.editingPaneID == tab.id || zoomed == tab.id ? 1 : 0)
                    }
                    ForEach(layout.dividers(in: rect, gap: PaneMetrics.gap), id: \.path) { divider in
                        PaneDividerView(model: model, split: split, divider: divider)
                            .frame(width: divider.frame.width, height: divider.frame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                            .allowsHitTesting(preview == nil && zoomed == nil)
                            .opacity(zoomed == nil ? 1 : 0)
                    }
                }
                if let preview, !narrow, let dragged, let frame = preview.frames(in: rect, gap: PaneMetrics.gap)[dragged.uuidString] {
                    PaneLandingHighlight(frame: frame)
                } else {
                    PaneDropHighlight(model: model, frames: narrow ? [focused.id.uuidString: rect] : frames)
                }
            }
            // Snappy but smooth: panes spring to a new layout (a drag's preview, a drop, the Mosaic bar's layouts,
            // Rotate, Swap, a pane added or taken out); none while dragging a divider, which follows the pointer.
            .animation(
                model.isDraggingDivider || AppModel.shared.reducesMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86),
                value: AnimatedLayout(layout: layout, dragging: dragged, zoomed: zoomed)
            )
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .background(theme?.toolbar ?? Color(nsColor: .windowBackgroundColor))
            .coordinateSpace(.named("paneArea"))
            // Where clicks focus a pane and drags drop: the model lays the panes out in this (`paneFrames`).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.paneArea = $0 }
        }
    }
}

/// Clips a pane to its rounded card, or (`active` false) to a shape far bigger than it, which leaves it whole. One
/// shape either way: switching between two views would rebuild the page and drop the address field's focus.
private struct PaneClip: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous).inset(by: active ? 0 : -2000))
    }
}

/// What the pane animation follows: the shape (not the name) and the pane on the move.
private struct AnimatedLayout: Equatable {
    var root: PaneNode
    var dragging: UUID?
    var zoomed: UUID?

    init(layout: PaneLayout, dragging: UUID?, zoomed: UUID?) {
        root = layout.root
        self.dragging = dragging
        self.zoomed = zoomed
    }
}

/// Where the dragged tab will land in the preview layout: an accent card in its pane's place.
private struct PaneLandingHighlight: View {
    let frame: CGRect
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let accent = theme?.accent ?? Color.accentColor
        RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
            .fill(accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous).strokeBorder(accent, lineWidth: 2))
            .frame(width: max(0, frame.width - 8), height: max(0, frame.height - 8))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Mosaic sizes shared by the content area and the model.
enum PaneMetrics {
    /// The gap of chrome between panes, which is also the divider's hit area (`mosaicGap`).
    static var gap: CGFloat { CGFloat(AppModel.shared.config.mosaicGap) }
    /// The height of a pane's own toolbar (`PaneBar`).
    static let barHeight: CGFloat = 30
    /// A pane's corners: slightly rounded, like the Mac's windows and controls.
    static let cornerRadius: CGFloat = 8
    /// `mosaicMinimumPaneWidth` × `mosaicMinimumPaneHeight`.
    static var minimumPane: CGSize {
        CGSize(width: AppModel.shared.config.mosaicMinimumPaneWidth, height: AppModel.shared.config.mosaicMinimumPaneHeight)
    }
    /// Pane toolbars only on hover (`mosaicPaneBars`): they sit over the top of the page.
    static var barsOnHover: Bool { AppModel.shared.config.mosaicPaneBars == .hover }

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
    /// The pane's size in the layout it is going to: the page takes it at once (no animation), so a layout change
    /// lays each page out once instead of stretching it frame by frame.
    let size: CGSize
    let content: Content
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
        let overlaid = PaneMetrics.barsOnHover
        // On hover the bar sits over the page's top edge and shows while the pointer is in the pane or its address is
        // being edited (⌘L too); it stays in place when hidden, so an edit in it isn't lost.
        let barShown = !overlaid || hovering || model.editingPaneID == tab.id
        ZStack(alignment: .top) {
        VStack(spacing: 0) {
            if !overlaid {
                PaneBar(model: model, tab: tab, focused: focused)
                    // Over the page, so its suggestions show on top of it (they aren't inside the page's clip).
                    .zIndex(1)
            }
            // The page is a card with slightly rounded corners under its bar, like the Mac's windows.
            content
                .frame(width: size.width, height: max(0, size.height - (overlaid ? 0 : PaneMetrics.barHeight)))
                .transaction { $0.animation = nil }
                .clipShape(shape)
                // Inside the card, by brightness alone: a dark ring with a light one inside it, so it shows on light
                // and dark pages alike (a single translucent line vanished on light pages in dark mode).
                .overlay {
                    if focused && ring {
                        ZStack {
                            shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 2)
                            RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius - 2, style: .continuous).inset(by: 2)
                                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                    }
                }
        }
            if overlaid {
                PaneBar(model: model, tab: tab, focused: focused)
                    .background(.regularMaterial)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: PaneMetrics.cornerRadius, topTrailingRadius: PaneMetrics.cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                    .opacity(barShown ? 1 : 0)
                    .allowsHitTesting(barShown)
                    .animation(AppModel.shared.reducesMotion ? nil : .easeOut(duration: 0.14), value: barShown)
            }
        }
        .onHover { hovering = $0 }
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
            .help("Remove from Mosaic: the tab stays, in the Mosaic's menu in the strip")
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
                    if !model.isDraggingDivider { model.isDraggingDivider = true }
                    model.setSplitRatio(PaneLayout.ratio(dragging: divider, to: value.location), at: divider.path, for: split)
                }
                .onEnded { _ in model.isDraggingDivider = false }
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
