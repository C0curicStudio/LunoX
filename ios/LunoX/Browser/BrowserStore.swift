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
        bookmarks = bookmarksFile.load([])
        history = historyFile.load([])
        scriptHandler.store = self
        router.register(normalStore)
        router.register(privateStore)
        monitor.pathUpdateHandler = { [weak self] p in Task { @MainActor in self?.online = p.status == .satisfied } }
        monitor.start(queue: .global(qos: .utility))
        Task { await blocker.prepare() ; restore() }
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
        t.ensureWebView()
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

    func setBars(collapsed: Bool) {
        guard barsCollapsed != collapsed else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { barsCollapsed = collapsed }
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

    // MARK: favicons

    func loadFavicon(_ icon: URL, host: String, _ done: @escaping (UIImage?) -> Void) {
        if let i = favicons[host] { done(i); return }
        Task {
            var img: UIImage?
            if let (d, _) = try? await URLSession.shared.data(from: icon), let i = UIImage(data: d) { img = i }
            else if settings.gatewayConfigured, let d = await gateway.favicon(host: host) { img = UIImage(data: d) }
            if let img { favicons[host] = img }
            done(img)
        }
    }
    func icon(for host: String) -> UIImage? { favicons[host] }

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
                tabs.append(t)
            }
            if let sel = tabs.first(where: { $0.id == s.selected }) ?? tabs.last { selectTab(sel) }
        } else {
            newTab()
        }
        if let hp = URL(string: settings.prefs.homepage), !settings.prefs.homepage.isEmpty, current?.isBlank == true { current?.navigate(hp) }
        if settings.prefs.syncBookmarks { Task { await sync() } }
    }

    // MARK: data

    func clearBrowsingData(history h: Bool, website: Bool, offline o: Bool) async {
        if h { clearHistory() }
        if o { offline.clear() }
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
