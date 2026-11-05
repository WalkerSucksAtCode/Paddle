import Foundation

/// Page-world script that puts a page back where it was scrolled after Back.
///
/// WebKit restores the document and an overflow element that is still the same node. Sites such as X scroll a
/// column, then on a route change set that column back to the top and build it again. An immediate Back then
/// lands at the top, because the site has not stored a position of its own yet. This script records the window
/// and any scrolled column on the click (before the site's handler) and on `pushState`, and writes those
/// positions back after `popstate` and after a back/forward load. Later writes cover a column the site resets
/// once it has rebuilt, including resets that run hundreds of milliseconds after Back. A trusted scroll after
/// wheel, key or pointer input cancels the rest, so a position the user picks in that window is left alone;
/// layout scroll from `pageZoom` reflow is ignored.
public enum ScrollRestoreScript {
    public static let source = #"""
    (() => {
      if (window.__paddleScrollRestore) return;
      window.__paddleScrollRestore = true;

      const norm = (href) => {
        try {
          const u = new URL(href, location.href);
          let path = u.pathname;
          if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
          return u.origin + path + u.search;
        } catch (e) {
          return href;
        }
      };

      const samePlace = (a, b) => norm(a) === norm(b);

      const storageKey = (href) => 'paddle-scroll-v1:' + norm(href);

      const persistSnap = (href, snap) => {
        if (!worth(snap)) return;
        try { sessionStorage.setItem(storageKey(href), JSON.stringify(snap)); } catch (e) {}
      };

      const readSnap = (href) => {
        let raw = null;
        try { raw = sessionStorage.getItem(storageKey(href)); } catch (e) {}
        if (!raw) return null;
        try { return JSON.parse(raw); } catch (e) { return null; }
      };

      const marker = (el) => {
        if (el.id) {
          const sel = '#' + CSS.escape(el.id);
          if (document.querySelectorAll(sel).length === 1) return sel;
        }
        const test = el.getAttribute && el.getAttribute('data-testid');
        if (test) {
          const sel = '[data-testid="' + CSS.escape(test) + '"]';
          if (document.querySelectorAll(sel).length === 1) return sel;
        }
        const parts = [];
        let node = el;
        while (node && node.parentElement && node !== document.body) {
          const kids = node.parentElement.children;
          let index = 0;
          for (; index < kids.length; index++) if (kids[index] === node) break;
          parts.push(index);
          node = node.parentElement;
        }
        return 'p:' + parts.reverse().join('.');
      };

      const find = (key) => {
        if (!key.startsWith('p:')) return document.querySelector(key);
        let node = document.body;
        const bits = key.slice(2);
        if (!bits) return node;
        for (const bit of bits.split('.')) {
          if (!node || !node.children) return null;
          node = node.children[Number(bit)];
        }
        return node;
      };

      const snapshot = () => {
        const nodes = [];
        const list = document.querySelectorAll('*');
        for (let i = 0; i < list.length && nodes.length < 30; i++) {
          const el = list[i];
          if (el === document.body || el === document.documentElement) continue;
          const top = el.scrollTop, left = el.scrollLeft;
          if (top <= 1 && left <= 1) continue;
          if (el.scrollHeight - el.clientHeight <= 1 && el.scrollWidth - el.clientWidth <= 1) continue;
          nodes.push([marker(el), top, left]);
        }
        return { x: window.scrollX || 0, y: window.scrollY || 0, nodes };
      };

      const restore = (snap) => {
        if (!snap) return;
        try { window.scrollTo(snap.x || 0, snap.y || 0); } catch (e) {}
        const nodes = snap.nodes || [];
        for (let i = 0; i < nodes.length; i++) {
          const el = find(nodes[i][0]);
          if (!el) continue;
          el.scrollTop = nodes[i][1];
          el.scrollLeft = nodes[i][2];
        }
      };

      const worth = (snap) => snap && (snap.y > 1 || snap.x > 1 || (snap.nodes && snap.nodes.length));

      const drifted = (snap) => {
        if (!snap) return false;
        if (Math.abs((window.scrollX || 0) - (snap.x || 0)) > 40) return true;
        if (Math.abs((window.scrollY || 0) - (snap.y || 0)) > 40) return true;
        const nodes = snap.nodes || [];
        for (let i = 0; i < nodes.length; i++) {
          const el = find(nodes[i][0]);
          if (!el) continue;
          if (Math.abs(el.scrollTop - nodes[i][1]) > 40) return true;
          if (Math.abs(el.scrollLeft - nodes[i][2]) > 40) return true;
        }
        return false;
      };

      const trail = [{ href: location.href, snap: null }];
      let index = 0;
      let pending = null;
      let token = 0;

      const capture = () => { pending = snapshot(); };
      document.addEventListener('pointerdown', capture, true);
      document.addEventListener('keydown', capture, true);

      const schedule = (snap) => {
        if (!worth(snap)) return;
        const mine = ++token;
        const href = location.href;
        let stop = false;
        let userIntent = false;
        const noteUser = () => { userIntent = true; };
        const noteKey = (event) => {
          const k = event.key;
          if (k === 'ArrowUp' || k === 'ArrowDown' || k === 'PageUp' || k === 'PageDown' || k === 'Home' || k === 'End' || k === ' ') {
            noteUser();
          }
        };
        document.addEventListener('wheel', noteUser, { capture: true, passive: true });
        document.addEventListener('keydown', noteKey, true);
        document.addEventListener('pointerdown', noteUser, true);
        const onScroll = (event) => {
          if (event.isTrusted && userIntent) stop = true;
        };
        document.addEventListener('scroll', onScroll, true);
        const apply = () => {
          if (mine !== token || stop || !samePlace(location.href, href)) return;
          restore(snap);
        };
        apply();
        requestAnimationFrame(apply);
        [50, 100, 200, 400, 800, 1200, 2000, 3000, 4000, 5000].forEach((ms) => setTimeout(apply, ms));
        const drift = setInterval(() => {
          if (mine !== token || stop || userIntent || !samePlace(location.href, href)) return;
          if (drifted(snap)) apply();
        }, 250);
        setTimeout(() => {
          if (mine !== token) return;
          clearInterval(drift);
          document.removeEventListener('scroll', onScroll, true);
          document.removeEventListener('wheel', noteUser, true);
          document.removeEventListener('keydown', noteKey, true);
          document.removeEventListener('pointerdown', noteUser, true);
        }, 5500);
      };

      const push = history.pushState;
      history.pushState = function () {
        const leaving = trail[index].href;
        const snap = pending || snapshot();
        trail[index].snap = snap;
        persistSnap(leaving, snap);
        pending = null;
        const result = push.apply(this, arguments);
        trail.splice(index + 1);
        index += 1;
        trail[index] = { href: location.href, snap: null };
        return result;
      };

      const replace = history.replaceState;
      history.replaceState = function () {
        const result = replace.apply(this, arguments);
        if (trail[index]) trail[index].href = location.href;
        return result;
      };

      addEventListener('popstate', () => {
        const href = location.href;
        let next = -1;
        if (trail[index - 1] && samePlace(trail[index - 1].href, href)) next = index - 1;
        else if (trail[index + 1] && samePlace(trail[index + 1].href, href)) next = index + 1;
        else {
          for (let k = trail.length - 1; k >= 0; k--) if (samePlace(trail[k].href, href)) { next = k; break; }
        }
        let snap = null;
        if (next >= 0) {
          snap = trail[next].snap;
          index = next;
        }
        if (!worth(snap)) snap = readSnap(href);
        schedule(snap);
      });

      addEventListener('pagehide', () => {
        const snap = pending || snapshot();
        persistSnap(location.href, snap);
      });
      addEventListener('pageshow', (event) => {
        let type = '';
        try { type = performance.getEntriesByType('navigation')[0].type; } catch (e) {}
        if (type !== 'back_forward' && !event.persisted) return;
        let snap = readSnap(location.href);
        if (!worth(snap) && event.persisted) return;
        schedule(snap);
      });
    })();
    """#
}
