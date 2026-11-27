import Foundation
import WebKit

/// Scripts that run in an isolated content world (page scripts cannot see or spoof them).
/// They make web pages behave like native screens: system tint from the page, no tap delay / zoom-on-focus,
/// no scrollbars, cookie-banner removal, plus the text/element snapshot used by AI and automation.
enum NativeAdapter {
    static let world = WKContentWorld.world(name: "luno")

    static func userScript(native: Bool, hideCookies: Bool) -> WKUserScript {
        let src = js
            .replacingOccurrences(of: "__NATIVE__", with: native ? "true" : "false")
            .replacingOccurrences(of: "__COOKIES__", with: hideCookies ? "true" : "false")
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
        'input,textarea,select{font-size:max(16px,1em)}' +
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

      window.__luno = { text: text, snapshot: snapshot, run: run, reader: reader, meta: meta };
    })();
    """#
}
