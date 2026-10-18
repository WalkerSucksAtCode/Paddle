import AppKit
import PaddleCore

/// The permission alerts. Text comes from `ExtensionPermissionText`, so extension-supplied strings are sanitized
/// and the list is capped; the extension's icon tells the alerts apart from Paddle's own.
enum ExtensionPrompts {
    /// Before an extension first runs, or when a new version asks for more (`isUpgrade`: `lines` lists only the new
    /// items, while the answer covers the whole extension). `notice` is a plain sentence about what the extension can't
    /// do in Paddle (`ExtensionBlocking.notice`), set apart from the list. `profile`: the profile's name when there is
    /// more than one, since the answer applies to that profile only. App-modal, one at a time.
    static func install(
        name: String, icon: NSImage?, lines: [String], notice: String?, folder: String, isUpgrade: Bool, profile: String? = nil
    ) -> ExtensionInstallAnswer {
        let alert = NSAlert()
        alert.messageText = isUpgrade ? "“\(name)” wants more access" : "Allow “\(name)” to run in Paddle?"
        var text = lines.map { "• \($0)" }
        if let notice {
            text.append("")
            text.append(notice)
        }
        text.append("")
        if isUpgrade {
            text.append("Don't Allow turns it off. Only When I Click also takes away the sites it can already access.")
        }
        text.append("Folder: extensions/\(ExtensionPermissionText.sanitize(folder, max: 80))")
        if let profile { text.append("Profile: \(ExtensionPermissionText.sanitize(profile, max: 80))") }
        alert.informativeText = text.joined(separator: "\n")
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Only When I Click")
        alert.addButton(withTitle: "Don't Allow")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allow
        case .alertSecondButtonReturn: return .onlyWhenClicked
        default: return .deny
        }
    }

    /// A store update that asks for access the user hasn't granted, or whose certificate chain isn't confirmed
    /// (`ExtensionUpdater`). Allow swaps the new version in and grants what it asks for; Don't Allow keeps the current
    /// version running and skips this update. `lines` is empty when the update asks for nothing new. App-modal.
    static func update(
        name: String, icon: NSImage?, lines: [String], notice: String?, folder: String, from current: String, to version: String
    ) -> Bool {
        let old = ExtensionPermissionText.sanitize(current, max: 30)
        let alert = NSAlert()
        alert.messageText = "Update “\(name)” to \(ExtensionPermissionText.sanitize(version, max: 30))?"
        var text: [String] = []
        if !lines.isEmpty {
            text.append("It asks for access you haven't allowed yet:")
            text += lines.map { "• \($0)" }
        }
        if let notice {
            if !text.isEmpty { text.append("") }
            text.append(notice)
        }
        if !text.isEmpty { text.append("") }
        text.append("Don't Allow keeps version \(old) running and skips this update.")
        text.append("Folder: extensions/\(ExtensionPermissionText.sanitize(folder, max: 80))")
        alert.informativeText = text.joined(separator: "\n")
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A running extension asking for more (`permissions.request`, optional hosts). The caller presents it: as a
    /// sheet on the tab that asked, or app-modal.
    static func runtime(name: String, icon: NSImage?, lines: [String], host: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(name)” wants more access"
        var text = lines.map { "• \($0)" }
        if let host, !host.isEmpty {
            text.append("")
            text.append("Asked while you were on \(ExtensionPermissionText.sanitize(host))")
        }
        alert.informativeText = text.joined(separator: "\n")
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert
    }

    /// An extension that brings its own New Tab page, the first time New Tab opens while it runs. True: use it.
    /// App-modal; asked once per extension and profile.
    static func newTabPage(name: String, icon: NSImage?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let “\(name)” show its page in new tabs?"
        alert.informativeText = "New tabs open the extension's page instead of Paddle's New Tab. Change it later in Settings > General > New Tab."
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Use Its Page")
        alert.addButton(withTitle: "Keep Paddle's")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
