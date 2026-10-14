import AppKit

@main
enum PaddleMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var started = false
    private var pendingURLs: [URL] = []

    /// Another Paddle with this bundle id that was already running (a second copy of the app, such as a development
    /// build next to the installed one). Two copies would share Application Support: each one's start-up tidy-up
    /// deletes block lists the other is compiling (so the next launch recompiles them for 20-30 s), and both write the
    /// session, history and config. This one hands its links to the running copy and quits before touching any of it.
    private var runningCopy: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        runningCopy = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != getpid() && !$0.isTerminated }
        guard runningCopy == nil else { return }
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let runningCopy {
            // Links that launched this copy arrive just before or after this call; give them a moment, then pass them on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                if !pendingURLs.isEmpty, let app = runningCopy.bundleURL {
                    NSWorkspace.shared.open(pendingURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
                runningCopy.activate()
                NSApp.terminate(nil)
            }
            return
        }
        // Before the first window: a notification click can launch Paddle, and macOS only delivers it to a delegate
        // that is already set.
        WebsiteNotifications.shared.install(on: AppModel.shared.web.dataStore)
        Task {
            await AppModel.shared.start(openingURLs: [])
            started = true
            AppModel.shared.open(pendingURLs)
            pendingURLs = []
            NSApp.activate()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if started, runningCopy == nil { AppModel.shared.open(urls) } else { pendingURLs += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Extensions see the front browser window as focused while Paddle is active, and no window otherwise.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard runningCopy == nil else { return }
        AppModel.shared.extensions.windowFocused(AppModel.shared.frontWindow)
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard runningCopy == nil else { return }
        AppModel.shared.extensions.windowFocused(nil)
    }

    /// Quitting stops running downloads (Paddle doesn't resume them), so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runningCopy == nil else { return .terminateNow }
        let running = AppModel.shared.downloads.activeCount
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A download is still in progress" : "\(running) downloads are still in progress"
        alert.informativeText = running == 1 ? "Quitting Paddle cancels it." : "Quitting Paddle cancels them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Don't Quit")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard runningCopy == nil else { return false }
        if !flag, AppModel.shared.windows.isEmpty { AppModel.shared.openWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A second copy never loaded the session; saving here would write an empty one over the running copy's.
        guard runningCopy == nil else { return }
        AppModel.shared.willTerminate()
    }

    // MARK: - App-level commands (work with no window open)

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paddleToggleBookmarksBar(_:)) {
            menuItem.title = AppModel.shared.showBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar"
        }
        if menuItem.action == #selector(paddleMakeDefaultBrowser(_:)) {
            let isDefault = DefaultBrowser.isDefault
            menuItem.title = isDefault ? "Paddle Is the Default Browser" : "Make Paddle the Default Browser…"
            return !isDefault
        }
        return true
    }

    @objc func paddleNewWindow(_ sender: Any?) { AppModel.shared.openWindow() }

    @objc func paddleNewPrivateWindow(_ sender: Any?) { AppModel.shared.openWindow(isPrivate: true) }

    /// Reached only when no browser window is key: open a window instead of a tab.
    @objc func paddleNewTab(_ sender: Any?) { AppModel.shared.openWindow() }

    @objc func paddleOpenLocation(_ sender: Any?) { AppModel.shared.openWindow().model.focusAddress() }

    @objc func paddleShowSettings(_ sender: Any?) { AppModel.shared.showSettings() }

    @objc func paddleOpenConfigFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.support) }

    @objc func paddleReloadConfig(_ sender: Any?) { Task { await AppModel.shared.reloadConfig() } }

    @objc func paddleSleepBackgroundTabs(_ sender: Any?) { AppModel.shared.sleepBackgroundTabs() }

    @objc func paddleOpenExtensionsFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.extensions) }

    @objc func paddleInstallExtensionFromLink(_ sender: Any?) { InstallFromLinkPanel.show(over: NSApp.mainWindow) }

    @objc func paddleCheckExtensionUpdates(_ sender: Any?) { Task { await ExtensionUpdater.shared.checkAll() } }

    @objc func paddleReloadExtensions(_ sender: Any?) { Task { await AppModel.shared.reloadExtensions() } }

    @objc func paddleShowHistory(_ sender: Any?) { HistoryWindowController.show() }

    @objc func paddleClearHistory(_ sender: Any?) { ClearHistoryPrompt.run(for: NSApp.keyWindow) }

    @objc func paddleShowBookmarks(_ sender: Any?) { BookmarksWindowController.show() }

    @objc func paddleToggleBookmarksBar(_ sender: Any?) { AppModel.shared.showBookmarksBar.toggle() }

    @objc func paddleImportBookmarks(_ sender: Any?) { BookmarkFiles.importFile() }

    @objc func paddleImportFromBrowser(_ sender: Any?) { BrowserImportController.show() }

    @objc func paddleExportBookmarks(_ sender: Any?) { BookmarkFiles.exportFile() }

    /// A bookmark from the Bookmarks menu; Command opens it in a background tab.
    @objc func paddleOpenBookmarkItem(_ sender: Any?) {
        guard let string = (sender as? NSMenuItem)?.representedObject as? String, let url = URL(string: string) else { return }
        AppModel.shared.openInFrontWindow(url, newTab: NSEvent.modifierFlags.contains(.command))
    }

    /// A recent page from the History menu.
    @objc func paddleOpenHistoryItem(_ sender: Any?) {
        guard let string = (sender as? NSMenuItem)?.representedObject as? String, let url = URL(string: string) else { return }
        AppModel.shared.openInFrontWindow(url, newTab: false)
    }

    @objc func paddleUpdateFilterLists(_ sender: Any?) {
        Task {
            let report = await AppModel.shared.web.updateFilterLists()
            let alert = NSAlert()
            if report.failures > 0 {
                alert.alertStyle = .warning
                alert.messageText = report.failures == 1
                    ? "A filter list couldn't be updated" : "\(report.failures) filter lists couldn't be updated"
            } else {
                alert.messageText = report.skipped ? "Filter lists are already updating" : "Filter lists updated"
            }
            alert.informativeText = report.text + "\n\n" + AppModel.shared.web.blockerStatus.joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc func paddleMakeDefaultBrowser(_ sender: Any?) { DefaultBrowser.make() }
}
