import SwiftUI
import WebKit
import AVKit

/// Swipe in from the left edge = back, like every other screen of the app.
struct EdgeSwipeBack: ViewModifier {
    @ObservedObject var tab: Tab
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Color.clear.frame(width: 24).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 14).onEnded { g in
                    if g.translation.width > 70, abs(g.translation.height) < 90, tab.canGoBack || tab.template != nil { Haptics.tap(); tab.goBack() }
                })
        }
    }
}
extension View { func edgeSwipeBack(_ tab: Tab) -> some View { modifier(EdgeSwipeBack(tab: tab)) } }

/// The native page that stands in for a templated website, laid out like the real app: search, tabs, two-column cards, endless scroll.
struct TemplateView: View {
    @ObservedObject var tab: Tab
    let route: TemplateRoute
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme

    private struct Feed { var items: [TItem] = []; var page = 0; var done = false; var loading = false; var failed = false }
    @State private var feeds: [String: Feed] = [:]
    @State private var sectionID = ""
    @State private var related: [TItem] = []
    @State private var detail: TDetail?
    @State private var loading = true
    @State private var failed = false
    @State private var query = ""
    @State private var expandDesc = false
    @FocusState private var searchFocus: Bool
    @Namespace private var tabNS

    private var isWatch: Bool { if case .watch = route.kind { return true } else { return false } }
    private var searchQuery: String? { if case .feed(let q) = route.kind { return q } else { return nil } }
    private var sections: [TSection] { searchQuery == nil ? route.platform.sections : [] }
    private var current: TSection? { sections.first { $0.id == sectionID } ?? sections.first }
    private var feedKey: String { searchQuery.map { "q:\($0)" } ?? (current?.id ?? "home") }
    private var items: [TItem] { feeds[feedKey]?.items ?? [] }
    private let cols = [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if isWatch { watchPart } else { feedPart }
            }
            .padding(.horizontal, isWatch ? 16 : 8).padding(.top, 54).padding(.bottom, 150)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background.ignoresSafeArea())
        .simultaneousGesture(DragGesture(minimumDistance: 28).onChanged { g in
            if abs(g.translation.height) > abs(g.translation.width) { store.setBars(collapsed: g.translation.height < 0) }
        })
        .refreshable { await reload() }
        .task(id: route.url) { await start() }
        .edgeSwipeBack(tab)
    }

    // MARK: feed (home / search)

    @ViewBuilder private var feedPart: some View {
        topBar
        if !sections.isEmpty { tabsBar }
        let list = items
        if list.isEmpty {
            if feeds[feedKey]?.failed == true { failure } else { skeleton }
        } else {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                    GridCard(item: it, index: i) { open(it) }
                        .onAppear { if i >= list.count - 4 { Task { await loadMore() } } }
                }
            }
            if feeds[feedKey]?.loading == true { ProgressView().frame(maxWidth: .infinity).padding(22) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: route.platform.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(route.platform.tint)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSoft)
                TextField(searchQuery ?? "在\(route.platform.name)搜索", text: $query).focused($searchFocus).submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { let t = query.trimmingCharacters(in: .whitespaces); guard !t.isEmpty, let r = TemplateRoute.search(route.platform, t) else { return }; searchFocus = false; Haptics.soft(); tab.navigate(r.url) }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkSoft) } }
            }
            .padding(.horizontal, 14).frame(height: 40).background(theme.surface, in: Capsule())
            webButton
        }.padding(.horizontal, 6).padding(.bottom, 8)
    }

    private var tabsBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(sections) { s in
                        Button {
                            Haptics.tap(); withAnimation(Motion.snappy) { sectionID = s.id }
                            Task { await ensureLoaded() }
                        } label: {
                            VStack(spacing: 5) {
                                Text(s.title).font(.system(size: 16, weight: (current?.id == s.id) ? .bold : .medium, design: .rounded))
                                    .foregroundStyle((current?.id == s.id) ? route.platform.tint : theme.inkSoft)
                                ZStack {
                                    Capsule().fill(Color.clear).frame(width: 18, height: 3)
                                    if current?.id == s.id { Capsule().fill(route.platform.tint).frame(width: 18, height: 3).matchedGeometryEffect(id: "ul", in: tabNS) }
                                }
                            }
                        }.buttonStyle(.plain).id(s.id)
                    }
                }.padding(.horizontal, 10)
            }.padding(.bottom, 8)
            .onChange(of: sectionID) { _, id in withAnimation(Motion.smooth) { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    // MARK: watch

    @ViewBuilder private var watchPart: some View {
        if case .watch(let id) = route.kind {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Spacer(); webButton }
                player(id).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    if !d.desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, d.desc.trimmingCharacters(in: .whitespacesAndNewlines) != "-" {
                        Text(d.desc).font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(expandDesc ? nil : 3)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onTapGesture { Haptics.tap(); withAnimation(Motion.snappy) { expandDesc.toggle() } }
                    }
                } else if loading {
                    RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(height: 22).padding(.top, 6)
                    RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(width: 160, height: 14)
                }
                Text("更多视频").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).padding(.top, 8)
                if related.isEmpty && loading { skeleton }
                else if related.isEmpty && failed { failure }
                else {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(Array(related.enumerated()), id: \.element.id) { i, it in GridCard(item: it, index: i) { open(it) } }
                    }
                }
            }.padding(.bottom, 8)
        }
    }

    @ViewBuilder private func player(_ id: String) -> some View {
        switch route.platform {
        case .youtube: YouTubeView(id: id, autoplay: true, controls: true, mute: false, dataStore: store.dataStore(isPrivate: tab.isPrivate)).id(id).aspectRatio(16.0 / 9.0, contentMode: .fit)
        case .bilibili: BiliPlayer(bvid: id, dataStore: store.dataStore(isPrivate: tab.isPrivate)).id(id)
        case .x, .instagram: EmptyView()
        }
    }

    private var webButton: some View {
        Button { Haptics.tap(); tab.navigate(route.url, forceWeb: true) } label: {
            Label("原网页", systemImage: "safari").font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).frame(height: 32).background(theme.surface, in: Capsule()).foregroundStyle(theme.accent)
        }.buttonStyle(PressableStyle(scale: 0.92))
    }

    private var skeleton: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface).aspectRatio(16.0 / 10.0, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 5).fill(theme.surface).frame(height: 13)
                    RoundedRectangle(cornerRadius: 5).fill(theme.surface).frame(width: 90, height: 11)
                }
            }
        }.phaseAnimator([0.45, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
    }

    private var failure: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 34, weight: .light)).foregroundStyle(theme.inkSoft)
            Text("暂时取不到内容").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
            HStack(spacing: 10) {
                Button("重试") { Task { await reload() } }.buttonStyle(.borderedProminent).tint(theme.accent)
                Button("打开原网页") { tab.navigate(route.url, forceWeb: true) }.buttonStyle(.bordered).tint(theme.accent)
            }
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: data

    private func open(_ it: TItem) {
        guard let r = TemplateRoute.watch(it.platform, it.id) else { return }
        Haptics.soft(); tab.navigate(r.url)
    }

    private func start() async {
        if isWatch { await loadWatch(); return }
        if sectionID.isEmpty { sectionID = sections.first?.id ?? "" }
        tab.title = (searchQuery ?? route.platform.name) + " – " + route.platform.name
        await ensureLoaded()
    }

    private func ensureLoaded() async {
        if let f = feeds[feedKey], !f.items.isEmpty || f.loading { return }
        // instant paint from the last session, then refresh
        let ck = TemplateCache.feedKey(route.platform, feedKey)
        if let c = TemplateCache.load(ck), !c.items.isEmpty { feeds[feedKey] = Feed(items: c.items, page: 1, done: false, loading: false, failed: false) }
        await fetch(page: 1, replace: true)
    }

    private func reload() async {
        if isWatch { await loadWatch(); return }
        feeds[feedKey] = Feed(items: feeds[feedKey]?.items ?? [], page: 0, done: false, loading: false, failed: false)
        await fetch(page: 1, replace: true)
    }

    private func loadMore() async {
        guard let f = feeds[feedKey], !f.loading, !f.done, f.page >= 1 else { return }
        await fetch(page: f.page + 1, replace: false)
    }

    private func fetch(page: Int, replace: Bool) async {
        let key = feedKey
        var f = feeds[key] ?? Feed(); f.loading = true; f.failed = false; feeds[key] = f
        let sec = current ?? TSection(id: "q", title: "", kind: .home)
        let got = await store.templates.page(route.platform, section: sec, page: page, query: searchQuery)
        var n = feeds[key] ?? Feed()
        n.loading = false
        if replace {
            if !got.isEmpty { withAnimation(Motion.smooth) { n.items = got }; n.page = 1; TemplateCache.save(TemplateCache.feedKey(route.platform, key), items: got) }
            else if n.items.isEmpty { n.failed = true }
        } else {
            let known = Set(n.items.map(\.id))
            let fresh = got.filter { !known.contains($0.id) }
            if fresh.isEmpty { n.done = got.isEmpty || page > 40 } else { withAnimation(Motion.smooth) { n.items += fresh } }
            n.page = page
        }
        feeds[key] = n
        if replace, let first = n.items.first?.thumb { tab.templateReady(thumb: first) }
        // a page that is too short to scroll would never ask for more: top it up
        if !replace, !n.done, n.items.count < 12 { await loadMore() }
    }

    private func loadWatch() async {
        guard case .watch(let id) = route.kind else { return }
        failed = false
        if detail == nil, let c = TemplateCache.load(TemplateCache.watchKey(route.platform, id)) { detail = c.detail; related = c.items; loading = false } else { loading = detail == nil && related.isEmpty }
        if let t = detail?.title { tab.title = t }
        if route.platform == .youtube { tab.templateReady(thumb: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
        let got = await store.templates.detail(route.platform, id: id)
        withAnimation(Motion.smooth) { if let g = got { detail = g.0; if !g.1.isEmpty { related = g.1 } } }
        if let t = got?.0.title { tab.title = t }
        if got?.1.isEmpty ?? true {
            let rel = await store.templates.related(route.platform, id: id, title: got?.0.title ?? detail?.title ?? "")
            if !rel.isEmpty { withAnimation(Motion.smooth) { related = rel } }
        }
        TemplateCache.save(TemplateCache.watchKey(route.platform, id), items: related, detail: detail)
        failed = detail == nil && related.isEmpty
        loading = false
    }
}

/// A card of the two-column grid, laid out like the real apps: cover with play count / comments / duration, two-line title, author.
struct GridCard: View {
    let item: TItem
    let index: Int
    let tap: () -> Void
    @State private var on = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay { RemoteImage(url: item.thumb) }
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 10) {
                            ForEach(Array(statParts.enumerated()), id: \.offset) { _, p in
                                Label(p.1, systemImage: p.0).labelStyle(.titleAndIcon).font(.system(size: 11, weight: .medium, design: .rounded))
                            }
                            Spacer(minLength: 0)
                            if let d = item.duration { Text(d).font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()) }
                        }
                        .foregroundStyle(.white).padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 6)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                    .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2)
                HStack(spacing: 5) {
                    Text(item.author).font(.system(size: 12, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.inkSoft.opacity(0.7)).rotationEffect(.degrees(90))
                }.padding(.horizontal, 2)
            }
            .padding(.bottom, 4).contentShape(Rectangle())
        }.buttonStyle(PressableStyle(scale: 0.97)).staggered(index % 8, on).onAppear { on = true }
    }

    /// "154,460 次观看 · 2 天前" / "12.3万播放 · 4567弹幕" -> small icon + number chips
    private var statParts: [(String, String)] {
        let parts = item.meta.components(separatedBy: " · ").filter { !$0.isEmpty }
        var out: [(String, String)] = []
        if let a = parts.first { out.append(("play.rectangle", a.replacingOccurrences(of: "次观看", with: "").replacingOccurrences(of: "播放", with: "").replacingOccurrences(of: " views", with: ""))) }
        if parts.count > 1, item.platform == .bilibili { out.append(("text.bubble", parts[1].replacingOccurrences(of: "弹幕", with: ""))) }
        return out
    }
}

/// The system player (controls, speed, AirPlay, Picture in Picture, pinch to fill) in SwiftUI.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer?
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player; c.allowsPictureInPicturePlayback = true; c.videoGravity = .resizeAspect; c.updatesNowPlayingInfoCenter = false
        c.view.backgroundColor = .black
        return c
    }
    func updateUIViewController(_ c: AVPlayerViewController, context: Context) { if c.player !== player { c.player = player } }
}

/// Bilibili with the system player: the best quality the account allows, full screen with rotation, pinch to fill, Picture in Picture.
/// The frame follows the video (vertical videos are tall, not a letterboxed strip). Falls back to the embedded web player.
struct BiliPlayer: View {
    let bvid: String
    let dataStore: WKWebsiteDataStore
    @EnvironmentObject var store: BrowserStore
    @State private var player: AVPlayer?
    @State private var qualities: [(Int, String)] = []
    @State private var quality = 0
    @State private var fellBack = false
    @State private var aspect: CGFloat = 16.0 / 9.0
    @State private var full = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if player != nil { SystemPlayer(player: full ? nil : player) }
            else if fellBack { EmbedPlayer(url: URL(string: "https://player.bilibili.com/player.html?bvid=\(bvid)&autoplay=1&high_quality=1&danmaku=0")!, dataStore: dataStore) }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if player != nil {
                HStack(spacing: 8) {
                    if qualities.count > 1 {
                        Menu {
                            ForEach(qualities.indices, id: \.self) { i in Button(qualities[i].1) { Task { await load(qn: qualities[i].0) } } }
                        } label: { chip { Text(label) } }
                    }
                    Button { Haptics.soft(); full = true } label: { chip { Image(systemName: "arrow.up.left.and.arrow.down.right") } }
                }.padding(8)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .animation(Motion.smooth, value: aspect)
        .task { try? AVAudioSession.sharedInstance().setCategory(.playback); await load(qn: 120) }
        .onDisappear { player?.pause() }
        .fullScreenCover(isPresented: $full) {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                SystemPlayer(player: full ? player : nil).ignoresSafeArea()
                Button { full = false } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
                }.padding(16)
            }
        }
    }

    private func chip<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
            .frame(minWidth: 30, minHeight: 28).padding(.horizontal, 6).background(.black.opacity(0.55), in: Capsule())
    }
    private var label: String { qualities.first { $0.0 == quality }?.1.components(separatedBy: " ").last ?? "画质" }

    private func load(qn: Int) async {
        let cookie = await store.templates.cookieHeader(dataStore, domain: "bilibili.com")
        guard let s = await store.templates.biliStream(bvid: bvid, cookie: cookie, qn: qn) else { if player == nil { fellBack = true }; return }
        let t = player?.currentTime()
        let asset = AVURLAsset(url: s.url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Referer": "https://www.bilibili.com/", "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 12
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        if let t, t.isValid, t.seconds > 1 { await p.seek(to: t) }
        p.play()
        player = p; qualities = s.qualities; quality = s.quality
        for _ in 0..<30 {                                   // shape the frame after the video once its size is known
            try? await Task.sleep(nanoseconds: 250_000_000)
            let z = item.presentationSize
            if z.width > 0, z.height > 0 { aspect = min(max(z.width / z.height, 0.66), 1.78); break }
        }
    }
}

struct EmbedPlayer: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true; cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true            // makes the player's full-screen button work
        cfg.websiteDataStore = dataStore
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false; w.backgroundColor = .black; w.scrollView.backgroundColor = .black
        w.scrollView.isScrollEnabled = false; w.scrollView.pinchGestureRecognizer?.isEnabled = false
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}
