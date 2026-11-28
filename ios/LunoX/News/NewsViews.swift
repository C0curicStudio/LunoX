import SwiftUI
import WebKit
import AVKit

// MARK: - Images (direct first, through your server when the site is blocked; memory + disk cache)

@MainActor
final class ImageStore {
    static let shared = ImageStore()
    var gateway: GatewayClient?
    private let mem = NSCache<NSString, UIImage>()
    private let dir = Paths.dir("NewsImages", excludeFromBackup: true)
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func load(_ s: String) async -> UIImage? {
        let key = s.sha256Hex
        if let i = mem.object(forKey: key as NSString) { return i }
        if let t = inflight[key] { return await t.value }
        let t = Task<UIImage?, Never> { await fetch(s, key: key) }
        inflight[key] = t
        let r = await t.value
        inflight[key] = nil
        return r
    }

    private func fetch(_ s: String, key: String) async -> UIImage? {
        guard let url = URL(string: s) else { return nil }
        let file = dir.appendingPathComponent(key)
        var data = try? Data(contentsOf: file)
        if data == nil {
            let c = URLSessionConfiguration.ephemeral; c.connectionProxyDictionary = [:]; c.timeoutIntervalForRequest = 6
            let sess = URLSession(configuration: c); defer { sess.finishTasksAndInvalidate() }
            if let (d, r) = try? await sess.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 { data = d }
            else if let g = gateway, let (d, _, _) = try? await g.fetch(url, maxBytes: 5_000_000) { data = d }
            if let d = data { DispatchQueue.global(qos: .utility).async { try? d.write(to: file) } }
        }
        guard let d = data, let img = UIImage(data: d) else { return nil }
        let small = await img.byPreparingThumbnail(ofSize: CGSize(width: 1000, height: 1000)) ?? img
        mem.setObject(small, forKey: key as NSString)
        return small
    }
}

struct RemoteImage: View {
    let url: String?
    @State private var image: UIImage?
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [theme.surface, theme.inkSoft.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
        }
        .clipped()
        .task(id: url) {
            guard let url, !url.isEmpty else { return }
            if let i = await ImageStore.shared.load(url) { withAnimation(.easeOut(duration: 0.4)) { image = i } }
        }
    }
}

// MARK: - Video

struct YouTubeView: UIViewRepresentable {
    let id: String
    var autoplay = true
    var controls = false
    var mute = true
    let dataStore: WKWebsiteDataStore

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = dataStore                         // same data store => the same proxy / Hysteria2 route as pages
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false; w.backgroundColor = .black; w.scrollView.backgroundColor = .black
        w.scrollView.isScrollEnabled = false; w.scrollView.pinchGestureRecognizer?.isEnabled = false
        let q = "autoplay=\(autoplay ? 1 : 0)&mute=\(mute ? 1 : 0)&playsinline=1&controls=\(controls ? 1 : 0)&loop=1&playlist=\(id)&modestbranding=1&rel=0&iv_load_policy=3&fs=0"
        let html = """
        <html><head><meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"></head>
        <body style="margin:0;background:#000"><iframe style="position:fixed;inset:0;width:100%;height:100%;border:0"
        src="https://www.youtube-nocookie.com/embed/\(id)?\(q)" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe></body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}

struct VideoPlayerView: View {
    let article: Article
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let v = article.video, v.kind == "youtube", let id = v.id {
                YouTubeView(id: id, autoplay: true, controls: true, mute: false, dataStore: store.dataStore(isPrivate: false)).ignoresSafeArea(edges: .bottom).padding(.top, 60)
            } else if let p = player { VideoPlayer(player: p).ignoresSafeArea() }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }.buttonStyle(PressableStyle(scale: 0.88)).padding(16)
        }
        .task {
            if let v = article.video, v.kind == "youtube" { _ = await store.router.prepare(for: URL(string: "https://www.youtube.com")!) }
            else if let s = article.video?.url, let u = URL(string: s) { let p = AVPlayer(url: u); player = p; p.play() }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Cards

private func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "zh_CN"); f.unitsStyle = .short
    return d.timeIntervalSinceNow > -30 ? "刚刚" : f.localizedString(for: d, relativeTo: Date())
}

private struct Meta: View {
    let a: Article
    var light = false
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            Text(a.source).fontWeight(.semibold)
            if a.ts > 0 { Text("·"); Text(relative(a.date)) }
        }
        .font(.system(size: 12, design: .rounded)).foregroundStyle(light ? Color.white.opacity(0.82) : theme.inkSoft).lineLimit(1)
    }
}

private struct PlayBadge: View {
    var size: CGFloat = 54
    var body: some View {
        Image(systemName: "play.fill").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white).offset(x: size * 0.03)
            .frame(width: size, height: size).background(.black.opacity(0.35), in: Circle()).background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
    }
}

struct HeroCard: View {
    let a: Article
    let autoplay: Bool
    let tap: () -> Void
    @EnvironmentObject var store: BrowserStore
    @State private var live = false
    var body: some View {
        Button(action: tap) {
            Color.clear.aspectRatio(4.0 / 3.4, contentMode: .fit)
                .overlay { RemoteImage(url: a.image) }
                .overlay {
                    if live, a.video?.kind == "youtube", let id = a.video?.id {
                        YouTubeView(id: id, autoplay: true, controls: false, mute: true, dataStore: store.dataStore(isPrivate: false)).allowsHitTesting(false).transition(.opacity)
                    }
                }
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom) }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        if a.video != nil { Label("视频", systemImage: "play.rectangle.fill").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 4).background(.white.opacity(0.22), in: Capsule()) }
                        Text(a.title).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(3).multilineTextAlignment(.leading)
                        Meta(a: a, light: true)
                    }.padding(18)
                }
                .overlay { if a.video != nil && !live { PlayBadge(size: 62) } }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .task(id: a.id) {
            guard autoplay, a.video?.kind == "youtube" else { return }
            _ = await store.router.prepare(for: URL(string: "https://www.youtube.com")!)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.6)) { live = true } }
        }
        .onDisappear { live = false }
    }
}

struct BigCard: View {
    let a: Article
    let tap: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { RemoteImage(url: a.image) }
                    .overlay { if a.video != nil { PlayBadge() } }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text(a.title).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(3).multilineTextAlignment(.leading)
                if !a.summary.isEmpty { Text(a.summary).font(.system(size: 14)).foregroundStyle(theme.inkSoft).lineLimit(2).multilineTextAlignment(.leading) }
                Meta(a: a)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(PressableStyle(scale: 0.985))
    }
}

struct CompactRow: View {
    let a: Article
    let tap: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(a.title).font(.system(size: 16.5, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(4).multilineTextAlignment(.leading)
                    Meta(a: a)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if a.image != nil {
                    RemoteImage(url: a.image).frame(width: 104, height: 104)
                        .overlay { if a.video != nil { PlayBadge(size: 34) } }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }.padding(.vertical, 4)
        }.buttonStyle(PressableStyle(scale: 0.985))
    }
}

struct ScoreStrip: View {
    let scores: [Score]
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("体育").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { ForEach(scores) { card($0) } }.padding(.horizontal, 16)
            }.padding(.horizontal, -16)
        }
    }
    private func card(_ s: Score) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if s.state == "in" { Circle().fill(Color.red).frame(width: 7, height: 7); Text("进行中").foregroundStyle(Color.red) }
                else { Text(s.state == "post" ? "已结束" : "未开始").foregroundStyle(theme.inkSoft) }
                Text(s.detail).foregroundStyle(theme.inkSoft).lineLimit(1)
            }.font(.system(size: 12, weight: .semibold, design: .rounded))
            ForEach(Array(s.teams.prefix(2).enumerated()), id: \.offset) { _, t in
                HStack(spacing: 10) {
                    Group {
                        if t.logo.isEmpty { Text(String(t.name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent).frame(width: 24, height: 24).background(theme.accent.opacity(0.14), in: Circle()) }
                        else { RemoteImage(url: t.logo).frame(width: 24, height: 24).clipShape(Circle()) }
                    }
                    Text(t.name).font(.system(size: 16, weight: t.winner ? .bold : .semibold, design: .rounded)).foregroundStyle(theme.ink)
                    Spacer(minLength: 8)
                    Text(t.score).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(theme.ink)
                }
            }
            Label(s.league, systemImage: "bubble.left").font(.system(size: 12, design: .rounded)).foregroundStyle(theme.inkSoft)
        }
        .padding(14).frame(width: 196)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.inkSoft.opacity(0.12), lineWidth: 0.6))
    }
}

struct TrendRow: View {
    let t: Trend
    let tap: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 14) {
                Text("\(t.rank)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.inkSoft).frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.title).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                    if !t.traffic.isEmpty { Text("\(t.traffic) 次搜索").font(.system(size: 12, design: .rounded)).foregroundStyle(theme.inkSoft) }
                    if !t.headline.isEmpty { Text(t.headline).font(.system(size: 14)).foregroundStyle(theme.inkSoft).lineLimit(2).multilineTextAlignment(.leading) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !t.image.isEmpty { RemoteImage(url: t.image).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }.padding(.vertical, 8)
        }.buttonStyle(PressableStyle(scale: 0.985))
    }
}

private struct Skeleton: View {
    @State private var on = false
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.inkSoft.opacity(on ? 0.16 : 0.08)).aspectRatio(16.0 / 9.0, contentMode: .fit)
            RoundedRectangle(cornerRadius: 6).fill(theme.inkSoft.opacity(on ? 0.16 : 0.08)).frame(height: 16)
            RoundedRectangle(cornerRadius: 6).fill(theme.inkSoft.opacity(on ? 0.16 : 0.08)).frame(width: 180, height: 14)
        }.onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - Screen

struct NewsView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    var onClose: () -> Void
    var onOpen: (URL) -> Void
    var onSearch: () -> Void
    var onSettings: () -> Void
    @State private var selection: NewsSection
    @State private var player: Article?
    @Namespace private var ns

    init(start: NewsSection = .explore, onClose: @escaping () -> Void, onOpen: @escaping (URL) -> Void, onSearch: @escaping () -> Void, onSettings: @escaping () -> Void) {
        _selection = State(initialValue: start)
        self.onClose = onClose; self.onOpen = onOpen; self.onSearch = onSearch; self.onSettings = onSettings
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabs
                Divider().opacity(0.5)
                TabView(selection: $selection) {
                    ForEach(NewsSection.allCases) { s in
                        SectionFeed(section: s, open: open, play: { player = $0 }, openText: { store.open($0); onClose() }).tag(s)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(Motion.smooth, value: selection)
            }
        }
        .fullScreenCover(item: $player) { VideoPlayerView(article: $0) }
    }

    private func open(_ a: Article) {
        if a.video != nil { player = a; return }
        if let u = URL(string: a.url) { onOpen(u) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { onClose() } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.ink).frame(width: 40, height: 40).background(theme.surface, in: Circle())
                    .overlay(Circle().stroke(theme.inkSoft.opacity(0.14), lineWidth: 0.6))
            }.buttonStyle(PressableStyle(scale: 0.9))
            Button { onSearch() } label: {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSoft); Text("搜索").foregroundStyle(theme.inkSoft); Spacer() }
                    .font(.system(size: 16, design: .rounded)).padding(.horizontal, 14).frame(height: 40).background(theme.inkSoft.opacity(0.12), in: Capsule())
            }.buttonStyle(PressableStyle(scale: 0.98))
            Button { onSettings() } label: { Image(systemName: "gearshape").font(.system(size: 19, weight: .regular)).foregroundStyle(theme.ink).frame(width: 40, height: 40) }.buttonStyle(PressableStyle(scale: 0.9))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    private var tabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(NewsSection.allCases) { s in
                        Button { Haptics.soft(); withAnimation(Motion.snappy) { selection = s } } label: {
                            VStack(spacing: 8) {
                                Text(s.title).font(.system(size: 16, weight: selection == s ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(selection == s ? theme.ink : theme.inkSoft)
                                ZStack {
                                    Capsule().fill(.clear).frame(height: 3)
                                    if selection == s { Capsule().fill(theme.accent).frame(height: 3).matchedGeometryEffect(id: "underline", in: ns) }
                                }
                            }.fixedSize()
                        }.id(s).buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20).padding(.top, 4)
            }
            .onChange(of: selection) { _, v in withAnimation(Motion.smooth) { proxy.scrollTo(v, anchor: .center) } }
        }
    }
}

private struct SectionFeed: View {
    let section: NewsSection
    let open: (Article) -> Void
    let play: (Article) -> Void
    let openText: (String) -> Void
    @EnvironmentObject var news: NewsStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    @State private var shown = false

    private var items: [Article] { news.articles[section] ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if section == .trends { trendList } else { articleList }
                if news.fromCache { Label("离线缓存内容", systemImage: "icloud.slash").font(.system(size: 12, design: .rounded)).foregroundStyle(theme.inkSoft).frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .refreshable { await news.load(section, force: true) }
        .task { await news.load(section); withAnimation { shown = true } }
    }

    @ViewBuilder private var articleList: some View {
        if items.isEmpty {
            if news.loading.contains(section) || news.failed[section] == nil { Skeleton(); Skeleton() }
            else { empty }
        } else {
            let hero = (section == .explore || section == .video) ? (items.first(where: { $0.video != nil && $0.image != nil }) ?? items.first!) : items.first!
            HeroCard(a: hero, autoplay: settings.prefs.newsAutoplay && (section == .explore || section == .video)) { tap(hero) }.staggered(0, shown)
            if (section == .explore || section == .sports), !news.scores.isEmpty { ScoreStrip(scores: news.scores).staggered(1, shown) }
            let rest = items.filter { $0.id != hero.id }
            ForEach(Array(rest.enumerated()), id: \.element.id) { i, a in
                Group {
                    if i % 4 == 0 { BigCard(a: a) { tap(a) } } else { CompactRow(a: a) { tap(a) } }
                }.staggered(min(i + 2, 10), shown, rise: 22)
                if i % 4 != 0 && i % 4 != 3 { Divider().opacity(0.4) }
            }
        }
    }

    @ViewBuilder private var trendList: some View {
        Text("当前趋势").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
        if news.trends.isEmpty { if news.failed[.trends] != nil { empty } else { Skeleton() } }
        ForEach(Array(news.trends.enumerated()), id: \.element.id) { i, t in
            TrendRow(t: t) { openText(t.title) }.staggered(min(i, 10), shown, rise: 18)
            Divider().opacity(0.4)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: news.failed[section] == "unpaired" ? "link.badge.plus" : "wifi.exclamationmark").font(.system(size: 38, weight: .light)).foregroundStyle(theme.inkSoft)
            Text(news.failed[section] == "unpaired" ? "新闻由你的服务器聚合，请先在 设置 › 网络与线路 完成配对" : "暂时没有内容，下拉重试").font(.system(size: 15, design: .rounded)).foregroundStyle(theme.inkSoft).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.top, 70)
    }

    private func tap(_ a: Article) { Haptics.tap(); if a.video != nil { play(a) } else { open(a) } }
}
