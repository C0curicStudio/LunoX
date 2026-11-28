import SwiftUI
import WebKit

/// The native page that stands in for a templated website. Same chrome, fonts and motion as the rest of the app.
struct TemplateView: View {
    @ObservedObject var tab: Tab
    let route: TemplateRoute
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @State private var items: [TItem] = []
    @State private var related: [TItem] = []
    @State private var detail: TDetail?
    @State private var loading = true
    @State private var failed = false
    @State private var query = ""
    @State private var expandDesc = false
    @FocusState private var searchFocus: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch route.kind {
                case .feed(let q): feedHeader(q)
                case .watch(let id): watchHeader(id)
                }
                let list = isWatch ? related : items
                if loading && list.isEmpty { skeleton }
                else if failed && list.isEmpty { failure }
                else {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                        Card(item: it, index: i) { open(it) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 58).padding(.bottom, 150)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background.ignoresSafeArea())
        .simultaneousGesture(DragGesture(minimumDistance: 28).onChanged { g in
            if abs(g.translation.height) > abs(g.translation.width) { store.setBars(collapsed: g.translation.height < 0) }
        })
        .refreshable { await load(force: true) }
        .task(id: route.url) { await load(force: false) }
    }

    private var isWatch: Bool { if case .watch = route.kind { return true } else { return false } }

    // MARK: headers

    private func feedHeader(_ q: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: route.platform.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(route.platform.tint)
                Text(q ?? route.platform.name).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(1)
                Spacer()
                webButton
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSoft)
                TextField("在\(route.platform.name)搜索", text: $query).focused($searchFocus).submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { let t = query.trimmingCharacters(in: .whitespaces); guard !t.isEmpty, let r = TemplateRoute.search(route.platform, t) else { return }; searchFocus = false; Haptics.soft(); tab.navigate(r.url) }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkSoft) } }
            }
            .padding(.horizontal, 14).frame(height: 44).background(theme.surface, in: Capsule())
            if q == nil {
                Text(route.platform == .youtube ? "热门" : "热门视频").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.inkSoft)
            }
        }.padding(.bottom, 16)
    }

    private func watchHeader(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(); webButton }
            player(id).aspectRatio(16.0 / 9.0, contentMode: .fit).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            if let d = detail {
                Text(d.title).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
                HStack(spacing: 10) {
                    RemoteImage(url: d.avatar).frame(width: 34, height: 34).clipShape(Circle()).opacity(d.avatar == nil ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.author).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                        if !d.meta.isEmpty { Text(d.meta).font(.system(size: 12, design: .rounded)).foregroundStyle(theme.inkSoft) }
                    }
                    Spacer()
                }
                if !d.desc.isEmpty {
                    Text(d.desc).font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(expandDesc ? nil : 3)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture { Haptics.tap(); withAnimation(Motion.snappy) { expandDesc.toggle() } }
                }
            } else if loading {
                RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(height: 22).padding(.top, 6)
                RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(width: 160, height: 14)
            }
            Text("更多视频").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).padding(.top, 8)
        }.padding(.bottom, 8)
    }

    @ViewBuilder private func player(_ id: String) -> some View {
        switch route.platform {
        case .youtube: YouTubeView(id: id, autoplay: true, controls: true, mute: false, dataStore: store.dataStore(isPrivate: tab.isPrivate)).id(id)
        case .bilibili: EmbedPlayer(url: URL(string: "https://player.bilibili.com/player.html?bvid=\(id)&autoplay=1&high_quality=1&danmaku=0")!, dataStore: store.dataStore(isPrivate: tab.isPrivate)).id(id)
        }
    }

    private var webButton: some View {
        Button { Haptics.tap(); tab.navigate(route.url, forceWeb: true) } label: {
            Label("原网页", systemImage: "safari").font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).frame(height: 32).background(theme.surface, in: Capsule()).foregroundStyle(theme.accent)
        }.buttonStyle(PressableStyle(scale: 0.92))
    }

    private var skeleton: some View {
        VStack(spacing: 22) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.surface).aspectRatio(16.0 / 9.0, contentMode: .fit)
                    HStack(spacing: 10) {
                        Circle().fill(theme.surface).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 5).fill(theme.surface).frame(height: 14)
                            RoundedRectangle(cornerRadius: 5).fill(theme.surface).frame(width: 140, height: 11)
                        }
                    }
                }
            }
        }.opacity(0.8).phaseAnimator([0.45, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
    }

    private var failure: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 34, weight: .light)).foregroundStyle(theme.inkSoft)
            Text("暂时取不到内容").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
            HStack(spacing: 10) {
                Button("重试") { Task { await load(force: true) } }.buttonStyle(.borderedProminent).tint(theme.accent)
                Button("打开原网页") { tab.navigate(route.url, forceWeb: true) }.buttonStyle(.bordered).tint(theme.accent)
            }
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: data

    private func open(_ it: TItem) {
        guard let r = TemplateRoute.watch(it.platform, it.id) else { return }
        Haptics.soft(); tab.navigate(r.url)
    }

    private func load(force: Bool) async {
        failed = false
        let svc = store.templates
        switch route.kind {
        case .feed(let q):
            // paint the last good copy at once, then refresh behind it
            if items.isEmpty, let c = TemplateCache.load(TemplateCache.feedKey(route.platform, q)) { items = c.items; loading = false } else { loading = items.isEmpty }
            tab.title = (q ?? route.platform.name) + " – " + route.platform.name
            tab.templateReady(thumb: items.first?.thumb)
            let r = await svc.feed(route.platform, query: q)
            if !r.isEmpty { withAnimation(Motion.smooth) { items = r }; tab.templateReady(thumb: r.first?.thumb) }
            failed = items.isEmpty
        case .watch(let id):
            if detail == nil, let c = TemplateCache.load(TemplateCache.watchKey(route.platform, id)) { detail = c.detail; related = c.items; loading = false } else { loading = detail == nil && related.isEmpty }
            if let t = detail?.title { tab.title = t }
            if route.platform == .youtube { tab.templateReady(thumb: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
            let got = await svc.detail(route.platform, id: id)
            withAnimation(Motion.smooth) { if let g = got { detail = g.0; if !g.1.isEmpty { related = g.1 } } }
            if let t = got?.0.title { tab.title = t }
            if got?.1.isEmpty ?? true {
                let rel = await svc.related(route.platform, id: id, title: got?.0.title ?? detail?.title ?? "")
                if !rel.isEmpty { withAnimation(Motion.smooth) { related = rel } }
            }
            TemplateCache.save(TemplateCache.watchKey(route.platform, id), items: related, detail: detail)
            failed = detail == nil && related.isEmpty
        }
        loading = false
    }

    private struct Card: View {
        let item: TItem
        let index: Int
        let tap: () -> Void
        @State private var on = false
        @Environment(\.theme) private var theme
        var body: some View {
            Button(action: tap) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        RemoteImage(url: item.thumb).aspectRatio(16.0 / 9.0, contentMode: .fit).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        if let d = item.duration {
                            Text(d).font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.72), in: Capsule()).padding(8)
                        }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        RemoteImage(url: item.avatar).frame(width: 36, height: 36).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(2).multilineTextAlignment(.leading)
                            Text([item.author, item.meta].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }.padding(.bottom, 22).contentShape(Rectangle())
            }.buttonStyle(PressableStyle(scale: 0.975)).staggered(index, on).onAppear { on = true }
        }
    }
}

struct EmbedPlayer: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true; cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = dataStore
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false; w.backgroundColor = .black; w.scrollView.backgroundColor = .black
        w.scrollView.isScrollEnabled = false; w.scrollView.pinchGestureRecognizer?.isEnabled = false
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}
