import AppKit
import CoreTransferable
import PaddleCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A tab being dragged inside Paddle (declared in Info.plist). Not text, so a web page under the pointer can't
    /// take the drop.
    nonisolated static let paddleTab = UTType(exportedAs: "com.walker.paddle.tab")
}

/// What a dragged tab puts on the pasteboard; the strips' `dropDestination`s read it.
nonisolated struct TabDragPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paddleTab)
    }
}

extension TabDragPayload {
    /// The dragged tab, in whichever window it is.
    @MainActor var tab: Tab? { AppModel.shared.allTabs.first { $0.id == id } }
}

/// Makes a tab draggable (not while it is being renamed, so a drag in the title field selects text). The drag is
/// AppKit's (`TabDragController`), not SwiftUI's, so Paddle can follow it: a tab pulled out of every tab strip becomes
/// a window under the pointer at once and moves with it, as in Firefox and Chrome.
struct TabDrag: ViewModifier {
    let tab: Tab
    let enabled: Bool
    /// A tab in a strip or sidebar (its place counts for the insertion bar), not a pane's title bar.
    var strip = true

    func body(content: Content) -> some View {
        content.background(TabDragAnchor(tab: tab, enabled: enabled, strip: strip))
    }
}

private struct TabDragAnchor: NSViewRepresentable {
    let tab: Tab
    let enabled: Bool
    let strip: Bool

    func makeNSView(context: Context) -> TabDragAnchorView { TabDragAnchorView() }

    func updateNSView(_ view: TabDragAnchorView, context: Context) {
        view.tab = tab
        view.enabled = enabled
        view.isStrip = strip
    }
}

/// The insertion bar of a tab drag: before this tab when the slot is this tab's, after it when it is the last tab and
/// the slot is the end. A 3 pt accent bar on the tab's edge (vertical tabs: its top or bottom).
struct TabDropBar: View {
    let tab: Tab
    let model: BrowserModel
    let vertical: Bool
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        if let slot = model.tabDropIndex, let index = model.tabs.firstIndex(where: { $0 === tab }),
           slot == index || (slot == model.tabs.count && index == model.tabs.count - 1) {
            let bar = Capsule().fill(theme?.accent ?? Color.accentColor)
            if vertical {
                VStack { if slot == index { bar.frame(height: 3); Spacer() } else { Spacer(); bar.frame(height: 3) } }
                    .offset(y: slot == index ? -2 : 2)
                    .allowsHitTesting(false)
            } else {
                HStack { if slot == index { bar.frame(width: 3); Spacer() } else { Spacer(); bar.frame(width: 3) } }
                    .padding(.vertical, 2)
                    .offset(x: slot == index ? -2.5 : 2.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// An invisible view the size of the tab. It takes no clicks (SwiftUI keeps selecting, closing and renaming); the
/// controller finds it under a mouse-down and starts the drag from it.
final class TabDragAnchorView: NSView {
    weak var tab: Tab?
    var enabled = true
    var isStrip = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TabDragController.shared.register(self) }
    }
}

/// A view's strip or sidebar item as a drop target: an invisible view the size of the item, taking no clicks, that
/// `TabDragController` finds under the pointer. A tab let go on it joins the view (`BrowserModel.addToView`).
final class ViewDropAnchorView: NSView {
    weak var model: BrowserModel?
    var viewID: UUID?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TabDragController.shared.register(view: self) }
    }
}

struct ViewDropAnchor: NSViewRepresentable {
    let model: BrowserModel
    let viewID: UUID

    func makeNSView(context: Context) -> ViewDropAnchorView { ViewDropAnchorView() }

    func updateNSView(_ view: ViewDropAnchorView, context: Context) {
        view.model = model
        view.viewID = viewID
    }
}

/// Runs tab drags. Inside a tab strip the drag is an ordinary drag and drop (the strips' drop destinations reorder
/// and re-dock). Once the pointer leaves every strip, the tab moves to a new window that follows the pointer (the
/// only tab of a window moves that window instead); bringing it over a strip again hides that window so the strip
/// can take the drop, and the emptied window closes. Escape puts the tab back where it was.
@MainActor
final class TabDragController: NSObject, NSDraggingSource {
    static let shared = TabDragController()

    private var anchors = NSHashTable<TabDragAnchorView>.weakObjects()
    private var viewAnchors = NSHashTable<ViewDropAnchorView>.weakObjects()
    /// The view (in the drag's own window) the tab would join when let go over its strip item.
    private weak var viewDropModel: BrowserModel?
    private var viewDropID: UUID?
    private var monitor: Any?
    private var pending: (anchor: TabDragAnchorView, start: NSPoint)?

    // The drag in progress.
    private weak var tab: Tab?
    private weak var origin: BrowserWindowController?
    private var originIndex = 0
    private var originFrame: NSRect?
    /// The window the tab is in while torn off: a new one, or its own when it was the window's only tab.
    private weak var floating: BrowserWindowController?
    private var floatingIsNew = false
    /// Pointer position relative to the floating window's top left.
    private var grabOffset = NSPoint(x: 140, y: 18)
    /// The window whose strip shows the insertion bar, and the slot.
    private weak var target: BrowserWindowController?
    private var targetIndex: Int?
    /// The pane of the drag's own window the tab would drop on (multi view), and on which edge (nil: the middle).
    private weak var paneWindow: BrowserWindowController?
    private var paneTarget: (id: UUID, edge: PaneEdge?)?
    /// The drag image is the ghost tab (over a strip), not the empty one (while the window follows the pointer).
    private var showsGhost = true
    private var ghost: NSImage?

    func register(view anchor: ViewDropAnchorView) {
        viewAnchors.add(anchor)
    }

    func register(_ anchor: TabDragAnchorView) {
        anchors.add(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { TabDragController.shared.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            SwitchTrace.mouseDown = event.timestamp
            // A double-click on a tab renames it (pinned tabs show no title, so they don't).
            if event.clickCount == 2, let tab = anchor(at: event, clicks: 2)?.tab, !tab.isPinned, let browser = tab.browser {
                pending = nil
                browser.select(tab)
                browser.renamingTabID = tab.id
                return
            }
            pending = anchor(at: event, clicks: 1).map { ($0, event.locationInWindow) }
        case .leftMouseDragged:
            guard let pending else { return }
            let moved = hypot(event.locationInWindow.x - pending.start.x, event.locationInWindow.y - pending.start.y)
            guard moved > 4 else { return }
            self.pending = nil
            begin(from: pending.anchor, event: event)
        default:
            pending = nil
        }
    }

    private func anchor(at event: NSEvent, clicks: Int) -> TabDragAnchorView? {
        guard let window = event.window, event.clickCount == clicks else { return nil }
        return anchors.allObjects.first { anchor in
            anchor.window === window && anchor.enabled && anchor.tab != nil
                && anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow)
        }
    }

    private func begin(from anchor: TabDragAnchorView, event: NSEvent) {
        guard let tab = anchor.tab, let browser = tab.browser, let controller = browser.controller,
              let data = try? JSONEncoder().encode(TabDragPayload(id: tab.id)) else { return }
        self.tab = tab
        origin = controller
        // Escape moves it back from another window, where `adopt` takes an index in the active space.
        originIndex = browser.tabs.firstIndex { $0 === tab } ?? 0
        originFrame = controller.window?.frame
        floating = nil
        floatingIsNew = false
        if let frame = controller.window?.frame {
            let mouse = NSEvent.mouseLocation
            grabOffset = NSPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        }
        showsGhost = true
        target = nil
        targetIndex = nil
        let ghost = Self.image(for: tab, size: anchor.bounds.size)
        self.ghost = ghost
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.paddleTab.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(anchor.bounds, contents: ghost)
        let session = anchor.beginDraggingSession(with: [dragging], event: event, source: self)
        // A drop nobody takes ends at once: no slide back to the tab before the window appears.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        moved(session, to: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ended(at: screenPoint, operation: operation)
    }

    private func moved(_ session: NSDraggingSession, to point: NSPoint) {
        guard let tab, let browser = tab.browser else { return }
        let overStrip = stripWindow(at: point)
        // Over a view's item in its own window's strip: it joins the view (no insertion bar).
        if let overStrip, floating == nil, let view = viewItem(in: overStrip, at: point, dragging: tab) {
            showSlot(nil)
            showViewDrop(view, in: overStrip.model)
            return
        }
        showViewDrop(nil, in: nil)
        showSlot(overStrip.map { ($0, slot(in: $0, at: point)) })
        if let floating {
            guard let window = floating.window else { return }
            window.setFrameTopLeftPoint(NSPoint(x: point.x - grabOffset.x, y: point.y + grabOffset.y))
            // Over a strip the floating window leaves the screen and the ghost tab shows where it goes: a window
            // under the pointer would hide the insertion bar.
            if overStrip == nil, !window.isVisible {
                window.orderFront(nil)
            } else if overStrip != nil, window.isVisible {
                window.orderOut(nil)
            }
            setGhost(overStrip != nil, in: session)
            return
        }
        guard overStrip == nil else {
            showPane(nil, in: nil)
            return
        }
        // Over the page area of its own window: a pane takes it (multi view), shown by a highlight; no tear-off.
        if let origin = browser.controller, let (id, edge) = pane(in: origin, at: point, dragging: tab) {
            showPane((id, edge), in: origin)
            return
        }
        showPane(nil, in: nil)
        if let origin = browser.controller, let window = origin.window, window.frame.contains(point) { return }
        // Out of every strip and its window: tear off.
        if browser.allTabs.count == 1 {
            floating = browser.controller
            floatingIsNew = false
        } else {
            let controller = AppModel.shared.openWindow(isPrivate: browser.isPrivate, profile: browser.profileID, moving: [tab])
            controller.model.select(tab)
            floating = controller
            floatingIsNew = true
            grabOffset = NSPoint(x: 140, y: 18)
        }
        // Clicks pass through the window that follows the pointer.
        floating?.window?.ignoresMouseEvents = true
        floating?.window?.orderFront(nil)
        floating?.window?.setFrameTopLeftPoint(NSPoint(x: point.x - grabOffset.x, y: point.y + grabOffset.y))
        // The window is the drag image now.
        setGhost(false, in: session)
    }

    private func setGhost(_ shown: Bool, in session: NSDraggingSession) {
        guard shown != showsGhost else { return }
        showsGhost = shown
        let image = shown ? ghost : NSImage(size: NSSize(width: 1, height: 1))
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(item.draggingFrame, contents: image)
        }
    }

    /// The pane under `point` in `window`'s page area and the drop edge there (`PaneLayout.dropEdge`), unless it is
    /// `tab`'s own pane, it can't take `tab` (pinned, a full view's edge), or the link preview covers the area.
    private func pane(in window: BrowserWindowController, at point: NSPoint, dragging tab: Tab) -> (UUID, PaneEdge?)? {
        let model = window.model
        guard model.preview == nil, !tab.isPinned, let local = window.contentPoint(fromScreen: point),
              let (id, frame) = model.paneFrames.first(where: { $0.value.contains(local) }), id != tab.id,
              let target = model.tabs.first(where: { $0.id == id }), !target.isPinned else { return nil }
        let edge = PaneLayout.dropEdge(at: local, in: frame)
        if let edge, let view = model.split(of: target), !view.contains(tab), view.layout.count >= model.maxPanes { return nil }
        // The middle of a single page (no view) only selects the tab, which the strip does; leave it to tear-off rules.
        if edge == nil, model.split(of: target) == nil { return nil }
        return (id, edge)
    }

    /// The view whose item is under `point` in `window`'s strip or sidebar, when `tab` (of that window, not pinned,
    /// not in it) can join it.
    private func viewItem(in window: BrowserWindowController, at point: NSPoint, dragging tab: Tab) -> BrowserModel.Split? {
        let model = window.model
        guard tab.browser === model, !tab.isPinned else { return nil }
        for anchor in viewAnchors.allObjects {
            guard anchor.model === model, let id = anchor.viewID, let anchorWindow = anchor.window, anchorWindow === window.window,
                  anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point),
                  let view = model.view(id: id), !view.contains(tab), view.layout.count < model.maxPanes else { continue }
            return view
        }
        return nil
    }

    /// Highlights `view`'s item in `model`'s window, or removes the highlight.
    private func showViewDrop(_ view: BrowserModel.Split?, in model: BrowserModel?) {
        if let viewDropModel, viewDropModel !== model || view == nil { viewDropModel.viewDropTargetID = nil }
        viewDropModel = view == nil ? nil : model
        viewDropID = view?.id
        if let view, let model, model.viewDropTargetID != view.id { model.viewDropTargetID = view.id }
    }

    /// Shows the pane highlight in `window` (removing it from the window that had it), or removes it.
    private func showPane(_ drop: (UUID, PaneEdge?)?, in window: BrowserWindowController?) {
        if let paneWindow, paneWindow !== window || drop == nil { paneWindow.model.paneDropHint = nil }
        paneWindow = drop == nil ? nil : window
        paneTarget = drop.map { (id: $0.0, edge: $0.1) }
        if let drop, let window {
            let current = window.model.paneDropHint
            if current?.target != drop.0 || current?.edge != drop.1 { window.model.paneDropHint = (target: drop.0, edge: drop.1) }
        }
    }

    /// Moves the insertion bar to `slot` of `window`, or removes it.
    private func showSlot(_ slot: (BrowserWindowController, Int)?) {
        if let target, target !== slot?.0 { target.model.tabDropIndex = nil }
        target = slot?.0
        targetIndex = slot?.1
        if let slot, slot.0.model.tabDropIndex != slot.1 { slot.0.model.tabDropIndex = slot.1 }
    }

    /// The slot in `window`'s `tabs` before the first shown tab whose middle is past the pointer (right of it, or below
    /// it with vertical tabs), else after the last shown tab. The dragged tab itself is left out.
    private func slot(in window: BrowserWindowController, at point: NSPoint) -> Int {
        let model = window.model
        let vertical = AppModel.shared.config.tabLayout == .vertical
        let shown: [(tab: Tab, frame: NSRect)] = anchors.allObjects.compactMap { anchor in
            guard anchor.isStrip, let anchorTab = anchor.tab, anchorTab !== tab, let anchorWindow = anchor.window,
                  anchorWindow === window.window, model.tabs.contains(where: { $0 === anchorTab }) else { return nil }
            return (anchorTab, anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil)))
        }
        let ordered = shown.sorted { vertical ? $0.frame.midY > $1.frame.midY : $0.frame.midX < $1.frame.midX }
        if let next = ordered.first(where: { vertical ? $0.frame.midY < point.y : $0.frame.midX > point.x }) {
            return model.tabs.firstIndex { $0 === next.tab } ?? model.tabs.count
        }
        guard let last = ordered.last, let index = model.tabs.firstIndex(where: { $0 === last.tab }) else { return model.tabs.count }
        return index + 1
    }

    private func ended(at point: NSPoint, operation: NSDragOperation) {
        let slot = target.flatMap { target in targetIndex.map { (target, $0) } }
        showSlot(nil)
        let pane = paneWindow.flatMap { window in paneTarget.map { (window, $0) } }
        showPane(nil, in: nil)
        let joining = viewDropModel.flatMap { model in viewDropID.flatMap(model.view(id:)).map { (model, $0) } }
        showViewDrop(nil, in: nil)
        defer {
            tab = nil
            floating = nil
            ghost = nil
        }
        let window = floating?.window
        window?.ignoresMouseEvents = false
        let escaped = NSApp.currentEvent.map { $0.type == .keyDown || $0.type == .keyUp } ?? false
        if escaped, let tab {
            if floatingIsNew, let origin, floating != nil {
                AppModel.shared.move(tab, to: origin, at: originIndex, select: true)
            } else if floating != nil, let originFrame {
                window?.setFrame(originFrame, display: true)
                window?.orderFront(nil)
            }
            return
        }
        // A group label took it (SwiftUI's drop): its handler moved the tab.
        if !operation.isEmpty { return }
        // Let go over a view's strip item in its own window: it joins the view.
        if floating == nil, let tab, let (model, view) = joining, tab.browser === model {
            model.addToView(tab, view)
            return
        }
        // Let go over a pane of its own window, never torn off: it goes there.
        if floating == nil, let tab, let (window, drop) = pane, tab.browser === window.model,
           let target = window.model.tabs.first(where: { $0.id == drop.id }) {
            window.model.dropTab(tab, onto: target, edge: drop.edge)
            return
        }
        if let tab, let (destination, index) = slot {
            insert(tab, into: destination, at: index)
        }
        // Not placed in a strip (let go away from them all, or the strip refused it, e.g. another profile): the
        // floating window stays where it was let go, back on screen.
        guard let tab, let floating, tab.browser === floating.model, let window else { return }
        if !window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: point.x - grabOffset.x, y: point.y + grabOffset.y)) }
        window.makeKeyAndOrderFront(nil)
        floating.model.select(tab)
    }

    /// Puts `tab` at `index` of `destination`'s `tabs`, taking the group of the two tabs around the slot when they
    /// share one. An emptied window closes (`AppModel.move`).
    private func insert(_ tab: Tab, into destination: BrowserWindowController, at index: Int) {
        let model = destination.model
        guard model.canAccept(tab) else { return }
        let tabs = model.tabs
        let group = index > 0 && index < tabs.count && tabs[index - 1].groupID == tabs[index].groupID ? tabs[index].groupID : nil
        if tab.browser === model {
            // `place` takes an index over every space's tabs, counted without the tab itself.
            var local = index
            if let current = tabs.firstIndex(where: { $0 === tab }), current < index { local -= 1 }
            let offset = tabs.first.flatMap { first in model.allTabs.firstIndex { $0 === first } } ?? 0
            AppModel.shared.move(tab, to: destination, at: offset + local, select: true)
        } else {
            AppModel.shared.move(tab, to: destination, at: index, select: true)
        }
        guard tab.browser === model else { return }
        tab.groupID = group
        model.normalizeGroups()
        destination.window?.makeKeyAndOrderFront(nil)
    }

    /// The browser window whose tab area (the strip in the title bar, or the vertical sidebar) is under `point`,
    /// leaving out the window following the pointer. A margin keeps a tab near the strip from tearing off.
    private func stripWindow(at point: NSPoint) -> BrowserWindowController? {
        let vertical = AppModel.shared.config.tabLayout == .vertical
        let defaults = UserDefaults.standard
        let sidebarWidth = defaults.bool(forKey: SidebarMetrics.collapsedKey)
            ? SidebarMetrics.collapsedWidth
            : SidebarMetrics.clamped(defaults.object(forKey: SidebarMetrics.widthKey) as? Double ?? SidebarMetrics.defaultWidth)
        for controller in AppModel.shared.windows where controller !== floating {
            guard let window = controller.window, window.isVisible, !window.isMiniaturized else { continue }
            let frame = window.frame
            let area = vertical
                ? NSRect(x: frame.minX, y: frame.minY, width: sidebarWidth, height: frame.height)
                : NSRect(x: frame.minX, y: frame.maxY - 38, width: frame.width, height: 38)
            if area.insetBy(dx: -12, dy: -16).contains(point) { return controller }
        }
        return nil
    }

    /// The ghost tab: a translucent tab shape with the tab's title (a SwiftUI view can't be snapshotted reliably).
    private static func image(for tab: Tab, size: NSSize) -> NSImage {
        let size = NSSize(width: max(size.width, 60), height: max(size.height, 24))
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: tab.displayTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75),
                .paragraphStyle: style,
            ])
            title.draw(in: NSRect(x: 10, y: (rect.height - 16) / 2, width: rect.width - 20, height: 16))
            return true
        }
    }
}

/// A dragged tab dropped onto a group label (the strips themselves are `TabDragController`'s).
@MainActor
enum TabDrop {
    /// Onto a group label: into that group (moved to this window first when it comes from another).
    static func add(_ payloads: [TabDragPayload], to group: TabGroup, in model: BrowserModel) -> Bool {
        guard let dragged = payloads.first?.tab, !dragged.isPinned else { return false }
        if dragged.browser !== model {
            guard let controller = model.controller, model.canAccept(dragged) else { return false }
            AppModel.shared.move(dragged, to: controller, at: model.tabs.count, select: true)
        }
        model.add(dragged, to: group)
        return true
    }
}
