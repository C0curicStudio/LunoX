import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    @State private var searching = false
    @State private var showMenu = false
    @State private var showSite = false
    @State private var showFind = false
    @State private var menuDetent: PresentationDetent = .medium
    @State private var showNews = false
    @State private var showStartEdit = false
    @State private var newsStart: NewsSection = .explore
    @State private var showHero = false
    @State private var menuRoute: MenuRoute?
    @Namespace private var ns
    @Namespace private var heroNS

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if let tab = store.current {
                TabContent(tab: tab).id(tab.id).ignoresSafeArea()
                    .scaleEffect(store.showSwitcher ? 0.9 : 1).blur(radius: store.showSwitcher ? 8 : 0)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            if showHero, let t = store.current { HeroSnapshot(tab: t, ns: heroNS).zIndex(1) }

            VStack(spacing: 8) {
                StatusPills()
                if let t = store.current { TranslateBanner(tab: t) }
                if let t = store.current { StuckChip(tab: t) { menuRoute = .diagnostics; showMenu = true } }
                Spacer()
                if let tab = store.current {
                    if showFind { FindBar(tab: tab) { withAnimation(.snappy) { showFind = false } }.transition(.move(edge: .bottom).combined(with: .opacity)) }
                    BottomChrome(tab: tab, ns: ns, searching: searching,
                                 onSearch: openSearch, onSite: { showSite = true }, onMenu: { showMenu = true }, onTabs: openSwitcher,
                                 onReader: { menuRoute = .reader; showMenu = true },
                                 onTranslate: { if tab.translated { tab.showOriginal() } else { Task { await tab.translate() } } })
                }
            }
            .padding(.bottom, 2).zIndex(2)

            if searching, let tab = store.current {
                SearchOverlay(tab: tab, ns: ns) { withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { searching = false } }
                    .transition(.opacity).zIndex(3)
            }
            if store.showSwitcher {
                TabSwitcher(ns: heroNS, pick: pickTab).transition(.opacity).zIndex(4)
            }
        }
        .translationHost(store.translator.coord, enabled: !showNews)
        .animation(Motion.smooth, value: store.selectedID)
        .animation(Motion.hero, value: store.showSwitcher)
        .onChange(of: store.searchRequest) { _, _ in openSearch() }
        .onChange(of: store.newsRequest) { _, _ in showNews = true }
        .onChange(of: store.startEditRequest) { _, _ in showStartEdit = true }
        .fullScreenCover(isPresented: $showNews) {
            NewsView(start: newsStart,
                     onClose: { showNews = false },
                     onOpen: { u in showNews = false; store.open(u.absoluteString) },
                     onSearch: { showNews = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openSearch() } },
                     onSettings: { showNews = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { menuRoute = .settings; showMenu = true } })
        }
        .sheet(isPresented: $showStartEdit) { StartPageEditor().presentationDetents([.large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $showMenu, onDismiss: { menuRoute = nil; menuDetent = .medium }) {
            MenuSheet(onFind: { withAnimation(.snappy) { showFind = true } }, initialRoute: menuRoute, onDeep: { menuDetent = .large },
                      onNews: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNews = true } },
                      onStartEdit: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showStartEdit = true } })
                .presentationDetents([.medium, .large], selection: $menuDetent).presentationDragIndicator(.visible)
        }
        #if DEBUG
        .task { await runDemo() }
        #endif
        .sheet(isPresented: $showSite) {
            if let t = store.current { SiteInfoView(tab: t).presentationDetents([.medium]).presentationDragIndicator(.visible) }
        }
    }

    @ViewBuilder private var background: some View {
        if let t = store.current, !t.isBlank, let c = t.tint { c } else { theme.background }
    }

    private func openSearch() {
        Haptics.soft()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { searching = true }
    }

    /// The live page shrinks into its tab card (a snapshot stands in for the web view while it moves).
    private func openSwitcher() {
        guard let t = store.current, !store.showSwitcher else { return }
        Haptics.soft()
        Task {
            await t.captureHero()
            showHero = true
            try? await Task.sleep(nanoseconds: 40_000_000)
            withAnimation(Motion.hero) { showHero = false; store.showSwitcher = true }
        }
    }

    /// The chosen card grows back to full screen, then the live page takes over.
    private func pickTab(_ t: Tab) {
        store.selectTab(t)
        withAnimation(Motion.hero) { store.showSwitcher = false; showHero = true }
        Task { try? await Task.sleep(nanoseconds: 600_000_000); showHero = false }
    }
}

/// Hosts the tab's WKWebView, or the native new-tab page.
struct TabContent: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        if let r = tab.template {
            if r.platform.isSocial { SocialTemplateView(tab: tab, route: r).id(r.url) } else { TemplateView(tab: tab, route: r).id(r.url) }
        }
        else if tab.isBlank { NewTabView() } else { WebContainer(tab: tab) }
    }
}

struct WebContainer: UIViewRepresentable {
    @ObservedObject var tab: Tab
    func makeUIView(context: Context) -> UIView { let v = UIView(); v.backgroundColor = .clear; attach(v); return v }
    func updateUIView(_ v: UIView, context: Context) { attach(v) }
    private func attach(_ host: UIView) {
        let wv = tab.ensureWebView()
        guard wv.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        wv.frame = host.bounds
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.scrollView.contentInset.bottom = 118
        wv.scrollView.verticalScrollIndicatorInsets.bottom = 118
        host.addSubview(wv)
    }
}

struct StatusPills: View {
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        VStack(spacing: 6) {
            if !store.online { PillView(icon: "wifi.slash", text: "离线 · 可打开 \(store.offline.pages.count) 个已缓存页面") }
            if let t = store.current { TabNotes(tab: t) }
        }
        .padding(.top, 54)
        .animation(Motion.snappy, value: store.online)
        .allowsHitTesting(false)
    }
}

private struct TabNotes: View {
    @ObservedObject var tab: Tab
    var body: some View {
        VStack(spacing: 6) {
            if tab.showingCachedCopy { PillView(icon: "clock.arrow.circlepath", text: "离线副本") }
            if let n = tab.note { PillView(icon: "bolt.horizontal.circle", text: n) }
        }
        .animation(Motion.bouncy, value: tab.note)
        .animation(Motion.snappy, value: tab.showingCachedCopy)
    }
}

private struct PillView: View {
    var icon: String
    var text: String
    @Environment(\.theme) private var theme
    var body: some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(theme.ink).padding(.horizontal, 12).padding(.vertical, 7)
            .lunoGlass(Capsule(), interactive: false)
            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .scale(scale: 0.8)).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9))))
    }
}

struct FindBar: View {
    @ObservedObject var tab: Tab
    var close: () -> Void
    @State private var text = ""
    @State private var found = true
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSoft)
            TextField("在页面中查找", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).onSubmit { tab.find(text) { found = $0 } }
                .onChange(of: text) { _, v in tab.find(v) { found = $0 } }
            if !found && !text.isEmpty { Text("无结果").font(.caption).foregroundStyle(.red) }
            Button { tab.find(text, backwards: true) { found = $0 } } label: { Image(systemName: "chevron.up") }
            Button { tab.find(text) { found = $0 } } label: { Image(systemName: "chevron.down") }
            Button("完成", action: close).fontWeight(.semibold)
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 16).frame(height: 46)
        .lunoGlass(Capsule()).padding(.horizontal, 16)
    }
}

#if DEBUG
/// Screenshot automation: `simctl launch … -demo <screen> -theme <id>` (never compiled into Release/IPA).
enum Demo {
    static func value(_ k: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-\(k)"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    @MainActor static func apply(to s: Settings) {
        if let t = value("theme") { s.prefs.themeID = t }
        if let a = value("appearance") { s.prefs.appearance = a == "dark" ? .dark : .light }
        if value("demo") != nil { s.prefs.restoreTabs = false; s.prefs.appLock = false }
    }
}
extension Demo {
    static let fixedBarPage = #"""
    <html><body style="margin:0;font:16px -apple-system;background:#fff;color:#111">
    <div style="padding:24px"><h1>Demo page</h1><p>This page has no viewport meta tag and its own bottom tab bar glued to the screen edge.
    The adapter should make it fill the phone, lift the bar above the toolbar and, in dark mode, invert it.</p>
    <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>
    <input placeholder="small input" style="font-size:12px;padding:6px;width:60%"></div>
    <div style="position:fixed;left:0;right:0;bottom:0;height:56px;background:#f2f2f7;border-top:1px solid #ccc;display:flex;justify-content:space-around;align-items:center">
    <span>Home</span><span>Search</span><span>Cart</span><span>Me</span></div></body></html>
    """#
}
extension RootView {
    @MainActor func settingsBG(_ id: String) { settings.prefs.startBackground = id }
    @MainActor func runDemo() async {
        guard let d = Demo.value("demo") else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        switch d {
        case "web":
            store.open(Demo.value("url") ?? "https://en.wikipedia.org/wiki/Cloudflare")
        case "web2":
            store.open("https://example.com"); try? await Task.sleep(nanoseconds: 6_000_000_000); showMenu = true
        case "search": searching = true
        case "switcher":
            store.newTab(url: URL(string: "https://example.com")); try? await Task.sleep(nanoseconds: 5_000_000_000)
            store.newTab(); store.showSwitcher = true
        case "news": showNews = true
        case "startedit": showStartEdit = true
        case "startbg": settingsBG(Demo.value("bg") ?? "dunes")
        case "private": store.newTab(isPrivate: true)
        case "fixedbar":    // page with its own bottom bar and no viewport meta: exercises the adapter
            let t = store.newTab(url: URL(string: "https://demo.lunox/"))
            t.ensureWebView().loadHTMLString(Demo.fixedBarPage, baseURL: URL(string: "https://demo.lunox/"))
        case "menu": showMenu = true
        case "find": showFind = true
        default:
            if let r = ["bookmarks": MenuRoute.bookmarks, "history": .history, "downloads": .downloads, "offline": .offline,
                        "extensions": .extensions, "themes": .themes, "settings": .settings, "ai": .ai][d] { menuRoute = r; showMenu = true }
        }
    }
}
#endif

/// Appears when a page has been blank for 10s: one tap to the connection diagnostics.
struct StuckChip: View {
    @ObservedObject var tab: Tab
    var action: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        if tab.stuck {
            Button(action: action) {
                Label("加载很慢？点此检查连接", systemImage: "stethoscope").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 9).lunoGlass(Capsule())
            }.buttonStyle(PressableStyle()).transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Safari-style offer shown once a foreign-language page has been recognised.
struct TranslateBanner: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    var body: some View {
        if tab.canTranslate && !tab.translated && !tab.translateDismissed, let l = tab.pageLang {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble").foregroundStyle(theme.accent)
                Text("此页面为\(LanguageUtil.name(l))").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(theme.ink)
                Button { Task { await tab.translate() } } label: {
                    Text(tab.translating ? "翻译中…" : "翻译成\(LanguageUtil.name(settings.translateTarget))").font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6).background(theme.accent, in: Capsule())
                }.buttonStyle(PressableStyle(scale: 0.92)).disabled(tab.translating)
                Button { Haptics.tap(); withAnimation(.snappy) { tab.dismissTranslateBanner() } } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.inkSoft).frame(width: 40, height: 40).contentShape(Rectangle())
                }.buttonStyle(PressableStyle(scale: 0.85))
            }
            .padding(.leading, 14).padding(.trailing, 2).padding(.vertical, 2)
            .lunoGlass(Capsule()).transition(.move(edge: .top).combined(with: .opacity))
            .gesture(DragGesture(minimumDistance: 8).onEnded { g in if g.translation.height < -10 { withAnimation(.snappy) { tab.dismissTranslateBanner() } } })
        }
    }
}
