import SwiftUI

struct NewTabView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var offline: OfflineCache
    @Environment(\.theme) private var theme
    @State private var shown = false

    private struct Site: Identifiable { var id: String { url }; let name: String; let url: String }
    private static let defaults: [Site] = [
        Site(name: "Google", url: "https://www.google.com"), Site(name: "YouTube", url: "https://www.youtube.com"),
        Site(name: "维基百科", url: "https://zh.wikipedia.org"), Site(name: "GitHub", url: "https://github.com"),
        Site(name: "百度", url: "https://www.baidu.com"), Site(name: "哔哩哔哩", url: "https://www.bilibili.com"),
        Site(name: "知乎", url: "https://www.zhihu.com"), Site(name: "Cloudflare", url: "https://www.cloudflare.com"),
    ]
    private var sites: [Site] {
        store.bookmarks.isEmpty ? Self.defaults : store.bookmarks.prefix(8).map { Site(name: $0.title, url: $0.url) }
    }
    private var isPrivate: Bool { store.current?.isPrivate == true }

    var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            // artwork lives in its own band above the text so it never covers the title
            FlatArt(theme: theme, seed: isPrivate ? 2 : abs(settings.prefs.themeID.hashValue) % 3)
                .frame(height: 250).frame(maxWidth: .infinity).opacity(isPrivate ? 0.5 : 1)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.75), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 6) {
                        Text(isPrivate ? "隐私浏览" : greeting)
                            .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
                        Text(isPrivate ? "关闭所有隐私标签页后，历史记录与 Cookie 都会被丢弃" : "在下方搜索或输入网址")
                            .font(.system(size: 14, design: .rounded)).foregroundStyle(theme.inkSoft).multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    .padding(.top, 262).staggered(0, shown)

                    if !isPrivate {
                        section(store.bookmarks.isEmpty ? "常用网站" : "收藏", index: 1) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 18) {
                                ForEach(sites) { s in
                                    Button { Haptics.tap(); store.open(s.url) } label: { tile(s) }.buttonStyle(PressableStyle())
                                }
                            }
                        }
                    }
                    if !isPrivate && !offline.pages.isEmpty {
                        section("离线可读", index: 2) {
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
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    if !store.online {
                        Label("当前离线：界面可用，已缓存的页面可直接打开", systemImage: "wifi.slash").font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft).staggered(3, shown)
                    }
                    Spacer(minLength: 170)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            withAnimation { shown = true }
            for s in sites { if let h = URL(string: s.url)?.host { store.ensureIcon(host: h); Prefetch.dns(h) } }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "夜深了" : h < 12 ? "早上好" : h < 18 ? "下午好" : "晚上好"
    }

    private func section<C: View>(_ title: String, index: Int, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.inkSoft).padding(.leading, 4)
            c()
        }.staggered(index, shown)
    }

    private func tile(_ s: Site) -> some View {
        let host = URL(string: s.url)?.host
        return VStack(spacing: 8) {
            FaviconTile(image: host.flatMap { store.icon(for: $0) }, fallback: s.name, size: 60, radius: 18)
                .shadow(color: .black.opacity(theme.scheme == .dark ? 0.3 : 0.07), radius: 8, y: 3)
            Text(s.name).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
        }
    }
}
