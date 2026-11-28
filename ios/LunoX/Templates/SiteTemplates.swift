import SwiftUI

/// Native page templates for well-known sites. A recognised URL is never loaded as a web page: the structured data is
/// requested directly (phone first, your server as the fallback) and rendered with native iOS views.
/// Adding a platform = one case in `SitePlatform`, one route matcher, one parser, one data call.

enum SitePlatform: String, CaseIterable, Codable {
    case youtube, bilibili
    var name: String { self == .youtube ? "YouTube" : "哔哩哔哩" }
    var icon: String { self == .youtube ? "play.rectangle.fill" : "tv.fill" }
    var tint: Color { self == .youtube ? Color(red: 1, green: 0.2, blue: 0.2) : Color(red: 0.98, green: 0.45, blue: 0.62) }
}

enum TemplateKind: Equatable {
    case feed(query: String?)          // home / trending (query == nil) or search results
    case watch(id: String)             // YouTube video id or Bilibili BV id
}

struct TemplateRoute: Equatable {
    let platform: SitePlatform
    let kind: TemplateKind
    let url: URL

    /// nil = not a templated page (it opens as an ordinary web page).
    static func match(_ url: URL) -> TemplateRoute? {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ n: String) -> String? { comps?.queryItems?.first { $0.name == n }?.value }
        let path = url.path

        if host == "youtu.be", path.count > 1 { return .init(platform: .youtube, kind: .watch(id: String(path.dropFirst().prefix(11))), url: url) }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if path == "/watch", let v = q("v"), v.count == 11 { return .init(platform: .youtube, kind: .watch(id: v), url: url) }
            if path.hasPrefix("/shorts/") { return .init(platform: .youtube, kind: .watch(id: String(path.dropFirst(8).prefix(11))), url: url) }
            if path == "/results", let s = q("search_query"), !s.isEmpty { return .init(platform: .youtube, kind: .feed(query: s), url: url) }
            if path == "" || path == "/" || path == "/feed/trending" || path == "/feed/explore" { return .init(platform: .youtube, kind: .feed(query: nil), url: url) }
        }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            if path.hasPrefix("/video/"), let bv = path.split(separator: "/").dropFirst().first, bv.hasPrefix("BV") { return .init(platform: .bilibili, kind: .watch(id: String(bv)), url: url) }
            if host.hasPrefix("search"), let s = q("keyword"), !s.isEmpty { return .init(platform: .bilibili, kind: .feed(query: s), url: url) }
            if host == "www.bilibili.com" || host == "bilibili.com" || host == "m.bilibili.com", path == "" || path == "/" || path == "/v/popular/all" { return .init(platform: .bilibili, kind: .feed(query: nil), url: url) }
        }
        return nil
    }

    static func search(_ platform: SitePlatform, _ q: String) -> TemplateRoute? {
        let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let s = platform == .youtube ? "https://www.youtube.com/results?search_query=\(e)" : "https://search.bilibili.com/all?keyword=\(e)"
        return URL(string: s).flatMap { match($0) }
    }
    static func watch(_ platform: SitePlatform, _ id: String) -> TemplateRoute? {
        let s = platform == .youtube ? "https://www.youtube.com/watch?v=\(id)" : "https://www.bilibili.com/video/\(id)"
        return URL(string: s).flatMap { match($0) }
    }
}

struct TItem: Identifiable, Equatable, Codable {
    var id: String                 // video id / BV id
    var platform: SitePlatform
    var title: String
    var thumb: String?
    var duration: String?
    var author: String
    var avatar: String?
    var meta: String               // "154,460 次观看 · 2 天前"
}

struct TDetail: Equatable, Codable {
    var title: String
    var author: String
    var avatar: String?
    var meta: String
    var desc: String
}

// MARK: - parsing (pure functions, unit-tested)

enum SiteParse {
    static func https(_ s: String?) -> String? {
        guard var s, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s } else if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        return s
    }

    static func ytInitialData(_ html: String) -> Any? {
        for marker in ["var ytInitialData = ", "ytInitialData = ", "window[\"ytInitialData\"] = "] {
            guard let r = html.range(of: marker) else { continue }
            let rest = html[r.upperBound...]
            guard let end = rest.range(of: ";</script>") ?? rest.range(of: ";\n") else { continue }
            if let d = String(rest[..<end.lowerBound]).data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { return j }
        }
        return nil
    }

    static func text(_ o: Any?) -> String {
        guard let d = o as? [String: Any] else { return "" }
        if let s = d["simpleText"] as? String { return s }
        if let runs = d["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return ""
    }

    static func youtubeVideos(_ json: Any?, limit: Int = 40) -> [TItem] {
        var out: [TItem] = []; var seen = Set<String>()
        func walk(_ o: Any) {
            if out.count >= limit { return }
            if let d = o as? [String: Any] {
                for key in ["videoRenderer", "compactVideoRenderer", "gridVideoRenderer"] {
                    if let v = d[key] as? [String: Any], let id = v["videoId"] as? String, seen.insert(id).inserted {
                        let title = text(v["title"])
                        guard !title.isEmpty else { continue }
                        let owner = text(v["ownerText"]).isEmpty ? text(v["longBylineText"]) : text(v["ownerText"])
                        let avatar = (((v["channelThumbnailSupportedRenderers"] as? [String: Any])?["channelThumbnailWithLinkRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])
                            .flatMap { ($0["thumbnails"] as? [[String: Any]])?.first?["url"] as? String }
                        let views = text(v["viewCountText"]), when = text(v["publishedTimeText"])
                        out.append(TItem(id: id, platform: .youtube, title: title, thumb: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                                         duration: text(v["lengthText"]).isEmpty ? nil : text(v["lengthText"]), author: owner, avatar: https(avatar),
                                         meta: [views, when].filter { !$0.isEmpty }.joined(separator: " · ")))
                    }
                }
                for (_, x) in d { walk(x) }
            } else if let a = o as? [Any] { for x in a { walk(x) } }
        }
        if let json { walk(json) }
        return out
    }

    static func count(_ n: Int) -> String { n >= 100_000_000 ? String(format: "%.1f亿", Double(n) / 1e8) : n >= 10_000 ? String(format: "%.1f万", Double(n) / 1e4) : "\(n)" }
    static func clock(_ sec: Int) -> String { sec >= 3600 ? String(format: "%d:%02d:%02d", sec / 3600, sec % 3600 / 60, sec % 60) : String(format: "%d:%02d", sec / 60, sec % 60) }
    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    static func bilibiliList(_ data: Data) -> [TItem] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (j["code"] as? Int) == 0 else { return [] }
        var items: [TItem] = []
        if let arr = j["data"] as? [[String: Any]] {                      // related
            for x in arr { items.append(bili(x)) }
        } else if let d = j["data"] as? [String: Any] {
            if let list = d["list"] as? [[String: Any]] {                  // popular
                for x in list { items.append(bili(x)) }
            } else if let list = d["result"] as? [[String: Any]] {         // search
                for x in list where x["bvid"] != nil {
                    let dur = (x["duration"] as? String) ?? ""
                    items.append(TItem(id: x["bvid"] as? String ?? "", platform: .bilibili, title: stripTags(x["title"] as? String ?? ""), thumb: https(x["pic"] as? String),
                                       duration: dur.isEmpty ? nil : dur, author: x["author"] as? String ?? "", avatar: https(x["upic"] as? String),
                                       meta: "\(count(Int("\(x["play"] ?? 0)") ?? 0))播放 · \(count(Int("\(x["danmaku"] ?? 0)") ?? 0))弹幕"))
                }
            }
        }
        return items.filter { !$0.id.isEmpty && !$0.title.isEmpty }
    }
    private static func bili(_ x: [String: Any]) -> TItem {
        let stat = x["stat"] as? [String: Any]; let owner = x["owner"] as? [String: Any]
        return TItem(id: x["bvid"] as? String ?? "", platform: .bilibili, title: x["title"] as? String ?? "", thumb: https(x["pic"] as? String),
                     duration: (x["duration"] as? Int).map(clock), author: owner?["name"] as? String ?? "", avatar: https(owner?["face"] as? String),
                     meta: "\(count(stat?["view"] as? Int ?? 0))播放 · \(count(stat?["danmaku"] as? Int ?? 0))弹幕")
    }

    static func bilibiliDetail(_ data: Data) -> TDetail? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (j["code"] as? Int) == 0, let d = j["data"] as? [String: Any] else { return nil }
        let stat = d["stat"] as? [String: Any]; let owner = d["owner"] as? [String: Any]
        let meta = "\(count(stat?["view"] as? Int ?? 0))播放 · \(count(stat?["like"] as? Int ?? 0))赞 · \(count(stat?["coin"] as? Int ?? 0))币"
        return TDetail(title: d["title"] as? String ?? "", author: owner?["name"] as? String ?? "", avatar: https(owner?["face"] as? String), meta: meta, desc: d["desc"] as? String ?? "")
    }

    /// Piped (open-source YouTube front end) JSON: trending is an array, search is {items}, streams has relatedStreams.
    static func pipedItems(_ any: Any?) -> [TItem] {
        let arr: [[String: Any]]
        if let a = any as? [[String: Any]] { arr = a } else if let d = any as? [String: Any], let a = (d["items"] ?? d["relatedStreams"]) as? [[String: Any]] { arr = a } else { return [] }
        return arr.compactMap { x in
            guard (x["type"] as? String ?? "stream") == "stream", let u = x["url"] as? String, let r = u.range(of: "v="),
                  let title = x["title"] as? String, !title.isEmpty else { return nil }
            let id = String(u[r.upperBound...].prefix(11))
            let dur = Int("\(x["duration"] ?? -1)") ?? -1
            let views = Int("\(x["views"] ?? 0)") ?? 0
            let when = (x["uploadedDate"] as? String).flatMap { $0 == "None" ? nil : $0 } ?? ""
            return TItem(id: id, platform: .youtube, title: title, thumb: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", duration: dur > 0 ? clock(dur) : nil,
                         author: x["uploaderName"] as? String ?? "", avatar: https(x["uploaderAvatar"] as? String),
                         meta: [views > 0 ? "\(count(views))次观看" : "", when].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }
    static func pipedDetail(_ data: Data) -> (TDetail, [TItem])? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = j["title"] as? String else { return nil }
        let views = Int("\(j["views"] ?? 0)") ?? 0, likes = Int("\(j["likes"] ?? 0)") ?? 0
        let meta = ["\(count(views))次观看", likes > 0 ? "\(count(likes))赞" : "", j["uploadDate"] as? String ?? ""].filter { !$0.isEmpty && $0 != "0次观看" }.joined(separator: " · ")
        return (TDetail(title: t, author: j["uploader"] as? String ?? "", avatar: https(j["uploaderAvatar"] as? String), meta: meta, desc: stripTags(j["description"] as? String ?? "")), pipedItems(j))
    }

    static func youtubeOEmbed(_ data: Data) -> TDetail? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = j["title"] as? String else { return nil }
        return TDetail(title: t, author: j["author_name"] as? String ?? "", avatar: nil, meta: "", desc: "")
    }
}

// MARK: - data

/// Last good answer per page, on disk: opening a templated page paints instantly from here, then refreshes in the background.
struct TemplateCache {
    private static let dir = Paths.dir("Templates", excludeFromBackup: true)
    private struct Box: Codable { var at: Date; var items: [TItem]; var detail: TDetail? }
    private static func file(_ key: String) -> URL { dir.appendingPathComponent(key.sha256Hex + ".json") }
    static func load(_ key: String) -> (items: [TItem], detail: TDetail?, age: TimeInterval)? {
        guard let d = try? Data(contentsOf: file(key)), let b = try? JSONDecoder().decode(Box.self, from: d) else { return nil }
        return (b.items, b.detail, Date().timeIntervalSince(b.at))
    }
    static func save(_ key: String, items: [TItem], detail: TDetail? = nil) {
        guard !items.isEmpty || detail != nil, let d = try? JSONEncoder().encode(Box(at: Date(), items: items, detail: detail)) else { return }
        let u = file(key)
        DispatchQueue.global(qos: .utility).async { try? d.write(to: u, options: .atomic) }
    }
    static func feedKey(_ p: SitePlatform, _ q: String?) -> String { "feed|\(p.rawValue)|\(q ?? "")" }
    static func watchKey(_ p: SitePlatform, _ id: String) -> String { "watch|\(p.rawValue)|\(id)" }
}

@MainActor
final class TemplateService {
    private let engine: NewsEngine
    init(engine: NewsEngine) { self.engine = engine }

    /// After launch: refresh both home feeds and their first thumbnails so the first tap on YouTube / Bilibili is already on screen.
    func warmUp() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for p in SitePlatform.allCases {
                if let c = TemplateCache.load(TemplateCache.feedKey(p, nil)), c.age < 600 { continue }
                guard let items = await self?.feed(p, query: nil) else { continue }
                for it in items.prefix(6) { if let t = it.thumb { _ = await ImageStore.shared.load(t) } }
            }
        }
    }

    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private func get(_ s: String, desktop: Bool = false) async -> Data? {
        guard let u = URL(string: s) else { return nil }
        return await engine.data(u, userAgent: desktop ? desktopUA : nil, headers: ["Cookie": "CONSENT=YES+1; SOCS=CAI", "Referer": "https://www.bilibili.com/"], maxBytes: 4_500_000)
    }
    private func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    /// Open-source Piped instances, tried in order (the first that answers wins; a dead one is skipped for the rest of the session).
    private static let piped = ["https://api.piped.private.coffee", "https://pipedapi.adminforge.de", "https://pipedapi.kavin.rocks"]
    private var deadPiped = Set<String>()
    private func pipedData(_ path: String) async -> Data? {
        for base in Self.piped where !deadPiped.contains(base) {
            if let u = URL(string: base + path), let d = await engine.data(u, maxBytes: 2_000_000), d.first == UInt8(ascii: "{") || d.first == UInt8(ascii: "[") { return d }
            deadPiped.insert(base)
        }
        return nil
    }

    func feed(_ platform: SitePlatform, query: String?) async -> [TItem] {
        var r = await feedDirect(platform, query: query)
        if r.isEmpty, platform == .youtube {
            let path = query.map { "/search?q=\(esc($0))&filter=videos" } ?? "/trending?region=US"
            if let d = await pipedData(path) { r = SiteParse.pipedItems(try? JSONSerialization.jsonObject(with: d)) }
        }
        TemplateCache.save(TemplateCache.feedKey(platform, query), items: r)
        return r
    }

    private func feedDirect(_ platform: SitePlatform, query: String?) async -> [TItem] {
        switch platform {
        case .youtube:
            let u = query.map { "https://www.youtube.com/results?search_query=\(esc($0))" } ?? "https://www.youtube.com/feed/trending"
            guard let d = await get(u, desktop: true), let html = String(data: d, encoding: .utf8) else { return [] }
            var items = await Task.detached { SiteParse.youtubeVideos(SiteParse.ytInitialData(html)) }.value
            if items.isEmpty, query == nil, let d2 = await get("https://www.youtube.com/", desktop: true), let h2 = String(data: d2, encoding: .utf8) {
                items = await Task.detached { SiteParse.youtubeVideos(SiteParse.ytInitialData(h2)) }.value
            }
            return items
        case .bilibili:
            let u = query.map { "https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=\(esc($0))" } ?? "https://api.bilibili.com/x/web-interface/popular?ps=30"
            guard let d = await get(u) else { return [] }
            return await Task.detached { SiteParse.bilibiliList(d) }.value
        }
    }

    /// Details plus (when the source has them) related videos.
    func detail(_ platform: SitePlatform, id: String) async -> (TDetail, [TItem])? {
        switch platform {
        case .youtube:
            if let d = await get("https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(id)&format=json"), let t = SiteParse.youtubeOEmbed(d) { return (t, []) }
            if let d = await pipedData("/streams/\(id)"), let r = SiteParse.pipedDetail(d) { return r }
            return nil
        case .bilibili:
            guard let d = await get("https://api.bilibili.com/x/web-interface/view?bvid=\(id)"), let t = SiteParse.bilibiliDetail(d) else { return nil }
            return (t, [])
        }
    }

    func related(_ platform: SitePlatform, id: String, title: String) async -> [TItem] {
        switch platform {
        case .youtube:
            if let d = await pipedData("/streams/\(id)"), let r = SiteParse.pipedDetail(d), !r.1.isEmpty { return r.1 }
            return await feed(.youtube, query: title).filter { $0.id != id }
        case .bilibili:
            guard let d = await get("https://api.bilibili.com/x/web-interface/archive/related?bvid=\(id)") else { return [] }
            return await Task.detached { SiteParse.bilibiliList(d) }.value
        }
    }
}
