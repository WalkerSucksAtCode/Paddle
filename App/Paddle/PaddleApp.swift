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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var started = false
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await AppModel.shared.start(openingURLs: [])
            started = true
            AppModel.shared.open(pendingURLs)
            pendingURLs = []
            NSApp.activate()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if started { AppModel.shared.open(urls) } else { pendingURLs += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops running downloads (Paddle doesn't resume them), so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        if !flag, AppModel.shared.windows.isEmpty { AppModel.shared.openWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.willTerminate()
    }

    // MARK: - App-level commands (work with no window open)

    @objc func paddleNewWindow(_ sender: Any?) { AppModel.shared.openWindow() }

    /// Reached only when no browser window is key: open a window instead of a tab.
    @objc func paddleNewTab(_ sender: Any?) { AppModel.shared.openWindow() }

    @objc func paddleOpenLocation(_ sender: Any?) { AppModel.shared.openWindow().model.focusAddress() }

    @objc func paddleOpenConfig(_ sender: Any?) { NSWorkspace.shared.open(Paths.config) }

    @objc func paddleOpenConfigFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.support) }

    @objc func paddleReloadConfig(_ sender: Any?) { Task { await AppModel.shared.reloadConfig() } }

    @objc func paddleSleepBackgroundTabs(_ sender: Any?) { AppModel.shared.sleepBackgroundTabs() }

    @objc func paddleShowHistory(_ sender: Any?) { HistoryWindowController.show() }

    @objc func paddleClearHistory(_ sender: Any?) { ClearHistoryPrompt.run(for: NSApp.keyWindow) }

    /// A recent page from the History menu.
    @objc func paddleOpenHistoryItem(_ sender: Any?) {
        guard let string = (sender as? NSMenuItem)?.representedObject as? String, let url = URL(string: string) else { return }
        AppModel.shared.openFromHistory(url, newTab: false)
    }

    @objc func paddleUpdateFilterLists(_ sender: Any?) {
        Task {
            let report = await AppModel.shared.web.updateFilterLists()
            let alert = NSAlert()
            alert.messageText = "Filter lists updated"
            alert.informativeText = report + "\n\n" + AppModel.shared.web.blockerStatus.joined(separator: "\n")
            alert.runModal()
        }
    }
}
