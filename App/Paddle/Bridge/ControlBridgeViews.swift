import AppKit
import PaddleCore
import SwiftUI

/// The toolbar's "Claude connected" label while a session uses the control bridge, in every window. Clicking it
/// offers to disconnect.
struct BridgeIndicator: View {
    @State private var confirming = false

    var body: some View {
        if ControlBridge.shared.clientCount > 0 {
            Button { confirming = true } label: {
                Label("Claude connected", systemImage: "link")
                    .chromeFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("A Claude session is controlling Paddle through the control bridge. Click to disconnect it.")
            .confirmationDialog("Disconnect Claude?", isPresented: $confirming) {
                Button("Disconnect", role: .destructive) { ControlBridge.shared.disconnectAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Connected sessions lose access until they reconnect. The bridge stays on; turn it off in Settings > Advanced.")
            }
        }
    }
}

/// Settings > Advanced > Control bridge: the switch, the setup command, connected sessions and the recent calls.
struct ControlBridgeSection: View {
    let model: SettingsModel
    private var bridge: ControlBridge { .shared }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.file.controlBridge },
                set: { on in Task { await model.save([ConfigChange(PaddleConfig.CodingKeys.controlBridge.rawValue, .bool(on))]) } }
            )) {
                Text("Let Claude sessions control Paddle (local MCP)")
                Text("Claude Code can list tabs, read and snapshot pages, run menu commands and change settings, through a socket only your account can open. Never a network port.")
            }
            .help("controlBridge in config.json")
            .disabled(model.controlsDisabled)
            Toggle(isOn: Binding(
                get: { model.file.controlBridgeScripts },
                set: { on in Task { await model.save([ConfigChange(PaddleConfig.CodingKeys.controlBridgeScripts.rawValue, .bool(on))]) } }
            )) {
                Text("Allow page scripts")
                Text("Lets Claude run scripts in pages (run_js). A script can read what the page's own scripts can, typed passwords included.")
            }
            .help("controlBridgeScripts in config.json. Off by default, even with the bridge on.")
            .disabled(model.controlsDisabled || !model.file.controlBridge)

            if AppModel.shared.config.controlBridge {
                LabeledContent {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ControlBridge.setupCommand, forType: .string)
                    }
                    .help("Copies the command; run it once in Terminal")
                } label: {
                    Text("Setup command")
                    Text(ControlBridge.setupCommand).monospaced().textSelection(.enabled)
                }
                if let error = bridge.startError {
                    Label {
                        Text("The bridge couldn't start: \(error)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Warning")
                    }
                }
                LabeledContent("Connected sessions", value: "\(bridge.clientCount)")
                DisclosureGroup("Recent calls (\(bridge.audit.count))") {
                    if bridge.audit.isEmpty {
                        SettingsCaption("None yet.")
                    }
                    ForEach(bridge.audit.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.octagon")
                                .accessibilityLabel(entry.ok ? "OK" : "Error")
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                            Text(entry.tool).monospaced()
                            Text(entry.summary).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
            }
        } header: {
            Text("Control bridge")
        } footer: {
            SettingsCaption("Private windows are invisible to the bridge. No tool reads the keychain, downloads or files outside Paddle's folder, and none but Run JavaScript can reach cookies or typed passwords: its guard is not a sandbox, so a script can reach what the page's own scripts can. The clipboard is off limits. Page text, titles and script results are marked as untrusted page content.")
        }
    }
}
