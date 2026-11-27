import Foundation
import SwiftUI
import WebKit
import UIKit

/// Detects touches without ever interfering with WebKit (used to tell user-opened popups from scripted ones).
final class TouchTracker: UIGestureRecognizer {
    var onTouch: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?(); state = .failed }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var store: BrowserStore?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        let wv = m.webView
        Task { @MainActor in self.store?.tabs.first { $0.webView === wv }?.handle(type, body) }
    }
}

@MainActor
final class Tab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let isPrivate: Bool
    unowned let store: BrowserStore

    @Published var title = ""
    @Published var url: URL?
    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var tint: Color?
    @Published var favicon: UIImage?
    @Published var thumbnail: UIImage?
    @Published var showingCachedCopy = false
    @Published var note: String?
    @Published var secure = false
    @Published var group: String?
    @Published var zoom = 100

    private(set) var webView: WKWebView?
    var restoreState: Data?
    var restoreURL: URL?
    private var adoptedConfig: WKWebViewConfiguration?
    private var observers: [NSKeyValueObservation] = []
    private var lastTouch = Date.distantPast
    private var loadingArchive = false
    private var healed = Set<String>()
    private var allowInsecure = Set<String>()
    private var lastY: CGFloat = 0
    private weak var refresh: UIRefreshControl?
    private var showingError = false
    private var errorLoadPending = false
    private var failedURL: URL?

    init(store: BrowserStore, id: UUID = UUID(), isPrivate: Bool, url: URL? = nil, title: String = "", config: WKWebViewConfiguration? = nil) {
        self.store = store; self.id = id; self.isPrivate = isPrivate
        self.url = url; self.title = title; self.adoptedConfig = config
        super.init()
        restoreURL = url
    }

    var displayTitle: String { title.isEmpty ? (url?.displayHost ?? "新标签页") : title }
    var isBlank: Bool { url == nil && webView?.url == nil }

    // MARK: web view

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let w = webView { return w }
        let s = store.settings
        let cfg = adoptedConfig ?? makeConfig()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        adoptedConfig = nil
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.scrollView.decelerationRate = .normal
        wv.overrideUserInterfaceStyle = s.theme.scheme == .dark ? .dark : .light
        #if DEBUG
        wv.isInspectable = true
        #endif

        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pulled), for: .valueChanged)
        wv.scrollView.refreshControl = rc
        refresh = rc

        let tt = TouchTracker()
        tt.onTouch = { [weak self] in self?.lastTouch = Date() }
        tt.cancelsTouchesInView = false; tt.delaysTouchesBegan = false; tt.delaysTouchesEnded = false
        wv.addGestureRecognizer(tt)

        observers = [
            wv.observe(\.estimatedProgress) { [weak self] w, _ in let v = w.estimatedProgress; Task { @MainActor in self?.progress = v } },
            wv.observe(\.isLoading) { [weak self] w, _ in let v = w.isLoading; Task { @MainActor in self?.isLoading = v; if !v { self?.refresh?.endRefreshing() } } },
            wv.observe(\.canGoBack) { [weak self] w, _ in let v = w.canGoBack; Task { @MainActor in self?.canGoBack = v } },
            wv.observe(\.canGoForward) { [weak self] w, _ in let v = w.canGoForward; Task { @MainActor in self?.canGoForward = v } },
            wv.observe(\.title) { [weak self] w, _ in let v = w.title; Task { @MainActor in if let v, !v.isEmpty { self?.title = v } } },
            wv.observe(\.url) { [weak self] w, _ in let v = w.url; Task { @MainActor in if let v, v.scheme != "about" { self?.url = v } } },
            wv.observe(\.hasOnlySecureContent) { [weak self] w, _ in let v = w.hasOnlySecureContent; Task { @MainActor in self?.secure = v } },
            wv.observe(\.themeColor) { [weak self] w, _ in let c = w.themeColor; Task { @MainActor in if let c { self?.tint = Color(uiColor: c) } } },
            wv.scrollView.observe(\.contentOffset) { [weak self] sv, _ in
                let y = sv.contentOffset.y, drag = sv.isDragging || sv.isDecelerating
                Task { @MainActor in self?.scrolled(y, dragging: drag) }
            },
        ]
        webView = wv
        if let st = restoreState { wv.interactionState = st; restoreState = nil }
        else if let u = restoreURL { restoreURL = nil; navigate(u) }
        return wv
    }

    private func makeConfig() -> WKWebViewConfiguration {
        let s = store.settings
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store.dataStore(isPrivate: isPrivate)
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        let ucc = WKUserContentController()
        ucc.add(store.scriptHandler, contentWorld: NativeAdapter.world, name: "luno")
        ucc.addUserScript(NativeAdapter.userScript(native: s.prefs.nativeMode, hideCookies: s.prefs.hideCookieBanners))
        store.extensions.userScripts().forEach { ucc.addUserScript($0) }
        if s.prefs.blockTrackers, let list = store.blocker.list { ucc.add(list) }
        cfg.userContentController = ucc
        return cfg
    }

    func suspend() {   // free memory for background tabs, keep history + scroll
        guard let wv = webView, !isLoading else { return }
        restoreState = wv.interactionState as? Data
        observers.removeAll()
        wv.stopLoading(); wv.removeFromSuperview()
        webView = nil
    }

    func captureState() -> Data? { (webView?.interactionState as? Data) ?? restoreState }

    // MARK: navigation

    func navigate(_ url: URL) {
        self.url = url
        let wv = ensureWebView()
        note = nil
        showingCachedCopy = false
        Task {
            let hint = Task { try? await Task.sleep(nanoseconds: 800_000_000); if !Task.isCancelled { self.note = "正在检测网络…" } }
            let route = await store.router.prepare(for: url)
            hint.cancel()
            note = route == .proxy ? "已通过服务器加速" : nil
            wv.load(URLRequest(url: url))
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { if webView?.url == nil, let u = url { navigate(u) } else { webView?.reloadFromOrigin() } }
    func stop() { webView?.stopLoading() }
    @objc private func pulled() { reload() }

    func setZoom(_ pct: Int) {
        zoom = max(50, min(300, pct))
        webView?.evaluateJavaScript("document.documentElement.style.webkitTextSizeAdjust='\(zoom)%'", completionHandler: nil)
    }

    func toggleDesktop() {
        store.settings.updateSite(url?.host) { $0.desktop.toggle() }
        webView?.reload()
    }
    var isDesktop: Bool { store.settings.site(url?.host).desktop }

    // MARK: page content helpers (isolated world)

    func js(_ code: String) async -> Any? {
        guard let wv = webView else { return nil }
        return try? await wv.evaluateJavaScript(code, in: nil, contentWorld: NativeAdapter.world)
    }
    func pageText() async -> String { (await js("window.__luno ? window.__luno.text().slice(0,60000) : ''") as? String) ?? "" }
    func snapshot() async -> (text: String, sensitive: Set<Int>)? {
        guard let d = await js("window.__luno.snapshot()") as? [String: Any], let t = d["text"] as? String else { return nil }
        let s = (d["sensitive"] as? [Int]) ?? []
        return (t, Set(s))
    }
    func run(_ a: AgentAction) async -> String {
        var obj: [String: Any] = ["type": a.type]
        if let v = a.id { obj["id"] = v }
        if let v = a.text { obj["text"] = v }
        if let v = a.dy { obj["dy"] = v }
        if let v = a.submit { obj["submit"] = v }
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "error" }
        return (await js("window.__luno.run(\(s))") as? String) ?? "error"
    }
    func readerContent() async -> (title: String, html: String)? {
        guard let d = await js("window.__luno.reader()") as? [String: Any], let h = d["html"] as? String else { return nil }
        return ((d["title"] as? String) ?? title, h)
    }

    func find(_ text: String, backwards: Bool = false, _ done: @escaping (Bool) -> Void) {
        guard let wv = webView, !text.isEmpty else { return done(false) }
        let c = WKFindConfiguration(); c.backwards = backwards; c.wraps = true; c.caseSensitive = false
        wv.find(text, configuration: c) { done($0.matchFound) }
    }

    // MARK: messages from the isolated-world adapter

    func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "meta":
            if let t = body["title"] as? String, !t.isEmpty { title = t }
            if let c = (body["themeColor"] as? String).flatMap(Tab.parseColor) ?? (body["bg"] as? String).flatMap(Tab.parseColor) { tint = Color(uiColor: c) }
            if let icon = (body["icon"] as? String).flatMap(URL.init(string:)), let host = url?.host { store.loadFavicon(icon, host: host) { [weak self] img in self?.favicon = img } }
        default: break
        }
    }

    static func parseColor(_ s: String) -> UIColor? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") {
            var h = String(t.dropFirst()); if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
            return UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        if t.hasPrefix("rgb") {
            let nums = t.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            guard nums.count >= 3 else { return nil }
            if nums.count >= 4, nums[3] < 0.05 { return nil }
            return UIColor(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: 1)
        }
        return nil
    }

    // MARK: scroll -> collapse chrome

    private func scrolled(_ y: CGFloat, dragging: Bool) {
        defer { lastY = y }
        guard dragging, y > 40 else { if y <= 40 { store.setBars(collapsed: false) }; return }
        let dy = y - lastY
        if dy > 14 { store.setBars(collapsed: true) } else if dy < -10 { store.setBars(collapsed: false) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.cancel, preferences) }
        if action.shouldPerformDownload { return (.download, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https": break
        case "about": return (.allow, preferences)
        case "lunox-action":
            // Only the built-in error page may trigger these.
            if showingError, let u = failedURL {
                if url.host == "retry" { healed.removeAll(); navigate(u) }
                else if url.host == "http" {
                    allowInsecure.insert(u.host ?? "")
                    var c = URLComponents(url: u, resolvingAgainstBaseURL: false); c?.scheme = "http"
                    if let n = c?.url { navigate(n) }
                }
            }
            return (.cancel, preferences)
        case "blob": return (.allow, preferences)
        case "data": return (action.targetFrame?.isMainFrame == false ? .allow : .cancel, preferences)
        case "tel", "mailto", "sms", "facetime", "maps", "itms-apps", "itms-appss":
            if action.navigationType == .linkActivated || Date().timeIntervalSince(lastTouch) < 2 { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
            return (.cancel, preferences)
        default: return (.cancel, preferences)      // javascript:, file:, unknown app schemes
        }
        let isMain = action.targetFrame?.isMainFrame ?? true
        guard isMain else { return (.allow, preferences) }

        let host = url.host ?? ""
        let local = host == "localhost" || host.hasSuffix(".local") || host.range(of: #"^[\d.]+$"#, options: .regularExpression) != nil
        if scheme == "http", store.settings.prefs.httpsOnly, !local, !allowInsecure.contains(host) {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false); c?.scheme = "https"
            if let up = c?.url { navigate(up); return (.cancel, preferences) }
        }
        let site = store.settings.site(host)
        preferences.allowsContentJavaScript = site.javascript
        preferences.preferredContentMode = site.desktop ? .desktop : .mobile
        if action.navigationType != .backForward { _ = await store.router.prepare(for: url) }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let r = response.response as? HTTPURLResponse, (r.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { store.downloads.attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { store.downloads.attach(download) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !loadingArchive { showingCachedCopy = false }
        if errorLoadPending { errorLoadPending = false } else { showingError = false }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let u = webView.url, u.scheme != "about" { url = u }
        if loadingArchive { showingCachedCopy = true }
        favicon = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let wasArchive = loadingArchive
        loadingArchive = false
        guard let u = webView.url, u.scheme == "http" || u.scheme == "https" else { return }
        url = u
        if !isPrivate { store.recordVisit(url: u, title: webView.title ?? title) }
        store.persistSoon()
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.webView === webView, webView.url == u else { return }
            let cfg = WKSnapshotConfiguration(); cfg.snapshotWidth = 340
            webView.takeSnapshot(with: cfg) { [weak self] img, _ in Task { @MainActor in self?.thumbnail = img } }
            if !isPrivate, !wasArchive, store.settings.prefs.offlineCache, !showingCachedCopy {
                store.offline.limitBytes = store.settings.prefs.offlineLimitMB * 1024 * 1024
                store.offline.save(url: u, title: webView.title ?? title, from: webView)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    private func fail(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && [100, 101, 102].contains(ns.code) { return }   // handled by policy / download
        guard let failed = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url else { return }
        let offline = ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorDataNotAllowed || ns.code == NSURLErrorInternationalRoamingOff
        let connectish: Set<Int> = [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                                    NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed]
        if ns.domain == NSURLErrorDomain, connectish.contains(ns.code), !offline, let host = failed.host {
            let dom = URLResolver.registrableDomain(host)
            // The direct probe said "fine" but the real load failed: switch this site to the server proxy and retry once.
            if store.settings.prefs.routing == .auto, store.settings.gatewayConfigured, !healed.contains(dom), store.router.proxied[dom] == nil {
                healed.insert(dom); store.router.markBlocked(dom); note = "直连失败，已改走服务器…"
                webView?.load(URLRequest(url: failed)); return
            }
        }
        if ns.domain == NSURLErrorDomain, offline || connectish.contains(ns.code), let data = store.offline.data(for: failed) {
            loadingArchive = true; url = failed
            webView?.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: failed)
            return
        }
        showError(error, failed)
    }

    private func showError(_ error: Error, _ failed: URL) {
        let msg = (error as NSError).localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        let httpOption = (failed.scheme == "https" && store.settings.prefs.httpsOnly)
            ? "<a class=g href=\"lunox-action://http\">改用 HTTP（不安全）</a>" : ""
        let html = """
        <meta name=viewport content="width=device-width,initial-scale=1"><style>
        :root{color-scheme:light dark}body{font:16px -apple-system,system-ui;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;background:Canvas;color:CanvasText}
        .c{max-width:340px;padding:32px;text-align:center}h1{font-size:22px;margin:0 0 8px}p{opacity:.6;line-height:1.5;margin:0 0 24px;word-break:break-word}
        a{display:inline-block;font:600 16px -apple-system;text-decoration:none;border-radius:999px;padding:13px 28px;background:#4F63FF;color:#fff;margin:4px}a.g{background:transparent;color:inherit;opacity:.6}
        </style><div class=c><h1>无法打开页面</h1><p>\(failed.displayHost)<br>\(msg)</p>
        <a href="lunox-action://retry">重试</a>\(httpOption)</div>
        """
        failedURL = failed
        showingError = true; errorLoadPending = true
        webView?.loadHTMLString(html, baseURL: failed)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest else { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        return await withCheckedContinuation { cont in
            let a = UIAlertController(title: "登录 \(host)", message: nil, preferredStyle: .alert)
            a.addTextField { $0.placeholder = "用户名"; $0.autocapitalizationType = .none }
            a.addTextField { $0.placeholder = "密码"; $0.isSecureTextEntry = true }
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in cont.resume(returning: (.cancelAuthenticationChallenge, nil)) })
            a.addAction(UIAlertAction(title: "登录", style: .default) { _ in
                let c = URLCredential(user: a.textFields?[0].text ?? "", password: a.textFields?[1].text ?? "", persistence: self.isPrivate ? .none : .forSession)
                cont.resume(returning: (.useCredential, c))
            })
            UIApplication.shared.topVC?.present(a, animated: true)
        }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let userInitiated = action.navigationType == .linkActivated || Date().timeIntervalSince(lastTouch) < 2
        if store.settings.prefs.blockPopups && !userInitiated { Haptics.warn(); return nil }
        // Hand WebKit a real web view so window.opener (OAuth sign-in popups) keeps working.
        return store.newTab(configuration: configuration, isPrivate: isPrivate).ensureWebView()
    }

    func webViewDidClose(_ webView: WKWebView) { store.close(self) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let a = UIAlertController(title: webView.url?.displayHost, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in c.resume() })
            present(a) { c.resume() }
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let a = UIAlertController(title: webView.url?.displayHost, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in c.resume(returning: false) })
            a.addAction(UIAlertAction(title: "确定", style: .default) { _ in c.resume(returning: true) })
            present(a) { c.resume(returning: false) }
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let a = UIAlertController(title: webView.url?.displayHost, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText }
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in c.resume(returning: nil) })
            a.addAction(UIAlertAction(title: "确定", style: .default) { _ in c.resume(returning: a.textFields?.first?.text) })
            present(a) { c.resume(returning: nil) }
        }
    }
    private func present(_ a: UIAlertController, fallback: () -> Void) {
        if let top = UIApplication.shared.topVC { top.present(a, animated: true) } else { fallback() }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host
        let wantsCam = type != .microphone, wantsMic = type != .camera
        let s = store.settings.site(host)
        if (wantsCam && s.camera == false) || (wantsMic && s.microphone == false) { return .deny }
        if (!wantsCam || s.camera == true) && (!wantsMic || s.microphone == true) { return .grant }
        let what = type == .camera ? "相机" : type == .microphone ? "麦克风" : "相机和麦克风"
        return await withCheckedContinuation { cont in
            let a = UIAlertController(title: "\(host) 想使用\(what)", message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in cont.resume(returning: .deny) })
            a.addAction(UIAlertAction(title: "允许一次", style: .default) { _ in cont.resume(returning: .grant) })
            a.addAction(UIAlertAction(title: "总是允许", style: .default) { _ in
                self.store.settings.updateSite(host) { if wantsCam { $0.camera = true }; if wantsMic { $0.microphone = true } }
                cont.resume(returning: .grant)
            })
            if let top = UIApplication.shared.topVC { top.present(a, animated: true) } else { cont.resume(returning: .deny) }
        }
    }
}

extension UIApplication {
    var topVC: UIViewController? {
        func top(_ v: UIViewController) -> UIViewController { v.presentedViewController.map(top) ?? v }
        let w = connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        return w?.rootViewController.map(top)
    }
}
