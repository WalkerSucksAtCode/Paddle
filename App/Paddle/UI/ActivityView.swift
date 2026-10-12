import AppKit
import SwiftUI

/// Popover from the memory button: every tab's memory and sleep state, plus content-blocking status.
/// Other private windows' tabs are not listed one by one (their titles would show in any window), only counted.
struct ActivityView: View {
    let app: AppModel
    /// The window the popover belongs to; its own private tabs are listed.
    let browser: BrowserModel

    private func isListed(_ tab: Tab) -> Bool { !tab.isPrivate || tab.browser === browser }

    private var tabs: [Tab] {
        app.allTabs.filter(isListed).sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    private var hiddenPrivateTabs: [Tab] { app.allTabs.filter { !isListed($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tabs").font(.headline)
                Spacer()
                Text("Total \(ProcessMemory.format(app.totalWebMemory))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tabs) { tab in
                        row(tab)
                    }
                    if !hiddenPrivateTabs.isEmpty {
                        privateSummary(hiddenPrivateTabs)
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Button("Sleep Background Tabs") { app.sleepBackgroundTabs() }
                Spacer()
                Button("Reload Config") { Task { await app.reloadConfig() } }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Content blocking").font(.subheadline.weight(.semibold))
                if app.web.isUpdatingFilters {
                    Text("Updating filter lists…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(app.web.blockerStatus, id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(app.web.filterUpdateProblems.values.sorted(), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                }
            }
        }
        .padding(14)
        .frame(width: 380)
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
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))
            Spacer()
            Text(tab.isAwake ? (tab.memoryBytes.map(ProcessMemory.format) ?? "–") + (tab.sharesProcess ? "*" : "") : "asleep")
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
        }
        .help(tab.sharesProcess ? "* Shared with other tabs from the same site" : "")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.items) { item in
                        row(item)
                    }
                }
            }
            .frame(maxHeight: 360)
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
            } else if item.state == .finished, let url = item.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
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
