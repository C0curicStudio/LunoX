import Foundation
import CryptoKit

/// On-device news fetching. Every source is requested directly from the phone first; if it is slow/blocked the request
/// is relayed through your server (GET /v1/fetch) and parsed here. The server's own aggregator is only the last fallback.
struct NewsSource {
    enum Kind { case rss, hn, spaceflight, github, wiki, apod }
    let name: String
    let url: String
    let kind: Kind
}

enum NewsCatalog {
    private static func yt(_ id: String) -> String { "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)" }
    private static func day(_ offset: Int = 0) -> (String, String, String) {
        let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: Date())!
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        return (String(format: "%04d", c.year ?? 2026), String(format: "%02d", c.month ?? 1), String(format: "%02d", c.day ?? 1))
    }
    private static func githubQuery() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let since = f.string(from: Date().addingTimeInterval(-14 * 86400))
        return "https://api.github.com/search/repositories?q=stars:%3E300+created:%3E\(since)&sort=stars&order=desc&per_page=24"
    }

    static func sources(_ s: NewsSection) -> [NewsSource] {
        let (y, m, d) = day()
        switch s {
        case .world: return [.init(name: "BBC News", url: "https://feeds.bbci.co.uk/news/world/rss.xml", kind: .rss), .init(name: "The Guardian", url: "https://www.theguardian.com/world/rss", kind: .rss),
                             .init(name: "NPR", url: "https://feeds.npr.org/1001/rss.xml", kind: .rss), .init(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", kind: .rss),
                             .init(name: "维基百科 · 新闻", url: "https://en.wikipedia.org/api/rest_v1/feed/featured/\(y)/\(m)/\(d)", kind: .wiki)]
        case .china: return [.init(name: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", kind: .rss), .init(name: "中新网", url: "https://www.chinanews.com.cn/rss/scroll-news.xml", kind: .rss),
                             .init(name: "少数派", url: "https://sspai.com/feed", kind: .rss), .init(name: "FT 中文网", url: "https://www.ftchinese.com/rss/news", kind: .rss)]
        case .tech: return [.init(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", kind: .rss), .init(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", kind: .rss),
                            .init(name: "TechCrunch", url: "https://techcrunch.com/feed/", kind: .rss), .init(name: "36氪", url: "https://36kr.com/feed", kind: .rss),
                            .init(name: "Hacker News", url: "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=25", kind: .hn)]
        case .opensource: return [.init(name: "GitHub 热门新项目", url: githubQuery(), kind: .github), .init(name: "GitHub Blog", url: "https://github.blog/feed/", kind: .rss),
                                  .init(name: "Hacker News · Show", url: "https://hn.algolia.com/api/v1/search?tags=show_hn&hitsPerPage=20", kind: .hn), .init(name: "阮一峰", url: "https://www.ruanyifeng.com/blog/atom.xml", kind: .rss)]
        case .finance: return [.init(name: "BBC Business", url: "https://feeds.bbci.co.uk/news/business/rss.xml", kind: .rss), .init(name: "CNBC", url: "https://www.cnbc.com/id/100003114/device/rss/rss.html", kind: .rss),
                               .init(name: "Guardian Business", url: "https://www.theguardian.com/uk/business/rss", kind: .rss)]
        case .sports: return [.init(name: "BBC Sport", url: "https://feeds.bbci.co.uk/sport/rss.xml", kind: .rss), .init(name: "ESPN", url: "https://www.espn.com/espn/rss/news", kind: .rss),
                              .init(name: "Guardian Sport", url: "https://www.theguardian.com/sport/rss", kind: .rss)]
        case .entertainment: return [.init(name: "BBC Entertainment", url: "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml", kind: .rss), .init(name: "Variety", url: "https://variety.com/feed/", kind: .rss),
                                     .init(name: "Guardian Film", url: "https://www.theguardian.com/film/rss", kind: .rss)]
        case .science: return [.init(name: "Spaceflight News", url: "https://api.spaceflightnewsapi.net/v4/articles/?limit=20", kind: .spaceflight), .init(name: "NASA 每日天文图", url: "https://api.nasa.gov/planetary/apod?api_key=DEMO_KEY", kind: .apod),
                               .init(name: "NASA", url: "https://www.nasa.gov/feed/", kind: .rss), .init(name: "BBC Science", url: "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml", kind: .rss), .init(name: "Nature", url: "https://www.nature.com/nature.rss", kind: .rss)]
        case .french: return [.init(name: "Le Monde", url: "https://www.lemonde.fr/rss/une.xml", kind: .rss), .init(name: "France 24", url: "https://www.france24.com/fr/rss", kind: .rss), .init(name: "RFI", url: "https://www.rfi.fr/fr/rss", kind: .rss)]
        case .video: return [("BBC News", "UC16niRr50-MSBwiO3YDb3RA"), ("Reuters", "UChqUTb7kYRX8-EiaN3XFrSQ"), ("NASA", "UCLA_DiR1FfKNvjuUpBHmylQ"), ("DW News", "UCknLrEdhRCp1aegoMqRaCZg"),
                             ("Al Jazeera", "UCNye-wNBqNL5ZzHSJj3l8Bg"), ("CNN", "UCupvZG-5ko_eiXAupbDfxWw"), ("Bloomberg", "UCIALMKvObZNtJ6AmdCLP7Lg")].map { NewsSource(name: $0.0, url: yt($0.1), kind: .rss) }
        case .explore, .trends: return []
        }
    }
    /// "Explore" mixes the best of several sections.
    static let exploreMix: [NewsSection] = [.video, .world, .tech, .opensource, .entertainment, .sports, .science]
}

// MARK: - parsing (nonisolated, runs off the main thread)

enum NewsParse {
    final class Feed: NSObject, XMLParserDelegate {
        struct Raw { var title = "", link = "", desc = "", date = "", image = "", imgW = -1, videoId = "", extra: [String: String] = [:] }
        private(set) var items: [Raw] = []
        private var cur: Raw?
        private var text = ""
        func parse(_ data: Data) -> [Raw] { let p = XMLParser(data: data); p.delegate = self; p.shouldProcessNamespaces = false; p.parse(); return items }

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""
            if name == "item" || name == "entry" { cur = Raw(); return }
            guard cur != nil else { return }
            switch name {
            case "media:thumbnail", "media:content":
                guard let u = a["url"], u.hasPrefix("http") else { return }
                let isImage = name == "media:thumbnail" || a["medium"] == "image" || (a["type"] ?? "").hasPrefix("image") || (a["type"] == nil && a["medium"] == nil && u.range(of: #"\.(jpe?g|png|webp)(\?|$)"#, options: .regularExpression) != nil)
                let w = Int(a["width"] ?? "") ?? 0
                if isImage, w >= (cur?.imgW ?? -1) { cur?.image = u; cur?.imgW = w }
            case "enclosure":
                if let u = a["url"], (a["type"] ?? "").hasPrefix("image"), cur?.image.isEmpty == true { cur?.image = u }
            case "link":
                if let h = a["href"], (a["rel"] ?? "alternate") == "alternate", cur?.link.isEmpty == true { cur?.link = h }
            case "ht:picture", "ht:news_item_title", "ht:news_item_url", "ht:approx_traffic": break
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard cur != nil else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": if cur!.title.isEmpty { cur!.title = t }
            case "link": if cur!.link.isEmpty, t.hasPrefix("http") { cur!.link = t }
            case "guid": if cur!.link.isEmpty, t.hasPrefix("http") { cur!.link = t }
            case "description", "summary", "content", "content:encoded": if cur!.desc.count < t.count { cur!.desc = t }
            case "pubDate", "published", "updated", "dc:date": if cur!.date.isEmpty { cur!.date = t }
            case "yt:videoId": cur!.videoId = t
            case "ht:picture", "ht:approx_traffic", "ht:news_item_title", "ht:news_item_url": if cur!.extra[name] == nil { cur!.extra[name] = t }
            case "item", "entry": items.append(cur!); cur = nil
            default: break
            }
            text = ""
        }
    }

    private static let dateFormats: [String] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
    static func date(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in dateFormats { f.dateFormat = fmt; if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 } }
        return 0
    }
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func firstImage(in html: String) -> String? {
        guard let r = html.range(of: #"<img[^>]+src=["']([^"']+)["']"#, options: .regularExpression) else { return nil }
        let tag = String(html[r])
        guard let s = tag.range(of: #"src=["']"#, options: .regularExpression) else { return nil }
        let rest = tag[s.upperBound...]
        return rest.firstIndex(where: { $0 == "\"" || $0 == "'" }).map { String(rest[..<$0]) }.flatMap { $0.hasPrefix("http") ? $0 : nil }
    }
    static func id(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }

    static func rss(_ data: Data, source: String) -> [Article] {
        Feed().parse(data).prefix(30).compactMap { r in
            guard !r.title.isEmpty, !r.link.isEmpty else { return nil }
            let decoded = plain(r.title)
            var image: String? = r.image.isEmpty ? firstImage(in: r.desc) : r.image
            image = image?.replacingOccurrences(of: #"(ichef\.bbci\.co\.uk/[^/]+/)(?:ace/)?(?:standard/)?\d+/"#, with: "$1976/", options: .regularExpression)
            var video: NewsVideo?
            if r.videoId.count == 11 { video = NewsVideo(kind: "youtube", id: r.videoId, url: nil); image = "https://i.ytimg.com/vi/\(r.videoId)/hqdefault.jpg" }
            return Article(id: id(r.link), title: decoded, summary: String(plain(r.desc).prefix(200)), url: r.link, source: source, ts: date(r.date), image: image, video: video, cat: nil)
        }
    }
    static func hn(_ data: Data, source: String) -> [Article] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hits = j["hits"] as? [[String: Any]] else { return [] }
        return hits.compactMap { h in
            guard let t = h["title"] as? String, let oid = h["objectID"] as? String else { return nil }
            let url = (h["url"] as? String) ?? "https://news.ycombinator.com/item?id=\(oid)"
            let pts = h["points"] as? Int ?? 0, by = h["author"] as? String ?? ""
            return Article(id: id(url), title: t, summary: "▲ \(pts) · \(by)", url: url, source: source, ts: Double(h["created_at_i"] as? Int ?? 0) * 1000, image: nil, video: nil, cat: nil)
        }
    }
    static func spaceflight(_ data: Data, source: String) -> [Article] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rs = j["results"] as? [[String: Any]] else { return [] }
        return rs.compactMap { r in
            guard let t = r["title"] as? String, let u = r["url"] as? String else { return nil }
            return Article(id: id(u), title: t, summary: (r["summary"] as? String) ?? "", url: u, source: (r["news_site"] as? String) ?? source, ts: date((r["published_at"] as? String) ?? ""), image: r["image_url"] as? String, video: nil, cat: nil)
        }
    }
    static func github(_ data: Data, source: String) -> [Article] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rs = j["items"] as? [[String: Any]] else { return [] }
        return rs.compactMap { r in
            guard let name = r["full_name"] as? String, let u = r["html_url"] as? String else { return nil }
            let stars = r["stargazers_count"] as? Int ?? 0, lang = (r["language"] as? String).map { " · \($0)" } ?? ""
            return Article(id: id(u), title: name, summary: "★ \(stars)\(lang) — \((r["description"] as? String) ?? "")", url: u, source: source, ts: date((r["pushed_at"] as? String) ?? ""),
                           image: "https://opengraph.githubassets.com/1/\(name)", video: nil, cat: nil)
        }
    }
    static func wiki(_ data: Data, source: String) -> [Article] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Article] = []
        for n in (j["news"] as? [[String: Any]] ?? []) {
            let links = n["links"] as? [[String: Any]] ?? []
            guard let story = n["story"] as? String else { continue }
            let first = links.first(where: { ($0["thumbnail"] as? [String: Any]) != nil }) ?? links.first
            let page = (((first?["content_urls"] as? [String: Any])?["mobile"] as? [String: Any])?["page"] as? String) ?? "https://en.wikipedia.org"
            out.append(Article(id: id(story), title: plain(story), summary: (first?["extract"] as? String).map { String($0.prefix(180)) } ?? "", url: page, source: source,
                               ts: Date().timeIntervalSince1970 * 1000, image: (first?["thumbnail"] as? [String: Any])?["source"] as? String, video: nil, cat: nil))
        }
        if let t = j["tfa"] as? [String: Any], let title = t["normalizedtitle"] as? String {
            let page = (((t["content_urls"] as? [String: Any])?["mobile"] as? [String: Any])?["page"] as? String) ?? "https://en.wikipedia.org"
            out.append(Article(id: id(page), title: title, summary: String(((t["extract"] as? String) ?? "").prefix(200)), url: page, source: "维基百科 · 今日条目",
                               ts: Date().timeIntervalSince1970 * 1000 - 1, image: ((t["originalimage"] as? [String: Any]) ?? (t["thumbnail"] as? [String: Any]))?["source"] as? String, video: nil, cat: nil))
        }
        return out
    }
    static func apod(_ data: Data, source: String) -> [Article] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = j["title"] as? String else { return [] }
        var image = (j["hdurl"] as? String) ?? (j["url"] as? String)
        var video: NewsVideo?
        if (j["media_type"] as? String) == "video", let u = j["url"] as? String, let r = u.range(of: #"embed/([\w-]{11})"#, options: .regularExpression) {
            let vid = String(u[r]).replacingOccurrences(of: "embed/", with: ""); video = NewsVideo(kind: "youtube", id: vid, url: nil); image = "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg"
        }
        return [Article(id: id("apod\(j["date"] ?? "")"), title: t, summary: String(((j["explanation"] as? String) ?? "").prefix(200)), url: "https://apod.nasa.gov/apod/astropix.html", source: source,
                        ts: date((j["date"] as? String) ?? ""), image: image, video: video, cat: nil)]
    }

    static func articles(kind: NewsSource.Kind, data: Data, source: String) -> [Article] {
        switch kind { case .rss: rss(data, source: source); case .hn: hn(data, source: source); case .spaceflight: spaceflight(data, source: source)
                      case .github: github(data, source: source); case .wiki: wiki(data, source: source); case .apod: apod(data, source: source) }
    }

    static func merge(_ parts: [[Article]], cap: Int = 48) -> [Article] {
        var seen = Set<String>(), out: [Article] = []
        let all: [Article] = parts.flatMap { $0 }
        let sorted: [Article] = all.sorted { (x: Article, y: Article) -> Bool in
            let tx: Double = x.ts == 0 ? -1 : Double(x.ts)
            let ty: Double = y.ts == 0 ? -1 : Double(y.ts)
            return tx > ty
        }
        for a in sorted {
            let letters: String = a.title.lowercased().filter { $0.isLetter || $0.isNumber }
            let k = String(letters.prefix(60))
            if seen.insert(k).inserted { out.append(a) }
        }
        return Array(out.prefix(cap))
    }

    static func ogImage(in html: String) -> String? {
        for pat in [#"<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]*content=["']([^"']+)["']"#, #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["']"#] {
            guard let r = html.range(of: pat, options: [.regularExpression, .caseInsensitive]) else { continue }
            let tag = String(html[r])
            guard let c = tag.range(of: #"content=["']"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let rest = tag[c.upperBound...]
            if let end = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
                let u = String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&")
                if u.hasPrefix("http") { return u }
            }
        }
        return nil
    }
}

// MARK: - network: direct from the phone, relayed through the server when needed

@MainActor
final class NewsEngine {
    private let gateway: GatewayClient
    private let router: Router
    private let settings: Settings
    init(gateway: GatewayClient, router: Router, settings: Settings) { self.gateway = gateway; self.router = router; self.settings = settings }

    private nonisolated static func direct(_ url: URL, timeout: TimeInterval = 7, userAgent: String? = nil, headers: [String: String] = [:]) async -> Data? {
        let c = URLSessionConfiguration.ephemeral; c.connectionProxyDictionary = [:]; c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout + 2; c.waitsForConnectivity = false
        let s = URLSession(configuration: c); defer { s.finishTasksAndInvalidate() }
        var r = URLRequest(url: url)
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        r.setValue("application/rss+xml, application/atom+xml, application/json, text/xml, */*", forHTTPHeaderField: "Accept")
        if let userAgent { r.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, resp) = try? await s.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    /// Direct first; if it has not answered within 2.5s (or the domain is known to be blocked) the server relay is used too. First good answer wins.
    func data(_ url: URL, userAgent: String? = nil, headers: [String: String] = [:], maxBytes: Int = 3_000_000) async -> Data? {
        let paired = settings.gatewayConfigured
        if paired, router.cachedRoute(for: url) == .proxy { return (try? await gateway.fetch(url, maxBytes: maxBytes))?.0 }
        return await withTaskGroup(of: Data?.self) { g in
            g.addTask { await Self.direct(url, userAgent: userAgent, headers: headers) }
            if paired {
                g.addTask { [gateway] in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if Task.isCancelled { return nil }
                    return (try? await gateway.fetch(url, maxBytes: maxBytes))?.0
                }
            }
            for await d in g { if let d { g.cancelAll(); return d } }
            return nil
        }
    }

    func items(_ s: NewsSource) async -> [Article] {
        guard let u = URL(string: s.url), let d = await data(u) else { return [] }
        return await Task.detached { NewsParse.articles(kind: s.kind, data: d, source: s.name) }.value
    }

    /// Loads a section progressively: `update` is called every time another source answered.
    func load(_ section: NewsSection, update: @escaping @MainActor ([Article]) -> Void) async -> [Article] {
        let list: [NewsSource]
        if section == .explore {
            list = NewsCatalog.exploreMix.flatMap { Array(NewsCatalog.sources($0).prefix($0 == .video ? 3 : 2)) }
        } else { list = NewsCatalog.sources(section) }
        var parts: [[Article]] = []
        await withTaskGroup(of: [Article].self) { g in
            for s in list { g.addTask { await self.items(s) } }
            for await p in g where !p.isEmpty {
                parts.append(section == .explore ? Array(p.prefix(5)) : p)
                update(Self.compose(parts, section))
            }
        }
        var result = Self.compose(parts, section)
        // pictures for stories whose feed has none: read og:image from the page head, then publish again
        let missing = result.enumerated().filter { $0.element.image == nil }.prefix(14).map { $0.offset }
        if !missing.isEmpty {
            await withTaskGroup(of: (Int, String?).self) { g in
                for i in missing { g.addTask { (i, await self.ogImage(result[i].url)) } }
                for await (i, img) in g { if let img { result[i].image = img } }
            }
            update(result)
        }
        return result
    }

    private static func compose(_ parts: [[Article]], _ section: NewsSection) -> [Article] {
        var all = NewsParse.merge(parts, cap: section == .explore ? 60 : 48)
        if section == .explore {
            // a video with a picture first, then everything else newest-first
            if let i = all.firstIndex(where: { $0.video != nil && $0.image != nil }), i > 0 { let v = all.remove(at: i); all.insert(v, at: 0) }
        }
        return all
    }

    private func ogImage(_ page: String) async -> String? {
        guard let u = URL(string: page), let d = await dataHead(u) else { return nil }
        return NewsParse.ogImage(in: String(decoding: d, as: UTF8.self))
    }
    /// First ~100KB of a page (direct only, 4s) — enough for <head>.
    private func dataHead(_ url: URL) async -> Data? {
        let c = URLSessionConfiguration.ephemeral; c.connectionProxyDictionary = [:]; c.timeoutIntervalForRequest = 4
        let s = URLSession(configuration: c); defer { s.finishTasksAndInvalidate() }
        var r = URLRequest(url: url); r.setValue("bytes=0-120000", forHTTPHeaderField: "Range")
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await s.data(for: r), let h = resp as? HTTPURLResponse, h.statusCode == 200 || h.statusCode == 206 else { return nil }
        return d.prefix(150_000)
    }

    // MARK: scores & trends

    func scores() async -> [Score] {
        let leagues: [(String, String, String)] = [("basketball", "nba", "NBA"), ("football", "nfl", "NFL"), ("hockey", "nhl", "NHL"), ("soccer", "eng.1", "英超"), ("soccer", "uefa.champions", "欧冠")]
        var all: [Score] = []
        await withTaskGroup(of: [Score].self) { g in
            for (sport, lg, label) in leagues {
                g.addTask {
                    guard let u = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(lg)/scoreboard"), let d = await self.data(u),
                          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let evs = j["events"] as? [[String: Any]] else { return [] }
                    return evs.prefix(8).compactMap { e in
                        guard let c = (e["competitions"] as? [[String: Any]])?.first, let comps = c["competitors"] as? [[String: Any]] else { return nil }
                        let teams = comps.map { x -> ScoreTeam in
                            let t = x["team"] as? [String: Any]
                            return ScoreTeam(name: (t?["abbreviation"] as? String) ?? (t?["shortDisplayName"] as? String) ?? "", logo: (t?["logo"] as? String) ?? "", score: (x["score"] as? String) ?? "0", winner: (x["winner"] as? Bool) ?? false)
                        }
                        let st = ((e["status"] as? [String: Any])?["type"] as? [String: Any]) ?? [:]
                        return Score(id: "\(lg)-\(e["id"] ?? "")", league: label, state: (st["state"] as? String) ?? "pre", detail: (st["shortDetail"] as? String) ?? "", teams: teams, url: "")
                    }
                }
            }
            for await p in g { all += p }
        }
        let rank = ["in": 0, "post": 1, "pre": 2]
        return Array(all.sorted { (rank[$0.state] ?? 3) < (rank[$1.state] ?? 3) }.prefix(24))
    }

    func trends(geo: String) async -> [Trend] {
        guard let u = URL(string: "https://trends.google.com/trending/rss?geo=\(geo)"), let d = await data(u) else { return [] }
        return await Task.detached {
            NewsParse.Feed().parse(d).prefix(20).enumerated().map { i, r in
                Trend(rank: i + 1, title: NewsParse.plain(r.title), traffic: r.extra["ht:approx_traffic"] ?? "", image: r.extra["ht:picture"] ?? "", headline: NewsParse.plain(r.extra["ht:news_item_title"] ?? ""), url: r.extra["ht:news_item_url"] ?? "")
            }.filter { !$0.title.isEmpty }
        }.value
    }
}
