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
        let titles = ["服务器配对", "直连网关（证书固定）", "Cloudflare 边缘", "服务器访问外网", "代理实测（App 内）", "WebKit 实测（网页真实路径）", "本机直连 Google（对照）"]
        steps = titles.enumerated().map { DiagStep(id: $0.offset, title: $0.element) }
        let s = store.settings, p = s.prefs
        let target = URL(string: "https://www.google.com/robots.txt")!

        // 0 pairing
        steps[0].state = .running
        if s.gatewayConfigured { set(0, .ok, "\(p.gatewayHost):\(p.gatewayPort)，密钥与证书指纹已填") }
        else { set(0, .fail, "还没有配对：缺少" + (s.gatewayKey.isEmpty ? "访问密钥 " : "") + (Pinning.normalize(p.gatewayPin).count == 64 ? "" : "证书指纹") + "。请在 设置 › 网络与线路 导入 lunox://setup 链接。"); return }

        // 1 direct gateway
        steps[1].state = .running
        let d = await store.gateway.ping(host: p.gatewayHost, port: p.gatewayPort, pinned: true)
        if let ms = d.ms { set(1, .ok, "\(Int(ms / 2)) ms") }
        else { set(1, .fail, (d.error ?? "无法连接") + "\n常见原因：云服务商安全组没放行 TCP \(p.gatewayPort)；证书指纹不一致；服务没运行。") }

        // 2 edge
        steps[2].state = .running
        if p.edgeHost.isEmpty { set(2, .warn, "App 还没有 Cloudflare 地址（需要先能连上网关，或在服务器运行 edge.sh）") }
        else {
            let e = await store.gateway.ping(host: p.edgeHost, port: p.edgePort, pinned: false)
            if let ms = e.ms { set(2, .ok, "\(p.edgeHost) · \(Int(ms / 2)) ms" + (e.colo.map { " · 节点 \($0)" } ?? "")) }
            else { set(2, .warn, "\(p.edgeHost)：\(e.error ?? "无法连接")") }
        }

        // 3 server -> internet
        steps[3].state = .running
        if d.ms != nil || store.edge.results["edge"]?.ms != nil || p.edgeHost.isEmpty == false {
            if let ms = await store.gateway.probeViaServer(URL(string: "https://www.google.com")!) { set(3, .ok, "服务器访问 Google 正常（往返 \(Int(ms)) ms）") }
            else { set(3, .fail, "服务器自己访问不了 Google，或网关接口不可达") }
        } else { set(3, .warn, "网关不可达，跳过") }

        // 4 proxy through URLSession (same ProxyConfiguration object WebKit gets)
        steps[4].state = .running
        if let cfg = store.router.makeConfig(loopback: false, matchDomains: nil) {
            let c = URLSessionConfiguration.ephemeral
            c.proxyConfigurations = [cfg]; c.timeoutIntervalForRequest = 12; c.waitsForConnectivity = false
            let sess = URLSession(configuration: c); defer { sess.finishTasksAndInvalidate() }
            let t0 = Date()
            do {
                let (_, r) = try await sess.data(from: target)
                let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                set(4, code == 200 ? .ok : .warn, "经服务器代理访问 Google：HTTP \(code)，\(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            } catch { let x = error as NSError; set(4, .fail, "\(x.localizedDescription)（\(x.domain) \(x.code)）\n代理隧道没有建立：检查服务器端口、密钥、证书指纹。") }
        } else { set(4, .fail, "无法生成代理配置") }

        // 5 the real WebKit path (forces google.com onto the proxy list first)
        steps[5].state = .running
        store.router.markBlocked("google.com")
        let viaTunnel = store.edge.usesTunnel
        let r = await WebKitProbe().run(store: store, url: target, timeout: 14)
        if let e = r.error { set(5, .fail, (viaTunnel ? "路径：本地隧道 → Cloudflare\n" : "路径：直连代理\n") + e) }
        else { set(5, .ok, (viaTunnel ? "经本地隧道/Cloudflare" : "经服务器代理") + "加载成功，\(Int(r.ms)) ms") }

        // 6 control: direct, no proxy
        steps[6].state = .running
        let c2 = URLSessionConfiguration.ephemeral; c2.connectionProxyDictionary = [:]; c2.timeoutIntervalForRequest = 5
        let s2 = URLSession(configuration: c2); defer { s2.finishTasksAndInvalidate() }
        if let (_, resp) = try? await s2.data(from: target), (resp as? HTTPURLResponse)?.statusCode == 200 { set(6, .ok, "本机可以直连 Google（不需要代理）") }
        else { set(6, .ok, "本机直连 Google 不通（需要代理，符合预期）") }
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
