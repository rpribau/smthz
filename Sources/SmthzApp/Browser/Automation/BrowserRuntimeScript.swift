import Foundation

/// JavaScript injected by browser automation (BROWSER-AGENTS-EXPERIMENT A.6). Kept in Swift so the
/// SwiftPM build and the packaged app carry it without a resource rule.
enum BrowserRuntimeScript {
    /// Page world, documentStart, main frame: console capture, fetch/XHR shim (network log, extra headers,
    /// interception) and the R-B7 shims. `__SMTHZ_CONFIG__` is replaced with the tab's JSON config.
    static let page = #"""
    (() => {
      if (window.__smthzConfigure) return;
      const post = (m) => { try { window.webkit.messageHandlers.smthzAutomation.postMessage(m); } catch (_) {} };
      let cfg = __SMTHZ_CONFIG__;
      const str = (v) => { try { return typeof v === 'string' ? v : (v instanceof Error ? v.stack || String(v) : JSON.stringify(v)); } catch (_) { return String(v); } };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) { post({ t: 'console', level, text: args.map(str).join(' ') }); return original.apply(this, args); };
      }
      addEventListener('error', (e) => post({ t: 'console', level: 'error', text: 'uncaught: ' + e.message }));
      addEventListener('unhandledrejection', (e) => post({ t: 'console', level: 'error', text: 'unhandledrejection: ' + str(e.reason) }));

      const glob = (pattern) => new RegExp('^' + pattern.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$');
      const matches = (url) => cfg.intercept && (cfg.patterns.length === 0 || cfg.patterns.some((p) => glob(p).test(url)));
      const paused = new Map();
      let nextId = 1;
      const pause = (method, url, type) => new Promise((resume) => {
        const id = String(nextId++);
        paused.set(id, resume);
        post({ t: 'intercept', id, method, url, type });
      });

      const originalFetch = window.fetch;
      window.fetch = async function (input, init) {
        const request = new Request(input, init);
        const url = request.url, method = request.method;
        if (cfg.offline) return Promise.reject(new TypeError('Load failed'));
        if (matches(url)) await pause(method, url, 'fetch');
        const headers = new Headers(request.headers);
        for (const [k, v] of Object.entries(cfg.headers || {})) headers.set(k, v);
        const response = await originalFetch.call(this, new Request(request, { headers }));
        post({ t: 'net', url, method, status: response.status, mime: response.headers.get('content-type'), size: Number(response.headers.get('content-length')) || null, source: 'script' });
        return response;
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url, ...rest) {
        this.__smthz = { method: String(method).toUpperCase(), url: new URL(url, location.href).href };
        return open.call(this, method, url, ...rest);
      };
      XMLHttpRequest.prototype.send = function (body) {
        const info = this.__smthz || { method: 'GET', url: '' };
        this.addEventListener('loadend', () => post({ t: 'net', url: info.url, method: info.method, status: this.status, mime: this.getResponseHeader('content-type'), size: Number(this.getResponseHeader('content-length')) || null, source: 'script' }));
        const go = () => {
          if (cfg.offline) { this.dispatchEvent(new ProgressEvent('error')); return; }
          for (const [k, v] of Object.entries(cfg.headers || {})) { try { this.setRequestHeader(k, v); } catch (_) {} }
          send.call(this, body);
        };
        if (matches(info.url)) pause(info.method, info.url, 'xhr').then(go); else go();
      };
      try {
        new PerformanceObserver((list) => {
          for (const e of list.getEntries()) {
            if (e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest') continue;
            post({ t: 'net', url: e.name, size: e.transferSize || null, source: 'resourceTiming' });
          }
        }).observe({ type: 'resource', buffered: true });
      } catch (_) {}

      const onLine = Object.getOwnPropertyDescriptor(Navigator.prototype, 'onLine');
      Object.defineProperty(Navigator.prototype, 'onLine', { configurable: true, get() { return cfg.offline ? false : onLine.get.call(this); } });
      const matchMedia = window.matchMedia.bind(window);
      window.matchMedia = (query) => {
        const m = /prefers-reduced-motion:\s*(reduce|no-preference)/.exec(query);
        if (!m || !cfg.reducedMotion) return matchMedia(query);
        return { matches: m[1] === cfg.reducedMotion, media: query, onchange: null, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; } };
      };
      const geo = navigator.geolocation;
      if (geo) {
        const position = () => ({ coords: { latitude: cfg.geo.latitude, longitude: cfg.geo.longitude, accuracy: cfg.geo.accuracy || 1, altitude: null, altitudeAccuracy: null, heading: null, speed: null }, timestamp: Date.now() });
        const getCurrent = geo.getCurrentPosition.bind(geo), watch = geo.watchPosition.bind(geo);
        geo.getCurrentPosition = (ok, err, opts) => cfg.geo ? setTimeout(() => ok(position()), 0) : getCurrent(ok, err, opts);
        geo.watchPosition = (ok, err, opts) => cfg.geo ? (setTimeout(() => ok(position()), 0), 0) : watch(ok, err, opts);
      }

      Object.defineProperty(window, '__smthzConfigure', { value: (next) => {
        const wasOffline = cfg.offline;
        cfg = next;
        if (!next.intercept) { for (const resume of paused.values()) resume(); paused.clear(); }
        if (wasOffline !== next.offline) dispatchEvent(new Event(next.offline ? 'offline' : 'online'));
      } });
    })();
    """#

    /// Isolated world (`WKContentWorld "smthz"`), prepended lazily to every call: snapshot with refs and
    /// element helpers. Refs live in this world only, so the page cannot see them.
    static let isolated = #"""
    if (!globalThis.__smthz) globalThis.__smthz = (() => {
      const refs = new Map();
      const IMPLICIT = { A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading', IMG: 'img', NAV: 'navigation', MAIN: 'main', FORM: 'form', UL: 'list', OL: 'list', LI: 'listitem', TABLE: 'table', SUMMARY: 'button', DIALOG: 'dialog', P: 'paragraph', LABEL: 'label' };
      const INPUT = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button', range: 'slider', search: 'searchbox', file: 'button' };
      const INTERACTIVE = new Set(['link', 'button', 'checkbox', 'radio', 'textbox', 'searchbox', 'combobox', 'slider', 'switch', 'tab', 'menuitem', 'option', 'listbox', 'spinbutton']);
      const role = (el) => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.split(' ')[0];
        if (el.tagName === 'INPUT') return el.type === 'hidden' ? null : (INPUT[el.type] || 'textbox');
        if (el.tagName === 'A' && !el.hasAttribute('href')) return null;
        if (el.isContentEditable && el.contentEditable === 'true') return 'textbox';
        return IMPLICIT[el.tagName] || null;
      };
      const clean = (s) => (s || '').replace(/\s+/g, ' ').trim().slice(0, 100);
      const name = (el) => {
        const by = el.getAttribute('aria-labelledby');
        if (by) return clean(by.split(' ').map((id) => document.getElementById(id)?.textContent).join(' '));
        if (el.getAttribute('aria-label')) return clean(el.getAttribute('aria-label'));
        if (el.labels && el.labels.length) return clean(el.labels[0].textContent);
        if (el.tagName === 'IMG') return clean(el.alt);
        if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value);
        if (['INPUT', 'TEXTAREA'].includes(el.tagName)) return clean(el.placeholder || el.title);
        if (el.tagName === 'SELECT') return clean(el.title);
        return clean(el.innerText || el.textContent || el.title);
      };
      const hidden = (el) => {
        if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return true;
        const s = getComputedStyle(el);
        return s.display === 'none' || s.visibility === 'hidden';
      };
      const visible = (el) => !hidden(el) && el.getClientRects().length > 0;
      const snapshot = () => {
        refs.clear();
        let n = 0, skipped = 0;
        const lines = [], list = [];
        const walk = (root, depth) => {
          for (const el of root.children || []) {
            if (hidden(el)) continue;
            const r = role(el);
            let d = depth;
            if (r) {
              let line = '  '.repeat(depth) + '- ' + r;
              const label = name(el);
              if (label) line += ' "' + label.replace(/"/g, '\\"') + '"';
              if (r === 'heading') line += ' [level=' + el.tagName.slice(1) + ']';
              if (el.checked !== undefined && (r === 'checkbox' || r === 'radio')) line += el.checked ? ' [checked]' : '';
              if (el.disabled) line += ' [disabled]';
              if (INTERACTIVE.has(r)) {
                const ref = 'e' + (++n);
                refs.set(ref, new WeakRef(el));
                line += ' [ref=' + ref + ']';
                if (el.value !== undefined && ['textbox', 'searchbox', 'combobox'].includes(r) && el.value) line += ': ' + clean(el.value);
                list.push({ ref, role: r, name: label });
              }
              lines.push(line);
              d = depth + 1;
            }
            if (el.shadowRoot) walk(el.shadowRoot, d);
            if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
              try { walk(el.contentDocument.body, d); } catch (_) { skipped++; }
            } else if (!(r && ['button', 'link', 'heading', 'paragraph', 'label', 'listitem'].includes(r) && !el.querySelector('a,button,input,select,textarea,[role]'))) {
              walk(el, d);
            }
          }
        };
        walk(document.body || document.documentElement, 0);
        return { snapshot: lines.join('\n'), refs: list, skippedFrames: skipped };
      };
      const resolve = (target) => {
        const key = target.replace(/^@/, '').replace(/^ref=/, '');
        if (/^e\d+$/.test(key)) {
          const el = refs.get(key)?.deref();
          if (!el || !el.isConnected) throw new Error('elementNotFound: ref ' + target + ' is stale; take a new snapshot');
          return el;
        }
        const el = document.querySelector(target);
        if (!el) throw new Error('elementNotFound: ' + target);
        return el;
      };
      const center = (el) => {
        el.scrollIntoView({ block: 'center', inline: 'center' });
        const r = el.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
      };
      const mouse = (el, type, x, y, extra) => {
        const Ctor = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        el.dispatchEvent(new Ctor(type, Object.assign({ bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view: window }, extra)));
      };
      const click = (el, count = 1) => {
        const { x, y } = center(el);
        for (let i = 1; i <= count; i++) {
          mouse(el, 'pointerdown', x, y, { detail: i }); mouse(el, 'mousedown', x, y, { detail: i });
          if (el.focus) el.focus();
          mouse(el, 'pointerup', x, y, { detail: i }); mouse(el, 'mouseup', x, y, { detail: i });
          el.click();
        }
        if (count === 2) mouse(el, 'dblclick', x, y, { detail: 2 });
      };
      const hover = (el) => {
        const { x, y } = center(el);
        for (const t of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) mouse(el, t, x, y);
      };
      const setValue = (el, value) => {
        el.focus();
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        if (el.isContentEditable) el.textContent = value;
        else Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      const LOCATORS = {
        role: (v) => [...document.querySelectorAll('*')].find((el) => role(el) === v && visible(el)),
        text: (v) => [...document.querySelectorAll('body *')].reverse().find((el) => visible(el) && clean(el.innerText).includes(v)),
        label: (v) => [...document.querySelectorAll('input,textarea,select,[aria-label]')].find((el) => name(el).includes(v)),
        placeholder: (v) => document.querySelector('[placeholder="' + CSS.escape(v) + '"]'),
        alt: (v) => document.querySelector('[alt="' + CSS.escape(v) + '"]'),
        title: (v) => document.querySelector('[title="' + CSS.escape(v) + '"]'),
        testid: (v) => document.querySelector('[data-testid="' + CSS.escape(v) + '"]'),
      };
      const find = (locator, value) => {
        const f = LOCATORS[locator];
        if (!f) throw new Error('invalidArgument: locator must be one of ' + Object.keys(LOCATORS).join(', '));
        const el = f(value);
        if (!el) throw new Error('elementNotFound: ' + locator + '=' + value);
        return el;
      };
      return { snapshot, resolve, center, mouse, click, hover, setValue, visible, find, name, role };
    })();
    const S = globalThis.__smthz;
    """#
}
