import Foundation
import WebKit

/// Fingerprint protection that stays believable.
///
/// Spoofing too much (a screen or GPU that does not match the browser, values that change on every read, a blank canvas) is itself what risk-control
/// systems look for. So this does the opposite of "stealth":
///  - The page keeps seeing a normal iPhone Safari (WebKit already reports a low-entropy fingerprint).
///  - The few high-entropy read-backs (canvas pixels, audio samples) are nudged by an invisible amount that is **the same on every read, on every visit**
///    for a given site, and different between sites. The seed is a per-device secret, so a site cannot link you to the same device on another site,
///    and your identity on one site does not "change device" from day to day.
///  - Captcha, anti-fraud, login and payment origins are left completely untouched: they must see real values.
///  - Query parameters whose only purpose is tracking (utm_*, fbclid, gclid …) are removed from links you open.
enum FingerprintGuard {
    static let messageName = "lunoxfp"

    /// Origins that must see an unmodified browser (hosts and everything under them).
    static let untouched: [String] = [
        "challenges.cloudflare.com", "cloudflare.com", "hcaptcha.com", "recaptcha.net", "geetest.com", "gt4.geetest.com", "captcha.qq.com", "turing.captcha.qcloud.com",
        "captcha-delivery.com", "datadome.co", "perimeterx.net", "px-cdn.net", "arkoselabs.com", "funcaptcha.com", "imperva.com", "incapsula.com", "akstat.io",
        "sift.com", "threatmetrix.com", "iovation.com", "fingerprint.com", "fpjs.io", "fpcdn.io", "yidun.com", "dun.163.com", "nocaptcha.aliyun.com", "captcha.aliyuncs.com",
        "stripe.com", "stripe.network", "paypal.com", "paypalobjects.com", "adyen.com", "checkout.com", "braintreegateway.com", "alipay.com", "unionpay.com",
        "accounts.google.com", "login.microsoftonline.com", "live.com", "login.live.com", "appleid.apple.com", "idmsa.apple.com",
    ]

    static func secret() -> String {
        let k = Keychain.get("fp-secret")
        if !k.isEmpty { return k }
        let n = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        Keychain.set(n, for: "fp-secret")
        return n
    }
    /// "Clear browsing data" starts a new identity.
    static func rotateSecret() { Keychain.set("", for: "fp-secret") }

    static func userScript(skip: [String]) -> WKUserScript {
        let list = (untouched + skip).map { "\"\($0)\"" }.joined(separator: ",")
        let src = #"""
        (function(){ try {
          var SKIP=[LIST], host=location.hostname.toLowerCase();
          for (var i=0;i<SKIP.length;i++){ if (host===SKIP[i] || host.endsWith('.'+SKIP[i])) return; }
          if (host==='www.google.com' && location.pathname.indexOf('/recaptcha')===0) return;
          var parts=host.split('.'), site=parts.slice(-2).join('.');
          function fnv(s){var h=2166136261;for(var i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619);}return h>>>0;}
          var seed=fnv('SECRET|'+site);
          function rng(n){var x=((seed^n)>>>0)||1;return function(){x^=x<<13;x>>>=0;x^=x>>>17;x^=x<<5;x>>>=0;return x/4294967296;};}
          var natives=new WeakMap(), fts=Function.prototype.toString;
          var ts=function toString(){var n=natives.get(this);return n!==undefined?n:fts.call(this);};
          natives.set(ts,'function toString() { [native code] }');
          Object.defineProperty(Function.prototype,'toString',{value:ts,writable:true,configurable:true});
          function wrap(obj,name,make){
            var o=obj[name]; if(typeof o!=='function') return;
            var w=make(o);
            try{Object.defineProperty(w,'name',{value:name,configurable:true});}catch(e){}
            natives.set(w,'function '+name+'() { [native code] }');
            Object.defineProperty(obj,name,{value:w,writable:true,configurable:true,enumerable:false});
          }
          function report(k){try{window.webkit.messageHandlers['NAME'].postMessage(k);}catch(e){}}
          // Pixel read-backs of canvases the size of a fingerprint probe get 6 colour values nudged by 1: invisible, identical every time for this site.
          function nudge(img){
            var w=img.width,h=img.height; if(w*h<256||w*h>240000) return false;
            var d=img.data, r=rng(w*7919+h);
            for(var i=0;i<6;i++){var p=Math.floor(r()*w*h)*4,c=Math.floor(r()*3),v=d[p+c];d[p+c]=v>0?v-1:v+1;}
            return true;
          }
          var C2=window.CanvasRenderingContext2D&&CanvasRenderingContext2D.prototype, CV=window.HTMLCanvasElement&&HTMLCanvasElement.prototype;
          var origGID=C2&&C2.getImageData;
          if(C2) wrap(C2,'getImageData',function(o){return function getImageData(){var img=o.apply(this,arguments);try{if(nudge(img))report('canvas');}catch(e){}return img;};});
          function copyOf(cv){
            var w=cv.width,h=cv.height; if(w*h<256||w*h>240000) return null;
            var c=document.createElement('canvas'); c.width=w; c.height=h;
            var x=c.getContext('2d'); x.drawImage(cv,0,0);
            var id=origGID.call(x,0,0,w,h); if(!nudge(id)) return null; x.putImageData(id,0,0); return c;
          }
          if(CV&&origGID){
            wrap(CV,'toDataURL',function(o){return function toDataURL(){var c=null;try{c=copyOf(this);}catch(e){} if(c){report('canvas');return o.apply(c,arguments);} return o.apply(this,arguments);};});
            wrap(CV,'toBlob',function(o){return function toBlob(){var c=null;try{c=copyOf(this);}catch(e){} if(c){report('canvas');return o.apply(c,arguments);} return o.apply(this,arguments);};});
          }
          // Audio fingerprints read the rendered samples: nudge a few by ~1e-7 (inaudible), once per buffer.
          var AB=window.AudioBuffer&&AudioBuffer.prototype, done=new WeakSet();
          if(AB) wrap(AB,'getChannelData',function(o){return function getChannelData(ch){
            var a=o.apply(this,arguments);
            try{ if(!done.has(a)&&a.length>2000){done.add(a);var r=rng(a.length+ch);for(var i=0;i<8;i++){a[Math.floor(r()*a.length)]+=(r()-0.5)*2e-7;}report('audio');} }catch(e){}
            return a;};});
        } catch(e) {} })();
        """#
        let s = src.replacingOccurrences(of: "LIST", with: list)
            .replacingOccurrences(of: "SECRET", with: secret())
            .replacingOccurrences(of: "NAME", with: messageName)
        return WKUserScript(source: s, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
}

/// Counts what was normalised on the current page (shown in the site info sheet).
final class FingerprintHandler: NSObject, WKScriptMessageHandler {
    weak var store: BrowserStore?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let wv = m.webView
        Task { @MainActor in self.store?.tabs.first { $0.webView === wv }?.fingerprintHits += 1 }
    }
}

enum TrackingParams {
    private static let exact: Set<String> = ["fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_eid", "mc_cid", "_hsenc", "_hsmi", "igshid", "yclid", "twclid", "ttclid", "srsltid", "wbraid", "gbraid", "vero_id", "oly_enc_id", "oly_anon_id", "_openstat"]
    /// Returns the URL without tracking parameters, or nil when there was nothing to remove.
    static func clean(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { i in
            let n = i.name.lowercased()
            return !(n.hasPrefix("utm_") || exact.contains(n) || (n == "si" && (url.host?.contains("youtu") ?? false)))
        }
        guard kept.count != items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url
    }
}
