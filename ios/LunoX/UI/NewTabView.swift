import SwiftUI

struct NewTabView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var offline: OfflineCache
    @Environment(\.theme) private var theme
    @State private var shown = false

    private var favorites: [Bookmark] { Array(store.bookmarks.prefix(8)) }
    private var isPrivate: Bool { store.current?.isPrivate == true }

    var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()
            FlatArt(theme: theme, seed: isPrivate ? 2 : abs(settings.prefs.themeID.hashValue) % 3)
                .frame(height: 300).opacity(isPrivate ? 0.55 : 1)
                .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(spacing: 30) {
                    VStack(spacing: 6) {
                        Text(isPrivate ? "隐私浏览" : greeting)
                            .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
                        Text(isPrivate ? "关闭所有隐私标签页后，历史记录与 Cookie 都会被丢弃" : "搜索或输入网址")
                            .font(.system(size: 14, design: .rounded)).foregroundStyle(theme.inkSoft).multilineTextAlignment(.center)
                    }
                    .padding(.top, 150).staggered(0, shown)

                    Button { Haptics.soft(); store.searchRequest += 1 } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(theme.accent)
                            Text("搜索或输入网址").foregroundStyle(theme.inkSoft)
                            Spacer()
                            Image(systemName: "mic.fill").foregroundStyle(theme.inkSoft.opacity(0.6)).font(.system(size: 14))
                        }
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .padding(.horizontal, 18).frame(height: 52)
                        .background(theme.surface, in: Capsule())
                        .shadow(color: .black.opacity(theme.scheme == .dark ? 0.35 : 0.08), radius: 16, y: 6)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97)).staggered(1, shown)

                    if !isPrivate && !favorites.isEmpty {
                        section("收藏", index: 2) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 16) {
                                ForEach(favorites) { b in
                                    Button { Haptics.tap(); store.open(b.url) } label: { tile(b) }.buttonStyle(PressableStyle())
                                }
                            }
                        }
                    }
                    if !isPrivate && !offline.pages.isEmpty {
                        section("离线可读", index: 3) {
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
                        Label("当前离线：界面可用，已缓存的页面可直接打开", systemImage: "wifi.slash").font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft).staggered(4, shown)
                    }
                    Spacer(minLength: 170)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { withAnimation { shown = true }; for b in favorites { if let h = URL(string: b.url)?.host { store.ensureIcon(host: h) } } }
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

    private func tile(_ b: Bookmark) -> some View {
        let host = URL(string: b.url)?.host
        return VStack(spacing: 8) {
            FaviconTile(image: host.flatMap { store.icon(for: $0) }, fallback: b.title, size: 60, radius: 18)
                .shadow(color: .black.opacity(theme.scheme == .dark ? 0.3 : 0.07), radius: 8, y: 3)
            Text(b.title).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
        }
    }
}
