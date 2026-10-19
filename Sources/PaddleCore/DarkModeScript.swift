import Foundation

/// Injected at document start in the isolated content world (`.defaultClient`).
/// Sets `color-scheme` before first paint. A page that is already dark (computed background, `data-theme`,
/// or `theme-color`) is left alone so it is not inverted twice. Light pages get inverted backgrounds and text;
/// photos, video, icons, and embeds are left alone. `window.__paddleDarkMode.setDarkMode(on)` toggles it live.
public enum DarkModeScript {
    public static func source(for sites: [String: SiteSettings], defaultDarkMode: Bool) -> String {
        let table = hostTable(sites)
        let tableJSON = json(table)
        let defaultDarkStr = defaultDarkMode ? "true" : "false"

        return """
        (() => {
        'use strict';

        (function () {
          const T = new Map(\(tableJSON));
          let defaultDark = \(defaultDarkStr);
          let currentOverride = null;

          function getHost() {
            return String(location.hostname || '').toLowerCase().replace(/\\.$/, '');
          }

          function shouldBeDark() {
            if (currentOverride !== null) return currentOverride;
            const host = getHost();
            if (!host) return defaultDark;
            for (let h = host; h !== '';) {
              if (T.has(h)) return T.get(h);
              const dot = h.indexOf('.');
              h = dot < 0 ? '' : h.slice(dot + 1);
            }
            return defaultDark;
          }

          const STYLE_ID = 'paddle-dark-mode-styles';

          function ensureStyles() {
            if (document.getElementById(STYLE_ID)) return;
            const style = document.createElement('style');
            style.id = STYLE_ID;
            style.textContent = `
              :root {
                color-scheme: dark !important;
              }
              html[data-paddle-dark-mode="active"] {
                filter: invert(90%) hue-rotate(180deg) !important;
                background-color: #181a1b !important;
              }
              html[data-paddle-dark-mode="active"] img,
              html[data-paddle-dark-mode="active"] video,
              html[data-paddle-dark-mode="active"] canvas,
              html[data-paddle-dark-mode="active"] picture,
              html[data-paddle-dark-mode="active"] iframe,
              html[data-paddle-dark-mode="active"] [role="img"],
              html[data-paddle-dark-mode="active"] [style*="background-image"] {
                filter: invert(100%) hue-rotate(180deg) !important;
              }
            `;
            (document.head || document.documentElement || document).appendChild(style);
          }

          function removeStyles() {
            const el = document.getElementById(STYLE_ID);
            if (el) el.remove();
            document.documentElement.removeAttribute('data-paddle-dark-mode');
          }

          function parseLuminance(colorStr) {
            if (!colorStr) return null;
            const m = colorStr.match(/\\d+(\\.\\d+)?/g);
            if (m && m.length >= 3) {
              const r = Number(m[0]), g = Number(m[1]), b = Number(m[2]);
              const a = m.length >= 4 ? Number(m[3]) : 1;
              if (a > 0.2) {
                return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
              }
            }
            return null;
          }

          function isNaturallyDark() {
            try {
              const elementsToCheck = [
                document.documentElement,
                document.body,
                document.querySelector('main, #root, #app, #__next, ytd-app, [role="main"]')
              ];
              for (const el of elementsToCheck) {
                if (!el) continue;
                const lum = parseLuminance(window.getComputedStyle(el).backgroundColor);
                if (lum !== null && lum < 0.45) return true;
              }

              const html = document.documentElement;
              const theme = (html.getAttribute('data-theme') || html.getAttribute('data-color-mode') || html.getAttribute('theme') || '').toLowerCase();
              if (theme.includes('dark')) return true;
              if (html.classList.contains('dark') || (document.body && document.body.classList.contains('dark'))) return true;

              const metaTheme = document.querySelector('meta[name="theme-color"]');
              if (metaTheme && metaTheme.content) {
                const lum = parseLuminance(metaTheme.content);
                if (lum !== null && lum < 0.45) return true;
              }
            } catch (e) {
              // Computed style or a missing attribute can throw; treat that as not dark.
            }
            return false;
          }

          function evaluateAndApply() {
            const darkDesired = shouldBeDark();
            if (!darkDesired) {
              removeStyles();
              return;
            }

            ensureStyles();

            // If the website already rendered natively in dark mode, do not invert it!
            if (isNaturallyDark()) {
              document.documentElement.removeAttribute('data-paddle-dark-mode');
            } else {
              document.documentElement.setAttribute('data-paddle-dark-mode', 'active');
            }
          }

          // At document-start, inject the style tag so color-scheme: dark triggers native dark palette immediately
          if (shouldBeDark()) {
            ensureStyles();
          }

          // Evaluate once DOM is loaded, and again after a short delay for late-hydrating SPAs
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', evaluateAndApply, { once: true });
          } else {
            evaluateAndApply();
          }
          setTimeout(evaluateAndApply, 400);

          window.__paddleDarkMode = {
            setDarkMode(on) {
              currentOverride = Boolean(on);
              evaluateAndApply();
            },
            toggle() {
              const next = !shouldBeDark();
              currentOverride = next;
              evaluateAndApply();
              return next;
            },
            isEnabled() {
              return shouldBeDark();
            }
          };
        })();
        })();
        """
    }

    /// Extracts normalized host keys where `darkMode` is explicitly configured.
    static func hostTable(_ sites: [String: SiteSettings]) -> [[Any]] {
        var table: [String: Bool] = [:]
        for (key, settings) in sites.sorted(by: { PaddleConfig.hostKeyPrecedes($0.key, $1.key) }) {
            if let darkMode = settings.darkMode {
                table[PaddleConfig.normalizedHost(key)] = darkMode
            }
        }
        return table.keys.sorted().map { [$0, table[$0] ?? false] }
    }

    private static func json(_ table: [[Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
          }
        return text
    }
}
