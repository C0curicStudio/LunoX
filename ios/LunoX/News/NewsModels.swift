import Foundation
import SwiftUI
import UIKit

struct NewsVideo: Codable, Hashable { var kind: String; var id: String?; var url: String? }

struct Article: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String
    var url: String
    var source: String
    var ts: Double
    var image: String?
    var video: NewsVideo?
    var cat: String?
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

struct ScoreTeam: Codable, Hashable { var name: String; var logo: String; var score: String; var winner: Bool }
struct Score: Codable, Identifiable, Hashable { var id: String; var league: String; var state: String; var detail: String; var teams: [ScoreTeam]; var url: String }
struct Trend: Codable, Identifiable, Hashable { var rank: Int; var title: String; var traffic: String; var image: String; var headline: String; var url: String; var id: Int { rank } }

enum NewsSection: String, CaseIterable, Identifiable {
    case explore, trends, world, china, tech, opensource, finance, sports, entertainment, science, french, video
    var id: String { rawValue }
    var title: String {
        switch self {
        case .explore: "探索"; case .trends: "当前趋势"; case .world: "国际"; case .china: "中文"; case .tech: "科技"; case .opensource: "开源"; case .finance: "财经"
        case .sports: "体育"; case .entertainment: "娱乐"; case .science: "科学"; case .french: "法语"; case .video: "视频"
        }
    }
}

@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var articles: [NewsSection: [Article]] = [:]
    @Published private(set) var scores: [Score] = []
    @Published private(set) var trends: [Trend] = []
    @Published private(set) var loading: Set<NewsSection> = []
    @Published private(set) var failed: [NewsSection: String] = [:]
    @Published private(set) var fromCache = false
    /// article id -> translated (title, summary); filled in the background so headlines read in your language.
    @Published private(set) var tr: [String: [String]] = [:]
    var translate: (([String], String?) async -> [String]?)?
    private var translating = false

    private let gateway: GatewayClient
    private let settings: Settings
    private let dir = Paths.dir("News", excludeFromBackup: true)
    private var fetchedAt: [NewsSection: Date] = [:]

    private let engine: NewsEngine

    init(gateway: GatewayClient, settings: Settings, router: Router) {
        self.gateway = gateway; self.settings = settings
        self.engine = NewsEngine(gateway: gateway, router: router, settings: settings)
        for s in NewsSection.allCases where s != .trends { if let a: [Article] = disk("\(s.rawValue).json") { articles[s] = a } }
        if let t: [String: [String]] = disk("tr.json") { tr = t }
        if let t: [Trend] = disk("trends.json") { trends = t }
        if let sc: [Score] = disk("scores.json") { scores = sc }
    }

    private func disk<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private func save<T: Encodable>(_ v: T, _ name: String) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        let u = dir.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async { try? d.write(to: u, options: .atomic) }
    }

    private struct Wrap<T: Decodable>: Decodable { var items: [T] }

    func title(_ a: Article) -> String { settings.prefs.translateNews ? (tr[a.id]?.first ?? a.title) : a.title }
    func summary(_ a: Article) -> String { settings.prefs.translateNews ? (tr[a.id]?.last.flatMap { $0.isEmpty ? nil : $0 } ?? a.summary) : a.summary }

    /// Launch: refresh the front page in the background (the last copy is already on screen from disk).
    func warmUp() {
        Task { [weak self] in try? await Task.sleep(nanoseconds: 1_200_000_000); await self?.load(.explore) }
    }

    /// Apple on-device translation of headlines that are not in the reading language. Grouped by source language, 30 at a time.
    private func translateHeadlines(_ items: [Article]) async {
        guard settings.prefs.translateNews, let translate, !translating else { return }
        let target = LanguageUtil.target(settings.prefs.translateTarget)
        var groups: [String: [Article]] = [:]
        for a in items.prefix(30) where tr[a.id] == nil {
            guard let d = LanguageUtil.detect(a.title), d.confidence > 0.5, !LanguageUtil.same(d.code, target) else { continue }
            groups[d.code, default: []].append(a)
        }
        guard !groups.isEmpty else { return }
        translating = true; defer { translating = false }
        for (code, arts) in groups {
            let texts = arts.flatMap { [$0.title, String($0.summary.prefix(160))] }
            guard let out = await translate(texts, code), out.count == texts.count else { continue }
            var next = tr
            for (i, a) in arts.enumerated() { next[a.id] = [out[i * 2], out[i * 2 + 1]] }
            withAnimation(.easeInOut(duration: 0.25)) { tr = next }
            save(next, "tr.json")
        }
    }

    private func hasContent(_ s: NewsSection) -> Bool { s == .trends ? !trends.isEmpty : !(articles[s] ?? []).isEmpty }

    /// Local-first: every source is fetched straight from the phone (relayed through your server only when slow/blocked),
    /// shown as soon as the first source answers; the server's aggregator is the last fallback.
    func load(_ s: NewsSection, force: Bool = false) async {
        if !force, let t = fetchedAt[s], Date().timeIntervalSince(t) < 300, hasContent(s) { return }
        guard !loading.contains(s) else { return }
        #if DEBUG
        if Demo.value("demo") == "news", !settings.gatewayConfigured { loadDemo(); return }
        #endif
        loading.insert(s); defer { loading.remove(s) }
        failed[s] = nil

        if s == .trends {
            let region = Locale.current.region?.identifier ?? "US"
            let geo = ["CN": "HK"][region] ?? region
            var t = await engine.trends(geo: geo)
            if t.isEmpty, settings.gatewayConfigured, let d = try? await gateway.newsData("/v1/news/trends", ["geo": geo]) { t = (try? JSONDecoder().decode(Wrap<Trend>.self, from: d).items) ?? [] }
            if t.isEmpty { failed[s] = settings.gatewayConfigured ? "empty" : "blocked"; fromCache = !trends.isEmpty }
            else { trends = t; save(t, "trends.json"); fetchedAt[s] = Date(); fromCache = false }
            return
        }

        var items = await engine.load(s) { [weak self] partial in self?.articles[s] = partial; Task { await self?.translateHeadlines(partial) } }
        if items.isEmpty, settings.gatewayConfigured, let d = try? await gateway.newsData("/v1/news", ["cat": s.rawValue]),
           let srv = try? JSONDecoder().decode(Wrap<Article>.self, from: d).items { items = srv }
        if items.isEmpty {
            failed[s] = settings.gatewayConfigured ? "empty" : "blocked"
            fromCache = !(articles[s] ?? []).isEmpty
        } else {
            articles[s] = items; save(items, "\(s.rawValue).json"); fetchedAt[s] = Date(); fromCache = false
            Task { await translateHeadlines(items) }
            for a in items.prefix(8) { if let u = a.image { Task.detached(priority: .utility) { _ = await ImageStore.shared.load(u) } } }
        }
        if s == .explore || s == .sports {
            let sc = await engine.scores()
            if !sc.isEmpty { scores = sc; save(sc, "scores.json") }
        }
    }

    #if DEBUG
    /// Screenshot data (never compiled into Release).
    private func loadDemo() {
        func img(_ n: Int) -> String { "https://picsum.photos/seed/lunox\(n)/900/600" }
        let now = Date().timeIntervalSince1970 * 1000
        let titles = ["月球基地计划公布：首批居住舱将于 2030 年送达", "全球芯片竞赛升温，新一代 2 纳米工艺量产在即", "Le Louvre dévoile une nouvelle aile consacrée à l'art numérique",
                      "世界杯预选赛：主场逆转取胜，晋级形势大好", "AI 眼镜发布会：续航翻倍，重量仅 38 克", "极光之夜：北欧摄影师带你看最壮观的天空", "央行宣布新一轮利率调整，市场反应平稳",
                      "The quiet revolution in solid-state batteries", "新片预告：科幻巨制定档，特效团队首次公开幕后"]
        let list = titles.enumerated().map { i, t in
            Article(id: "d\(i)", title: t, summary: "这是一段用于预览的摘要文字，展示卡片在不同长度内容下的排版效果。", url: "https://example.com/\(i)", source: ["BBC 中文", "The Verge", "Le Monde", "ESPN", "36氪", "NASA", "FT 中文网", "Nature", "Variety"][i % 9],
                    ts: now - Double(i) * 1_800_000, image: img(i), video: i == 0 ? NewsVideo(kind: "youtube", id: "21X5lGlDOfg", url: nil) : (i == 5 ? NewsVideo(kind: "youtube", id: "21X5lGlDOfg", url: nil) : nil), cat: "demo")
        }
        for s in NewsSection.allCases where s != .trends { articles[s] = s == .video ? list.filter { $0.video != nil } + list.prefix(3) : list }
        trends = (1...8).map { Trend(rank: $0, title: ["世界杯", "新款 iPhone", "极光", "油价", "AI 眼镜", "Hunger Games", "地震", "奥斯卡"][$0 - 1], traffic: "\($0 * 200)万+", image: img(20 + $0), headline: "相关报道：这是第 \($0) 个热门话题的最新进展", url: "") }
        scores = [
            Score(id: "s1", league: "NBA", state: "in", detail: "2nd 06:39", teams: [ScoreTeam(name: "MIA", logo: "", score: "48", winner: false), ScoreTeam(name: "NYK", logo: "", score: "27", winner: false)], url: ""),
            Score(id: "s2", league: "NBA", state: "in", detail: "1st 06:36", teams: [ScoreTeam(name: "PHI", logo: "", score: "17", winner: false), ScoreTeam(name: "IND", logo: "", score: "7", winner: false)], url: ""),
            Score(id: "s3", league: "英超", state: "post", detail: "FT", teams: [ScoreTeam(name: "ARS", logo: "", score: "2", winner: true), ScoreTeam(name: "CHE", logo: "", score: "1", winner: false)], url: ""),
        ]
    }
    #endif
}
