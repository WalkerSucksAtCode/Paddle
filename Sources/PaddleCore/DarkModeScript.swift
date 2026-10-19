import Foundation

/// Injected at document start in the isolated content world (`.defaultClient`).
/// Sets `color-scheme` before first paint. A page that is already dark (computed background, `data-theme`,
/// or `theme-color`) is left alone so it is not inverted twice. Light pages get inverted backgrounds and text;
/// photos, video, icons, and embeds are left alone. `window.__paddleDarkMode.setDarkMode(on)` toggles it live.
/// When `invertTextImages` is active, images that are clearly dark text on a bright background (text screenshots,
/// documents) are filtered into dark mode, and any image can be toggled via Option-click or the context menu.
public enum DarkModeScript {
    public static func source(for sites: [String: SiteSettings], defaultDarkMode: Bool, invertTextImages: Bool = false) -> String {
        let table = hostTable(sites)
        let tableJSON = json(table)
        let defaultDarkStr = defaultDarkMode ? "true" : "false"
        let invertTextImagesStr = invertTextImages ? "true" : "false"

        return """
        (() => {
        'use strict';

        (function () {
          const T = new Map(\(tableJSON));
          let defaultDark = \(defaultDarkStr);
          let invertTextImages = \(invertTextImagesStr);
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
          const IMAGE_STYLE_ID = 'paddle-text-image-styles';

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

          function isDarkModeActive() {
            return shouldBeDark() || isNaturallyDark();
          }

          function evaluateAndApply() {
            const darkDesired = shouldBeDark();
            if (!darkDesired) {
              removeStyles();
              if (invertTextImages && isNaturallyDark()) {
                ensureImageStyles();
                scanImages();
              }
              return;
            }

            ensureStyles();

            // If the website already rendered natively in dark mode, do not invert it!
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

          // --- Image Inversion & Heuristic ---

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

          // Option-click toggles inversion directly on an image
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

          // At document-start, inject the style tag so color-scheme: dark triggers native dark palette immediately
          if (shouldBeDark()) {
            ensureStyles();
          }

          // Evaluate once DOM is loaded, and again after a short delay for late-hydrating SPAs
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => {
              evaluateAndApply();
              startMutationObserver();
            }, { once: true });
          } else {
            evaluateAndApply();
            startMutationObserver();
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
