import Foundation
import SwiftUI

struct Route: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let isEdge: Bool
}
struct RouteResult: Equatable { var ms: Double?; var colo: String?; var error: String? = nil }

/// Measures every way into the server (direct vs Cloudflare edge) and keeps using the fastest one.
@MainActor
final class EdgeSelector: ObservableObject {
    @Published private(set) var results: [String: RouteResult] = [:]
    @Published private(set) var activeID = "direct"
    @Published private(set) var measuring = false
    @Published private(set) var server: ServerConfig?
    let tunnel = LocalTunnel()
    var onChange: (() -> Void)?
    private let settings: Settings
    private let gateway: GatewayClient
    var hy2: Hy2Manager?
    private var lastMeasure = Date.distantPast

    init(settings: Settings, gateway: GatewayClient) { self.settings = settings; self.gateway = gateway }

    var routes: [Route] {
        let p = settings.prefs
        var r = [Route(id: "direct", name: "直连服务器", host: p.gatewayHost, port: p.gatewayPort, isEdge: false)]
        if !p.edgeHost.isEmpty { r.append(Route(id: "edge", name: "Cloudflare 边缘", host: p.edgeHost, port: p.edgePort, isEdge: true)) }
        return r
    }
    var active: Route? { routes.first { $0.id == activeID } ?? routes.first }
    /// WebKit traffic only goes through the in-app loopback tunnel when the user opted in, or the server cannot be reached directly.
    var usesTunnel: Bool {
        guard active?.isEdge == true, tunnel.port != 0 else { return false }
        return settings.prefs.preferEdgeTunnel || results["direct"]?.ms == nil
    }

    /// Re-test routes (at most every 4 minutes unless forced) and switch if another is clearly faster.
    func measure(force: Bool = false) async {
        guard settings.gatewayConfigured, !measuring else { return }
        if !force, Date().timeIntervalSince(lastMeasure) < 240 { return }
        var learned = true
        // if the server's answer is missing (tunnel not up yet / network just changed) look again in under a minute, not in four
        measuring = true; defer { measuring = false; lastMeasure = learned ? Date() : Date().addingTimeInterval(-200) }
        hy2?.ensureRunning(enabled: settings.prefs.useHy2)            // the gateway is reached through the tunnel when direct TCP is blocked
        learned = await refreshServerConfig()
        let rs = routes
        var out: [String: RouteResult] = [:]
        await withTaskGroup(of: (String, RouteResult).self) { g in
            for r in rs { g.addTask { (r.id, await self.gateway.ping(host: r.host, port: r.port, pinned: !r.isEdge)) } }
            for await (id, res) in g { out[id] = res }
        }
        results = out
        let ok = rs.compactMap { r in out[r.id]?.ms.map { (r, $0) } }.sorted { $0.1 < $1.1 }
        guard let best = ok.first else { return }
        // hysteresis: only move if the new route is >15% faster than the current one (or the current one failed)
        let curMs = out[activeID]?.ms
        let switchTo: Route
        if let cur = rs.first(where: { $0.id == activeID }), let cm = curMs, best.0.id != cur.id, best.1 > cm * 0.85 { switchTo = cur } else { switchTo = best.0 }
        await activate(switchTo)
    }

    /// The gateway tells us its Cloudflare address (and model status): nothing to type in the app.
    @discardableResult
    func refreshServerConfig() async -> Bool {
        guard let c = await gateway.config() else { return false }
        server = c
        if settings.prefs.useHy2 { hy2?.update(c.hy2) } else { hy2?.stop() }
        if let e = c.edge, !e.isEmpty, (settings.prefs.edgeHost != e || settings.prefs.edgePort != 443) {
            settings.prefs.edgeHost = e; settings.prefs.edgePort = 443
        }
        return true
    }

    private func activate(_ r: Route) async {
        let changed = activeID != r.id
        activeID = r.id
        gateway.endpoint = r.isEdge ? (r.host, r.port) : nil
        if r.isEdge {
            tunnel.target = TunnelTarget(host: r.host, port: r.port, key: settings.gatewayKey, pinHost: "", pin: "")
            let before = tunnel.port
            let p = await tunnel.start()
            tunnel.topUpWarm()
            if changed || p != before { onChange?() }
        } else if changed { onChange?() }
    }

    /// Call when the app returns to the foreground: iOS may have closed the loopback listener.
    func resume() async {
        if active?.isEdge == true {
            let before = tunnel.port
            let p = await tunnel.start()
            if p != before { onChange?() }
        }
        await measure()
    }

    var summary: String {
        guard let a = active else { return "" }
        let r = results[a.id]
        return "\(a.name)" + (r?.ms.map { " · \(Int($0)) ms" } ?? "") + (r?.colo.map { " · \($0)" } ?? "")
    }
}
