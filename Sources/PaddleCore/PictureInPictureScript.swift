import Foundation

/// Page-world helpers for HTML5 Picture-in-Picture. WebKit shows the system PiP window once
/// `requestPictureInPicture()` succeeds; Paddle picks a `<video>` and reports whether one is active.
public enum PictureInPictureScript {
    public static let handlerName = "paddlePictureInPicture"

    /// Listens for PiP enter/leave on the main document.
    public static let monitorSource = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler || window.__paddlePictureInPicture) return;
      window.__paddlePictureInPicture = true;
      const post = handler.postMessage.bind(handler);
      let active = !!document.pictureInPictureElement;
      const report = () => {
        const now = !!document.pictureInPictureElement;
        if (now === active) return;
        active = now;
        try { post({ active: now }); } catch (e) {}
      };
      document.addEventListener('enterpictureinpicture', report);
      document.addEventListener('leavepictureinpicture', report);
      try { post({ active }); } catch (e) {}
    })();
    """

    /// Runs in the menu/shortcut turn. Wrapping the call in `Task` drops user activation and YouTube refuses PiP.
    public static let toggle = """
    (() => {
      if (document.pictureInPictureElement) {
        document.exitPictureInPicture();
        return true;
      }
      const pick = () => {
        const seen = new Set();
        const videos = [];
        const walk = (root) => {
          if (!root || seen.has(root)) return;
          seen.add(root);
          if (root instanceof HTMLVideoElement) videos.push(root);
          const list = root.querySelectorAll ? root.querySelectorAll('video') : [];
          for (let i = 0; i < list.length; i++) videos.push(list[i]);
          const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
          for (let i = 0; i < all.length; i++) {
            const el = all[i];
            if (el && el.shadowRoot) walk(el.shadowRoot);
          }
        };
        walk(document);
        const uniq = [];
        const ids = new Set();
        for (const v of videos) {
          if (!ids.has(v)) { ids.add(v); uniq.push(v); }
        }
        const yt = document.querySelector('video.html5-main-video');
        if (yt && !yt.ended) return yt;
        const playing = uniq.find(v => !v.paused && !v.ended && v.readyState > 2)
          || uniq.find(v => !v.paused && !v.ended)
          || uniq.find(v => !v.paused)
          || uniq.slice().sort((a, b) => (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight))[0];
        return playing || null;
      };
      const video = pick();
      if (!video) return false;
      if (video.disablePictureInPicture) video.disablePictureInPicture = false;
      try {
        const p = video.requestPictureInPicture();
        if (p && typeof p.catch === 'function') p.catch(() => {});
      } catch (e) { return false; }
      return true;
    })()
    """

    public static let exit = """
    (() => {
      if (document.pictureInPictureElement) document.exitPictureInPicture();
    })()
    """
}
