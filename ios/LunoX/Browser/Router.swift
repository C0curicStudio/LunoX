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
        "youtube.com": ["googlevideo.com", "ytimg.com", "ggpht.com", "gstatic.com", "googleapis.com", "youtu.be", "google.com"],
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

    init(settings: Settings) {
        self.settings = settings
        // Remember recently-blocked domains for 6h so cold starts don't wait for a probe.
        let saved = file.load([:]).filter { Date().timeIntervalSince($0.value) < 6 * 3600 }
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
        if isForced(dom) || settings.site(host).forceProxy || proxied[dom] != nil { return .proxy }
        if let v = verdicts[dom], Date().timeIntervalSince(v.at) < 600, v.ok { return .direct }
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
        if proxied[dom] != nil { apply(); return .proxy }
        if let v = verdicts[dom], Date().timeIntervalSince(v.at) < 600, v.ok { return .direct }

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
        settings.prefs.forcedProxyDomains.forEach { domains.insert(URLResolver.registrableDomain($0)) }
        settings.sites.filter { $0.value.forceProxy }.keys.forEach { domains.insert($0) }
        if mode == .auto && domains.isEmpty { store.proxyConfigurations = []; return }
        let match: [String]? = mode == .auto ? Array(domains) : nil
        if settings.prefs.useHy2, let h = makeHy2Config(matchDomains: match) { store.proxyConfigurations = [h]; return }
        if let cfg = makeConfig(loopback: edge?.usesTunnel == true, matchDomains: match) { store.proxyConfigurations = [cfg] }
        else { store.proxyConfigurations = [] }
    }
}
