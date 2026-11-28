import Foundation

/// "Directed" queries skip the search engine: a site name opens that site, "site + words" searches inside that site.
/// Only curated, unambiguous names are listed (so "apple pie" is still an ordinary search), and the search box always shows the
/// ordinary search as the next row.
struct DirectTarget: Equatable {
    var name: String
    var url: URL
    var isSearch: Bool
    var query: String = ""
}

enum SmartSearch {
    private struct Site {
        let name: String
        let aliases: [String]           // lower-case; the whole input equal to one of these opens `home`
        let home: String
        let search: String?             // %s = encoded words; nil = open only
        var searchByWords = true        // "alias words" searches inside the site (off for names that are also ordinary words)
    }

    private static let sites: [Site] = [
        Site(name: "YouTube", aliases: ["youtube", "油管", "ytb"], home: "https://www.youtube.com/", search: "https://www.youtube.com/results?search_query=%s"),
        Site(name: "哔哩哔哩", aliases: ["bilibili", "b站", "哔哩哔哩", "哔站", "bili"], home: "https://www.bilibili.com/", search: "https://search.bilibili.com/all?keyword=%s"),
        Site(name: "GitHub", aliases: ["github"], home: "https://github.com/", search: "https://github.com/search?q=%s&type=repositories"),
        Site(name: "知乎", aliases: ["知乎", "zhihu"], home: "https://www.zhihu.com/", search: "https://www.zhihu.com/search?type=content&q=%s"),
        Site(name: "淘宝", aliases: ["淘宝", "taobao"], home: "https://www.taobao.com/", search: "https://s.taobao.com/search?q=%s"),
        Site(name: "京东", aliases: ["京东", "jingdong"], home: "https://www.jd.com/", search: "https://search.jd.com/Search?keyword=%s"),
        Site(name: "微博", aliases: ["微博", "weibo"], home: "https://weibo.com/", search: "https://s.weibo.com/weibo?q=%s"),
        Site(name: "豆瓣", aliases: ["豆瓣", "douban"], home: "https://www.douban.com/", search: "https://www.douban.com/search?q=%s"),
        Site(name: "小红书", aliases: ["小红书", "xhs", "xiaohongshu"], home: "https://www.xiaohongshu.com/", search: "https://www.xiaohongshu.com/search_result?keyword=%s"),
        Site(name: "抖音", aliases: ["抖音", "douyin"], home: "https://www.douyin.com/", search: nil),
        Site(name: "百度", aliases: ["百度", "baidu"], home: "https://www.baidu.com/", search: "https://www.baidu.com/s?wd=%s"),
        Site(name: "维基百科", aliases: ["维基百科", "维基", "wikipedia"], home: "https://zh.wikipedia.org/", search: "https://zh.wikipedia.org/w/index.php?search=%s"),
        Site(name: "X", aliases: ["推特", "twitter"], home: "https://x.com/", search: "https://x.com/search?q=%s"),
        Site(name: "Instagram", aliases: ["ins", "instagram", "照片墙"], home: "https://www.instagram.com/", search: nil),
        Site(name: "Stack Overflow", aliases: ["stackoverflow"], home: "https://stackoverflow.com/", search: "https://stackoverflow.com/search?q=%s"),
        Site(name: "Larousse（法语词典）", aliases: ["larousse"], home: "https://www.larousse.fr/", search: "https://www.larousse.fr/dictionnaires/francais/%s"),
        Site(name: "Kimi", aliases: ["kimi"], home: "https://www.kimi.com/", search: nil),
        Site(name: "DeepSeek", aliases: ["deepseek"], home: "https://chat.deepseek.com/", search: nil),
        Site(name: "ChatGPT", aliases: ["chatgpt"], home: "https://chatgpt.com/", search: nil),
        Site(name: "Claude", aliases: ["claude"], home: "https://claude.ai/", search: nil),
        Site(name: "Gemini", aliases: ["gemini"], home: "https://gemini.google.com/", search: nil),
        Site(name: "豆包", aliases: ["豆包", "doubao"], home: "https://www.doubao.com/", search: nil),
        Site(name: "Perplexity", aliases: ["perplexity"], home: "https://www.perplexity.ai/", search: nil),
        // ordinary words as well as brands: only the exact name opens the site, never "apple pie"
        Site(name: "Apple", aliases: ["apple", "苹果官网"], home: "https://www.apple.com/cn/", search: nil, searchByWords: false),
        Site(name: "Google", aliases: ["谷歌", "google"], home: "https://www.google.com/", search: nil, searchByWords: false),
        Site(name: "Amazon", aliases: ["amazon", "亚马逊"], home: "https://www.amazon.com/", search: nil, searchByWords: false),
        Site(name: "Netflix", aliases: ["netflix", "奈飞"], home: "https://www.netflix.com/", search: nil, searchByWords: false),
        Site(name: "Spotify", aliases: ["spotify"], home: "https://open.spotify.com/", search: nil, searchByWords: false),
        Site(name: "Telegram", aliases: ["telegram", "电报"], home: "https://web.telegram.org/", search: nil, searchByWords: false),
        Site(name: "Discord", aliases: ["discord"], home: "https://discord.com/app", search: nil, searchByWords: false),
        Site(name: "12306", aliases: ["12306"], home: "https://www.12306.cn/", search: nil, searchByWords: false),
    ]

    private static let fillers = ["官方网站", "官网", "网页版", "首页", "入口", "登录"]

    private static func isCJK(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value >= 0x2E80 } }

    static func resolve(_ raw: String) -> DirectTarget? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 60, !q.contains("\""), !q.contains("://"), !q.lowercased().contains("site:"), !q.hasPrefix("-") else { return nil }
        let norm = q.lowercased()

        // 1. the name alone (optionally "官网", "首页", "登录" …) opens the site
        var base = norm
        for f in fillers where base.hasSuffix(f) && base.count > f.count { base = String(base.dropLast(f.count)).trimmingCharacters(in: .whitespaces) }
        if let s = sites.first(where: { $0.aliases.contains(base) }), let u = URL(string: s.home) { return DirectTarget(name: s.name, url: u, isSearch: false) }

        // 2. "site words": the site name FIRST, then what to look for ("youtube swift", "b站 swift教程", "淘宝手机壳")
        let tokens = q.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count <= 8 else { return nil }
        for s in sites where s.searchByWords {
            guard let tpl = s.search else { continue }
            var words: String?
            if tokens.count >= 2, s.aliases.contains(tokens[0].lowercased()) { words = tokens.dropFirst().joined(separator: " ") }
            else if let a = s.aliases.first(where: { isCJK($0) && norm.hasPrefix($0) && norm.count > $0.count }), tokens.count == 1 || tokens[0].lowercased().hasPrefix(a) {
                words = String(q.dropFirst(a.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let w = words, !w.isEmpty else { continue }
            let enc = w.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))) ?? w
            if let u = URL(string: tpl.replacingOccurrences(of: "%s", with: enc)) { return DirectTarget(name: s.name, url: u, isSearch: true, query: w) }
        }
        return nil
    }
}
