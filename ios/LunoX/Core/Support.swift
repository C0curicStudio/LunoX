import Foundation
import Security
import CryptoKit
import UIKit
import SwiftUI

// MARK: - Paths / persistence

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LunoX", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func dir(_ name: String, excludeFromBackup: Bool = false) -> URL {
        var u = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        if excludeFromBackup { var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v) }
        return u
    }
    static let downloads: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

struct JSONFile<T: Codable> {
    let url: URL
    init(_ name: String) { url = Paths.support.appendingPathComponent(name) }
    func load(_ fallback: T) -> T {
        guard let d = try? Data(contentsOf: url) else { return fallback }
        if let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        // The file was written by an older build and lacks newer keys: keep what it has, default the rest (never wipe settings on update).
        if let base = (try? JSONEncoder().encode(fallback)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
           let old = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let merged = try? JSONSerialization.data(withJSONObject: base.merging(old) { _, stored in stored }),
           let v = try? JSONDecoder().decode(T.self, from: merged) { return v }
        return fallback
    }
    func save(_ v: T) {
        let u = url
        guard let d = try? JSONEncoder().encode(v) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? d.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static func query(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.lunox", kSecAttrAccount as String: k]
    }
    /// `strong`: readable only while the phone is unlocked (used for the password vault).
    static func set(_ v: String, for k: String, strong: Bool = false) {
        SecItemDelete(query(k) as CFDictionary)
        guard !v.isEmpty else { return }
        var q = query(k)
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = strong ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ k: String) -> String {
        var q = query(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Certificate pinning (shared by URLSession and the WebKit proxy)

enum Pinning {
    static func normalize(_ s: String) -> String { s.lowercased().filter { $0.isHexDigit } }
    static func verify(trust: SecTrust, pin: String) -> Bool {
        let want = normalize(pin)
        guard want.count == 64,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let got = digest.map { String(format: "%02x", $0) }.joined()
        return got == want
    }
}

// MARK: - Models

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var folder: String = ""
    var date = Date()
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
}

struct SiteSetting: Codable, Hashable {
    var desktop = false
    var javascript = true
    var forceProxy = false
    var fingerprintLoose = false   // true = this site sees the browser exactly as it is
    var allowNags = false          // true = leave this site's "open in app" / login prompts alone
    var camera: Bool? = nil     // nil = ask
    var microphone: Bool? = nil

    init(desktop: Bool = false) { self.desktop = desktop }
    /// Settings saved by older builds lack newer keys: read what is there, default the rest (never lose a site's settings on update).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        desktop = try c.decodeIfPresent(Bool.self, forKey: .desktop) ?? false
        javascript = try c.decodeIfPresent(Bool.self, forKey: .javascript) ?? true
        forceProxy = try c.decodeIfPresent(Bool.self, forKey: .forceProxy) ?? false
        fingerprintLoose = try c.decodeIfPresent(Bool.self, forKey: .fingerprintLoose) ?? false
        allowNags = try c.decodeIfPresent(Bool.self, forKey: .allowNags) ?? false
        camera = try c.decodeIfPresent(Bool.self, forKey: .camera)
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone)
    }
}

struct SearchEngine: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var template: String      // %s = query
    var suggestKey: String
    static let all: [SearchEngine] = [
        .init(id: "google", name: "Google", template: "https://www.google.com/search?q=%s", suggestKey: "google"),
        .init(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s", suggestKey: "bing"),
        .init(id: "ddg", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s", suggestKey: "duckduckgo"),
        .init(id: "baidu", name: "百度", template: "https://www.baidu.com/s?wd=%s", suggestKey: "baidu"),
        .init(id: "brave", name: "Brave", template: "https://search.brave.com/search?q=%s", suggestKey: "google"),
    ]
}

enum URLResolver {
    /// Turns omnibox text into a navigable http(s) URL or a search URL. Never yields file:/javascript:/data:.
    static func resolve(_ raw: String, engine: SearchEngine) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let s = u.scheme?.lowercased() {
            if s == "http" || s == "https" { return u.host == nil ? nil : u }
            if t.contains("://") || ["javascript", "data", "file", "blob", "about"].contains(s) { return search(t, engine) }
        }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host?.contains(".") == true { return u }
        if t.lowercased().hasPrefix("localhost"), let u = URL(string: "http://" + t) { return u }
        return search(t, engine)
    }
    static func search(_ q: String, _ e: SearchEngine) -> URL? {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))) ?? q
        return URL(string: e.template.replacingOccurrences(of: "%s", with: enc))
    }
    static func registrableDomain(_ host: String) -> String {
        let p = host.lowercased().split(separator: ".").map(String.init)
        guard p.count > 2 else { return host.lowercased() }
        let sld: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
        if p[p.count - 1].count == 2, sld.contains(p[p.count - 2]) { return p.suffix(3).joined(separator: ".") }
        return p.suffix(2).joined(separator: ".")
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func ok() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

extension URL {
    var displayHost: String { (host ?? absoluteString).replacingOccurrences(of: "www.", with: "") }
}
extension String {
    var sha256Hex: String { SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined() }
}

extension Color {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

/// Resolve a host's DNS name ahead of the navigation (the system DNS cache is shared with WebKit's network process).
enum Prefetch {
    private static let queue = DispatchQueue(label: "app.lunox.dns", qos: .utility, attributes: .concurrent)
    private static var seen = Set<String>()
    private static let lock = NSLock()
    static func dns(_ host: String?) {
        guard let host, !host.isEmpty else { return }
        lock.lock(); let fresh = seen.insert(host).inserted; if seen.count > 500 { seen.removeAll() }; lock.unlock()
        guard fresh else { return }
        queue.async {
            var res: UnsafeMutablePointer<addrinfo>?
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            if getaddrinfo(host, "443", &hints, &res) == 0 { freeaddrinfo(res) }
        }
    }
}
