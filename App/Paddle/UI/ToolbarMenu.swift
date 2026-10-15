import AppKit
import PaddleCore
import SwiftUI

/// A menu item that runs a closure, for the toolbar menu's rows that aren't menu-bar commands.
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// AppKit calls this on the main thread, where the handler's isolation holds.
    @objc private func run() {
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}

/// The menu button at the right of the toolbar. Its menu is built each time it opens.
struct ToolbarMenuButton: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> ToolbarMenuNSButton { ToolbarMenuNSButton() }

    func updateNSView(_ view: ToolbarMenuNSButton, context: Context) {
        view.model = model
    }
}

final class ToolbarMenuNSButton: NSButton {
    var model: BrowserModel?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Menu")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        focusRingType = .none
        toolTip = "Menu"
        setAccessibilityLabel("Menu")
        identifier = NSUserInterfaceItemIdentifier("toolbar-menu")
        target = self
        action = #selector(showMenu)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func showMenu() {
        guard let model else { return }
        let menu = makeMenu(model: model)
        // Right edges aligned under the button (above it when the view is flipped).
        let y = isFlipped ? bounds.maxY + 4 : bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - menu.size.width, y: y), in: self)
    }

    /// The menu-bar commands, copied so their shortcuts match, with the Downloads and Extensions rows and the zoom row.
    private func makeMenu(model: BrowserModel) -> NSMenu {
        let menu = NSMenu()
        func addCommand(_ name: String, title: String? = nil) {
            if let item = MainMenu.copyOfItem(name, title: title) { menu.addItem(item) }
        }
        addCommand("newTab")
        addCommand("newWindow")
        addCommand("newPrivateWindow")
        menu.addItem(.separator())
        addCommand("showHistory", title: "History")
        addCommand("showBookmarks", title: "Bookmarks")
        addCommand("addToNewTabPage")
        addCommand("showDownloads", title: "Downloads")
        menu.addItem(ClosureMenuItem(title: "Extensions") { model.showSettings(pane: .extensions) })
        menu.addItem(.separator())
        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoom.view = ZoomMenuRowView(model: model)
        menu.addItem(zoom)
        menu.addItem(.separator())
        addCommand("print")
        addCommand("importFromBrowser")
        menu.addItem(.separator())
        addCommand("settings")
        return menu
    }
}

/// The Zoom row of the toolbar menu: "Zoom", then zoom out, the zoom percentage (click for actual size) and zoom in.
/// Plain AppKit, since a SwiftUI view in a menu item doesn't take its own clicks.
final class ZoomMenuRowView: NSView {
    private let model: BrowserModel
    private let label = NSTextField(labelWithString: "Zoom")
    private let zoomOutButton = NSButton()
    private let percentButton = NSButton()
    private let zoomInButton = NSButton()

    init(model: BrowserModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
        label.font = NSFont.menuFont(ofSize: 0)
        configureSymbolButton(zoomOutButton, symbol: "minus", help: "Zoom Out", action: #selector(zoomOutClicked))
        configureSymbolButton(zoomInButton, symbol: "plus", help: "Zoom In", action: #selector(zoomInClicked))
        percentButton.isBordered = false
        percentButton.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percentButton.toolTip = "Actual Size"
        percentButton.setAccessibilityLabel("Actual Size")
        percentButton.target = self
        percentButton.action = #selector(actualSizeClicked)
        percentButton.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, spacer, zoomOutButton, percentButton, zoomInButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        // 16, not 20: a label field draws its text 2 pt in, and this lines "Zoom" up with the item titles (measured).
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureSymbolButton(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.target = self
        button.action = action
    }

    @objc private func zoomOutClicked() { adjustZoom(by: -SitePolicy.zoomStep) }
    @objc private func zoomInClicked() { adjustZoom(by: SitePolicy.zoomStep) }

    @objc private func actualSizeClicked() {
        model.selectedTab?.setZoom(1)
        refresh()
    }

    private func adjustZoom(by delta: Double) {
        guard let tab = model.selectedTab, let webView = tab.webView else { return }
        tab.setZoom(webView.pageZoom + delta)
        refresh()
    }

    /// Enables the buttons only when the selected tab shows a web page (not the start page or Settings), and shows
    /// that page's zoom.
    private func refresh() {
        let tab = model.selectedTab
        let enabled = tab?.url != nil && tab?.webView != nil && tab?.settingsPane == nil
        // Explicit colours: a borderless button in a menu otherwise draws dimmer than the item titles (measured).
        let color: NSColor = enabled ? .labelColor : .disabledControlTextColor
        for button in [zoomOutButton, percentButton, zoomInButton] {
            button.isEnabled = enabled
            button.contentTintColor = color
        }
        label.textColor = color
        let zoom = tab?.webView?.pageZoom ?? 1
        percentButton.title = "\(Int((zoom * 100).rounded())) %"
    }
}
