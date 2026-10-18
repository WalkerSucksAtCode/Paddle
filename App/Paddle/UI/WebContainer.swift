import os
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
        // A container taken from `MountedWebPages` may still be transparent there.
        container.alphaValue = 1
        view.addSubview(container)
        context.coordinator.generation = generation
        if takesKeyboard { tab.browser?.controller?.focusWebView() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var generation = -1
    }
}

/// Draws the window's mounted pages (`BrowserModel.mountedWebTabs`: the selected one, the one you just left, a tab
/// the pointer rests on and the one Cmd-W would show), so switching to any of them is an opacity flip. Every other page is detached from the window, which lets WebKit
/// mark it hidden and throttle its timers, animations and video as Safari does for background tabs.
///
/// `addSubview` on a view that is already in this window still calls `viewDidMoveToWindow` and
/// `_removeLayerFromSuperlayer`. The layer is gone until that tab's process paints again, which is the
/// frozen second between two awake pages. `isHidden` does the same via `viewDidHide`. Opacity does neither, so the
/// mounted pages switch by opacity.
///
/// A page that was detached draws nothing until its process commits a frame after it is attached. Where WebKit has
/// `_doAfterNextPresentationUpdate:`, the page on screen stays opaque (and attached, even when it has left the
/// mounted set) until the new one has presented; without it the switch flips at once.
/// Media is left alone unless `resumeMediaOnSelect` is on.
struct MountedWebPages: NSViewRepresentable {
    var tabs: [Tab]
    var selectedID: UUID?
    /// Off unless `resumeMediaOnSelect` is set. On, the selected page's media resumes and every other page of the
    /// space stays paused, mounted or detached, until it is selected again; a page that sleeps, closes or leaves the
    /// space gets its media back.
    var resumeMediaOnSelect = false

    func makeNSView(context: Context) -> MountedWebHost {
        let view = MountedWebHost()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: MountedWebHost, context: Context) {
        let coordinator = context.coordinator
        let frontChanged = coordinator.front != selectedID
        coordinator.host = view
        coordinator.keep = Set(tabs.map { ObjectIdentifier($0.container) })
        let target = tabs.first { $0.id == selectedID }
        // The page drawn now, when it is about to be replaced by another.
        let outgoing = coordinator.shown.flatMap { $0.superview === view && $0 !== target?.container ? $0 : nil }
        let attached = target.map { $0.container.superview === view } ?? false
        let stillWaiting = attached && target != nil && coordinator.pendingID == target?.id
        // Not yet painted: just attached, or mounted ahead of a click (hover) that came before WebKit presented it.
        let painted = target.map { coordinator.hasPresented($0.container) } ?? true
        let startsWaiting = !stillWaiting && (!attached || !painted)
            && target?.webView?.responds(to: Coordinator.presentationSelector) == true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tab in tabs where tab.container.superview !== view {
            // Transparent until `apply` picks the front, so a page that has not presented never covers the old one.
            tab.container.alphaValue = 0
            tab.container.frame = view.bounds
            tab.container.autoresizingMask = [.width, .height]
            tab.container.isHidden = false
            view.addSubview(tab.container)
            coordinator.attached(tab)
        }
        CATransaction.commit()
        if let outgoing, let target, stillWaiting || startsWaiting {
            coordinator.apply(front: outgoing, retaining: outgoing)
            if startsWaiting { coordinator.wait(for: target) }
        } else {
            coordinator.cancelWait()
            coordinator.apply(front: target?.container)
            coordinator.shown = target?.container
            if frontChanged, let target { SwitchTrace.shown(target) }
        }
        view.front = target?.container
        updateMedia(coordinator)
        if frontChanged, let target { target.browser?.controller?.focusWebView() }
        coordinator.front = selectedID
    }

    private func updateMedia(_ coordinator: Coordinator) {
        if let browser = tabs.first?.browser { coordinator.browser = browser }
        let mounted = Set(tabs.map(\.id))
        for (id, page) in coordinator.media where !mounted.contains(id) {
            // Only detached, the page keeps its pause until it is selected again ("pauses the tab you left").
            // Asleep, closed, or moved to another space or window: a pause set here must not outlive its place here.
            let browser = coordinator.browser
            let gone = page.tab.webView == nil || page.tab.browser !== browser
                || browser?.tabs.contains(where: { $0 === page.tab }) != true
            guard gone else { continue }
            if page.suspended, !page.tab.isSuspendedInWebKit { page.tab.webView?.setAllMediaPlaybackSuspended(false, completionHandler: nil) }
            coordinator.media[id] = nil
        }
        if resumeMediaOnSelect {
            for tab in tabs {
                let suspend = tab.id != selectedID
                // A frozen page plays nothing and WebKit raises from the call; it is set once the page is live.
                guard coordinator.media[tab.id]?.suspended != suspend, !tab.isSuspendedInWebKit else { continue }
                tab.webView?.setAllMediaPlaybackSuspended(suspend, completionHandler: nil)
                coordinator.media[tab.id] = (tab, suspend)
            }
        } else {
            // The option was on and paused these. Release them so a page can play on its own again.
            for page in coordinator.media.values where page.suspended && !page.tab.isSuspendedInWebKit {
                page.tab.webView?.setAllMediaPlaybackSuspended(false, completionHandler: nil)
            }
            coordinator.media.removeAll()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        static let presentationSelector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        private static let log = Logger(subsystem: "com.walker.Paddle", category: "switch")
        /// How long the old page stays up when the new one never reports a presentation (a hung process, an
        /// occluded window); then the switch flips anyway, as it would without the private call.
        private static let presentationLimit: Duration = .milliseconds(300)

        var front: UUID?
        /// The page drawn opaque now.
        weak var shown: NSView?
        weak var host: MountedWebHost?
        /// The mounted containers as of the last update; `apply` detaches the rest.
        var keep: Set<ObjectIdentifier> = []
        /// The selected tab whose newly attached page has not presented yet.
        private(set) var pendingID: UUID?
        /// Bumped by every wait and cancel, so a callback from an earlier switch does nothing.
        private var generation = 0
        /// Containers WebKit has presented since they were last attached; a page in here shows at once.
        private var presented: Set<ObjectIdentifier> = []

        func hasPresented(_ container: NSView) -> Bool { presented.contains(ObjectIdentifier(container)) }

        /// `tab`'s container was just added to the host: it counts as painted once WebKit presents it.
        func attached(_ tab: Tab) {
            let key = ObjectIdentifier(tab.container)
            presented.remove(key)
            guard let webView = tab.webView, webView.responds(to: Self.presentationSelector) else {
                presented.insert(key)
                return
            }
            // WebKit raises "The WKWebView is suspended" from this call on a frozen page (a hovered or Cmd-W
            // successor tab can be frozen); it stays unpresented, and selecting it unfreezes it and waits then.
            if tab.isSuspendedInWebKit { Self.log.info("mounted a suspended page: presentation check deferred") }
            tab.whenLive {
                let done: @Sendable @convention(block) () -> Void = { [weak self, weak tab] in
                    MainActor.assumeIsolated {
                        guard let self, let tab, tab.container.superview === self.host else { return }
                        self.presented.insert(ObjectIdentifier(tab.container))
                    }
                }
                Self.afterNextPresentation(webView, done)
            }
        }

        /// `-[WKWebView _doAfterNextPresentationUpdate:]`. Only on a page that isn't suspended (`Tab.whenLive`).
        private static func afterNextPresentation(_ webView: WKWebView, _ block: @escaping @Sendable @convention(block) () -> Void) {
            typealias After = @convention(c) (WKWebView, Selector, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(webView.method(for: presentationSelector), to: After.self)(webView, presentationSelector, block)
        }
        /// Pages whose media this view set, and whether it holds it paused.
        var media: [UUID: (tab: Tab, suspended: Bool)] = [:]
        /// The window's tabs, for telling a page that is only detached from one that has left the window's space.
        weak var browser: BrowserModel?

        /// Makes `front` the one opaque page and detaches every container outside `keep` but `extra`.
        func apply(front: NSView?, retaining extra: NSView? = nil) {
            guard let host else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for subview in host.subviews {
                if keep.contains(ObjectIdentifier(subview)) || subview === extra {
                    // Opacity, not addSubview and not isHidden: both of those take the layer down.
                    subview.alphaValue = subview === front ? 1 : 0
                } else {
                    subview.isHidden = false
                    subview.alphaValue = 1
                    subview.removeFromSuperview()
                    presented.remove(ObjectIdentifier(subview))
                }
            }
            CATransaction.commit()
        }

        func cancelWait() {
            generation += 1
            pendingID = nil
        }

        /// Shows `tab`'s page once WebKit has presented it after attaching, or after `presentationLimit`.
        func wait(for tab: Tab) {
            guard let webView = tab.webView else { return }
            generation += 1
            let generation = generation
            pendingID = tab.id
            let presented: @Sendable @convention(block) () -> Void = { [weak self, weak tab] in
                MainActor.assumeIsolated {
                    guard let self, let tab, self.generation == generation else { return }
                    self.finishWait(tab)
                }
            }
            // A frozen page is asked nothing; `presentationLimit` flips the switch either way.
            tab.whenLive { Self.afterNextPresentation(webView, presented) }
            Task { [weak self, weak tab] in
                try? await Task.sleep(for: Self.presentationLimit)
                guard let self, let tab, self.generation == generation else { return }
                self.finishWait(tab)
            }
        }

        private func finishWait(_ tab: Tab) {
            cancelWait()
            guard let host, tab.container.superview === host else {
                // The page left this window meanwhile: drop the old page rather than keep it up.
                apply(front: nil)
                shown = nil
                return
            }
            apply(front: tab.container)
            shown = tab.container
            SwitchTrace.shown(tab)
        }
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
