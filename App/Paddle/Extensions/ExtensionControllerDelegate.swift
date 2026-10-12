import AppKit
import os
import PaddleCore
import WebKit

/// Answers WebKit's questions about windows and tabs, opens what extensions ask to open, and routes permission
/// prompts to the host. Every protocol method is optional, so a misnamed one compiles and is silently never
/// called: `verifySelectors()` checks the ObjC selectors in DEBUG builds.
final class ExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    private var app: AppModel { AppModel.shared }
    private var host: ExtensionHost { AppModel.shared.extensions }

    // MARK: - Windows and tabs

    /// Front window first, then the others in screen order.
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        var ordered: [BrowserWindowController] = []
        if let front = app.frontWindow { ordered.append(front) }
        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? BrowserWindowController, !ordered.contains(where: { $0 === controller }) else { continue }
            ordered.append(controller)
        }
        for controller in app.windows where !ordered.contains(where: { $0 === controller }) { ordered.append(controller) }
        return host.registered(ordered).map(\.extensionWindow)
    }

    /// Always the front browser window, even while Paddle is inactive: Chrome's "last focused" window.
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let front = app.frontWindow, host.isRegistered(front) else { return nil }
        return front.extensionWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        if let url = configuration.url { try PaddleExtensionError.checkOpenable(url, for: extensionContext) }
        let url = configuration.url ?? app.newTabPageURL
        let target = (configuration.window as? ExtensionWindow)?.controller ?? app.frontWindow
        guard let target else {
            let window = app.openWindow(url: url)
            return window.model.selectedTab?.extensionTab
        }
        let model = target.model
        let parent = (configuration.parentTab as? ExtensionTab)?.tab
        let tab = model.newTab(url: url, select: configuration.shouldBeActive, after: parent)
        if configuration.index != NSNotFound, configuration.index != model.tabs.firstIndex(where: { $0 === tab }) {
            model.place(tab, at: configuration.index)
        }
        if configuration.shouldBePinned != tab.isPinned { model.togglePin(tab) }
        return tab.extensionTab
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionWindow)? {
        guard !configuration.shouldBePrivate else { throw PaddleExtensionError.unsupported("Private windows") }
        if !configuration.tabs.isEmpty {
            log.notice("windows.create with existing tabs: moving tabs between windows is not supported; opening a new window instead")
        }
        let urls = configuration.tabURLs
        for url in urls { try PaddleExtensionError.checkOpenable(url, for: extensionContext) }
        let window = app.openWindow(url: urls.first ?? app.newTabPageURL)
        for url in urls.dropFirst() { window.model.newTab(url: url, select: false) }
        let frame = configuration.frame
        if !frame.isNull, frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite {
            window.window?.setFrame(frame, display: true)
        }
        return window.extensionWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { throw PaddleExtensionError.noOptions }
        for window in app.windows {
            if let tab = window.model.tabs.first(where: { $0.url == url }) {
                window.model.select(tab)
                window.window?.makeKeyAndOrderFront(nil)
                return
            }
        }
        guard let front = app.frontWindow else {
            app.openWindow(url: url)
            return
        }
        front.model.newTab(url: url, select: true)
        front.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Permissions

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.Permission>, Date?) {
        let granted = await host.promptAtRuntime(
            permissions: Set(permissions.map(\.rawValue)), hosts: [], in: tab as? ExtensionTab, for: extensionContext
        )
        return (Set(granted.permissions.map { WKWebExtension.Permission(rawValue: $0) }), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<URL>, Date?) {
        let byString = Dictionary(urls.map { ($0.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        let granted = await host.promptAtRuntime(
            permissions: [], hosts: Set(byString.keys), in: tab as? ExtensionTab, for: extensionContext
        )
        return (Set(granted.hosts.compactMap { byString[$0] }), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let byString = Dictionary(matchPatterns.map { ($0.string, $0) }, uniquingKeysWith: { first, _ in first })
        let allSites = Set(matchPatterns.filter { $0.matchesAllHosts || $0.matchesAllURLs }.map(\.string))
        let granted = await host.promptAtRuntime(
            permissions: [], hosts: Set(byString.keys), allSites: allSites, in: tab as? ExtensionTab, for: extensionContext
        )
        return (Set(granted.hosts.compactMap { byString[$0] }), nil)
    }

    // MARK: - Actions

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        host.actionUpdated()
    }

    /// The toolbar button and popover arrive with the next sub-wave; until then a popup request is logged and
    /// closed so the popup web view doesn't linger.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        log.notice("popup requested by \(context.uniqueIdentifier, privacy: .public): no toolbar yet, closing it")
        action.closePopup()
        throw PaddleExtensionError.noPopup
    }

    // MARK: - Native messaging: never

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        throw PaddleExtensionError.unsupported("Native messaging")
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        throw PaddleExtensionError.unsupported("Native messaging")
    }

    // MARK: - DEBUG selector check

    #if DEBUG
    /// Every delegate and adapter method is `@optional` in ObjC, so a near-miss Swift name compiles and is never
    /// called. This asserts that each implementation answers to the selector WebKit will send.
    func verifySelectors() {
        let delegateSelectors = [
            "webExtensionController:openWindowsForExtensionContext:",
            "webExtensionController:focusedWindowForExtensionContext:",
            "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:",
            "webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:",
            "webExtensionController:openOptionsPageForExtensionContext:completionHandler:",
            "webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:",
            "webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:",
            "webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:",
            "webExtensionController:didUpdateAction:forExtensionContext:",
            "webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:",
            "webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:",
            "webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:",
        ]
        let tabSelectors = [
            "windowForWebExtensionContext:",
            "indexInWindowForWebExtensionContext:",
            "parentTabForWebExtensionContext:",
            "setParentTab:forWebExtensionContext:completionHandler:",
            "webViewForWebExtensionContext:",
            "titleForWebExtensionContext:",
            "urlForWebExtensionContext:",
            "isLoadingCompleteForWebExtensionContext:",
            "isPinnedForWebExtensionContext:",
            "setPinned:forWebExtensionContext:completionHandler:",
            "sizeForWebExtensionContext:",
            "zoomFactorForWebExtensionContext:",
            "setZoomFactor:forWebExtensionContext:completionHandler:",
            "loadURL:forWebExtensionContext:completionHandler:",
            "reloadFromOrigin:forWebExtensionContext:completionHandler:",
            "goBackForWebExtensionContext:completionHandler:",
            "goForwardForWebExtensionContext:completionHandler:",
            "activateForWebExtensionContext:completionHandler:",
            "isSelectedForWebExtensionContext:",
            "setSelected:forWebExtensionContext:completionHandler:",
            "duplicateUsingConfiguration:forWebExtensionContext:completionHandler:",
            "closeForWebExtensionContext:completionHandler:",
            "takeSnapshotUsingConfiguration:forWebExtensionContext:completionHandler:",
            "shouldGrantPermissionsOnUserGestureForWebExtensionContext:",
        ]
        let windowSelectors = [
            "tabsForWebExtensionContext:",
            "activeTabForWebExtensionContext:",
            "windowTypeForWebExtensionContext:",
            "windowStateForWebExtensionContext:",
            "setWindowState:forWebExtensionContext:completionHandler:",
            "isPrivateForWebExtensionContext:",
            "screenFrameForWebExtensionContext:",
            "frameForWebExtensionContext:",
            "setFrame:forWebExtensionContext:completionHandler:",
            "focusForWebExtensionContext:completionHandler:",
            "closeForWebExtensionContext:completionHandler:",
        ]
        var missing: [String] = []
        for selector in delegateSelectors where !responds(to: NSSelectorFromString(selector)) { missing.append("delegate \(selector)") }
        let tab = ExtensionTab(tab: nil)
        for selector in tabSelectors where !tab.responds(to: NSSelectorFromString(selector)) { missing.append("tab \(selector)") }
        let window = ExtensionWindow(controller: nil)
        for selector in windowSelectors where !window.responds(to: NSSelectorFromString(selector)) { missing.append("window \(selector)") }
        if missing.isEmpty {
            log.info("selector check passed: \(delegateSelectors.count + tabSelectors.count + windowSelectors.count) selectors")
        } else {
            log.fault("selector check FAILED: \(missing.joined(separator: ", "), privacy: .public)")
            assertionFailure("WebExtension selector check failed: \(missing)")
        }
    }
    #endif
}
