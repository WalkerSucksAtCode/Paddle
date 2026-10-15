import AppKit
import WebKit

/// Fills the "Inspect Extension Background Page" submenu each time it opens: one item per loaded extension that has
/// background content, titled with the extension's name, or a disabled line when there is none. The main menu and the
/// toolbar menu's Developer Tools submenu both use it.
final class DevelopMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = DevelopMenuDelegate()

    /// The submenu item, with this delegate and its placeholder line.
    static func backgroundPagesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Inspect Extension Background Page", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        menu.delegate = shared
        item.submenu = menu
        shared.fill(menu)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        // The front window's profile: another profile's background pages aren't listed.
        let withBackground = AppModel.shared.frontExtensions.loaded.filter { $0.webExtension.hasBackgroundContent }
        for ext in withBackground {
            let item = NSMenuItem(title: ext.displayName, action: #selector(inspect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ext
            menu.addItem(item)
        }
        if withBackground.isEmpty {
            // No action: AppKit shows it disabled.
            menu.addItem(NSMenuItem(title: "No Extension Background Pages", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func inspect(_ sender: NSMenuItem) {
        guard let ext = sender.representedObject as? LoadedExtension else { return }
        WebInspector.inspectBackgroundPage(of: ext.context)
    }
}
