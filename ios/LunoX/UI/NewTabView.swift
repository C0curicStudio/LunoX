import SwiftUI

struct NewTabView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var offline: OfflineCache
    @Environment(\.theme) private var theme
    @State private var appear = false

    private var favorites: [Bookmark] { Array(store.bookmarks.prefix(8)) }
    private var isPrivate: Bool { store.current?.isPrivate == true }

    var body: some View {
        ZStack {
            theme.background
            Circle().fill(theme.glow.opacity(0.35)).frame(width: 340).blur(radius: 90).offset(x: 90, y: -230)
            Circle().fill(theme.accent.opacity(0.18)).frame(width: 260).blur(radius: 80).offset(x: -120, y: 120)
            ScrollView {
                VStack(spacing: 34) {
                    VStack(spacing: 8) {
                        Image(systemName: isPrivate ? "eyeglasses" : "moon.stars.fill")
                            .font(.system(size: 34, weight: .light)).foregroundStyle(theme.accent)
                        Text(isPrivate ? "隐私浏览" : "LunoX")
                            .font(.system(size: 40, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                        Text(isPrivate ? "关闭所有隐私标签页后，记录与 Cookie 会被丢弃。" : greeting)
                            .font(.system(size: 14, design: .rounded)).foregroundStyle(theme.inkSoft).multilineTextAlignment(.center)
                    }.padding(.top, 110)

                    if !isPrivate && !favorites.isEmpty {
                        section("收藏") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 18) {
                                ForEach(favorites) { b in
                                    Button { store.open(b.url) } label: { tile(b.title, URL(string: b.url)?.host) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !isPrivate && !offline.pages.isEmpty {
                        section("离线可读") {
                            VStack(spacing: 0) {
                                ForEach(offline.pages.prefix(4)) { p in
                                    Button { store.open(p.url) } label: {
                                        HStack {
                                            Image(systemName: "arrow.down.circle").foregroundStyle(theme.accent)
                                            Text(p.title).lineLimit(1).font(.system(size: 15, design: .rounded)).foregroundStyle(theme.ink)
                                            Spacer()
                                        }.padding(.horizontal, 16).padding(.vertical, 13)
                                    }.buttonStyle(.plain)
                                }
                            }.lunoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
                        }
                    }
                    Spacer(minLength: 160)
                }
                .padding(.horizontal, 20)
                .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 14)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appear = true } }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 6 ? "夜深了，早点休息" : h < 12 ? "早上好" : h < 18 ? "下午好" : "晚上好"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.inkSoft).padding(.leading, 6)
            c()
        }
    }

    private func tile(_ title: String, _ host: String?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.accent.opacity(0.14))
                if let h = host, let img = store.icon(for: h) { Image(uiImage: img).resizable().scaledToFit().frame(width: 28, height: 28) }
                else { Text(String(title.prefix(1)).uppercased()).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(theme.accent) }
            }.frame(width: 58, height: 58)
            Text(title).font(.system(size: 11, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
        }
    }
}
