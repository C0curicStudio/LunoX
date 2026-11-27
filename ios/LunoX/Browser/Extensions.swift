import Foundation
import WebKit

struct UserExtension: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var version = "1.0"
    var desc = ""
    var matches: [String] = ["*://*/*"]
    var excludes: [String] = []
    var runAtStart = false
    var allFrames = false
    var js = ""
    var css = ""
    var enabled = true
    var builtin = false
}

enum ExtensionError: LocalizedError {
    case empty, invalid(String)
    var errorDescription: String? { switch self { case .empty: "内容为空"; case .invalid(let s): s } }
}

/// Extensions are userscripts / userstyles. Chrome (CRX) extensions need Blink and cannot run on iOS WebKit,
/// so LunoX supports the open formats: Greasemonkey `.user.js` and a small JSON manifest.
@MainActor
final class ExtensionManager: ObservableObject {
    private let file = JSONFile<[UserExtension]>("extensions.json")
    @Published var items: [UserExtension] { didSet { file.save(items) } }

    init() {
        var saved = file.load([])
        for b in Self.builtins where !saved.contains(where: { $0.id == b.id }) { saved.append(b) }
        items = saved
    }

    static let builtins: [UserExtension] = [
        UserExtension(id: "builtin.dark", name: "强制深色", version: "1.0", desc: "给任何网页套上深色外观（图片保持原色）。", css: "html{filter:invert(.92) hue-rotate(180deg)!important;background:#fff}img,video,canvas,picture,svg image,[style*='background-image']{filter:invert(1) hue-rotate(180deg)!important}", enabled: false, builtin: true),
        UserExtension(id: "builtin.unlock", name: "解除复制限制", version: "1.0", desc: "允许在禁止选择/复制/右键的网页上选取文字。", runAtStart: false, js: "['copy','cut','contextmenu','selectstart','dragstart'].forEach(function(e){document.addEventListener(e,function(ev){ev.stopImmediatePropagation()},true)});", css: "*{-webkit-user-select:text!important;user-select:text!important}", enabled: false, builtin: true),
        UserExtension(id: "builtin.bigtext", name: "大字号", version: "1.0", desc: "把网页文字放大 115%，阅读更轻松。", css: "html{-webkit-text-size-adjust:115%!important}", enabled: false, builtin: true),
    ]

    // MARK: install

    @discardableResult
    func install(text raw: String) throws -> UserExtension {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtensionError.empty }
        var ext: UserExtension
        if text.hasPrefix("{") {
            guard let d = text.data(using: .utf8), let m = try? JSONDecoder().decode(Manifest.self, from: d) else { throw ExtensionError.invalid("manifest 格式不正确") }
            ext = UserExtension(id: m.id ?? "user.\(m.name.sha256Hex.prefix(10))", name: m.name, version: m.version ?? "1.0", desc: m.description ?? "",
                                matches: m.matches ?? ["*://*/*"], excludes: m.excludes ?? [], runAtStart: m.run_at == "document_start",
                                allFrames: m.all_frames ?? false, js: m.js ?? "", css: m.css ?? "")
        } else {
            ext = Self.parseUserScript(text)
        }
        guard !ext.js.isEmpty || !ext.css.isEmpty else { throw ExtensionError.invalid("没有可执行的脚本或样式") }
        ext.enabled = true; ext.builtin = false
        if let i = items.firstIndex(where: { $0.id == ext.id }) { items[i] = ext } else { items.append(ext) }
        return ext
    }

    private struct Manifest: Decodable {
        var id: String?; var name: String; var version: String?; var description: String?
        var matches: [String]?; var excludes: [String]?; var run_at: String?; var all_frames: Bool?
        var js: String?; var css: String?
    }

    static func parseUserScript(_ text: String) -> UserExtension {
        var name = "未命名脚本", ver = "1.0", desc = "", inc: [String] = [], exc: [String] = [], start = false
        if let s = text.range(of: "==UserScript=="), let e = text.range(of: "==/UserScript==") {
            for line in text[s.upperBound..<e.lowerBound].split(separator: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces)
                guard parts.hasPrefix("@") else { continue }
                let kv = parts.dropFirst().split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let k = kv.first else { continue }
                let v = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
                switch k {
                case "name": name = v
                case "version": ver = v
                case "description": desc = v
                case "match", "include": inc.append(v)
                case "exclude", "exclude-match": exc.append(v)
                case "run-at": start = v == "document-start"
                default: break
                }
            }
        }
        return UserExtension(id: "user.\(name.sha256Hex.prefix(10))", name: name, version: ver, desc: desc,
                             matches: inc.isEmpty ? ["*://*/*"] : inc, excludes: exc, runAtStart: start, js: text)
    }

    func remove(_ e: UserExtension) { items.removeAll { $0.id == e.id && !$0.builtin } }

    // MARK: compile to WKUserScripts

    func userScripts() -> [WKUserScript] {
        items.filter(\.enabled).map { e in
            WKUserScript(source: Self.wrap(e), injectionTime: e.runAtStart ? .atDocumentStart : .atDocumentEnd, forMainFrameOnly: !e.allFrames)
        }
    }

    private static func json(_ v: Any) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed), encoding: .utf8)) ?? "null"
    }

    static func wrap(_ e: UserExtension) -> String {
        #"""
        (function(){try{
          var inc=\#(json(e.matches)), exc=\#(json(e.excludes));
          function m2r(p){
            if(p==='*'||p==='<all_urls>')return /^https?:\/\//;
            if(p.charAt(0)==='/'&&p.lastIndexOf('/')>0){try{return new RegExp(p.slice(1,p.lastIndexOf('/')),'i')}catch(x){}}
            var s=p.replace(/[.+?^${}()|[\]\\]/g,'\\$&').replace(/\*/g,'.*');
            s=s.replace(/^\.\*:\/\//,'https?:\/\/').replace(/^(https?:\/\/)\.\*\\\./,'$1([^/]*\\.)?');
            return new RegExp('^'+s+'$','i');
          }
          function hit(l){return l.some(function(p){try{return m2r(p).test(location.href)}catch(x){return false}})}
          if(!hit(inc)||(exc.length&&hit(exc)))return;
          var css=\#(json(e.css));
          function GM_addStyle(c){var s=document.createElement('style');s.textContent=c;(document.head||document.documentElement).appendChild(s);return s}
          if(css)GM_addStyle(css);
          function GM_getValue(k,d){try{var v=localStorage.getItem('__gm_'+k);return v===null?d:JSON.parse(v)}catch(x){return d}}
          function GM_setValue(k,v){try{localStorage.setItem('__gm_'+k,JSON.stringify(v))}catch(x){}}
          function GM_log(){console.log.apply(console,arguments)}
          var GM_info={script:{name:\#(json(e.name)),version:\#(json(e.version))}};
          \#(e.js)
        }catch(err){console.log('[LunoX extension: '+\#(json(e.name))+']',err)}})();
        """#
    }
}
