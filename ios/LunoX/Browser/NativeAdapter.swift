import Foundation
import WebKit

/// Scripts that run in an isolated content world (page scripts cannot see or spoof them).
/// They make web pages behave like native screens: system tint from the page, no tap delay / zoom-on-focus,
/// no scrollbars, cookie-banner removal, plus the text/element snapshot used by AI and automation.
enum NativeAdapter {
    static let world = WKContentWorld.world(name: "luno")

    static func userScript(native: Bool, hideCookies: Bool, autoDark: Bool, accent: String) -> WKUserScript {
        let src = js
            .replacingOccurrences(of: "__NATIVE__", with: native ? "true" : "false")
            .replacingOccurrences(of: "__COOKIES__", with: hideCookies ? "true" : "false")
            .replacingOccurrences(of: "__AUTODARK__", with: autoDark ? "true" : "false")
            .replacingOccurrences(of: "__ACCENT__", with: accent)
        return WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    private static let js = #"""
    (function () {
      if (window.__luno) return;
      var OPT = { native: __NATIVE__, cookies: __COOKIES__ };
      function post(m) { try { window.webkit.messageHandlers.luno.postMessage(m); } catch (e) {} }

      var css = '';
      if (OPT.native) css +=
        'html{-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent}' +
        'a,button,[role=button],input,select,textarea,label,summary{touch-action:manipulation}' +
        'button,[role=button],summary{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}' +
        '[data-luno-fb]{bottom:calc(var(--luno-orig,0px) + var(--luno-inset,0px))!important;transition:bottom .25s ease}' +
        '::-webkit-scrollbar{display:none}';
      if (OPT.cookies) css +=
        '#onetrust-consent-sdk,#onetrust-banner-sdk,#CybotCookiebotDialog,#cookie-banner,.cookie-banner,.cookie-consent,' +
        '.cc-window,#cookiescript_injected,.fc-consent-root,.qc-cmp2-container,#truste-consent-track,[id*="cookie-consent"],' +
        '[class*="cookie-notice"],[id*="cookieNotice"]{display:none!important}';
      if (css) {
        var st = document.createElement('style'); st.id = '__luno_css'; st.textContent = css;
        (document.head || document.documentElement).appendChild(st);
      }

      function meta() {
        var q = function (s) { return document.querySelector(s); };
        var tc = q('meta[name="theme-color"]');
        var ic = q('link[rel~="apple-touch-icon"]') || q('link[rel~="icon"]') || q('link[rel="shortcut icon"]');
        var bg = '';
        try { bg = getComputedStyle(document.body || document.documentElement).backgroundColor; } catch (e) {}
        post({ type: 'meta', title: document.title || '', themeColor: tc ? tc.content : null, bg: bg, icon: ic ? ic.href : null });
      }
      var t; function later() { clearTimeout(t); t = setTimeout(meta, 400); }
      document.addEventListener('DOMContentLoaded', function () {
        meta();
        try { new MutationObserver(later).observe(document.head, { childList: true, subtree: true, attributes: true }); } catch (e) {}
      });
      window.addEventListener('load', meta);

      function text() {
        var s = (document.body && document.body.innerText) || '';
        return s.replace(/\n{3,}/g, '\n\n');
      }
      function visible(el) {
        var r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) return false;
        var cs = getComputedStyle(el);
        if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') return false;
        return r.bottom > 0 && r.top < innerHeight * 3;
      }
      var map = {};
      var SENS = /pay|buy|purchase|checkout|delete|remove|confirm order|支付|购买|付款|删除|转账|提交订单|确认订单/i;

      function snapshot() {
        var els = Array.prototype.slice.call(document.querySelectorAll(
          'a[href],button,input,select,textarea,[role=button],[role=link],[onclick],summary')).filter(visible).slice(0, 80);
        map = {}; var lines = [], sens = [];
        els.forEach(function (el, i) {
          var id = i + 1; map[id] = el;
          var tag = el.tagName.toLowerCase(), type = el.type || '';
          var label = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.alt || '')
            .toString().trim().replace(/\s+/g, ' ').slice(0, 60);
          var s = type === 'password' || SENS.test(label + ' ' + (el.name || '') + ' ' + (el.id || ''));
          if (s) sens.push(id);
          lines.push('[' + id + '] ' + tag + (type ? '(' + type + ')' : '') + ' "' + label + '"' +
            (el.href ? ' -> ' + String(el.href).slice(0, 80) : '') + (s ? ' !SENSITIVE' : ''));
        });
        return { text: text().slice(0, 6000) + '\n\nELEMENTS:\n' + lines.join('\n'), sensitive: sens, title: document.title, url: location.href };
      }
      function setValue(el, v) {
        var proto = Object.getPrototypeOf(el);
        var d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) d.set.call(el, v); else el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      function run(a) {
        var el = a.id ? map[a.id] : null;
        if (['click', 'type', 'extract'].indexOf(a.type) >= 0 && !el) return 'error: unknown element';
        switch (a.type) {
          case 'click': el.scrollIntoView({ block: 'center' }); el.click(); return 'clicked ' + a.id;
          case 'type':
            if (el.type === 'password') return 'refused: password field';
            el.focus(); setValue(el, a.text || '');
            if (a.submit) { if (el.form && el.form.requestSubmit) el.form.requestSubmit(); else el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); }
            return 'typed into ' + a.id;
          case 'scroll': window.scrollBy({ top: a.dy || 400, behavior: 'smooth' }); return 'scrolled';
          case 'extract': return String(el.innerText || el.value || '').slice(0, 2000);
          default: return 'noop';
        }
      }

      function reader() {
        var cands = Array.prototype.slice.call(document.querySelectorAll('article,main,[role=main],#content,.post,.article,.entry-content,body'));
        var best = null, bestLen = 0;
        cands.forEach(function (c) {
          var n = 0; c.querySelectorAll('p').forEach(function (p) { n += p.innerText.length; });
          if (n > bestLen) { best = c; bestLen = n; }
        });
        if (!best || bestLen < 200) return null;
        var ALLOW = { P:1,H1:1,H2:1,H3:1,H4:1,UL:1,OL:1,LI:1,BLOCKQUOTE:1,PRE:1,CODE:1,EM:1,STRONG:1,B:1,I:1,A:1,IMG:1,FIGURE:1,FIGCAPTION:1,BR:1,TABLE:1,TR:1,TD:1,TH:1,THEAD:1,TBODY:1 };
        function clean(node, out) {
          node.childNodes.forEach(function (n) {
            if (n.nodeType === 3) { out.appendChild(document.createTextNode(n.textContent)); return; }
            if (n.nodeType !== 1) return;
            if (!ALLOW[n.tagName]) { clean(n, out); return; }
            if (/^(NAV|ASIDE|FORM|SCRIPT|STYLE)$/.test(n.tagName)) return;
            var e = document.createElement(n.tagName.toLowerCase());
            if (n.tagName === 'A' && /^https?:/i.test(n.href)) e.setAttribute('href', n.href);
            if (n.tagName === 'IMG') { var s = n.currentSrc || n.src; if (!/^https?:/i.test(s)) return; e.setAttribute('src', s); e.setAttribute('alt', n.alt || ''); }
            clean(n, e); out.appendChild(e);
          });
        }
        var box = document.createElement('div'); clean(best, box);
        return { title: document.title, html: box.innerHTML };
      }

      // ---------- adaptive layer: runs once, when the browser is idle (kept tiny so pages stay fast) ----------
      var state = { dark: __AUTODARK__, light: false, readable: false, fixed: 0, desktop: false };
      function idle(f) { (window.requestIdleCallback || function (g) { setTimeout(g, 200); })(f, { timeout: 1500 }); }
      function addMeta(n, c) { var m = document.createElement('meta'); m.name = n; m.content = c; (document.head || document.documentElement).appendChild(m); return m; }

      // ---------- native-app behaviour: the page can not be zoomed; we fit it to the phone ourselves ----------
      function deviceWidth() {
        var o = Math.abs(window.orientation || 0) === 90;
        return o ? Math.max(screen.width, screen.height) : Math.min(screen.width, screen.height);
      }
      var lockState = { content: '' };
      // Rewrites the viewport so user zoom is impossible; `opt.width`/`opt.scale` force a fit for desktop-only layouts.
      function lockViewport(opt) {
        opt = opt || {};
        var vp = document.querySelector('meta[name=viewport]');
        var base = vp ? vp.content : 'width=device-width';
        var parts = base.split(',').map(function (s) { return s.trim(); }).filter(function (p) {
          return p && !/^(initial-scale|minimum-scale|maximum-scale|user-scalable|viewport-fit)\s*=/i.test(p);
        });
        var wm = /(?:^|,)\s*width\s*=\s*([\d.]+)/i.exec(base);
        var im = /initial-scale\s*=\s*([\d.]+)/i.exec(base);
        var scale = 1;
        if (opt.scale) { scale = opt.scale; parts = parts.filter(function (p) { return !/^width\s*=/i.test(p); }); parts.unshift('width=' + opt.width); }
        else if (wm) { scale = im ? parseFloat(im[1]) : deviceWidth() / parseFloat(wm[1]); }   // fixed-width viewport: scale it to fit
        else if (!parts.some(function (p) { return /^width\s*=/i.test(p); })) parts.unshift('width=device-width');
        scale = Math.max(0.25, Math.min(scale, 1));
        var s = scale.toFixed(4);
        parts.push('initial-scale=' + s, 'minimum-scale=' + s, 'maximum-scale=' + s, 'user-scalable=no');
        var content = parts.join(', ');
        lockState.content = content;
        if (!vp) vp = addMeta('viewport', content); else if (vp.content !== content) vp.content = content;
        return vp;
      }
      function fitViewport() {
        if (!OPT.native) return;
        lockViewport();
        requestAnimationFrame(function () { requestAnimationFrame(function () {
          var de = document.documentElement, dw = deviceWidth();
          var over = de.scrollWidth - innerWidth;
          // still wider than the phone (desktop-only layout): shrink the whole page so it fits exactly
          if (over > innerWidth * 0.08 && de.scrollWidth > dw) {
            var w = Math.min(de.scrollWidth, 2600);
            lockViewport({ width: w, scale: dw / w });
            state.desktop = true;
          }
        }); });
      }
      // pages that (re)write their viewport later must not get zoom back
      function guardViewport() {
        try {
          new MutationObserver(function () {
            var vp = document.querySelector('meta[name=viewport]');
            if (OPT.native && (!vp || vp.content !== lockState.content)) lockViewport();
          }).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['content', 'name'] });
        } catch (e) {}
      }

      // page-owned bars glued to the bottom edge would hide behind our floating toolbar: lift them by the toolbar height
      function scanFixed() {
        if (!document.body) return 0;
        var level = [].slice.call(document.body.children), n = 0, hit = 0;
        for (var d = 0; d < 3 && level.length && n < 400; d++) {
          var next = [];
          level.forEach(function (el) {
            if (n++ > 400 || el.nodeType !== 1) return;
            var cs = getComputedStyle(el);
            if (cs.position === 'fixed') {
              var r = el.getBoundingClientRect();
              if (r.width > 40 && r.top > innerHeight * 0.4 && r.bottom >= innerHeight - 4) {
                el.setAttribute('data-luno-fb', ''); el.style.setProperty('--luno-orig', (parseFloat(cs.bottom) || 0) + 'px'); hit++;
              }
            }
            if (d < 2 && el.children.length) next.push.apply(next, el.children);
          });
          level = next;
        }
        return hit;
      }
      function setInset(px) { document.documentElement.style.setProperty('--luno-inset', px + 'px'); }

      // light pages in dark mode: invert them (media keeps its colours); pages with real dark support are left alone
      function bgLum() {
        function parse(c) { var m = c.match(/[\d.]+/g); return m && m.length >= 3 ? { r: +m[0], g: +m[1], b: +m[2], a: m.length > 3 ? +m[3] : 1 } : null; }
        var b = document.body && parse(getComputedStyle(document.body).backgroundColor), h = parse(getComputedStyle(document.documentElement).backgroundColor);
        var c = (b && b.a > 0.05) ? b : ((h && h.a > 0.05) ? h : { r: 255, g: 255, b: 255 });
        return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255;
      }
      function applyDark() {
        var want = state.dark && state.light && !document.querySelector('meta[name=color-scheme]');
        var el = document.getElementById('__luno_dark');
        if (want && !el) {
          el = document.createElement('style'); el.id = '__luno_dark';
          el.textContent = 'html{filter:invert(.93) hue-rotate(180deg)!important;background:#fff}img,picture,video,canvas,svg,iframe,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}';
          (document.head || document.documentElement).appendChild(el);
        } else if (!want && el) el.remove();
      }
      function setDark(b) { state.dark = !!b; applyDark(); }
      function setAccent(h) {
        var el = document.getElementById('__luno_accent');
        if (!el) { el = document.createElement('style'); el.id = '__luno_accent'; (document.head || document.documentElement).appendChild(el); }
        el.textContent = ':root{accent-color:' + h + '}';
      }
      function readable() {
        var c = document.querySelector('article,main,[role=main]') || document.body; if (!c) return false;
        var n = 0, ps = c.querySelectorAll('p'); for (var i = 0; i < ps.length && n < 700; i++) n += ps[i].innerText.length;
        return n >= 600;
      }
      function adapt() {
        state.light = bgLum() > 0.72; applyDark();
        state.fixed = scanFixed(); state.readable = readable();
        var sample = ((document.body && document.body.innerText) || '').replace(/\s+/g, ' ').slice(0, 1500);
        post({ type: 'page', readable: state.readable, fixedBottom: state.fixed, desktop: state.desktop, light: state.light,
               lang: (document.documentElement.lang || '').toLowerCase(), sample: sample });
      }
      if (OPT.native) setAccent('__ACCENT__');
      document.addEventListener('DOMContentLoaded', function () { fitViewport(); guardViewport(); });
      window.addEventListener('load', function () { idle(function () { setTimeout(adapt, 250); }); });

      // ---------- in-place translation (text nodes only; originals are kept so the page can be restored) ----------
      var tr = { nodes: {}, orig: {}, next: 1, on: false, observer: null, timer: null };
      var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|CODE|PRE|TEXTAREA|INPUT|SELECT|SVG|CANVAS|KBD|SAMP)$/;
      function translateCollect() {
        var ids = [], texts = [], chars = 0;
        if (!document.body) return { ids: ids, texts: texts };
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var n;
        while ((n = w.nextNode()) && ids.length < 900 && chars < 40000) {
          var p = n.parentElement; if (!p || SKIP.test(p.tagName) || p.isContentEditable) continue;
          var t = n.nodeValue; if (!t || t.trim().length < 2 || !/\p{L}/u.test(t)) continue;
          if (n.__lunoDone && n.__lunoDone === t) continue;           // already translated by us
          var id = n.__lunoId || (n.__lunoId = tr.next++);
          tr.nodes[id] = n; if (!(id in tr.orig)) tr.orig[id] = t;
          ids.push(id); texts.push(t.trim()); chars += t.length;
        }
        return { ids: ids, texts: texts };
      }
      function translateApply(ids, texts) {
        for (var i = 0; i < ids.length; i++) {
          var n = tr.nodes[ids[i]]; if (!n || !texts[i]) continue;
          var o = n.nodeValue, lead = (o.match(/^\s*/) || [''])[0], trail = (o.match(/\s*$/) || [''])[0];
          n.nodeValue = lead + texts[i] + trail; n.__lunoDone = n.nodeValue;
        }
        tr.on = true; watchMore();
      }
      function translateRestore() {
        for (var id in tr.nodes) { var n = tr.nodes[id]; if (n && tr.orig[id] !== undefined) { n.nodeValue = tr.orig[id]; n.__lunoDone = null; } }
        tr.on = false; if (tr.observer) { tr.observer.disconnect(); tr.observer = null; }
      }
      function watchMore() {                                          // content added later (infinite scroll, SPA) gets translated too
        if (tr.observer || !document.body) return;
        tr.observer = new MutationObserver(function () {
          if (!tr.on) return; clearTimeout(tr.timer);
          tr.timer = setTimeout(function () { post({ type: 'dom-more' }); }, 900);
        });
        tr.observer.observe(document.body, { childList: true, subtree: true });
      }

      window.__luno = { translateCollect: translateCollect, translateApply: translateApply, translateRestore: translateRestore, text: text, snapshot: snapshot, run: run, reader: reader, meta: meta, setInset: setInset, setDark: setDark, setAccent: setAccent, adapt: adapt };
    })();
    """#
}
