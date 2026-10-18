import CoreGraphics
import Foundation

/// How a split divides its space: `horizontal` puts its two sides next to each other (a vertical divider),
/// `vertical` stacks them (a horizontal divider).
public enum PaneAxis: String, Codable, Sendable {
    case horizontal, vertical
}

/// The edge of a pane a tab is dropped on: it takes that side of the pane, which gives up half its space.
public enum PaneEdge: String, Sendable, CaseIterable {
    case left, right, top, bottom

    var axis: PaneAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// The new tab is the first side of the split (left or top).
    var newFirst: Bool { self == .left || self == .top }
}

/// One node of a multi view: a tab (by its session id), or a split of two nodes at `ratio` (the first side's share).
public indirect enum PaneNode: Equatable, Sendable {
    case tab(String)
    case split(PaneAxis, ratio: Double, PaneNode, PaneNode)

    /// Its tabs, left to right and top to bottom (depth first).
    public var tabs: [String] {
        switch self {
        case .tab(let id): [id]
        case .split(_, _, let a, let b): a.tabs + b.tabs
        }
    }
}

/// A divider of a multi view, where it is drawn and which split it moves (`path`: 0 for the first side, 1 for the
/// second, from the root down).
public struct PaneDivider: Equatable, Sendable {
    public var path: [Int]
    public var axis: PaneAxis
    public var frame: CGRect
    /// The split's whole rectangle, which a drag's position is measured against.
    public var span: CGRect
}

/// Several tabs of one window shown at once, tiled: a tree of splits whose leaves are tabs. Two to `maxPanes`
/// tabs; a tab is in it at most once. A two-tab layout side by side is what split view always was
/// (`init(split:)`). The rules on which tabs may share a layout (adjacent in the strip, not pinned, one group) are
/// the app's, as for `SplitRules`.
public struct PaneLayout: Equatable, Sendable {
    public static let maxPanes = 6
    /// A side's share can't go below 15 %, so no pane is dragged out of sight.
    public static let ratioRange: ClosedRange<Double> = 0.15...0.85

    public private(set) var root: PaneNode
    /// The view's name in the tab strip, set by Rename View; nil shows the focused pane's site.
    public var name: String?

    public init?(root: PaneNode) {
        guard let root = Self.cleaned(root), root.tabs.count >= 2, root.tabs.count <= Self.maxPanes,
              Set(root.tabs).count == root.tabs.count else { return nil }
        self.root = root
    }

    /// The two tabs of a split view record, side by side at its ratio.
    public init(split: SplitRecord) {
        root = .split(.horizontal, ratio: Self.clamped(split.ratio), .tab(split.left), .tab(split.right))
    }

    /// Two tabs side by side: `first` on the left.
    public init?(_ first: String, _ second: String, axis: PaneAxis = .horizontal) {
        guard first != second else { return nil }
        root = .split(axis, ratio: 0.5, .tab(first), .tab(second))
    }

    public var tabs: [String] { root.tabs }
    /// The same layout without a name.
    public var unnamed: PaneLayout {
        var copy = self
        copy.name = nil
        return copy
    }
    public var count: Int { tabs.count }
    public func contains(_ id: String) -> Bool { tabs.contains(id) }
    public var isFull: Bool { count >= Self.maxPanes }

    /// Puts `new` on `edge` of `target`'s pane, which keeps the other half. False (and nothing changes) when `new` is
    /// already shown, `target` isn't, or the layout already has `limit` panes (at most `maxPanes`).
    @discardableResult
    public mutating func insert(_ new: String, at target: String, edge: PaneEdge, limit: Int = PaneLayout.maxPanes) -> Bool {
        guard !contains(new), contains(target), count < min(limit, Self.maxPanes) else { return false }
        root = Self.inserting(new, at: target, edge: edge, in: root)
        return true
    }

    /// Takes `id` out; its sibling takes its space. Returns the layout left, nil when fewer than two tabs remain
    /// (the multi view ends) or `id` wasn't in it (then the layout is unchanged).
    public func removing(_ id: String) -> PaneLayout? {
        guard contains(id), let rest = Self.removing(id, from: root), rest.tabs.count >= 2 else { return contains(id) ? nil : self }
        var copy = self
        copy.root = rest
        return copy
    }

    /// Swaps two shown tabs' panes. False when either isn't shown.
    @discardableResult
    public mutating func swap(_ a: String, _ b: String) -> Bool {
        guard a != b, contains(a), contains(b) else { return false }
        root = Self.mapTabs(root) { $0 == a ? b : $0 == b ? a : $0 }
        return true
    }

    /// Puts `new` in `old`'s pane (a tab replaced by another, as a link preview becoming the tab). False when `old`
    /// isn't shown or `new` already is.
    @discardableResult
    public mutating func replace(_ old: String, with new: String) -> Bool {
        guard contains(old), !contains(new) else { return false }
        root = Self.mapTabs(root) { $0 == old ? new : $0 }
        return true
    }

    /// Moves `id` from its pane to `edge` of `target` (a pane dragged onto another). False when either isn't
    /// shown, they're the same, or only these two are shown (then swap instead).
    @discardableResult
    public mutating func move(_ id: String, to target: String, edge: PaneEdge) -> Bool {
        guard id != target, contains(id), contains(target), count > 2, let rest = Self.removing(id, from: root) else { return false }
        root = Self.inserting(id, at: target, edge: edge, in: rest)
        return true
    }

    /// The layout with every tab renamed by `rename` (session ids to tab ids and back); a tab it names nil is taken out.
    /// Nil when fewer than two are left or two would share a name.
    public func mapped(_ rename: (String) -> String?) -> PaneLayout? {
        var layout: PaneLayout? = self
        for id in tabs where rename(id) == nil { layout = layout?.removing(id) }
        guard let layout else { return nil }
        let names = layout.tabs.compactMap(rename)
        guard Set(names).count == names.count else { return nil }
        var renamed = PaneLayout(root: Self.mapTabs(layout.root) { rename($0) ?? $0 })
        renamed?.name = name
        return renamed
    }

    /// Sets the ratio of the split at `path`, clamped to `ratioRange`. False for a path that isn't a split.
    @discardableResult
    public mutating func setRatio(_ ratio: Double, at path: [Int]) -> Bool {
        guard let updated = Self.updatingSplit(at: path, in: root, { axis, _, a, b in .split(axis, ratio: Self.clamped(ratio), a, b) }) else {
            return false
        }
        root = updated
        return true
    }

    /// Every split back to even shares (the double-click on a divider does one; this is View > Even Out Panes).
    public mutating func equalize() {
        root = Self.equalized(root)
    }

    // MARK: - Geometry

    /// Each tab's rectangle in `rect`, with `gap` points between panes for the dividers.
    public func frames(in rect: CGRect, gap: CGFloat = 1) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        var unused: [PaneDivider] = []
        Self.layout(root, in: rect, gap: gap, path: [], frames: &out, dividers: &unused)
        return out
    }

    /// The dividers, each with the split it moves.
    public func dividers(in rect: CGRect, gap: CGFloat = 1) -> [PaneDivider] {
        var frames: [String: CGRect] = [:]
        var out: [PaneDivider] = []
        Self.layout(root, in: rect, gap: gap, path: [], frames: &frames, dividers: &out)
        return out
    }

    /// The ratio a divider drag to `point` sets: the point's position across the divider's split, clamped.
    public static func ratio(dragging divider: PaneDivider, to point: CGPoint) -> Double {
        let span = divider.span
        let value = divider.axis == .horizontal
            ? (span.width > 0 ? Double((point.x - span.minX) / span.width) : 0.5)
            : (span.height > 0 ? Double((point.y - span.minY) / span.height) : 0.5)
        return clamped(value)
    }

    /// The pane next to `id` in a direction (⌘⌥ and an arrow), measured in `rect`: of the panes on that side that
    /// overlap it across, the nearest, then the one overlapping most. Nil at the edge.
    public func neighbor(of id: String, toward edge: PaneEdge, in rect: CGRect) -> String? {
        let frames = frames(in: rect, gap: 0)
        guard let from = frames[id] else { return nil }
        let candidates = frames.filter { other, frame in
            guard other != id else { return false }
            switch edge {
            case .left: return frame.maxX <= from.minX + 0.5 && Self.overlap(frame.minY, frame.maxY, from.minY, from.maxY) > 0
            case .right: return frame.minX >= from.maxX - 0.5 && Self.overlap(frame.minY, frame.maxY, from.minY, from.maxY) > 0
            case .top: return frame.maxY <= from.minY + 0.5 && Self.overlap(frame.minX, frame.maxX, from.minX, from.maxX) > 0
            case .bottom: return frame.minY >= from.maxY - 0.5 && Self.overlap(frame.minX, frame.maxX, from.minX, from.maxX) > 0
            }
        }
        func distance(_ frame: CGRect) -> CGFloat {
            switch edge {
            case .left: from.minX - frame.maxX
            case .right: frame.minX - from.maxX
            case .top: from.minY - frame.maxY
            case .bottom: frame.minY - from.maxY
            }
        }
        func shared(_ frame: CGRect) -> CGFloat {
            edge.axis == .horizontal ? Self.overlap(frame.minY, frame.maxY, from.minY, from.maxY)
                : Self.overlap(frame.minX, frame.maxX, from.minX, from.maxX)
        }
        return candidates.min { a, b in
            let da = distance(a.value), db = distance(b.value)
            if abs(da - db) > 0.5 { return da < db }
            if shared(a.value) != shared(b.value) { return shared(a.value) > shared(b.value) }
            return a.key < b.key
        }?.key
    }

    /// Where a drag over `frame` (a pane's rectangle) at `point` would drop: the edge band it is in (the outer 30 %
    /// of the pane toward that edge, the nearest edge in a corner), or nil in the middle (a swap).
    public static func dropEdge(at point: CGPoint, in frame: CGRect) -> PaneEdge? {
        guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        let band: CGFloat = 0.3
        let distances: [(PaneEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < band else { return nil }
        return nearest.0
    }

    // MARK: - Tree work

    static func clamped(_ ratio: Double) -> Double {
        ratio.isFinite ? min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound) : 0.5
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }

    private static func inserting(_ new: String, at target: String, edge: PaneEdge, in node: PaneNode) -> PaneNode {
        switch node {
        case .tab(let id) where id == target:
            return edge.newFirst ? .split(edge.axis, ratio: 0.5, .tab(new), node) : .split(edge.axis, ratio: 0.5, node, .tab(new))
        case .tab:
            return node
        case .split(let axis, let ratio, let a, let b):
            return .split(axis, ratio: ratio, inserting(new, at: target, edge: edge, in: a), inserting(new, at: target, edge: edge, in: b))
        }
    }

    private static func removing(_ id: String, from node: PaneNode) -> PaneNode? {
        switch node {
        case .tab(let tab): return tab == id ? nil : node
        case .split(let axis, let ratio, let a, let b):
            switch (removing(id, from: a), removing(id, from: b)) {
            case (nil, nil): return nil
            case (let rest?, nil), (nil, let rest?): return rest
            case (let a?, let b?): return .split(axis, ratio: ratio, a, b)
            }
        }
    }

    private static func mapTabs(_ node: PaneNode, _ transform: (String) -> String) -> PaneNode {
        switch node {
        case .tab(let id): .tab(transform(id))
        case .split(let axis, let ratio, let a, let b): .split(axis, ratio: ratio, mapTabs(a, transform), mapTabs(b, transform))
        }
    }

    private static func updatingSplit(
        at path: [Int], in node: PaneNode, _ change: (PaneAxis, Double, PaneNode, PaneNode) -> PaneNode
    ) -> PaneNode? {
        guard case .split(let axis, let ratio, let a, let b) = node else { return nil }
        guard let step = path.first else { return change(axis, ratio, a, b) }
        let rest = Array(path.dropFirst())
        switch step {
        case 0: return updatingSplit(at: rest, in: a, change).map { .split(axis, ratio: ratio, $0, b) }
        case 1: return updatingSplit(at: rest, in: b, change).map { .split(axis, ratio: ratio, a, $0) }
        default: return nil
        }
    }

    private static func equalized(_ node: PaneNode) -> PaneNode {
        switch node {
        case .tab: node
        case .split(let axis, _, let a, let b): .split(axis, ratio: 0.5, equalized(a), equalized(b))
        }
    }

    /// Ratios clamped, a split of a tab with itself collapsed; nil for nothing left.
    static func cleaned(_ node: PaneNode) -> PaneNode? {
        switch node {
        case .tab: return node
        case .split(let axis, let ratio, let a, let b):
            switch (cleaned(a), cleaned(b)) {
            case (nil, nil): return nil
            case (let one?, nil), (nil, let one?): return one
            case (let a?, let b?): return .split(axis, ratio: clamped(ratio), a, b)
            }
        }
    }

    private static func layout(
        _ node: PaneNode, in rect: CGRect, gap: CGFloat, path: [Int], frames: inout [String: CGRect], dividers: inout [PaneDivider]
    ) {
        switch node {
        case .tab(let id):
            frames[id] = rect
        case .split(let axis, let ratio, let a, let b):
            let first: CGRect, second: CGRect, divider: CGRect
            if axis == .horizontal {
                let w = max(0, rect.width - gap)
                let wa = (w * CGFloat(ratio)).rounded()
                first = CGRect(x: rect.minX, y: rect.minY, width: wa, height: rect.height)
                divider = CGRect(x: rect.minX + wa, y: rect.minY, width: gap, height: rect.height)
                second = CGRect(x: rect.minX + wa + gap, y: rect.minY, width: w - wa, height: rect.height)
            } else {
                let h = max(0, rect.height - gap)
                let ha = (h * CGFloat(ratio)).rounded()
                first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ha)
                divider = CGRect(x: rect.minX, y: rect.minY + ha, width: rect.width, height: gap)
                second = CGRect(x: rect.minX, y: rect.minY + ha + gap, width: rect.width, height: h - ha)
            }
            dividers.append(PaneDivider(path: path, axis: axis, frame: divider, span: rect))
            layout(a, in: first, gap: gap, path: path + [0], frames: &frames, dividers: &dividers)
            layout(b, in: second, gap: gap, path: path + [1], frames: &frames, dividers: &dividers)
        }
    }
}

// MARK: - Session form

/// `{"tab": "<id>"}` or `{"axis": "horizontal", "ratio": 0.5, "first": {…}, "second": {…}}`. Lenient: an odd ratio is
/// clamped or 0.5, an unknown axis is horizontal.
extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey { case tab, axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .tab) {
            self = .tab(id)
            return
        }
        let axis = (try? c.decodeIfPresent(PaneAxis.self, forKey: .axis)).flatMap { $0 } ?? .horizontal
        let ratio = PaneLayout.clamped((try? c.decodeIfPresent(Double.self, forKey: .ratio)).flatMap { $0 } ?? 0.5)
        self = .split(axis, ratio: ratio, try c.decode(PaneNode.self, forKey: .first), try c.decode(PaneNode.self, forKey: .second))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let id):
            try c.encode(id, forKey: .tab)
        case .split(let axis, let ratio, let a, let b):
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .first)
            try c.encode(b, forKey: .second)
        }
    }
}

/// The root node's object, with the view's `name` beside its keys when it has one.
extension PaneLayout: Codable {
    private enum NameKey: String, CodingKey { case name }

    public init(from decoder: Decoder) throws {
        let node = try PaneNode(from: decoder)
        guard var layout = PaneLayout(root: node) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not 2 to \(Self.maxPanes) distinct tabs"))
        }
        let c = try decoder.container(keyedBy: NameKey.self)
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        layout.name = name?.isEmpty == false ? String(name!.prefix(60)) : nil
        self = layout
    }

    public func encode(to encoder: Encoder) throws {
        try root.encode(to: encoder)
        if let name {
            var c = encoder.container(keyedBy: NameKey.self)
            try c.encode(name, forKey: .name)
        }
    }

    /// A saved layout against the window's tabs now: tabs that are gone taken out (their siblings take the space);
    /// nil when fewer than two are left.
    public func keeping(_ existing: Set<String>) -> PaneLayout? {
        var layout: PaneLayout? = self
        for id in tabs where !existing.contains(id) { layout = layout?.removing(id) }
        return layout
    }
}
