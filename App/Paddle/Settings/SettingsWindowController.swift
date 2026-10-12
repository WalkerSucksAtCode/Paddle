import AppKit
import SwiftUI

/// The Settings window's panes, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general, tabsMemory, privacy, sites, extensions, shortcuts, advanced

    var title: String {
        switch self {
        case .general: "General"
        case .tabsMemory: "Tabs & Memory"
        case .privacy: "Privacy & Blocking"
        case .sites: "Sites"
        case .extensions: "Extensions"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tabsMemory: "memorychip"
        case .privacy: "hand.raised"
        case .sites: "globe"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "command"
        case .advanced: "gearshape.2"
        }
    }

    /// Panes with a table get a fixed height and scroll inside it; the rest are as tall as their form.
    var fixedHeight: CGFloat? {
        switch self {
        case .sites, .shortcuts: 520
        default: nil
        }
    }

    static let width: CGFloat = 640
}

/// Paddle > Settings… (⌘,): a preferences-style toolbar of panes over `config.json`. Exists only while open:
/// closing drops the window, every pane, the model and the config watcher (its descriptors and debounce).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private static let paneKey = "settingsPane"

    private let model = SettingsModel()
    private var watcher: ConfigWatcher?

    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane, model: model))
            host.sizingOptions = [.preferredContentSize]
            // The window title follows the selected pane (`canPropagateSelectedChildViewControllerTitle`).
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let saved = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: saved) ?? 0
        tabs.onSelect = { pane in UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("PaddleSettings")
        if !window.setFrameUsingName("PaddleSettings") { window.center() }
        updatePaneHeightLimit()
        tabs.fitWindow(animated: false)

        watcher = ConfigWatcher { [weak self] in self?.model.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// File > Close Tab (⌘W) closes this window, as it does History and Bookmarks.
    @objc func paddleCloseTab(_ sender: Any?) { window?.performClose(sender) }

    /// A backstop for any edit the watcher missed; the stamp check makes it free when nothing changed.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updatePaneHeightLimit()
    }

    /// A pane may be as tall as the window's screen allows, less the title bar and toolbar, room for the banner
    /// and a margin; taller panes scroll.
    private func updatePaneHeightLimit() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        model.maxPaneHeight = max(320, screen.visibleFrame.height - chrome - 120)
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.cancel()
        watcher = nil
        Self.shared = nil
    }
}

/// Remembers the selected pane and sizes the window to it. The toolbar style also resizes on selection; doing it
/// here too covers a pane whose height changes while shown (the banner appearing) and the first pane on open.
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) { onSelect?(pane) }
        fitWindow(animated: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        fitWindow(animated: true)
    }

    /// Resizes the window to the selected pane's preferred size, keeping its top edge in place.
    func fitWindow(animated: Bool) {
        guard let window = view.window,
              let size = tabViewItems[safe: selectedTabViewItemIndex]?.viewController?.preferredContentSize,
              size.width > 0, size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.size != size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        // Keeping the top edge can push the bottom off the screen; move the window up instead.
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = min(visible.minY, visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One pane: the banner above the pane's form, at the fixed width (and, for table panes, height).
private struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsModel
    /// The form's own height, measured, so a pane taller than the screen scrolls instead of running off it.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                SettingsBanner(banner: banner, model: model)
            }
            if pane.fixedHeight == nil {
                ScrollView(.vertical) {
                    content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: contentHeight > 0 ? min(contentHeight, model.maxPaneHeight) : nil)
            } else {
                content
            }
        }
        .frame(width: SettingsPane.width, height: pane.fixedHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: pane.fixedHeight == nil)
    }


    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralPane(model: model)
        case .tabsMemory: TabsMemoryPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .sites: SitesPane(model: model)
        case .extensions: ExtensionsPane(model: model)
        case .shortcuts: ShortcutsPane(model: model)
        case .advanced: AdvancedPane(model: model)
        }
    }
}

/// The form style every pane uses: grouped, not scrolling, as tall as its content, so the hosting controller
/// reports a real preferred height (an unbounded grouped form reports 10000).
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
