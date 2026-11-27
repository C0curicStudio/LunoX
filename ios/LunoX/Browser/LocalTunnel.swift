import Foundation
import Network

struct TunnelTarget {
    var host: String
    var port: Int
    var key: String
    var pinHost: String     // non-empty = pin this host's certificate (direct-to-server route)
    var pin: String
}

/// A loopback HTTP-CONNECT proxy inside the app. WebKit talks to it; each CONNECT becomes one WebSocket
/// to the gateway's /v1/tunnel (reachable through Cloudflare's edge, which forwards WebSocket but not CONNECT).
/// Guarded by a per-launch random password so other apps on the phone cannot borrow the tunnel.
final class LocalTunnel: NSObject, URLSessionDelegate {
    fileprivate let queue = DispatchQueue(label: "app.lunox.tunnel")
    private var listener: NWListener?
    private let lock = NSLock()
    private var _target: TunnelTarget?
    private(set) var port: UInt16 = 0
    let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    fileprivate var live: [ObjectIdentifier: TunnelConn] = [:]
    // Pre-opened WebSockets: a new connection skips the TCP+TLS+upgrade round trips (browsers open dozens at a time).
    private var warm: [(task: URLSessionWebSocketTask, at: Date)] = []
    private let warmLock = NSLock()
    private let warmTarget = 3

    var target: TunnelTarget? {
        get { lock.lock(); defer { lock.unlock() }; return _target }
        set { lock.lock(); _target = newValue; lock.unlock() }
    }

    fileprivate lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Returns the loopback port (restarts the listener if iOS tore it down while suspended).
    func start() async -> UInt16? {
        if let l = listener, l.state == .ready, port != 0 { return port }
        stop()
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        l.newConnectionHandler = { [weak self] c in
            guard let self else { c.cancel(); return }
            let t = TunnelConn(conn: c, owner: self)
            self.queue.async { self.live[ObjectIdentifier(t)] = t }
            t.start()
        }
        return await withCheckedContinuation { cont in
            var done = false
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if !done { done = true; self?.port = l.port?.rawValue ?? 0; cont.resume(returning: self?.port) }
                case .failed, .cancelled:
                    if !done { done = true; cont.resume(returning: nil) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    private func makeSocket(_ t: TunnelTarget, host: String? = nil, port: Int? = nil) -> URLSessionWebSocketTask? {
        var c = URLComponents()
        c.scheme = "wss"; c.host = t.host; c.port = t.port; c.path = "/v1/tunnel"
        if let host, let port { c.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port))] }
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(t.key)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        return task
    }

    /// A ready socket (pre-opened if possible) already told to connect to host:port.
    fileprivate func socket(for host: String, port: Int) -> URLSessionWebSocketTask? {
        guard let t = target else { return nil }
        warmLock.lock()
        warm.removeAll { Date().timeIntervalSince($0.at) > 45 }          // the server drops idle warm sockets after 90s
        let w = warm.popLast()
        warmLock.unlock()
        topUpWarm()
        if let w {
            let msg = "{\"host\":\"\(host)\",\"port\":\(port)}"
            w.task.send(.string(msg)) { _ in }
            return w.task
        }
        return makeSocket(t, host: host, port: port)
    }

    func topUpWarm() {
        guard let t = target else { return }
        warmLock.lock()
        let need = warmTarget - warm.count
        warmLock.unlock()
        guard need > 0 else { return }
        for _ in 0..<need {
            guard let task = makeSocket(t) else { continue }
            warmLock.lock(); warm.append((task, Date())); warmLock.unlock()
        }
    }

    func stop() {
        warmLock.lock(); warm.forEach { $0.task.cancel(with: .goingAway, reason: nil) }; warm.removeAll(); warmLock.unlock()
        listener?.cancel(); listener = nil; port = 0
        queue.async { self.live.values.forEach { $0.close() }; self.live.removeAll() }
    }

    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = ch.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if let t = target, !t.pinHost.isEmpty, ch.protectionSpace.host == t.pinHost {
            Pinning.verify(trust: trust, pin: t.pin) ? completionHandler(.useCredential, URLCredential(trust: trust)) : completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)   // Cloudflare edge: normal certificate validation
        }
    }

    fileprivate func forget(_ c: TunnelConn) { queue.async { self.live[ObjectIdentifier(c)] = nil } }
}

fileprivate final class TunnelConn {
    private let conn: NWConnection
    private unowned let owner: LocalTunnel
    private var ws: URLSessionWebSocketTask?
    private var buf = Data()
    private var closed = false
    private let lock = NSLock()

    init(conn: NWConnection, owner: LocalTunnel) { self.conn = conn; self.owner = owner }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.close() }
            if case .cancelled = st { self?.close() }
        }
        conn.start(queue: owner.queue)
        readHead()
    }

    func close() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; lock.unlock()
        ws?.cancel(with: .normalClosure, reason: nil)
        conn.cancel()
        owner.forget(self)
    }

    private func reply(_ s: String, thenClose: Bool) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { [weak self] _ in if thenClose { self?.close() } })
    }

    private func readHead() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self else { return }
            if let d = data { self.buf.append(d) }
            if let r = self.buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.buf[..<r.lowerBound], as: UTF8.self)
                let rest = Data(self.buf[r.upperBound...])
                self.open(head: head, rest: rest)
            } else if self.buf.count > 16384 || done || err != nil { self.close() }
            else { self.readHead() }
        }
    }

    private func open(head: String, rest: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count >= 2, first[0].uppercased() == "CONNECT" else { return reply("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n", thenClose: true) }

        let want = "Basic " + Data("lunox:\(owner.token)".utf8).base64EncodedString()
        let got = lines.dropFirst().first { $0.lowercased().hasPrefix("proxy-authorization:") }?.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) ?? ""
        guard got == want else {
            return reply("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"lunox\"\r\nContent-Length: 0\r\n\r\n", thenClose: true)
        }
        let hp = first[1]
        guard let colon = hp.lastIndex(of: ":"), let port = Int(hp[hp.index(after: colon)...]) else { return reply("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", thenClose: true) }
        let host = String(hp[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let t = owner.target else { return reply("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n", thenClose: true) }

        _ = t
        guard let task = owner.socket(for: host, port: port) else { return close() }
        ws = task
        task.receive { [weak self] result in
            guard let self else { return }
            guard case .success(let m) = result, case .string(let s) = m, s == "ok" else {
                return self.reply("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n", thenClose: true)
            }
            self.conn.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] e in
                guard let self, e == nil else { return }
                if !rest.isEmpty { self.ws?.send(.data(rest)) { _ in } }
                self.pumpUp(); self.pumpDown()
            })
        }
    }

    private func pumpUp() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let d = data, !d.isEmpty {
                self.ws?.send(.data(d)) { e in
                    if e != nil || done || err != nil { self.close() } else { self.pumpUp() }
                }
            } else if done || err != nil { self.close() } else { self.pumpUp() }
        }
    }

    private func pumpDown() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let d)):
                self.conn.send(content: d, completion: .contentProcessed { e in if e != nil { self.close() } else { self.pumpDown() } })
            case .success: self.pumpDown()
            case .failure: self.close()
            }
        }
    }
}
