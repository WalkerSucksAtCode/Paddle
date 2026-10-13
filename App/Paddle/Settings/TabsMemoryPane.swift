import PaddleCore
import SwiftUI

/// Settings > Tabs & Memory: when background tabs sleep, the toolbar readout, and a live memory readout. The
/// readout measures every 5 s only while this pane is on screen (its `.task` ends when the pane is switched away
/// or the window closes), so it works with `showTabMemory` off and costs nothing otherwise.
struct TabsMemoryPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Sleeping tabs") {
                SleepAfterRows(model: model)
                MaxAwakeRow(model: model)
                Toggle("Let pinned tabs sleep", isOn: Binding(
                    get: { model.file.sleepPinnedTabs },
                    set: { value in Task { await model.saveKey(.sleepPinnedTabs, .bool(value)) } }
                ))
                .help("sleepPinnedTabs in config.json")
                Picker("Save Back history for", selection: Binding(
                    get: { model.file.sessionHistoryTabs },
                    set: { value in Task { await model.saveKey(.sessionHistoryTabs, .number(Double(value))) } }
                )) {
                    ForEach(Set([0, 10, 30, 50, 100, model.file.sessionHistoryTabs]).sorted(), id: \.self) { count in
                        Text(count == 0 ? "Pinned tabs only" : "\(count) most recent tabs, plus pinned").tag(count)
                    }
                }
                .help("sessionHistoryTabs in config.json: other tabs reopen at next launch on their page, with no Back history")
                SettingsCaption("A sleeping tab's web process exits; the tab reloads when you show it. The tab you are looking at, and tabs playing sound or using the camera or microphone, stay awake.")
            }
            .disabled(model.controlsDisabled)

            Section("Memory") {
                Toggle("Show memory in toolbar", isOn: Binding(
                    get: { model.file.showTabMemory },
                    set: { value in Task { await model.saveKey(.showTabMemory, .bool(value)) } }
                ))
                .help("showTabMemory in config.json")
                .disabled(model.controlsDisabled)
                MemoryReadout()
            }
        }
    }
}

/// `maxAwakeTabs`. Clicks edit a local draft and the value is written after 0.7 s without a click, because each
/// write sweeps tabs to sleep at once and the values passed on the way to the target must not sleep anything.
private struct MaxAwakeRow: View {
    let model: SettingsModel

    @State private var draft = 0
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        LabeledContent("Keep at most") {
            Stepper(label, value: Binding(get: { draft }, set: edit), in: 0...100)
                .accessibilityValue(label)
        }
        .help("maxAwakeTabs in config.json (0 = no limit)")
        .onAppear { draft = model.file.maxAwakeTabs }
        .onChange(of: model.file.maxAwakeTabs) { _, value in if commitTask == nil { draft = value } }
        .onDisappear { commit() }
    }

    private var label: String {
        draft == 0 ? "No limit" : "\(draft) \(draft == 1 ? "tab" : "tabs") awake"
    }

    private func edit(_ value: Int) {
        draft = value
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        commitTask?.cancel()
        commitTask = nil
        let value = draft
        guard value != model.file.maxAwakeTabs else { return }
        Task { await model.saveKey(.maxAwakeTabs, .number(Double(value))) }
    }
}

/// `tabSleepAfterMinutes`: the usual choices, or Custom with a minutes field.
private struct SleepAfterRows: View {
    let model: SettingsModel

    @State private var choosingCustom = false
    @State private var draft: Double = 0
    @State private var issues: [ConfigIssue] = []
    @FocusState private var focused: Bool

    private static let choices: [Double] = [0, 5, 10, 15, 30, 60, 120]
    /// The picker's tag for Custom; never a saved value (negative minutes are refused).
    private static let custom: Double = -1

    private var saved: Double { model.file.tabSleepAfterMinutes }
    private var showsCustom: Bool { choosingCustom || !Self.choices.contains(saved) }

    var body: some View {
        Picker("Put background tabs to sleep after", selection: Binding(get: { showsCustom ? Self.custom : saved }, set: choose)) {
            ForEach(Self.choices, id: \.self) { minutes in
                Text(Self.label(minutes)).tag(minutes)
            }
            Divider()
            Text("Custom").tag(Self.custom)
        }
        .help("tabSleepAfterMinutes in config.json (0 = never)")
        .onAppear { draft = saved }
        .onChange(of: saved) { _, value in
            draft = value
            if Self.choices.contains(value) { choosingCustom = false }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        if showsCustom {
            LabeledContent("Minutes") {
                TextField("Minutes", value: $draft, format: .number)
                    .labelsHidden()
                    .frame(width: 80)
                    .focused($focused)
                    .onSubmit(commit)
                    .accessibilityLabel("Minutes before a background tab sleeps")
            }
            .help("tabSleepAfterMinutes in config.json (0 = never)")
            ConfigIssueList(issues: issues)
        }
    }

    private static func label(_ minutes: Double) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "1 hour"
        case 120: "2 hours"
        default: "\(Int(minutes)) minutes"
        }
    }

    private func choose(_ minutes: Double) {
        issues = []
        guard minutes != Self.custom else {
            choosingCustom = true
            draft = saved
            return
        }
        choosingCustom = false
        Task { await model.saveKey(.tabSleepAfterMinutes, .number(minutes)) }
    }

    private func commit() {
        let value = draft
        issues = model.issues(for: .tabSleepAfterMinutes) { $0.tabSleepAfterMinutes = value }
        guard value != saved, !issues.contains(where: { $0.severity == .error }) else { return }
        Task { await model.saveKey(.tabSleepAfterMinutes, .number(value)) }
    }
}

/// The live readout: Paddle's total and where it goes (the Activity popover's rows), and how many tabs are awake.
/// Open, it is a memory readout (`AppModel.beginMemoryReadout()`): measured on appear and every 5 s after while
/// Paddle is active, `showTabMemory` off too.
private struct MemoryReadout: View {
    private let app = AppModel.shared

    var body: some View {
        let breakdown = app.memoryBreakdown
        let tabs = app.allTabs
        let awake = tabs.count(where: \.isAwake)
        LabeledContent("Paddle is using") {
            Text(ProcessMemory.format(breakdown.total)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        ForEach(Self.rows(breakdown), id: \.title) { row in
            LabeledContent(row.title) {
                Text(ProcessMemory.format(row.bytes)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        LabeledContent("Tabs awake") {
            Text("\(awake) of \(tabs.count)").monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        HStack {
            Button("Sleep Background Tabs Now") { app.sleepBackgroundTabs() }
                .help("Sleeps every background tab that may sleep, as under memory pressure (Tabs > Sleep Background Tabs).")
            Spacer()
        }
        // The app's sampler refreshes these every 5 s while the pane is shown and Paddle is active, with a full
        // helper scan each time, as the Activity popover.
        .onAppear { app.beginMemoryReadout() }
        .onDisappear { app.endMemoryReadout() }
    }

    /// The same rows as the Activity popover; rows that are empty right now are left out, except the ones always
    /// present (tabs, shared processes, the app).
    private static func rows(_ b: ProcessBreakdown) -> [(title: String, bytes: UInt64)] {
        let rows: [(String, UInt64, Bool)] = [
            ("Tabs", b.tabs, true),
            ("Extensions", b.extensions, false),
            ("Service workers", b.serviceWorkers, false),
            ("Shared (GPU, Networking)", b.shared, true),
            ("Paddle app", b.app, true),
            ("Other (cached pages)", b.other, false),
            ("Helpers", b.helpers, false),
        ]
        return rows.filter { $0.2 || $0.1 > 0 }.map { (title: $0.0, bytes: $0.1) }
    }
}
