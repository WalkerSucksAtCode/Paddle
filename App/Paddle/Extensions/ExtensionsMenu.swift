import AppKit
import PaddleCore
import WebKit

/// Extensions menu: a submenu per running extension, then each folder's load status as disabled
/// lines. Items exist only while the menu is open — a command item carries the extension shortcut
/// as its key equivalent, and sitting in the menu bar it would claim the key from the page.
/// Commands run from `ExtensionHost`'s key monitor, which leaves Paddle's menu keys to the menu.
final class ExtensionsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ExtensionsMenuDelegate()
    private static let tag = 7_003

    /// The front window's profile: its extensions are the ones listed.
    private var host: ExtensionHost { AppModel.shared.frontExtensions }
    private var isOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        removeDynamicItems(from: menu)
        add(.separator(), to: menu)
        for ext in host.loaded { add(item(for: ext), to: menu) }
        if !host.loaded.isEmpty { add(.separator(), to: menu) }
        for line in host.statusLines {
            // No action: AppKit shows it disabled.
            add(NSMenuItem(title: ExtensionPermissionText.sanitize(line, max: 80), action: nil, keyEquivalent: ""), to: menu)
        }
        // Store updates, one line per folder checked (`ExtensionUpdater`).
        let updates = ExtensionUpdater.shared.statuses
        for folder in updates.keys.sorted() {
            let line = "\(folder): \(updates[folder] ?? "")"
            add(NSMenuItem(title: ExtensionPermissionText.sanitize(line, max: 80), action: nil, keyEquivalent: ""), to: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        // After the chosen item's action has been sent; not if the menu is already open again.
        DispatchQueue.main.async {
            guard !self.isOpen else { return }
            self.removeDynamicItems(from: menu)
        }
    }

    private func removeDynamicItems(from menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)
    }

    private func add(_ item: NSMenuItem, to menu: NSMenu) {
        item.tag = Self.tag
        menu.addItem(item)
    }

    private func item(for ext: LoadedExtension) -> NSMenuItem {
        let item = NSMenuItem(title: "\(ext.displayName) \(ext.version) (\(ext.name))", action: nil, keyEquivalent: "")
        if let icon = ext.webExtension.icon(for: CGSize(width: 16, height: 16)) {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        item.submenu = submenu(for: ext)
        return item
    }

    private func submenu(for ext: LoadedExtension) -> NSMenu {
        let menu = NSMenu(title: ext.displayName)
        let context = ext.context
        // A private window this extension can't see is in front: actions and commands would act on (and grant
        // activeTab to) a hidden window's tab, so they are disabled (no action).
        let frontIsHidden = AppModel.shared.frontWindowIsHidden(from: context)
        if ext.hasAction {
            let tab = AppModel.shared.frontExtensionWindow(for: context)?.model.selectedTab
            let presentsPopup = context.action(for: tab?.extensionTab)?.presentsPopup ?? false
            let item = own(presentsPopup ? "Show Popup" : "Run Action", #selector(performAction(_:)), ext)
            if frontIsHidden { item.action = nil }
            menu.addItem(item)
        }
        if context.optionsPageURL != nil {
            menu.addItem(own("Options…", #selector(openOptions(_:)), ext))
        }
        menu.addItem(.separator())
        menu.addItem(own("Show Problems…", #selector(showProblems(_:)), ext))
        menu.addItem(own("Ask About Permissions Again", #selector(askAgain(_:)), ext))
        if let denials = host.autoDenied[ext.name], !denials.sites.isEmpty {
            let count = denials.requests
            menu.addItem(own("\(count) site request\(count == 1 ? "" : "s") auto-denied — Review…", #selector(reviewAutoDenied(_:)), ext))
        }
        if AppModel.shared.config.developerTools {
            if let background = host.backgroundWebView(of: ext), WebInspector.isAvailable(for: background) {
                menu.addItem(own("Inspect Background Page", #selector(inspectBackground(_:)), ext))
            } else {
                let reason = ext.webExtension.hasBackgroundContent ? "not running" : "none"
                menu.addItem(NSMenuItem(title: "Inspect Background Page (\(reason))", action: nil, keyEquivalent: ""))
            }
        }
        // Commands last, under a header and with sanitized titles, so one named "Ask About Permissions Again" can't
        // pass for Paddle's item. Paddle builds the items (key equivalent shown, not claimed: the menu is open).
        let commands = context.commands
        if !commands.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Commands from \(ext.displayName)"))
            for command in commands {
                let title = ExtensionPermissionText.sanitize(command.title, max: 80)
                let item = NSMenuItem(title: title.isEmpty ? ExtensionPermissionText.sanitize(command.id, max: 80) : title, action: frontIsHidden ? nil : #selector(performCommand(_:)), keyEquivalent: command.activationKey ?? "")
                item.keyEquivalentModifierMask = command.modifierFlags
                item.target = self
                item.representedObject = CommandChoice(ext: ext, command: command)
                menu.addItem(item)
            }
        }
        return menu
    }

    private struct CommandChoice {
        let ext: LoadedExtension
        let command: WKWebExtension.Command
    }

    @objc private func performCommand(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? CommandChoice, let host = choice.ext.host,
              host.loaded.contains(where: { $0 === choice.ext }), !AppModel.shared.frontWindowIsHidden(from: choice.ext.context) else { return }
        host.performCommand(choice.command, of: choice.ext)
    }

    private func own(_ title: String, _ action: Selector, _ ext: LoadedExtension) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = ext
        return item
    }

    private func ext(_ sender: Any?) -> LoadedExtension? {
        guard let ext = (sender as? NSMenuItem)?.representedObject as? LoadedExtension else { return nil }
        // The item may outlive a reload; only an extension still running is acted on, by its own profile's host.
        return ext.host?.loaded.first { $0 === ext }
    }

    @objc private func performAction(_ sender: Any?) {
        guard let ext = ext(sender), let host = ext.host, !AppModel.shared.frontWindowIsHidden(from: ext.context) else { return }
        host.performAction(ext, in: AppModel.shared.frontExtensionWindow(for: ext.context)?.model.selectedTab)
    }

    @objc private func openOptions(_ sender: Any?) {
        guard let ext = ext(sender) else { return }
        try? ext.host?.openOptionsPage(for: ext.context)
    }

    @objc private func askAgain(_ sender: Any?) {
        guard let ext = ext(sender), let host = ext.host else { return }
        Task { await host.askAgain(ext) }
    }

    /// Sites the extension asked about with no tab and no click (answered "no" without an alert): tick the ones it
    /// may access. Most asked-about first.
    @objc private func reviewAutoDenied(_ sender: Any?) {
        guard let ext = ext(sender), let host = ext.host, let sites = host.autoDenied[ext.name]?.sites, !sites.isEmpty else { return }
        let ordered = sites.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let boxes = ordered.map { site, count in
            NSButton(checkboxWithTitle: "\(ExtensionPermissionText.sanitize(site, max: 80)) (\(count))", target: nil, action: nil)
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.frame.size = stack.fittingSize
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: min(stack.fittingSize.height, 240)))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = stack

        let alert = NSAlert()
        alert.messageText = "Sites “\(ext.displayName)” asked about"
        alert.informativeText = "It asked to see tabs on these sites without a click on it, so Paddle said no. "
            + "Checked sites are allowed from now on: it can read and change their pages. The number is how often it asked."
        if let icon = ext.webExtension.icon(for: CGSize(width: 64, height: 64)) { alert.icon = icon }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Allow Checked")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = zip(ordered, boxes).filter { $1.state == .on }.map(\.0.key)
        // The extension may have been unloaded while the alert was up.
        guard !chosen.isEmpty, let current = self.ext(sender) else { return }
        host.allowAutoDeniedSites(Set(chosen), for: current)
    }

    @objc private func inspectBackground(_ sender: Any?) {
        guard let ext = ext(sender), let background = ext.host?.backgroundWebView(of: ext) else { return }
        WebInspector.show(background)
    }

    /// Manifest problems found at load, plus WebKit's parse-time and runtime errors so far (minus the read-only
    /// assignment errors the compat prelude's pinned globals cause on purpose).
    @objc private func showProblems(_ sender: Any?) {
        guard let ext = ext(sender) else { return }
        let runtime = ext.context.errors.map(\.localizedDescription).filter { !host.isPreludeNoise($0, extension: ext.name) }
        let lines = (ext.problems + runtime).map { ExtensionPermissionText.sanitize($0, max: 240) }
        let alert = NSAlert()
        alert.messageText = "\(ext.displayName) \(ext.version)"
        alert.informativeText = lines.isEmpty ? "No problems." : lines.joined(separator: "\n")
        if let icon = ext.webExtension.icon(for: CGSize(width: 64, height: 64)) { alert.icon = icon }
        alert.runModal()
    }
}
