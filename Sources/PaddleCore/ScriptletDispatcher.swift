import Foundation

/// One script that runs several scriptlets, each only where its sites match the frame's hostname. For rules a
/// WebKit match pattern can't express (`site.*` entities, which mean the name under any public suffix), and for
/// every rule when WebKit's per-script match patterns aren't available. Each scriptlet's function and each helper
/// block appear once however many rules use them; the rules themselves are one JSON table.
extension ScriptletLibrary {
    public static func dispatcherSource(for rules: [ScriptletRule]) -> String {
        let names = ScriptletName.allCases.filter { name in rules.contains { $0.name == name } }
        guard !names.isEmpty else { return "" }
        var blocks: [Helper] = [.core]
        for name in names {
            for helper in helpers(for: name) where !blocks.contains(helper) { blocks.append(helper) }
        }
        let bodies = names.map { "\(jsonString($0.rawValue)): \(body(for: $0))" }.joined(separator: ",\n")
        let table: [[Any]] = rules.map {
            [$0.name.rawValue, $0.arguments, $0.includeDomains, $0.includeEntities, $0.excludeDomains, $0.excludeEntities]
        }
        let tableJSON = (try? JSONSerialization.data(withJSONObject: table)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return """
        (function () {
        'use strict';
        try {
        const host = String(location.hostname || '').toLowerCase().replace(/\\.$/, '');
        if (host === '') return;
        \(dispatchHelpers)
        const rules = \(tableJSON).filter(r => applies(host, r));
        if (rules.length === 0) return;
        \(blocks.map(\.source).joined(separator: "\n"))
        const bodies = {
        \(bodies)
        };
        for (const r of rules) { try { bodies[r[0]].apply(null, r[1]); } catch (e) {} }
        } catch (e) {}
        })();

        """
    }

    /// Host matching for the table: a domain covers itself and its subdomains; an entity `name` covers
    /// `name.<suffix>` and its subdomains, where the suffix is one label, or two when the first is a short
    /// second-level label (`co.uk`, `com.au`). That approximates the public suffix list without shipping it.
    static let dispatchHelpers = #"""
    const covers = (h, d) => h === d || h.endsWith('.' + d);
    function entityCovers(h, e) {
      const labels = h.split('.');
      for (let i = 0; i < labels.length; i++) {
        const rest = labels.slice(i);
        const n = e.split('.').length;
        if (rest.slice(0, n).join('.') !== e) continue;
        const suffix = rest.slice(n);
        if (suffix.length === 1) return true;
        if (suffix.length === 2 && (suffix[0].length <= 3 || suffix[0] === 'gouv')) return true;
      }
      return false;
    }
    function applies(h, r) {
      const generic = r[2].length === 0 && r[3].length === 0;
      if (!generic && !r[2].some(d => covers(h, d)) && !r[3].some(e => entityCovers(h, e))) return false;
      return !r[4].some(d => covers(h, d)) && !r[5].some(e => entityCovers(h, e));
    }
    """#

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
