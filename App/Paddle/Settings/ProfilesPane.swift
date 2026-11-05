import PaddleCore
import SwiftUI

/// Settings > Profiles: add, rename, change the symbol of, open a window in, and delete profiles, and each profile's
/// own settings (`ProfileOverrides`): what it sets differently from config.json, with the global value beside it.
/// The list is profiles.json (`AppModel.profiles`), not config.json.
struct ProfilesPane: View {
    let model: SettingsModel
    @State private var pendingDelete: Profile?
    @State private var deleteFailed = false
    @State private var addingSite: Profile?
    @FocusState private var focused: String?

    private var store: ProfileStore { AppModel.shared.profiles }

    var body: some View {
        SettingsForm(maxColumns: 1, minColumnWidth: 520) {
            if let error = store.loadError {
                Section {
                    Text("\(error). Paddle leaves the file alone until it is fixed.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.all, id: \.id) { profile in
                Section {
                    ProfileOverrideRows(profile: profile)
                    AddOverrideMenu(profile: profile) { addingSite = profile }
                        .disabled(store.loadError != nil)
                } header: {
                    ProfileRow(profile: profile, focused: $focused) { pendingDelete = profile }
                } footer: {
                    if let problems = AppModel.shared.profileConfigProblems[profile.id], !problems.isEmpty {
                        SettingsCaption(problems.joined(separator: "\n"))
                    }
                }
            }
            Section {
                Button("Add Profile", systemImage: "plus") { add() }
                    .disabled(store.loadError != nil)
                SettingsLearnMore(
                    summary: "Each profile keeps its own cookies, history, extensions and overrides; bookmarks and block lists are shared.",
                    detail: "Settings come from config.json; a profile can override search, pages, downloads, theme, tab sleep timers and per-site permissions. Tabs can't move between profiles."
                )
            }
        }
        .sheet(item: $addingSite) { profile in
            AddSiteOverrideSheet(profile: profile) { addingSite = nil }
        }
        .alert(
            pendingDelete.map { "Delete the profile \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                Task { deleteFailed = !(await store.delete(id: profile.id)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its cookies, logins, site data, history and own settings are deleted, and its windows close.")
        }
        .alert("The profile could not be deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("WebKit could not remove its site data. The profile is kept; try again.")
        }
    }

    private func add() {
        let used = Set(store.all.map(\.symbol))
        let symbol = ProfileSymbol.allCases.first { !used.contains($0) } ?? .person
        guard let profile = store.add(name: "New Profile", symbol: symbol) else { return }
        // On the next turn: the new row's field doesn't exist until SwiftUI has drawn it.
        Task { @MainActor in focused = profile.id }
    }
}

/// One profile's header: symbol, editable name, symbol picker, Open Window and Delete…
private struct ProfileRow: View {
    let profile: Profile
    var focused: FocusState<String?>.Binding
    let onDelete: () -> Void
    @State private var name = ""

    private var store: ProfileStore { AppModel.shared.profiles }

    var body: some View {
        // On one line when the card is wide enough, else the buttons under the name.
        ViewThatFits(in: .horizontal) {
            HStack {
                identity
                Spacer()
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { identity }
                HStack { buttons }
            }
        }
        .textCase(nil)
        .foregroundStyle(.primary)
        .padding(.bottom, 4)
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { name = profile.name }
        .onChange(of: focused.wrappedValue) { old, new in
            if old == profile.id, new != profile.id { commit() }
        }
    }

    @ViewBuilder private var identity: some View {
        Image(systemName: profile.symbol.sfSymbol)
            .frame(width: 20)
            .accessibilityHidden(true)
        TextField("Name", text: $name)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.headline)
            .frame(minWidth: 140, maxWidth: 220)
            .focused(focused, equals: profile.id)
            .onSubmit(commit)
            .accessibilityLabel("Profile name")
            .help("The profile's name, saved when you press Return or leave the field. Two profiles can't share a name.")
        Picker("Symbol", selection: Binding(
            get: { profile.symbol },
            set: { store.setSymbol($0, for: profile.id) }
        )) {
            ForEach(ProfileSymbol.allCases, id: \.self) { symbol in
                Label(symbol.displayName, systemImage: symbol.sfSymbol).tag(symbol)
            }
        }
        .labelsHidden()
        .frame(width: 130)
    }

    @ViewBuilder private var buttons: some View {
        Button("Open Window") { AppModel.shared.openWindow(profile: profile.id) }
        if !profile.isDefault {
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    /// Saves the typed name; one the store refuses (empty, or another profile's) goes back to the saved name.
    private func commit() {
        guard name != profile.name else { return }
        if !store.rename(id: profile.id, to: name) { name = profile.name }
    }
}

/// The profile's own settings, one row each, or a line saying it uses config.json for everything.
private struct ProfileOverrideRows: View {
    let profile: Profile

    var body: some View {
        let entries = ProfileOverrides.entries(profile.settings)
        if entries.isEmpty {
            Text("Uses the global settings (config.json) for everything.")
                .foregroundStyle(.secondary)
        }
        ForEach(entries, id: \.path) { entry in
            OverrideRow(profile: profile, path: entry.path, value: entry.value)
        }
    }
}

/// One override: its name and the global value, an editor for the profile's value, and Remove.
private struct OverrideRow: View {
    let profile: Profile
    let path: [String]
    let value: JSONValue

    private var setting: ProfileOverrides.Setting? {
        path.count == 1 ? ProfileOverrides.setting(key: path[0]) : ProfileOverrides.siteSetting(field: path[2])
    }

    private var title: String {
        guard let setting else { return path.joined(separator: ".") }
        return path.count == 3 ? "\(path[1]): \(setting.title)" : setting.title
    }

    /// config.json's value in words; a theme by its name rather than its id.
    private func globalText(_ kind: ProfileOverrides.Kind) -> String {
        let global = ProfileOverrides.value(at: path, in: AppModel.shared.config)
        if kind == .theme, case .string(let id)? = global {
            return id == "default" ? "Default" : AppModel.shared.themes.theme(id: id)?.name ?? id
        }
        return ProfileOverrides.describe(global, as: kind)
    }

    var body: some View {
        if let setting {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text("Global: \(globalText(setting.kind))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                OverrideEditor(kind: setting.kind, title: title, value: value) { new in
                    AppModel.shared.profiles.setOverride(path, to: new, for: profile.id)
                }
                Button {
                    AppModel.shared.profiles.setOverride(path, to: nil, for: profile.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove: \(profile.name) uses the global value again")
                .accessibilityLabel("Remove \(title) override")
            }
            .help(path.joined(separator: ".") + " in profiles.json")
        }
    }
}

/// The control for one override's value, by its kind. Text and numbers save on Return or when the field loses focus.
private struct OverrideEditor: View {
    let kind: ProfileOverrides.Kind
    let title: String
    let value: JSONValue
    let save: (JSONValue) -> Void
    @State private var text = ""
    @State private var number: Double = 0
    @FocusState private var focused: Bool

    var body: some View {
        editor
            .onAppear(perform: load)
            .onChange(of: value) { load() }
    }

    @ViewBuilder private var editor: some View {
        switch kind {
        case .toggle:
            Toggle(title, isOn: Binding(
                get: { if case .bool(let on) = value { on } else { false } },
                set: { save(.bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        case .number(let range, let step, let zero, let unit):
            HStack(spacing: 4) {
                TextField(title, value: $number, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($focused)
                    .onSubmit { commitNumber(range, step: step) }
                    .onChange(of: focused) { _, now in if !now { commitNumber(range, step: step) } }
                Stepper(title, value: Binding(get: { number }, set: { number = $0; commitNumber(range, step: step) }), in: range, step: step)
                    .labelsHidden()
                Text(number == 0 && zero != nil ? zero! : unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .leading)
            }
        case .text(let placeholder, let presets):
            HStack(spacing: 4) {
                TextField(title, text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .frame(minWidth: 180, maxWidth: 260)
                    .focused($focused)
                    .onSubmit { save(.string(text)) }
                    .onChange(of: focused) { _, now in if !now, .string(text) != value { save(.string(text)) } }
                if !presets.isEmpty {
                    Menu {
                        ForEach(presets, id: \.self) { preset in
                            Button(preset.label) { save(.string(preset.value)) }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a value")
                    .accessibilityLabel("Choose \(title)")
                }
            }
        case .choice(let choices):
            Picker(title, selection: Binding(get: { stringValue }, set: { save(.string($0)) })) {
                ForEach(choices, id: \.self) { Text($0.label).tag($0.value) }
                if !choices.contains(where: { $0.value == stringValue }) { Text(stringValue).tag(stringValue) }
            }
            .labelsHidden()
            .fixedSize()
        case .theme:
            let themes = AppModel.shared.themes.available
            Picker(title, selection: Binding(get: { stringValue }, set: { save(.string($0)) })) {
                Text("Default").tag("default")
                ForEach(themes) { Text($0.name).tag($0.id) }
                if stringValue != "default", !themes.contains(where: { $0.id == stringValue }) {
                    Text("\(stringValue) (missing)").tag(stringValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .color(let automatic):
            colorEditor(automatic: automatic)
        }
    }

    private var stringValue: String { if case .string(let text) = value { text } else { "" } }

    @ViewBuilder private func colorEditor(automatic: String) -> some View {
        let choice = ColorChoice(configValue: stringValue, automaticValue: automatic) ?? .automatic
        let tag: String = switch choice {
        case .automatic: "automatic"
        case .preset(let preset): preset.rawValue
        case .custom: "custom"
        }
        HStack(spacing: 4) {
            Picker(title, selection: Binding(get: { tag }, set: { new in
                let next: ColorChoice = if new == "automatic" {
                    .automatic
                } else if let preset = ColorPreset(rawValue: new) {
                    .preset(preset)
                } else {
                    .custom(choice.color ?? ColorPreset.blue.color)
                }
                save(.string(next.configValue(automaticValue: automatic)))
            })) {
                Text("Automatic").tag("automatic")
                ForEach(ColorPreset.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                Text("Custom").tag("custom")
            }
            .labelsHidden()
            .fixedSize()
            if case .custom(let color) = choice {
                CustomColorWell(title: title, saved: color) { save(.string($0)) }
            }
        }
    }

    private func load() {
        switch value {
        case .string(let string): text = string
        case .number(let value): number = value
        default: break
        }
    }

    /// Whole-number settings (days, minutes, percent: a step of 1 or more) round, so 7.5 days isn't a wrong-typed value.
    private func commitNumber(_ range: ClosedRange<Double>, step: Double) {
        let whole = step >= 1 ? number.rounded() : number
        let clamped = min(max(whole, range.lowerBound), range.upperBound)
        number = clamped
        if .number(clamped) != value { save(.number(clamped)) }
    }
}

/// Add Setting: the settings this profile doesn't set yet, by pane, each starting at the global value; and a site
/// setting, which asks for the site first.
private struct AddOverrideMenu: View {
    let profile: Profile
    let addSite: () -> Void

    var body: some View {
        let unset = ProfileOverrides.settings.filter { profile.settings[$0.key] == nil }
        let groups = Dictionary(grouping: unset, by: \.group)
        Menu("Add Setting", systemImage: "plus") {
            ForEach(["General", "Appearance", "Tabs & Memory"], id: \.self) { group in
                if let settings = groups[group] {
                    Section(group) {
                        ForEach(settings) { setting in
                            Button(setting.title) {
                                guard let global = ProfileOverrides.value(at: [setting.key], in: AppModel.shared.config) else { return }
                                AppModel.shared.profiles.setOverride([setting.key], to: global, for: profile.id)
                            }
                        }
                    }
                }
            }
            Section("Sites") {
                Button("Site Setting…", action: addSite)
            }
        }
        .fixedSize()
        .help("Give \(profile.name) its own value for a setting; it starts at the global value")
    }
}

/// A site override: the site (a host suffix, as in Settings > Sites) and the field; it starts at the global value.
private struct AddSiteOverrideSheet: View {
    let profile: Profile
    let done: () -> Void
    @State private var host = ""
    @State private var field = ProfileOverrides.siteSettings[0].key

    private var normalized: String { PaddleConfig.normalizedHost(host.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        Form {
            Text("Site setting for \(profile.name)").font(.headline)
            TextField("Site", text: $host, prompt: Text("example.com"))
            Picker("Setting", selection: $field) {
                ForEach(ProfileOverrides.siteSettings) { Text($0.title).tag($0.key) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let path = [ProfileOverrides.sitesKey, normalized, field]
                    if let global = ProfileOverrides.value(at: path, in: AppModel.shared.config) {
                        AppModel.shared.profiles.setOverride(path, to: global, for: profile.id)
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalized.isEmpty || normalized.contains(" "))
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
