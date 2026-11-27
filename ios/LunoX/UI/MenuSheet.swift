import SwiftUI
import WebKit

enum MenuRoute: Hashable { case bookmarks, history, downloads, offline, extensions, themes, settings, ai, reader }

struct MenuSheet: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var onFind: () -> Void
    var initialRoute: MenuRoute? = nil
    @State private var path: [MenuRoute] = []

    private var tab: Tab? { store.current }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    tile("plus.square", "新标签页") { store.newTab(); dismiss() }
                    tile("eyeglasses", "隐私标签页") { store.newTab(isPrivate: true); dismiss() }
                    tile("arrow.uturn.backward.circle", "恢复关闭", on: !store.recentlyClosed.isEmpty) { store.reopenClosed(); dismiss() }

                    link("star", "书签", .bookmarks)
                    link("clock", "历史记录", .history)
                    link("arrow.down.circle", "下载", .downloads)

                    link("tray.and.arrow.down", "离线页面", .offline)
                    tile("magnifyingglass", "页内查找", on: tab?.isBlank == false) { dismiss(); onFind() }
                    tile("desktopcomputer", tab?.isDesktop == true ? "移动版网站" : "桌面版网站", on: tab?.isBlank == false) { tab?.toggleDesktop(); dismiss() }

                    link("text.page", "阅读模式", .reader, on: tab?.isBlank == false)
                    link("sparkles", "AI 助手", .ai, on: settings.prefs.aiEnabled)
                    tile(store.isBookmarked(tab?.url) ? "star.fill" : "star.circle", store.isBookmarked(tab?.url) ? "取消收藏" : "添加书签", on: tab?.isBlank == false) { store.toggleBookmark(tab); dismiss() }

                    if let u = tab?.url, !(tab?.isBlank ?? true) {
                        ShareLink(item: u) { tileBody("square.and.arrow.up", "分享", true) }.buttonStyle(.plain)
                    } else { tileBody("square.and.arrow.up", "分享", false) }
                    tile("printer", "打印", on: tab?.isBlank == false) { printPage(); dismiss() }
                    tile("safari", "在 Safari 打开", on: tab?.url != nil) { if let u = tab?.url { UIApplication.shared.open(u) }; dismiss() }

                    link("puzzlepiece.extension", "扩展与脚本", .extensions)
                    link("paintpalette", "主题", .themes)
                    link("gearshape", "设置", .settings)
                }
                .padding(16)

                if let t = tab, !t.isBlank {
                    HStack(spacing: 14) {
                        Image(systemName: "textformat.size").foregroundStyle(theme.inkSoft)
                        Slider(value: Binding(get: { Double(t.zoom) }, set: { t.setZoom(Int($0)) }), in: 70...250, step: 5)
                        Text("\(t.zoom)%").font(.system(size: 13, design: .rounded).monospacedDigit()).foregroundStyle(theme.inkSoft).frame(width: 44)
                    }.padding(.horizontal, 22).padding(.bottom, 20)
                }
            }
            .navigationTitle("LunoX").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MenuRoute.self) { r in
                switch r {
                case .bookmarks: BookmarksView()
                case .history: HistoryView()
                case .downloads: DownloadsView()
                case .offline: OfflineView(dismissMenu: { dismiss() })
                case .extensions: ExtensionsView()
                case .themes: ThemesView()
                case .settings: SettingsView()
                case .ai: if let t = tab { AIPanel(tab: t, initialQuestion: "", initialMode: .summarize) }
                case .reader: if let t = tab { ReaderView(tab: t) }
                }
            }
        }
        .presentationBackground(.regularMaterial)
        .onAppear { if let r = initialRoute, path.isEmpty { path = [r] } }
    }

    private func printPage() {
        guard let wv = tab?.webView else { return }
        let info = UIPrintInfo(dictionary: nil); info.jobName = tab?.displayTitle ?? "LunoX"; info.outputType = .general
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info; pc.printFormatter = wv.viewPrintFormatter()
        pc.present(animated: true)
    }

    private func tile(_ icon: String, _ title: String, on: Bool = true, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: { tileBody(icon, title, on) }.buttonStyle(.plain).disabled(!on)
    }
    private func link(_ icon: String, _ title: String, _ r: MenuRoute, on: Bool = true) -> some View {
        Button { Haptics.tap(); path.append(r) } label: { tileBody(icon, title, on) }.buttonStyle(.plain).disabled(!on)
    }
    private func tileBody(_ icon: String, _ title: String, _ on: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(on ? theme.accent : theme.inkSoft.opacity(0.4))
            Text(title).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(on ? theme.ink : theme.inkSoft.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 84)
        .lunoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: on)
    }
}

// MARK: - Library

struct BookmarksView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var q = ""
    var body: some View {
        List {
            ForEach(store.bookmarks.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }) { b in
                Button { store.open(b.url) } label: { VStack(alignment: .leading, spacing: 3) {
                    Text(b.title).lineLimit(1); Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                    .foregroundStyle(.primary)
            }
            .onDelete { store.bookmarks.remove(atOffsets: $0); store.saveBookmarks() }
        }
        .overlay { if store.bookmarks.isEmpty { ContentUnavailableView("还没有书签", systemImage: "star", description: Text("在菜单里点「添加书签」")) } }
        .searchable(text: $q).navigationTitle("书签")
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var q = ""
    private var items: [HistoryItem] { store.history.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) } }
    var body: some View {
        List {
            ForEach(items.prefix(300)) { h in
                Button { store.open(h.url) } label: { VStack(alignment: .leading, spacing: 3) {
                    Text(h.title).lineLimit(1)
                    Text("\(h.date.formatted(date: .abbreviated, time: .shortened)) · \(URL(string: h.url)?.displayHost ?? "")").font(.caption).foregroundStyle(.secondary) } }
                    .foregroundStyle(.primary)
                    .swipeActions { Button(role: .destructive) { store.removeHistory(h) } label: { Label("删除", systemImage: "trash") } }
            }
        }
        .overlay { if store.history.isEmpty { ContentUnavailableView("没有历史记录", systemImage: "clock") } }
        .searchable(text: $q).navigationTitle("历史记录")
        .toolbar { Button("清除", role: .destructive) { store.clearHistory() } }
    }
}

struct DownloadsView: View {
    @EnvironmentObject var dl: DownloadManager
    var body: some View {
        List {
            ForEach(dl.items) { i in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(i.name).lineLimit(1)
                        Spacer()
                        if i.failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                        else if i.done, let u = i.fileURL { ShareLink(item: u) { Image(systemName: "square.and.arrow.up") } }
                    }
                    if !i.done && !i.failed { ProgressView(value: i.progress) }
                }
                .swipeActions { Button(role: .destructive) { dl.remove(i) } label: { Label("删除", systemImage: "trash") } }
            }
        }
        .overlay { if dl.items.isEmpty { ContentUnavailableView("没有下载", systemImage: "arrow.down.circle", description: Text("文件保存在「文件」App › LunoX › Downloads")) } }
        .navigationTitle("下载")
    }
}

struct OfflineView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var offline: OfflineCache
    var dismissMenu: () -> Void
    var body: some View {
        List {
            Section(footer: Text("共 \(ByteCountFormatter.string(fromByteCount: Int64(offline.totalBytes), countStyle: .file))。访问过的网页会自动保存，断网时可直接打开。")) {
                ForEach(offline.pages) { p in
                    Button { store.open(p.url); dismissMenu() } label: { VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).lineLimit(1)
                        Text("\(p.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file))").font(.caption).foregroundStyle(.secondary) } }
                        .foregroundStyle(.primary)
                        .swipeActions { Button(role: .destructive) { offline.remove(p) } label: { Label("删除", systemImage: "trash") } }
                }
            }
        }
        .overlay { if offline.pages.isEmpty { ContentUnavailableView("暂无离线页面", systemImage: "tray") } }
        .navigationTitle("离线页面")
    }
}

// MARK: - Site info / permissions

struct SiteInfoView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let host = tab.url?.host
        NavigationStack {
            Form {
                Section {
                    Label(tab.isBlank ? "新标签页" : (tab.secure ? "连接安全（HTTPS）" : "连接不安全"), systemImage: tab.secure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tab.secure || tab.isBlank ? Color.primary : Color.orange)
                    if let h = host { LabeledContent("站点", value: h) }
                    if let r = host.map({ URLResolver.registrableDomain($0) }), store.router.proxied[r] != nil {
                        Label("此站点通过服务器访问", systemImage: "bolt.horizontal.circle").foregroundStyle(.tint)
                    }
                }
                if host != nil {
                    Section("此站点的设置") {
                        Toggle("桌面版网站", isOn: Binding(get: { settings.site(host).desktop }, set: { v in settings.updateSite(host) { $0.desktop = v }; tab.webView?.reload() }))
                        Toggle("允许 JavaScript", isOn: Binding(get: { settings.site(host).javascript }, set: { v in settings.updateSite(host) { $0.javascript = v }; tab.webView?.reload() }))
                        Toggle("始终通过服务器访问", isOn: Binding(get: { settings.site(host).forceProxy }, set: { v in settings.updateSite(host) { $0.forceProxy = v }; store.router.apply(); tab.webView?.reload() }))
                        Picker("相机", selection: Binding(get: { settings.site(host).camera.map { $0 ? 1 : 2 } ?? 0 }, set: { v in settings.updateSite(host) { $0.camera = v == 0 ? nil : v == 1 } })) { Text("询问").tag(0); Text("允许").tag(1); Text("拒绝").tag(2) }
                        Picker("麦克风", selection: Binding(get: { settings.site(host).microphone.map { $0 ? 1 : 2 } ?? 0 }, set: { v in settings.updateSite(host) { $0.microphone = v == 0 ? nil : v == 1 } })) { Text("询问").tag(0); Text("允许").tag(1); Text("拒绝").tag(2) }
                    }
                    Section {
                        Button("清除此站点的数据", role: .destructive) {
                            guard let h = host, let store0 = tab.webView?.configuration.websiteDataStore else { return }
                            let dom = URLResolver.registrableDomain(h)
                            store0.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
                                store0.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs.filter { $0.displayName.hasSuffix(dom) }) { Haptics.ok() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("站点信息").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

// MARK: - Themes

struct ThemesView: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var current
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Theme.all) { t in
                    Button { Haptics.soft(); withAnimation(.easeInOut(duration: 0.35)) { settings.prefs.themeID = t.id } } label: {
                        ZStack(alignment: .bottomLeading) {
                            t.background
                            Circle().fill(t.glow.opacity(0.5)).frame(width: 90).blur(radius: 24).offset(x: 40, y: -30)
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(t.accent).frame(width: 34, height: 6)
                                Text(t.name).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(t.ink)
                            }.padding(16)
                        }
                        .frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(settings.prefs.themeID == t.id ? t.accent : .gray.opacity(0.2), lineWidth: settings.prefs.themeID == t.id ? 2.5 : 0.5))
                    }.buttonStyle(.plain)
                }
            }.padding(16)
        }.navigationTitle("主题")
    }
}
