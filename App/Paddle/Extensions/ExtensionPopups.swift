import AppKit
import os
import PaddleCore
import WebKit

/// Shows an extension's popup: WebKit's own `NSPopover` for the action (it holds the popup web view and sizes
/// itself to the page), anchored to that extension's toolbar button. One popup is on screen at a time. The popover
/// window is made key with the popup web view as first responder, so its fields take typing and the Edit menu's
/// cut, copy and paste reach it through the responder chain.
///
/// A popup shows only for a user action: Paddle's own button, menu item or key command for that extension (noted
/// by `noteUserAction` just before `performAction`), or a gesture WebKit saw in the action's tab. An extension's
/// `action.openPopup()` from a timer is refused, so it can't take the keyboard from the page or close another
/// extension's popup.
final class ExtensionPopupPresenter {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")
    /// How long a Paddle user action counts for the popup request it starts.
    private static let userActionWindow: TimeInterval = 1
    /// A button click this soon after its popup closed is the click that closed it (the transient popover closes on
    /// mouse-down; the button fires on mouse-up).
    private static let reopenGuard: TimeInterval = 0.5

    /// The popover on screen, if any. WebKit owns it; this is for closing it before another shows, and for the
    /// runtime permission prompt, which keeps it open while the alert is up.
    private(set) weak var shownPopover: NSPopover?
    /// The action and context `shownPopover` belongs to. The action is the tab's own (`action(for: tab)`), not the
    /// default one, when the popup was opened for a tab.
    private weak var shownAction: WKWebExtension.Action?
    private var shownContextID: String?
    /// Context id of Paddle's last user action and when it stops counting; a nil id (a key command) covers any.
    private var userAction: (contextID: String?, until: Date)?
    /// Context id of the popup that closed last, and when.
    private var lastClose: (contextID: String, at: Date)?
    /// Installed on a popup web view only when WebKit left that delegate unset.
    private let fallbackDelegate = ExtensionPopupWebDelegate()

    private var closeObserver: (any NSObjectProtocol)?
    /// The toolbar button that was just clicked, so its popup anchors there and not on another copy of the button.
    private weak var clickedButton: NSView?
    private var clickedContextID: String?
    /// Keeps the shown popup inside `maxSize`; WebKit sizes it to the page, which can be any width.
    private var sizeObservation: NSKeyValueObservation?
    private static let maxSize = NSSize(width: 800, height: 600)

    init() {
        closeObserver = NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue (`queue: .main`).
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated { self?.popoverWillClose(object as? NSPopover) }
        }
    }

    /// The toolbar button calls this before running its action, so the popup that follows anchors to it.
    func noteClick(from button: NSView, for context: WKWebExtensionContext) {
        clickedButton = button
        clickedContextID = context.uniqueIdentifier
    }

    /// Called just before Paddle runs an extension's action or a key command: the popup that follows is the user's.
    /// `context` nil: a key command, which can belong to any extension.
    func noteUserAction(for context: WKWebExtensionContext?) {
        userAction = (context?.uniqueIdentifier, Date().addingTimeInterval(Self.userActionWindow))
    }

    /// The toolbar button's click as a toggle: true when this extension's popup is open (it is closed now) or closed
    /// a moment ago by the mouse-down of this same click, so the caller must not open it again.
    func closeForToggle(_ context: WKWebExtensionContext) -> Bool {
        let id = context.uniqueIdentifier
        if shownContextID == id, let shownPopover, shownPopover.isShown {
            shownPopover.performClose(nil)
            return true
        }
        if let lastClose, lastClose.contextID == id, Date().timeIntervalSince(lastClose.at) < Self.reopenGuard { return true }
        return false
    }

    /// Closes the popup on screen if it belongs to `context` (unloading it): through the action WebKit showed it
    /// for, then the popover itself in case WebKit no longer tracks it.
    func close(for context: WKWebExtensionContext) {
        guard shownContextID == context.uniqueIdentifier else { return }
        shownAction?.closePopup()
        if let shownPopover, shownPopover.isShown { shownPopover.close() }
        shownPopover = nil
        shownAction = nil
        shownContextID = nil
    }

    private func popoverWillClose(_ popover: NSPopover?) {
        guard let popover, popover === shownPopover, let id = shownContextID else { return }
        lastClose = (id, Date())
        sizeObservation = nil
    }

    /// Consumes Paddle's user action if it covers `context`.
    private func takeUserAction(for context: WKWebExtensionContext) -> Bool {
        guard let userAction, userAction.until > Date(),
              userAction.contextID == nil || userAction.contextID == context.uniqueIdentifier else { return false }
        self.userAction = nil
        return true
    }

    /// `presentActionPopup`: shows `action.popupPopover` at the extension's toolbar button in the window of the
    /// action's tab (else the front window), or below the toolbar at the window's right edge when the button isn't
    /// on screen (another window's tab, a window too narrow to show it, or a button SwiftUI hasn't added yet).
    func present(_ action: WKWebExtension.Action, for context: WKWebExtensionContext) throws {
        // Checked before `popupPopover` is read: reading it creates the popup web view.
        let gesture = takeUserAction(for: context) || action.associatedTab.map { context.hasActiveUserGesture(in: $0) } == true
        guard gesture else {
            log.notice("popup for \(context.uniqueIdentifier, privacy: .public) refused: no user action (action.openPopup() without a click)")
            throw PaddleExtensionError.noUserAction
        }
        guard action.presentsPopup, let popover = action.popupPopover else { throw PaddleExtensionError.noPopup }
        let controller = (action.associatedTab as? ExtensionTab)?.tab?.browser?.controller ?? AppModel.shared.frontWindow
        guard let window = controller?.window, let contentView = window.contentView else { throw PaddleExtensionError.noWindow }

        if let shownPopover, shownPopover !== popover, shownPopover.isShown {
            shownPopover.performClose(nil)
        }
        prepare(action, for: context)

        if !popover.isShown {
            // Click-outside closes it; Escape reaches the popover through the responder chain when the page itself
            // doesn't handle it.
            popover.behavior = .transient
            if let anchor = anchorButton(for: context, in: window, contentView: contentView) {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: Self.belowEdge(of: anchor))
            } else {
                // 76 pt down from the top: under the tab strip and the navigation bar. The content view is a
                // flipped NSHostingView, so "down from the top" depends on the orientation.
                let bounds = contentView.bounds
                let y = contentView.isFlipped ? bounds.minY + 76 : bounds.maxY - 76
                let rect = NSRect(x: bounds.maxX - 40, y: y, width: 1, height: 1)
                popover.show(relativeTo: rect, of: contentView, preferredEdge: Self.belowEdge(of: contentView))
                log.notice("popup for \(context.uniqueIdentifier, privacy: .public): toolbar button not on screen, anchored under the toolbar at the right edge")
            }
        }
        clickedButton = nil
        clickedContextID = nil
        clamp(popover)
        if let controller = popover.contentViewController {
            sizeObservation = controller.observe(\.preferredContentSize) { [weak popover] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { popover.map(Self.clampSize) } }
            }
        }
        shownPopover = popover
        shownAction = action
        shownContextID = context.uniqueIdentifier
        focus(popover, webView: action.popupWebView)
    }

    /// The button just clicked for this extension, else a visible copy of its button in `window`. SwiftUI can keep an
    /// old copy of the button around (after Reload Extensions), so the first match by identifier isn't enough.
    private func anchorButton(for context: WKWebExtensionContext, in window: NSWindow, contentView: NSView) -> NSView? {
        if clickedContextID == context.uniqueIdentifier, let clickedButton, clickedButton.window === window,
           !clickedButton.isHiddenOrHasHiddenAncestor, !clickedButton.visibleRect.isEmpty {
            return clickedButton
        }
        let identifier = ExtensionActionNSButton.identifier(for: context.uniqueIdentifier)
        return contentView.descendants(withIdentifier: identifier).last {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
    }

    private func clamp(_ popover: NSPopover) { Self.clampSize(popover) }

    private static func clampSize(_ popover: NSPopover) {
        let size = popover.contentSize
        let clamped = NSSize(width: min(size.width, maxSize.width), height: min(size.height, maxSize.height))
        guard clamped != size, clamped.width > 0, clamped.height > 0 else { return }
        popover.contentSize = clamped
    }

    /// The edge that puts a popover below its anchor rect. The edge is in the view's own coordinates (measured:
    /// in a flipped view `.minY` opens it above), and NSButton and NSHostingView are both flipped.
    private static func belowEdge(of view: NSView) -> NSRectEdge {
        view.isFlipped ? .maxY : .minY
    }

    /// Inspectability and the delegates that open the popup's links as tabs.
    private func prepare(_ action: WKWebExtension.Action, for context: WKWebExtensionContext) {
        guard let webView = action.popupWebView else { return }
        webView.isInspectable = AppModel.shared.config.developerTools
        if action.inspectionName == nil, let name = context.inspectionName { action.inspectionName = "\(name) popup" }
        // WebKit normally installs its own delegates on the popup web view (links and target=_blank go through
        // the controller delegate's openNewTab). Paddle's fallback covers a build that leaves them unset.
        if webView.uiDelegate == nil {
            webView.uiDelegate = fallbackDelegate
            log.notice("popup web view had no UI delegate; Paddle's fallback opens its new windows as tabs")
        }
        if webView.navigationDelegate == nil {
            webView.navigationDelegate = fallbackDelegate
            log.notice("popup web view had no navigation delegate; Paddle's fallback opens its web links as tabs")
        }
    }

    /// The popover's window becomes key and the web view first responder, so typing goes to the popup at once.
    private func focus(_ popover: NSPopover, webView: WKWebView?) {
        guard let popupWindow = popover.contentViewController?.view.window ?? webView?.window else { return }
        if !popupWindow.isKeyWindow { popupWindow.makeKey() }
        if let webView, popupWindow.firstResponder !== webView { popupWindow.makeFirstResponder(webView) }
    }
}

/// Fallback delegates for a popup web view: a web link in the popup opens as a selected tab in the front window
/// and the popup stays on its own page; `window.open` and `target=_blank` do the same.
final class ExtensionPopupWebDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
    private static func isWebPage(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func openAsTab(_ url: URL) {
        guard let front = AppModel.shared.frontWindow else {
            AppModel.shared.openWindow(url: url)
            return
        }
        front.model.newTab(url: url, select: true)
        front.window?.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url, Self.isWebPage(url) else { return .allow }
        openAsTab(url)
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isWebPage(url) { openAsTab(url) }
        return nil
    }
}

extension NSView {
    /// Every view in this subtree with `identifier`, depth first.
    func descendants(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> [NSView] {
        var found = self.identifier == identifier ? [self] : []
        for subview in subviews { found += subview.descendants(withIdentifier: identifier) }
        return found
    }
}
