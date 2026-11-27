import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @EnvironmentObject var offline: OfflineCache
    @EnvironmentObject var edge: EdgeSelector
    @State private var key = ""
    @State private var testResult = ""
    @State private var testing = false
    @State private var link = ""
    @State private var forced = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("通用") {
                Picker("搜索引擎", selection: $settings.prefs.engineID) { ForEach(SearchEngine.all) { Text($0.name).tag($0.id) } }
                TextField("主页（留空 = 新标签页）", text: $settings.prefs.homepage).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Toggle("搜索建议（经服务器）", isOn: $settings.prefs.searchSuggest)
                Toggle("启动时恢复标签页", isOn: $settings.prefs.restoreTabs)
                Toggle("默认请求桌面版网站", isOn: $settings.prefs.defaultDesktop)
            }

            Section("外观") {
                Picker("外观", selection: $settings.prefs.appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } }
                NavigationLink("主题：\(settings.family.name)") { ThemesView() }
                Toggle("原生化网页（去缩放/去延迟/隐藏滚动条）", isOn: $settings.prefs.nativeMode)
            }

            Section(header: Text("网络与服务器"), footer: Text("智能模式：访问网站前先本地直连探测；不通则该站点自动走你的服务器代理（证书固定 + 密钥认证）。")) {
                Picker("路由", selection: $settings.prefs.routing) { ForEach(RoutingMode.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: settings.prefs.routing) { _, _ in router.apply() }
                TextField("服务器地址", text: $settings.prefs.gatewayHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack { Text("端口"); Spacer(); TextField("8443", value: $settings.prefs.gatewayPort, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                SecureField(settings.gatewayKey.isEmpty ? "访问密钥" : "访问密钥（已保存到钥匙串）", text: $key)
                    .onSubmit { commitKey() }
                TextField("证书指纹 SHA-256", text: $settings.prefs.gatewayPin, axis: .vertical).font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    TextField("粘贴 lunox://setup 配置链接", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("导入") {
                        if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), settings.applySetupLink(u) { link = ""; testResult = "已导入"; router.apply() } else { testResult = "链接无效" }
                    }.disabled(link.isEmpty)
                }
                Button(testing ? "测试中…" : "测试连接") { commitKey(); Task { await test() } }.disabled(testing)
                if !testResult.isEmpty { Text(testResult).font(.footnote).foregroundStyle(testResult.hasPrefix("已连接") || testResult == "已导入" ? .green : .secondary) }
                TextField("强制走服务器的域名（逗号分隔）", text: $forced).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onAppear { forced = settings.prefs.forcedProxyDomains.joined(separator: ",") }
                    .onSubmit { settings.prefs.forcedProxyDomains = forced.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; router.apply() }
                TextField("Cloudflare 边缘域名（可选，例如 edge.example.com）", text: $settings.prefs.edgeHost).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit { Task { await edge.measure(force: true) } }
                ForEach(edge.routes) { r in
                    HStack {
                        Image(systemName: r.id == edge.activeID ? "checkmark.circle.fill" : "circle").foregroundStyle(r.id == edge.activeID ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(r.name); Text("\(r.host):\(r.port)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let res = edge.results[r.id] {
                            if let ms = res.ms { Text("\(Int(ms)) ms" + (res.colo.map { " · \($0)" } ?? "")).font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
                            else { Text("不可用").font(.footnote).foregroundStyle(.red) }
                        }
                    }
                }
                Button(edge.measuring ? "测速中…" : "重新测速并自动选择最快线路") { commitKey(); Task { await edge.measure(force: true) } }.disabled(edge.measuring)
                if !router.proxied.isEmpty {
                    DisclosureGroup("当前走服务器的站点（\(router.proxied.count)）") {
                        ForEach(router.proxied.keys.sorted(), id: \.self) { Text($0).font(.footnote) }
                        Button("重置检测结果", role: .destructive) { router.reset() }
                    }
                }
            }

            Section(header: Text("离线"), footer: Text("访问过的网页会自动保存为离线副本；界面本身是原生的，断网也能使用。已用 \(ByteCountFormatter.string(fromByteCount: Int64(offline.totalBytes), countStyle: .file))。")) {
                Toggle("自动缓存已访问页面", isOn: $settings.prefs.offlineCache)
                Stepper("缓存上限 \(settings.prefs.offlineLimitMB) MB", value: $settings.prefs.offlineLimitMB, in: 50...2000, step: 50)
                Button("清空离线缓存", role: .destructive) { offline.clear() }
            }

            Section("隐私与安全") {
                Toggle("拦截广告与跟踪器", isOn: $settings.prefs.blockTrackers)
                Toggle("仅 HTTPS（自动升级）", isOn: $settings.prefs.httpsOnly)
                Toggle("拦截弹出窗口", isOn: $settings.prefs.blockPopups)
                Toggle("隐藏 Cookie 提示横幅", isOn: $settings.prefs.hideCookieBanners)
                Toggle("Face ID / 密码锁定 App", isOn: $settings.prefs.appLock)
                Button("清除浏览数据…", role: .destructive) { confirmClear = true }
            }

            Section(header: Text("智能功能"), footer: Text("AI 请求由你的服务器转发，API 密钥只存放在服务器上。")) {
                Toggle("启用 AI 助手与智能搜索", isOn: $settings.prefs.aiEnabled)
                Toggle("同步书签（端到端加密）", isOn: $settings.prefs.syncBookmarks)
                if settings.prefs.syncBookmarks {
                    Button("立即同步") { Task { await store.sync() } }
                    if !store.syncStatus.isEmpty { Text(store.syncStatus).font(.footnote).foregroundStyle(.secondary) }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("内核", value: "WebKit（iOS 系统）")
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("清除浏览数据", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("历史记录 + Cookie 与网站数据", role: .destructive) { Task { await store.clearBrowsingData(history: true, website: true, offline: false) } }
            Button("全部（含离线缓存）", role: .destructive) { Task { await store.clearBrowsingData(history: true, website: true, offline: true) } }
            Button("取消", role: .cancel) {}
        }
        .onDisappear { commitKey(); router.apply() }
    }

    private func commitKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { settings.gatewayKey = k; key = "" }
        settings.prefs.gatewayPin = Pinning.normalize(settings.prefs.gatewayPin)
    }

    private func test() async {
        testing = true; defer { testing = false }
        switch await store.gateway.health() {
        case .success(let s): testResult = s; router.apply(); Haptics.ok()
        case .failure(let e): testResult = "连接失败：\(e.localizedDescription)"; Haptics.warn()
        }
    }
}
