import Foundation

/// Page-world script that tells Paddle when a frame is uploading a file or asks before it is left (unsaved changes),
/// so the sleep sweep can leave that tab running (`keepPageWorkRunning`). It posts `{id, uploading, guardsUnload}` to
/// the `paddlePageWork` handler when either changes, and both false when the frame goes away; `id` tells frames apart.
///
/// An upload is a `fetch` or `XMLHttpRequest` whose body carries at least 64 KB (a file, a large blob or string) or is
/// a stream, counted until the request ends. Short posts (analytics, chat messages, autosave pings) don't count. Unsaved
/// changes is a `beforeunload` listener on the window or an `onbeforeunload` handler: what sites add while a form is
/// dirty. Nothing here changes what the page sends or sees beyond the wrapped functions themselves.
public enum PageWorkScript {
    public static let handlerName = "paddlePageWork"
    /// Bytes of request body that make a request an upload.
    public static let uploadThreshold = 64 * 1024

    public static let source = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler || window.__paddlePageWork) return;
      window.__paddlePageWork = true;
      const post = handler.postMessage.bind(handler);
      const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
      const big = \(uploadThreshold);
      let uploads = 0;
      const listeners = new Set();
      let handlerSet = false;
      let sent = 'false:false';
      const report = (gone) => {
        const uploading = !gone && uploads > 0;
        const guardsUnload = !gone && (listeners.size > 0 || handlerSet);
        const key = uploading + ':' + guardsUnload;
        if (key === sent) return;
        sent = key;
        try { post({ id, uploading, guardsUnload }); } catch (e) {}
      };
      const isUpload = (body) => {
        try {
          if (body == null) return false;
          if (typeof body === 'string') return body.length >= big;
          if (body instanceof Blob) return body.size >= big;
          if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return body.byteLength >= big;
          if (typeof ReadableStream !== 'undefined' && body instanceof ReadableStream) return true;
          if (body instanceof FormData) {
            let size = 0;
            for (const [, value] of body) size += value instanceof Blob ? value.size : String(value).length;
            return size >= big;
          }
        } catch (e) {}
        return false;
      };
      const started = () => {
        uploads += 1;
        report(false);
        let ended = false;
        return () => {
          if (ended) return;
          ended = true;
          uploads -= 1;
          report(false);
        };
      };

      const nativeFetch = window.fetch;
      if (typeof nativeFetch === 'function') {
        window.fetch = function (input, init) {
          let upload = false;
          try {
            upload = isUpload(init && init.body)
              || (!(init && 'body' in init) && typeof Request !== 'undefined' && input instanceof Request
                  && input.body != null);
          } catch (e) {}
          if (!upload) return nativeFetch.apply(this, arguments);
          const end = started();
          try {
            const result = nativeFetch.apply(this, arguments);
            Promise.resolve(result).then(end, end);
            return result;
          } catch (e) {
            end();
            throw e;
          }
        };
      }

      const xhr = window.XMLHttpRequest && XMLHttpRequest.prototype;
      if (xhr && typeof xhr.send === 'function') {
        const nativeSend = xhr.send;
        xhr.send = function (body) {
          if (!isUpload(body)) return nativeSend.apply(this, arguments);
          const end = started();
          try { this.addEventListener('loadend', end); } catch (e) {}
          try {
            return nativeSend.apply(this, arguments);
          } catch (e) {
            end();
            throw e;
          }
        };
      }

      const target = window.EventTarget && EventTarget.prototype;
      if (target) {
        const nativeAdd = target.addEventListener, nativeRemove = target.removeEventListener;
        target.addEventListener = function (type, listener) {
          if (this === window && type === 'beforeunload' && listener) { listeners.add(listener); report(false); }
          return nativeAdd.apply(this, arguments);
        };
        target.removeEventListener = function (type, listener) {
          if (this === window && type === 'beforeunload' && listener) { listeners.delete(listener); report(false); }
          return nativeRemove.apply(this, arguments);
        };
      }

      for (const owner of [window, Object.getPrototypeOf(window)]) {
        const d = owner && Object.getOwnPropertyDescriptor(owner, 'onbeforeunload');
        if (!d || !d.configurable || typeof d.set !== 'function') continue;
        Object.defineProperty(owner, 'onbeforeunload', {
          configurable: true, enumerable: d.enumerable,
          get: d.get,
          set: function (value) {
            d.set.call(this, value);
            if (this === window) { handlerSet = typeof value === 'function'; report(false); }
          },
        });
        break;
      }

      window.addEventListener('pagehide', () => report(true), true);
      window.addEventListener('pageshow', () => report(false), true);
    })();
    """
}
