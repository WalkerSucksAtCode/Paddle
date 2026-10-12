import AppKit
import PaddleCore

/// The permission alerts. Text comes from `ExtensionPermissionText`, so extension-supplied strings are sanitized
/// and the list is capped; the extension's icon tells the alerts apart from Paddle's own.
enum ExtensionPrompts {
    /// Before an extension first runs, or when a new version asks for more (`isUpgrade`: `lines` lists only the new
    /// items, while the answer covers the whole extension). App-modal, one at a time.
    static func install(name: String, icon: NSImage?, lines: [String], folder: String, isUpgrade: Bool) -> ExtensionInstallAnswer {
        let alert = NSAlert()
        alert.messageText = isUpgrade ? "“\(name)” wants more access" : "Allow “\(name)” to run in Paddle?"
        var text = lines.map { "• \($0)" }
        text.append("")
        if isUpgrade {
            text.append("Don't Allow turns it off. Only When I Click also takes away the sites it can already access.")
        }
        text.append("Folder: extensions/\(ExtensionPermissionText.sanitize(folder, max: 80))")
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
}
