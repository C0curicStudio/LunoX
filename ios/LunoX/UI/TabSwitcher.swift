import SwiftUI

struct TabSwitcher: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    var ns: Namespace.ID
    var pick: (Tab) -> Void
    @State private var mode = 0                   // 0 normal, 1 private
    @State private var shown = false
    @State private var groupTarget: Tab?
    @State private var groupName = ""

    private var privateMode: Bool { mode == 1 }
    private var list: [Tab] { privateMode ? store.privateTabs : store.normalTabs }
    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).overlay(theme.bgTop.opacity(0.66)).ignoresSafeArea()
            FlatArt(theme: theme, seed: 1).frame(height: 260).opacity(0.5).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    SegmentPill(selection: $mode, items: [("square.on.square", "标签页 \(store.normalTabs.count)"), ("eyeglasses", "隐私 \(store.privateTabs.count)")])
                        .padding(.horizontal, 28)
                }
                .padding(.top, 14).staggered(0, shown, rise: -10)

                ScrollView {
                    if list.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: privateMode ? "eyeglasses" : "square.on.square").font(.system(size: 40, weight: .light)).foregroundStyle(theme.inkSoft)
                            Text(privateMode ? "没有隐私标签页" : "没有标签页").foregroundStyle(theme.inkSoft)
                            Button("新建\(privateMode ? "隐私" : "")标签页") { create() }.buttonStyle(.borderedProminent).clipShape(Capsule())
                        }.padding(.top, 110).transition(.opacity)
                    }
                    ForEach(sections, id: \.0) { name, tabs in
                        if !name.isEmpty {
                            Label(name, systemImage: "folder.fill").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.top, 16)
                        }
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, t in
                                TabCard(tab: t, ns: ns, selected: t.id == store.selectedID, index: i, shown: shown,
                                        onPick: { pick(t) },
                                        onClose: { Haptics.tap(); withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { store.close(t) } },
                                        onGroup: { groupTarget = t })
                                .transition(.scale(scale: 0.7).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 20).padding(.top, 12)
                    }
                    Spacer(minLength: 130)
                }
                .scrollIndicators(.hidden)
            }

            VStack {
                Spacer()
                GlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { Haptics.warn(); withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { store.closeAll(private: privateMode) } } label: {
                            Text("全部关闭").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(theme.inkSoft).padding(.horizontal, 18).frame(height: 50)
                        }.buttonStyle(PressableStyle()).lunoGlass(Capsule())
                        Button { create() } label: {
                            Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).frame(width: 58, height: 58).background(theme.accent, in: Circle())
                                .shadow(color: theme.accent.opacity(0.45), radius: 12, y: 5)
                        }.buttonStyle(PressableStyle(scale: 0.88))
                        Button { Haptics.tap(); if let t = store.current { pick(t) } } label: {
                            Text("完成").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(theme.accent).padding(.horizontal, 24).frame(height: 50)
                        }.buttonStyle(PressableStyle()).lunoGlass(Capsule())
                    }
                }
                .padding(.bottom, 22).staggered(2, shown, rise: 30)
            }
        }
        .onAppear {
            mode = (store.current?.isPrivate ?? false) ? 1 : 0
            withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) { shown = true }
        }
        .alert("分组名称", isPresented: Binding(get: { groupTarget != nil }, set: { if !$0 { groupTarget = nil } })) {
            TextField("例如：作业", text: $groupName)
            Button("确定") { groupTarget?.group = groupName.isEmpty ? nil : groupName; store.persistSoon(); groupName = "" }
            Button("取消", role: .cancel) {}
        }
    }

    private func create() {
        Haptics.soft()
        var created: Tab?
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { created = store.newTab(isPrivate: privateMode) }
        guard let t = created else { return }
        Task { try? await Task.sleep(nanoseconds: 420_000_000); pick(t) }   // let the new card pop in, then zoom into it
    }

    private var sections: [(String, [Tab])] {
        let names = Array(Set(list.compactMap(\.group))).sorted()
        var out: [(String, [Tab])] = []
        let ungrouped = list.filter { $0.group == nil }
        if !ungrouped.isEmpty { out.append(("", ungrouped)) }
        for n in names { out.append((n, list.filter { $0.group == n })) }
        return out
    }
}

struct TabCard: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    var ns: Namespace.ID
    var selected: Bool
    var index: Int
    var shown: Bool
    var onPick: () -> Void
    var onClose: () -> Void
    var onGroup: () -> Void

    private var host: String? { tab.url?.host }
    private var icon: UIImage? { tab.favicon ?? host.flatMap { store.icon(for: $0) } }

    var body: some View {
        VStack(spacing: 9) {
            Button(action: onPick) {
                Color.clear
                    .aspectRatio(0.66, contentMode: .fit)
                    .overlay(alignment: .top) { preview }
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(selected ? theme.accent : theme.inkSoft.opacity(0.18), lineWidth: selected ? 2.5 : 0.6))
                    .matchedGeometryEffect(id: tab.id, in: ns)
                    .shadow(color: .black.opacity(theme.scheme == .dark ? 0.45 : 0.14), radius: 14, y: 8)
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.ink).frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }.buttonStyle(PressableStyle(scale: 0.85)).padding(10)
            }

            HStack(spacing: 7) {
                FaviconTile(image: icon, fallback: tab.displayTitle, size: 18, radius: 5)
                Text(tab.isBlank ? "新标签页" : tab.displayTitle).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
        }
        // the selected card is positioned by the hero transition; the others pop in
        .modifier(PopIn(active: !selected, index: index, shown: shown))
        .contextMenu {
            Button(action: onGroup) { Label("加入分组…", systemImage: "folder.badge.plus") }
            if tab.group != nil { Button { tab.group = nil } label: { Label("移出分组", systemImage: "folder.badge.minus") } }
            if let u = tab.url { Button { UIPasteboard.general.string = u.absoluteString } label: { Label("拷贝链接", systemImage: "doc.on.doc") } }
            Button(role: .destructive, action: onClose) { Label("关闭", systemImage: "xmark") }
        }
    }

    @ViewBuilder private var preview: some View {
        if let img = tab.thumbnail {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                theme.background
                FlatArt(theme: theme, seed: abs(tab.id.hashValue) % 3, animated: false).opacity(0.8)
                FaviconTile(image: icon, fallback: tab.displayTitle, size: 54, radius: 16).shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
        }
    }
}

private struct PopIn: ViewModifier {
    var active: Bool; var index: Int; var shown: Bool
    func body(content: Content) -> some View {
        if active { content.staggered(index + 1, shown, rise: 24) } else { content }
    }
}
