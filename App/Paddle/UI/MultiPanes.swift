import AppKit
import PaddleCore
import SwiftUI

/// The content area of a multi view: each tab's page in its pane of the layout (`PaneLayout.frames`), a title bar on
/// each (drag it to move the pane, × takes the tab out of the view), dividers between them, a ring on the focused
/// one, and where a dragged tab would land. When a pane would be smaller than `minimumPane`, only the focused one
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
    static let minimumPane = CGSize(width: 260, height: 160)

    /// A pane would be under `minimumPane`, so only the focused one shows.
    static func isNarrow(_ frames: [String: CGRect]) -> Bool {
        frames.values.contains { $0.width < minimumPane.width || $0.height < minimumPane.height }
    }
}

/// One pane: a title bar over the page, and the focused pane's ring.
private struct PaneFrame<Content: View>: View {
    let model: BrowserModel
    let tab: Tab
    let focused: Bool
    let ring: Bool
    let content: Content
    @Environment(\.chromeTheme) private var theme

    static var titleHeight: CGFloat { 24 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                FaviconView(url: tab.url, size: 12)
                Text(tab.displayTitle)
                    .chromeFont(size: 11, weight: focused ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(focused ? .primary : .secondary)
                Spacer(minLength: 4)
                Button {
                    model.removeFromView(tab)
                } label: {
                    Image(systemName: "xmark").chromeFont(size: 9, weight: .semibold)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove from View: the tab stays in the strip")
                .accessibilityLabel("Remove \(tab.displayTitle) from the view")
            }
            .padding(.horizontal, 8)
            .frame(height: Self.titleHeight)
            .frame(maxWidth: .infinity)
            .background(theme?.toolbar ?? Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            // Drag the title bar to move the pane onto another, or out to the strip.
            .modifier(TabDrag(tab: tab, enabled: true, strip: false))
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

/// The view's bracket in the tab strip (underline) or sidebar (leading edge): the first tab's piece opens toward the
/// rest, the last's closes it, and the ones between are straight, so the run reads as one shape.
nonisolated struct SplitBracket: Shape {
    let piece: SplitSide
    let vertical: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        let tick: CGFloat = 4
        if vertical {
            let x = r.minX + 1.5
            switch piece {
            case .first:
                p.move(to: CGPoint(x: x + tick, y: r.minY + 3)); p.addLine(to: CGPoint(x: x, y: r.minY + 3)); p.addLine(to: CGPoint(x: x, y: r.maxY + 1))
            case .middle:
                p.move(to: CGPoint(x: x, y: r.minY - 1)); p.addLine(to: CGPoint(x: x, y: r.maxY + 1))
            case .last:
                p.move(to: CGPoint(x: x, y: r.minY - 1)); p.addLine(to: CGPoint(x: x, y: r.maxY - 3)); p.addLine(to: CGPoint(x: x + tick, y: r.maxY - 3))
            }
        } else {
            let y = r.maxY + 3
            switch piece {
            case .first:
                p.move(to: CGPoint(x: r.minX + 3, y: y - tick)); p.addLine(to: CGPoint(x: r.minX + 3, y: y)); p.addLine(to: CGPoint(x: r.maxX + 1, y: y))
            case .middle:
                p.move(to: CGPoint(x: r.minX - 1, y: y)); p.addLine(to: CGPoint(x: r.maxX + 1, y: y))
            case .last:
                p.move(to: CGPoint(x: r.minX - 1, y: y)); p.addLine(to: CGPoint(x: r.maxX - 3, y: y)); p.addLine(to: CGPoint(x: r.maxX - 3, y: y - tick))
            }
        }
        return p
    }
}

extension View {
    /// The view's bracket on a strip tab or sidebar row that is in a multi view.
    @ViewBuilder
    func splitBracket(_ piece: SplitSide?, vertical: Bool, ink: Color) -> some View {
        if let piece {
            overlay {
                SplitBracket(piece: piece, vertical: vertical)
                    .stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}

/// Where a tab sits in its multi view's run in the strip.
enum SplitSide { case first, middle, last }

extension BrowserModel {
    /// Where `tab` is in its multi view's run of strip tabs, nil when it is in none.
    func splitSide(of tab: Tab) -> SplitSide? {
        guard let split = split(of: tab) else { return nil }
        let members = Set(split.tabIDs)
        let run = tabs.filter { members.contains($0.id) }
        if run.first === tab { return .first }
        if run.last === tab { return .last }
        return .middle
    }

    /// What VoiceOver adds for a tab in a multi view.
    func spokenSplit(of tab: Tab, after state: String) -> String {
        let others = others(of: tab)
        guard !others.isEmpty else { return state }
        let phrase = "in a view with " + others.map(\.displayTitle).joined(separator: ", ")
        return state.isEmpty ? phrase : "\(state), \(phrase)"
    }
}
