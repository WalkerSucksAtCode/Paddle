import PaddleCore
import SwiftUI

/// Settings > Shortcuts: every menu command with its default and current shortcut and a recorder (`shortcuts`).
/// A clash with another menu item, a hidden second shortcut or a running extension's command is shown before
/// anything is saved. Fixed height; the table scrolls.
struct ShortcutsPane: View {
    let model: SettingsModel
    @State private var search = ""
    @State private var pending: PendingShortcut?
    @State private var confirmingRestoreAll = false

    private struct PendingShortcut {
        let row: ShortcutRow
        let shortcut: Shortcut
        let conflicts: ShortcutConflicts
    }

    var body: some View {
        let rows = model.shortcutRows
        let shown = search.isEmpty ? rows : rows.filter { row in
            [row.title, row.name, row.menu, row.current.displayText].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        let unknown = model.unknownShortcutEntries
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search commands", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Search commands")
                Spacer()
                Button("Restore All Defaults…") { confirmingRestoreAll = true }
                    .disabled(model.file.shortcuts.isEmpty)
                    .help("Removes the shortcuts key from config.json.")
            }

            Table(shown) {
                TableColumn("Command") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                        caption(row)
                    }
                    .accessibilityElement(children: .combine)
                }
                TableColumn("Default") { row in
                    Text(defaultText(row))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Default: " + ([row.defaultShortcut] + row.aliases).map(\.spokenText).joined(separator: ", or "))
                }
                .width(min: 80, ideal: 110)
                TableColumn("Shortcut") { row in
                    ShortcutRecorder(shortcut: row.current, title: row.title) { recorded in
                        propose(recorded, for: row)
                    }
                    .help("shortcuts.\(row.name) in config.json")
                }
                .width(min: 120, ideal: 130)
                TableColumn("") { row in
                    Button {
                        Task { await model.restoreDefaultShortcut(row.name) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!row.isCustom)
                    .accessibilityLabel("Restore Default Shortcut for \(row.title)")
                    .help(row.isCustom ? "Restore the default (removes shortcuts.\(row.name))" : "Already the default")
                }
                .width(28)
            }
            .accessibilityLabel("Menu shortcuts")

            if !unknown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not understood in config.json (bind nothing):", systemImage: "questionmark.circle")
                    ForEach(unknown, id: \.name) { entry in
                        HStack {
                            Text("\"\(entry.name)\": \"\(entry.text)\"").font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { Task { await model.save([ConfigChange("shortcuts", entry.name, nil)]) } }
                                .accessibilityLabel("Remove \(entry.name) from shortcuts")
                        }
                    }
                }
            }

            Text("Click a shortcut, or select it and press Space, then type the new one. Escape cancels; Delete sets none. Saved to shortcuts in config.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .disabled(model.controlsDisabled)
        .confirmationDialog(
            pending.map { "\($0.shortcut.displayText) is already in use" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button("Use Anyway") { save(pending, replacing: []) }
            if !pending.conflicts.replaceable.isEmpty {
                Button("Replace") { save(pending, replacing: pending.conflicts.replaceable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(conflictMessage(pending))
        }
        .confirmationDialog("Restore every shortcut to its default?", isPresented: $confirmingRestoreAll) {
            Button("Restore All Defaults", role: .destructive) { Task { await model.restoreAllShortcuts() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the shortcuts key from config.json (\(model.file.shortcuts.count) entr\(model.file.shortcuts.count == 1 ? "y" : "ies")). Nothing else in the file changes.")
        }
    }

    /// The line under a command: what's wrong with its entry (icon plus words), else its menu and action name.
    @ViewBuilder private func caption(_ row: ShortcutRow) -> some View {
        if let text = row.notUnderstood {
            Label("Not understood: \"\(text)\"; the default applies", systemImage: "exclamationmark.triangle")
                .font(.caption)
        } else if let issue = row.issues.first {
            Label(issue, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .help(row.issues.joined(separator: "\n"))
        } else {
            Text("\(row.menu) · \(row.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func defaultText(_ row: ShortcutRow) -> String {
        let main = row.defaultShortcut.key.isEmpty ? "None" : row.defaultShortcut.displayText
        guard !row.aliases.isEmpty else { return main }
        return main + " or " + row.aliases.map(\.displayText).joined(separator: " or ")
    }

    /// Saves at once unless the shortcut clashes; then the sheet asks first.
    private func propose(_ shortcut: Shortcut, for row: ShortcutRow) {
        guard shortcut != row.current || row.notUnderstood != nil else { return }
        let conflicts = model.shortcutConflicts(shortcut, for: row.name)
        if conflicts.isEmpty {
            Task { await model.saveShortcut(shortcut, for: row.name) }
        } else {
            pending = PendingShortcut(row: row, shortcut: shortcut, conflicts: conflicts)
        }
    }

    private func save(_ pending: PendingShortcut, replacing: [String]) {
        Task { await model.saveShortcut(pending.shortcut, for: pending.row.name, replacing: replacing) }
    }

    private func conflictMessage(_ pending: PendingShortcut) -> String {
        var lines: [String] = []
        let conflicts = pending.conflicts
        if !conflicts.menuItems.isEmpty {
            let titles = conflicts.menuItems.map { item in
                item.name == nil ? "\(item.title) (its second shortcut)" : item.title
            }
            lines.append("It is used by \(titles.joined(separator: ", ")). Only one command can respond to it.")
            if conflicts.replaceable.isEmpty {
                lines.append("A second shortcut can't be removed here.")
            } else {
                lines.append("Replace sets \(conflicts.replaceable.joined(separator: ", ")) to none.")
            }
        } else {
            lines += conflicts.fileWarnings
        }
        if !conflicts.extensionCommands.isEmpty {
            lines.append("Extension commands on this key (Paddle's menu keeps it): \(conflicts.extensionCommands.joined(separator: ", ")).")
        }
        return "Set \(pending.row.title) to \(pending.shortcut.displayText)? " + lines.joined(separator: " ")
    }
}
