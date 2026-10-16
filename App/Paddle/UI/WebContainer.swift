import AppKit
import SwiftUI
import WebKit

/// Shows the selected tab's container (its web view, plus a docked Web Inspector). Other tabs' containers are
/// detached from the window, which lets WebKit throttle their timers and stop rendering them.
struct WebContainer: NSViewRepresentable {
    let tab: Tab
    /// Changes whenever the tab's web view is created or dropped.
    let generation: Int
    /// False for the unfocused side of a split: attaching it leaves the keyboard where it is.
    var takesKeyboard = true
    /// The link preview's card: it shows the tab only while the tab is still the preview. After Open as Tab the fading
    /// card's view keeps being updated (SwiftUI doesn't rebuild a view on its way out) and can come after the tab's own
    /// in the same pass; taking the page then, it would leave the window with it.
    var forPreview = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let container = tab.container
        guard tab.isPreview == forPreview else { return }
        if view.subviews.count == 1, view.subviews.first === container {
            if generation != context.coordinator.generation, takesKeyboard { tab.browser?.controller?.focusWebView() }
            context.coordinator.generation = generation
            return
        }
        view.subviews.forEach { $0.removeFromSuperview() }
        container.frame = view.bounds
        container.autoresizingMask = [.width, .height]
        container.isHidden = false
        view.addSubview(container)
        context.coordinator.generation = generation
        if takesKeyboard { tab.browser?.controller?.focusWebView() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var generation = -1
    }
}

/// Draws the awake pages in one window. They stay attached. The one on screen is opaque; the others are
/// transparent, so nothing is reparented when you switch.
///
/// `addSubview` on a view that is already in this window still calls `viewDidMoveToWindow` and
/// `_removeLayerFromSuperlayer`. The layer is gone until that tab's process paints again, which is the
/// frozen second between two awake pages. `isHidden` does the same via `viewDidHide`. Opacity does neither.
/// Media is left alone unless `resumeMediaOnSelect` is on.
struct MountedWebPages: NSViewRepresentable {
    var tabs: [Tab]
    var selectedID: UUID?
    /// Off unless `resumeMediaOnSelect` is set. On, the selected page's media resumes and the others pause.
    var resumeMediaOnSelect = false

    func makeNSView(context: Context) -> MountedWebHost {
        let view = MountedWebHost()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: MountedWebHost, context: Context) {
        let keep = Set(tabs.map { ObjectIdentifier($0.container) })
        for subview in view.subviews where !keep.contains(ObjectIdentifier(subview)) {
            subview.isHidden = false
            subview.removeFromSuperview()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tab in tabs {
            let show = tab.id == selectedID
            // Opacity, not addSubview and not isHidden: both of those take the layer down.
            tab.container.alphaValue = show ? 1 : 0
            guard tab.container.superview !== view else { continue }
            tab.container.frame = view.bounds
            tab.container.autoresizingMask = [.width, .height]
            tab.container.isHidden = false
            view.addSubview(tab.container)
        }
        CATransaction.commit()
        view.front = tabs.first { $0.id == selectedID }?.container
        if resumeMediaOnSelect {
            let alive = Set(tabs.map(\.id))
            context.coordinator.suspended = context.coordinator.suspended.filter { alive.contains($0.key) }
            for tab in tabs {
                let suspend = tab.id != selectedID
                guard context.coordinator.suspended[tab.id] != suspend else { continue }
                tab.webView?.setAllMediaPlaybackSuspended(suspend, completionHandler: nil)
                context.coordinator.suspended[tab.id] = suspend
            }
        } else if context.coordinator.suspended.values.contains(true) {
            // The option was on and paused these. Release them so a page can play on its own again.
            for tab in tabs where context.coordinator.suspended[tab.id] == true {
                tab.webView?.setAllMediaPlaybackSuspended(false, completionHandler: nil)
            }
            context.coordinator.suspended.removeAll()
        }
        if context.coordinator.front != selectedID, selectedID != nil, let shown = tabs.first(where: { $0.id == selectedID }) {
            shown.browser?.controller?.focusWebView()
            SwitchTrace.shown(shown)
        }
        context.coordinator.front = selectedID
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var front: UUID?
        var suspended: [UUID: Bool] = [:]
    }
}

/// Hit testing follows subview order, not `zPosition`, so clicks go to the page that is drawn in front.
final class MountedWebHost: NSView {
    weak var front: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let front, front.superview === self else { return super.hitTest(point) }
        guard isMousePoint(point, in: frame) else { return nil }
        return front.hitTest(convert(point, from: superview))
    }
}
