import AppKit
import PaddleCore
import SwiftUI

/// Popover from the memory button: every tab's memory and sleep state, plus content-blocking status.
/// Other private windows' tabs are not listed one by one (their titles would show in any window), only counted.
struct ActivityView: View {
    let app: AppModel
    /// The window the popover belongs to; its own private tabs are listed.
    let browser: BrowserModel

    private func isListed(_ tab: Tab) -> Bool { !tab.isPrivate || tab.browser === browser }

    /// A Settings tab uses no memory and has no sleep state, so it isn't listed or counted.
    private var tabs: [Tab] {
        app.allTabs.filter { $0.settingsPane == nil && isListed($0) }.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    private var hiddenPrivateTabs: [Tab] { app.allTabs.filter { $0.settingsPane == nil && !isListed($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tabs").font(.headline)
                Spacer()
                Text("Total \(ProcessMemory.format(app.totalWebMemory))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            FittedScrollView(maxHeight: 320) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tabs) { tab in
                        row(tab)
                    }
                    if !hiddenPrivateTabs.isEmpty {
                        privateSummary(hiddenPrivateTabs)
                    }
                }
            }

            breakdownRows

            if let reason = app.power.reason {
                let policy = app.effectiveSleepPolicy
                Label(
                    "Saving power (\(reason)): \(policy.sleepAfter > 0 ? "tabs sleep after \(Int(policy.sleepAfter / 60)) min" : "idle sleep is off")\(policy.maxAwakeTabs > 0 ? ", at most \(policy.maxAwakeTabs) awake" : "").",
                    systemImage: "leaf"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("Sleep Background Tabs") { app.sleepBackgroundTabs() }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Content blocking").font(.subheadline.weight(.semibold))
                if app.web.isUpdatingFilters {
                    Text("Updating filter lists…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                // One plain line per list ("easylist: 62,141 rules"); the converter's statistics and what it couldn't
                // cover wait under Details. Keyed by position: a line keeps its identity while the lists compile.
                ForEach(app.web.blockerLines.indices, id: \.self) { index in
                    let line = app.web.blockerLines[index]
                    Text(Self.shortLine(line.text)).font(.system(size: 11)).foregroundStyle(.secondary).help(line.text)
                }
                if app.web.blockerLines.contains(where: { $0.summary != nil || Self.shortLine($0.text) != $0.text }) {
                    SettingsDisclosure(title: "Details") {
                        ForEach(app.web.blockerLines.indices, id: \.self) { index in
                            let line = app.web.blockerLines[index]
                            Text(line.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let summary = line.summary {
                                CoverageDisclosure(summary: summary, scriptletsOn: app.config.scriptlets)
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
                ForEach(app.web.filterUpdateProblems.values.sorted(), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        // Fresh numbers every 5 s while open, with a full helper scan each time.
        .onAppear { app.beginMemoryReadout() }
        .onDisappear { app.endMemoryReadout() }
    }

    /// A block list's status line without its parenthesised statistics: "easylist: 62,141 rules".
    private static func shortLine(_ text: String) -> String {
        text.components(separatedBy: " (").first ?? text
    }

    /// Where the total goes: every WebContent process lands in one row, plus the shared processes, the app and
    /// the helpers macOS holds Paddle responsible for.
    /// Rows that are empty right now (no extension running, no workers, nothing cached) are left out.
    private var breakdownRows: some View {
        let b = app.memoryBreakdown
        let rows: [(String, UInt64, Bool)] = [
            ("Tabs", b.tabs, true),
            ("Extensions", b.extensions, false),
            ("Service workers", b.serviceWorkers, false),
            ("Shared (GPU, Networking)", b.shared, true),
            ("Paddle app", b.app, true),
            ("Other (cached pages)", b.other, false),
            ("Helpers", b.helpers, false),
        ]
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(rows.filter { $0.2 || $0.1 > 0 }, id: \.0) { row in
                HStack {
                    Text(row.0)
                    Spacer()
                    Text(ProcessMemory.format(row.1)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// One line for other private windows: tab count and memory, no titles and no way to bring them forward.
    private func privateSummary(_ tabs: [Tab]) -> some View {
        let bytes = tabs.compactMap(\.memoryBytes).reduce(0, +)
        return HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10))
                .frame(width: 12, height: 12)
            Text("Other private windows (\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs"))")
                .lineLimit(1)
                .font(.system(size: 12))
            Spacer()
            Text(bytes > 0 ? ProcessMemory.format(bytes) : "–")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    private func row(_ tab: Tab) -> some View {
        HStack(spacing: 8) {
            Glyph(name: tab.isAwake ? "surf-tab-awake" : "surf-tab-sleep", size: 12)
                .accessibilityHidden(true)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))
            Spacer()
            HStack(spacing: 4) {
                if tab.isFrozen { Text("frozen") }
                Text(tab.isAwake ? (tab.memoryBytes.map(ProcessMemory.format) ?? "–") + (tab.sharesProcess ? "*" : "") : "asleep")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            Button(tab.isAwake ? "Sleep" : "Show") {
                if tab.isAwake, tab.browser?.selectedID != tab.id {
                    tab.sleep()
                    app.sampleMemory()
                } else if let browser = tab.browser {
                    browser.select(tab)
                    browser.controller?.window?.makeKeyAndOrderFront(nil)
                }
            }
            .controlSize(.small)
            .disabled(tab.isAwake && tab.browser?.selectedID == tab.id)
            .accessibilityLabel("\(tab.isAwake ? "Sleep" : "Show") \(tab.displayTitle)")
        }
        .help(tab.sharesProcess ? "* Shared with other tabs from the same site" : "")
    }
}

/// "Not covered" for one installed block list: what the converter left out of it, by reason, with the scriptlet note
/// in the disclosure. Plain text, so VoiceOver reads each line.
private struct CoverageDisclosure: View {
    let summary: RuleListSummary
    let scriptletsOn: Bool

    var body: some View {
        if let notCovered = summary.notCoveredText(scriptletsOn: scriptletsOn) {
            DisclosureGroup {
                Text(summary.scriptletText(scriptletsOn: scriptletsOn) ?? "The rest of this list is in effect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text(notCovered)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let scriptlets = summary.scriptletText(scriptletsOn: scriptletsOn) {
            Text(scriptlets)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DownloadsView: View {
    let store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { store.clearFinished() }
                    .disabled(store.items.allSatisfy { $0.state == .running })
            }
            FittedScrollView(maxHeight: 360) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.items) { item in
                        row(item)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle).font(.system(size: 12))
                switch item.state {
                case .running:
                    // Servers that don't send a size get a moving bar and a byte count, not a bar stuck at zero.
                    if let expected = item.expectedBytes {
                        ProgressView(value: item.fraction).controlSize(.small)
                        status("\(bytes(item.receivedBytes)) of \(bytes(expected))")
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                        status(bytes(item.receivedBytes))
                    }
                case .finished:
                    status("Done")
                case .failed(let message):
                    status("Failed: \(message)").lineLimit(2)
                case .cancelled:
                    status("Cancelled")
                }
            }
            Spacer()
            if item.state == .running {
                Button { store.cancel(item) } label: { Image(systemName: "xmark.circle") }
                    .help("Cancel")
                    .accessibilityLabel("Cancel download of \(item.filename)")
            } else if item.state == .finished, let url = item.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(item.filename) in Finder")
            }
        }
        .buttonStyle(.borderless)
    }

    private func status(_ text: String) -> Text {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A vertical scroll view as tall as its content up to `maxHeight`: a plain `ScrollView` in a popover takes its whole
/// maximum, leaving a gap under a short list.
private struct FittedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}
