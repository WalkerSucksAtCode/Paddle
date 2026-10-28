import Foundation

/// A form field contact autofill can fill. The raw values are what the page script asks for and what the reply is
/// keyed by.
public enum ContactField: String, CaseIterable, Sendable {
    case name, givenName, familyName, email, tel, organization
    case streetAddress, addressLine1, addressLine2, city, region, postalCode, country
}

/// The contact info contact autofill fills (`contactAutofill`): name, email, phone and one postal address. Never
/// passwords or cards. Kept in the Keychain by the app, not in config.json.
public struct ContactCard: Codable, Equatable, Sendable {
    public var givenName = ""
    public var familyName = ""
    public var email = ""
    public var phone = ""
    public var organization = ""
    public var addressLine1 = ""
    public var addressLine2 = ""
    public var city = ""
    public var region = ""
    public var postalCode = ""
    public var country = ""

    public init(
        givenName: String = "", familyName: String = "", email: String = "", phone: String = "", organization: String = "",
        addressLine1: String = "", addressLine2: String = "", city: String = "", region: String = "", postalCode: String = "",
        country: String = ""
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.email = email
        self.phone = phone
        self.organization = organization
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
    }

    /// Given and family name with one space between, either alone when the other is empty.
    public var fullName: String {
        [givenName, familyName].map(trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isEmpty: Bool { ContactField.allCases.allSatisfy { value(for: $0).isEmpty } }

    /// The text for `field`, trimmed; `streetAddress` is both address lines, one per line.
    public func value(for field: ContactField) -> String {
        switch field {
        case .name: fullName
        case .givenName: trimmed(givenName)
        case .familyName: trimmed(familyName)
        case .email: trimmed(email)
        case .tel: trimmed(phone)
        case .organization: trimmed(organization)
        case .streetAddress: [addressLine1, addressLine2].map(trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        case .addressLine1: trimmed(addressLine1)
        case .addressLine2: trimmed(addressLine2)
        case .city: trimmed(city)
        case .region: trimmed(region)
        case .postalCode: trimmed(postalCode)
        case .country: trimmed(country)
        }
    }

    /// The reply to the page script: the non-empty values of the fields it asked for (raw `ContactField` names;
    /// anything else is ignored), so a form gets only what it has fields for.
    public func reply(for requested: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for name in requested {
            guard let field = ContactField(rawValue: name) else { continue }
            let value = value(for: field)
            if !value.isEmpty { out[name] = value }
        }
        return out
    }

    /// A one-line summary for Settings: the name, then the email, then the city; empty for an empty card.
    public var summary: String {
        [fullName, value(for: .email), value(for: .city)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// What a chip can name; the order is the order it is written in.
public enum ContactGroup: String, CaseIterable, Sendable {
    case name, email, phone, company, address
}

public extension ContactField {
    /// The group the chip names this field under.
    var group: ContactGroup {
        switch self {
        case .name, .givenName, .familyName: .name
        case .email: .email
        case .tel: .phone
        case .organization: .company
        case .streetAddress, .addressLine1, .addressLine2, .city, .region, .postalCode, .country: .address
        }
    }
}

/// What the native chip offers, from what the page script reported (the page script's words are never trusted
/// further than this).
public enum ContactChipOffer {
    /// The known groups in `raw`, once each, in chip order.
    public static func groups(from raw: [String]) -> [ContactGroup] {
        let given = Set(raw.compactMap(ContactGroup.init(rawValue:)))
        return ContactGroup.allCases.filter(given.contains)
    }

    /// "Fill name, email, address"; nil when there is nothing to fill.
    public static func label(for groups: [ContactGroup]) -> String? {
        groups.isEmpty ? nil : "Fill " + groups.map(\.rawValue).joined(separator: ", ")
    }

    /// The raw `ContactField` names the card is asked for: every kind in `groups`.
    public static func kinds(for groups: [ContactGroup]) -> [String] {
        ContactField.allCases.filter { groups.contains($0.group) }.map(\.rawValue)
    }

    /// Where the chip goes, top-left origin, in web-view points: just under the field and clamped inside `bounds`,
    /// or above it when there is no room below. Nil for a rect that is not finite, empty, or entirely outside.
    public static func frame(field: CGRect, chip: CGSize, in bounds: CGSize, margin: CGFloat = 4) -> CGRect? {
        let values = [field.origin.x, field.origin.y, field.width, field.height, chip.width, chip.height, bounds.width, bounds.height]
        guard values.allSatisfy(\.isFinite), field.width > 0, field.height > 0, chip.width > 0, chip.height > 0 else { return nil }
        guard field.maxX > 0, field.maxY > 0, field.minX < bounds.width, field.minY < bounds.height else { return nil }
        let maxX = max(margin, bounds.width - chip.width - margin)
        let maxY = max(margin, bounds.height - chip.height - margin)
        let x = min(max(field.minX, margin), maxX)
        var y = field.maxY + margin
        if y > maxY { y = field.minY - margin - chip.height }
        y = min(max(y, margin), maxY)
        return CGRect(x: x, y: y, width: chip.width, height: chip.height)
    }
}

/// The isolated-world page script behind contact autofill, for https main frames only. When a field it recognises (by
/// `autocomplete`, then by its type, name, id, placeholder and label) gets focus, it tells Paddle (the content-world
/// handler) which groups it could fill and where the field is; it adds nothing to the page. Paddle draws a native chip
/// over the web view naming what it would fill ("Fill name, email, address"), which page code can neither restyle,
/// move nor hide. Only a real click on that chip makes Paddle call `__paddleFill` in this world with the values for
/// the groups it named; they go into the form's empty, recognised fields of those groups that are visible on screen
/// right then (inside the window, not covered, faded out or with see-through text), with input and change events as
/// typing sends. Card and password fields are never touched. The handler and `__paddleFill` live only in the script's
/// own content world, so the page can reach neither the values nor the fill.
public enum ContactAutofillScript {
    public static let handlerName = "paddleContactAutofill"
    public static let worldName = "PaddleContactAutofill"

    /// `__paddleClassify(f)`: the `ContactField` name for a field described as
    /// `{autocomplete, type, name, id, placeholder, label, tag}`, or null. Separate so it can be tested on its own.
    public static let classifierSource = #"""
    function __paddleClassify(f) {
      const tokens = String(f.autocomplete || '').toLowerCase().split(/\s+/).filter(Boolean);
      if (tokens.some(t => t.startsWith('cc-') || t === 'current-password' || t === 'new-password' || t === 'one-time-code')) return null;
      const type = String(f.type || '').toLowerCase();
      if (['password', 'hidden', 'submit', 'button', 'reset', 'checkbox', 'radio', 'file', 'image', 'range', 'color', 'date', 'datetime-local', 'month', 'week', 'time', 'search'].includes(type)) return null;
      const byToken = {
        'name': 'name', 'given-name': 'givenName', 'family-name': 'familyName', 'email': 'email',
        'tel': 'tel', 'tel-national': 'tel', 'organization': 'organization', 'street-address': 'streetAddress',
        'address-line1': 'addressLine1', 'address-line2': 'addressLine2', 'address-level2': 'city',
        'address-level1': 'region', 'postal-code': 'postalCode', 'country': 'country', 'country-name': 'country'
      };
      for (const t of tokens) if (byToken[t]) return byToken[t];
      if (type === 'email') return 'email';
      if (type === 'tel') return 'tel';
      const text = [f.name, f.id, f.placeholder, f.label].map(s => String(s || '').toLowerCase()).join(' ');
      if (/card|cvc|cvv|ccnum|cc-|expir|security.?code|password|passwd|user.?name|login|coupon|promo|search|captcha/.test(text)) return null;
      if (/e-?mail/.test(text)) return 'email';
      if (/phone|mobile|\btel\b|telephone/.test(text)) return 'tel';
      if (/first.?name|\bfname\b|given.?name|forename/.test(text)) return 'givenName';
      if (/last.?name|\blname\b|surname|family.?name/.test(text)) return 'familyName';
      if (/full.?name|your.?name|^\s*name\b|\bname\s*$/.test(text)) return 'name';
      if (/compan|organi[sz]ation|business/.test(text)) return 'organization';
      if (/address.?(line)?.?2|\bapt\b|apartment|suite|\bunit\b/.test(text)) return 'addressLine2';
      if (/address|street|addr/.test(text)) return f.tag === 'textarea' ? 'streetAddress' : 'addressLine1';
      if (/\bcity\b|town|locality/.test(text)) return 'city';
      if (/\bstate\b|province|region|county/.test(text)) return 'region';
      if (/\bzip\b|postal|post.?code|postcode/.test(text)) return 'postalCode';
      if (/country/.test(text)) return 'country';
      return null;
    }
    """#

    public static let source = """
    (() => {
      if (window.__paddleContactAutofill || location.protocol !== 'https:' || window.top !== window) return;
      window.__paddleContactAutofill = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) return;
    \(classifierSource)
      const labelText = (el) => {
        const parts = [];
        try { for (const l of (el.labels || [])) parts.push(l.textContent || ''); } catch (e) {}
        parts.push(el.getAttribute('aria-label') || '');
        const ids = (el.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean);
        for (const id of ids) { const n = document.getElementById(id); if (n) parts.push(n.textContent || ''); }
        return parts.join(' ').slice(0, 200);
      };
      const isField = (el) => el && el.nodeType === 1 && /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName) && !el.disabled && !el.readOnly;
      const kindOf = (el) => isField(el) ? __paddleClassify({
        autocomplete: el.getAttribute('autocomplete') || '', type: el.tagName === 'INPUT' ? (el.type || 'text') : '',
        name: el.name || '', id: el.id || '', placeholder: el.getAttribute('placeholder') || '', label: labelText(el),
        tag: el.tagName.toLowerCase()
      }) : null;
      // Only fields the user can see right now get filled: a page could otherwise collect an address through fields
      // moved off screen, clipped, covered by other content or made transparent, next to one visible field. The centre
      // must be inside the window and hit the field itself (or its label), which also rules out clipping.
      const clear = (c) => c === 'transparent' || /^rgba\\(.*,\\s*0(\\.0*)?\\)$/.test(c) || /\\/\\s*0(\\.0*)?\\)$/.test(c);
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) return false;
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return false;
        const own = getComputedStyle(el);
        if (own.visibility !== 'visible' || clear(own.color) || clear(own.webkitTextFillColor || '')) return false;
        let opacity = 1;
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
          opacity *= parseFloat(getComputedStyle(n).opacity);
          if (!(opacity >= 0.1)) return false;
        }
        const hit = document.elementFromPoint(x, y);
        if (hit === el) return true;
        try { for (const l of (el.labels || [])) if (l === hit || l.contains(hit)) return true; } catch (e) {}
        return false;
      };
      // The form's recognised fields that are empty (a select always has a value) and visible.
      const fillable = (el) => {
        const root = el.form || el.closest('form') || document;
        return Array.from(root.querySelectorAll('input, select, textarea'))
          .filter(f => kindOf(f) && (f.tagName === 'SELECT' || !f.value) && visible(f));
      };
      // What the chip names, in this order.
      const groupOf = {
        name: 'name', givenName: 'name', familyName: 'name', email: 'email', tel: 'phone', organization: 'company',
        streetAddress: 'address', addressLine1: 'address', addressLine2: 'address', city: 'address', region: 'address',
        postalCode: 'address', country: 'address'
      };
      const groupOrder = ['name', 'email', 'phone', 'company', 'address'];

      // No element is ever added to the page. The chip is a native view Paddle draws over the web view; this script
      // only tells Paddle which groups it could fill and where the field is (a page that lies about that can at most
      // move a visible native chip that names what it fills), and fills when Paddle asks after a real click.
      let target = null, dismissed = false, shown = false, offered = new Set();
      const send = (message) => { try { Promise.resolve(handler.postMessage(message)).catch(() => {}); } catch (e) {} };
      const hide = () => {
        target = null;
        if (shown) { shown = false; send({ type: 'hide' }); }
      };
      const setValue = (el, value) => {
        if (el.tagName === 'SELECT') {
          const want = value.toLowerCase();
          const option = Array.from(el.options).find(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want);
          if (!option) return false;
          el.value = option.value;
        } else {
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, el.tagName === 'TEXTAREA' ? value : value.replace(/\\n/g, ', '));
        }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      };
      // Called by Paddle after a real click on its chip, with the values for the kinds of the groups it named. Only
      // fields of the groups offered, still empty and visible now, get a value.
      window.__paddleFill = (values) => {
        const from = target;
        hide();
        if (!from || !from.isConnected || !values || typeof values !== 'object' || !offered.size) return 0;
        let count = 0;
        for (const f of fillable(from).filter(f => offered.has(groupOf[kindOf(f)]))) {
          const v = values[kindOf(f)];
          if (typeof v === 'string' && v && setValue(f, v)) count++;
        }
        return count;
      };
      window.__paddleDismiss = () => { dismissed = true; hide(); };
      document.addEventListener('focusin', (e) => {
        const el = e.target;
        hide();
        if (dismissed || !kindOf(el) || !visible(el)) return;
        const groups = new Set(fillable(el).map(f => groupOf[kindOf(f)]));
        offered = new Set(groupOrder.filter(g => groups.has(g)));
        if (!offered.size) return;
        const r = el.getBoundingClientRect();
        target = el;
        shown = true;
        send({ type: 'show', groups: Array.from(offered), rect: { x: r.left, y: r.top, width: r.width, height: r.height } });
      }, true);
      document.addEventListener('focusout', () => setTimeout(() => {
        if (!document.activeElement || !kindOf(document.activeElement)) hide();
      }, 150), true);
      window.addEventListener('scroll', hide, true);
      window.addEventListener('resize', hide);
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); }, true);
    })();
    """
}
