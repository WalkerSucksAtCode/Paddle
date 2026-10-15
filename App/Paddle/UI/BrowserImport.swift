import AppKit
import os
import PaddleCore
import SwiftUI

/// File > Import from Browser…: a sheet over the front window (a window of its own when none is key) that lists the
/// browser profiles found and brings over their settings, history, bookmarks, open tabs, site settings and a
/// list of extensions to reinstall. Exists only while open.
final class BrowserImportController: NSWindowController, NSWindowDelegate {
    private static var shared: BrowserImportController?
    /// The window the sheet was opened over, where extension questions are asked after it closes.
    fileprivate weak var parentWindow: NSWindow?

    static func show() {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BrowserImportController()
        shared = controller
        guard let window = controller.window else { return }
        if let parent = NSApp.keyWindow, parent.attachedSheet == nil {
            controller.parentWindow = parent
            parent.beginSheet(window) { _ in shared = nil }
        } else {
            window.center()
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Import from Browser"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: BrowserImportView(model: BrowserImportModel(), close: { [weak self] installs in self?.dismiss(installing: installs) }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Closes the sheet first, then installs the chosen extensions one at a time.
    private func dismiss(installing links: [(name: String, link: StoreLink)] = []) {
        guard let window else { return }
        let host = parentWindow ?? window.sheetParent
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        Self.shared = nil
        guard !links.isEmpty else { return }
        Task { @MainActor in
            var failures: [String] = []
            for item in links {
                let target = (host?.isVisible == true ? host : nil) ?? NSApp.keyWindow
                let outcome = await StoreInstaller.shared.install(item.link, window: target)
                switch outcome {
                case .installed, .updated, .alreadyInstalled: break
                case .cancelled: break
                case .failed: failures.append("\(ExtensionPermissionText.sanitize(item.name, max: 60)): \(outcome.message)")
                }
            }
            guard !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Some extensions weren't installed"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

/// One line of the result: what happened to one setting or to the history.
struct ImportReportLine: Identifiable {
    enum Kind { case done, unchanged, problem }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?

    var symbol: String {
        switch kind {
        case .done: "checkmark.circle.fill"
        case .unchanged: "minus.circle"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    var spoken: String { [title, detail].compactMap { $0 }.joined(separator: ". ") }
}

struct ImportReportSection: Identifiable {
    let id = UUID()
    var title: String
    var lines: [ImportReportLine]
}

@Observable
final class BrowserImportModel {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "import")

    let sources: [ImportSource]
    var selection: ImportSource.ID? {
        didSet { if selection != oldValue { loadExtensions() } }
    }
    var includeSettings = true
    var includeHistory = true
    var includeBookmarks = true
    /// Off by default: it opens windows.
    var includeOpenTabs = false
    var includeSiteSettings = true
    /// Extension ids ticked for reinstalling after the sheet closes.
    var chosenExtensions: Set<String> = []
    private(set) var extensions: [ImportedExtension] = []
    private(set) var extensionsError: String?
    /// Ids of listed extensions Paddle already has, checked once when the list loads.
    private var installedExtensions: Set<String> = []
    private var extensionsTask: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var report: [ImportReportSection]?

    init() {
        sources = BrowserImport.discoverSources(home: FileManager.default.homeDirectoryForCurrentUser)
        selection = (sources.first { $0.browser != .safari && !$0.needsFullDiskAccess } ?? sources.first)?.id
        loadExtensions()
    }

    /// Reads the selected profile's extension list off the main actor when the selection changes.
    private func loadExtensions() {
        extensionsTask?.cancel()
        extensions = []
        installedExtensions = []
        extensionsError = nil
        chosenExtensions = []
        guard let source = selected, source.hasExtensions, source.browser != .safari else { return }
        let id = source.id
        extensionsTask = Task { [weak self] in
            let result: Result<[ImportedExtension], Error> = await Task.detached {
                Result { try BrowserExtensionReader.read(source) }
            }.value
            guard let self, !Task.isCancelled, self.selection == id else { return }
            switch result {
            case .success(let list):
                // Installed from this store, or the same extension from another store (Proton Pass from
                // addons.mozilla.org listed again from the Chrome Web Store): matched by name.
                let names = Set(AppModel.shared.frontExtensions.loaded.map { $0.displayName.lowercased() })
                self.installedExtensions = Set(list.compactMap { item in
                    guard let link = item.link else { return nil }
                    let sameName = names.contains(ExtensionPermissionText.sanitize(item.name).lowercased())
                    return StoreInstaller.shared.isInstalled(link) || sameName ? item.id : nil
                })
                self.extensions = list
            case .failure(let error):
                Self.log.error("extension list: \(error.localizedDescription, privacy: .public)")
                self.extensionsError = error.localizedDescription
            }
        }
    }

    /// Whether an extension can be ticked: it has a store link and Paddle doesn't have it yet.
    func isInstallable(_ item: ImportedExtension) -> Bool {
        item.link != nil && !installedExtensions.contains(item.id)
    }

    /// What the sheet hands to the installer when it closes.
    var pendingInstalls: [(name: String, link: StoreLink)] {
        extensions.compactMap { item in
            guard chosenExtensions.contains(item.id), let link = item.link, isInstallable(item) else { return nil }
            return (item.name, link)
        }
    }

    var selected: ImportSource? { sources.first { $0.id == selection } }

    var canRun: Bool {
        guard let selected, !isRunning else { return false }
        return (includeSettings && selected.hasSettings) || (includeHistory && selected.hasHistory)
            || (includeBookmarks && selected.hasBookmarks) || (includeOpenTabs && selected.hasOpenTabs)
            || (includeSiteSettings && selected.hasSiteSettings) || !pendingInstalls.isEmpty
    }

    func run() async {
        guard let source = selected, canRun else { return }
        isRunning = true
        var sections: [ImportReportSection] = []
        if includeSettings, source.hasSettings { sections.append(await importSettings(from: source)) }
        if includeHistory, source.hasHistory { sections.append(await importHistory(from: source)) }
        if includeBookmarks, source.hasBookmarks { sections.append(await importBookmarks(from: source)) }
        if includeOpenTabs, source.hasOpenTabs { sections.append(await importOpenTabs(from: source)) }
        if includeSiteSettings, source.hasSiteSettings { sections.append(await importSiteSettings(from: source)) }
        let installs = pendingInstalls
        if !installs.isEmpty {
            let count = installs.count
            sections.append(ImportReportSection(title: "Extensions", lines: [ImportReportLine(
                kind: .done, title: "\(count) extension\(count == 1 ? "" : "s") will install when you press Done; each may ask for permissions.")]))
        }
        report = sections
        isRunning = false
        AccessibilityNotification.Announcement(
            "Import finished. " + sections.flatMap(\.lines).map(\.spoken).joined(separator: ". ")).post()
    }

    // MARK: - Settings

    private func importSettings(from source: ImportSource) async -> ImportReportSection {
        let app = AppModel.shared
        let title = "Settings"
        let settings: BrowserSettings
        do {
            settings = try BrowserSettingsReader.read(source)
        } catch {
            Self.log.error("settings import: \(error.localizedDescription, privacy: .public)")
            return ImportReportSection(title: title, lines: [ImportReportLine(kind: .problem, title: error.localizedDescription)])
        }
        let plan = SettingsMapper.map(settings, current: app.config, currentShowBookmarksBar: app.showBookmarksBar)

        // The same write path as Settings: only the keys changed move, and a key edited by hand meanwhile is a
        // conflict rather than overwritten.
        var failure: String?
        if !plan.changes.isEmpty {
            do {
                switch await app.writeConfig(plan.changes, base: try AppModel.readConfigFile(Paths.config)) {
                case .written: break
                case .conflict(let paths):
                    failure = "config.json changed at \(paths.map { $0.joined(separator: ".") }.joined(separator: ", ")) while importing."
                case .failed(let message):
                    failure = "config.json couldn't be saved: \(message)"
                }
            } catch {
                failure = "config.json couldn't be read: \(error.localizedDescription)"
            }
        }
        if failure == nil, let bar = plan.showBookmarksBar { app.showBookmarksBar = bar }

        var lines: [ImportReportLine] = []
        if let failure { lines.append(ImportReportLine(kind: .problem, title: failure, detail: "Nothing was imported from settings.")) }
        for item in plan.items {
            switch item.status {
            case .imported(let value):
                lines.append(failure == nil
                    ? ImportReportLine(kind: .done, title: "\(item.title): \(value)")
                    : ImportReportLine(kind: .problem, title: "\(item.title): not saved", detail: value))
            case .unchanged(let value):
                lines.append(ImportReportLine(kind: .unchanged, title: "\(item.title): \(value)", detail: "Already the same in Paddle."))
            case .skipped(let reason):
                lines.append(ImportReportLine(kind: .unchanged, title: "\(item.title): not imported", detail: reason))
            }
        }
        return ImportReportSection(title: title, lines: lines)
    }

    // MARK: - History

    private func importHistory(from source: ImportSource) async -> ImportReportSection {
        let app = AppModel.shared
        let title = "History"
        func problem(_ text: String) -> ImportReportSection {
            ImportReportSection(title: title, lines: [ImportReportLine(kind: .problem, title: text)])
        }
        let profile = app.frontWindow?.model.profileID ?? ProfileStore.defaultID
        guard app.history(for: profile) != nil else {
            return problem("History is turned off (historyDays is 0 in config.json), so nothing was imported.")
        }

        // Copying and reading the database can take a while: off the main actor.
        let read: HistoryReadResult
        do {
            read = try await Task.detached { try BrowserHistoryReader.read(source) }.value
        } catch {
            Self.log.error("history read: \(error.localizedDescription, privacy: .public)")
            return problem(error.localizedDescription)
        }

        let summary: HistoryImportSummary
        do {
            guard let result = try await app.importHistory(read.visits, profile: profile) else {
                return problem("History is turned off (historyDays is 0 in config.json), so nothing was imported.")
            }
            summary = result
        } catch {
            Self.log.error("history write: \(error.localizedDescription, privacy: .public)")
            return problem("History couldn't be written: \(error.localizedDescription). Importing again skips what was already added.")
        }

        var lines = [ImportReportLine(kind: summary.added > 0 ? .done : .unchanged, title: "Added \(Self.visits(summary.added))")]
        if summary.duplicates > 0 {
            lines.append(ImportReportLine(kind: .unchanged, title: "\(Self.visits(summary.duplicates)) already in Paddle's history, skipped"))
        }
        if summary.beforeRetention > 0 {
            lines.append(ImportReportLine(
                kind: .unchanged, title: "\(Self.visits(summary.beforeRetention)) older than your \(app.config.historyDays)-day history limit, skipped",
                detail: "historyDays in config.json sets the limit."))
        }
        let notWeb = read.skippedNotWeb + summary.notRecordable
        if notWeb > 0 {
            lines.append(ImportReportLine(
                kind: .unchanged, title: "\(Self.visits(notWeb)) to addresses that aren't web pages, skipped",
                detail: "Browser settings pages, local files, extension pages."))
        }
        if read.skippedBadDate > 0 {
            lines.append(ImportReportLine(kind: .unchanged, title: "\(Self.visits(read.skippedBadDate)) with no usable date, skipped"))
        }
        if read.truncated {
            lines.append(ImportReportLine(
                kind: .unchanged, title: "Only the newest \(BrowserHistoryReader.defaultRowCap.formatted()) visits were read"))
        }
        return ImportReportSection(title: title, lines: lines)
    }

    // MARK: - Bookmarks

    private func importBookmarks(from source: ImportSource) async -> ImportReportSection {
        let title = "Bookmarks"
        func problem(_ text: String) -> ImportReportSection {
            ImportReportSection(title: title, lines: [ImportReportLine(kind: .problem, title: text)])
        }
        let read: BookmarkReadResult
        do {
            read = try await Task.detached { try BrowserBookmarkReader.read(source) }.value
        } catch {
            Self.log.error("bookmarks read: \(error.localizedDescription, privacy: .public)")
            return problem(error.localizedDescription)
        }
        let added: Int
        do {
            added = try AppModel.shared.bookmarks.importTree(read.tree, folderTitle: "Imported from \(source.title)")
        } catch {
            Self.log.error("bookmarks write: \(error.localizedDescription, privacy: .public)")
            return problem(error.localizedDescription)
        }
        var lines = [ImportReportLine(kind: added > 0 ? .done : .unchanged, title: "\(added.formatted()) bookmark\(added == 1 ? "" : "s") added")]
        let existing = max(0, read.bookmarks - added)
        if existing > 0 {
            // Already in Paddle, or listed twice in the old browser.
            lines.append(ImportReportLine(kind: .unchanged, title: "\(existing.formatted()) duplicate\(existing == 1 ? "" : "s") skipped"))
        }
        if read.skippedNotWeb > 0 {
            lines.append(ImportReportLine(kind: .unchanged, title: "\(read.skippedNotWeb.formatted()) not web pages, skipped"))
        }
        return ImportReportSection(title: title, lines: lines)
    }

    // MARK: - Open tabs

    private func importOpenTabs(from source: ImportSource) async -> ImportReportSection {
        let title = "Open tabs"
        let read: SessionReadResult
        do {
            read = try await Task.detached { try BrowserSessionReader.read(source) }.value
        } catch {
            Self.log.error("session read: \(error.localizedDescription, privacy: .public)")
            return ImportReportSection(title: title, lines: [ImportReportLine(kind: .problem, title: error.localizedDescription)])
        }
        // Each record becomes a new normal window; its tabs stay asleep until shown. The import doesn't write session.json; the normal session save picks the windows up.
        let profile = AppModel.shared.frontWindow?.model.profileID ?? ProfileStore.defaultID
        for record in read.windows { _ = AppModel.shared.openWindow(record: record, profile: profile) }
        let windows = read.windows.count
        var lines = [ImportReportLine(
            kind: read.tabs > 0 ? .done : .unchanged,
            title: "\(read.tabs.formatted()) tab\(read.tabs == 1 ? "" : "s") opened in \(windows) window\(windows == 1 ? "" : "s")")]
        if read.skippedNotWeb > 0 {
            lines.append(ImportReportLine(kind: .unchanged, title: "\(read.skippedNotWeb.formatted()) not web pages, skipped"))
        }
        if read.truncated {
            lines.append(ImportReportLine(kind: .unchanged, title: "Stopped at \(BrowserSessionReader.tabCap) tabs"))
        }
        return ImportReportSection(title: title, lines: lines)
    }

    // MARK: - Site settings

    private func importSiteSettings(from source: ImportSource) async -> ImportReportSection {
        let app = AppModel.shared
        let title = "Site settings"
        func problem(_ text: String, detail: String? = nil) -> ImportReportSection {
            ImportReportSection(title: title, lines: [ImportReportLine(kind: .problem, title: text, detail: detail)])
        }
        let imported: ImportedSiteSettings
        do {
            imported = try await Task.detached { try BrowserSiteSettingsReader.read(source) }.value
        } catch {
            Self.log.error("site settings read: \(error.localizedDescription, privacy: .public)")
            return problem(error.localizedDescription)
        }
        let plan = SiteSettingsMapper.map(imported, existing: app.config.sites)
        if !plan.changes.isEmpty {
            do {
                switch await app.writeConfig(plan.changes, base: try AppModel.readConfigFile(Paths.config)) {
                case .written: break
                case .conflict(let paths):
                    return problem("config.json changed at \(paths.map { $0.joined(separator: ".") }.joined(separator: ", ")) while importing.",
                                   detail: "Nothing was imported from site settings.")
                case .failed(let message):
                    return problem("config.json couldn't be saved: \(message)", detail: "Nothing was imported from site settings.")
                }
            } catch {
                return problem("config.json couldn't be read: \(error.localizedDescription)", detail: "Nothing was imported from site settings.")
            }
        }
        func sites(_ n: Int) -> String { "\(n.formatted()) site\(n == 1 ? "" : "s")" }
        var lines: [ImportReportLine] = []
        let labels: [(SiteSettings.Field, String)] = [
            (.zoom, "Zoom for"), (.notifications, "Notification answers for"), (.location, "Location answers for"),
            (.javaScript, "JavaScript off for"), (.autoplay, "Autoplay for"),
        ]
        for (field, label) in labels {
            if let n = plan.fieldsSet[field], n > 0 { lines.append(ImportReportLine(kind: .done, title: "\(label) \(sites(n))")) }
        }
        if plan.keptExisting > 0 {
            lines.append(ImportReportLine(kind: .unchanged, title: "\(plan.keptExisting.formatted()) kept (Paddle already had a setting)"))
        }
        if imported.skippedPatterns > 0 {
            lines.append(ImportReportLine(kind: .unchanged, title: "\(imported.skippedPatterns.formatted()) patterns skipped (wildcards or ports)"))
        }
        if lines.isEmpty { lines.append(ImportReportLine(kind: .unchanged, title: "No site settings to bring over")) }
        return ImportReportSection(title: title, lines: lines)
    }

    private static func visits(_ count: Int) -> String { "\(count.formatted()) visit\(count == 1 ? "" : "s")" }
}

private struct BrowserImportView: View {
    @State var model: BrowserImportModel
    let close: ([(name: String, link: StoreLink)]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Browser").font(.headline)
            if let report = model.report {
                ReportView(sections: report)
            } else {
                form
            }
            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if model.report == nil {
                    Button("Cancel") { close([]) }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isRunning)
                    Button("Import") { Task { await model.run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRun)
                } else {
                    Button("Done") { close(model.pendingInstalls) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var form: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a browser profile and what to bring over.")
                .foregroundStyle(.secondary)

            List(model.sources, selection: $model.selection) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(subtitle(source)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(source.id)
                .accessibilityElement(children: .combine)
            }
            .frame(height: 150)
            .disabled(model.isRunning)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Settings: search engine, home page, bookmarks bar", isOn: $model.includeSettings)
                    .disabled(model.isRunning || model.selected?.hasSettings != true)
                Toggle("History: up to \(BrowserHistoryReader.defaultRowCap.formatted()) of the newest visits", isOn: $model.includeHistory)
                    .disabled(model.isRunning || model.selected?.hasHistory != true)
                Toggle("Bookmarks", isOn: $model.includeBookmarks)
                    .disabled(model.isRunning || model.selected?.hasBookmarks != true)
                Toggle("Open tabs from the last session (opens new windows; tabs stay asleep until shown)", isOn: $model.includeOpenTabs)
                    .disabled(model.isRunning || model.selected?.hasOpenTabs != true)
                Toggle("Site zoom and permissions (only for sites Paddle has no setting for)", isOn: $model.includeSiteSettings)
                    .disabled(model.isRunning || model.selected?.hasSiteSettings != true)
            }

            extensionsSection

            if let source = model.selected, source.browser == .safari || source.needsFullDiskAccess {
                Text("\(source.browser.displayName)'s files are protected by macOS. To import them, allow Paddle in System Settings > Privacy & Security > Full Disk Access first. Paddle doesn't ask for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("From a bookmarks HTML file instead:")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Import Bookmarks…") {
                    close([])
                    DispatchQueue.main.async { BookmarkFiles.importFile() }
                }
                .disabled(model.isRunning)
                Text("Passwords, cookies and sign-ins are not imported.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .font(.callout)
        }
        }
        .frame(height: 400)
    }

    @ViewBuilder
    private var extensionsSection: some View {
        if let source = model.selected, source.browser == .safari {
            Text("Safari extensions come inside Mac apps; Paddle can't install them.")
                .font(.callout).foregroundStyle(.secondary)
        } else if let error = model.extensionsError {
            Text(error).font(.callout).foregroundStyle(.secondary)
        } else if !model.extensions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extensions").font(.subheadline.weight(.semibold))
                Text("Ticked ones install one by one after you press Done; each may ask for permissions.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.extensions) { item in
                    let installable = model.isInstallable(item)
                    VStack(alignment: .leading, spacing: 1) {
                        if installable {
                            Toggle(ExtensionPermissionText.sanitize(item.name, max: 60), isOn: Binding(
                                get: { model.chosenExtensions.contains(item.id) },
                                set: { if $0 { model.chosenExtensions.insert(item.id) } else { model.chosenExtensions.remove(item.id) } }))
                                .disabled(model.isRunning)
                        } else {
                            Text(ExtensionPermissionText.sanitize(item.name, max: 60))
                        }
                        Text(caption(item, installable: installable, source: model.selected))
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, installable ? 20 : 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func caption(_ item: ImportedExtension, installable: Bool, source: ImportSource?) -> String {
        var parts: [String] = []
        if let link = item.link {
            switch link {
            case .mozillaAddons: parts.append(installable ? "Firefox Add-ons" : "Already in Paddle")
            case .chromeWebStore: parts.append(installable ? "Chrome Web Store" : "Already in Paddle")
            }
        } else if let reason = item.notInstallable {
            parts.append(reason)
        }
        if !item.enabled { parts.append("Off in \(source?.browser.displayName ?? "the old browser")") }
        return parts.joined(separator: ". ")
    }

    private func subtitle(_ source: ImportSource) -> String {
        if source.needsFullDiskAccess { return "Needs Full Disk Access" }
        var what: [String] = []
        if source.hasSettings { what.append("settings") }
        if source.hasHistory { what.append("history") }
        if source.hasBookmarks { what.append("bookmarks") }
        if source.hasOpenTabs { what.append("open tabs") }
        if source.hasSiteSettings { what.append("site settings") }
        if source.hasExtensions { what.append("extensions") }
        guard !what.isEmpty else { return "Nothing to import" }
        let joined = what.joined(separator: ", ")
        let text = joined.prefix(1).uppercased() + joined.dropFirst()
        return source.browser == .safari ? "\(text) (needs Full Disk Access)" : text
    }
}

private struct ReportView: View {
    let sections: [ImportReportSection]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if sections.isEmpty { Text("Nothing was selected to import.") }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.subheadline.weight(.semibold))
                        ForEach(section.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: line.symbol)
                                    .foregroundStyle(line.kind == .problem ? Color.orange : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(line.title).fixedSize(horizontal: false, vertical: true)
                                    if let detail = line.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, maxHeight: 360)
    }
}
