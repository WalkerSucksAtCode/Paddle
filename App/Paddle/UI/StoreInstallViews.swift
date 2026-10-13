import AppKit
import PaddleCore
import SwiftUI

/// Extensions > Install from Link…: a sheet on the front browser window, or a small window when there is none.
enum InstallFromLinkPanel {
    /// The open panel; one at a time.
    private(set) static var window: NSWindow?

    static func show(over parent: NSWindow?) {
        if let window {
            (window.sheetParent ?? window).makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.title = "Install Extension from Link"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: InstallFromLinkView())
        window = panel
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    static func close() {
        guard let panel = window else { return }
        window = nil
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.close()
        }
    }
}

private struct InstallFromLinkView: View {
    @State private var text = ""
    @State private var message: String?
    @State private var failed = false
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a Chrome Web Store link or a 32-letter extension id.")
            TextField("https://chromewebstore.google.com/detail/…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(busy)
                .onSubmit(install)
                .accessibilityLabel("Chrome Web Store link or extension id")
            HStack(alignment: .top, spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).accessibilityLabel("Installing")
                    Text("Downloading and checking…").foregroundStyle(.secondary)
                } else if let message {
                    Label(message, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(message != nil && !failed ? "Close" : "Cancel") {
                    task?.cancel()
                    InstallFromLinkPanel.close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Install", action: install)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func install() {
        guard !busy else { return }
        guard let link = StoreLink.parse(text) else {
            show("That isn't a Chrome Web Store link or a 32-letter extension id.", failed: true)
            return
        }
        if case .mozillaAddons = link {
            show("Firefox add-on installs aren't available yet.", failed: true)
            return
        }
        busy = true
        message = nil
        AccessibilityNotification.Announcement("Installing").post()
        task = Task {
            let outcome = await StoreInstaller.shared.install(link, window: InstallFromLinkPanel.window)
            busy = false
            show(outcome.message, failed: !outcome.succeeded)
        }
    }

    private func show(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
        AccessibilityNotification.Announcement(text).post()
    }
}

/// The slim bar under the toolbar while the selected tab shows a Chrome Web Store detail page: "Install <name> in
/// Paddle", or "installed" with no button. Paddle's own view; nothing runs in the page.
struct StoreInstallBar: View {
    let id: String
    let pageTitle: String
    let model: BrowserModel

    private var installer: StoreInstaller { .shared }

    private var name: String {
        StoreInstall.storePageName(title: pageTitle).map { ExtensionPermissionText.sanitize($0) } ?? id
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension").accessibilityHidden(true)
            if installer.installing == id {
                ProgressView().controlSize(.small).accessibilityLabel("Installing")
                Text("Installing \(name)…")
                Spacer()
            } else if installer.isInstalled(chromeID: id) {
                Text(installer.lastMessage[id] ?? "\(name) is installed in Paddle.")
                    .lineLimit(2)
                Spacer()
            } else {
                Text(installer.lastMessage[id] ?? "Install \(name) in Paddle")
                    .lineLimit(2)
                Spacer()
                Button("Install") { install() }
                    .disabled(installer.installing != nil)
                    .help("Download it from the Chrome Web Store, check its signatures and install it in Paddle")
                    .accessibilityLabel("Install \(name) in Paddle")
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func install() {
        let window = model.controller?.window
        AccessibilityNotification.Announcement("Installing \(name)").post()
        Task {
            let outcome = await StoreInstaller.shared.install(.chromeWebStore(id: id), window: window)
            AccessibilityNotification.Announcement(outcome.message).post()
        }
    }
}
