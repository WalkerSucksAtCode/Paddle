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

/// Answers `ContactAutofillScript`'s request after a real click on its chip: the saved card's values for the kinds of
/// field the form has, only for the https main frame of a browser tab while `contactAutofill` is on (an embedded frame
/// or a plain-http page never gets them). It is registered only in the script's own content world, so a page's scripts
/// can't reach it.
final class ContactAutofillHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ContactAutofillHandler()
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "autofill")

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.name == ContactAutofillScript.handlerName,
              let body = message.body as? [String: Any],
              let kinds = body["kinds"] as? [String], kinds.count <= ContactField.allCases.count,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol.lowercased() == "https",
              let webView = message.webView,
              let tab = AppModel.shared.allTabs.first(where: { $0.webView === webView }),
              tab.config.contactAutofill,
              let card = ContactCardStore.shared.card else {
            replyHandler(nil, nil)
            return
        }
        let reply = card.reply(for: kinds)
        Self.log.info("contact autofill: \(reply.count, privacy: .public) kinds filled")
        replyHandler(reply, nil)
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
