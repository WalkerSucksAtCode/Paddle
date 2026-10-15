import AppKit
import PaddleCore
import SwiftUI

/// The content area of a split: the left and right tab's pages side by side, a draggable divider between them, and an
/// edge on the focused side. Under `minimumWidth` only the focused side shows (the split is kept).
struct SplitPanes<Pane: View>: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    let left: Tab
    let right: Tab
    /// The selected tab: one of `left` and `right`.
    let focused: Tab
    let pane: (Tab, Bool) -> Pane
    @Environment(\.chromeTheme) private var theme

    static var minimumWidth: CGFloat { 640 }
    /// The least either side can take, in points (and `SplitRecord.ratioRange` as a share).
    static var minimumSide: CGFloat { 320 }
    private static var dividerHit: CGFloat { 6 }

    private static func minSide(in width: CGFloat) -> CGFloat { max(minimumSide, width * SplitRecord.ratioRange.lowerBound) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let narrow = width < Self.minimumWidth
            let side = Self.minSide(in: width)
            let leftWidth = min(max(width * split.ratio, side), max(side, width - side))
            let focusedLeft = focused.id == left.id
            Group {
                if narrow {
                    framed(focused, focused: true, edge: false).id(focused.id)
                } else {
                    // The divider is a real gap of chrome between the pages: a thin line drawn over a page vanished
                    // on light pages in dark mode (measured all white).
                    HStack(spacing: 0) {
                        framed(left, focused: focusedLeft).id(left.id)
                            .frame(width: max(0, leftWidth - Self.dividerHit / 2))
                        SplitDivider(model: model, split: split, width: width, side: side)
                            .frame(width: Self.dividerHit)
                        framed(right, focused: !focusedLeft).id(right.id)
                    }
                    .background(theme?.toolbar ?? Color(nsColor: .windowBackgroundColor))
                }
            }
            .coordinateSpace(.named("splitArea"))
            // Where a click focuses the other side: the controller's mouse monitor reads this.
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .global)
                if narrow { return .zero }
                return focusedLeft
                    ? CGRect(x: frame.minX + leftWidth + Self.dividerHit / 2, y: frame.minY, width: frame.width - leftWidth - Self.dividerHit / 2, height: frame.height)
                    : CGRect(x: frame.minX, y: frame.minY, width: leftWidth - Self.dividerHit / 2, height: frame.height)
            } action: { model.splitUnfocusedFrame = $0 }
        }
        .onDisappear { model.splitUnfocusedFrame = .zero }
    }

    private func framed(_ tab: Tab, focused: Bool, edge: Bool = true) -> some View {
        pane(tab, focused)
            // Inside the pane's frame, by brightness alone: a dark ring with a light one inside it, so it shows on light
            // and dark pages alike (a single translucent line vanished on light pages in dark mode).
            .overlay {
                if focused && edge {
                    ZStack {
                        Rectangle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2)
                        Rectangle().inset(by: 2).strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(focused ? "Focused side" : "Other side")
    }
}

/// The 6 pt gap between the pages: a grip in the middle, a resize cursor, drag to move, double-click for 50/50.
private struct SplitDivider: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    /// The content area's width and the least either side can take.
    let width: CGFloat
    let side: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(Capsule().fill(Color.secondary.opacity(0.7)).frame(width: 2, height: 28))
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("splitArea")).onChanged { value in
                    guard width > 0 else { return }
                    let x = min(max(value.location.x, side), max(side, width - side))
                    model.setSplitRatio(Double(x / width), for: split)
                }
            )
            .onTapGesture(count: 2) { model.setSplitRatio(0.5, for: split) }
            .accessibilityElement()
            .accessibilityLabel("Split divider")
            .accessibilityValue("\(Int((split.ratio * 100).rounded())) percent left")
            .accessibilityAdjustableAction { direction in
                model.setSplitRatio(split.ratio + (direction == .increment ? 0.05 : -0.05), for: split)
            }
    }
}

/// The pair's bracket in the tab strip (underline) or sidebar (leading edge): the first tab's piece opens toward the
/// second, the second's toward the first, so the two read as one shape.
nonisolated struct SplitBracket: Shape {
    let first: Bool
    let vertical: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        let tick: CGFloat = 4
        if vertical {
            let x = r.minX + 1.5
            if first {
                p.move(to: CGPoint(x: x + tick, y: r.minY + 3)); p.addLine(to: CGPoint(x: x, y: r.minY + 3)); p.addLine(to: CGPoint(x: x, y: r.maxY + 1))
            } else {
                p.move(to: CGPoint(x: x, y: r.minY - 1)); p.addLine(to: CGPoint(x: x, y: r.maxY - 3)); p.addLine(to: CGPoint(x: x + tick, y: r.maxY - 3))
            }
        } else {
            let y = r.maxY + 3
            if first {
                p.move(to: CGPoint(x: r.minX + 3, y: y - tick)); p.addLine(to: CGPoint(x: r.minX + 3, y: y)); p.addLine(to: CGPoint(x: r.maxX + 1, y: y))
            } else {
                p.move(to: CGPoint(x: r.minX - 1, y: y)); p.addLine(to: CGPoint(x: r.maxX - 3, y: y)); p.addLine(to: CGPoint(x: r.maxX - 3, y: y - tick))
            }
        }
        return p
    }
}

extension View {
    /// The split bracket on a strip tab or sidebar row that is one side of a split.
    @ViewBuilder
    func splitBracket(_ side: SplitSide?, vertical: Bool, ink: Color) -> some View {
        if let side {
            overlay {
                SplitBracket(first: side == .left, vertical: vertical)
                    .stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}

/// Which side of a split a tab is.
enum SplitSide { case left, right }

extension BrowserModel {
    /// The side `tab` is on, nil when it is not split.
    func splitSide(of tab: Tab) -> SplitSide? {
        guard let split = split(of: tab) else { return nil }
        return split.leftID == tab.id ? .left : .right
    }

    /// What VoiceOver adds for a split tab.
    func spokenSplit(of tab: Tab, after state: String) -> String {
        guard let other = partner(of: tab) else { return state }
        let phrase = "split with \(other.displayTitle)"
        return state.isEmpty ? phrase : "\(state), \(phrase)"
    }
}
