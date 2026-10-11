import AppKit
import os
import PaddleCore

/// The menu bar. Every command has an action name (in brackets in README) that config.json's
/// `shortcuts` can rebind, e.g. `"shortcuts": { "nextTab": "cmd+option+right" }`.
enum MainMenu {
    private static var itemsByName: [String: NSMenuItem] = [:]
    private static var defaultShortcuts: [String: (String, NSEvent.ModifierFlags)] = [:]
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "menu")

    static var actionNames: [String] { itemsByName.keys.sorted() }

    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Paddle")
        app.addItem(withTitle: "About Paddle", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, "settings", "Settings (config.json)…", #selector(AppDelegate.paddleOpenConfig(_:)), ",", target: appDelegate)
        add(app, "openConfigFolder", "Open Config Folder", #selector(AppDelegate.paddleOpenConfigFolder(_:)), "", target: appDelegate)
        add(app, "reloadConfig", "Reload Config", #selector(AppDelegate.paddleReloadConfig(_:)), ",", [.command, .option], target: appDelegate)
        add(app, "updateFilterLists", "Update Filter Lists", #selector(AppDelegate.paddleUpdateFilterLists(_:)), "", target: appDelegate)
        app.addItem(.separator())
        add(app, "hide", "Hide Paddle", #selector(NSApplication.hide(_:)), "h")
        add(app, "hideOthers", "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, "quit", "Quit Paddle", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, "File")
        add(file, "newTab", "New Tab", #selector(BrowserWindowController.paddleNewTab(_:)), "t")
        add(file, "newWindow", "New Window", #selector(AppDelegate.paddleNewWindow(_:)), "n", target: appDelegate)
        add(file, "openLocation", "Open Location…", #selector(BrowserWindowController.paddleOpenLocation(_:)), "l")
        file.addItem(.separator())
        add(file, "closeTab", "Close Tab", #selector(BrowserWindowController.paddleCloseTab(_:)), "w")
        add(file, "closeWindow", "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(file, "reopenClosedTab", "Reopen Closed Tab", #selector(BrowserWindowController.paddleReopenClosedTab(_:)), "t", [.command, .shift])

        let edit = submenu(main, "Edit")
        add(edit, "undo", "Undo", Selector(("undo:")), "z")
        add(edit, "redo", "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "cut", "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "copy", "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "paste", "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "pasteAndMatchStyle", "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(edit, "selectAll", "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "find", "Find…", #selector(BrowserWindowController.paddleFind(_:)), "f")
        add(edit, "findNext", "Find Next", #selector(BrowserWindowController.paddleFindNext(_:)), "g")
        add(edit, "findPrevious", "Find Previous", #selector(BrowserWindowController.paddleFindPrevious(_:)), "g", [.command, .shift])

        let view = submenu(main, "View")
        add(view, "reload", "Reload Page", #selector(BrowserWindowController.paddleReload(_:)), "r")
        add(view, "hardReload", "Reload Without Cache", #selector(BrowserWindowController.paddleHardReload(_:)), "r", [.command, .option])
        add(view, "stop", "Stop", #selector(BrowserWindowController.paddleStop(_:)), ".")
        view.addItem(.separator())
        add(view, "zoomIn", "Zoom In", #selector(BrowserWindowController.paddleZoomIn(_:)), "+")
        hidden(view, "Zoom In", #selector(BrowserWindowController.paddleZoomIn(_:)), "=")
        add(view, "zoomOut", "Zoom Out", #selector(BrowserWindowController.paddleZoomOut(_:)), "-")
        add(view, "actualSize", "Actual Size", #selector(BrowserWindowController.paddleActualSize(_:)), "0")
        view.addItem(.separator())
        add(view, "webInspector", "Web Inspector", #selector(BrowserWindowController.paddleWebInspector(_:)), "i", [.command, .option])
        view.addItem(.separator())
        add(view, "fullScreen", "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let history = submenu(main, "History")
        add(history, "back", "Back", #selector(BrowserWindowController.paddleBack(_:)), "[")
        add(history, "forward", "Forward", #selector(BrowserWindowController.paddleForward(_:)), "]")
        history.addItem(.separator())
        add(history, "showHistory", "Show All History", #selector(AppDelegate.paddleShowHistory(_:)), "y", target: appDelegate)
        // Recently visited pages go here, filled in by HistoryMenuDelegate when the menu opens.
        history.addItem(.separator())
        add(history, "clearHistory", "Clear History…", #selector(AppDelegate.paddleClearHistory(_:)), "", target: appDelegate)
        history.delegate = HistoryMenuDelegate.shared

        let tabs = submenu(main, "Tabs")
        add(tabs, "nextTab", "Show Next Tab", #selector(BrowserWindowController.paddleNextTab(_:)), "\t", [.control])
        hidden(tabs, "Show Next Tab", #selector(BrowserWindowController.paddleNextTab(_:)), "]", [.command, .shift])
        add(tabs, "previousTab", "Show Previous Tab", #selector(BrowserWindowController.paddlePreviousTab(_:)), "\t", [.control, .shift])
        hidden(tabs, "Show Previous Tab", #selector(BrowserWindowController.paddlePreviousTab(_:)), "[", [.command, .shift])
        tabs.addItem(.separator())
        add(tabs, "togglePin", "Pin Tab", #selector(BrowserWindowController.paddleTogglePin(_:)), "")
        add(tabs, "duplicateTab", "Duplicate Tab", #selector(BrowserWindowController.paddleDuplicateTab(_:)), "")
        add(tabs, "sleepBackgroundTabs", "Sleep Background Tabs", #selector(AppDelegate.paddleSleepBackgroundTabs(_:)), "", target: appDelegate)
        tabs.addItem(.separator())
        for n in 1...9 {
            let item = add(tabs, "tab\(n)", n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.paddleSelectTab(_:)), "\(n)")
            item.tag = n
        }

        let window = submenu(main, "Window")
        add(window, "minimize", "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    /// Restores default shortcuts, then applies config.json overrides. Bad entries are logged and skipped.
    static func applyShortcuts(_ overrides: [String: String]) {
        for (name, (key, modifiers)) in defaultShortcuts {
            itemsByName[name]?.keyEquivalent = key
            itemsByName[name]?.keyEquivalentModifierMask = modifiers
        }
        for (name, text) in overrides {
            guard let item = itemsByName[name] else {
                log.error("shortcuts: unknown action \(name, privacy: .public)")
                continue
            }
            guard let shortcut = Shortcut.parse(text) else {
                log.error("shortcuts: can't parse \(text, privacy: .public) for \(name, privacy: .public)")
                continue
            }
            var modifiers: NSEvent.ModifierFlags = []
            if shortcut.command { modifiers.insert(.command) }
            if shortcut.shift { modifiers.insert(.shift) }
            if shortcut.option { modifiers.insert(.option) }
            if shortcut.control { modifiers.insert(.control) }
            item.keyEquivalent = keyEquivalent(for: shortcut.key)
            item.keyEquivalentModifierMask = modifiers
        }
    }

    private static func keyEquivalent(for key: String) -> String {
        func function(_ code: Int) -> String { UnicodeScalar(UInt16(code)).map { String(Character($0)) } ?? "" }
        switch key {
        case "left": return function(NSLeftArrowFunctionKey)
        case "right": return function(NSRightArrowFunctionKey)
        case "up": return function(NSUpArrowFunctionKey)
        case "down": return function(NSDownArrowFunctionKey)
        case "home": return function(NSHomeFunctionKey)
        case "end": return function(NSEndFunctionKey)
        case "pageup": return function(NSPageUpFunctionKey)
        case "pagedown": return function(NSPageDownFunctionKey)
        case "tab": return "\t"
        case "return": return "\r"
        case "escape": return "\u{1b}"
        case "delete": return "\u{8}"
        case "space": return " "
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) { return function(NSF1FunctionKey + n - 1) }
            return key
        }
    }

    // MARK: - Helpers

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu,
        _ name: String,
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        item.identifier = NSUserInterfaceItemIdentifier(name)
        menu.addItem(item)
        itemsByName[name] = item
        defaultShortcuts[name] = (key, item.keyEquivalentModifierMask)
        return item
    }

    /// A second shortcut for a command (e.g. Cmd-Shift-] next to Ctrl-Tab): hidden but still active.
    private static func hidden(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        menu.addItem(item)
    }
}
