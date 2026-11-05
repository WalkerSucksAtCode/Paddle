import Foundation

/// Injected at document start in the isolated content world (`.defaultClient`).
/// Applies smart invert or native `color-scheme` before first paint. Smart mode skips pages that are already dark
/// (`isNaturallyDark`). `window.__paddleDarkMode.setPolicy({ engine, invertTextImages })` switches engines live;
/// `setDarkMode(on)` remains for compat (`true` → smart, `false` → off).
public enum DarkModeScript {
    public static func source(
        for sites: [String: SiteSettings],
        defaultEngine: PageDarkEngine,
        globalDarkMode: DarkModePreference = .off,
        invertTextImages: Bool = false
    ) -> String {
        let table = hostTable(sites)
        let tableJSON = json(table)
        let defaultEngineStr = defaultEngine.rawValue
        let globalDarkNativeStr = (globalDarkMode == .native) ? "true" : "false"
        let invertTextImagesStr = invertTextImages ? "true" : "false"

        return """
        (() => {
        'use strict';

        (function () {
          const T = new Map(\(tableJSON));
          let defaultEngine = '\(defaultEngineStr)';
          let globalDarkNative = \(globalDarkNativeStr);
          let invertTextImages = \(invertTextImagesStr);
          let engineOverride = null;

          function getHost() {
            let hostname = location.hostname || '';
            try {
              const origins = window.top === window ? null : location.ancestorOrigins;
              if (origins && origins.length) hostname = new URL(origins[origins.length - 1]).hostname;
            } catch (e) {}
            return String(hostname).toLowerCase().replace(/\\.$/, '');
          }

          function resolveSiteToken(host) {
            if (!host) return null;
            for (let h = host; h !== '';) {
              if (T.has(h)) return T.get(h);
              const dot = h.indexOf('.');
              h = dot < 0 ? '' : h.slice(dot + 1);
            }
            return null;
          }

          function tokenToEngine(token) {
            if (token === 'light') return 'off';
            if (token === 'native') return 'native';
            if (token === 'dark') return globalDarkNative ? 'native' : 'smart';
            return null;
          }

          function resolveBaseEngine() {
            const token = resolveSiteToken(getHost());
            const fromSite = tokenToEngine(token);
            if (fromSite !== null) return fromSite;
            return defaultEngine;
          }

          function currentEngine() {
            if (engineOverride !== null) return engineOverride;
            return resolveBaseEngine();
          }

          const STYLE_ID = 'paddle-dark-mode-styles';
          const NATIVE_STYLE_ID = 'paddle-dark-mode-native';
          const IMAGE_STYLE_ID = 'paddle-text-image-styles';

          function ensureSmartStyles() {
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
              html[data-paddle-dark-mode="active"] [style*="background-image"],
              html[data-paddle-dark-mode="active"] .gm-style,
              html[data-paddle-dark-mode="active"] .mapboxgl-map,
              html[data-paddle-dark-mode="active"] .mapboxgl-canvas,
              html[data-paddle-dark-mode="active"] .leaflet-container,
              html[data-paddle-dark-mode="active"] .leaflet-pane,
              html[data-paddle-dark-mode="active"] [class*="apple-map"],
              html[data-paddle-dark-mode="active"] .monaco-editor,
              html[data-paddle-dark-mode="active"] .cm-editor,
              html[data-paddle-dark-mode="active"] .CodeMirror,
              html[data-paddle-dark-mode="active"] .ace_editor,
              html[data-paddle-dark-mode="active"] #docs-editor,
              html[data-paddle-dark-mode="active"] #docs-editor canvas,
              html[data-paddle-dark-mode="active"] .pdfViewer,
              html[data-paddle-dark-mode="active"] .canvasWrapper,
              html[data-paddle-dark-mode="active"] embed,
              html[data-paddle-dark-mode="active"] object,
              html[data-paddle-dark-mode="active"] [style*="mix-blend-mode"] {
                filter: invert(100%) hue-rotate(180deg) !important;
              }
              html[data-paddle-dark-mode="active"] :is(img, video, canvas, picture, iframe, [role="img"], [style*="background-image"], .gm-style, .mapboxgl-map, .mapboxgl-canvas, .leaflet-container, .leaflet-pane, [class*="apple-map"], .monaco-editor, .cm-editor, .CodeMirror, .ace_editor, #docs-editor, .pdfViewer, .canvasWrapper, embed, object, [style*="mix-blend-mode"]) :is(img, video, canvas, picture, iframe, [role="img"], [style*="background-image"], .gm-style, .mapboxgl-map, .mapboxgl-canvas, .leaflet-container, .leaflet-pane, [class*="apple-map"], .monaco-editor, .cm-editor, .CodeMirror, .ace_editor, #docs-editor, .pdfViewer, .canvasWrapper, embed, object, [style*="mix-blend-mode"]) {
                filter: none !important;
              }
            `;
            (document.head || document.documentElement || document).appendChild(style);
          }

          function ensureNativeStyles() {
            if (document.getElementById(NATIVE_STYLE_ID)) return;
            const style = document.createElement('style');
            style.id = NATIVE_STYLE_ID;
            style.textContent = `
              :root {
                color-scheme: dark !important;
              }
            `;
            (document.head || document.documentElement || document).appendChild(style);
          }

          function ensureImageStyles() {
            if (document.getElementById(IMAGE_STYLE_ID)) return;
            const style = document.createElement('style');
            style.id = IMAGE_STYLE_ID;
            style.textContent = `
              img[data-paddle-inverted-text="true"],
              picture[data-paddle-inverted-text="true"] img,
              div:has(> img[data-paddle-inverted-text="true"]) > [style*="background-image"],
              [style*="background-image"][data-paddle-inverted-text="true"] {
                filter: invert(90%) hue-rotate(180deg) contrast(90%) brightness(95%) !important;
              }
              html[data-paddle-dark-mode="active"] img[data-paddle-inverted-text="true"],
              html[data-paddle-dark-mode="active"] picture[data-paddle-inverted-text="true"] img,
              html[data-paddle-dark-mode="active"] div:has(> img[data-paddle-inverted-text="true"]) > [style*="background-image"],
              html[data-paddle-dark-mode="active"] [style*="background-image"][data-paddle-inverted-text="true"] {
                filter: contrast(95%) brightness(95%) !important;
              }
            `;
            (document.head || document.documentElement || document).appendChild(style);
          }

          function removeSmartStyles() {
            const el = document.getElementById(STYLE_ID);
            if (el) el.remove();
            document.documentElement.removeAttribute('data-paddle-dark-mode');
          }

          function removeNativeStyles() {
            const el = document.getElementById(NATIVE_STYLE_ID);
            if (el) el.remove();
          }

          function removeAllDarkStyles() {
            removeSmartStyles();
            removeNativeStyles();
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
            const html = document.documentElement;
            const ours = html && html.getAttribute('data-paddle-dark-mode');
            if (ours) html.removeAttribute('data-paddle-dark-mode');
            try { return measureNaturallyDark(); } finally { if (ours) html.setAttribute('data-paddle-dark-mode', ours); }
          }

          const DARK_CLASSES = ['dark', 'dark-mode', 'darkMode', 'theme-dark', 'night-mode', 'is-dark', 'docs-darkmode-on'];
          const THEME_ATTRS = ['data-theme', 'data-color-mode', 'data-bs-theme', 'data-mdb-theme', 'theme'];

          function isOverlaySized(el) {
            if (!el || el === document.documentElement || el === document.body) return false;
            const w = el.clientWidth, h = el.clientHeight;
            return w > 0 && h > 0 && w <= 1 && h <= 1;
          }

          function schemeIncludesDark(el) {
            if (!el) return false;
            try {
              const cs = (window.getComputedStyle(el).colorScheme || '').toLowerCase();
              return cs.includes('dark');
            } catch (e) { return false; }
          }

          function withSiteColorScheme(fn) {
            const tweaks = [];
            for (const el of [document.getElementById(STYLE_ID), document.getElementById(NATIVE_STYLE_ID)]) {
              if (!el || !el.sheet) continue;
              try {
                const rules = el.sheet.cssRules;
                for (let i = 0; i < rules.length; i++) {
                  const r = rules[i];
                  if (r.selectorText === ':root' && r.style && r.style.colorScheme) {
                    tweaks.push([r, r.style.getPropertyValue('color-scheme'), r.style.getPropertyPriority('color-scheme')]);
                    r.style.removeProperty('color-scheme');
                  }
                }
              } catch (e) {}
            }
            if (!tweaks.length && (document.getElementById(STYLE_ID) || document.getElementById(NATIVE_STYLE_ID))) {
              return false;
            }
            try { return fn(); }
            finally {
              for (const [r, v, pri] of tweaks) {
                try { r.style.setProperty('color-scheme', v, pri); } catch (e) {}
              }
            }
          }

          function attrThemeDark(el) {
            if (!el || !el.getAttribute) return false;
            for (const name of THEME_ATTRS) {
              const v = (el.getAttribute(name) || '').toLowerCase();
              if (v.includes('dark')) return true;
            }
            const mode = (el.getAttribute('data-color-mode') || '').toLowerCase();
            if (mode === 'auto' && el.getAttribute('data-dark-theme')) {
              try {
                if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return true;
              } catch (e) {}
              if (schemeIncludesDark(el)) return true;
            }
            if (el.hasAttribute('dark')) return true;
            if (el.classList) {
              for (const c of DARK_CLASSES) {
                if (el.classList.contains(c)) return true;
              }
            }
            return false;
          }

          function luminanceDark(el) {
            if (!el || isOverlaySized(el)) return false;
            const lum = parseLuminance(window.getComputedStyle(el).backgroundColor);
            return lum !== null && lum < 0.45;
          }

          function measureNaturallyDark() {
            try {
              const html = document.documentElement;
              const body = document.body;
              const main = document.querySelector('main, #root, #app, #__next, ytd-app, [role="main"]');
              if (luminanceDark(html) || luminanceDark(body) || luminanceDark(main)) return true;

              if (withSiteColorScheme(() => schemeIncludesDark(html) || schemeIncludesDark(body))) return true;

              const metaScheme = document.querySelector('meta[name="color-scheme"]');
              if (metaScheme && String(metaScheme.content || '').toLowerCase().includes('dark')) return true;

              const metaTheme = document.querySelector('meta[name="theme-color"]');
              if (metaTheme && metaTheme.content) {
                const lum = parseLuminance(metaTheme.content);
                if (lum !== null && lum < 0.45) return true;
              }

              if (attrThemeDark(html) || attrThemeDark(body)) return true;
              const ytd = document.querySelector('ytd-app');
              if (ytd && (ytd.hasAttribute('dark') || attrThemeDark(ytd))) return true;

              if (body) {
                const nodes = body.getElementsByTagName('*');
                let seen = 0;
                for (let i = 0; i < nodes.length && seen < 8; i++) {
                  const el = nodes[i];
                  if (el.tagName.indexOf('-') < 0) continue;
                  seen++;
                  const root = el.shadowRoot;
                  if (!root) continue;
                  if (attrThemeDark(el) || luminanceDark(el)) return true;
                  const inner = root.querySelector('main, #root, #app, #__next, [role="main"]') || root.firstElementChild;
                  if (inner && (luminanceDark(inner) || attrThemeDark(inner))) return true;
                }
              }
            } catch (e) {}
            return false;
          }

          function isDarkModeActive() {
            const engine = currentEngine();
            if (engine === 'smart') return true;
            if (engine === 'off' && invertTextImages && isNaturallyDark()) return true;
            return false;
          }

          function evaluateAndApply() {
            const engine = currentEngine();

            if (engine === 'off') {
              removeAllDarkStyles();
              if (invertTextImages && isNaturallyDark()) {
                ensureImageStyles();
                scanImages();
              }
              return;
            }

            if (engine === 'native') {
              removeSmartStyles();
              ensureNativeStyles();
              return;
            }

            removeNativeStyles();
            ensureSmartStyles();

            if (isNaturallyDark()) {
              document.documentElement.removeAttribute('data-paddle-dark-mode');
            } else {
              document.documentElement.setAttribute('data-paddle-dark-mode', 'active');
            }

            if (invertTextImages) {
              ensureImageStyles();
              scanImages();
            }
          }

          let lastContextMenuTarget = null;
          document.addEventListener('contextmenu', (e) => {
            lastContextMenuTarget = e.target;
          }, true);

          function findTargetImage(el) {
            if (!el || el.nodeType !== 1) return null;
            if (el.tagName === 'IMG') return el;
            const direct = el.querySelector('img');
            if (direct) return direct;
            const container = el.closest('[data-testid="tweetPhoto"], picture, figure, a');
            if (container) {
              const img = container.querySelector('img');
              if (img) return img;
            }
            if (el.parentElement) {
              const sib = el.parentElement.querySelector(':scope > img');
              if (sib) return sib;
            }
            return null;
          }

          document.addEventListener('click', (e) => {
            if (e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey) {
              const img = findTargetImage(e.target);
              if (img) {
                e.preventDefault();
                e.stopPropagation();
                toggleElement(img);
              }
            }
          }, true);

          function toggleElement(el) {
            if (!el) return false;
            ensureImageStyles();
            const img = findTargetImage(el) || el;
            const active = img.getAttribute('data-paddle-inverted-text') === 'true';
            img.setAttribute('data-paddle-manual', 'true');
            if (active) {
              img.removeAttribute('data-paddle-inverted-text');
              img.removeAttribute('data-paddle-auto-inverted');
            } else {
              img.setAttribute('data-paddle-inverted-text', 'true');
            }
            return !active;
          }

          function testCanvas(source, targetImg) {
            const canvas = document.createElement('canvas');
            canvas.width = 48;
            canvas.height = 48;
            const ctx = canvas.getContext('2d', { willReadFrequently: true });
            if (!ctx) return;
            ctx.drawImage(source, 0, 0, 48, 48);
            const id = ctx.getImageData(0, 0, 48, 48);
            const d = id.data;
            let bright = 0;
            let dark = 0;
            let achromatic = 0;
            let totalSat = 0;
            const total = 48 * 48;
            for (let i = 0; i < d.length; i += 4) {
              const r = d[i] / 255;
              const g = d[i+1] / 255;
              const b = d[i+2] / 255;
              const sat = Math.max(r, g, b) - Math.min(r, g, b);
              totalSat += sat;
              if (sat < 0.08) achromatic++;
              const lum = 0.299 * r + 0.587 * g + 0.114 * b;
              if (lum > 0.80) bright++;
              else if (lum < 0.45) dark++;
            }
            const meanSat = totalSat / total;
            const achromaticFrac = achromatic / total;
            const brightFrac = bright / total;
            const darkFrac = dark / total;
            if (meanSat < 0.12 && achromaticFrac >= 0.75 && brightFrac >= 0.45 && darkFrac >= 0.03) {
              ensureImageStyles();
              targetImg.setAttribute('data-paddle-inverted-text', 'true');
              targetImg.setAttribute('data-paddle-auto-inverted', 'true');
            }
          }

          function analyzeImage(img) {
            if (!img || img.getAttribute('data-paddle-manual') === 'true') return;

            const run = () => {
              if (!invertTextImages || !isDarkModeActive()) return;
              if (img.getAttribute('data-paddle-manual') === 'true') return;
              const src = img.currentSrc || img.src || '';
              if (!src || img.getAttribute('data-paddle-analyzed-src') === src) return;
              const w = img.naturalWidth || img.width || 0;
              const h = img.naturalHeight || img.height || 0;
              if (w < 120 || h < 80) return;
              img.setAttribute('data-paddle-analyzed-src', src);
              try {
                testCanvas(img, img);
              } catch (corsErr) {
                if (!src.startsWith('data:')) {
                  const probe = new Image();
                  probe.crossOrigin = 'anonymous';
                  probe.onload = () => {
                    try { testCanvas(probe, img); } catch (_) {}
                  };
                  probe.src = src;
                }
              }
            };

            if (img.complete && (img.naturalWidth || 0) > 0) {
              run();
            } else {
              img.addEventListener('load', run, { once: true });
            }
          }

          function scanImages() {
            if (!invertTextImages || !isDarkModeActive()) return;
            ensureImageStyles();
            document.querySelectorAll('img').forEach(analyzeImage);
          }

          let mutationObserver = null;
          function startMutationObserver() {
            if (mutationObserver || !('MutationObserver' in window)) return;
            mutationObserver = new MutationObserver((mutations) => {
              if (!invertTextImages || !isDarkModeActive()) return;
              for (const m of mutations) {
                if (m.type === 'attributes' && m.target && m.target.tagName === 'IMG') {
                  const img = m.target;
                  const src = img.currentSrc || img.src || '';
                  if (img.getAttribute('data-paddle-analyzed-src') !== src && img.getAttribute('data-paddle-manual') !== 'true') {
                    img.removeAttribute('data-paddle-inverted-text');
                    img.removeAttribute('data-paddle-auto-inverted');
                    analyzeImage(img);
                  }
                  continue;
                }
                for (const node of m.addedNodes) {
                  if (node.nodeType === 1) {
                    if (node.tagName === 'IMG') {
                      analyzeImage(node);
                    } else if (node.querySelectorAll) {
                      node.querySelectorAll('img').forEach(analyzeImage);
                    }
                  }
                }
              }
            });
            const root = document.documentElement || document;
            mutationObserver.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'srcset'] });
          }

          let themeObserver = null;
          let themeTimer = null;
          function startThemeObserver() {
            if (!('MutationObserver' in window)) return;
            if (!themeObserver) {
              themeObserver = new MutationObserver(() => {
                if (themeTimer) clearTimeout(themeTimer);
                themeTimer = setTimeout(() => {
                  themeTimer = null;
                  evaluateAndApply();
                }, 100);
              });
            }
            const opts = { attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-bs-theme', 'dark', 'theme'] };
            if (document.documentElement) themeObserver.observe(document.documentElement, opts);
            if (document.body) themeObserver.observe(document.body, opts);
          }

          const bootEngine = currentEngine();
          if (bootEngine === 'smart') {
            ensureSmartStyles();
          } else if (bootEngine === 'native') {
            ensureNativeStyles();
          }

          startThemeObserver();

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => {
              evaluateAndApply();
              startMutationObserver();
              startThemeObserver();
            }, { once: true });
          } else {
            evaluateAndApply();
            startMutationObserver();
            startThemeObserver();
          }
          setTimeout(evaluateAndApply, 400);
          setTimeout(evaluateAndApply, 1600);

          window.__paddleDarkMode = {
            setPolicy(policy) {
              if (policy && policy.engine) {
                engineOverride = String(policy.engine);
              }
              if (policy && typeof policy.invertTextImages === 'boolean') {
                invertTextImages = policy.invertTextImages;
              }
              evaluateAndApply();
            },
            setKeepLight() {
              engineOverride = 'off';
              evaluateAndApply();
            },
            setDarkMode(on) {
              engineOverride = on ? 'smart' : 'off';
              evaluateAndApply();
            },
            toggle() {
              const next = currentEngine() === 'off';
              engineOverride = next ? 'smart' : 'off';
              evaluateAndApply();
              return next;
            },
            isEnabled() {
              return currentEngine() !== 'off';
            },
            toggleLastClickedImage(imageURL) {
              let target = findTargetImage(lastContextMenuTarget);
              if (!target && imageURL) {
                target = document.querySelector(`img[src="${imageURL}"], [style*="${imageURL}"]`);
              }
              if (target) {
                return toggleElement(target);
              }
              return false;
            },
            setInvertTextImages(enabled) {
              invertTextImages = Boolean(enabled);
              if (invertTextImages) {
                ensureImageStyles();
                scanImages();
              } else {
                document.querySelectorAll('[data-paddle-auto-inverted="true"]').forEach((el) => {
                  el.removeAttribute('data-paddle-inverted-text');
                  el.removeAttribute('data-paddle-auto-inverted');
                });
                document.querySelectorAll('[data-paddle-analyzed-src]').forEach((el) => {
                  el.removeAttribute('data-paddle-analyzed-src');
                });
              }
            }
          };
        })();
        })();
        """
    }

    /// Extracts normalized host keys where `darkMode` is explicitly configured (not Auto).
    static func hostTable(_ sites: [String: SiteSettings]) -> [[Any]] {
        var table: [String: String] = [:]
        for (key, settings) in sites.sorted(by: { PaddleConfig.hostKeyPrecedes($0.key, $1.key) }) {
            guard let mode = settings.darkMode else { continue }
            let token: String? = switch mode {
            case .light: "light"
            case .dark: "dark"
            case .native: "native"
            case .auto: nil
            }
            if let token {
                table[PaddleConfig.normalizedHost(key)] = token
            }
        }
        return table.keys.sorted().map { [$0, table[$0] ?? "light"] }
    }

    private static func json(_ table: [[Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
          }
        return text
    }
}
