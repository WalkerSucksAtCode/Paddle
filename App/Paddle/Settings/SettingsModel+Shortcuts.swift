import AppKit
import Foundation
import PaddleCore

/// One menu command in Settings > Shortcuts, with what config.json says about it.
struct ShortcutRow: Identifiable, Equatable {
    let name: String
    let title: String
    let menu: String
    let defaultShortcut: Shortcut
    /// Hidden second shortcuts `shortcuts` doesn't change (⇧⌘] for `nextTab`).
    let aliases: [Shortcut]
    /// The shortcut config.json gives it: its entry when that parses, else the default.
    let current: Shortcut
    /// config.json has an entry for it.
    let isCustom: Bool
    /// The entry's text when it doesn't parse (Paddle then keeps the default).
    let notUnderstood: String?
    /// ConfigValidator's messages for this entry (a duplicate key, an unparsable value).
    let issues: [String]

    var id: String { name }
}

/// What a shortcut would clash with, worked out before it is saved.
struct ShortcutConflicts {
    /// Menu items that respond to it now, hidden second shortcuts included: action name (nil for a hidden one)
    /// and title.
    var menuItems: [(name: String?, title: String)] = []
    /// ConfigValidator duplicate warnings for config.json with the change made (covers hand edits not applied yet).
    var fileWarnings: [String] = []
    /// Commands of running extensions on the same key; Paddle's menu keeps it.
    var extensionCommands: [String] = []

    var isEmpty: Bool { menuItems.isEmpty && fileWarnings.isEmpty && extensionCommands.isEmpty }
    /// Other actions Replace sets to none.
    var replaceable: [String] { menuItems.compactMap(\.name) }
}

/// Settings > Shortcuts' reads and writes of the `shortcuts` key.
extension SettingsModel {
    /// Every menu action in menu order, with its shortcut as config.json (not the running menu) has it.
    var shortcutRows: [ShortcutRow] {
        let issues = shortcutIssues(file)
        return MainMenu.actionNamesInMenuOrder.map { name in
            let fallback = MainMenu.defaultShortcut(for: name) ?? Shortcut(key: "")
            let text = file.shortcuts[name]
            let parsed = text.flatMap(Shortcut.parse)
            return ShortcutRow(
                name: name,
                title: MainMenu.title(for: name) ?? name,
                menu: MainMenu.menuTitle(for: name) ?? "",
                defaultShortcut: fallback,
                aliases: MainMenu.aliasShortcuts(for: name),
                current: parsed ?? fallback,
                isCustom: text != nil,
                notUnderstood: parsed == nil ? text : nil,
                issues: issues.filter { $0.path == ["shortcuts", name] }.map(\.message)
            )
        }
    }

    /// Entries whose name is no menu action (renamed or mistyped), with their text: listed so they aren't lost
    /// silently, each with Remove.
    var unknownShortcutEntries: [(name: String, text: String)] {
        let names = Set(MainMenu.actionNames)
        return file.shortcuts.keys.filter { !names.contains($0) }.sorted().map { ($0, file.shortcuts[$0] ?? "") }
    }

    /// What `shortcut` on action `name` would clash with: the running menu (excluding the action's own item),
    /// the validator on config.json with the change made, and running extensions' commands.
    func shortcutConflicts(_ shortcut: Shortcut, for name: String) -> ShortcutConflicts {
        guard !shortcut.key.isEmpty else { return ShortcutConflicts() }
        var result = ShortcutConflicts()
        result.menuItems = MainMenu.conflicts(with: shortcut, excluding: name)
        var proposed = file
        proposed.shortcuts[name] = shortcut.configText
        result.fileWarnings = shortcutIssues(proposed)
            .filter { $0.path == ["shortcuts", name] && $0.severity == .warning }
            .map(\.message)
        // Every profile's extensions: one running in two profiles is listed once.
        for ext in AppModel.shared.extensionHosts.flatMap(\.loaded) {
            for command in ext.context.commands {
                guard let key = command.activationKey,
                      Shortcut(key: key, modifiers: Shortcut.Modifiers(command.modifierFlags)) == shortcut else { continue }
                let line = "\(ext.displayName): \(ExtensionPermissionText.sanitize(command.title))"
                if !result.extensionCommands.contains(line) { result.extensionCommands.append(line) }
            }
        }
        return result
    }

    /// Saves `shortcut` for `name` (its default removes the entry; an empty key writes "none") and sets each
    /// action in `replacing` to none, in one write.
    func saveShortcut(_ shortcut: Shortcut, for name: String, replacing: [String] = []) async {
        var changes = [ConfigChange("shortcuts", name, entryValue(shortcut, for: name))]
        for other in replacing where other != name {
            changes.append(ConfigChange("shortcuts", other, entryValue(Shortcut(key: ""), for: other)))
        }
        await save(changes)
    }

    /// Restore Default: removes the entry.
    func restoreDefaultShortcut(_ name: String) async {
        await save([ConfigChange("shortcuts", name, nil)])
    }

    /// Restore All Defaults: removes the `shortcuts` key, unknown entries included.
    func restoreAllShortcuts() async {
        await save([ConfigChange("shortcuts", nil)])
    }

    private func entryValue(_ shortcut: Shortcut, for name: String) -> JSONValue? {
        shortcut == MainMenu.defaultShortcut(for: name) ? nil : .string(shortcut.configText)
    }

    private func shortcutIssues(_ config: PaddleConfig) -> [ConfigIssue] {
        ConfigValidator.issues(config, actionNames: Set(MainMenu.actionNames), defaults: MainMenu.validatorDefaults)
            .filter { $0.key == .shortcuts }
    }
}
