import AppKit
import PaddleCore
import SwiftUI

/// Settings > Extensions: one row per folder in `extensions/` (icon, name, version, status, load
/// switch). Details (collapsed, remembered per folder this session) holds the folder, memory,
/// answers, `extensionCompat.private`, compatibility notes and folder actions. Also
/// `extensionsInPrivate` and folder/reload actions. Memory sampled every 5 s only while shown.
/// Follows the window's profile: default switches are config.json, others are profiles.json;
/// private-window switches only on the default profile (the one private windows run).
struct ExtensionsPane: View {
    let model: SettingsModel
    @State private var memory = ExtensionMemory()
    /// Folders with a save, Ask Again or reload in flight (prompts included); "" is the whole folder.
    @State private var busy: Set<String> = []
    /// Folders whose Details disclosure is open. Not persisted.
    @State private var expanded: Set<String> = []

    /// The profile of the window this Settings tab is in.
    private var profileID: ProfileID { model.profileID }
    private var isDefaultProfile: Bool { profileID == ProfileStore.defaultID }
    private var host: ExtensionHost { AppModel.shared.extensions(for: profileID) ?? AppModel.shared.extensions }

    var body: some View {
        // Read so the list redraws when a load, reconcile or reload finishes.
        let _ = host.statusLines
        let summaries = host.folderSummaries
        let profiles = AppModel.shared.profiles
        SettingsForm {
            if profiles.hasSeveral {
                let profile = profiles.profile(id: profileID)
                Section {
                    Label("Extensions in \(profile.name)", systemImage: profile.symbol.sfSymbol)
                        .font(.headline)
                    Text(isDefaultProfile
                        ? "These switches apply to this profile only. Another profile starts with no extensions; open Settings from one of its windows to choose them. Each profile keeps its own extension data, sign-ins and permission answers."
                        : "These switches apply to this profile only and are saved in profiles.json. Each profile keeps its own extension data, sign-ins and permission answers. Private windows use the extensions of \(profiles.profile(id: ProfileStore.defaultID).name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            if isDefaultProfile {
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
            }
            Section {
                LabeledContent("Extension pages' memory") {
                    Text(memory.total > 0 ? ProcessMemory.format(memory.total) : "None open now")
                }
                .help("The Extensions row of the Activity popover: processes running only extension pages.")
                HStack {
                    Button("Open Extensions Folder") { NSWorkspace.shared.open(Paths.extensions) }
                    Button("Reload Extensions") {
                        // Every profile's, and announced.
                        run("") { await AppModel.shared.reloadExtensions() }
                    }
                    .help("Unloads every extension, in every profile, and loads the folder again, edited files included.")
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
        let enabled = isEnabled(summary.folder)
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
                set: { [profileID] on in run(summary.folder) { await model.setExtension(summary.folder, enabled: on, profile: profileID) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Load \(summary.displayName)")
            .help(isDefaultProfile
                ? "extensions.\(summary.folder) in config.json: false turns it off; on removes the entry."
                : "This profile's extensions in profiles.json: on runs it in this profile only.")
            .disabled(model.controlsDisabled || busy.contains(summary.folder))
        }
    }

    /// Everything else for one folder, shown under its Details disclosure.
    @ViewBuilder private func details(_ summary: ExtensionFolderSummary) -> some View {
        let enabled = isEnabled(summary.folder)
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

        if isDefaultProfile {
            Toggle("Allow in private windows", isOn: Binding(
                get: { model.file.extensionAllowedInPrivate(folder: summary.folder) },
                set: { on in run(summary.folder) { await model.setExtensionInPrivate(summary.folder, on) } }
            ))
            .help("extensionCompat.\(summary.folder).private in config.json; unset follows extensionsInPrivate")
            .disabled(model.controlsDisabled || busy.contains(summary.folder))
        }

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
        let root = summary.root ?? Paths.extensions.appendingPathComponent(summary.folder, isDirectory: true)
        if let image = host.loaded.first(where: { $0.name == summary.folder })?.icon(side: 32)
            ?? LoadedExtension.icon(in: root, side: 32) {
            Image(nsImage: image).resizable().frame(width: size.width, height: size.height).accessibilityHidden(true)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        }
    }

    /// Whether the folder runs in this pane's profile (config.json for the default profile, profiles.json otherwise).
    private func isEnabled(_ folder: String) -> Bool {
        host.isEnabled(folder, config: model.file)
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
