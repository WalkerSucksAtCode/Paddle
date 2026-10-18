import AppKit
import PaddleCore
import SwiftUI
import UniformTypeIdentifiers

/// Popover from the memory button: every tab's memory and sleep state, plus content-blocking status.
/// Other private windows' tabs are not listed one by one (their titles would show in any window), only counted.
struct ActivityView: View {
    let app: AppModel
    /// The window the popover belongs to; its own private tabs are listed.
    let browser: BrowserModel
    @Environment(\.chromeScale) private var scale

    /// Tabs of another profile are not listed either: their titles belong to that profile's windows.
    private func isListed(_ tab: Tab) -> Bool { tab.browser === browser || (!tab.isPrivate && tab.profileID == browser.profileID) }

    /// A Settings tab uses no memory and has no sleep state, so it isn't listed or counted.
    private var tabs: [Tab] {
        app.allTabs.filter { $0.settingsPane == nil && isListed($0) }.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    private var hiddenPrivateTabs: [Tab] { app.allTabs.filter { $0.settingsPane == nil && $0.isPrivate && !isListed($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tabs").font(.headline)
                Spacer()
                Text("Total \(ProcessMemory.format(app.totalWebMemory))")
                    .chromeFont(size: 11, monospacedDigit: true)
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
                .chromeFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("Sleep Background Tabs") { app.sleepBackgroundTabs() }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Content blocking").font(.subheadline.weight(.semibold))
                if app.web.isUpdatingFilters {
                    Text("Updating filter lists…").chromeFont(size: 11).foregroundStyle(.secondary)
                }
                // One plain line per list ("easylist: 62,141 rules"); the converter's statistics and what it couldn't
                // cover wait under Details. Keyed by position: a line keeps its identity while the lists compile.
                ForEach(app.web.blockerLines.indices, id: \.self) { index in
                    let line = app.web.blockerLines[index]
                    Text(Self.shortLine(line.text)).chromeFont(size: 11).foregroundStyle(.secondary).help(line.text)
                }
                if app.web.blockerLines.contains(where: { $0.summary != nil || Self.shortLine($0.text) != $0.text }) {
                    SettingsDisclosure(title: "Details") {
                        ForEach(app.web.blockerLines.indices, id: \.self) { index in
                            let line = app.web.blockerLines[index]
                            Text(line.text)
                                .chromeFont(size: 11)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let summary = line.summary {
                                CoverageDisclosure(summary: summary, scriptletsOn: app.config.scriptlets)
                            }
                        }
                    }
                    .chromeFont(size: 11)
                }
                ForEach(app.web.filterUpdateProblems.values.sorted(), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .chromeFont(size: 11)
                }
            }
        }
        .padding(14)
        .frame(width: 380 * scale)
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
        .chromeFont(size: 11)
        .foregroundStyle(.secondary)
    }

    /// One line for other private windows: tab count and memory, no titles and no way to bring them forward.
    private func privateSummary(_ tabs: [Tab]) -> some View {
        let bytes = tabs.compactMap(\.memoryBytes).reduce(0, +)
        return HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .chromeFont(size: 10)
                .frame(width: 12, height: 12)
            Text("Other private windows (\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs"))")
                .lineLimit(1)
                .chromeFont(size: 12)
            Spacer()
            Text(bytes > 0 ? ProcessMemory.format(bytes) : "–")
                .chromeFont(size: 11, monospacedDigit: true)
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
                .chromeFont(size: 12)
            Spacer()
            HStack(spacing: 4) {
                if tab.isFrozen { Text("frozen") }
                Text(tab.isAwake ? (tab.memoryBytes.map(ProcessMemory.format) ?? "–") + (tab.sharesProcess ? "*" : "") : "asleep")
            }
            .chromeFont(size: 11, monospacedDigit: true)
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
                    .chromeFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text(notCovered)
                    .chromeFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let scriptlets = summary.scriptletText(scriptletsOn: scriptletsOn) {
            Text(scriptlets)
                .chromeFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DownloadsView: View {
    let store: DownloadStore
    /// The window's privacy: a normal window doesn't list private downloads.
    let isPrivate: Bool
    /// The window's profile's folder (`downloadFolder` may be set per profile).
    var folder: URL = DownloadStore.folder
    @Environment(\.chromeScale) private var scale

    private var listed: [DownloadItem] { store.items(forPrivateWindow: isPrivate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { store.clearFinished(inPrivateWindow: isPrivate) }
                    .disabled(listed.allSatisfy { $0.state == .running })
            }
            FittedScrollView(maxHeight: 360) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(listed) { item in
                        DownloadRow(item: item, store: store)
                    }
                }
            }
            if listed.isEmpty {
                Text("No downloads this session.").chromeFont(size: 11).foregroundStyle(.secondary)
            }
            Divider()
            Button("Open Downloads Folder") { NSWorkspace.shared.open(folder) }
                .buttonStyle(.borderless)
                .chromeFont(size: 12)
        }
        .padding(14)
        .frame(width: 340 * scale)
    }
}

/// One download: the file's icon, name and progress (bytes, speed, time left) or result. A finished row opens the
/// file on click and drags out as the file; the right-click menu has Open, Show in Finder, Copy Download Link, Retry
/// and Remove from List, as in Chrome and Safari.
private struct DownloadRow: View {
    let item: DownloadItem
    let store: DownloadStore
    @State private var hovering = false

    private var exists: Bool {
        item.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                .opacity(item.state == .finished && exists ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle).chromeFont(size: 12)
                switch item.state {
                case .running:
                    // Servers that don't send a size get a moving bar and a byte count, not a bar stuck at zero.
                    if item.expectedBytes != nil {
                        ProgressView(value: item.fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    status(progressText)
                case .finished:
                    status(exists ? Self.bytes(item.receivedBytes) : "Deleted or moved")
                case .failed(let message):
                    status("Failed: \(message)").lineLimit(2)
                case .cancelled:
                    status("Cancelled")
                }
            }
            Spacer(minLength: 4)
            switch item.state {
            case .running:
                Button { store.cancel(item) } label: { Image(systemName: "xmark.circle") }
                    .help("Cancel")
                    .accessibilityLabel("Cancel download of \(item.filename)")
            case .finished:
                if let url = item.destination, exists {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                        .help("Show in Finder")
                        .accessibilityLabel("Show \(item.filename) in Finder")
                }
            case .failed, .cancelled:
                if store.canRetry(item) {
                    Button { store.retry(item) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Retry")
                    .accessibilityLabel("Retry download of \(item.filename)")
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && item.state == .finished && exists ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(item) }
        .onDrag {
            guard item.state == .finished, let url = item.destination, exists else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu { menu }
        .buttonStyle(.borderless)
        .help(item.state == .finished && exists ? "Click to open, or drag the file out" : "")
    }

    @ViewBuilder
    private var menu: some View {
        if item.state == .finished, exists, let url = item.destination {
            Button("Open") { store.open(item) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if let source = DownloadStore.sourceURL(of: item), ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            Button("Copy Download Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        if item.state != .running {
            if store.canRetry(item) { Button("Retry") { store.retry(item) } }
            Divider()
            Button("Remove from List") { store.remove(item) }
        } else {
            Button("Cancel") { store.cancel(item) }
        }
    }

    private var icon: NSImage {
        if item.state == .finished, let url = item.destination, exists { return NSWorkspace.shared.icon(forFile: url.path) }
        let ext = (item.filename as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    /// "12.4 MB of 57.8 MB — 3.1 MB/s, 15 s left", as Chrome's row reads.
    private var progressText: String {
        let received = Self.bytes(item.receivedBytes)
        let elapsed = Date().timeIntervalSince(item.startedAt)
        let rate = elapsed > 1 ? Double(item.receivedBytes) / elapsed : 0
        var text = item.expectedBytes.map { "\(received) of \(Self.bytes($0))" } ?? received
        if rate > 0 {
            text += " — \(Self.bytes(Int64(rate)))/s"
            if let expected = item.expectedBytes, expected > item.receivedBytes {
                let left = Double(expected - item.receivedBytes) / rate
                let formatter = DateComponentsFormatter()
                formatter.unitsStyle = .abbreviated
                formatter.maximumUnitCount = 1
                if let remaining = formatter.string(from: max(1, left)) { text += ", \(remaining) left" }
            }
        }
        return text
    }

    private func status(_ text: String) -> some View {
        Text(text).chromeFont(size: 11).foregroundStyle(.secondary)
    }

    private static func bytes(_ count: Int64) -> String {
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
