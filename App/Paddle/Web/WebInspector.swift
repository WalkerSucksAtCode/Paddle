import WebKit

/// Opens Web Inspector on a web view through WebKit's private `_inspector` (personal build). Every step is checked
/// with `responds(to:)`, so if the API goes away nothing happens and `isAvailable` says so.
enum WebInspector {
    private static let inspectorKey = "_inspector"
    private static let showSelector = NSSelectorFromString("show")
    private static let showConsoleSelector = NSSelectorFromString("showConsole")
    private static let toggleSelectionSelector = NSSelectorFromString("toggleElementSelection")
    private static let selectionActiveSelectors = [NSSelectorFromString("isElementSelectionActive"), NSSelectorFromString("elementSelectionActive")]
    private static let backgroundKey = "_backgroundWebView"

    static func isAvailable(for webView: WKWebView) -> Bool {
        inspector(of: webView) != nil
    }

    /// Whether WebKit's inspector class has `selector` at all (decided without a page, to hide a menu item).
    static func isAvailable(_ selector: Selector) -> Bool {
        NSClassFromString("_WKInspector")?.instancesRespond(to: selector) ?? false
    }

    /// Whether `WKWebExtensionContext` can hand out its background web view.
    static var canInspectBackgroundPages: Bool {
        WKWebExtensionContext.instancesRespond(to: NSSelectorFromString(backgroundKey))
    }

    /// True when the inspector was asked to show.
    @discardableResult
    static func show(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        inspector.perform(showSelector)
        return true
    }

    /// True when the inspector was asked to show with the JavaScript console selected.
    @discardableResult
    static func showConsole(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView, responding: showConsoleSelector) else { return false }
        inspector.perform(showConsoleSelector)
        return true
    }

    /// True when element selection was toggled (the inspector opens if it wasn't).
    @discardableResult
    static func toggleElementSelection(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView, responding: toggleSelectionSelector) else { return false }
        inspector.perform(toggleSelectionSelector)
        return true
    }

    /// Whether element selection is on now; false when the inspector can't say.
    static func isElementSelectionActive(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView), selectionActiveSelectors.contains(where: inspector.responds(to:)),
              let active = inspector.value(forKey: "elementSelectionActive") as? Bool else { return false }
        return active
    }

    /// Shows the inspector of the extension's background page, starting the background first if it isn't running.
    /// True when the request was made (the background may still be loading); false when the API is missing.
    @discardableResult
    static func inspectBackgroundPage(of context: WKWebExtensionContext) -> Bool {
        guard context.responds(to: NSSelectorFromString(backgroundKey)) else { return false }
        func background() -> WKWebView? { context.value(forKey: backgroundKey) as? WKWebView }
        if let view = background() { return show(view) }
        Task {
            try? await context.loadBackgroundContent()
            if let view = background() { show(view) }
        }
        return true
    }

    private static func inspector(of webView: WKWebView, responding selector: Selector? = nil) -> NSObject? {
        guard webView.responds(to: NSSelectorFromString(inspectorKey)),
              let inspector = webView.value(forKey: inspectorKey) as? NSObject,
              inspector.responds(to: showSelector),
              selector.map(inspector.responds(to:)) ?? true else { return nil }
        return inspector
    }
}
