import AppKit
import PaddleCore
import SwiftUI

/// Settings > Extensions: every folder in `extensions/`, running or not, as one row each (icon, name, version and status,
/// and the `extensions` load switch). Each row's Details disclosure, collapsed by default and remembered per folder for
/// this session only, holds the folder, memory, answers, the `extensionCompat` `private` switch for private windows,
/// compatibility notes and the folder actions. Also `extensionsInPrivate`, and the folder and reload actions. Memory is
/// measured every 5 s only while the pane is shown.
struct ExtensionsPane: View {
    let model: SettingsModel
    @State private var memory = ExtensionMemory()
    /// Folders with a save, Ask Again or reload in flight (prompts included); "" is the whole folder.
    @State private var busy: Set<String> = []
    /// Folders whose Details disclosure is open. Not persisted.
    @State private var expanded: Set<String> = []

    private var host: ExtensionHost { AppModel.shared.extensions }

    var body: some View {
        // Read so the list redraws when a load, reconcile or reload finishes.
        let _ = host.statusLines
        let summaries = host.folderSummaries
        SettingsForm {
            if summaries.isEmpty {
                Section("Extensions") {
                    Text("No extensions. Put each unpacked extension in its own folder in the extensions folder, then Reload Extensions.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(summaries) { summary in
                Section {
                    row(summary)
                    SettingsDisclosure(
                        title: "Details", isExpanded: isExpanded(summary.folder),
                        accessibilityLabel: "Details for \(summary.displayName)"
                    ) {
                        details(summary)
                    }
                }
            }
            Section {
                Toggle("Allow extensions in private windows", isOn: Binding(
                    get: { model.file.extensionsInPrivate },
                    set: { on in run("") { await model.setExtensionsInPrivate(on) } }
                ))
                .help("extensionsInPrivate in config.json")
                Text("Applies to private windows opened afterwards; turning it off also removes extensions from private windows already open. Each extension's own switch under Details overrides this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.controlsDisabled)
            Section {
                LabeledContent("Extension pages' memory") {
                    Text(memory.total > 0 ? ProcessMemory.format(memory.total) : "None open now")
                }
                .help("The Extensions row of the Activity popover: processes running only extension pages.")
                HStack {
                    Button("Open Extensions Folder") { NSWorkspace.shared.open(Paths.extensions) }
                    Button("Reload Extensions") {
                        run("") {
                            await host.reloadAll(config: AppModel.shared.config)
                            AccessibilityNotification.Announcement("Extensions reloaded").post()
                        }
                    }
                    .help("Unloads every extension and loads the folder again, edited files included.")
                    .disabled(!busy.isEmpty)
                    if !busy.isEmpty {
                        ProgressView().controlSize(.small).accessibilityLabel("Working")
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                memory = ExtensionMemory.sample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The always-visible line: icon, name, "Version X · status" and the load switch on the right.
    @ViewBuilder private func row(_ summary: ExtensionFolderSummary) -> some View {
        let enabled = model.file.isExtensionEnabled(summary.folder)
        let state = status(summary, enabled: enabled)
        HStack(spacing: 10) {
            icon(summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName).font(.headline)
                HStack(spacing: 4) {
                    if !summary.version.isEmpty { Text("Version \(summary.version) ·") }
                    Label(state.text, systemImage: state.symbol)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(state.text)
            }
            Spacer(minLength: 8)
            Toggle("Load \(summary.displayName)", isOn: Binding(
                get: { enabled },
                set: { on in run(summary.folder) { await model.setExtension(summary.folder, enabled: on) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Load \(summary.displayName)")
            .help("extensions.\(summary.folder) in config.json: false turns it off; on removes the entry.")
            .disabled(model.controlsDisabled || busy.contains(summary.folder))
        }
    }

    /// Everything else for one folder, shown under its Details disclosure.
    @ViewBuilder private func details(_ summary: ExtensionFolderSummary) -> some View {
        let enabled = model.file.isExtensionEnabled(summary.folder)
        LabeledContent("Folder") { Text(summary.folder) }

        if summary.isLoaded {
            LabeledContent("Memory") { Text(memoryText(summary.folder)) }
        }

        LabeledContent("Access") {
            VStack(alignment: .trailing, spacing: 2) {
                switch summary.access {
                case .notAsked: Text("Not asked yet")
                case .unreadable: Label("Permissions file unreadable", systemImage: "exclamationmark.triangle")
                case .declined: Text("Not allowed to run")
                case .allowed(let lines): ForEach(lines, id: \.self) { Text($0) }
                }
            }
            .multilineTextAlignment(.trailing)
        }

        Toggle("Allow in private windows", isOn: Binding(
            get: { model.file.extensionAllowedInPrivate(folder: summary.folder) },
            set: { on in run(summary.folder) { await model.setExtensionInPrivate(summary.folder, on) } }
        ))
        .help("extensionCompat.\(summary.folder).private in config.json; unset follows extensionsInPrivate")
        .disabled(model.controlsDisabled || busy.contains(summary.folder))

        Picker("Toolbar button", selection: Binding(
            get: { model.file.toolbarPlacement(folder: summary.folder) },
            set: { placement in run(summary.folder) { await model.setToolbarPlacement(summary.folder, placement) } }
        )) {
            Text("On the toolbar").tag(ExtensionToolbarPlacement.pinned)
            Text("In the Extensions menu").tag(ExtensionToolbarPlacement.menu)
            Text("Hidden").tag(ExtensionToolbarPlacement.hidden)
        }
        .pickerStyle(.menu)
        .help("extensionToolbar.\(summary.folder) in config.json")
        .disabled(model.controlsDisabled || busy.contains(summary.folder))

        if !summary.compatNotes.isEmpty {
            LabeledContent("Compatibility") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(summary.compatNotes, id: \.self) { Text($0) }
                }
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            }
        }

        HStack {
            Button("Ask About Permissions Again") {
                run(summary.folder) { await host.askAgain(folder: summary.folder) }
            }
            .disabled(!enabled || summary.root == nil || summary.access == .unreadable || busy.contains(summary.folder))
            .help(summary.access == .unreadable
                ? "extension-permissions.json can't be read; fix or delete it first."
                : "Forgets your answers in extension-permissions.json for this extension and asks again.")
            if summary.hasOptionsPage {
                Button("Options…") {
                    guard let ext = host.loaded.first(where: { $0.name == summary.folder }) else { return }
                    try? host.openOptionsPage(for: ext.context)
                }
            }
            Spacer()
            Button("Reveal Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.root ?? Paths.extensions.appendingPathComponent(summary.folder)])
            }
        }
    }

    @ViewBuilder private func icon(_ summary: ExtensionFolderSummary) -> some View {
        let size = CGSize(width: 32, height: 32)
        if let image = host.loaded.first(where: { $0.name == summary.folder })?.webExtension.icon(for: size) {
            Image(nsImage: image).resizable().frame(width: size.width, height: size.height).accessibilityHidden(true)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        }
    }

    /// The status line as an icon plus words, never colour alone.
    private func status(_ summary: ExtensionFolderSummary, enabled: Bool) -> (text: String, symbol: String) {
        if summary.isLoaded { return (enabled ? "Running" : "Running (turning off)", "checkmark.circle") }
        if !enabled { return ("Off", "pause.circle") }
        if summary.access == .declined { return ("Not running: permissions declined", "hand.raised") }
        return (summary.status, "exclamationmark.triangle")
    }

    /// Whether one folder's Details disclosure is open.
    private func isExpanded(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(folder) },
            set: { on in
                if on { expanded.insert(folder) } else { expanded.remove(folder) }
            }
        )
    }

    private func memoryText(_ folder: String) -> String {
        guard let process = memory.byFolder[folder] else { return "Not measured (no background page running)" }
        let bytes = ProcessMemory.format(process.bytes)
        if process.sharedWith.isEmpty { return "\(bytes), background page" }
        return "\(bytes), a process shared with \(process.sharedWith.joined(separator: ", "))"
    }

    /// Runs `work` with `key` marked busy, so its controls stay off until it (and any prompt) is done.
    private func run(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        busy.insert(key)
        Task {
            await work()
            busy.remove(key)
        }
    }
}
