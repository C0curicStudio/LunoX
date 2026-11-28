import Foundation
#if canImport(Hy2bridge)
import Hy2bridge
#endif

/// Parameters of YOUR Hysteria2 server. They are stored on the gateway (server/deploy/set-hy2.sh) and fetched once,
/// so nothing is typed on the phone; they are then kept in the Keychain.
struct Hy2Config: Codable, Equatable {
    var host: String
    var port: Int
    var auth: String
    var obfs: String = ""
    var sni: String = ""
    var insecure: Bool = false
    var pin: String = ""
    var downMbps: Int = 0
}

extension Hy2Config {
    /// `hy2=` value of a lunox://setup link: URL-safe base64 of the JSON the server printed.
    static func fromLink(_ v: String) -> Hy2Config? {
        var b = v.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let c = try? JSONDecoder().decode(Hy2Config.self, from: d), !c.host.isEmpty, c.port > 0, !c.auth.isEmpty else { return nil }
        return c
    }
}

/// The official Hysteria2 client, compiled into the app (ios/hy2bridge -> Hy2bridge.xcframework).
/// It exposes a loopback HTTP CONNECT proxy; WebKit is pointed at it, so no VPN profile or second app is needed.
@MainActor
final class Hy2Manager: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    private(set) var port: UInt16 = 0
    let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    private(set) var config: Hy2Config?
    var onChange: (() -> Void)?

    init() {
        if let d = Keychain.get("hy2-config").data(using: .utf8), let c = try? JSONDecoder().decode(Hy2Config.self, from: d) { config = c }
    }

    var compiledIn: Bool {
        #if canImport(Hy2bridge)
        true
        #else
        false
        #endif
    }
    var configured: Bool { config != nil }

    /// Called when the gateway sends its (possibly updated) Hysteria2 parameters.
    func update(_ c: Hy2Config?) {
        guard let c else { return }
        if c != config {
            config = c
            if let d = try? JSONEncoder().encode(c), let s = String(data: d, encoding: .utf8) { Keychain.set(s, for: "hy2-config") }
            stop()
        }
        if !running { start() }
    }

    func start() {
        #if canImport(Hy2bridge)
        guard let c = config, !running else { return }
        var p = 0
        var err: NSError?
        // gomobile exposes Go's (int, error) as: BOOL f(..., long *ret0, NSError **error)
        if Hy2bridgeStart(c.host, c.port, c.auth, c.obfs, c.sni, c.insecure, c.pin, c.downMbps, token, &p, &err) {
            port = UInt16(clamping: p); running = true; lastError = nil
            onChange?()
        } else { lastError = err?.localizedDescription ?? "Hysteria2 启动失败"; running = false }
        #endif
    }

    func stop() {
        #if canImport(Hy2bridge)
        Hy2bridgeStop()
        #endif
        let was = running
        running = false; port = 0
        if was { onChange?() }
    }

    /// Opens one tunnelled connection through Hysteria2: proves the QUIC link, credentials and obfuscation work.
    func probe(_ addr: String = "www.google.com:443") async -> (ms: Int, error: String?) {
        #if canImport(Hy2bridge)
        if !running { start() }
        guard running else { return (0, lastError ?? "Hysteria2 未启动") }
        return await Task.detached {
            var ms = 0
            var err: NSError?
            if Hy2bridgeProbe(addr, &ms, &err) { return (ms, nil) }
            return (0, err?.localizedDescription ?? "连接失败")
        }.value
        #else
        return (0, "这个版本没有内置 Hysteria2 内核")
        #endif
    }

    var statusText: String {
        #if canImport(Hy2bridge)
        return Hy2bridgeStatus()
        #else
        return "未内置"
        #endif
    }
}
