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
    @State private var demoRoute: MenuRoute?
    @Namespace private var ns

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if let tab = store.current { TabContent(tab: tab).id(tab.id).ignoresSafeArea() }

            VStack(spacing: 8) {
                StatusPills()
                Spacer()
                if let tab = store.current {
                    if showFind { FindBar(tab: tab) { withAnimation(.snappy) { showFind = false } } }
                    BottomChrome(tab: tab, ns: ns, searching: searching,
                                 onSearch: { Haptics.soft(); withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { searching = true } },
                                 onSite: { showSite = true }, onMenu: { showMenu = true })
                }
            }
            .padding(.bottom, 2)

            if searching, let tab = store.current {
                SearchOverlay(tab: tab, ns: ns) { withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { searching = false } }
                    .transition(.opacity)
            }
            if store.showSwitcher {
                TabSwitcher().transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: store.showSwitcher)
        .sheet(isPresented: $showMenu) {
            MenuSheet(onFind: { withAnimation(.snappy) { showFind = true } }, initialRoute: demoRoute).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
}

/// Hosts the tab's WKWebView, or the native new-tab page.
struct TabContent: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        if tab.isBlank { NewTabView() } else { WebContainer(tab: tab) }
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
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 6) {
            if !store.online {
                pill("wifi.slash", "离线 · 可打开 \(store.offline.pages.count) 个已缓存页面")
            }
            if let t = store.current, t.showingCachedCopy { pill("clock.arrow.circlepath", "离线副本") }
            if let n = store.current?.note { pill("bolt.horizontal.circle", n) }
        }
        .padding(.top, 54)
        .animation(.snappy, value: store.online)
        .allowsHitTesting(false)
    }
    private func pill(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(theme.ink).padding(.horizontal, 12).padding(.vertical, 7)
            .lunoGlass(Capsule(), interactive: false).transition(.move(edge: .top).combined(with: .opacity))
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
        if value("demo") != nil { s.prefs.restoreTabs = false; s.prefs.appLock = false }
    }
}
extension RootView {
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
        case "private": store.newTab(isPrivate: true)
        case "menu": showMenu = true
        case "find": showFind = true
        default:
            if let r = ["bookmarks": MenuRoute.bookmarks, "history": .history, "downloads": .downloads, "offline": .offline,
                        "extensions": .extensions, "themes": .themes, "settings": .settings, "ai": .ai][d] { demoRoute = r; showMenu = true }
        }
    }
}
#endif
