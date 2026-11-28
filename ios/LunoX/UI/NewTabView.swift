import SwiftUI

/// Clean start page. Sections, their order and an optional flat background come from the "自定义起始页" editor.
struct NewTabView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var offline: OfflineCache
    @EnvironmentObject var news: NewsStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var edge: EdgeSelector
    @Environment(\.theme) private var theme
    @State private var shown = false
    @State private var pairMsg: String?

    private struct Site: Identifiable { var id: String { url }; let name: String; let url: String }
    private static let defaults: [Site] = [
        Site(name: "Google", url: "https://www.google.com"), Site(name: "YouTube", url: "https://www.youtube.com"),
        Site(name: "维基百科", url: "https://zh.wikipedia.org"), Site(name: "GitHub", url: "https://github.com"),
        Site(name: "百度", url: "https://www.baidu.com"), Site(name: "哔哩哔哩", url: "https://www.bilibili.com"),
        Site(name: "知乎", url: "https://www.zhihu.com"), Site(name: "Cloudflare", url: "https://www.cloudflare.com"),
    ]
    private var isPrivate: Bool { store.current?.isPrivate == true }
    private var bg: StartBG? { settings.prefs.startBackground.isEmpty || isPrivate ? nil : StartBG(rawValue: settings.prefs.startBackground) }

    private var sections: [StartSection] {
        var o = settings.prefs.startOrder.compactMap(StartSection.init(rawValue:))
        for s in StartSection.allCases where !o.contains(s) { o.append(s) }
        return o.filter { !settings.prefs.startHidden.contains($0.rawValue) }
    }
    private var favorites: [Site] { store.bookmarks.isEmpty ? Self.defaults : store.bookmarks.prefix(8).map { Site(name: $0.title, url: $0.url) } }
    private var frequent: [Site] {
        var counts: [String: (n: Int, url: String)] = [:]
        for h in store.history.prefix(600) {
            guard let u = URL(string: h.url), let host = u.host else { continue }
            counts[u.displayHost, default: (0, "https://\(host)")].n += 1
        }
        return counts.sorted { $0.value.n > $1.value.n }.prefix(8).map { Site(name: $0.key, url: $0.value.url) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let bg { StartBackgroundView(bg: bg, dark: theme.scheme == .dark).ignoresSafeArea().transition(.opacity) }
            else { theme.background.ignoresSafeArea() }

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isPrivate ? "隐私浏览" : greeting).font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
                        Text(isPrivate ? "关闭所有隐私标签页后，历史记录与 Cookie 都会被丢弃" : "在下方搜索或输入网址")
                            .font(.system(size: 14, design: .rounded)).foregroundStyle(theme.inkSoft)
                    }
                    .padding(.top, 70).padding(.horizontal, 4).staggered(0, shown)

                    if !settings.gatewayConfigured && !isPrivate && !hy2Ready { pairBanner.staggered(1, shown) }

                    if !isPrivate {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { i, s in
                            sectionView(s).staggered(i + 1, shown)
                        }
                        Button { Haptics.soft(); store.startEditRequest += 1 } label: {
                            Label("编辑", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                                .padding(.horizontal, 20).frame(height: 42).background(.ultraThinMaterial, in: Capsule())
                        }.buttonStyle(PressableStyle()).frame(maxWidth: .infinity).staggered(sections.count + 2, shown)
                    }
                    if !store.online { Label("当前离线：界面可用，已缓存的页面可直接打开", systemImage: "wifi.slash").font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft) }
                    Spacer(minLength: 170)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .animation(Motion.smooth, value: settings.prefs.startBackground)
        .animation(Motion.smooth, value: settings.prefs.startOrder)
        .animation(Motion.smooth, value: settings.prefs.startHidden)
        .onAppear {
            withAnimation { shown = true }
            for s in favorites + frequent { if let h = URL(string: s.url)?.host { store.ensureIcon(host: h); Prefetch.dns(h) } }
        }
        .task { if settings.gatewayConfigured && !settings.prefs.startHidden.contains("news") { await news.load(.explore) } }
    }

    private var hy2Ready: Bool { store.hy2.running }

    // MARK: sections

    @ViewBuilder private func sectionView(_ s: StartSection) -> some View {
        switch s {
        case .favorites:
            block(store.bookmarks.isEmpty ? "常用网站" : "个人收藏", icon: "star") { grid(favorites) }
        case .frequent:
            if !frequent.isEmpty { block("经常访问的网站", icon: "clock") { grid(frequent) } }
        case .news:
            newsBlock
        case .offline:
            if !offline.pages.isEmpty { block("离线可读", icon: "arrow.down.circle") { offlineList } }
        case .closed:
            if !store.recentlyClosed.isEmpty { block("最近关闭的标签页", icon: "square.on.square") { closedList } }
        }
    }

    private func block<C: View>(_ title: String, icon: String, trailing: (() -> AnyView)? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).labelStyle(.titleAndIcon)
                Spacer()
                if let trailing { trailing() }
            }
            content()
        }
        .padding(bg == nil ? 0 : 16)
        .background { if bg != nil { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial) } }
    }

    private func grid(_ sites: [Site]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 16) {
            ForEach(sites) { s in
                Button { Haptics.tap(); store.open(s.url) } label: {
                    VStack(spacing: 8) {
                        FaviconTile(image: URL(string: s.url)?.host.flatMap { store.icon(for: $0) }, fallback: s.name, size: 60, radius: 18)
                            .shadow(color: .black.opacity(theme.scheme == .dark ? 0.3 : 0.07), radius: 8, y: 3)
                        Text(s.name).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
                    }
                }.buttonStyle(PressableStyle())
            }
        }
    }

    private var offlineList: some View {
        VStack(spacing: 0) {
            ForEach(Array(offline.pages.prefix(4).enumerated()), id: \.element.id) { i, p in
                Button { store.open(p.url) } label: {
                    HStack(spacing: 12) {
                        FaviconTile(image: URL(string: p.url)?.host.flatMap { store.icon(for: $0) }, fallback: p.title, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).lineLimit(1).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(theme.ink)
                            Text(URL(string: p.url)?.displayHost ?? "").font(.system(size: 12)).foregroundStyle(theme.inkSoft)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(theme.accent.opacity(0.8))
                    }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }.buttonStyle(PressableStyle(scale: 0.98))
                if i < min(offline.pages.count, 4) - 1 { Divider().padding(.leading, 56) }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var closedList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.recentlyClosed.prefix(4).enumerated()), id: \.element.id) { i, c in
                Button { Haptics.tap(); store.open(c.url.absoluteString) } label: {
                    HStack(spacing: 12) {
                        FaviconTile(image: c.url.host.flatMap { store.icon(for: $0) }, fallback: c.title, size: 30)
                        Text(c.title).lineLimit(1).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(theme.ink)
                        Spacer()
                    }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }.buttonStyle(PressableStyle(scale: 0.98))
                if i < min(store.recentlyClosed.count, 4) - 1 { Divider().padding(.leading, 56) }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var newsBlock: some View {
        block("新闻", icon: "newspaper", trailing: {
            AnyView(Button { Haptics.soft(); store.newsRequest += 1 } label: {
                HStack(spacing: 3) { Text("查看全部"); Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)) }
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(theme.accent)
            }.buttonStyle(.plain))
        }) {
            let items = Array((news.articles[.explore] ?? []).filter { $0.image != nil }.prefix(7))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if items.isEmpty {
                        Button { store.newsRequest += 1 } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "newspaper.fill").font(.system(size: 30)).foregroundStyle(theme.accent)
                                Text("打开新闻").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                                Text(settings.gatewayConfigured ? "图片、视频与各板块头条" : "需要先与服务器配对").font(.system(size: 12)).foregroundStyle(theme.inkSoft)
                            }.frame(width: 240, height: 150).background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }.buttonStyle(PressableStyle(scale: 0.97))
                    }
                    ForEach(items) { a in
                        Button { Haptics.tap(); store.open(a.url) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Color.clear.frame(width: 230, height: 130).overlay { RemoteImage(url: a.image) }
                                    .overlay { if a.video != nil { Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.92)) } }
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                Text(a.title).font(.system(size: 14.5, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(2).multilineTextAlignment(.leading).frame(width: 230, alignment: .leading)
                                Text(a.source).font(.system(size: 11.5, design: .rounded)).foregroundStyle(theme.inkSoft)
                            }
                        }.buttonStyle(PressableStyle(scale: 0.97))
                    }
                }.padding(.horizontal, 1)
            }.padding(.horizontal, bg == nil ? -20 : 0).padding(.leading, bg == nil ? 20 : 0)
        }
    }

    private var pairBanner: some View {
        Button { pair() } label: {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus").font(.system(size: 20)).foregroundStyle(.orange).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("尚未连接你的服务器").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                    Text(pairMsg ?? "复制服务器给的 lunox:// 链接，然后点这里一键配对").font(.system(size: 12)).foregroundStyle(theme.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.inkSoft)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }.buttonStyle(PressableStyle(scale: 0.98))
    }

    private func pair() {
        let t = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), store.applyPairing(u) {
            pairMsg = "已配对 ✓"; Haptics.ok()
        } else { pairMsg = "剪贴板里没有 lunox:// 配对链接"; Haptics.warn() }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "夜深了" : h < 12 ? "早上好" : h < 18 ? "下午好" : "晚上好"
    }
}
