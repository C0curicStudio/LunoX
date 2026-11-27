import Foundation
import Network
import WebKit
import CryptoKit

struct AgentAction: Codable, Hashable {
    var type: String
    var id: Int?
    var text: String?
    var submit: Bool?
    var dy: Int?
    var url: String?
    var ms: Int?
}
struct AgentPlan: Codable {
    var thought: String
    var done: Bool
    var answer: String
    var actions: [AgentAction]
}
struct ServerConfig: Decodable {
    struct LLM: Decodable { var configured: Bool; var provider: String; var baseUrl: String; var model: String }
    var edge: String?
    var llm: LLM
}
struct SearchHit: Codable, Identifiable, Hashable { var title: String; var url: String; var snippet: String; var id: String { url } }

enum GatewayError: LocalizedError {
    case notConfigured, http(Int), bad
    var errorDescription: String? {
        switch self {
        case .notConfigured: "服务器未配置（设置 › 网络）"
        case .http(let c): "服务器返回 \(c)"
        case .bad: "响应无效"
        }
    }
}

/// Everything that needs the network but is not page rendering goes through the server.
final class GatewayClient: NSObject, URLSessionDelegate {
    private let settings: Settings
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]          // never loop through our own proxy
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    @MainActor init(settings: Settings) { self.settings = settings }

    // Snapshot of config (read on main, used anywhere)
    private struct Cfg { var host: String; var port: Int; var key: String; var pin: String; var pinned: Bool }
    /// Set by EdgeSelector when the Cloudflare route is the fastest; nil = talk to the server directly (certificate-pinned).
    @MainActor var endpoint: (host: String, port: Int)?
    @MainActor private func cfg() throws -> Cfg {
        guard settings.gatewayConfigured else { throw GatewayError.notConfigured }
        let p = settings.prefs
        if let e = endpoint { return Cfg(host: e.host, port: e.port, key: settings.gatewayKey, pin: p.gatewayPin, pinned: false) }
        return Cfg(host: p.gatewayHost, port: p.gatewayPort, key: settings.gatewayKey, pin: p.gatewayPin, pinned: true)
    }
    private var pin: String = ""
    private var pinHost: String = ""

    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = ch.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        guard !pinHost.isEmpty, ch.protectionSpace.host == pinHost else { return completionHandler(.performDefaultHandling, nil) }  // Cloudflare edge: normal validation
        Pinning.verify(trust: trust, pin: pin) ? completionHandler(.useCredential, URLCredential(trust: trust)) : completionHandler(.cancelAuthenticationChallenge, nil)
    }

    @MainActor
    private func makeRequest(_ path: String, _ query: [String: String] = [:], method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) throws -> URLRequest {
        let c = try cfg()
        pin = c.pin; pinHost = c.pinned ? c.host : ""
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = c.host; comps.port = c.port; comps.path = path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw GatewayError.bad }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(c.key)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw GatewayError.bad }
        guard h.statusCode == 200 else { throw GatewayError.http(h.statusCode) }
        return (d, h)
    }

    // MARK: route measurement

    /// Round-trip to /v1/health on a fresh connection (TLS + request, then a warm request). Returns the Cloudflare edge city if any.
    func ping(host: String, port: Int, pinned: Bool) async -> RouteResult {
        let (key, pin) = await MainActor.run { (settings.gatewayKey, settings.prefs.gatewayPin) }
        let d = PinDelegate(pinHost: pinned ? host : "", pin: pin)
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]; c.timeoutIntervalForRequest = 5; c.waitsForConnectivity = false
        let s = URLSession(configuration: c, delegate: d, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        var comps = URLComponents(); comps.scheme = "https"; comps.host = host; comps.port = port; comps.path = "/v1/health"
        guard let url = comps.url else { return RouteResult(ms: nil, colo: nil) }
        var r = URLRequest(url: url); r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var total = 0.0, colo: String?
        for _ in 0..<2 {
            let t0 = Date()
            guard let (_, resp) = try? await s.data(for: r), let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return RouteResult(ms: nil, colo: nil) }
            total += Date().timeIntervalSince(t0) * 1000
            if let ray = h.value(forHTTPHeaderField: "cf-ray"), let c = ray.split(separator: "-").last { colo = String(c) }
        }
        return RouteResult(ms: total, colo: colo)
    }

    /// How long the SERVER needs to reach a site (+ our round trip to the server). Used to compare against a slow direct connection.
    func probeViaServer(_ url: URL) async -> Double? {
        guard let r = try? await makeRequest("/v1/probe", ["url": url.absoluteString], timeout: 8) else { return nil }
        let t0 = Date()
        guard (try? await send(r)) != nil else { return nil }
        return Date().timeIntervalSince(t0) * 1000
    }

    // MARK: server self-configuration

    func config() async -> ServerConfig? {
        guard let r = try? await makeRequest("/v1/config", timeout: 6), let (d, _) = try? await send(r) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: d)
    }

    /// Model API settings are written to the server only; the key is never sent back to the phone.
    func saveLLM(provider: String, baseUrl: String, model: String, apiKey: String?) async throws {
        var body: [String: Any] = ["provider": provider, "baseUrl": baseUrl, "model": model]
        if let apiKey, !apiKey.isEmpty { body["apiKey"] = apiKey }
        let data = try JSONSerialization.data(withJSONObject: body)
        let r = try await makeRequest("/v1/admin/llm", method: "PUT", body: data, timeout: 10)
        _ = try await send(r)
    }

    // MARK: API

    func health() async -> Result<String, Error> {
        do {
            let r = try await makeRequest("/v1/health", timeout: 6)
            let (d, _) = try await send(r)
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let llm = (j?["llm"] as? Bool) == true ? "AI ✓" : "AI ✗"
            let s = (j?["search"] as? Bool) == true ? "搜索 ✓" : "搜索 ✗"
            return .success("已连接 · \(llm) · \(s)")
        } catch { return .failure(error) }
    }

    func suggest(_ q: String, engine: String) async -> [String] {
        guard let r = try? await makeRequest("/v1/suggest", ["q": q, "engine": engine], timeout: 5),
              let (d, _) = try? await send(r),
              let j = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [] }
        return j["items"] ?? []
    }

    /// Fetch a URL from the server's network. Returns body + final URL.
    func fetch(_ url: URL, maxBytes: Int = 5_000_000) async throws -> (Data, URL, String) {
        let r = try await makeRequest("/v1/fetch", ["url": url.absoluteString, "max": String(maxBytes)], timeout: 25)
        let (d, h) = try await send(r)
        let final = (h.value(forHTTPHeaderField: "x-lunox-final-url")).flatMap(URL.init(string:)) ?? url
        return (d, final, h.value(forHTTPHeaderField: "content-type") ?? "")
    }

    func favicon(host: String) async -> Data? {
        guard let r = try? await makeRequest("/v1/favicon", ["host": host], timeout: 6), let (d, _) = try? await send(r) else { return nil }
        return d
    }

    func search(_ q: String) async throws -> [SearchHit] {
        let r = try await makeRequest("/v1/search", ["q": q], timeout: 15)
        let (d, _) = try await send(r)
        struct R: Decodable { var results: [SearchHit] }
        return try JSONDecoder().decode(R.self, from: d).results
    }

    func act(args: [String: Any]) async throws -> AgentPlan {
        let body = try JSONSerialization.data(withJSONObject: ["task": "act", "args": args])
        let r = try await makeRequest("/v1/ai", method: "POST", body: body, timeout: 60)
        let (d, _) = try await send(r)
        struct R: Decodable { var plan: AgentPlan? }
        guard let p = try JSONDecoder().decode(R.self, from: d).plan else { throw GatewayError.bad }
        return p
    }

    /// Streams text deltas. `sources` receives search citations when present.
    func stream(task: String, args: [String: Any], sources: @escaping ([SearchHit]) -> Void = { _ in }) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    let body = try JSONSerialization.data(withJSONObject: ["task": task, "args": args])
                    let r = try await makeRequest("/v1/ai/stream", method: "POST", body: body, timeout: 90)
                    let (bytes, resp) = try await session.bytes(for: r)
                    guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw GatewayError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
                    if let b64 = h.value(forHTTPHeaderField: "x-lunox-sources"), let d = Data(base64Encoded: b64),
                       let hits = try? JSONDecoder().decode([SearchHit].self, from: d) { sources(hits) }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let p = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if p == "[DONE]" { break }
                        guard let d = p.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if let e = j["error"] as? String { throw NSError(domain: "ai", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
                        if let t = j["t"] as? String { cont.yield(t) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    // MARK: Encrypted bookmark sync (server only stores ciphertext)

    private func syncKey() throws -> SymmetricKey {
        let k = try cfgKeyData()
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: k), salt: Data("lunox-sync-v1".utf8), info: Data(), outputByteCount: 32)
    }
    private func cfgKeyData() throws -> Data { Data(Keychain.get("gateway-key").utf8) }

    func pushSync(bucket: String, json: Data) async throws {
        let sealed = try AES.GCM.seal(json, using: syncKey())
        guard let combined = sealed.combined else { throw GatewayError.bad }
        var r = try await makeRequest("/v1/sync/\(bucket)", method: "PUT")
        r.httpBody = combined
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await send(r)
    }
    func pullSync(bucket: String) async throws -> Data? {
        let r = try await makeRequest("/v1/sync/\(bucket)")
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw GatewayError.bad }
        if h.statusCode == 404 { return nil }
        guard h.statusCode == 200 else { throw GatewayError.http(h.statusCode) }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: d), using: syncKey())
    }
}


final class PinDelegate: NSObject, URLSessionDelegate {
    let pinHost: String, pin: String
    init(pinHost: String, pin: String) { self.pinHost = pinHost; self.pin = pin }
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = ch.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        guard !pinHost.isEmpty, ch.protectionSpace.host == pinHost else { return completionHandler(.performDefaultHandling, nil) }
        Pinning.verify(trust: trust, pin: pin) ? completionHandler(.useCredential, URLCredential(trust: trust)) : completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
