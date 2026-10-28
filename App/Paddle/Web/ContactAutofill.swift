import Contacts
import Foundation
import os
import PaddleCore
import Security
import WebKit

/// The contact card for contact autofill, kept as one generic-password item in the login Keychain (never in
/// config.json or a plain file). Read on first use, then cached; Settings edits and removes it.
@Observable
final class ContactCardStore {
    static let shared = ContactCardStore()

    private static let service = "com.walker.Paddle.contact-autofill"
    private static let account = "card"
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "autofill")

    @ObservationIgnored private var loaded = false
    private var stored: ContactCard?

    /// The saved card; nil when none is saved (or the Keychain item can't be read).
    var card: ContactCard? {
        if !loaded {
            loaded = true
            stored = Self.read()
        }
        return stored
    }

    /// Saves `card`; an empty card removes the item. False when the Keychain refused.
    @discardableResult
    func save(_ card: ContactCard) -> Bool {
        guard !card.isEmpty else { return remove() }
        guard let data = try? JSONEncoder().encode(card) else { return false }
        let query = Self.baseQuery()
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Paddle contact autofill"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Self.log.error("contact card not saved: OSStatus \(status, privacy: .public)")
            return false
        }
        loaded = true
        stored = card
        return true
    }

    /// Removes the saved card. True when none is left.
    @discardableResult
    func remove() -> Bool {
        let status = SecItemDelete(Self.baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.log.error("contact card not removed: OSStatus \(status, privacy: .public)")
            return false
        }
        loaded = true
        stored = nil
        return true
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read() -> ContactCard? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { log.error("contact card not read: OSStatus \(status, privacy: .public)") }
            return nil
        }
        return try? JSONDecoder().decode(ContactCard.self, from: data)
    }
}

/// Receives `ContactAutofillScript`'s reports (a field was focused: the groups it could fill and where the field is;
/// or: hide the chip) and shows or hides the native chip, only for the https main frame of a browser tab while
/// `contactAutofill` is on. It never replies with contact info. It is registered only in the script's own content
/// world, so a page's scripts can't reach it.
final class ContactAutofillHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ContactAutofillHandler()

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        replyHandler(nil, nil)
        guard message.name == ContactAutofillScript.handlerName,
              let body = message.body as? [String: Any],
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol.lowercased() == "https",
              let webView = message.webView,
              let tab = Tab.owning(webView) else { return }
        guard tab.config.contactAutofill, body["type"] as? String == "show",
              let raw = body["groups"] as? [String], raw.count <= ContactGroup.allCases.count,
              let rect = body["rect"] as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
              let width = (rect["width"] as? NSNumber)?.doubleValue, let height = (rect["height"] as? NSNumber)?.doubleValue
        else {
            tab.hideContactChip()
            return
        }
        tab.showContactChip(groups: ContactChipOffer.groups(from: raw), fieldRect: CGRect(x: x, y: y, width: width, height: height))
    }
}

/// The chip drawn by Paddle over a tab's web view, outside the page: it names what it fills and has a dismiss button.
/// System colors and fonts; its buttons never take keyboard focus from the page's field.
final class ContactChipView: NSView {
    var onFill: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var groups: [ContactGroup] = []
    private let fillButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fillButton.isBordered = false
        fillButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        fillButton.refusesFirstResponder = true
        fillButton.target = self
        fillButton.action = #selector(fillClicked)
        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Not on this page")
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.toolTip = "Not on this page"
        dismissButton.refusesFirstResponder = true
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        let stack = NSStackView(views: [fillButton, dismissButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    func show(groups: [ContactGroup]) {
        self.groups = groups
        fillButton.title = ContactChipOffer.label(for: groups) ?? ""
        fillButton.setAccessibilityLabel(fillButton.title)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A tab switch takes the container out of the window: the chip doesn't come back with it.
        if window == nil { removeFromSuperview() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func fillClicked() { onFill?() }
    @objc private func dismissClicked() { onDismiss?() }
}

extension Tab {
    private static let contactWorld = WKContentWorld.world(name: ContactAutofillScript.worldName)

    func hideContactChip() {
        contactChip?.removeFromSuperview()
    }

    /// Shows the chip just under the field (`fieldRect`: CSS pixels in the page's viewport), clamped inside the web view.
    func showContactChip(groups: [ContactGroup], fieldRect: CGRect) {
        guard config.contactAutofill, !groups.isEmpty, let webView, !isSuspendedInWebKit, webView.superview === container,
              webView.url?.scheme?.lowercased() == "https" else {
            hideContactChip()
            return
        }
        let chip: ContactChipView
        if let existing = contactChip {
            chip = existing
        } else {
            chip = ContactChipView(frame: .zero)
            chip.onFill = { [weak self] in self?.fillFromContactChip() }
            chip.onDismiss = { [weak self] in
                guard let self else { return }
                hideContactChip()
                runInContactWorld("window.__paddleDismiss && window.__paddleDismiss()", arguments: [:])
            }
            contactChip = chip
        }
        chip.show(groups: groups)
        let zoom = webView.pageZoom
        let field = CGRect(x: fieldRect.minX * zoom, y: fieldRect.minY * zoom, width: fieldRect.width * zoom, height: fieldRect.height * zoom)
        guard let frame = ContactChipOffer.frame(field: field, chip: chip.fittingSize, in: webView.bounds.size) else {
            hideContactChip()
            return
        }
        // `frame` is top-left based in the web view's (flipped) space; converting handles the container's own.
        chip.frame = webView.convert(frame, to: container)
        if chip.superview !== container { container.addSubview(chip, positioned: .above, relativeTo: nil) }
    }

    /// A real click on the chip: the saved card's values for the groups the chip named go to the script, which fills
    /// only those groups' fields that are visible now.
    private func fillFromContactChip() {
        let groups = contactChip?.groups ?? []
        hideContactChip()
        guard config.contactAutofill, !groups.isEmpty, webView?.url?.scheme?.lowercased() == "https",
              let card = ContactCardStore.shared.card else { return }
        let values = card.reply(for: ContactChipOffer.kinds(for: groups))
        guard !values.isEmpty else { return }
        runInContactWorld("return window.__paddleFill ? window.__paddleFill(values) : 0", arguments: ["values": values])
    }

    private func runInContactWorld(_ body: String, arguments: [String: Any]) {
        guard let webView, !isSuspendedInWebKit else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.contactWorld)
        }
    }
}

/// Copies My Card from Contacts into a `ContactCard`: name, company, the first email and phone, the first address.
enum ContactsImport {
    struct Failure: Error {
        let message: String
    }

    static func myCard() async -> Result<ContactCard, Failure> {
        let store = CNContactStore()
        let granted: Bool
        do {
            granted = try await store.requestAccess(for: .contacts)
        } catch {
            granted = false
        }
        guard granted else {
            return .failure(Failure(message: "Paddle can't read Contacts. Allow it in System Settings > Privacy & Security > Contacts."))
        }
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey,
        ] as [CNKeyDescriptor]
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else {
            return .failure(Failure(message: "Contacts has no My Card. Choose one in Contacts > Card > Make This My Card."))
        }
        var card = ContactCard(
            givenName: me.givenName, familyName: me.familyName,
            email: (me.emailAddresses.first?.value as String?) ?? "",
            phone: me.phoneNumbers.first?.value.stringValue ?? "",
            organization: me.organizationName
        )
        if let address = me.postalAddresses.first?.value {
            let lines = address.street.split(separator: "\n").map(String.init)
            card.addressLine1 = lines.first ?? ""
            card.addressLine2 = lines.dropFirst().joined(separator: ", ")
            card.city = address.city
            card.region = address.state
            card.postalCode = address.postalCode
            card.country = address.country
        }
        return .success(card)
    }
}
