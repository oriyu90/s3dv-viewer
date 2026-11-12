// Boot-time JavaScript injected at documentStart of the embedded WKWebView.
//
//  * redirects the viewer's `ws://127.0.0.1:<HTTP port>/ws` URL to the native
//    WebSocket server port, so the kit renderer (`web/main.js`) stays
//    byte-identical to the research kit;
//  * forwards the user's streaming/memory settings to the product renderer;
//  * replaces requestAnimationFrame while the page is hidden (WebKit pauses it
//    for occluded windows, which would freeze the replay);
//  * funnels console.error/warn, uncaught errors and promise rejections into the
//    native console panel;
//  * exposes `window.__s3dvHost`, the small bridge the native toolbar drives
//    (the product renderer answers it; the parity renderer maps it to DOM clicks).
import Foundation

enum ViewerBootScript {
    static func source(wsURL: String, renderer: RendererMode, config: [String: Any]) -> String {
        let configJSON = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => {
          window.__s3dvWsOverride = '\(wsURL)';
          window.__s3dvRenderer = '\(renderer.rawValue)';
          window.__s3dvConfig = \(configJSON);
          const Real = window.WebSocket;
          class S3DVRedirectWS extends Real {
            // Redirect only the viewer's own local /ws URL; any other WebSocket
            // the page might create passes through untouched.
            constructor(url, protocols) {
              const raw = String(url);
              super(/^ws:\\/\\/127\\.0\\.0\\.1:\\d+\\/ws$/.test(raw) ? window.__s3dvWsOverride : raw, protocols);
            }
          }
          window.WebSocket = S3DVRedirectWS;
          // rAF fallback: WebKit pauses requestAnimationFrame while the page is
          // hidden (occluded window / background launches). The replay must keep
          // presenting frames in that state too, so while hidden the rAF queue is
          // serviced by a throttled interval instead (WebKit clamps hidden timers
          // to ~1 Hz, which matches replay pacing; a visible page uses real rAF).
          const realRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : null;
          let hiddenCbs = [], hiddenTimer = null, hiddenNext = 0, hiddenHandle = 1e9;
          const pump = () => {
            const now = performance.now();
            if (now < hiddenNext || hiddenCbs.length === 0) return;
            hiddenNext = now + 200;
            const due = hiddenCbs; hiddenCbs = [];
            for (const cb of due) { try { cb(now); } catch (e) { lowercaseLog('error', ['rAF cb: ' + e]); } }
          };
          window.requestAnimationFrame = (cb) => {
            if (!document.hidden && realRAF) return realRAF(cb);
            if (hiddenTimer == null) hiddenTimer = setInterval(pump, 60);
            hiddenCbs.push(cb);
            return ++hiddenHandle;
          };
          document.addEventListener('visibilitychange', () => {
            if (!document.hidden && hiddenTimer != null) {
              clearInterval(hiddenTimer); hiddenTimer = null;
              const pending = hiddenCbs; hiddenCbs = [];
              for (const cb of pending) { try { realRAF(cb); } catch (e) { lowercaseLog('error', ['rAF flush: ' + e]); } }
            }
          });
          const lowercaseLog = (level, args) => {
            try {
              window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.s3dvLog
                && window.webkit.messageHandlers.s3dvLog.postMessage(
                  { level: level, text: args.map(String).join(' ') });
            } catch (e) {}
          };
          ['error', 'warn'].forEach(level => {
            const original = window.console[level] ? window.console[level].bind(window.console) : null;
            window.console[level] = (...a) => { lowercaseLog(level, a); original && original(...a); };
          });
          window.addEventListener('error', e => lowercaseLog('error', [e.message || 'uncaught error']));
          window.addEventListener('unhandledrejection',
            e => lowercaseLog('error', ['unhandled rejection: ' + (e.reason && e.reason.message || e.reason)]));
          // Native bridge. The product renderer installs window.__s3dv itself;
          // these fallbacks keep the toolbar functional on the parity page by
          // driving its DOM controls.
          window.__s3dvHost = {
            click: (id) => { const e = document.getElementById(id); if (e) e.click(); },
            seek: (t) => {
              const el = document.getElementById('timeline');
              if (el && !el.disabled) { el.value = String(t); el.dispatchEvent(new Event('change')); }
            },
            setSpeed: (r) => {
              const el = document.getElementById('speed');
              if (el) { el.value = String(r); el.dispatchEvent(new Event('change')); }
            },
            applyConfig: (cfg) => {
              if (window.__s3dv && window.__s3dv.applyConfig) window.__s3dv.applyConfig(cfg);
            },
            metrics: () => {
              if (window.__s3dv && window.__s3dv.metrics) return JSON.stringify(window.__s3dv.metrics());
              return '{}';
            }
          };
        })();
        """
    }

    // Parity page: the kit UI owns the state, so the native menu clicks its controls.
    static let toggleWireframeParity = "document.getElementById('wire')?.click()"
    static let resetViewParity = "document.getElementById('reset')?.click()"

    // Product page: first-party API.
    static let toggleWireframeProduct = "window.__s3dv && window.__s3dv.toggleWireframe()"
    static let resetViewProduct = "window.__s3dv && window.__s3dv.resetView()"

    /// Telemetry snapshot read back from the viewer page. Both pages expose the
    /// same element ids, so one probe covers the research and product renderers.
    static let telemetryJS = """
    (() => {
      const t = id => { const e = document.getElementById(id); return e ? e.textContent : null; };
      const num = s => s === null ? null : Number(String(s).replace(/[^0-9.]/g, ''));
      const api = window.__s3dv && window.__s3dv.metrics ? window.__s3dv.metrics() : null;
      return JSON.stringify({
        status: t('status'),
        chunks: num(t('chunks')),
        triangles: num(t('triangles')),
        tex: num(t('tex')),
        packets: num(t('packets')),
        bytesLabel: t('bytes'),
        op: t('op'),
        time: t('time'),
        fps: num(t('fps')),
        frameMs: num(t('frame_ms')),
        drawCalls: num(t('draw_calls')),
        geometries: num(t('geometries')),
        evicted: api && Number.isFinite(api.evicted) ? api.evicted : null,
        deferred: api && Number.isFinite(api.deferred) ? api.deferred : null,
        arenaBytes: api && Number.isFinite(api.arenaBytes) ? api.arenaBytes : null,
        liveBytes: api && Number.isFinite(api.liveBytes) ? api.liveBytes : null,
        presented: api && Number.isFinite(api.presented) ? api.presented : num(t('presented')),
        dropped: api && Number.isFinite(api.dropped) ? api.dropped : num(t('dropped')),
        backlog: api && Number.isFinite(api.backlog) ? api.backlog : num(t('backlog')),
        renderer: window.__s3dvRenderer || null
      });
    })()
    """
}
