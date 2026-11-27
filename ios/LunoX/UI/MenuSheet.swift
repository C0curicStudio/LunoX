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
    @State private var shown = false

    private var tab: Tab? { store.current }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private enum Kind { case action(() -> Void), route(MenuRoute), share(URL) }
    private struct Item: Identifiable { var id: String { title }; var icon: String; var title: String; var on = true; var kind: Kind }

    private var items: [Item] {
        let page = tab?.isBlank == false
        var l: [Item] = [
            Item(icon: "plus.square", title: "新标签页", kind: .action { store.newTab(); dismiss() }),
            Item(icon: "eyeglasses", title: "隐私标签页", kind: .action { store.newTab(isPrivate: true); dismiss() }),
            Item(icon: "arrow.uturn.backward.circle", title: "恢复关闭", on: !store.recentlyClosed.isEmpty, kind: .action { store.reopenClosed(); dismiss() }),
            Item(icon: "star", title: "书签", kind: .route(.bookmarks)),
            Item(icon: "clock", title: "历史记录", kind: .route(.history)),
            Item(icon: "arrow.down.circle", title: "下载", kind: .route(.downloads)),
            Item(icon: "tray.and.arrow.down", title: "离线页面", kind: .route(.offline)),
            Item(icon: "magnifyingglass", title: "页内查找", on: page, kind: .action { dismiss(); onFind() }),
            Item(icon: "desktopcomputer", title: tab?.isDesktop == true ? "移动版网站" : "桌面版网站", on: page, kind: .action { tab?.toggleDesktop(); dismiss() }),
            Item(icon: "text.page", title: "阅读模式", on: page, kind: .route(.reader)),
            Item(icon: "sparkles", title: "AI 助手", on: settings.prefs.aiEnabled, kind: .route(.ai)),
            Item(icon: store.isBookmarked(tab?.url) ? "star.fill" : "star.circle", title: store.isBookmarked(tab?.url) ? "取消收藏" : "添加书签", on: page, kind: .action { store.toggleBookmark(tab); dismiss() }),
        ]
        if let u = tab?.url, page { l.append(Item(icon: "square.and.arrow.up", title: "分享", kind: .share(u))) }
        else { l.append(Item(icon: "square.and.arrow.up", title: "分享", on: false, kind: .action {})) }
        l += [
            Item(icon: "printer", title: "打印", on: page, kind: .action { printPage(); dismiss() }),
            Item(icon: "safari", title: "在 Safari 打开", on: tab?.url != nil, kind: .action { if let u = tab?.url { UIApplication.shared.open(u) }; dismiss() }),
            Item(icon: "puzzlepiece.extension", title: "扩展与脚本", kind: .route(.extensions)),
            Item(icon: "paintpalette", title: "主题与外观", kind: .route(.themes)),
            Item(icon: "gearshape", title: "设置", kind: .route(.settings)),
        ]
        return l
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        cell(it).staggered(i, shown, rise: 14)
                    }
                }
                .padding(16)

                if let t = tab, !t.isBlank {
                    HStack(spacing: 14) {
                        Image(systemName: "textformat.size").foregroundStyle(theme.inkSoft)
                        Slider(value: Binding(get: { Double(t.zoom) }, set: { t.setZoom(Int($0)) }), in: 70...250, step: 5)
                        Text("\(t.zoom)%").font(.system(size: 13, design: .rounded).monospacedDigit()).foregroundStyle(theme.inkSoft).frame(width: 44)
                    }.padding(.horizontal, 22).padding(.bottom, 20).staggered(items.count, shown)
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
        .onAppear {
            if let r = initialRoute, path.isEmpty { path = [r] }
            withAnimation { shown = true }
        }
    }

    @ViewBuilder private func cell(_ it: Item) -> some View {
        switch it.kind {
        case .action(let f):
            Button { Haptics.tap(); f() } label: { tileBody(it) }.buttonStyle(PressableStyle()).disabled(!it.on)
        case .route(let r):
            Button { Haptics.tap(); path.append(r) } label: { tileBody(it) }.buttonStyle(PressableStyle()).disabled(!it.on)
        case .share(let u):
            ShareLink(item: u) { tileBody(it) }.buttonStyle(PressableStyle())
        }
    }

    private func printPage() {
        guard let wv = tab?.webView else { return }
        let info = UIPrintInfo(dictionary: nil); info.jobName = tab?.displayTitle ?? "LunoX"; info.outputType = .general
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info; pc.printFormatter = wv.viewPrintFormatter()
        pc.present(animated: true)
    }

    private func tileBody(_ it: Item) -> some View {
        VStack(spacing: 10) {
            Image(systemName: it.icon).font(.system(size: 22, weight: .regular)).foregroundStyle(it.on ? theme.accent : theme.inkSoft.opacity(0.4)).frame(height: 26)
            Text(it.title).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(it.on ? theme.ink : theme.inkSoft.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).frame(height: 88)
        .background(theme.surface.opacity(theme.scheme == .dark ? 0.7 : 0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.inkSoft.opacity(0.1), lineWidth: 0.5))
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
            VStack(spacing: 18) {
                SegmentPill(selection: Binding(get: { Appearance.allCases.firstIndex(of: settings.prefs.appearance) ?? 0 },
                                               set: { settings.prefs.appearance = Appearance.allCases[$0] }),
                            items: [("circle.lefthalf.filled", "跟随系统"), ("sun.max", "浅色"), ("moon", "深色")])
                    .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(ThemeFamily.all) { f in card(f) }
                }
            }.padding(16)
        }
        .navigationTitle("主题与外观")
    }

    private func card(_ f: ThemeFamily) -> some View {
        let on = settings.prefs.themeID == f.id
        let t = f.resolve(current.scheme)
        return Button { Haptics.soft(); withAnimation(.easeInOut(duration: 0.35)) { settings.prefs.themeID = f.id } } label: {
            ZStack(alignment: .bottomLeading) {
                // left half = light, right half = dark: both variants at a glance
                HStack(spacing: 0) { f.light.background; f.dark.background }
                FlatArt(theme: t, seed: abs(f.id.hashValue) % 3, animated: false).opacity(0.95)
                HStack(spacing: 6) {
                    Circle().fill(f.light.accent).frame(width: 14, height: 14)
                    Circle().fill(f.dark.accent).frame(width: 14, height: 14)
                    Spacer()
                    if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.accent).font(.system(size: 20)).transition(.scale.combined(with: .opacity)) }
                }.padding(.horizontal, 14).padding(.top, 14).frame(maxHeight: .infinity, alignment: .top)
                Text(f.name).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(t.ink).padding(14)
            }
            .frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(on ? t.accent : .gray.opacity(0.2), lineWidth: on ? 2.5 : 0.5))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 5)
        }.buttonStyle(PressableStyle(scale: 0.96))
    }
}
