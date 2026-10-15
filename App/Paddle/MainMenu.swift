import AppKit
import os
import PaddleCore

/// The menu bar. Every command has an action name (listed under "Shortcut action names" in README) that config.json's
/// `shortcuts` can rebind, e.g. `"shortcuts": { "nextTab": "cmd+option+right" }`.
enum MainMenu {
    private static var itemsByName: [String: NSMenuItem] = [:]
    private static var defaultShortcuts: [String: (String, NSEvent.ModifierFlags)] = [:]
    /// Action names in menu order, for Settings > Shortcuts.
    private static var order: [String] = []
    /// Hidden second shortcuts by the action they belong to (⇧⌘] for `nextTab`); `shortcuts` never changes them.
    private static var aliases: [String: [(String, NSEvent.ModifierFlags)]] = [:]
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "menu")

    static var actionNames: [String] { itemsByName.keys.sorted() }

    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Paddle")
        app.addItem(withTitle: "About Paddle", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, "settings", "Settings…", #selector(AppDelegate.paddleShowSettings(_:)), ",", target: appDelegate)
        add(app, "openConfigFolder", "Open Config Folder", #selector(AppDelegate.paddleOpenConfigFolder(_:)), "", target: appDelegate)
        add(app, "reloadConfig", "Reload Config", #selector(AppDelegate.paddleReloadConfig(_:)), ",", [.command, .option], target: appDelegate)
        add(app, "updateFilterLists", "Update Filter Lists", #selector(AppDelegate.paddleUpdateFilterLists(_:)), "", target: appDelegate)
        add(app, "makeDefaultBrowser", "Make Paddle the Default Browser…", #selector(AppDelegate.paddleMakeDefaultBrowser(_:)), "", target: appDelegate)
        app.addItem(.separator())
        add(app, "hide", "Hide Paddle", #selector(NSApplication.hide(_:)), "h")
        add(app, "hideOthers", "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, "quit", "Quit Paddle", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, "File")
        add(file, "newTab", "New Tab", #selector(BrowserWindowController.paddleNewTab(_:)), "t")
        add(file, "newWindow", "New Window", #selector(AppDelegate.paddleNewWindow(_:)), "n", target: appDelegate)
        add(file, "newPrivateWindow", "New Private Window", #selector(AppDelegate.paddleNewPrivateWindow(_:)), "n", [.command, .shift], target: appDelegate)
        add(file, "openLocation", "Open Location…", #selector(BrowserWindowController.paddleOpenLocation(_:)), "l")
        file.addItem(.separator())
        add(file, "closeTab", "Close Tab", #selector(BrowserWindowController.paddleCloseTab(_:)), "w")
        add(file, "closeWindow", "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(file, "reopenClosedTab", "Reopen Closed Tab", #selector(BrowserWindowController.paddleReopenClosedTab(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        add(file, "savePage", "Save Page As…", #selector(BrowserWindowController.paddleSavePage(_:)), "s")
        add(file, "print", "Print…", #selector(BrowserWindowController.paddlePrint(_:)), "p")
        file.addItem(.separator())
        add(file, "importFromBrowser", "Import from Browser…", #selector(AppDelegate.paddleImportFromBrowser(_:)), "", target: appDelegate)

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
        add(edit, "useSelectionForFind", "Use Selection for Find", #selector(BrowserWindowController.paddleUseSelectionForFind(_:)), "e")
        add(edit, "jumpToSelection", "Jump to Selection", #selector(BrowserWindowController.paddleJumpToSelection(_:)), "j")

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
        add(view, "toggleVerticalTabs", "Vertical Tabs", #selector(AppDelegate.paddleToggleVerticalTabs(_:)), "", target: appDelegate)
        add(view, "toggleSidebarCollapsed", "Collapse Sidebar", #selector(AppDelegate.paddleToggleSidebarCollapsed(_:)), "", target: appDelegate)
        add(view, "showDownloads", "Show Downloads", #selector(BrowserWindowController.paddleShowDownloads(_:)), "l", [.command, .option])
        view.addItem(.separator())
        add(view, "viewSource", "View Source", #selector(BrowserWindowController.paddleViewSource(_:)), "u", [.command, .option])
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

        let bookmarks = submenu(main, "Bookmarks")
        add(bookmarks, "addBookmark", "Bookmark This Page", #selector(BrowserWindowController.paddleToggleBookmark(_:)), "d")
        add(bookmarks, "showBookmarks", "Show Bookmarks", #selector(AppDelegate.paddleShowBookmarks(_:)), "b", [.command, .option], target: appDelegate)
        add(bookmarks, "toggleBookmarksBar", "Hide Bookmarks Bar", #selector(AppDelegate.paddleToggleBookmarksBar(_:)), "b", [.command, .shift], target: appDelegate)
        bookmarks.addItem(.separator())
        add(bookmarks, "importBookmarks", "Import Bookmarks…", #selector(AppDelegate.paddleImportBookmarks(_:)), "", target: appDelegate)
        add(bookmarks, "exportBookmarks", "Export Bookmarks…", #selector(AppDelegate.paddleExportBookmarks(_:)), "", target: appDelegate)
        // Bookmarks themselves are listed below, filled in by BookmarksMenuDelegate when the menu opens.
        bookmarks.delegate = BookmarksMenuDelegate.shared

        let tabs = submenu(main, "Tabs")
        add(tabs, "nextTab", "Show Next Tab", #selector(BrowserWindowController.paddleNextTab(_:)), "\t", [.control])
        hidden(tabs, "Show Next Tab", #selector(BrowserWindowController.paddleNextTab(_:)), "]", [.command, .shift])
        hidden(tabs, "Show Next Tab", #selector(BrowserWindowController.paddleNextTab(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        add(tabs, "previousTab", "Show Previous Tab", #selector(BrowserWindowController.paddlePreviousTab(_:)), "\t", [.control, .shift])
        hidden(tabs, "Show Previous Tab", #selector(BrowserWindowController.paddlePreviousTab(_:)), "[", [.command, .shift])
        hidden(tabs, "Show Previous Tab", #selector(BrowserWindowController.paddlePreviousTab(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        tabs.addItem(.separator())
        add(tabs, "togglePin", "Pin Tab", #selector(BrowserWindowController.paddleTogglePin(_:)), "")
        add(tabs, "duplicateTab", "Duplicate Tab", #selector(BrowserWindowController.paddleDuplicateTab(_:)), "")
        add(tabs, "renameTab", "Rename Tab…", #selector(BrowserWindowController.paddleRenameTab(_:)), "")
        add(tabs, "addTabToNewGroup", "Add Tab to New Group", #selector(BrowserWindowController.paddleAddTabToNewGroup(_:)), "")
        add(tabs, "removeTabFromGroup", "Remove Tab from Group", #selector(BrowserWindowController.paddleRemoveTabFromGroup(_:)), "")
        add(tabs, "moveTabLeft", "Move Tab Left", #selector(BrowserWindowController.paddleMoveTabLeft(_:)), String(UnicodeScalar(NSPageUpFunctionKey)!), [.control, .shift])
        add(tabs, "moveTabRight", "Move Tab Right", #selector(BrowserWindowController.paddleMoveTabRight(_:)), String(UnicodeScalar(NSPageDownFunctionKey)!), [.control, .shift])
        add(tabs, "toggleMute", "Mute Tab", #selector(BrowserWindowController.paddleToggleMute(_:)), "m", [.command, .control])
        add(tabs, "searchTabs", "Search Tabs…", #selector(BrowserWindowController.paddleSearchTabs(_:)), "a", [.command, .shift])
        add(tabs, "sleepBackgroundTabs", "Sleep Background Tabs", #selector(AppDelegate.paddleSleepBackgroundTabs(_:)), "", target: appDelegate)
        tabs.addItem(.separator())
        for n in 1...9 {
            let item = add(tabs, "tab\(n)", n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.paddleSelectTab(_:)), "\(n)")
            item.tag = n
        }

        let extensions = submenu(main, "Extensions")
        add(extensions, "installExtensionFromLink", "Install from Link…", #selector(AppDelegate.paddleInstallExtensionFromLink(_:)), "", target: appDelegate)
        add(extensions, "checkExtensionUpdates", "Check for Extension Updates", #selector(AppDelegate.paddleCheckExtensionUpdates(_:)), "", target: appDelegate)
        add(extensions, "openExtensionsFolder", "Open Extensions Folder", #selector(AppDelegate.paddleOpenExtensionsFolder(_:)), "", target: appDelegate)
        add(extensions, "reloadExtensions", "Reload Extensions", #selector(AppDelegate.paddleReloadExtensions(_:)), "", target: appDelegate)
        // Each running extension and the load status lines follow, filled in by ExtensionsMenuDelegate when the menu opens.
        extensions.delegate = ExtensionsMenuDelegate.shared

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

    /// True when an item in the menu bar (hidden ones included) has this key equivalent, compared in key-equivalent
    /// form: an uppercase letter implies Shift. Used to leave Paddle's own shortcuts to the menu when an extension
    /// command is bound to the same key. Items of the Extensions menu's extension submenus exist only while it is
    /// open, so they never match.
    static func usesKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return !items(matching: normalized(key, modifiers)).isEmpty
    }

    /// Every menu item, hidden ones included, whose key equivalent is `target`.
    private static func items(matching target: KeyEquivalent) -> [NSMenuItem] {
        guard let menu = NSApp.mainMenu else { return [] }
        var found: [NSMenuItem] = []
        func search(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty, normalized(item.keyEquivalent, item.keyEquivalentModifierMask) == target { found.append(item) }
                if let submenu = item.submenu { search(submenu) }
            }
        }
        search(menu)
        return found
    }

    private struct KeyEquivalent: Equatable {
        let key: String
        let modifiers: NSEvent.ModifierFlags.RawValue
    }

    private static func normalized(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> KeyEquivalent {
        var flags = modifiers.intersection([.command, .shift, .option, .control])
        if key != key.lowercased() || Shortcut.isShiftedPunctuation(key) { flags.insert(.shift) }
        // In `Shortcut`'s canonical form, so shifted punctuation is its base key ("{" and "[" with ⇧⌘ are one key)
        // and a control character is its name ("\t" is "tab"). Keys `Shortcut` can't name compare as written.
        let base = Shortcut(key: key, modifiers: shortcutModifiers(flags))?.key ?? key.lowercased()
        return KeyEquivalent(key: base, modifiers: flags.rawValue)
    }

    private static func shortcutModifiers(_ flags: NSEvent.ModifierFlags) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    // MARK: - Settings

    /// Every action name in menu order (`actionNames` is alphabetical).
    static var actionNamesInMenuOrder: [String] { order }

    /// The command's menu title as it reads now, and the menu it is in.
    static func title(for name: String) -> String? { itemsByName[name]?.title }
    static func menuTitle(for name: String) -> String? { itemsByName[name]?.menu?.title }

    /// A fresh copy of the menu-bar command `name` (action, target, tag and its current shortcut, so a `shortcuts`
    /// rebinding shows here too), for the toolbar menu. `title` replaces the menu-bar title.
    static func copyOfItem(_ name: String, title: String? = nil) -> NSMenuItem? {
        guard let item = itemsByName[name] else { return nil }
        let copy = NSMenuItem(title: title ?? item.title, action: item.action, keyEquivalent: item.keyEquivalent)
        copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
        copy.target = item.target
        copy.tag = item.tag
        return copy
    }

    /// The shortcut an action has without config.json (an empty key: none). Nil for an unknown name.
    static func defaultShortcut(for name: String) -> Shortcut? {
        guard let (key, modifiers) = defaultShortcuts[name] else { return nil }
        return shortcut(key, modifiers)
    }

    /// The hidden second shortcuts an action keeps whatever `shortcuts` says (⇧⌘] for `nextTab`).
    static func aliasShortcuts(for name: String) -> [Shortcut] {
        (aliases[name] ?? []).compactMap { shortcut($0.0, $0.1) }
    }

    /// Each action's own default shortcut (an empty key: none), for `ConfigFile.tidy(_:shortcutDefaults:)`.
    static var defaultBindings: [String: Shortcut] {
        Dictionary(uniqueKeysWithValues: order.compactMap { name in defaultShortcut(for: name).map { (name, $0) } })
    }

    /// Each action's default and hidden shortcuts, for `ConfigValidator.issues(_:actionNames:defaults:)`.
    static var validatorDefaults: [String: [Shortcut]] {
        Dictionary(uniqueKeysWithValues: order.map { name in
            (name, [defaultShortcut(for: name)].compactMap { $0 } + aliasShortcuts(for: name))
        })
    }

    /// Menu items other than action `name`'s own (and its hidden second shortcuts) that respond to `shortcut`
    /// now, hidden ones included: the action name (nil for a hidden second shortcut) and the title.
    static func conflicts(with shortcut: Shortcut, excluding name: String) -> [(name: String?, title: String)] {
        guard !shortcut.key.isEmpty else { return [] }
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.command { modifiers.insert(.command) }
        if shortcut.shift { modifiers.insert(.shift) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.control { modifiers.insert(.control) }
        let own = itemsByName[name]
        return items(matching: normalized(keyEquivalent(for: shortcut.key), modifiers)).compactMap { item in
            if item === own || (item.isHidden && own != nil && item.action == own?.action && item.menu === own?.menu) { return nil }
            return (item.isHidden ? nil : item.identifier?.rawValue, item.title)
        }
    }

    /// A key equivalent as a `Shortcut`; an uppercase letter implies Shift.
    private static func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Shortcut? {
        guard !key.isEmpty else { return Shortcut(key: "") }
        var flags = modifiers
        if key != key.lowercased() { flags.insert(.shift) }
        return Shortcut(key: key, modifiers: shortcutModifiers(flags))
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
        if itemsByName[name] == nil { order.append(name) }
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
        if let name = itemsByName.first(where: { $0.value.action == action && $0.value.menu === menu })?.key {
            aliases[name, default: []].append((key, modifiers))
        }
    }
}
