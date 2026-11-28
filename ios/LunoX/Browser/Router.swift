import Foundation
import Network
import WebKit

/// "Direct first, server proxy second."
/// Before a host is loaded we probe it directly (short timeout). If it can't be reached the host's
/// domain is added to the proxy match-list of every WKWebsiteDataStore, so WebKit tunnels it through
/// the gateway's HTTPS CONNECT proxy. Everything else keeps going direct.
@MainActor
final class Router: ObservableObject {
    private let settings: Settings
    @Published private(set) var proxied: [String: Date] = [:]     // registrable domain -> since
    private var verdicts: [String: (ok: Bool, at: Date)] = [:]
    private var inflight: [String: Task<Probe, Never>] = [:]
    private var stores: [WeakStore] = []
    private let file = JSONFile<[String: Date]>("proxied.json")
    var edge: EdgeSelector?
    var gateway: GatewayClient?
    var hy2: Hy2Manager?

    private struct WeakStore { weak var s: WKWebsiteDataStore? }

    /// Sites whose sub-resources live on other domains; proxying the main site must cover them too.
    static let companions: [String: [String]] = [
        "google.com": ["gstatic.com", "googleapis.com", "googleusercontent.com", "ggpht.com", "gvt1.com", "google.com.hk"],
        "youtube.com": ["googlevideo.com", "ytimg.com", "youtube-nocookie.com", "ggpht.com", "gstatic.com", "googleapis.com", "youtu.be", "google.com"],
        "facebook.com": ["fbcdn.net", "fb.com", "facebook.net"],
        "instagram.com": ["cdninstagram.com", "fbcdn.net"],
        "twitter.com": ["twimg.com", "t.co", "x.com"],
        "x.com": ["twimg.com", "t.co", "twitter.com"],
        "wikipedia.org": ["wikimedia.org", "wikimedia.org"],
        "github.com": ["githubassets.com", "githubusercontent.com", "github.io"],
        "reddit.com": ["redd.it", "redditstatic.com", "redditmedia.com"],
        "telegram.org": ["t.me", "telegram.me", "cdn-telegram.org"],
        "openai.com": ["oaistatic.com", "oaiusercontent.com", "chatgpt.com"],
        "chatgpt.com": ["oaistatic.com", "oaiusercontent.com", "openai.com"],
        "medium.com": ["medium.com", "cdn-images-1.medium.com"],
        "netflix.com": ["nflxvideo.net", "nflximg.net", "nflxext.com"],
    ]

    // MARK: policy groups (like a proxy app's strategy groups)

    struct PolicyGroup: Identifiable {
        let id: String
        let name: String
        let note: String
        let icon: String
        let defaultMode: RouteMode
        let domains: [String]
    }

    /// Order matters only for display; a domain belongs to the first group that lists it.
    /// Principle: a site should always be seen from the same place. Domestic and payment/login sites are never sent through the overseas server
    /// (their risk systems flag datacenter addresses and address changes); blocked foreign sites always use the server (one fixed exit address).
    static let groups: [PolicyGroup] = [
        PolicyGroup(id: "cn", name: "国内平台", note: "永远直连：国内网站用国外出口容易被风控", icon: "house", defaultMode: .direct, domains: [
            "baidu.com", "bdstatic.com", "qq.com", "weixin.com", "wechat.com", "gtimg.com", "qpic.cn", "zhihu.com", "zhimg.com", "taobao.com", "tmall.com", "alipay.com", "alicdn.com", "aliyun.com",
            "jd.com", "360buyimg.com", "douyin.com", "douyinpic.com", "toutiao.com", "bytedance.com", "byteimg.com", "xiaohongshu.com", "xhscdn.com", "163.com", "126.net", "netease.com",
            "weibo.com", "sinaimg.cn", "bilibili.com", "hdslb.com", "bilivideo.com", "b23.tv", "iqiyi.com", "youku.com", "mgtv.com", "kuaishou.com", "ixigua.com",
            "kimi.ai", "kimi.com", "moonshot.cn", "deepseek.com", "doubao.com", "volcengine.com", "bigmodel.cn", "aliyuncs.com", "tencent.com", "tencentcloud.com", "huawei.com",
            "meituan.com", "dianping.com", "ctrip.com", "csdn.net", "cnblogs.com", "juejin.cn", "36kr.com", "xiaomi.com", "mi.com", "oppo.com", "vivo.com", "sohu.com", "ifeng.com", "douban.com"]),
        PolicyGroup(id: "pay", name: "账号与支付", note: "登录、支付对 IP 变化最敏感：一律直连", icon: "creditcard", defaultMode: .direct, domains: [
            "unionpay.com", "icbc.com.cn", "ccb.com", "boc.cn", "abchina.com", "cmbchina.com", "bankcomm.com", "paypal.com", "stripe.com", "wise.com",
            "apple.com", "icloud.com", "microsoft.com", "live.com", "office.com", "microsoftonline.com", "windows.net"]),
        PolicyGroup(id: "open", name: "国外可直连", note: "国外但国内能访问：直连更快也更稳", icon: "globe.asia.australia", defaultMode: .direct, domains: [
            "amazon.com", "cloudflare.com", "jsdelivr.net", "unpkg.com", "npmjs.com", "pypi.org", "python.org", "mozilla.org", "nvidia.com", "adobe.com",
            "stackoverflow.com", "stackexchange.com", "docker.com", "gitlab.com", "swift.org", "steampowered.com", "gravatar.com", "w3.org"]),
        PolicyGroup(id: "social", name: "国外社交与视频", note: "被墙：固定走你的服务器（同一个出口地址）", icon: "play.rectangle", defaultMode: .proxy, domains: [
            "youtube.com", "googlevideo.com", "ytimg.com", "youtube-nocookie.com", "youtu.be", "facebook.com", "fbcdn.net", "fb.com", "facebook.net", "instagram.com", "cdninstagram.com",
            "twitter.com", "twimg.com", "t.co", "x.com", "telegram.org", "t.me", "telegram.me", "discord.com", "discord.gg", "discordapp.com", "reddit.com", "redd.it", "redditstatic.com", "redditmedia.com",
            "tiktok.com", "twitch.tv", "netflix.com", "nflxvideo.net", "spotify.com", "pinterest.com", "linkedin.com", "whatsapp.com", "snapchat.com", "threads.net", "medium.com", "quora.com",
            "wikipedia.org", "wikimedia.org", "blogspot.com", "line.me"]),
        PolicyGroup(id: "ai", name: "海外 AI", note: "被墙且对出口地址敏感：固定走服务器，不要和直连来回切换", icon: "sparkles", defaultMode: .proxy, domains: [
            "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "anthropic.com", "claude.ai", "perplexity.ai", "x.ai", "grok.com", "huggingface.co", "midjourney.com", "poe.com", "character.ai"]),
        PolicyGroup(id: "google", name: "Google 服务", note: "被墙：走服务器", icon: "magnifyingglass", defaultMode: .proxy, domains: [
            "google.com", "gstatic.com", "googleapis.com", "googleusercontent.com", "ggpht.com", "gvt1.com", "google.com.hk", "android.com", "chrome.com", "blogger.com", "withgoogle.com", "goog"]),
        PolicyGroup(id: "dev", name: "开发者站点", note: "有时慢：自动判断（先直连，不通再走服务器）", icon: "chevron.left.forwardslash.chevron.right", defaultMode: .auto, domains: [
            "github.com", "githubassets.com", "githubusercontent.com", "github.io", "stackblitz.com", "vercel.app", "netlify.app", "readthedocs.io"]),
    ]

    func mode(of g: PolicyGroup) -> RouteMode { settings.prefs.groupModes[g.id].flatMap(RouteMode.init(rawValue:)) ?? g.defaultMode }
    func domains(of g: PolicyGroup) -> [String] { g.domains + (settings.prefs.groupDomains[g.id] ?? []) }

    /// The group that decides this site: domains the user added win over the built-in lists.
    func group(for dom: String, host: String) -> PolicyGroup? {
        for g in Router.groups where (settings.prefs.groupDomains[g.id] ?? []).contains(where: { URLResolver.registrableDomain($0) == dom }) { return g }
        for g in Router.groups where g.domains.contains(where: { URLResolver.registrableDomain($0) == dom }) { return g }
        if host.hasSuffix(".cn") || host.hasSuffix(".com.cn") || host.hasSuffix(".gov.cn") { return Router.groups.first { $0.id == "cn" } }
        return nil
    }
    /// .direct / .proxy when a group decides, nil = decide automatically.
    func policyMode(_ dom: String, host: String) -> RouteMode? {
        if let d = direct[dom], Date().timeIntervalSince(d) < 7 * 86_400 { return .direct }      // learned: it blocked the proxy exit
        guard let g = group(for: dom, host: host) else { return nil }
        let m = mode(of: g)
        return m == .auto ? nil : m
    }

    /// Sites that blocked the proxy exit address and answered fine directly (learned, kept for 7 days).
    @Published private(set) var direct: [String: Date] = [:]
    private let directFile = JSONFile<[String: Date]>("direct-sites.json")

    /// A proxied page came back as a firewall block page: if the site is reachable directly, go direct from now on.
    func markDirect(_ dom: String) {
        direct[dom] = Date(); proxied[dom] = nil; verdicts[dom] = (true, Date())
        directFile.save(direct); file.save(proxied); apply()
    }

    init(settings: Settings) {
        self.settings = settings
        direct = directFile.load([:]).filter { Date().timeIntervalSince($0.value) < 7 * 86_400 }
        // Remember recently-blocked domains for 6h so cold starts don't wait for a probe.
        let saved = file.load([:]).filter { Date().timeIntervalSince($0.value) < 24 * 3600 }      // a site keeps the same route for a day (changing address back and forth triggers risk control)
        proxied = saved
    }

    // MARK: probe

    enum Route { case direct, proxy }

    /// Instant answer from what we already know (no network). nil = not known yet.
    func cachedRoute(for url: URL) -> Route? {
        guard let host = url.host, url.scheme == "http" || url.scheme == "https" else { return .direct }
        let dom = URLResolver.registrableDomain(host)
        switch settings.prefs.routing {
        case .direct: return .direct
        case .proxy: return .proxy
        case .auto: break
        }
        guard settings.gatewayConfigured || hy2?.running == true else { return .direct }
        if isForced(dom) || settings.site(host).forceProxy { return .proxy }
        if let m = policyMode(dom, host: host) { return m == .proxy ? .proxy : .direct }
        if proxied[dom] != nil { return .proxy }
        if let v = verdicts[dom], Date().timeIntervalSince(v.at) < 6 * 3600, v.ok { return .direct }
        return nil
    }

    /// Probe without holding up the page load; `onProxy` fires only if the verdict is "use the server".
    func resolveInBackground(_ url: URL, onProxy: @escaping () -> Void) {
        Task { if await prepare(for: url) == .proxy { onProxy() } }
    }

    /// Decide the route for `url` and make sure WebKit's proxy list reflects it before the request starts.
    func prepare(for url: URL) async -> Route {
        guard let host = url.host, url.scheme == "http" || url.scheme == "https" else { return .direct }
        let dom = URLResolver.registrableDomain(host)
        switch settings.prefs.routing {
        case .direct: return .direct
        case .proxy: apply(); return .proxy
        case .auto: break
        }
        guard settings.gatewayConfigured || hy2?.running == true else { return .direct }
        if isForced(dom) || settings.site(host).forceProxy { apply(); return .proxy }
        if let m = policyMode(dom, host: host) { return m == .proxy ? .proxy : .direct }
        if proxied[dom] != nil { apply(); return .proxy }
        if let v = verdicts[dom], Date().timeIntervalSince(v.at) < 6 * 3600, v.ok { return .direct }

        let r: Probe
        if let t = inflight[dom] { r = await t.value } else {
            let t = Task { await Router.probeDirect(host: host) }
            inflight[dom] = t
            r = await t.value
            inflight[dom] = nil
        }
        if r.ok, r.ms > 1200, let gw = gateway, let via = await gw.probeViaServer(url), via < r.ms * 0.6 {
            // reachable but slow: the server (and its tunnel) gets there clearly faster -> use it
            verdicts[dom] = (false, Date()); markBlocked(dom); return .proxy
        }
        verdicts[dom] = (r.ok, Date())
        if r.ok { return .direct }
        markBlocked(dom)
        return .proxy
    }

    func markBlocked(_ dom: String) {
        proxied[dom] = Date()
        for c in Router.companions[dom] ?? [] { proxied[URLResolver.registrableDomain(c)] = Date() }
        file.save(proxied)
        apply()
    }

    func reset() { proxied = [:]; verdicts = [:]; file.save([:]); apply() }

    private func isForced(_ dom: String) -> Bool { settings.prefs.forcedProxyDomains.contains { URLResolver.registrableDomain($0) == dom } }

    /// Direct connectivity probe. Any HTTP answer = reachable. Timeouts / resets / DNS / TLS failures = blocked.
    struct Probe { var ok: Bool; var ms: Double }
    nonisolated static func probeDirect(host: String) async -> Probe {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 3.5
        c.timeoutIntervalForResource = 4.5
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: c)
        defer { s.finishTasksAndInvalidate() }
        guard let u = URL(string: "https://\(host)/") else { return Probe(ok: true, ms: 0) }
        var r = URLRequest(url: u); r.httpMethod = "HEAD"
        let t0 = Date()
        let ms = { Date().timeIntervalSince(t0) * 1000 }
        do { _ = try await s.data(for: r); return Probe(ok: true, ms: ms()) }
        catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cancelled: return Probe(ok: true, ms: 0)  // offline ≠ blocked
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .cannotParseResponse:
                return Probe(ok: false, ms: ms())
            default: return Probe(ok: true, ms: ms())
            }
        } catch { return Probe(ok: true, ms: 0) }
    }

    // MARK: apply to WebKit

    func register(_ store: WKWebsiteDataStore) {
        stores.removeAll { $0.s == nil }
        if !stores.contains(where: { $0.s === store }) { stores.append(WeakStore(s: store)) }
        configure(store)
    }

    func apply() { stores.removeAll { $0.s == nil }; stores.forEach { if let s = $0.s { configure(s) } } }

    /// The proxy WebKit (and the diagnostics) use: the server's HTTPS CONNECT proxy, or the in-app loopback tunnel.
    /// Built-in Hysteria2 (your own server) as a loopback proxy. Highest priority when it is up.
    func makeHy2Config(matchDomains: [String]?) -> ProxyConfiguration? {
        guard let h = hy2, h.running, h.port != 0, let p = NWEndpoint.Port(rawValue: h.port) else { return nil }
        var c = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p), tlsOptions: nil)
        c.applyCredential(username: "lunox", password: h.token)
        c.allowFailover = true
        if let m = matchDomains { c.matchDomains = m }
        return c
    }

    func makeConfig(loopback: Bool, matchDomains: [String]?) -> ProxyConfiguration? {
        if loopback, let e = edge, e.tunnel.port != 0, let p = NWEndpoint.Port(rawValue: e.tunnel.port) {
            var local = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p), tlsOptions: nil)
            local.applyCredential(username: "lunox", password: e.tunnel.token)
            local.allowFailover = true
            if let m = matchDomains { local.matchDomains = m }
            return local
        }
        guard settings.gatewayConfigured, let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.prefs.gatewayPort)) else { return nil }
        let pin = settings.prefs.gatewayPin
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            complete(Pinning.verify(trust: trust, pin: pin))
        }, DispatchQueue.global(qos: .userInitiated))
        var cfg = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(settings.prefs.gatewayHost), port: port), tlsOptions: tls)
        cfg.applyCredential(username: "lunox", password: settings.gatewayKey)
        cfg.allowFailover = true        // if the gateway is down, fall back to direct instead of a dead page
        if let m = matchDomains { cfg.matchDomains = m }
        return cfg
    }

    private func configure(_ store: WKWebsiteDataStore) {
        guard settings.prefs.routing != .direct, (settings.gatewayConfigured || hy2?.running == true) else { store.proxyConfigurations = []; return }
        let mode = settings.prefs.routing
        var domains = Set(proxied.keys)
        for g in Router.groups where mode(of: g) == .proxy { domains.formUnion(self.domains(of: g).map { URLResolver.registrableDomain($0) }) }
        domains = domains.filter { policyMode($0, host: $0) != .direct }                       // a direct group wins over an old "blocked" verdict
        settings.prefs.forcedProxyDomains.forEach { domains.insert(URLResolver.registrableDomain($0)) }
        settings.sites.filter { $0.value.forceProxy }.keys.forEach { domains.insert($0) }
        if mode == .auto && domains.isEmpty { store.proxyConfigurations = []; return }
        let match: [String]? = mode == .auto ? Array(domains) : nil
        if settings.prefs.useHy2, let h = makeHy2Config(matchDomains: match) { store.proxyConfigurations = [h]; return }
        if let cfg = makeConfig(loopback: edge?.usesTunnel == true, matchDomains: match) { store.proxyConfigurations = [cfg] }
        else { store.proxyConfigurations = [] }
    }
}
