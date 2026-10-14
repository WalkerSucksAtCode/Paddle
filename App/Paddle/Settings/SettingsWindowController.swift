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

}

/// One size for every pane, so switching panes never moves the toolbar or resizes the window; each pane scrolls
/// inside it. Wide enough for the Sites table's seven columns. The window is resizable from there.
private enum SettingsWindowSize {
    static let initial = CGSize(width: 760, height: 640)
    static let minimum = CGSize(width: 700, height: 440)
}

/// Paddle > Settings… (⌘,): a preferences-style toolbar of panes over `config.json`. Exists only while open:
/// closing drops the window, every pane, the model and the config watcher (its descriptors and debounce).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private static let paneKey = "settingsPane"

    private let model = SettingsModel()
    private var watcher: ConfigWatcher?
    /// The panes' tab view, kept so `show(pane:)` can select one.
    private let paneTabs: SettingsTabViewController

    /// Opens Settings, on `pane` when one is given (selected and remembered, as a click on its toolbar item would).
    static func show(pane: SettingsPane? = nil) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        if let pane { controller.select(pane) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Selects `pane` and saves it under `paneKey`, as `onSelect` does for a click.
    private func select(_ pane: SettingsPane) {
        paneTabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane) ?? 0
        UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey)
    }

    private init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane, model: model))
            // No preferred size: the tab view controller would resize the window to each pane's.
            host.sizingOptions = []
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
        paneTabs = tabs

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsWindowSize.minimum
        window.setContentSize(SettingsWindowSize.initial)
        super.init(window: window)
        window.delegate = self
        // A new name: frames saved under "PaddleSettings" were each pane's own size.
        window.setFrameAutosaveName("PaddleSettingsWindow")
        if !window.setFrameUsingName("PaddleSettingsWindow") { window.center() }

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

    func windowWillClose(_ notification: Notification) {
        watcher?.cancel()
        watcher = nil
        Self.shared = nil
    }
}

/// Remembers the selected pane. The window keeps its size across panes (`SettingsWindowSize`).
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) { onSelect?(pane) }
    }
}

/// One pane: the banner above the pane, filling the window; forms scroll inside it, tables scroll themselves.
private struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                SettingsBanner(banner: banner, model: model)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

/// A collapsed group (collapsed until opened) whose whole label opens it, not only the chevron: a plain
/// `DisclosureGroup` in a grouped form answers clicks on its chevron alone. `isExpanded` nil keeps the state here.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    var isExpanded: Binding<Bool>?
    var accessibilityLabel: String?
    @ViewBuilder var content: Content
    @State private var expandedHere = false

    var body: some View {
        let expanded = isExpanded ?? $expandedHere
        DisclosureGroup(isExpanded: expanded) {
            content
        } label: {
            Button(title) { withAnimation { expanded.wrappedValue.toggle() } }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel ?? title)
        }
    }
}

/// The form style every pane uses: grouped, scrolling inside the pane.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}
