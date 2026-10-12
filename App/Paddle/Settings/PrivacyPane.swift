import AppKit
import PaddleCore
import SwiftUI

/// Settings > Privacy & Blocking: ad and tracker blocking with its filter lists, your own rules, how long
/// history is kept, and the website data sites have stored.
struct PrivacyPane: View {
    let model: SettingsModel
    @State private var showingWebsiteData = false

    var body: some View {
        SettingsForm {
            Section("Content blocking") {
                BlockingRows(model: model)
            }
            Section("Filter lists") {
                FilterListRows(model: model)
            }
            Section("My rules") {
                UserFilterRows()
            }
            Section("History") {
                HistoryRows(model: model)
            }
            Section("Website data") {
                LabeledContent("Cookies, caches and site storage") {
                    Button("Manage Website Data…") { showingWebsiteData = true }
                        .help("Lists what each site has stored in Paddle and removes it. Private windows keep nothing.")
                }
            }
        }
        .sheet(isPresented: $showingWebsiteData) {
            WebsiteDataSheet()
        }
    }
}

/// `contentBlocking`, `filterUpdateDays` and Update Now, with the last update's result shown under the button.
private struct BlockingRows: View {
    let model: SettingsModel
    @State private var result: (text: String, failed: Bool)?

    private static let choices: [(days: Int, title: String)] = [
        (0, "Manually"), (1, "Daily"), (3, "Every 3 days"), (7, "Weekly"), (14, "Every 2 weeks"), (30, "Monthly"),
    ]

    private var web: WebEnvironment { AppModel.shared.web }

    var body: some View {
        Toggle("Block ads and trackers", isOn: Binding(
            get: { model.file.contentBlocking },
            set: { value in Task { await model.saveKey(.contentBlocking, .bool(value)) } }
        ))
        .help("contentBlocking in config.json")
        .disabled(model.controlsDisabled)

        Picker("Download list updates", selection: Binding(
            get: { model.file.filterUpdateDays },
            set: { value in Task { await model.saveKey(.filterUpdateDays, .number(Double(value))) } }
        )) {
            ForEach(Self.choices, id: \.days) { choice in
                Text(choice.title).tag(choice.days)
            }
            if !Self.choices.contains(where: { $0.days == model.file.filterUpdateDays }) {
                Text("Every \(model.file.filterUpdateDays) days").tag(model.file.filterUpdateDays)
            }
        }
        .help("filterUpdateDays in config.json (0 = only by hand; a list never downloaded is still fetched)")
        .disabled(model.controlsDisabled || !model.file.contentBlocking)

        LabeledContent("Download every list now") {
            HStack {
                if web.isUpdatingFilters {
                    ProgressView().controlSize(.small)
                    Text("Updating…").foregroundStyle(.secondary)
                }
                Button("Update Now", action: update)
                    .disabled(web.isUpdatingFilters || !model.file.contentBlocking)
                    .help("Paddle > Update Filter Lists: downloads every list in filterLists and recompiles the ones that changed.")
            }
        }
        if let result {
            Label {
                Text(result.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: result.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.failed ? .yellow : .green)
                    .accessibilityLabel(result.failed ? "Warning" : "Done")
            }
        }
    }

    /// The menu item's download, with its report here instead of in an alert.
    private func update() {
        Task {
            let report = await web.updateFilterLists()
            let summary = report.skipped ? "Filter lists are already updating."
                : report.failures == 0 ? "Filter lists updated."
                : report.failures == 1 ? "A filter list couldn't be updated." : "\(report.failures) filter lists couldn't be updated."
            let text = ([summary] + (report.skipped ? [] : report.lines)).joined(separator: "\n")
            result = (text, report.failures > 0)
            AccessibilityNotification.Announcement(summary).post()
        }
    }
}

/// `filterLists`: each list with its status, add and remove, and Remove Unused List Files. Removing a list stops
/// it blocking; its file stays in `filters/` (ignored) until Remove Unused List Files moves it to the Trash.
private struct FilterListRows: View {
    let model: SettingsModel
    @State private var newList = ""
    @State private var addProblem: String?
    @State private var unusedFiles: [URL]?
    @State private var trashResult: String?

    private var web: WebEnvironment { AppModel.shared.web }

    var body: some View {
        let rows = PrivacySettings.rows(lists: model.file.filterLists, blockerStatus: web.blockerStatus, problems: web.filterUpdateProblems)
        ForEach(rows) { row in
            listRow(row)
        }
        if rows.isEmpty {
            SettingsCaption("No filter lists: only your own rules block.")
        }

        LabeledContent("Add a list") {
            HStack {
                TextField("List URL", text: $newList, prompt: Text("https://example.com/list.txt"))
                    .labelsHidden()
                    .onSubmit(add)
                    .accessibilityLabel("Filter list URL")
                Button("Add", action: add)
                    .disabled(newList.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .help("Appends to filterLists in config.json. The list downloads at once.")
        .disabled(model.controlsDisabled)
        if let addProblem {
            ConfigIssueList(issues: [ConfigIssue(key: .filterLists, severity: .error, message: addProblem)])
        }

        LabeledContent("List files no list uses") {
            Button("Remove Unused List Files…") {
                trashResult = nil
                let lists = model.file.filterLists + AppModel.shared.config.filterLists
                let files = PrivacySettings.unusedListFiles(lists: lists)
                if files.isEmpty {
                    trashResult = "filters/ has no unused list files."
                } else {
                    unusedFiles = files
                }
            }
            .help("Moves files in filters/ that no list in filterLists downloads to the Trash, after listing them.")
        }
        if let trashResult {
            SettingsCaption(trashResult)
        }
        SettingsCaption("Only these lists and your own rules block. A removed list stops blocking at once; its file stays in filters/ until you remove unused list files.")
            .sheet(isPresented: Binding(get: { unusedFiles != nil }, set: { if !$0 { unusedFiles = nil } })) {
                UnusedFilesSheet(files: unusedFiles ?? []) { confirmed in
                    if confirmed, let files = unusedFiles {
                        let failures = PrivacySettings.trash(files)
                        let moved = files.count - failures.count
                        trashResult = (["Moved \(moved) \(moved == 1 ? "file" : "files") to the Trash."] + failures).joined(separator: "\n")
                    }
                    unusedFiles = nil
                }
            }
    }

    private func listRow(_ row: PrivacySettings.ListRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium)
                Text(row.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                statusLabel(row)
                if let downloaded = row.downloaded {
                    Text("Downloaded \(downloaded, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                remove(row.url)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(row.name)")
            .help("Removes this list from filterLists in config.json. Its file stays in filters/, unused.")
            .disabled(model.controlsDisabled)
        }
        .accessibilityElement(children: .contain)
    }

    /// The list's state as icon and text: a failed download, its compiled status, or why it has none yet.
    private func statusLabel(_ row: PrivacySettings.ListRow) -> some View {
        let text: String
        let symbol: String
        if let problem = row.problem {
            (text, symbol) = (problem, "exclamationmark.triangle.fill")
        } else if row.file == nil {
            (text, symbol) = ("Not an https URL, so it is never downloaded or used.", "xmark.octagon.fill")
        } else if let status = row.status {
            if status.contains("failed to compile") || status.contains("unreadable") {
                symbol = "xmark.octagon.fill"
            } else if status.contains("not downloaded") {
                symbol = "arrow.down.circle"
            } else {
                symbol = "checkmark.circle"
            }
            text = String(status.dropFirst(row.name.count + 2))
        } else if !AppModel.shared.config.contentBlocking {
            (text, symbol) = ("Off: content blocking is off.", "pause.circle")
        } else if AppModel.shared.config.filterLists.contains(row.url) {
            (text, symbol) = ("Loading…", "clock")
        } else {
            // In config.json but not what Paddle is running with: a hand edit the banner offers to apply.
            (text, symbol) = ("Not applied yet.", "clock")
        }
        return Label(text, systemImage: symbol)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func add() {
        let list = newList.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !list.isEmpty else { return }
        guard FilterUpdatePolicy.fileName(forList: list) != nil else {
            addProblem = "Use the https URL of an Adblock Plus filter list."
            return
        }
        guard !model.file.filterLists.contains(list) else {
            addProblem = "That list is already here."
            return
        }
        addProblem = nil
        newList = ""
        let lists = model.file.filterLists + [list]
        Task { await model.saveKey(.filterLists, .array(lists.map(JSONValue.string))) }
    }

    private func remove(_ list: String) {
        let lists = model.file.filterLists.filter { $0 != list }
        Task { await model.saveKey(.filterLists, .array(lists.map(JSONValue.string))) }
    }
}

/// The confirmation for Remove Unused List Files: every file it would move, with its size, before anything moves.
private struct UnusedFilesSheet: View {
    let files: [URL]
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(files.count) unused list \(files.count == 1 ? "file" : "files") to the Trash?")
                .font(.headline)
            Text("No list in filterLists downloads to these files in filters/, so they don't block anything.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files, id: \.self) { file in
                        HStack {
                            Image(systemName: "doc.text").accessibilityHidden(true)
                            Text(file.lastPathComponent)
                            Spacer()
                            Text(PrivacySettings.fileSize(file).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { finish(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// `user-filters.txt`: its status line, opened in the user's editor (not edited here, so there is one writer),
/// and recompiled on request.
private struct UserFilterRows: View {
    private var web: WebEnvironment { AppModel.shared.web }

    var body: some View {
        let status = PrivacySettings.userFiltersStatus(web.blockerStatus)
        let empty = status?.hasSuffix(": empty") == true || status?.hasSuffix(": no file") == true || status?.contains(": 0 rules") == true
        LabeledContent("user-filters.txt") {
            HStack {
                Button("Edit…") { NSWorkspace.shared.open(Paths.userFilters) }
                    .help("Opens user-filters.txt in your editor.")
                Button("Apply Changes") { Task { await web.loadContentBlockers() } }
                    .help("Recompiles user-filters.txt, as Reload Config does.")
            }
        }
        if let status {
            Label(String(status.drop { $0 != ":" }.dropFirst(2)), systemImage: empty ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        if empty {
            SettingsCaption("Your rules block nothing yet: the file is empty or only comments.")
        }
        SettingsCaption("@@ and #@# exceptions here also apply to EasyList and the other lists; changing them recompiles every list.")
    }
}

/// `historyDays`. A choice that would delete visits (`countVisits`) asks first in a sheet; Cancel leaves both
/// config.json and history.sqlite as they were.
private struct HistoryRows: View {
    let model: SettingsModel

    private struct Pending {
        var days: Int
        var count: Int?
    }

    @State private var pending: Pending?

    private static let choices: [(days: Int, title: String)] = [
        (0, "Don't keep history"), (1, "1 day"), (7, "1 week"), (14, "2 weeks"), (30, "1 month"), (90, "3 months"), (365, "1 year"),
    ]

    var body: some View {
        Picker("Keep history for", selection: Binding(get: { model.file.historyDays }, set: request)) {
            ForEach(Self.choices, id: \.days) { choice in
                Text(choice.title).tag(choice.days)
            }
            if !Self.choices.contains(where: { $0.days == model.file.historyDays }) {
                Text("\(model.file.historyDays) days").tag(model.file.historyDays)
            }
        }
        .help("historyDays in config.json (0 = no history)")
        .disabled(model.controlsDisabled)
        .confirmationDialog(
            pending.map { "Keep history for \(Self.title($0.days))?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button(pending.count.map { "Delete \($0.formatted()) \($0 == 1 ? "Visit" : "Visits")" } ?? "Delete Older Visits", role: .destructive) {
                Task { await model.saveKey(.historyDays, .number(Double(pending.days))) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if let count = pending.count {
                Text("This deletes \(count.formatted()) \(count == 1 ? "visit" : "visits") older than \(Self.title(pending.days)) from your history. This can't be undone.")
            } else {
                Text("Visits older than \(Self.title(pending.days)) will be deleted from your history. This can't be undone.")
            }
        }

        if model.file.historyDays == 0 {
            SettingsCaption("History is off: nothing is recorded, and existing history stays until you clear it.")
        }
        LabeledContent("Remove visited pages") {
            Button("Clear History…") { ClearHistoryPrompt.run(for: NSApp.keyWindow) }
                .help("History > Clear History…")
        }
    }

    private static func title(_ days: Int) -> String {
        choices.first { $0.days == days }?.title ?? "\(days) days"
    }

    /// Saves at once when nothing would be deleted; otherwise asks first.
    private func request(_ days: Int) {
        guard days != model.file.historyDays else { return }
        let count = PrivacySettings.visitsDeleted(keepingDays: days)
        if count == 0 {
            Task { await model.saveKey(.historyDays, .number(Double(days))) }
        } else {
            pending = Pending(days: days, count: count)
        }
    }
}
