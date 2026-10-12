import AppKit
import SwiftUI

/// The strip above every pane when config.json needs attention: an icon and text (never colour alone) plus the
/// actions for that state. `SettingsModel` announces each new state to VoiceOver.
struct SettingsBanner: View {
    let banner: SettingsModel.Banner
    let model: SettingsModel
    @State private var confirmingReset: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(banner.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isWarning ? .yellow : .accentColor)
                    .accessibilityLabel(isWarning ? "Warning" : "Note")
            }
            HStack(spacing: 8) {
                actions
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Reset \(confirmingReset ?? "") to its default?",
            isPresented: Binding(get: { confirmingReset != nil }, set: { if !$0 { confirmingReset = nil } }),
            presenting: confirmingReset
        ) { key in
            Button("Reset \(key)", role: .destructive) { Task { await model.resetKey(key) } }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            if case .invalid(_, _, let badValue?) = banner {
                Text("Removes \"\(key)\": \(badValue) from config.json, so Paddle uses the default. Nothing else in the file changes.")
            } else {
                Text("Removes \"\(key)\" from config.json, so Paddle uses the default. Nothing else in the file changes.")
            }
        }
    }

    private var isWarning: Bool {
        if case .unapplied = banner { return false }
        return true
    }

    @ViewBuilder private var actions: some View {
        switch banner {
        case .invalid(_, let key, _):
            Button("Edit config.json…") { SettingsBanner.editConfig() }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.config]) }
            Button("Try Again") { model.refresh(force: true) }
            if let key {
                Button("Reset \(key) to Default…") { confirmingReset = key }
            }
        case .unapplied:
            Button("Apply Now") { Task { await model.applyNow() } }
        case .conflict:
            Button("Use the File's Value") { model.useFilesValue() }
            Button("Save Mine") { Task { await model.saveMine() } }
        case .writeFailed:
            Button("Edit config.json…") { SettingsBanner.editConfig() }
            Button("Dismiss") { model.dismissFailure() }
        }
    }

    /// Opens config.json in the default editor for JSON (the old Settings menu item's job).
    static func editConfig() {
        NSWorkspace.shared.open(Paths.config)
    }
}
