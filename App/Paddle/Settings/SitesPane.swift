import PaddleCore
import SwiftUI

/// Settings > Sites: a row per host with a `sites` or `siteUserAgents` entry (zoom, JavaScript,
/// autoplay, blocking, location, notifications, user agent); Add Site / Add Current Site / Remove
/// Site, Clear Data, and "This session" (this-run answers, Forget per host). Fixed height; the table
/// scrolls. While config.json can't be read, only the config edits are off: Clear Data and Forget
/// don't touch the file.
struct SitesPane: View {
    let model: SettingsModel
    @State private var search = ""
    @State private var newSite = ""
    @State private var addIssues: [ConfigIssue] = []
    @State private var selection: String?
    @State private var clearing: String?
    @State private var isClearing = false
    /// The outcome of the last Clear Data or a refused change, shown under the table.
    @State private var status: String?
    /// The row whose custom user agent is being typed, and the text so far.
    @State private var editingAgent: SiteRow?
    @State private var agentText = ""
    @State private var moreSite: SiteRow?

    /// Zoom levels the picker offers (percent); a value set by hand or with Zoom In / Out is added to them.
    private static let zoomLevels = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300]

    var body: some View {
        let rows = model.siteRows
        let shown = search.isEmpty ? rows : rows.filter { $0.key.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Site", text: $newSite, prompt: Text("example.com"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .accessibilityLabel("New site")
                    .onSubmit { addSite(newSite) }
                Button("Add Site") { addSite(newSite) }
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Adds an entry to sites in config.json. It covers the host's subdomains too.")
                Button("Add Current Site") {
                    if let host = model.currentSiteHost {
                        addSite(host)
                    } else {
                        status = "The front window has no website open."
                    }
                }
                .help("Adds the site of the front window's page (private windows aside).")
                Spacer()
                TextField("Search sites", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Search sites")
            }
            .disabled(model.controlsDisabled)
            ConfigIssueList(issues: addIssues)

            Table(shown, selection: $selection) {
                TableColumn("Site") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.key)
                        if let issue = row.issues.first {
                            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .font(.caption)
                                .help(row.issues.map(\.message).joined(separator: "\n"))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .help(row.key)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Zoom") { row in zoomPicker(row) }
                    .width(80)
                TableColumn("Dark mode") { row in darkModePicker(row) }
                    .width(88)
                TableColumn("JavaScript") { row in
                    toggle(row, .javaScript, isOn: row.policy.javaScript, label: "JavaScript")
                }
                .width(70)
                TableColumn("Blocking") { row in blockingToggle(row) }
                    .width(58)
                TableColumn("Autoplay") { row in autoplayPicker(row) }
                    .width(84)
                TableColumn("Location") { row in locationPicker(row) }
                    .width(74)
                TableColumn("Notifications") { row in notificationsPicker(row) }
                    .width(92)
                TableColumn("") { row in
                    Button("More…") { moreSite = row }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("More settings for \(row.key)")
                }
                .width(52)
            }
            // No striped placeholder rows below the last site.
            .alternatingRowBackgrounds(.disabled)
            .accessibilityLabel("Site settings")
            .contextMenu(forSelectionType: String.self) { keys in
                if let key = keys.first, let row = rows.first(where: { $0.key == key }) {
                    Button("Clear Data…") { clearing = key }
                    Button("Remove Site") { remove(row) }
                        .disabled(model.controlsDisabled)
                }
            }
            .overlay {
                if rows.isEmpty {
                    Text("No sites yet. Add one, or zoom a page: Zoom In and Zoom Out remember the zoom here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(40)
                }
            }

            HStack {
                Button("Remove Site") { if let row = rows.first(where: { $0.key == selection }) { remove(row) } }
                    .disabled(selection == nil || model.controlsDisabled)
                    .accessibilityLabel(selection.map { "Remove \($0)" } ?? "Remove Site")
                    .help("Removes the selected entry from sites in config.json. Its site goes back to the defaults.")
                Button("Clear Data…") { clearing = selection }
                    .disabled(selection == nil || isClearing)
                    .accessibilityLabel(selection.map { "Clear data for \($0)" } ?? "Clear Data")
                    .help("Removes the cookies, caches and storage the selected site's domain keeps in Paddle.")
                if isClearing { ProgressView().controlSize(.small).accessibilityLabel("Clearing") }
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }

            sessionSection

            SettingsLearnMore(
                summary: "Each host entry covers its subdomains; zoom applies at once, other fields on the next load.",
                detail: "Freeze Auto follows keepNotifyingSitesLive for sites allowed to notify. \(Self.builtInAgents) Web Push (notifications while a site is closed) isn't supported."
            )
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            clearing.map { "Clear data stored by \($0)?" } ?? "",
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            presenting: clearing
        ) { key in
            Button("Clear Data", role: .destructive) { Task { await clear(key) } }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text("Removes the cookies, caches, storage and service workers \(key) keeps in Paddle. WebKit keeps data by domain, so this clears the whole domain, its other subdomains included, and signs you out of it. Private windows' data isn't touched. This can't be undone.")
        }
        .onChange(of: rows.map(\.key)) { _, keys in
            if let selection, !keys.contains(selection) { self.selection = nil }
        }
        .sheet(item: Binding(get: { editingAgent.map(AgentEdit.init) }, set: { if $0 == nil { editingAgent = nil } })) { edit in
            customAgentSheet(edit.row)
        }
        .sheet(item: Binding(get: { moreSite.map(MoreSiteEdit.init) }, set: { if $0 == nil { moreSite = nil } })) { edit in
            siteMoreSheet(edit.row)
        }
    }

    /// `sheet(item:)` needs an Identifiable value.
    private struct AgentEdit: Identifiable {
        let row: SiteRow
        var id: String { row.key }
    }

    private struct MoreSiteEdit: Identifiable {
        let row: SiteRow
        var id: String { row.key }
    }

    private func siteMoreSheet(_ row: SiteRow) -> some View {
        NavigationStack {
            Form {
                Section("Pop-ups") {
                    toggle(row, .popups, isOn: row.policy.popups, label: "Pop-ups")
                }
                Section("Freeze") {
                    freezePicker(row)
                }
                Section("User agent") {
                    userAgentPicker(row)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(row.key)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { moreSite = nil }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 280)
    }

    // MARK: - Cells

    private func darkModePicker(_ row: SiteRow) -> some View {
        Picker("Dark mode for \(row.key)", selection: Binding(
            get: { model.file.sites[row.key]?.darkMode ?? .auto },
            set: { mode in set(.darkMode, .string(mode.rawValue), on: row) }
        )) {
            Text("Auto").tag(SiteSettings.SiteDarkMode.auto)
            Text("Light").tag(SiteSettings.SiteDarkMode.light)
            Text("Dark").tag(SiteSettings.SiteDarkMode.dark)
            Text("Native").tag(SiteSettings.SiteDarkMode.native)
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help(source(row, .darkMode))
        .accessibilityLabel("Dark mode for \(row.key)")
    }

    private func zoomPicker(_ row: SiteRow) -> some View {
        let current = Int((row.policy.zoom * 100).rounded())
        let levels = Self.zoomLevels.contains(current) ? Self.zoomLevels : (Self.zoomLevels + [current]).sorted()
        return Picker("Zoom for \(row.key)", selection: Binding(
            get: { current },
            set: { percent in set(.zoom, .number(SitePolicy.normalizedZoom(Double(percent) / 100)), on: row) }
        )) {
            ForEach(levels, id: \.self) { Text("\($0) %").tag($0) }
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help(source(row, .zoom))
    }

    private func toggle(_ row: SiteRow, _ field: SiteSettings.Field, isOn: Bool, label: String) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { set(field, .bool($0), on: row) }))
            .labelsHidden()
            .accessibilityLabel("\(label) for \(row.key)")
            .disabled(model.controlsDisabled)
            .help(source(row, field))
    }

    @ViewBuilder private func blockingToggle(_ row: SiteRow) -> some View {
        if let parent = row.blockingOffBy {
            toggle(row, .contentBlocking, isOn: false, label: "Content blocking")
                .disabled(true)
                .help("Off: \(parent)'s entry turns blocking off for it and every subdomain.")
        } else {
            toggle(row, .contentBlocking, isOn: row.policy.contentBlocking, label: "Content blocking")
        }
    }

    @ViewBuilder private func autoplayPicker(_ row: SiteRow) -> some View {
        if TabWebDelegate.supportsSiteAutoplay {
            autoplayChoices(row)
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Autoplay for \(row.key): not available")
                .help("This version of WebKit has no per-site autoplay setting, so every site gets the default: media starts on its own only without sound.")
        }
    }

    private func autoplayChoices(_ row: SiteRow) -> some View {
        Picker("Autoplay for \(row.key)", selection: Binding(
            get: { row.policy.autoplay },
            set: { set(.autoplay, .string($0.rawValue), on: row) }
        )) {
            Text("Allow").tag(SiteSettings.Autoplay.allow)
            Text("Muted").tag(SiteSettings.Autoplay.muted)
            Text("Block").tag(SiteSettings.Autoplay.block)
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help("Allow: media may start with sound. Muted: only without sound. Block: nothing starts on its own. " + source(row, .autoplay))
    }

    private func locationPicker(_ row: SiteRow) -> some View {
        Picker("Location for \(row.key)", selection: Binding(
            get: { row.policy.location },
            set: { set(.location, .string($0.rawValue), on: row) }
        )) {
            Text("Ask").tag(SiteSettings.Permission.ask)
            Text("Allow").tag(SiteSettings.Permission.allow)
            Text("Deny").tag(SiteSettings.Permission.deny)
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help("Ask asks once per site per session. " + source(row, .location))
    }

    private func notificationsPicker(_ row: SiteRow) -> some View {
        Picker("Notifications for \(row.key)", selection: Binding(
            get: { row.policy.notifications },
            set: { set(.notifications, .string($0.rawValue), on: row) }
        )) {
            Text("Ask").tag(SiteSettings.Permission.ask)
            Text("Allow").tag(SiteSettings.Permission.allow)
            Text("Deny").tag(SiteSettings.Permission.deny)
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help("Ask asks once per site per session. Allowed notifications appear in macOS Notification Center. " + source(row, .notifications))
    }

    private func freezePicker(_ row: SiteRow) -> some View {
        Picker("Freeze for \(row.key)", selection: Binding(
            get: { row.policy.freeze },
            set: { set(.freeze, .string($0.rawValue), on: row) }
        )) {
            Text("Auto").tag(SiteSettings.Freeze.auto)
            Text("Never").tag(SiteSettings.Freeze.never)
            Text("Always").tag(SiteSettings.Freeze.always)
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help("sites.<host>.freeze in config.json. Auto: idle freeze like any tab; if keepNotifyingSitesLive is on and notifications are allowed, the tab stays unfrozen with its WebContent process and RAM so in-tab messages can arrive. Never: always unfrozen and out of idle sleep (same RAM and CPU cost). Always: freezes even when notifications are allowed, saving RAM and CPU but missing new messages while the tab is in the background (Paddle has no Web Push); turning keepNotifyingSitesLive off does the same for all notify sites. " + source(row, .freeze))
    }

    /// Default (Safari's), Chrome, Firefox, Custom (a hand-written string; shown only when set), or Custom… to type one.
    private func userAgentPicker(_ row: SiteRow) -> some View {
        let value = row.userAgent?.value
        let preset = value.flatMap(UserAgentPreset.init(value:))
        let current = value == nil ? "default" : preset?.rawValue ?? "custom"
        return Picker("User agent for \(row.key)", selection: Binding(
            get: { current },
            set: { choice in
                switch choice {
                case "default": setAgent(nil, on: row)
                case "edit":
                    agentText = value ?? ""
                    editingAgent = row
                default:
                    if let preset = UserAgentPreset(rawValue: choice) { setAgent(preset.value, on: row) }
                }
            }
        )) {
            Text("Default").tag("default")
            ForEach(UserAgentPreset.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            if preset == nil, value != nil { Text("Custom").tag("custom") }
            Divider()
            Text("Custom…").tag("edit")
        }
        .labelsHidden()
        .disabled(model.controlsDisabled)
        .help(value.map { "siteUserAgents.\(row.userAgent?.key ?? row.key) in config.json: \($0)" }
            ?? "Safari's user agent, Paddle's default. Pick another for a site that refuses Safari.")
    }

    private func customAgentSheet(_ row: SiteRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("User agent for \(row.key)").font(.headline)
            TextField("User agent", text: $agentText, prompt: Text("Mozilla/5.0 …"), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("User agent for \(row.key)")
            Text("Sent to \(row.key) and its subdomains instead of Safari's. Leave empty for the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editingAgent = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    setAgent(agentText, on: row)
                    editingAgent = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Paddle's built-in user agent fixes (`SiteCompat`), in words, and how a row's own user agent overrides them.
    private static var builtInAgents: String {
        let byPersona = Dictionary(grouping: SiteCompat.defaults, by: { $0.value.persona == .chrome ? "Chrome" : "Firefox" })
        let parts = byPersona.keys.sorted().map { name in
            "\(name)'s user agent to \(byPersona[name, default: []].map(\.key).sorted().joined(separator: ", "))"
        }
        return "Paddle sends \(parts.joined(separator: "; ")) unless a row here sets one."
    }

    /// Where a cell's value comes from, for its tooltip.
    private func source(_ row: SiteRow, _ field: SiteSettings.Field) -> String {
        if Self.isSet(field, in: model.file.sites[row.key]) {
            return "sites.\(row.key).\(field.rawValue) in config.json."
        }
        return SettingsModel.json(field, of: row.inherited) == SettingsModel.json(field, of: .defaults)
            ? "Paddle's default."
            : "From a parent domain's entry."
    }

    private static func isSet(_ field: SiteSettings.Field, in entry: SiteSettings?) -> Bool {
        guard let entry else { return false }
        switch field {
        case .zoom: return entry.zoom != nil
        case .darkMode: return entry.darkMode != nil
        case .javaScript: return entry.javaScript != nil
        case .autoplay: return entry.autoplay != nil
        case .contentBlocking: return entry.contentBlocking != nil
        case .location: return entry.location != nil
        case .notifications: return entry.notifications != nil
        case .httpsOnly: return entry.httpsOnly != nil
        case .popups: return entry.popups != nil
        case .freeze: return entry.freeze != nil
        }
    }

    // MARK: - This session

    private var sessionSection: some View {
        let groups = model.sessionAnswers
        return VStack(alignment: .leading, spacing: 4) {
            Text("This session").font(.headline)
            if groups.isEmpty {
                SettingsLearnMore(
                    summary: "No camera, microphone, location, notification or download answers yet.",
                    detail: "They last until Paddle quits; use Forget below to reset a host for this run."
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.host) { group in
                            HStack {
                                Text(group.host)
                                Text(describe(group.answers))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Forget") {
                                    model.forgetSessionAnswers(group.host)
                                    AccessibilityNotification.Announcement("Forgot this session's answers for \(group.host)").post()
                                }
                                .accessibilityLabel("Forget answers for \(group.host)")
                                .help("\(group.host) asks again at its next request.")
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
                .frame(maxHeight: 76)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// "Camera allowed, Location denied", in kind order; an answer given on more than one origin of the host
    /// (another port or scheme) shows once per answer.
    private func describe(_ answers: [SessionPermissions.Answer]) -> String {
        answers.sorted { $0.kind < $1.kind }.map { answer in
            let kind = switch answer.kind {
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .location: "Location"
            case .notifications: "Notifications"
            case .downloads: "Downloads"
            }
            return "\(kind) \(answer.allowed ? "allowed" : "denied")"
        }
        .joined(separator: ", ")
    }

    // MARK: - Actions

    private func addSite(_ text: String) {
        guard let typed = model.siteKey(forTyped: text) else { return }
        let key = typed.key
        if typed.exists {
            addIssues = []
            selection = key
            status = "\(key) is already listed."
            return
        }
        let found = model.newSiteIssues(key)
        addIssues = found
        guard found.isEmpty else { return }
        newSite = ""
        status = nil
        Task {
            await model.addSite(key)
            selection = key
        }
    }

    private func remove(_ row: SiteRow) {
        status = nil
        Task {
            await model.removeSite(row)
            if !model.siteRows.contains(where: { $0.key == row.key }) {
                AccessibilityNotification.Announcement("Removed \(row.key)").post()
            }
        }
    }

    private func setAgent(_ value: String?, on row: SiteRow) {
        status = nil
        Task { await model.setUserAgent(value, for: row) }
    }

    private func set(_ field: SiteSettings.Field, _ value: JSONValue, on row: SiteRow) {
        status = nil
        Task {
            if let refused = await model.setSiteField(field, value, forKey: row.key) {
                status = "Not saved: \(refused)"
            }
        }
    }

    private func clear(_ key: String) async {
        isClearing = true
        let count = await model.clearSiteData(key)
        isClearing = false
        status = count == 0
            ? "\(key) had no data stored."
            : "Cleared \(count) \(count == 1 ? "record" : "records") for \(key)'s domain."
        if let status { AccessibilityNotification.Announcement(status).post() }
    }
}
