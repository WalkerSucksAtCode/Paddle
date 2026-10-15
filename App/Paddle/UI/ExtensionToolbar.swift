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
        let inMenu = shown.filter { (placements[$0.name] ?? .pinned) == .menu }
        HStack(spacing: 2) {
            ForEach(shown.filter { (placements[$0.name] ?? .pinned) == .pinned }) { ext in
                ExtensionToolbarItem(ext: ext, tab: tab)
            }
            if !inMenu.isEmpty {
                ExtensionOverflowButton(host: host, model: model, tab: tab, extensions: inMenu)
                    .frame(width: 26, height: 26)
            }
        }
    }
}

/// The puzzle-piece button that holds the extensions placed `menu`.
struct ExtensionOverflowButton: NSViewRepresentable {
    let host: ExtensionHost
    let model: BrowserModel
    let tab: Tab?
    let extensions: [LoadedExtension]

    func makeNSView(context: Context) -> ExtensionOverflowNSButton { ExtensionOverflowNSButton() }

    func updateNSView(_ button: ExtensionOverflowNSButton, context: Context) {
        button.host = host
        button.model = model
        button.tab = tab
        button.extensions = extensions
        button.setScale(context.environment.chromeScale)
    }
}

final class ExtensionOverflowNSButton: NSButton {
    static let identifier = NSUserInterfaceItemIdentifier("extension-overflow")

    var host: ExtensionHost?
    var model: BrowserModel?
    weak var tab: Tab?
    var extensions: [LoadedExtension] = []

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
        for ext in extensions {
            let action = ext.context.action(for: tab?.extensionTab)
            var title = ExtensionPermissionText.sanitize(ext.displayName, max: 60)
            let badge = String(ExtensionPermissionText.sanitize(action?.badgeText ?? "", max: 16).prefix(4))
            if !badge.isEmpty { title += " (\(badge))" }
            let item = ClosureMenuItem(title: title) { [weak self] in self?.perform(ext) }
            item.image = ExtensionActionNSButton.toolbarIcon(ext: ext, action: action)
            item.isEnabled = action?.isEnabled ?? false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pin = NSMenuItem(title: "Pin to Toolbar", action: nil, keyEquivalent: "")
        let pinMenu = NSMenu()
        for ext in extensions {
            let title = ExtensionPermissionText.sanitize(ext.displayName, max: 60)
            let folder = ext.name
            pinMenu.addItem(ClosureMenuItem(title: title) {
                Task { await AppModel.shared.setToolbarPlacement(.pinned, folder: folder) }
            })
        }
        pin.submenu = pinMenu
        menu.addItem(pin)
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

    var body: some View {
        ExtensionActionButton(ext: ext, tab: tab, generation: ext.actionGeneration)
            .frame(width: 26, height: 26)
    }
}

/// A real NSView, so the popover has something to anchor to and right-click shows a native menu.
struct ExtensionActionButton: NSViewRepresentable {
    let ext: LoadedExtension
    let tab: Tab?
    let generation: Int

    func makeNSView(context: Context) -> ExtensionActionNSButton {
        ExtensionActionNSButton(ext: ext)
    }

    func updateNSView(_ button: ExtensionActionNSButton, context: Context) {
        button.update(ext: ext, tab: tab, generation: generation, scale: context.environment.chromeScale)
    }
}

final class ExtensionActionNSButton: NSButton {
    static func identifier(for extensionID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("extension-action-\(extensionID)")
    }

    /// The icon the button draws, 16 x 16 at the default text size: the action's, else the extension's, else a puzzle
    /// piece.
    static func toolbarIcon(ext: LoadedExtension, action: WKWebExtension.Action?, side: CGFloat = 16) -> NSImage? {
        let size = CGSize(width: side, height: side)
        // A copy: WebKit may hand back its cached image, whose size shouldn't be changed under it.
        let icon = (action?.icon(for: size) ?? ext.webExtension.icon(for: size))?.copy() as? NSImage
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        icon?.size = size
        return icon
    }

    private var ext: LoadedExtension
    private weak var tab: Tab?
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
