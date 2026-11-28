import Foundation
import LocalAuthentication
import WebKit

/// Saved sign-ins and account profiles. Everything lives in ONE Keychain item that is readable only while the phone is unlocked,
/// never leaves this device (no iCloud, no server, not in backups), and is only shown or used after Face ID / the device passcode.
struct Credential: Codable, Identifiable, Hashable {
    var id = UUID()
    var site: String              // registrable domain, e.g. "github.com"
    var username: String
    var password: String
    var note = ""
    var updatedAt = Date()
    var lastUsed: Date?
}

struct CookieRec: Codable, Hashable {
    var name: String, value: String, domain: String, path: String
    var expires: Double?
    var secure: Bool, httpOnly: Bool
    var sameSite: String?
}

/// A signed-in session of one site: its cookies. Applying it signs you in as that account without typing anything.
struct AccountProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var site: String
    var label: String
    var cookies: [CookieRec]
    var savedAt = Date()
    var lastUsed: Date?
}

struct VaultData: Codable {
    var credentials: [Credential] = []
    var accounts: [AccountProfile] = []
    var neverSave: [String] = []                 // sites the user said "never ask to save a password" for
}

@MainActor
final class Vault: ObservableObject {
    @Published private(set) var data = VaultData()
    private var unlockedUntil = Date.distantPast
    private static let key = "vault-v1"

    init() { load() }

    // MARK: storage
    private func load() {
        let s = Keychain.get(Self.key)
        if let d = s.data(using: .utf8), let v = try? JSONDecoder().decode(VaultData.self, from: d) { data = v }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(data), let s = String(data: d, encoding: .utf8) { Keychain.set(s, for: Self.key, strong: true) }
    }
    func wipe() { data = VaultData(); Keychain.set("", for: Self.key) }

    // MARK: Face ID / passcode gate
    var isUnlocked: Bool { Date() < unlockedUntil }
    func unlock(_ reason: String = "查看或使用已保存的密码与账号") async -> Bool {
        if isUnlocked { return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }       // no passcode set: refuse
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { unlockedUntil = Date().addingTimeInterval(120) }
        return ok
    }
    func lock() { unlockedUntil = .distantPast }

    // MARK: queries (counts and site names only; secrets are read after unlock)
    func site(for host: String?) -> String { URLResolver.registrableDomain(host ?? "") }
    func logins(for host: String?) -> [Credential] { let s = site(for: host); return data.credentials.filter { $0.site == s }.sorted { ($0.lastUsed ?? $0.updatedAt) > ($1.lastUsed ?? $1.updatedAt) } }
    func accounts(for host: String?) -> [AccountProfile] { let s = site(for: host); return data.accounts.filter { $0.site == s }.sorted { ($0.lastUsed ?? $0.savedAt) > ($1.lastUsed ?? $1.savedAt) } }
    func hasAnything(for host: String?) -> Bool { let s = site(for: host); return !s.isEmpty && (data.credentials.contains { $0.site == s } || data.accounts.contains { $0.site == s }) }
    var sites: [String] { Set(data.credentials.map(\.site) + data.accounts.map(\.site)).sorted() }

    // MARK: passwords
    enum SaveResult { case saved, updated, unchanged }
    @discardableResult
    func save(site: String, username: String, password: String) -> SaveResult {
        guard !site.isEmpty, !password.isEmpty else { return .unchanged }
        if let i = data.credentials.firstIndex(where: { $0.site == site && $0.username == username }) {
            if data.credentials[i].password == password { return .unchanged }
            data.credentials[i].password = password; data.credentials[i].updatedAt = Date(); persist(); return .updated
        }
        data.credentials.append(Credential(site: site, username: username, password: password)); persist(); return .saved
    }
    func update(_ c: Credential) { if let i = data.credentials.firstIndex(where: { $0.id == c.id }) { var n = c; n.updatedAt = Date(); data.credentials[i] = n; persist() } }
    func touch(_ c: Credential) { if let i = data.credentials.firstIndex(where: { $0.id == c.id }) { data.credentials[i].lastUsed = Date(); persist() } }
    func delete(_ c: Credential) { data.credentials.removeAll { $0.id == c.id }; persist() }
    func isNeverSave(_ site: String) -> Bool { data.neverSave.contains(site) }
    func neverSave(_ site: String) { if !data.neverSave.contains(site) { data.neverSave.append(site); persist() } }
    func allowSave(_ site: String) { data.neverSave.removeAll { $0 == site }; persist() }

    // MARK: account profiles (cookies)
    private static func match(_ cookieDomain: String, site: String) -> Bool {
        let d = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return d == site || d.hasSuffix("." + site)
    }

    /// Snapshot of the cookies this tab holds for its site.
    @discardableResult
    func saveAccount(from tab: Tab, label: String? = nil) async -> AccountProfile? {
        guard let host = tab.url?.host, let store = tab.webView?.configuration.websiteDataStore else { return nil }
        let site = site(for: host)
        let cookies = await store.httpCookieStore.allCookies().filter { Self.match($0.domain, site: site) }
        guard !cookies.isEmpty else { return nil }
        let recs = cookies.map {
            CookieRec(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate?.timeIntervalSince1970,
                      secure: $0.isSecure, httpOnly: $0.isHTTPOnly, sameSite: $0.sameSitePolicy?.rawValue)
        }
        let n = data.accounts.filter { $0.site == site }.count + 1
        let acct = AccountProfile(site: site, label: label ?? "账号 \(n)", cookies: recs)
        data.accounts.append(acct); persist()
        return acct
    }

    /// Replace the site's cookies in this tab's data store with the saved ones. The caller reloads the page.
    func apply(_ a: AccountProfile, to tab: Tab) async {
        let store = tab.webView?.configuration.websiteDataStore ?? tab.store.dataStore(isPrivate: tab.isPrivate)
        let cs = store.httpCookieStore
        for c in await cs.allCookies() where Self.match(c.domain, site: a.site) { await cs.deleteCookie(c) }
        let now = Date()
        for r in a.cookies {
            var p: [HTTPCookiePropertyKey: Any] = [.name: r.name, .value: r.value, .domain: r.domain, .path: r.path]
            if let e = r.expires { let d = Date(timeIntervalSince1970: e); if d < now { continue }; p[.expires] = d }
            if r.secure { p[.secure] = "TRUE" }
            if r.httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let s = r.sameSite { p[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: s) }
            if let c = HTTPCookie(properties: p) { await cs.setCookie(c) }
        }
        if let i = data.accounts.firstIndex(where: { $0.id == a.id }) { data.accounts[i].lastUsed = now; persist() }
    }
    func rename(_ a: AccountProfile, to label: String) { if let i = data.accounts.firstIndex(where: { $0.id == a.id }) { data.accounts[i].label = label; persist() } }
    func delete(_ a: AccountProfile) { data.accounts.removeAll { $0.id == a.id }; persist() }

    // MARK: site data (cookies, storage) for the data manager
    func cookieCount(site: String, in store: WKWebsiteDataStore) async -> Int {
        await store.httpCookieStore.allCookies().filter { Self.match($0.domain, site: site) }.count
    }
    func clearSiteData(_ site: String, in store: WKWebsiteDataStore) async {
        let cs = store.httpCookieStore
        for c in await cs.allCookies() where Self.match(c.domain, site: site) { await cs.deleteCookie(c) }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let recs = await store.dataRecords(ofTypes: types).filter { Self.match($0.displayName, site: site) || $0.displayName == site }
        await store.removeData(ofTypes: types, for: recs)
    }
}
