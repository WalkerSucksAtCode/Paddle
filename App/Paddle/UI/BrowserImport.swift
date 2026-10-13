import AppKit
import os
import PaddleCore
import SwiftUI

/// File > Import from Browser…: a sheet over the front window (a window of its own when none is key) that lists the
/// browser profiles found and brings over their settings and history. Exists only while open.
final class BrowserImportController: NSWindowController, NSWindowDelegate {
    private static var shared: BrowserImportController?

    static func show() {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BrowserImportController()
        shared = controller
        guard let window = controller.window else { return }
        if let parent = NSApp.keyWindow, parent.attachedSheet == nil {
            parent.beginSheet(window) { _ in shared = nil }
        } else {
            window.center()
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Import from Browser"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: BrowserImportView(model: BrowserImportModel(), close: { [weak self] in self?.dismiss() }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        Self.shared = nil
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
    var selection: ImportSource.ID?
    var includeSettings = true
    var includeHistory = true
    private(set) var isRunning = false
    private(set) var report: [ImportReportSection]?

    init() {
        sources = BrowserImport.discoverSources(home: FileManager.default.homeDirectoryForCurrentUser)
        selection = (sources.first { $0.browser != .safari && !$0.needsFullDiskAccess } ?? sources.first)?.id
    }

    var selected: ImportSource? { sources.first { $0.id == selection } }

    var canRun: Bool {
        guard let selected, !isRunning else { return false }
        return (includeSettings && selected.hasSettings) || (includeHistory && selected.hasHistory)
    }

    func run() async {
        guard let source = selected, canRun else { return }
        isRunning = true
        var sections: [ImportReportSection] = []
        if includeSettings, source.hasSettings { sections.append(await importSettings(from: source)) }
        if includeHistory, source.hasHistory { sections.append(await importHistory(from: source)) }
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
        guard app.history != nil else {
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
            guard let result = try await app.importHistory(read.visits) else {
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

    private static func visits(_ count: Int) -> String { "\(count.formatted()) visit\(count == 1 ? "" : "s")" }
}

private struct BrowserImportView: View {
    @State var model: BrowserImportModel
    let close: () -> Void

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
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isRunning)
                    Button("Import") { Task { await model.run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRun)
                } else {
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var form: some View {
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
            .frame(height: 170)
            .disabled(model.isRunning)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Settings: search engine, home page, bookmarks bar", isOn: $model.includeSettings)
                    .disabled(model.isRunning || model.selected?.hasSettings != true)
                Toggle("History: up to \(BrowserHistoryReader.defaultRowCap.formatted()) of the newest visits", isOn: $model.includeHistory)
                    .disabled(model.isRunning || model.selected?.hasHistory != true)
            }

            if let source = model.selected, source.browser == .safari || source.needsFullDiskAccess {
                Text("\(source.browser.displayName)'s files are protected by macOS. To import them, allow Paddle in System Settings > Privacy & Security > Full Disk Access first. Paddle doesn't ask for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Bookmarks come from an HTML file: export them from the old browser, then use Bookmarks > Import Bookmarks…")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Import Bookmarks…") {
                    close()
                    DispatchQueue.main.async { BookmarkFiles.importFile() }
                }
                .disabled(model.isRunning)
                Text("Passwords, cookies, sign-ins and extensions are not imported.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func subtitle(_ source: ImportSource) -> String {
        switch (source.needsFullDiskAccess, source.hasHistory, source.hasSettings) {
        case (true, _, _): "Needs Full Disk Access"
        case (false, true, true): source.browser == .safari ? "History and settings (needs Full Disk Access)" : "History and settings"
        case (false, true, false): "History only"
        case (false, false, true): "Settings only"
        case (false, false, false): "Nothing to import"
        }
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
