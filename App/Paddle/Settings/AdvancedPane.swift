import AppKit
import PaddleCore
import SwiftUI

/// Settings > Advanced: developer tools and user agents, then the file itself: keys Paddle ignores, problems in
/// values it reads, and Tidy for keys that only repeat a default.
struct AdvancedPane: View {
    let model: SettingsModel
    @State private var removal: Removal?
    @State private var tidyPaths: TidyList?
    @State private var newHost = ""
    @State private var newAgent = ""
    @State private var agentProblem: String?

    var body: some View {
        SettingsForm {
            developerSection
            siteAgentsSection
            fileSection
            unknownKeysSection
            issuesSection
        }
        .confirmationDialog(
            removal?.title ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { removal in
            Button(removal.button, role: .destructive) { Task { await model.reset(removal.path, basedOn: removal.base) } }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
        .sheet(item: $tidyPaths) { list in
            TidySheet(paths: list.paths) { Task { await model.tidy(list.paths, basedOn: list.base) } }
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section("Developer") {
            Toggle(isOn: Binding(
                get: { model.file.developerTools },
                set: { on in Task { await model.save([ConfigChange(PaddleConfig.CodingKeys.developerTools.rawValue, .bool(on))]) } }
            )) {
                Text("Developer tools")
                Text("Inspect Element and Safari's Develop menu. Open pages keep the setting they loaded with; extension pages pick up a change after a relaunch.")
            }
            .help("developerTools in config.json")

            DraftField(
                title: "User agent", value: model.file.userAgentSuffix, prompt: WebEnvironment.safariApplicationName, model: model
            ) { text, snapshot in
                await model.save([ConfigChange(PaddleConfig.CodingKeys.userAgentSuffix.rawValue, .string(text))], basedOn: snapshot)
            }
            .help("userAgentSuffix in config.json: replaces Version/… Safari/… at the end of the user agent. Empty matches the installed Safari. Tabs opened or woken afterwards use it.")
        }
        .disabled(model.controlsDisabled)
    }

    // MARK: - Site user agents

    private var siteAgentsSection: some View {
        Section {
            let agents = model.file.siteUserAgents
            ForEach(agents.keys.sorted(), id: \.self) { host in
                HStack(spacing: 8) {
                    DraftField(title: "Site", value: host, model: model, labelHidden: true) { text, snapshot in
                        let newHost = text.trimmingCharacters(in: .whitespaces)
                        guard !newHost.isEmpty, newHost != host else { return }
                        guard model.file.siteUserAgents[newHost] == nil else {
                            agentProblem = "\(newHost) already has a user agent; the rename wasn't saved."
                            return
                        }
                        agentProblem = nil
                        await model.setSiteUserAgent(host: newHost, agent: agents[host] ?? "", replacing: host, basedOn: snapshot)
                    }
                    .frame(width: 170)
                    .accessibilityLabel("Site")
                    DraftField(title: "User agent", value: agents[host] ?? "", model: model, labelHidden: true) { text, snapshot in
                        await model.setSiteUserAgent(host: host, agent: text, basedOn: snapshot)
                    }
                    .accessibilityLabel("User agent for \(host)")
                    Button {
                        Task { await model.setSiteUserAgent(host: host, agent: nil) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove user agent for \(host)")
                    .help("Removes siteUserAgents.\(host) from config.json")
                }
            }
            HStack(spacing: 8) {
                TextField("Site", text: $newHost, prompt: Text("example.com"))
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel("New site")
                TextField("User agent", text: $newAgent, prompt: Text("Mozilla/5.0 …"))
                    .labelsHidden()
                    .accessibilityLabel("User agent for the new site")
                    .onSubmit(addAgent)
                Button(action: addAgent) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty || newAgent.isEmpty)
                .accessibilityLabel("Add Site User Agent")
                .help("Adds an entry to siteUserAgents in config.json")
            }
            if let agentProblem {
                Label(agentProblem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Site User Agents")
        } footer: {
            Text("A full user agent for a site and its subdomains (siteUserAgents), used from its next load. \(Self.builtInAgents)")
                .foregroundStyle(.secondary)
        }
        .disabled(model.controlsDisabled)
    }

    /// Paddle's built-in fixes (`SiteCompat`), in words: whose user agent goes to which hosts, and how an entry here
    /// overrides them.
    private static var builtInAgents: String {
        let byPersona = Dictionary(grouping: SiteCompat.defaults, by: { $0.value.persona == .chrome ? "Chrome" : "Firefox" })
        let parts = byPersona.keys.sorted().map { name in
            "\(name)'s to \(byPersona[name, default: []].map(\.key).sorted().joined(separator: ", "))"
        }
        return "Built in: \(parts.joined(separator: "; ")), unless an entry here or a persona covers the host (an empty entry sends WebKit's own)."
    }

    private func addAgent() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !newAgent.isEmpty else { return }
        guard model.file.siteUserAgents[host] == nil else {
            agentProblem = "\(host) already has a user agent; edit its row instead."
            return
        }
        agentProblem = nil
        let agent = newAgent
        newHost = ""
        newAgent = ""
        Task { await model.setSiteUserAgent(host: host, agent: agent) }
    }

    // MARK: - The file

    private var fileSection: some View {
        Section("config.json") {
            HStack {
                Button("Edit config.json…") { SettingsBanner.editConfig() }
                    .help("Opens config.json in your editor. Settings notices the edit; Apply Now (or any change here) applies it.")
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.config]) }
                Button("Open Config Folder") { NSWorkspace.shared.open(Paths.support) }
                    .help("Opens the folder with config.json, user.css, user-filters.txt and userscripts/")
            }
            let paths = model.tidyPaths
            LabeledContent {
                Button("Tidy…") { tidyPaths = TidyList(paths: paths, base: model.base) }
                    .disabled(paths.isEmpty || model.controlsDisabled)
                    .help("Removes keys from config.json that hold their default value, after listing them")
            } label: {
                Text("Default-valued keys")
                Text(paths.isEmpty ? "None: every key in the file changes something." : "\(paths.count) \(paths.count == 1 ? "key repeats its" : "keys repeat their") default.")
            }
        }
    }

    @ViewBuilder private var unknownKeysSection: some View {
        let keys = model.unknownKeys
        if !keys.isEmpty {
            Section("Keys Paddle Ignores") {
                ForEach(keys, id: \.self) { key in
                    LabeledContent {
                        Button("Remove…") {
                            removal = Removal(
                                path: [key], base: model.base, title: "Remove \(key) from config.json?", button: "Remove \(key)",
                                message: "Removes \"\(key)\": \(model.writtenValue(of: key) ?? "…") from config.json. Paddle doesn't read this key, so nothing else changes."
                            )
                        }
                        .disabled(model.controlsDisabled)
                        .help("Removes \(key) from config.json")
                    } label: {
                        Label {
                            Text(key).monospaced()
                            Text("Not a Paddle setting, probably a typo; it has no effect.")
                        } icon: {
                            Image(systemName: "questionmark.circle")
                                .accessibilityLabel("Unknown key")
                        }
                    }
                }
            }
        }
    }

    private var issuesSection: some View {
        Section("Problems") {
            let issues = model.issues
            if issues.isEmpty {
                Label("No problems found in config.json's values.", systemImage: "checkmark.circle")
            }
            ForEach(issues) { issue in
                let name = issue.path.joined(separator: ".")
                LabeledContent {
                    if let path = SettingsModel.resetPath(for: issue) {
                        let whole = path.count == 1
                        Button(whole ? "Reset…" : "Remove…") {
                            removal = Removal(
                                path: path,
                                base: model.base,
                                title: whole ? "Reset \(name) to its default?" : "Remove \(name)?",
                                button: whole ? "Reset \(name)" : "Remove \(name)",
                                message: whole
                                    ? "Removes \"\(name)\" from config.json, so Paddle uses the default. Nothing else in the file changes."
                                    : "Removes this entry from \(path[0]) in config.json. Nothing else in the file changes."
                            )
                        }
                        .disabled(model.controlsDisabled)
                        .help("Removes \(name) from config.json")
                    }
                } label: {
                    Label {
                        Text(name).monospaced()
                        Text(issue.message)
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .accessibilityLabel(issue.severity == .error ? "Error" : "Warning")
                    }
                }
            }
        }
    }
}

/// A destructive single-path removal waiting for confirmation (an unknown key, or an issue's key or entry).
private struct Removal {
    var path: [String]
    /// `model.base` when the button was clicked: the write is checked against it, so a hand edit made while the
    /// dialog is open raises the conflict banner instead of being removed.
    var base: Data
    var title: String
    var button: String
    var message: String
}

private struct TidyList: Identifiable {
    let id = UUID()
    var paths: [[String]]
    /// `model.base` the list was computed from (see `Removal.base`).
    var base: Data
}

/// The Tidy confirmation: every key it will remove, before anything is written.
private struct TidySheet: View {
    let paths: [[String]]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(paths.count) default-valued \(paths.count == 1 ? "key" : "keys") from config.json?")
                .font(.headline)
            Text("Each holds the value Paddle uses anyway, so nothing changes in how Paddle runs. Every other byte of the file stays as it is.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paths, id: \.self) { path in
                        Text(path.joined(separator: ".")).monospaced()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .accessibilityLabel("Keys to remove")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(paths.count) \(paths.count == 1 ? "Key" : "Keys")", role: .destructive) {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// A text field over one config value that saves on Return or when focus leaves. While the user types it keeps
/// the `base` the edit started from, so a hand edit to the same key meanwhile is reported as a conflict instead of
/// being overwritten; when not being edited it shows the file's current value.
private struct DraftField: View {
    let title: String
    let value: String
    var prompt: String?
    let model: SettingsModel
    var labelHidden = false
    let commit: @MainActor (String, Data) async -> Void

    init(
        title: String, value: String, prompt: String? = nil, model: SettingsModel, labelHidden: Bool = false,
        commit: @escaping @MainActor (String, Data) async -> Void
    ) {
        self.title = title
        self.value = value
        self.prompt = prompt
        self.model = model
        self.labelHidden = labelHidden
        self.commit = commit
    }

    @State private var text = ""
    /// The base bytes when typing started; nil while the field just mirrors `value`.
    @State private var snapshot: Data?
    @FocusState private var focused: Bool

    var body: some View {
        let field = TextField(title, text: Binding(
            get: { snapshot == nil ? value : text },
            set: { new in
                if snapshot == nil { snapshot = model.base }
                text = new
            }
        ), prompt: prompt.map { Text($0) })
        .focused($focused)
        .onSubmit(save)
        .onChange(of: focused) { if !focused { save() } }
        if labelHidden { field.labelsHidden() } else { field }
    }

    private func save() {
        guard let base = snapshot else { return }
        snapshot = nil
        let new = text
        guard new != value else { return }
        Task { await commit(new, base) }
    }
}
