import AppKit
import os
import PaddleCore
import WebKit

/// Answers WebKit's questions about windows and tabs, opens what extensions ask to open, and routes permission
/// prompts to the host. One per profile's host: an extension sees only that profile's windows, and what it opens
/// opens in that profile. Every protocol method is optional, so a misnamed one compiles and is silently never
/// called: `verifySelectors()` checks the ObjC selectors in DEBUG builds.
final class ExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    private var app: AppModel { AppModel.shared }
    /// The host that owns this delegate's controller; nil once a deleted profile's host is gone.
    weak var host: ExtensionHost?

    // MARK: - Windows and tabs

    /// Front window first, then the others in screen order. Only the windows this extension may see.
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let host else { return [] }
        var ordered: [BrowserWindowController] = []
        if let front = app.frontWindow { ordered.append(front) }
        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? BrowserWindowController, !ordered.contains(where: { $0 === controller }) else { continue }
            ordered.append(controller)
        }
        for controller in app.windows where !ordered.contains(where: { $0 === controller }) { ordered.append(controller) }
        return ordered.filter { host.isVisible($0, to: extensionContext) }.map(\.extensionWindow)
    }

    /// Always the front browser window, even while Paddle is inactive: Chrome's "last focused" window.
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let front = app.frontExtensionWindow(for: extensionContext) else { return nil }
        return front.extensionWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        guard let host else { throw PaddleExtensionError.noWindow }
        if let url = configuration.url { try PaddleExtensionError.checkOpenable(url, for: extensionContext) }
        let url = configuration.url ?? app.newTabPageURL(for: host.profileID)
        let target = (configuration.window as? ExtensionWindow)?.controller ?? app.frontExtensionWindow(for: extensionContext)
        guard let target else {
            let window = app.openWindow(url: url, profile: host.profileID)
            return window.model.selectedTab?.extensionTab
        }
        let model = target.model
        let parent = (configuration.parentTab as? ExtensionTab)?.tab
        let tab = model.newTab(url: url, select: configuration.shouldBeActive, after: parent)
        if configuration.index != NSNotFound, configuration.index != model.allTabs.firstIndex(where: { $0 === tab }) {
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
        guard let host else { throw PaddleExtensionError.noWindow }
        // Private windows run the default profile's extensions only.
        guard !configuration.shouldBePrivate || (host.isDefaultProfile && extensionContext.hasAccessToPrivateData) else { throw PaddleExtensionError.privateNotAllowed }
        // `tabId`: those tabs move into the new window. WebKit only looks the tabs up, so their kind is checked here.
        let moving = configuration.tabs.compactMap { ($0 as? ExtensionTab)?.tab }
        guard moving.count == configuration.tabs.count else { throw PaddleExtensionError.tabNotFound }
        guard moving.allSatisfy({ $0.isPrivate == configuration.shouldBePrivate }) else { throw PaddleExtensionError.privacyMismatch }
        let urls = configuration.tabURLs
        for url in urls { try PaddleExtensionError.checkOpenable(url, for: extensionContext) }
        let window = moving.isEmpty
            ? app.openWindow(url: urls.first ?? app.newTabPageURL(for: host.profileID), isPrivate: configuration.shouldBePrivate, profile: host.profileID)
            : app.openWindow(isPrivate: configuration.shouldBePrivate, moving: moving)
        for url in moving.isEmpty ? Array(urls.dropFirst()) : urls { window.model.newTab(url: url, select: false) }
        let frame = configuration.frame
        if !frame.isNull, frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite {
            window.window?.setFrame(frame, display: true)
        }
        return window.extensionWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        try host?.openOptionsPage(for: extensionContext)
    }

    /// `tabs.move`, within a window or into another. Private WebKit API (in macOS 27's WebKit); without it WebKit
    /// answers every `tabs.move` with "it is not implemented". WebKit has already checked that the tabs and the
    /// destination are normal windows of the same privacy, and turned index -1 into the end.
    @objc(_webExtensionController:moveTabs:toIndex:inWindow:forExtensionContext:completionHandler:)
    func webExtensionController(
        _ controller: WKWebExtensionController, moveTabs tabs: [any WKWebExtensionTab], toIndex index: Int,
        inWindow window: any WKWebExtensionWindow, forExtensionContext extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (NSError?) -> Void
    ) {
        let moving = tabs.compactMap { ($0 as? ExtensionTab)?.tab }
        guard let target = (window as? ExtensionWindow)?.controller else {
            completionHandler(PaddleExtensionError.noWindow as NSError)
            return
        }
        guard moving.count == tabs.count else {
            completionHandler(PaddleExtensionError.tabNotFound as NSError)
            return
        }
        for (offset, tab) in moving.enumerated() { app.move(tab, to: target, at: index + offset) }
        completionHandler(nil)
    }

    // MARK: - Permissions

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.Permission>, Date?) {
        guard let host else { return ([], nil) }
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
        // `tabs.query` and CORS failures come with no tab; the host answers those without an alert.
        guard let host else { return ([], nil) }
        return (await host.promptForURLs(urls, in: tab as? ExtensionTab, for: extensionContext), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        guard let host else { return ([], nil) }
        let byString = Dictionary(matchPatterns.map { ($0.string, $0) }, uniquingKeysWith: { first, _ in first })
        let allSites = Set(matchPatterns.filter { $0.matchesAllHosts || $0.matchesAllURLs }.map(\.string))
        let granted = await host.promptAtRuntime(
            permissions: [], hosts: Set(byString.keys), allSites: allSites, in: tab as? ExtensionTab, for: extensionContext
        )
        return (Set(granted.hosts.compactMap { byString[$0] }), nil)
    }

    // MARK: - Actions

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        host?.actionUpdated(action, for: context)
    }

    /// A click on the button, or the extension's `action.openPopup()`: WebKit's popover at the toolbar button.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        guard let host else { throw PaddleExtensionError.noWindow }
        do {
            try host.popups.present(action, for: context)
            host.noteUserAction(on: context, showingPopup: true)
        } catch {
            log.error("popup for \(context.uniqueIdentifier, privacy: .public) not shown: \(error.localizedDescription, privacy: .public)")
            action.closePopup()
            throw error
        }
    }

    // MARK: - Native messaging: Paddle's own bus only

    /// Only `ExtensionCompat.busID`, answered by `CompatBus`; any other id gets Chrome's "not found" error.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        guard let host else { throw PaddleExtensionError.noWindow }
        return try await host.bus.handle(
            message, applicationID: applicationIdentifier, context: extensionContext,
            extension: host.loaded.first { $0.context === extensionContext }
        )
    }

    /// The same id check on the port path, from `port.applicationIdentifier` (nil is refused).
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        guard let host else { throw PaddleExtensionError.noWindow }
        try host.bus.connect(port, context: extensionContext, extension: host.loaded.first { $0.context === extensionContext })
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
            "_webExtensionController:moveTabs:toIndex:inWindow:forExtensionContext:completionHandler:",
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
