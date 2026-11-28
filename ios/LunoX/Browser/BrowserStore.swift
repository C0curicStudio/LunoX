import Foundation
import SwiftUI
import WebKit
import Network

struct ClosedTab: Identifiable { let id = UUID(); let url: URL; let title: String }

struct SavedTab: Codable { var id: UUID; var url: URL?; var title: String; var state: Data?; var group: String? }
struct SavedSession: Codable { var tabs: [SavedTab]; var selected: UUID? }

@MainActor
final class BrowserStore: ObservableObject {
    let settings: Settings
    let router: Router
    let gateway: GatewayClient
    let edge: EdgeSelector
    let translator: Translator
    let hy2 = Hy2Manager()
    let fingerprintHandler = FingerprintHandler()
    let news: NewsStore
    @Published var newsRequest = 0
    private(set) lazy var templates = TemplateService(engine: NewsEngine(gateway: gateway, router: router, settings: settings))
    @Published var startEditRequest = 0
    let offline = OfflineCache()
    let downloads = DownloadManager()
    let extensions = ExtensionManager()
    let blocker = ContentBlocker()
    let scriptHandler = ScriptHandler()

    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    @Published var showSwitcher = false
    @Published var barsCollapsed = false
    @Published var online = true
    @Published var bookmarks: [Bookmark]
    @Published var history: [HistoryItem]
    @Published var recentlyClosed: [ClosedTab] = []
    @Published var syncStatus = ""
    @Published var searchRequest = 0
    @Published private(set) var faviconRev = 0
    private(set) var webStyle: UIUserInterfaceStyle = .unspecified
    private(set) var isDark = false
    private(set) var accentHex = "#0A84FF"
    private(set) var pageBackdrop = Color.white
    private var warmView: WKWebView?
    private let favDir = Paths.dir("Favicons", excludeFromBackup: true)
    private var missingIcons = Set<String>()

    private let bookmarksFile = JSONFile<[Bookmark]>("bookmarks.json")
    private let historyFile = JSONFile<[HistoryItem]>("history.json")
    private let sessionFile = JSONFile<SavedSession>("session.json")
    private let monitor = NWPathMonitor()
    private let normalStore = WKWebsiteDataStore.default()
    private var privateStore = WKWebsiteDataStore.nonPersistent()
    private var favicons: [String: UIImage] = [:]
    private var persistTask: Task<Void, Never>?
    private var recency: [UUID] = []

    init() {
        let s = Settings()
        settings = s
        router = Router(settings: s)
        gateway = GatewayClient(settings: s)
        edge = EdgeSelector(settings: s, gateway: gateway)
        translator = Translator(gateway: gateway)
        news = NewsStore(gateway: gateway, settings: s, router: router)
        ImageStore.shared.gateway = gateway
        ImageStore.shared.router = router
        bookmarks = bookmarksFile.load([])
        history = historyFile.load([])
        scriptHandler.store = self
        fingerprintHandler.store = self
        router.edge = edge
        router.hy2 = hy2
        gateway.hy2 = hy2
        edge.hy2 = hy2
        hy2.onChange = { [weak self] in self?.router.apply() }
        news.translate = { [weak self] texts, source in await self?.translator.translate(texts, source: source, target: LanguageUtil.target(self?.settings.prefs.translateTarget ?? "")) }
        router.gateway = gateway
        edge.onChange = { [weak self] in self?.router.apply() }
        router.register(normalStore)
        router.register(privateStore)
        monitor.pathUpdateHandler = { [weak self] p in Task { @MainActor in self?.online = p.status == .satisfied } }
        monitor.start(queue: .global(qos: .utility))
        #if DEBUG
        Demo.apply(to: s)
        #endif
        warmUp()
        Task { await blocker.prepare() ; restore() }
        Task { [weak self] in                                   // keep picking the fastest route into the server
            while let self {
                await self.edge.measure()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    var current: Tab? { tabs.first { $0.id == selectedID } }
    var normalTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [Tab] { tabs.filter(\.isPrivate) }

    func dataStore(isPrivate: Bool) -> WKWebsiteDataStore { isPrivate ? privateStore : normalStore }

    // MARK: tabs

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false, select: Bool = true) -> Tab {
        if isPrivate && privateTabs.isEmpty {      // a fresh private session starts with an empty, non-persistent store
            privateStore = .nonPersistent(); router.register(privateStore)
        }
        let t = Tab(store: self, isPrivate: isPrivate, url: url)
        tabs.append(t)
        if select { selectTab(t) }
        persistSoon()
        return t
    }

    /// Popup created by WebKit (window.open): the configuration must be used as given.
    func newTab(configuration: WKWebViewConfiguration, isPrivate: Bool) -> Tab {
        let t = Tab(store: self, isPrivate: isPrivate, config: configuration)
        tabs.append(t); selectTab(t)
        return t
    }

    func selectTab(_ t: Tab) {
        selectedID = t.id
        recency.removeAll { $0 == t.id }; recency.append(t.id)
        barsCollapsed = false
        if t.template == nil { t.ensureWebView() }
        // Keep the 6 most recent web views alive, park the rest (like Chrome's tab discarding).
        let keep = Set(recency.suffix(6))
        for o in tabs where !keep.contains(o.id) { o.suspend() }
        persistSoon()
    }

    func close(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        if !t.isPrivate, let u = t.url { recentlyClosed.insert(ClosedTab(url: u, title: t.displayTitle), at: 0); recentlyClosed = Array(recentlyClosed.prefix(10)) }
        t.suspend()
        tabs.remove(at: i)
        recency.removeAll { $0 == t.id }
        if selectedID == t.id {
            let sameKind = tabs.filter { $0.isPrivate == t.isPrivate }
            if let next = sameKind.last ?? tabs.last { selectTab(next) } else { selectedID = nil }
        }
        if tabs.isEmpty { newTab() }
        persistSoon()
    }

    func reopenClosed() {
        guard let c = recentlyClosed.first else { return }
        recentlyClosed.removeFirst(); newTab(url: c.url)
    }

    func closeAll(private p: Bool) {
        for t in tabs where t.isPrivate == p { t.suspend() }
        tabs.removeAll { $0.isPrivate == p }
        if tabs.isEmpty { newTab() } else if current == nil, let t = tabs.last { selectTab(t) }
        persistSoon()
    }

    /// One entry point for every pairing link (clipboard, paste box, tapped link): gateway + built-in Hysteria2.
    @discardableResult
    func applyPairing(_ url: URL) -> Bool {
        guard settings.applySetupLink(url) else { return false }
        if let c = settings.pendingHy2 { settings.pendingHy2 = nil; hy2.update(c) }
        router.apply()
        if settings.gatewayConfigured { Task { await edge.measure(force: true) } }
        return true
    }

    func setBars(collapsed: Bool, force: Bool = false) {
        guard barsCollapsed != collapsed else { return }
        if !collapsed, settings.prefs.compactBar, !force { return }      // "always compact": only a tap on the pill opens it
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { barsCollapsed = collapsed }
        current?.syncInset()
    }

    /// Spin up WebKit's web-content + networking processes before the first page is requested.
    private func warmUp() {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = normalStore
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.loadHTMLString("<html></html>", baseURL: nil)
        warmView = w
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); warmView = nil }
    }

    func applyTheme(_ t: Theme) {
        isDark = t.scheme == .dark; accentHex = t.accent.hexString; pageBackdrop = t.bgBottom
        tabs.forEach {
            $0.webView?.underPageBackgroundColor = UIColor(t.bgBottom)
            $0.webView?.backgroundColor = UIColor(t.bgBottom)
            $0.applyLook(dark: settings.prefs.autoDarkPages && isDark, accent: accentHex)
        }
    }

    // MARK: omnibox

    func open(_ input: String) {
        guard let url = URLResolver.resolve(input, engine: settings.engine) else { return }
        if let t = current { t.navigate(url) } else { newTab(url: url) }
    }

    // MARK: history & bookmarks

    func recordVisit(url: URL, title: String) {
        let s = url.absoluteString
        if history.first?.url == s { return }
        history.insert(HistoryItem(title: title.isEmpty ? url.displayHost : title, url: s), at: 0)
        if history.count > 3000 { history.removeLast(history.count - 3000) }
        historyFile.save(history)
    }
    func clearHistory() { history = []; historyFile.save(history) }
    func removeHistory(_ h: HistoryItem) { history.removeAll { $0.id == h.id }; historyFile.save(history) }

    func isBookmarked(_ url: URL?) -> Bool { url.map { u in bookmarks.contains { $0.url == u.absoluteString } } ?? false }
    func toggleBookmark(_ t: Tab?) {
        guard let t, let u = t.url else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == u.absoluteString }) { bookmarks.remove(at: i) }
        else { bookmarks.insert(Bookmark(title: t.displayTitle, url: u.absoluteString), at: 0); Haptics.ok() }
        bookmarksFile.save(bookmarks)
    }
    func saveBookmarks() { bookmarksFile.save(bookmarks) }

    // MARK: local-first search suggestions (direct first, server only if that fails)

    func suggest(_ q: String, engine: SearchEngine) async -> [String] {
        if let local = await Self.localSuggest(q, key: engine.suggestKey), !local.isEmpty { return local }
        guard settings.gatewayConfigured else { return [] }
        return await gateway.suggest(q, engine: engine.suggestKey)
    }

    nonisolated static func localSuggest(_ q: String, key: String) async -> [String]? {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let urls = ["google": "https://suggestqueries.google.com/complete/search?client=firefox&q=\(enc)",
                    "bing": "https://api.bing.com/osjson.aspx?query=\(enc)",
                    "duckduckgo": "https://duckduckgo.com/ac/?type=list&q=\(enc)",
                    "baidu": "https://suggestion.baidu.com/su?action=opensearch&wd=\(enc)"]
        guard let u = urls[key].flatMap(URL.init(string:)) else { return nil }
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]; c.timeoutIntervalForRequest = 1.5; c.waitsForConnectivity = false
        let sess = URLSession(configuration: c); defer { sess.finishTasksAndInvalidate() }
        guard let (d, _) = try? await sess.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [Any], j.count > 1, let arr = j[1] as? [String] else { return nil }
        return Array(arr.prefix(8))
    }

    // MARK: favicons

    func loadFavicon(_ icon: URL, host: String, _ done: @escaping (UIImage?) -> Void) {
        if let i = self.icon(for: host) { done(i); return }
        Task {
            var img: UIImage?
            for u in [icon, URL(string: "https://\(host)/favicon.ico")].compactMap({ $0 }) {
                if let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, let i = UIImage(data: d) { img = i; break }
            }
            if img == nil, settings.gatewayConfigured, let d = await gateway.favicon(host: host) { img = UIImage(data: d) }
            if let img { store(img, host: host) }
            done(img)
        }
    }
    private func store(_ img: UIImage, host: String) {
        favicons[host] = img; missingIcons.remove(host); faviconRev += 1
        if let d = img.pngData() { let f = favDir.appendingPathComponent(host.sha256Hex); DispatchQueue.global(qos: .utility).async { try? d.write(to: f) } }
    }
    /// Icons are cached in memory and on disk, so tabs and favorites show them instantly (and offline).
    func icon(for host: String) -> UIImage? {
        if let i = favicons[host] { return i }
        if missingIcons.contains(host) { return nil }
        if let d = try? Data(contentsOf: favDir.appendingPathComponent(host.sha256Hex)), let i = UIImage(data: d) { favicons[host] = i; return i }
        missingIcons.insert(host); return nil
    }
    func ensureIcon(host: String) {
        guard icon(for: host) == nil, let u = URL(string: "https://\(host)/favicon.ico") else { return }
        missingIcons.remove(host)
        loadFavicon(u, host: host) { _ in }
    }

    func applyAppearance(_ a: Appearance) {
        webStyle = a == .system ? .unspecified : (a == .dark ? .dark : .light)
        tabs.forEach { $0.webView?.overrideUserInterfaceStyle = webStyle }
    }

    // MARK: persistence

    func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { try? await Task.sleep(nanoseconds: 600_000_000); if !Task.isCancelled { persistNow() } }
    }
    func persistNow() {
        let saved = normalTabs.map { SavedTab(id: $0.id, url: $0.url, title: $0.title, state: $0.captureState(), group: $0.group) }
        sessionFile.save(SavedSession(tabs: saved, selected: current?.isPrivate == false ? selectedID : saved.last?.id))
    }
    private func restore() {
        let s = sessionFile.load(SavedSession(tabs: [], selected: nil))
        if settings.prefs.restoreTabs, !s.tabs.isEmpty {
            for st in s.tabs {
                let t = Tab(store: self, id: st.id, isPrivate: false, url: st.url, title: st.title)
                t.restoreState = st.state; t.group = st.group
                if settings.prefs.nativeTemplates, let u = st.url, let r = TemplateRoute.match(u) { t.template = r; t.restoreState = nil }
                tabs.append(t)
            }
            if let sel = tabs.first(where: { $0.id == s.selected }) ?? tabs.last { selectTab(sel) }
        } else {
            newTab()
        }
        if let hp = URL(string: settings.prefs.homepage), !settings.prefs.homepage.isEmpty, current?.isBlank == true { current?.navigate(hp) }
        if settings.prefs.syncBookmarks { Task { await sync() } }
        if settings.prefs.nativeTemplates { templates.warmUp() }
        news.warmUp()
    }

    // MARK: data

    func clearBrowsingData(history h: Bool, website: Bool, offline o: Bool) async {
        if h { clearHistory() }
        if o { offline.clear() }
        if h || website { TranslationCache.shared.clear() }
        if website { FingerprintGuard.rotateSecret() }
        if website {
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            router.reset()
        }
    }

    // MARK: sync (end-to-end encrypted; the server only sees ciphertext)

    func sync() async {
        guard settings.gatewayConfigured else { syncStatus = "服务器未配置"; return }
        do {
            var merged = bookmarks
            if let d = try await gateway.pullSync(bucket: "bookmarks"), let remote = try? JSONDecoder().decode([Bookmark].self, from: d) {
                for r in remote where !merged.contains(where: { $0.url == r.url }) { merged.append(r) }
                merged.sort { $0.date > $1.date }
            }
            bookmarks = merged; saveBookmarks()
            try await gateway.pushSync(bucket: "bookmarks", json: try JSONEncoder().encode(merged))
            syncStatus = "已同步 \(merged.count) 个书签"
        } catch { syncStatus = "同步失败：\(error.localizedDescription)" }
    }
}
