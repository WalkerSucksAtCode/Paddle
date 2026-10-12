import AppKit
import PaddleCore
import SwiftUI
import WebKit

/// One button per running extension with a toolbar action, right of the address bar: its icon, badge and enabled
/// state for the selected tab. A button redraws when WebKit reports a change to its own extension's action
/// (`LoadedExtension.actionGeneration`) and when the selected tab changes.
struct ExtensionToolbar: View {
    let host: ExtensionHost
    let tab: Tab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(host.loaded) { ext in
                if ext.hasAction {
                    ExtensionToolbarItem(ext: ext, tab: tab)
                }
            }
        }
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
        button.update(ext: ext, tab: tab, generation: generation)
    }
}

final class ExtensionActionNSButton: NSButton {
    static func identifier(for extensionID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("extension-action-\(extensionID)")
    }

    private var ext: LoadedExtension
    private weak var tab: Tab?
    private let badge = BadgeLabel()
    /// What the button last drew: an update with the same extension, action object and generation is skipped.
    private weak var drawnAction: WKWebExtension.Action?
    private var drawnGeneration: Int?
    private weak var drawnExtension: LoadedExtension?

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
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var currentAction: WKWebExtension.Action? {
        ext.context.action(for: tab?.extensionTab)
    }

    func update(ext: LoadedExtension, tab: Tab?, generation: Int) {
        self.ext = ext
        self.tab = tab
        let action = currentAction
        if drawnGeneration == generation, drawnExtension === ext, drawnAction === action { return }
        drawnGeneration = generation
        drawnExtension = ext
        drawnAction = action
        identifier = Self.identifier(for: ext.id)
        let size = CGSize(width: 16, height: 16)
        // A copy: WebKit may hand back its cached image, whose size shouldn't be changed under it.
        let icon = (action?.icon(for: size) ?? ext.webExtension.icon(for: size))?.copy() as? NSImage
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        icon?.size = NSSize(width: 16, height: 16)
        image = icon
        isEnabled = action?.isEnabled ?? false
        let rawLabel = action?.label ?? ""
        let label = ExtensionPermissionText.sanitize(rawLabel.isEmpty ? ext.displayName : rawLabel, max: 120)
        toolTip = label
        setAccessibilityLabel(label)
        badge.text = Self.badgeText(action)
        needsLayout = true
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
        let host = AppModel.shared.extensions
        // A click on the button of an open popup closes it, as in Safari and Chrome. The transient popover already
        // started closing on this click's mouse-down, so this also covers a popup that closed a moment ago.
        if host.popups.closeForToggle(ext.context) { return }
        currentAction?.hasUnreadBadgeText = false
        badge.text = Self.badgeText(currentAction)
        host.popups.noteClick(from: self, for: ext.context)
        host.performAction(ext, in: tab)
    }

    /// Right-click: Paddle's items, then the extension's own (fetched now, they change) under a "From <name>"
    /// header with sanitized titles, so an extension can't pass its items off as Paddle's.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
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
        try? AppModel.shared.extensions.openOptionsPage(for: ext.context)
    }

    @objc private func askAboutPermissions() {
        let ext = self.ext
        Task { await AppModel.shared.extensions.askAgain(ext) }
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
