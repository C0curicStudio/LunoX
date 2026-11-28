import SwiftUI
import WebKit

struct DiagStep: Identifiable {
    enum State { case pending, running, ok, warn, fail }
    let id: Int
    var title: String
    var state: State = .pending
    var detail = ""
}

/// Loads a URL in a throw-away WKWebView on the real data store, i.e. exactly the path a page takes.
@MainActor
private final class WebKitProbe: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<String?, Never>?
    private var wv: WKWebView?

    func run(store: BrowserStore, url: URL, timeout: TimeInterval) async -> (ms: Double, error: String?) {
        let t0 = Date()
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = store.dataStore(isPrivate: false)
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: cfg)
        w.navigationDelegate = self; wv = w
        let err: String? = await withCheckedContinuation { c in
            cont = c
            w.load(URLRequest(url: url, timeoutInterval: timeout))
            Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); self.finish("超时：\(Int(timeout)) 秒内没有加载完成") }
        }
        return (Date().timeIntervalSince(t0) * 1000, err)
    }
    private func finish(_ e: String?) { guard let c = cont else { return }; cont = nil; wv?.stopLoading(); wv = nil; c.resume(returning: e) }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(nil) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { let x = e as NSError; finish("\(x.localizedDescription)（\(x.domain) \(x.code)）") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { let x = e as NSError; finish("\(x.localizedDescription)（\(x.domain) \(x.code)）") }
}

@MainActor
final class Diagnostics: ObservableObject {
    @Published var steps: [DiagStep] = []
    @Published var running = false

    private func set(_ i: Int, _ s: DiagStep.State, _ d: String) { steps[i].state = s; steps[i].detail = d }

    var report: String { steps.map { "[\($0.state)] \($0.title): \($0.detail)" }.joined(separator: "\n") }

    func run(store: BrowserStore) async {
        guard !running else { return }
        running = true; defer { running = false }
        let titles = ["服务器配对", "直连网关（证书固定）", "Cloudflare 边缘", "服务器访问外网", "代理实测（App 内）", "WebKit 实测（网页真实路径）", "本机直连 Google（对照）", "内置 Hysteria2（你的节点）"]
        steps = titles.enumerated().map { DiagStep(id: $0.offset, title: $0.element) }
        let s = store.settings, p = s.prefs
        let target = URL(string: "https://www.google.com/robots.txt")!
        let paired = s.gatewayConfigured

        // 0 pairing (Hysteria2 does not need it, so the rest still runs)
        if paired { set(0, .ok, "\(p.gatewayHost):\(p.gatewayPort)，密钥与证书指纹已填") }
        else { set(0, .warn, "还没有配对网关（AI/搜索/同步和备用代理需要）。内置 Hysteria2 不依赖它。") }

        var directMs: Double?
        if paired {
            // 1 direct gateway
            steps[1].state = .running
            let d = await store.gateway.ping(host: p.gatewayHost, port: p.gatewayPort, pinned: true)
            directMs = d.ms
            if let ms = d.ms { set(1, .ok, "\(Int(ms / 2)) ms") }
            else {
                // direct TCP failed: can the server still be reached through the Hysteria2 tunnel?
                let t = await store.gateway.healthViaTunnel()
                if let ms = t.ms { set(1, .warn, "直连不通（\(d.error ?? "无法连接")），但经 Hysteria2 隧道可达（\(ms) ms）。App 会自动走隧道访问网关，AI/搜索/同步可用。") }
                else { set(1, .fail, (d.error ?? "无法连接") + "\n隧道里也连不上：\(t.error ?? "")\n常见原因：证书指纹不一致；网关服务没运行；云安全组没放行 TCP \(p.gatewayPort)。") }
            }
            // 2 edge
            steps[2].state = .running
            if p.edgeHost.isEmpty { set(2, .warn, "App 还没有 Cloudflare 地址（先在服务器运行 edge.sh，且网关要能连上）") }
            else {
                let e = await store.gateway.ping(host: p.edgeHost, port: p.edgePort, pinned: false)
                if let ms = e.ms { set(2, .ok, "\(p.edgeHost) · \(Int(ms / 2)) ms" + (e.colo.map { " · 节点 \($0)" } ?? "")) }
                else { set(2, .warn, "\(p.edgeHost)：\(e.error ?? "无法连接")") }
            }
            // 3 server -> internet
            steps[3].state = .running
            if let ms = await store.gateway.probeViaServer(URL(string: "https://www.google.com")!) { set(3, .ok, "服务器访问 Google 正常（往返 \(Int(ms)) ms）") }
            else { set(3, .warn, "网关接口不可达或服务器访问不了 Google") }
            await store.edge.refreshServerConfig()          // also hands the Hysteria2 parameters to the built-in core
        } else { for i in 1...3 { set(i, .warn, "未配对，跳过") } }

        // 7 built-in Hysteria2 (run before the WebKit test so that test uses it)
        steps[7].state = .running
        let hy = store.hy2
        if !hy.compiledIn { set(7, .warn, "这个安装包没有内置 Hysteria2 内核") }
        else if !hy.configured { set(7, .warn, "还没有 Hysteria2 参数。在服务器运行：sudo bash server/deploy/set-hy2.sh，再回到这里重新检测。") }
        else if !p.useHy2 { set(7, .warn, "已在设置里关闭") }
        else {
            let r = await hy.probe()
            if let e = r.error { set(7, .fail, "\(e)\n检查：节点密码/混淆密码/SNI/证书指纹是否与服务器一致；服务器 UDP \(hy.config?.port ?? 443) 是否放行。") }
            else { set(7, .ok, "Hysteria2 隧道正常（\(hy.config?.host ?? ""):\(hy.config?.port ?? 0)），打开一条连接 \(r.ms) ms") }
        }

        // 4 proxy through URLSession (same ProxyConfiguration object WebKit gets)
        steps[4].state = .running
        if let cfg = store.router.makeHy2Config(matchDomains: nil) ?? store.router.makeConfig(loopback: false, matchDomains: nil) {
            let c = URLSessionConfiguration.ephemeral
            c.proxyConfigurations = [cfg]; c.timeoutIntervalForRequest = 12; c.waitsForConnectivity = false
            let sess = URLSession(configuration: c); defer { sess.finishTasksAndInvalidate() }
            let t0 = Date()
            do {
                let (_, r) = try await sess.data(from: target)
                let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                set(4, code == 200 ? .ok : .warn, "经代理访问 Google：HTTP \(code)，\(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            } catch { let x = error as NSError; set(4, .fail, "\(x.localizedDescription)（\(x.domain) \(x.code)）\n代理隧道没有建立。") }
        } else { set(4, .warn, "没有可用的代理（既未配对网关，也没有 Hysteria2）") }

        // 5 the real WebKit path (forces google.com onto the proxy list first)
        steps[5].state = .running
        store.router.markBlocked("google.com")
        let via = (p.useHy2 && hy.running) ? "内置 Hysteria2" : (store.edge.usesTunnel ? "本地隧道 → Cloudflare" : "网关代理")
        let r = await WebKitProbe().run(store: store, url: target, timeout: 14)
        if let e = r.error { set(5, .fail, "路径：\(via)\n\(e)") }
        else { set(5, .ok, "经\(via)加载成功，\(Int(r.ms)) ms") }

        // 6 control: direct, no proxy
        steps[6].state = .running
        let c2 = URLSessionConfiguration.ephemeral; c2.connectionProxyDictionary = [:]; c2.timeoutIntervalForRequest = 5
        let s2 = URLSession(configuration: c2); defer { s2.finishTasksAndInvalidate() }
        if let (_, resp) = try? await s2.data(from: target), (resp as? HTTPURLResponse)?.statusCode == 200 { set(6, .ok, "本机可以直连 Google（不需要代理）") }
        else { set(6, .ok, "本机直连 Google 不通（需要代理，符合预期）") }
        _ = directMs
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @StateObject private var diag = Diagnostics()

    var body: some View {
        List {
            Section {
                ForEach(diag.steps) { st in
                    HStack(alignment: .top, spacing: 12) {
                        icon(st.state).frame(width: 24).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(st.title).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.ink)
                            if !st.detail.isEmpty { Text(st.detail).font(.system(size: 13)).foregroundStyle(st.state == .fail ? Color.red : theme.inkSoft).textSelection(.enabled) }
                        }
                    }.padding(.vertical, 2)
                }
            }.listRowBackground(theme.surface)
            Section {
                Button { Task { await diag.run(store: store) } } label: { Label(diag.running ? "检测中…" : "重新检测", systemImage: "arrow.clockwise") }.disabled(diag.running)
                if !diag.steps.isEmpty { Button { UIPasteboard.general.string = diag.report; Haptics.ok() } label: { Label("复制报告", systemImage: "doc.on.doc") } }
            }.listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(theme.background.ignoresSafeArea())
        .navigationTitle("连接诊断").navigationBarTitleDisplayMode(.inline)
        .task { await diag.run(store: store) }
    }

    @ViewBuilder private func icon(_ s: DiagStep.State) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(theme.inkSoft.opacity(0.5))
        case .running: ProgressView()
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
