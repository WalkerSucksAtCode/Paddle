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

/// The isolated-world page script behind contact autofill. When a field it recognises (by `autocomplete`, then by its
/// type, name, id, placeholder and label) gets focus, it shows a "Fill contact info" chip under it, in a closed shadow
/// root and with none of the contact info in it. Only a real click on the chip (`isTrusted`) asks Paddle for the
/// values, and only for the kinds of field in that form; they go into the form's visible, empty, recognised fields,
/// with input and change events as typing sends. Card and password fields are never touched. The handler lives only
/// in the script's own content world, so the page can't ask for the values itself.
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
      if (window.__paddleContactAutofill) return;
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
      // Hidden fields never get filled: a page could otherwise collect an address behind one visible field.
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) return false;
        for (let n = el, i = 0; n && n.nodeType === 1 && i < 8; n = n.parentElement, i++) {
          const s = getComputedStyle(n);
          if (s.visibility === 'hidden' || s.display === 'none' || parseFloat(s.opacity) < 0.1) return false;
        }
        return true;
      };
      const fieldsFor = (el) => {
        const root = el.form || el.closest('form') || document;
        return Array.from(root.querySelectorAll('input, select, textarea')).filter(f => kindOf(f) && visible(f));
      };

      let host = null, chip = null, target = null, dismissed = false;
      const hide = () => { if (host) host.style.setProperty('display', 'none', 'important'); target = null; };
      const place = () => {
        if (!host || !target) return;
        const r = target.getBoundingClientRect();
        host.style.setProperty('top', Math.round(r.bottom + 4) + 'px', 'important');
        host.style.setProperty('left', Math.round(Math.max(4, r.left)) + 'px', 'important');
      };
      const makeChip = () => {
        host = document.createElement('paddle-contact-autofill');
        const style = 'position: fixed !important; z-index: 2147483647 !important; display: none !important; opacity: 1 !important; visibility: visible !important; pointer-events: auto !important;';
        host.setAttribute('style', style);
        const shadow = host.attachShadow({ mode: 'closed' });
        shadow.innerHTML = '<style>div{display:flex;gap:2px;align-items:center;font:13px -apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;border:1px solid rgba(128,128,128,.45);border-radius:7px;box-shadow:0 2px 8px rgba(0,0,0,.18);padding:2px}button{font:inherit;border:0;background:transparent;color:inherit;padding:4px 8px;border-radius:5px;cursor:default}button:hover{background:rgba(128,128,128,.18)}.x{padding:4px 6px;opacity:.6}</style><div><button class="fill">Fill contact info</button><button class="x" title="Not on this page">✕</button></div>';
        chip = shadow;
        const keepFocus = (e) => e.preventDefault();
        shadow.querySelector('.fill').addEventListener('mousedown', keepFocus);
        shadow.querySelector('.x').addEventListener('mousedown', keepFocus);
        shadow.querySelector('.x').addEventListener('click', (e) => { if (e.isTrusted) { dismissed = true; hide(); } });
        shadow.querySelector('.fill').addEventListener('click', (e) => { if (e.isTrusted && target) fill(target); });
        (document.body || document.documentElement).appendChild(host);
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
      const fill = (from) => {
        const fields = fieldsFor(from).filter(f => f.tagName === 'SELECT' ? true : !f.value);
        const kinds = Array.from(new Set(fields.map(kindOf)));
        hide();
        if (!kinds.length) return;
        Promise.resolve(handler.postMessage({ kinds })).then((values) => {
          if (!values || typeof values !== 'object') return;
          for (const f of fields) {
            const v = values[kindOf(f)];
            if (typeof v === 'string' && v) setValue(f, v);
          }
        }).catch(() => {});
      };
      document.addEventListener('focusin', (e) => {
        const el = e.target;
        if (dismissed || !kindOf(el) || !visible(el)) { hide(); return; }
        if (!host) makeChip();
        target = el;
        host.style.setProperty('display', 'block', 'important');
        place();
      }, true);
      document.addEventListener('focusout', () => setTimeout(() => {
        if (!document.activeElement || !kindOf(document.activeElement)) hide();
      }, 150), true);
      window.addEventListener('scroll', place, true);
      window.addEventListener('resize', place);
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); }, true);
    })();
    """
}
