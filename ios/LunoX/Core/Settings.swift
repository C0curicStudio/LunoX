import Foundation
import SwiftUI

enum RouteMode: String, Codable, CaseIterable, Identifiable {
    case direct, proxy, auto
    var id: String { rawValue }
    var title: String { switch self { case .direct: "直连"; case .proxy: "代理"; case .auto: "自动" } }
}

enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case auto, direct, proxy
    var id: String { rawValue }
    var title: String { switch self { case .auto: "智能（先直连，不通走服务器）"; case .direct: "仅直连"; case .proxy: "全部走服务器" } }
}

struct Prefs: Codable, Equatable {
    var engineID = "google"
    var homepage = ""
    var themeID = "safari"
    var appearance: Appearance = .system
    var routing: RoutingMode = .auto
    var blockTrackers = true
    var httpsOnly = true
    var blockPopups = true
    var appLock = false
    var nativeMode = true
    var autoDarkPages = true
    var preferEdgeTunnel = false
    var translateTarget = ""          // "" = follow the phone's language
    var autoTranslatePages = true     // translate foreign-language pages as soon as they load
    var startOrder: [String] = ["favorites", "frequent", "news", "offline", "closed"]
    var startHidden: [String] = ["closed"]
    var startBackground = ""          // "" = plain (default)
    var newsAutoplay = true
    var translateNews = true          // translate headlines into the reading language
    var fingerprintProtection = true  // consistent, believable normalisation (see Fingerprint.swift)
    var stripTrackingParams = true    // utm_*, fbclid, gclid … removed from links you open
    var nativeTemplates = true        // YouTube / Bilibili … open as native pages
    var compactBar = false            // keep the bottom bar small until tapped
    var useHy2 = true
    var blockAppPrompts = true
    var blockForcedLogin = true
    var translateAIFallback = false
    var hideCookieBanners = true
    var offlineCache = true
    var offlineLimitMB = 300
    var aiEnabled = true
    var searchSuggest = true
    var aiRouting = true              // a clear question goes to the AI assistant instead of a search engine
    var smartDirect = true            // a clear target ("youtube", "b站 swift") goes straight to that site
    var restoreTabs = true
    var defaultDesktop = false
    var syncBookmarks = false
    var gatewayHost = "186.244.245.83"
    var gatewayPort = 8443
    var gatewayPin = ""
    var edgeHost = ""
    var edgePort = 8443
    var forcedProxyDomains: [String] = []
    var groupModes: [String: String] = [:]          // policy group id -> "direct" | "proxy" | "auto" (absent = the group default)
    var groupDomains: [String: [String]] = [:]      // domains the user added to a policy group
}

@MainActor
final class Settings: ObservableObject {
    private let file = JSONFile<Prefs>("prefs.json")
    @Published var prefs: Prefs { didSet { if prefs != oldValue { file.save(prefs) } } }
    @Published private(set) var keyRevision = 0
    @Published var sites: [String: SiteSetting] { didSet { sitesFile.save(sites) } }
    private let sitesFile = JSONFile<[String: SiteSetting]>("sites.json")

    init() {
        var p = file.load(Prefs())
        // Optional build-time pairing (CI secrets -> Info.plist) so the app needs no typing at all.
        let info = Bundle.main.infoDictionary ?? [:]
        if Pinning.normalize(p.gatewayPin).count != 64, let pin = info["LunoXPin"] as? String, Pinning.normalize(pin).count == 64 { p.gatewayPin = Pinning.normalize(pin) }
        prefs = p
        sites = sitesFile.load([:])
        if Keychain.get("gateway-key").isEmpty, let k = info["LunoXKey"] as? String, !k.isEmpty, !k.hasPrefix("$(") { Keychain.set(k, for: "gateway-key") }
    }

    var gatewayKey: String {
        get { Keychain.get("gateway-key") }
        set { Keychain.set(newValue, for: "gateway-key"); keyRevision += 1 }
    }
    var translateTarget: String { prefs.translateTarget.isEmpty ? LanguageUtil.systemTarget() : prefs.translateTarget }
    var gatewayConfigured: Bool { !gatewayKey.isEmpty && !prefs.gatewayHost.isEmpty && Pinning.normalize(prefs.gatewayPin).count == 64 }
    var engine: SearchEngine { SearchEngine.all.first { $0.id == prefs.engineID } ?? SearchEngine.all[0] }
    var family: ThemeFamily { ThemeFamily.all.first { $0.id == prefs.themeID } ?? ThemeFamily.all[0] }

    func site(_ host: String?) -> SiteSetting { sites[URLResolver.registrableDomain(host ?? "")] ?? SiteSetting(desktop: prefs.defaultDesktop) }
    func updateSite(_ host: String?, _ f: (inout SiteSetting) -> Void) {
        guard let host else { return }
        let k = URLResolver.registrableDomain(host)
        var s = sites[k] ?? SiteSetting(desktop: prefs.defaultDesktop)
        f(&s); sites[k] = s
    }

    /// Hysteria2 parameters that came with the last setup link (handed to the Hysteria2 manager by the caller).
    var pendingHy2: Hy2Config?

    /// lunox://setup?host=&port=&key=&pin=[&edge=][&hy2=<base64url json>]  (either the gateway part, the hy2 part, or both)
    @discardableResult
    func applySetupLink(_ url: URL) -> Bool {
        guard url.scheme == "lunox", url.host == "setup",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func q(_ n: String) -> String? { c.first { $0.name == n }?.value }
        var ok = false
        if let h = q("hy2"), let cfg = Hy2Config.fromLink(h) { pendingHy2 = cfg; ok = true }
        if let host = q("host"), let key = q("key"), let pin = q("pin"), Pinning.normalize(pin).count == 64,
           host.range(of: #"^[A-Za-z0-9.\-:]{1,253}$"#, options: .regularExpression) != nil {
            prefs.gatewayHost = host
            prefs.gatewayPort = Int(q("port") ?? "") ?? 8443
            prefs.gatewayPin = Pinning.normalize(pin)
            if let e = q("edge"), e.range(of: #"^[A-Za-z0-9.\-]{1,253}$"#, options: .regularExpression) != nil { prefs.edgeHost = e; prefs.edgePort = Int(q("edgePort") ?? "") ?? 8443 }
            gatewayKey = key
            ok = true
        }
        return ok
    }
}
