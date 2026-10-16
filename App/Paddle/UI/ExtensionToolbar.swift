import AppKit
import PaddleCore
import SwiftUI
import WebKit

/// One button per running extension with a toolbar action, right of the address bar: its icon, badge and enabled
/// state for the selected tab. A button redraws when WebKit reports a change to its own extension's action
/// (`LoadedExtension.actionGeneration`) and when the selected tab changes. A private window shows only the buttons
/// of extensions allowed in private windows.
struct ExtensionToolbar: View {
    let host: ExtensionHost
    let model: BrowserModel
    let tab: Tab?
    let isPrivate: Bool
    let placements: [String: ExtensionToolbarPlacement]

    var body: some View {
        let shown = host.loaded.filter { $0.hasAction && (!isPrivate || $0.allowedInPrivate) }
        let listed = shown.filter { (placements[$0.name] ?? .pinned) != .hidden }
        HStack(spacing: 2) {
            ForEach(shown.filter { (placements[$0.name] ?? .pinned) == .pinned }) { ext in
                ExtensionToolbarItem(ext: ext, tab: tab, pinnedFolders: Self.pinned(listed, placements))
            }
            // Always there while any extension has a button, as in Chrome: it lists every extension, pinned or not.
            if !listed.isEmpty {
                ExtensionOverflowButton(host: host, model: model, tab: tab, extensions: listed, placements: placements)
                    .frame(width: 26, height: 26)
            }
        }
    }

    static func pinned(_ extensions: [LoadedExtension], _ placements: [String: ExtensionToolbarPlacement]) -> [String] {
        extensions.filter { (placements[$0.name] ?? .pinned) == .pinned }.map(\.name)
    }
}

/// "Hide All Pinned Extensions in Menu" and "Pin All Extensions to Toolbar", for the puzzle button's menus and a
/// pinned button's right-click menu. Each is left out when it would do nothing.
@MainActor
enum ExtensionPlacementItems {
    static func add(to menu: NSMenu, pinned: [String], unpinned: [String]) {
        if !pinned.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Hide All Pinned Extensions in Menu") {
                Task { await AppModel.shared.setToolbarPlacement(.menu, folders: pinned) }
            })
        }
        if !unpinned.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Pin All Extensions to Toolbar") {
                Task { await AppModel.shared.setToolbarPlacement(.pinned, folders: unpinned) }
            })
        }
    }
}

/// The puzzle-piece button: every extension with a button (pinned ones too), each with its icon.
struct ExtensionOverflowButton: NSViewRepresentable {
    let host: ExtensionHost
    let model: BrowserModel
    let tab: Tab?
    let extensions: [LoadedExtension]
    let placements: [String: ExtensionToolbarPlacement]

    func makeNSView(context: Context) -> ExtensionOverflowNSButton { ExtensionOverflowNSButton() }

    func updateNSView(_ button: ExtensionOverflowNSButton, context: Context) {
        button.host = host
        button.model = model
        button.tab = tab
        button.extensions = extensions
        button.placements = placements
        button.setScale(context.environment.chromeScale)
    }
}

final class ExtensionOverflowNSButton: NSButton {
    static let identifier = NSUserInterfaceItemIdentifier("extension-overflow")

    var host: ExtensionHost?
    var model: BrowserModel?
    weak var tab: Tab?
    var extensions: [LoadedExtension] = []
    var placements: [String: ExtensionToolbarPlacement] = [:]

    private func isPinned(_ ext: LoadedExtension) -> Bool { (placements[ext.name] ?? .pinned) == .pinned }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        isBordered = false
        imagePosition = .imageOnly
        setScale(1)
        focusRingType = .none
        toolTip = "Extensions"
        setAccessibilityLabel("Extensions")
        identifier = Self.identifier
        target = self
        action = #selector(showMenu)
    }

    private var drawnScale: Double?

    /// Settings > Appearance > Text size, applied to the symbol as `chromeFont` applies it to the toolbar's others.
    func setScale(_ scale: Double) {
        guard scale != drawnScale else { return }
        drawnScale = scale
        image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")?
            .withSymbolConfiguration(.init(pointSize: 13 * scale, weight: .medium))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showMenu() {
        let menu = makeMenu()
        // Left edges aligned under the button (above it when the view is flipped).
        let y = isFlipped ? bounds.maxY + 4 : bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: self)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Unpinned first: those are the ones only reachable here.
        for ext in extensions.sorted(by: { !isPinned($0) && isPinned($1) }) {
            let action = ext.context.action(for: tab?.extensionTab)
            var title = ExtensionPermissionText.sanitize(ext.displayName, max: 60)
            let badge = String(ExtensionPermissionText.sanitize(action?.badgeText ?? "", max: 16).prefix(4))
            if !badge.isEmpty { title += " (\(badge))" }
            let item = ClosureMenuItem(title: title) { [weak self] in self?.perform(ext) }
            ExtensionActionNSButton.setMenuIcon(item, ext: ext, action: action)
            item.isEnabled = action?.isEnabled ?? false
            item.toolTip = isPinned(ext) ? "Pinned to the toolbar" : nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(pinMenuItem())
        addPlacementItems(to: menu)
        let model = self.model
        menu.addItem(ClosureMenuItem(title: "Manage Extensions…") { model?.showSettings(pane: .extensions) })
        return menu
    }

    /// "Pin to Toolbar": each extension with its icon, checked when pinned; choosing one toggles it.
    private func pinMenuItem() -> NSMenuItem {
        let pin = NSMenuItem(title: "Pin to Toolbar", action: nil, keyEquivalent: "")
        let pinMenu = NSMenu()
        for ext in extensions {
            let folder = ext.name
            let pinned = isPinned(ext)
            let pinItem = ClosureMenuItem(title: ExtensionPermissionText.sanitize(ext.displayName, max: 60)) {
                Task { await AppModel.shared.setToolbarPlacement(pinned ? .menu : .pinned, folder: folder) }
            }
            pinItem.state = pinned ? .on : .off
            ExtensionActionNSButton.setMenuIcon(pinItem, ext: ext, action: ext.context.action(for: tab?.extensionTab))
            pinMenu.addItem(pinItem)
        }
        pin.submenu = pinMenu
        return pin
    }

    private func addPlacementItems(to menu: NSMenu) {
        ExtensionPlacementItems.add(
            to: menu,
            pinned: extensions.filter(isPinned).map(\.name),
            unpinned: extensions.filter { !isPinned($0) }.map(\.name)
        )
    }

    /// Right-click: the placement items without the extension list.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(pinMenuItem())
        addPlacementItems(to: menu)
        menu.addItem(.separator())
        let model = self.model
        menu.addItem(ClosureMenuItem(title: "Manage Extensions…") { model?.showSettings(pane: .extensions) })
        return menu
    }

    private func perform(_ ext: LoadedExtension) {
        guard let host else { return }
        host.popups.noteClick(from: self, for: ext.context)
        host.performAction(ext, in: tab)
    }
}

/// Reads its extension's generation in its own body, so one extension's update redraws only its button.
private struct ExtensionToolbarItem: View {
    let ext: LoadedExtension
    let tab: Tab?
    let pinnedFolders: [String]

    var body: some View {
        ExtensionActionButton(ext: ext, tab: tab, generation: ext.actionGeneration, pinnedFolders: pinnedFolders)
            .frame(width: 26, height: 26)
    }
}

/// A real NSView, so the popover has something to anchor to and right-click shows a native menu.
struct ExtensionActionButton: NSViewRepresentable {
    let ext: LoadedExtension
    let tab: Tab?
    let generation: Int
    let pinnedFolders: [String]

    func makeNSView(context: Context) -> ExtensionActionNSButton {
        ExtensionActionNSButton(ext: ext)
    }

    func updateNSView(_ button: ExtensionActionNSButton, context: Context) {
        button.pinnedFolders = pinnedFolders
        button.update(ext: ext, tab: tab, generation: generation, scale: context.environment.chromeScale)
    }
}

final class ExtensionActionNSButton: NSButton {
    static func identifier(for extensionID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("extension-action-\(extensionID)")
    }

    /// The icon the button draws, 16 x 16 at the default text size: the action's, else the extension's, else a puzzle
    /// piece.
    /// The toolbar icon for an NSMenu row. macOS 27 hides menu item images unless the item asks to show them.
    static func setMenuIcon(_ item: NSMenuItem, ext: LoadedExtension, action: WKWebExtension.Action?) {
        item.image = toolbarIcon(ext: ext, action: action)
        item.preferredImageVisibility = .visible
    }

    static func toolbarIcon(ext: LoadedExtension, action: WKWebExtension.Action?, side: CGFloat = 16) -> NSImage? {
        if let icon = ext.icon(side: side, action: action) {
            return icon
        }
        let fallback = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        fallback?.size = NSSize(width: side, height: side)
        return fallback
    }

    private var ext: LoadedExtension
    private weak var tab: Tab?
    /// Every pinned extension's folder, for Hide All Pinned Extensions in Menu.
    var pinnedFolders: [String] = []
    private let badge = BadgeLabel()
    /// What the button last drew: an update with the same extension, action object and generation is skipped.
    private weak var drawnAction: WKWebExtension.Action?
    private var drawnGeneration: Int?
    private weak var drawnExtension: LoadedExtension?
    private var drawnScale: Double?

    init(ext: LoadedExtension) {
        self.ext = ext
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        identifier = Self.identifier(for: ext.id)
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        target = self
        action = #selector(clicked)
        badge.setAccessibilityElement(false)
        setAccessibilityValue("")
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var currentAction: WKWebExtension.Action? {
        ext.context.action(for: tab?.extensionTab)
    }

    /// `scale` is Settings > Appearance > Text size, applied to the icon as `chromeFont` applies it to text.
    func update(ext: LoadedExtension, tab: Tab?, generation: Int, scale: Double) {
        self.ext = ext
        self.tab = tab
        let action = currentAction
        if drawnGeneration == generation, drawnExtension === ext, drawnAction === action, drawnScale == scale { return }
        drawnGeneration = generation
        drawnExtension = ext
        drawnAction = action
        drawnScale = scale
        identifier = Self.identifier(for: ext.id)
        image = Self.toolbarIcon(ext: ext, action: action, side: 16 * scale)
        isEnabled = action?.isEnabled ?? false
        let rawLabel = action?.label ?? ""
        let label = ExtensionPermissionText.sanitize(rawLabel.isEmpty ? ext.displayName : rawLabel, max: 120)
        toolTip = label
        setAccessibilityLabel(label)
        showBadge(Self.badgeText(action))
        needsLayout = true
    }

    /// Draws the badge and speaks it as the button's value (empty without one), since the badge view is not read.
    private func showBadge(_ text: String) {
        badge.text = text
        setAccessibilityValue(text)
    }

    /// At most four characters, as Chrome shows.
    private static func badgeText(_ action: WKWebExtension.Action?) -> String {
        String(ExtensionPermissionText.sanitize(action?.badgeText ?? "", max: 16).prefix(4))
    }

    override func layout() {
        super.layout()
        let size = badge.fittingSize
        // Bottom-right corner, overlapping the icon's edge a little as Safari and Chrome do.
        badge.frame = NSRect(x: bounds.maxX - size.width + 1, y: 1, width: size.width, height: size.height)
    }

    @objc private func clicked() {
        guard let host = ext.host else { return }
        // A click on the button of an open popup closes it, as in Safari and Chrome. The transient popover already
        // started closing on this click's mouse-down, so this also covers a popup that closed a moment ago.
        if host.popups.closeForToggle(ext.context) { return }
        currentAction?.hasUnreadBadgeText = false
        showBadge(Self.badgeText(currentAction))
        host.popups.noteClick(from: self, for: ext.context)
        host.performAction(ext, in: tab)
    }

    /// Right-click: Paddle's items, then the extension's own (fetched now, they change) under a "From <name>"
    /// header with sanitized titles, so an extension can't pass its items off as Paddle's.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let folder = ext.name
        menu.addItem(ClosureMenuItem(title: "Unpin from Toolbar") {
            Task { await AppModel.shared.setToolbarPlacement(.menu, folder: folder) }
        })
        menu.addItem(ClosureMenuItem(title: "Hide Button") {
            Task { await AppModel.shared.setToolbarPlacement(.hidden, folder: folder) }
        })
        ExtensionPlacementItems.add(to: menu, pinned: pinnedFolders, unpinned: [])
        menu.addItem(.separator())
        if ext.context.optionsPageURL != nil {
            let options = NSMenuItem(title: "Options…", action: #selector(openOptions), keyEquivalent: "")
            options.target = self
            menu.addItem(options)
        }
        let askAgain = NSMenuItem(title: "Ask About Permissions Again", action: #selector(askAboutPermissions), keyEquivalent: "")
        askAgain.target = self
        menu.addItem(askAgain)
        if let items = currentAction?.menuItems, !items.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "From \(ext.displayName)"))
            for item in items { menu.addItem(item.extensionSupplied()) }
        }
        return menu
    }

    @objc private func openOptions() {
        try? ext.host?.openOptionsPage(for: ext.context)
    }

    @objc private func askAboutPermissions() {
        let ext = self.ext
        guard let host = ext.host else { return }
        Task { await host.askAgain(ext) }
    }
}

extension NSMenuItem {
    /// A copy of an item WebKit built from extension text (`WKWebExtension.Action.menuItems`), safe to show: its
    /// title and its submenu's titles sanitized (no line breaks, bidi overrides or overlong text). A copy, because
    /// adding an item that is still in another menu raises an ObjC exception and WebKit's own item stays as it is.
    func extensionSupplied() -> NSMenuItem {
        let item = copy() as? NSMenuItem ?? self
        item.sanitizeTitles()
        return item
    }

    private func sanitizeTitles() {
        title = ExtensionPermissionText.sanitize(title, max: 80)
        submenu?.items.forEach { $0.sanitizeTitles() }
    }
}

/// The badge capsule: red, white bold 9 pt text, hidden when the text is empty.
private final class BadgeLabel: NSTextField {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            stringValue = text
            isHidden = text.isEmpty
            superview?.needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .systemFont(ofSize: 9, weight: .bold)
        textColor = .white
        lineBreakMode = .byClipping
        isHidden = true
        wantsLayer = true
        layer?.cornerRadius = 6
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let width = max(12, ceil(attributedStringValue.size().width) + 6)
        return NSSize(width: width, height: 12)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }
}
