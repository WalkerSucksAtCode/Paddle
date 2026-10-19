import AppKit
import os
import PaddleCore
import WebKit

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

    /// The Develop menu's bar item; in the bar only while `developerTools` is on.
    private static var developItem: NSMenuItem?

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
        let profileItem = NSMenuItem(title: "New Window in Profile", action: nil, keyEquivalent: "")
        profileItem.submenu = NSMenu(title: "New Window in Profile")
        profileItem.isHidden = true
        file.addItem(profileItem)
        ProfileMenuDelegate.shared.item = profileItem
        file.delegate = ProfileMenuDelegate.shared
        add(file, "newPrivateWindow", "New Private Window", #selector(AppDelegate.paddleNewPrivateWindow(_:)), "n", [.command, .shift], target: appDelegate)
        add(file, "openLocation", "Open Location…", #selector(BrowserWindowController.paddleOpenLocation(_:)), "l")
        file.addItem(.separator())
        add(file, "closeTab", "Close Tab", #selector(BrowserWindowController.paddleCloseTab(_:)), "w")
        add(file, "closeWindow", "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(file, "reopenClosedTab", "Reopen Closed Tab", #selector(BrowserWindowController.paddleReopenClosedTab(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        add(file, "savePage", "Save Page As…", #selector(BrowserWindowController.paddleSavePage(_:)), "s")
        add(file, "exportPDF", "Export as PDF…", #selector(BrowserWindowController.paddleExportPDF(_:)), "")
        add(file, "openInPreview", "Open in Preview", #selector(BrowserWindowController.paddleOpenInPreview(_:)), "")
        add(file, "createQRCode", "Create QR Code…", #selector(BrowserWindowController.paddleCreateQRCode(_:)), "")
        add(file, "print", "Print…", #selector(BrowserWindowController.paddlePrint(_:)), "p")
        let share = add(file, "sharePage", "Share…", #selector(BrowserWindowController.paddleShare(_:)), "")
        let shareSubmenu = NSMenu(title: "Share")
        shareSubmenu.delegate = ShareMenuDelegate.shared
        share.submenu = shareSubmenu
        ShareMenuDelegate.shared.item = share
        file.addItem(.separator())
        add(file, "importFromBrowser", "Import from Browser…", #selector(AppDelegate.paddleImportFromBrowser(_:)), "", target: appDelegate)

        let edit = submenu(main, "Edit")
        add(edit, "undo", "Undo", Selector(("undo:")), "z")
        add(edit, "redo", "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "cut", "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "copy", "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "copyLinkToHighlight", "Copy Link to Highlight", #selector(BrowserWindowController.paddleCopyLinkToHighlight(_:)), "c", [.command, .shift])
        add(edit, "paste", "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "pasteAndMatchStyle", "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(edit, "selectAll", "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "find", "Find…", #selector(BrowserWindowController.paddleFind(_:)), "f")
        add(edit, "findNext", "Find Next", #selector(BrowserWindowController.paddleFindNext(_:)), "g")
        add(edit, "findPrevious", "Find Previous", #selector(BrowserWindowController.paddleFindPrevious(_:)), "g", [.command, .shift])
        add(edit, "useSelectionForFind", "Use Selection for Find", #selector(BrowserWindowController.paddleUseSelectionForFind(_:)), "e")
        add(edit, "jumpToSelection", "Jump to Selection", #selector(BrowserWindowController.paddleJumpToSelection(_:)), "j")
        add(edit, "searchSelectedText", "Search with Search Engine", #selector(BrowserWindowController.paddleSearchSelectedText(_:)), "f", [.command, .shift])

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
        add(view, "toggleReaderMode", "Show Reader", #selector(BrowserWindowController.paddleToggleReaderMode(_:)), "r", [.command, .shift])
        add(view, "toggleDarkMode", "Dark Mode", #selector(BrowserWindowController.paddleToggleDarkMode(_:)), "d", [.command, .shift])
        add(view, "togglePictureInPicture", "Picture in Picture", #selector(BrowserWindowController.paddleTogglePictureInPicture(_:)), "p", [.command, .control])
        add(view, "translatePage", "Translate Page…", #selector(BrowserWindowController.paddleTranslatePage(_:)), "")
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
        add(bookmarks, "addToNewTabPage", "Add Page to New Tab Page", #selector(BrowserWindowController.paddleToggleNewTabSite(_:)), "")
        add(bookmarks, "showBookmarks", "Show Bookmarks", #selector(AppDelegate.paddleShowBookmarks(_:)), "b", [.command, .option], target: appDelegate)
        add(bookmarks, "toggleBookmarksBar", "Hide Bookmarks Bar", #selector(AppDelegate.paddleToggleBookmarksBar(_:)), "b", [.command, .shift], target: appDelegate)
        bookmarks.addItem(.separator())
        add(bookmarks, "importBookmarks", "Import Bookmarks…", #selector(AppDelegate.paddleImportBookmarks(_:)), "", target: appDelegate)
        add(bookmarks, "exportBookmarks", "Export Bookmarks…", #selector(AppDelegate.paddleExportBookmarks(_:)), "", target: appDelegate)
        // Bookmarks themselves are listed below, filled in by BookmarksMenuDelegate when the menu opens.
        bookmarks.delegate = BookmarksMenuDelegate.shared

        // Present only while config.developerTools is on (`setDevelopMenu(visible:)`). An item whose private WebKit call
        // is missing is hidden, decided here once.
        let develop = submenu(main, "Develop")
        developItem = main.items.last
        let webInspector = add(develop, "webInspector", "Show Web Inspector", #selector(BrowserWindowController.paddleWebInspector(_:)), "i", [.command, .option])
        webInspector.isHidden = !WebInspector.isAvailable(NSSelectorFromString("show"))
        let console = add(develop, "javaScriptConsole", "Show JavaScript Console", #selector(BrowserWindowController.paddleJavaScriptConsole(_:)), "c", [.command, .option])
        console.isHidden = !WebInspector.isAvailable(NSSelectorFromString("showConsole"))
        let selection = add(develop, "elementSelection", "Start Element Selection", #selector(BrowserWindowController.paddleElementSelection(_:)), "c", [.command, .shift])
        selection.isHidden = !WebInspector.isAvailable(NSSelectorFromString("toggleElementSelection"))
        develop.addItem(.separator())
        let noBlockers = add(develop, "reloadWithoutContentBlockers", "Reload Without Content Blockers", #selector(BrowserWindowController.paddleReloadWithoutContentBlockers(_:)), "")
        noBlockers.isHidden = !WKWebView.instancesRespond(to: NSSelectorFromString("_reloadWithoutContentBlockers"))
        add(develop, "emptyCaches", "Empty Caches", #selector(BrowserWindowController.paddleEmptyCaches(_:)), "e", [.command, .option])
        develop.addItem(.separator())
        add(develop, "responsiveDesignMode", "Responsive Design Mode", #selector(BrowserWindowController.paddleToggleResponsiveDesignMode(_:)), "r", [.command, .control])
        develop.addItem(.separator())
        let background = DevelopMenuDelegate.backgroundPagesItem()
        background.isHidden = !WebInspector.canInspectBackgroundPages
        develop.addItem(background)
        if !AppModel.shared.config.developerTools { main.removeItem(developItem!) }

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
        add(tabs, "closeOtherTabs", "Close Other Tabs", #selector(BrowserWindowController.paddleCloseOtherTabs(_:)), "")
        add(tabs, "closeTabsToTheRight", "Close Tabs to the Right", #selector(BrowserWindowController.paddleCloseTabsToTheRight(_:)), "")
        add(tabs, "renameTab", "Rename Tab…", #selector(BrowserWindowController.paddleRenameTab(_:)), "")
        add(tabs, "addTabToNewGroup", "Add Tab to New Group", #selector(BrowserWindowController.paddleAddTabToNewGroup(_:)), "")
        add(tabs, "removeTabFromGroup", "Remove Tab from Group", #selector(BrowserWindowController.paddleRemoveTabFromGroup(_:)), "")
        tabs.addItem(.separator())
        for n in 1...9 {
            let item = add(tabs, "space\(n)", "Space \(n)", #selector(BrowserWindowController.paddleSelectSpace(_:)), "\(n)", [.control])
            item.tag = n
            // Shown only while the window has that many spaces (SpacesMenuDelegate); the key stays live meanwhile.
            item.allowsKeyEquivalentWhenHidden = true
        }
        add(tabs, "nextSpace", "Next Space", #selector(BrowserWindowController.paddleNextSpace(_:)), "")
        add(tabs, "previousSpace", "Previous Space", #selector(BrowserWindowController.paddlePreviousSpace(_:)), "")
        add(tabs, "newSpace", "New Space", #selector(BrowserWindowController.paddleNewSpace(_:)), "")
        add(tabs, "editSpace", "Edit Space…", #selector(BrowserWindowController.paddleEditSpace(_:)), "")
        add(tabs, "deleteSpace", "Delete Space", #selector(BrowserWindowController.paddleDeleteSpace(_:)), "")
        let moveToSpace = NSMenuItem(title: "Move Tab to Space", action: nil, keyEquivalent: "")
        moveToSpace.submenu = NSMenu(title: "Move Tab to Space")
        tabs.addItem(moveToSpace)
        SpacesMenuDelegate.shared.moveItem = moveToSpace
        tabs.delegate = SpacesMenuDelegate.shared
        tabs.addItem(.separator())
        add(tabs, "toggleMosaic", "Mosaic", #selector(BrowserWindowController.paddleToggleSplitView(_:)), "\\", [.command, .control])
        let mosaic = NSMenu(title: "Mosaic Layout")
        let mosaicItem = NSMenuItem(title: "Mosaic Layout", action: nil, keyEquivalent: "")
        mosaicItem.submenu = mosaic
        tabs.addItem(mosaicItem)
        add(mosaic, "arrangeColumns", "Columns", #selector(BrowserWindowController.paddleArrangeColumns(_:)), "")
        add(mosaic, "arrangeRows", "Rows", #selector(BrowserWindowController.paddleArrangeRows(_:)), "")
        add(mosaic, "arrangeGrid", "Grid", #selector(BrowserWindowController.paddleArrangeGrid(_:)), "")
        add(mosaic, "arrangeMainAndStack", "Main and Stack", #selector(BrowserWindowController.paddleArrangeMainAndStack(_:)), "")
        mosaic.addItem(.separator())
        add(mosaic, "evenOutPanes", "Even Out Panes", #selector(BrowserWindowController.paddleEvenOutPanes(_:)), "")
        add(mosaic, "rotatePanes", "Rotate Panes", #selector(BrowserWindowController.paddleRotatePanes(_:)), "")
        add(mosaic, "swapMosaicPanes", "Swap Panes", #selector(BrowserWindowController.paddleSwapSplitSides(_:)), "")
        mosaic.addItem(.separator())
        add(mosaic, "zoomPane", "Zoom Pane", #selector(BrowserWindowController.paddleZoomPane(_:)), "\r", [.command, .control])
        add(mosaic, "movePaneLeft", "Move Pane Left", #selector(BrowserWindowController.paddleMovePaneLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option, .control, .shift])
        add(mosaic, "movePaneRight", "Move Pane Right", #selector(BrowserWindowController.paddleMovePaneRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option, .control, .shift])
        add(mosaic, "movePaneUp", "Move Pane Up", #selector(BrowserWindowController.paddleMovePaneUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option, .control, .shift])
        add(mosaic, "movePaneDown", "Move Pane Down", #selector(BrowserWindowController.paddleMovePaneDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option, .control, .shift])
        add(mosaic, "muteOtherPanes", "Mute Other Panes", #selector(BrowserWindowController.paddleMuteOtherPanes(_:)), "")
        add(tabs, "addPane", "Add Pane to Mosaic", #selector(BrowserWindowController.paddleAddPane(_:)), "")
        add(tabs, "reloadAllPanes", "Reload All Panes", #selector(BrowserWindowController.paddleReloadAllPanes(_:)), "")
        add(tabs, "focusNextPane", "Focus Next Pane", #selector(BrowserWindowController.paddleFocusOtherSplitSide(_:)), "")
        add(tabs, "focusPaneLeft", "Focus Pane on the Left", #selector(BrowserWindowController.paddleFocusPaneLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option, .control])
        add(tabs, "focusPaneRight", "Focus Pane on the Right", #selector(BrowserWindowController.paddleFocusPaneRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option, .control])
        add(tabs, "focusPaneUp", "Focus Pane Above", #selector(BrowserWindowController.paddleFocusPaneUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option, .control])
        add(tabs, "focusPaneDown", "Focus Pane Below", #selector(BrowserWindowController.paddleFocusPaneDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option, .control])
        add(tabs, "removeFromMosaic", "Remove Tab from Mosaic", #selector(BrowserWindowController.paddleRemoveFromView(_:)), "")
        tabs.addItem(.separator())
        add(tabs, "openLinkPreviewAsTab", "Open Preview as Tab", #selector(BrowserWindowController.paddleOpenLinkPreviewAsTab(_:)), "\r", [.command, .shift])
        // No key: Escape closes the preview from the page (`BrowserWindowController.closePreviewOnEscape`).
        add(tabs, "closeLinkPreview", "Close Preview", #selector(BrowserWindowController.paddleCloseLinkPreview(_:)), "")
        tabs.addItem(.separator())
        add(tabs, "moveTabLeft", "Move Tab Left", #selector(BrowserWindowController.paddleMoveTabLeft(_:)), String(UnicodeScalar(NSPageUpFunctionKey)!), [.control, .shift])
        add(tabs, "moveTabRight", "Move Tab Right", #selector(BrowserWindowController.paddleMoveTabRight(_:)), String(UnicodeScalar(NSPageDownFunctionKey)!), [.control, .shift])
        add(tabs, "toggleMute", "Mute Tab", #selector(BrowserWindowController.paddleToggleMute(_:)), "m", [.command, .control])
        add(tabs, "muteOtherTabs", "Mute Other Tabs", #selector(BrowserWindowController.paddleMuteOtherTabs(_:)), "")
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

    /// Puts the Develop menu in the menu bar (after Bookmarks) or takes it out, live when `developerTools` changes.
    static func setDevelopMenu(visible: Bool) {
        guard let main = NSApp.mainMenu, let item = developItem else { return }
        let present = main.items.contains { $0 === item }
        if visible, !present {
            let bookmarks = main.items.firstIndex { $0.submenu?.title == "Bookmarks" }
            main.insertItem(item, at: bookmarks.map { $0 + 1 } ?? main.items.count)
        } else if !visible, present {
            main.removeItem(item)
        }
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
    /// The menu item for an action name (the control bridge's `menu_action`).
    static func item(named name: String) -> NSMenuItem? { itemsByName[name] }
    static func menuTitle(for name: String) -> String? { itemsByName[name]?.menu?.title }

    /// A fresh copy of the menu-bar command `name` (action, target, tag and its current shortcut, so a `shortcuts`
    /// rebinding shows here too), for the toolbar menu. `title` replaces the menu-bar title.
    static func copyOfItem(_ name: String, title: String? = nil) -> NSMenuItem? {
        guard let item = itemsByName[name], !item.isHidden else { return nil }
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

/// Fills File > New Window in Profile each time File opens: one item per profile, hidden while there is only one.
@MainActor
final class ProfileMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ProfileMenuDelegate()
    var item: NSMenuItem?

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item, let submenu = item.submenu else { return }
        let profiles = AppModel.shared.profiles
        item.isHidden = !profiles.hasSeveral
        submenu.removeAllItems()
        for profile in profiles.all {
            let entry = NSMenuItem(title: profile.name, action: #selector(AppDelegate.paddleNewWindowInProfile(_:)), keyEquivalent: "")
            entry.target = NSApp.delegate
            entry.representedObject = profile.id
            entry.image = NSImage(systemSymbolName: profile.symbol.sfSymbol, accessibilityDescription: profile.symbol.displayName)
            entry.preferredImageVisibility = .visible
            submenu.addItem(entry)
        }
    }
}

/// Refreshes the Tabs menu's space items from the front window each time the menu opens or a key is tried: Space 1…9
/// carry their space's name, are hidden past the last one and tick the active one; Move Tab to Space lists the others.
@MainActor
final class SpacesMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = SpacesMenuDelegate()
    var moveItem: NSMenuItem?

    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = AppModel.shared.frontWindow?.model
        let spaces = model?.spaces ?? []
        for item in menu.items where item.action == #selector(BrowserWindowController.paddleSelectSpace(_:)) {
            let space = spaces.indices.contains(item.tag - 1) ? spaces[item.tag - 1] : nil
            item.isHidden = space == nil
            item.title = space?.name ?? "Space \(item.tag)"
            item.image = space.flatMap { NSImage(systemSymbolName: $0.symbol.sfSymbol, accessibilityDescription: $0.symbol.displayName) }
            item.preferredImageVisibility = .visible
            item.state = space?.id == model?.activeSpaceID ? .on : .off
        }
        guard let moveItem, let submenu = moveItem.submenu else { return }
        submenu.removeAllItems()
        for space in spaces where space.id != model?.activeSpaceID {
            let entry = NSMenuItem(title: space.name, action: #selector(BrowserWindowController.paddleMoveTabToSpace(_:)), keyEquivalent: "")
            entry.representedObject = space.id
            entry.image = NSImage(systemSymbolName: space.symbol.sfSymbol, accessibilityDescription: space.symbol.displayName)
            entry.preferredImageVisibility = .visible
            submenu.addItem(entry)
        }
        moveItem.isHidden = false
        moveItem.isEnabled = !submenu.items.isEmpty && model?.selectedTab != nil
    }
}

/// Fills File > Share submenu with system sharing services for the active page (AirDrop, Messages, Notes, etc.).
@MainActor
final class ShareMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ShareMenuDelegate()
    var item: NSMenuItem?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = NSApp.keyWindow?.windowController as? BrowserWindowController,
              let tab = controller.tab, let url = tab.url else {
            let empty = NSMenuItem(title: "No Shareable Page", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let items: [Any] = [url, tab.title]
        let services = NSSharingService.sharingServices(forItems: items)
        for service in services {
            let entry = NSMenuItem(title: service.title, action: #selector(BrowserWindowController.performSharingService(_:)), keyEquivalent: "")
            entry.representedObject = service
            entry.image = service.image
            entry.preferredImageVisibility = .visible
            menu.addItem(entry)
        }
    }
}
