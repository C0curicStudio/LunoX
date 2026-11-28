import SwiftUI

// MARK: - Flat iOS settings (inset grouped lists, hairline separators, native push transitions)

private struct FlatList<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme
    var body: some View {
        List { content() }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .listRowSeparatorTint(theme.inkSoft.opacity(0.18))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// Icon + title + trailing value, exactly like a system settings row.
private struct RowLabel: View {
    var icon: String
    var title: String
    var value: String = ""
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
            Text(title).foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).foregroundStyle(theme.inkSoft).lineLimit(1) }
        }
        .font(.system(size: 17))
    }
}

private extension View {
    func sectionStyle(_ surface: Color) -> some View { self.listRowBackground(surface) }
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var offline: OfflineCache
    @EnvironmentObject var edge: EdgeSelector
    @EnvironmentObject var ext: ExtensionManager
    @Environment(\.theme) private var theme

    var body: some View {
        FlatList(title: "设置") {
            Section {
                NavigationLink { GeneralSettings() } label: { RowLabel(icon: "gearshape", title: "通用", value: settings.engine.name) }
                NavigationLink { AppearanceSettings() } label: { RowLabel(icon: "circle.lefthalf.filled", title: "外观与主题", value: settings.family.name) }
                NavigationLink { NetworkSettings() } label: { RowLabel(icon: "bolt.horizontal.circle", title: "网络与线路", value: networkValue) }
                NavigationLink { PrivacySettings() } label: { RowLabel(icon: "lock.shield", title: "隐私与安全") }
            }.sectionStyle(theme.surface)

            Section {
                NavigationLink { AISettings() } label: { RowLabel(icon: "sparkles", title: "智能与 AI", value: aiValue) }
                NavigationLink { OfflineSettings() } label: { RowLabel(icon: "arrow.down.circle", title: "离线与缓存", value: ByteCountFormatter.string(fromByteCount: Int64(offline.totalBytes), countStyle: .file)) }
                NavigationLink { ExtensionsView() } label: { RowLabel(icon: "puzzlepiece.extension", title: "扩展与脚本", value: "\(ext.items.filter(\.enabled).count) 个已启用") }
            } header: { Text("功能").textCase(nil) }.sectionStyle(theme.surface)

            Section {
                RowLabel(icon: "info.circle", title: "版本", value: "1.0.0")
                RowLabel(icon: "globe", title: "网页内核", value: "WebKit")
            } header: { Text("关于").textCase(nil) }.sectionStyle(theme.surface)
        }
    }

    private var networkValue: String {
        if !settings.gatewayConfigured { return "未配对" }
        guard let a = edge.active, let ms = edge.results[a.id]?.ms else { return "智能" }
        return "\(a.isEdge ? "边缘" : "直连") \(Int(ms / 2)) ms"
    }
    private var aiValue: String {
        guard settings.prefs.aiEnabled else { return "已关闭" }
        return edge.server?.llm.configured == true ? "已就绪" : "未设置模型"
    }
}

// MARK: 通用

struct GeneralSettings: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    var body: some View {
        FlatList(title: "通用") {
            Section {
                Picker(selection: $settings.prefs.engineID) { ForEach(SearchEngine.all) { Text($0.name).tag($0.id) } } label: { RowLabel(icon: "magnifyingglass", title: "搜索引擎") }
                HStack(spacing: 14) {
                    Image(systemName: "house").font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
                    TextField("主页（留空 = 新标签页）", text: $settings.prefs.homepage).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
            }.sectionStyle(theme.surface)
            Section {
                Picker(selection: $settings.prefs.translateTarget) {
                    Text("跟随系统（\(LanguageUtil.name(LanguageUtil.systemTarget()))）").tag("")
                    ForEach(LanguageUtil.supported, id: \.code) { Text($0.name).tag($0.code) }
                } label: { RowLabel(icon: "character.bubble", title: "翻译成") }
                Toggle(isOn: $settings.prefs.autoTranslatePages) { RowLabel(icon: "wand.and.stars", title: "自动翻译外语网页") }
                Toggle(isOn: $settings.prefs.translateNews) { RowLabel(icon: "newspaper", title: "自动翻译新闻标题") }
                Toggle(isOn: $settings.prefs.translateAIFallback) { RowLabel(icon: "sparkles", title: "苹果翻译不可用时用服务器 AI") }
            } header: { Text("翻译").textCase(nil) }
            footer: { Text("使用 Apple 系统翻译：网页文字只在手机上处理。每个语言首次使用时系统会弹出它自己的下载提示，下载一次后离线秒翻。服务器 AI 默认关闭（开启后网页文字会发送到你的服务器和模型）。") }.sectionStyle(theme.surface)
            Section {
                Toggle(isOn: $settings.prefs.searchSuggest) { RowLabel(icon: "text.magnifyingglass", title: "搜索建议") }
                Toggle(isOn: $settings.prefs.restoreTabs) { RowLabel(icon: "arrow.counterclockwise", title: "启动时恢复标签页") }
                Toggle(isOn: $settings.prefs.defaultDesktop) { RowLabel(icon: "desktopcomputer", title: "默认请求桌面版网站") }
            }.sectionStyle(theme.surface)
            Section {
                Toggle(isOn: $settings.prefs.nativeTemplates) { RowLabel(icon: "rectangle.stack.badge.play", title: "网站原生模板（YouTube、哔哩哔哩、X、Instagram）") }
                Toggle(isOn: $settings.prefs.compactBar) { RowLabel(icon: "arrow.down.right.and.arrow.up.left", title: "始终使用精简底部栏") }
            } header: { Text("界面").textCase(nil) }
            footer: { Text("原生模板直接请求视频数据并用系统界面渲染，不加载网页，打开更快；页面右上角“原网页”可随时切回网页。底部栏可向下滑缩小、点一下展开。") }.sectionStyle(theme.surface)
        }
    }
}

// MARK: 外观

struct AppearanceSettings: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    var body: some View {
        FlatList(title: "外观与主题") {
            Section {
                Picker(selection: $settings.prefs.appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } } label: { RowLabel(icon: "circle.lefthalf.filled", title: "外观") }
                NavigationLink { ThemesView() } label: { RowLabel(icon: "paintpalette", title: "主题", value: settings.family.name) }
            }.sectionStyle(theme.surface)
            Section {
                Toggle(isOn: $settings.prefs.nativeMode) { RowLabel(icon: "iphone", title: "网页原生化适配") }
                Toggle(isOn: $settings.prefs.autoDarkPages) { RowLabel(icon: "moon.stars", title: "深色模式下自动反色浅色网页") }
                Toggle(isOn: $settings.prefs.hideCookieBanners) { RowLabel(icon: "rectangle.badge.xmark", title: "隐藏 Cookie 横幅") }
            } footer: { Text("自动适配：修正没有适配手机的页面、让网页自带的底栏避开工具栏、表单控件使用主题色、输入时不再误缩放。") }
            .sectionStyle(theme.surface)
        }
    }
}

// MARK: 网络

struct NetworkSettings: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @EnvironmentObject var edge: EdgeSelector
    @Environment(\.theme) private var theme
    @State private var key = ""
    @State private var link = ""
    @State private var forced = ""
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        FlatList(title: "网络与线路") {
            Section {
                Picker(selection: $settings.prefs.routing) { ForEach(RoutingMode.allCases) { Text($0.short).tag($0) } } label: { RowLabel(icon: "arrow.triangle.branch", title: "访问方式") }
                    .onChange(of: settings.prefs.routing) { _, _ in router.apply() }
            } footer: { Text("智能：先直连探测，不通或明显更慢时该站点自动改走你的服务器（加密隧道）。") }.sectionStyle(theme.surface)

            Section {
                Toggle(isOn: $settings.prefs.useHy2) { RowLabel(icon: "bolt.shield", title: "使用内置 Hysteria2") }
                    .onChange(of: settings.prefs.useHy2) { _, on in if on { store.hy2.start() } else { store.hy2.stop() }; router.apply() }
                RowLabel(icon: "dot.radiowaves.left.and.right", title: "Hysteria2 状态", value: hy2Value)
            } header: { Text("内置 Hysteria2（你的节点）").textCase(nil) }
            footer: { Text("节点参数由服务器提供（在服务器运行 set-hy2.sh 一次），App 里不用填，也不需要另开 VPN 软件。") }.sectionStyle(theme.surface)

            Section {
                ForEach(edge.routes) { r in
                    HStack(spacing: 14) {
                        Image(systemName: r.id == edge.activeID ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .light))
                            .foregroundStyle(r.id == edge.activeID ? theme.accent : theme.inkSoft).frame(width: 26)
                        Text(r.name).foregroundStyle(theme.ink)
                        Spacer()
                        if let res = edge.results[r.id] {
                            if let ms = res.ms { Text("\(Int(ms / 2)) ms" + (res.colo.map { " · \($0)" } ?? "")).monospacedDigit().foregroundStyle(theme.inkSoft) }
                            else { Text("不可用").foregroundStyle(.red) }
                        } else if edge.measuring { ProgressView() }
                    }.font(.system(size: 17))
                }
                Button { Task { await edge.measure(force: true) } } label: { RowLabel(icon: "speedometer", title: edge.measuring ? "测速中…" : "重新测速") }.disabled(edge.measuring)
                Toggle(isOn: $settings.prefs.preferEdgeTunnel) { RowLabel(icon: "flask", title: "实验：网页流量也走 Cloudflare") }
                    .onChange(of: settings.prefs.preferEdgeTunnel) { _, _ in router.apply() }
            } header: { Text("线路（自动选择最快）").textCase(nil) }
            footer: { Text("Cloudflare 地址由服务器自动提供，无需填写。默认只有直连网关不通时，网页流量才会改走 Cloudflare。") }.sectionStyle(theme.surface)

            Section {
                HStack(spacing: 14) {
                    Image(systemName: settings.gatewayConfigured ? "checkmark.shield" : "exclamationmark.shield").font(.system(size: 18, weight: .light))
                        .foregroundStyle(settings.gatewayConfigured ? theme.accent : .orange).frame(width: 26)
                    Text(settings.gatewayConfigured ? "已与服务器配对" : "尚未配对服务器").foregroundStyle(theme.ink)
                    Spacer()
                    if !result.isEmpty { Text(result).foregroundStyle(result.hasPrefix("已连接") ? .green : theme.inkSoft).font(.system(size: 14)) }
                }.font(.system(size: 17))
                HStack(spacing: 14) {
                    Image(systemName: "link").font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
                    TextField("粘贴 lunox://setup 配置链接", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !link.isEmpty { Button("导入") { importLink() }.fontWeight(.semibold) }
                }
                Button { pairFromClipboard() } label: { RowLabel(icon: "doc.on.clipboard", title: "从剪贴板配对", value: "复制 lunox:// 链接后点这里") }
                Button { Task { await test() } } label: { RowLabel(icon: "waveform.path.ecg", title: testing ? "测试中…" : "测试连接") }.disabled(testing)
                NavigationLink { PolicyGroupsView() } label: { RowLabel(icon: "square.stack.3d.up", title: "策略组", value: "国内直连 · 国外走服务器") }
                NavigationLink { DiagnosticsView() } label: { RowLabel(icon: "stethoscope", title: "连接诊断", value: "逐项检查代理链路") }
            } header: { Text("服务器").textCase(nil) }.sectionStyle(theme.surface)

            Section {
                DisclosureGroup {
                    TextField("服务器地址", text: $settings.prefs.gatewayHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack { Text("端口"); Spacer(); TextField("8443", value: $settings.prefs.gatewayPort, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                    SecureField(settings.gatewayKey.isEmpty ? "访问密钥" : "访问密钥（已保存在钥匙串）", text: $key).onSubmit { commitKey() }
                    TextField("证书指纹 SHA-256", text: $settings.prefs.gatewayPin, axis: .vertical).font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("强制走服务器的域名（逗号分隔）", text: $forced).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onAppear { forced = settings.prefs.forcedProxyDomains.joined(separator: ",") }
                        .onSubmit { settings.prefs.forcedProxyDomains = forced.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; router.apply() }
                } label: { RowLabel(icon: "slider.horizontal.3", title: "高级（手动配置）") }
                if !router.proxied.isEmpty {
                    DisclosureGroup {
                        ForEach(router.proxied.keys.sorted(), id: \.self) { Text($0).font(.footnote).foregroundStyle(theme.inkSoft) }
                        Button("重置检测结果", role: .destructive) { router.reset() }
                    } label: { RowLabel(icon: "bolt.horizontal", title: "正在走服务器的站点", value: "\(router.proxied.count)") }
                }
            }.sectionStyle(theme.surface)
        }
        .onDisappear { commitKey(); router.apply() }
    }

    private var hy2Value: String {
        if !store.hy2.compiledIn { return "此安装包未内置" }
        if !store.hy2.configured { return "等待服务器参数" }
        return store.hy2.running ? "已启动" : (store.hy2.lastError ?? "未启动")
    }
    private func commitKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { settings.gatewayKey = k; key = "" }
        settings.prefs.gatewayPin = Pinning.normalize(settings.prefs.gatewayPin)
    }
    private func pairFromClipboard() {
        let t = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), store.applyPairing(u) {
            result = "已配对"; Haptics.ok()
        } else { result = "剪贴板里没有配对链接"; Haptics.warn() }
    }
    private func importLink() {
        if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), store.applyPairing(u) {
            link = ""; result = "已导入"; Haptics.ok()
        } else { result = "链接无效"; Haptics.warn() }
    }
    private func test() async {
        commitKey(); testing = true; defer { testing = false }
        switch await store.gateway.health() {
        case .success(let s): result = s; router.apply(); Haptics.ok(); await edge.measure(force: true)
        case .failure(let e): result = "失败：\(e.localizedDescription)"; Haptics.warn()
        }
    }
}

private extension RoutingMode {
    var short: String { switch self { case .auto: "智能"; case .direct: "仅直连"; case .proxy: "全部走服务器" } }
}

// MARK: 隐私

struct PrivacySettings: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @State private var confirmClear = false
    var body: some View {
        FlatList(title: "隐私与安全") {
            Section {
                Toggle(isOn: $settings.prefs.blockTrackers) { RowLabel(icon: "hand.raised", title: "拦截广告与跟踪器") }
                Toggle(isOn: $settings.prefs.httpsOnly) { RowLabel(icon: "lock", title: "仅 HTTPS（自动升级）") }
                Toggle(isOn: $settings.prefs.fingerprintProtection) { RowLabel(icon: "touchid", title: "指纹防护（稳定、不伪装）") }
                Toggle(isOn: $settings.prefs.stripTrackingParams) { RowLabel(icon: "link.badge.minus", title: "移除链接里的追踪参数") }
                Toggle(isOn: $settings.prefs.blockPopups) { RowLabel(icon: "rectangle.on.rectangle.slash", title: "拦截弹出窗口") }
                Toggle(isOn: $settings.prefs.blockAppPrompts) { RowLabel(icon: "arrow.up.forward.app", title: "拦截“打开 App”提示与跳转") }
                Toggle(isOn: $settings.prefs.blockForcedLogin) { RowLabel(icon: "person.crop.circle.badge.xmark", title: "移除强制登录弹窗") }
                Toggle(isOn: $settings.prefs.appLock) { RowLabel(icon: "faceid", title: "Face ID / 密码锁定") }
            } footer: { Text("指纹防护不会把浏览器伪装成别的设备，那样反而容易被风控识别。它只对画布、音频这类“读取像素/采样来识别设备”的接口做不可见的微调：同一个网站每次读到的结果都一样，不同网站之间互不相同，所以不会出现“每天换设备”。验证码、反欺诈、登录和支付站点完全不处理。清除网站数据会同时更换这个标识。") }.sectionStyle(theme.surface)
            Section {
                Button(role: .destructive) { confirmClear = true } label: { RowLabel(icon: "trash", title: "清除浏览数据…") }
            }.sectionStyle(theme.surface)
        }
        .confirmationDialog("清除浏览数据", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("历史记录 + Cookie 与网站数据", role: .destructive) { Task { await store.clearBrowsingData(history: true, website: true, offline: false) } }
            Button("全部（含离线缓存）", role: .destructive) { Task { await store.clearBrowsingData(history: true, website: true, offline: true) } }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: 智能与 AI

struct AISettings: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var edge: EdgeSelector
    @Environment(\.theme) private var theme
    @State private var provider = "anthropic"
    @State private var baseUrl = "https://api.anthropic.com"
    @State private var model = "claude-haiku-5-5"
    @State private var apiKey = ""
    @State private var status = ""
    @State private var saving = false

    var body: some View {
        FlatList(title: "智能与 AI") {
            Section {
                Toggle(isOn: $settings.prefs.aiEnabled) { RowLabel(icon: "sparkles", title: "AI 助手与智能搜索") }
                Toggle(isOn: $settings.prefs.syncBookmarks) { RowLabel(icon: "arrow.triangle.2.circlepath", title: "同步书签（端到端加密）") }
                if settings.prefs.syncBookmarks {
                    Button { Task { await store.sync() } } label: { RowLabel(icon: "arrow.clockwise", title: "立即同步", value: store.syncStatus) }
                }
            }.sectionStyle(theme.surface)

            Section {
                Picker(selection: $provider) { Text("Anthropic").tag("anthropic"); Text("OpenAI 兼容").tag("openai") } label: { RowLabel(icon: "cpu", title: "接口类型") }
                    .onChange(of: provider) { _, p in baseUrl = p == "anthropic" ? "https://api.anthropic.com" : "https://api.openai.com" }
                HStack(spacing: 14) { Image(systemName: "network").font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
                    TextField("Base URL", text: $baseUrl).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL) }
                HStack(spacing: 14) { Image(systemName: "square.stack.3d.up").font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
                    TextField("模型", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled() }
                HStack(spacing: 14) { Image(systemName: "key").font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
                    SecureField(edge.server?.llm.configured == true ? "API 密钥（已保存在服务器，留空不改）" : "API 密钥", text: $apiKey) }
                Button { Task { await save() } } label: { RowLabel(icon: "icloud.and.arrow.up", title: saving ? "保存中…" : "保存到服务器", value: status) }.disabled(saving || !settings.gatewayConfigured)
            } header: { Text("模型 API").textCase(nil) }
            footer: { Text("这是唯一需要你填写的密钥：它只写入你的服务器并保存在那里，不会保存在手机上，也不会再回传。其余配置（线路、Cloudflare、搜索）由服务器自动完成。") }
            .sectionStyle(theme.surface)
        }
        .task {
            await edge.refreshServerConfig()
            if let l = edge.server?.llm { provider = l.provider; baseUrl = l.baseUrl; model = l.model }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            try await store.gateway.saveLLM(provider: provider, baseUrl: baseUrl, model: model, apiKey: apiKey)
            apiKey = ""; status = "已保存"; Haptics.ok(); await edge.refreshServerConfig()
        } catch { status = "失败"; Haptics.warn() }
    }
}

// MARK: 离线

struct OfflineSettings: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var offline: OfflineCache
    @Environment(\.theme) private var theme
    var body: some View {
        FlatList(title: "离线与缓存") {
            Section {
                Toggle(isOn: $settings.prefs.offlineCache) { RowLabel(icon: "arrow.down.circle", title: "自动缓存已访问页面") }
                Stepper(value: $settings.prefs.offlineLimitMB, in: 50...2000, step: 50) { RowLabel(icon: "internaldrive", title: "缓存上限", value: "\(settings.prefs.offlineLimitMB) MB") }
                RowLabel(icon: "externaldrive", title: "已用空间", value: ByteCountFormatter.string(fromByteCount: Int64(offline.totalBytes), countStyle: .file))
            } footer: { Text("访问过的网页会自动保存为离线副本；界面本身是原生的，断网也能使用。") }.sectionStyle(theme.surface)
            Section {
                Button(role: .destructive) { offline.clear() } label: { RowLabel(icon: "trash", title: "清空离线缓存") }
            }.sectionStyle(theme.surface)
        }
    }
}


// MARK: 策略组

/// Which sites go direct and which go through the server. Domestic / payment sites are never sent abroad; blocked sites always use the server
/// (one fixed exit address), so each site is always seen from the same place and trips fewer risk-control systems.
struct PolicyGroupsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var router: Router
    @Environment(\.theme) private var theme
    @State private var draft: [String: String] = [:]

    var body: some View {
        FlatList(title: "策略组") {
            ForEach(Router.groups) { g in
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: g.icon).font(.system(size: 18, weight: .light)).foregroundStyle(theme.inkSoft).frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g.name).font(.system(size: 17))
                            Text(g.note).font(.system(size: 12)).foregroundStyle(theme.inkSoft)
                        }
                        Spacer()
                    }
                    Picker("方式", selection: Binding(
                        get: { router.mode(of: g) },
                        set: { settings.prefs.groupModes[g.id] = $0.rawValue; router.apply() })) {
                        ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    DisclosureGroup {
                        ForEach(settings.prefs.groupDomains[g.id] ?? [], id: \.self) { d in
                            HStack { Text(d).font(.system(size: 15)); Spacer(); Text("我添加的").font(.system(size: 11)).foregroundStyle(theme.inkSoft) }
                        }
                        .onDelete { idx in
                            var l = settings.prefs.groupDomains[g.id] ?? []; l.remove(atOffsets: idx)
                            settings.prefs.groupDomains[g.id] = l; router.apply()
                        }
                        HStack {
                            TextField("添加域名，如 example.com", text: Binding(get: { draft[g.id] ?? "" }, set: { draft[g.id] = $0 }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            if !(draft[g.id] ?? "").isEmpty { Button("添加") { add(g) }.fontWeight(.semibold) }
                        }
                        Text(g.domains.prefix(40).joined(separator: "  ")).font(.system(size: 12)).foregroundStyle(theme.inkSoft)
                    } label: { Text("包含 \(router.domains(of: g).count) 个网站").font(.system(size: 15)).foregroundStyle(theme.inkSoft) }
                }.sectionStyle(theme.surface)
            }
            Section {
                Button("恢复默认", role: .destructive) { settings.prefs.groupModes = [:]; settings.prefs.groupDomains = [:]; router.reset() }
            } footer: { Text("其他不在任何组里的网站：先直连测试，不通再走服务器，并且之后一天内保持同一条路线（来回换出口地址更容易触发风控）。个别网站如果拦截了代理出口，会自动改直连。") }.sectionStyle(theme.surface)
        }
    }

    private func add(_ g: Router.PolicyGroup) {
        var t = (draft[g.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        t = t.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        t = String(t.split(separator: "/").first ?? "")
        guard t.contains("."), t.range(of: #"^[a-z0-9.\-]{3,253}$"#, options: .regularExpression) != nil else { return }
        for other in Router.groups { settings.prefs.groupDomains[other.id]?.removeAll { $0 == t } }          // one group per site
        settings.prefs.groupDomains[g.id, default: []].append(t)
        draft[g.id] = ""; Haptics.ok(); router.apply()
    }
}
