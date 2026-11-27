import SwiftUI

struct TabSwitcher: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @State private var privateMode = false
    @State private var groupTarget: Tab?
    @State private var groupName = ""

    private var shown: [Tab] { privateMode ? store.privateTabs : store.normalTabs }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).overlay(theme.bgTop.opacity(0.6)).ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("", selection: $privateMode.animation(.snappy)) {
                    Text("标签页 \(store.normalTabs.count)").tag(false)
                    Label("隐私 \(store.privateTabs.count)", systemImage: "eyeglasses").tag(true)
                }
                .pickerStyle(.segmented).padding(.horizontal, 24).padding(.top, 16)

                ScrollView {
                    if shown.isEmpty {
                        Text(privateMode ? "没有隐私标签页" : "没有标签页").foregroundStyle(theme.inkSoft).padding(.top, 120)
                    }
                    ForEach(sections, id: \.0) { name, tabs in
                        if !name.isEmpty { Text(name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 14) }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                            ForEach(tabs) { t in card(t) }
                        }.padding(.horizontal, 20).padding(.top, 10)
                    }
                    Spacer(minLength: 120)
                }
            }
            VStack {
                Spacer()
                GlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { Haptics.warn(); store.closeAll(private: privateMode) } label: { Text("全部关闭").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.inkSoft).padding(.horizontal, 18).frame(height: 48) }
                            .lunoGlass(Capsule())
                        GlassIconButton(system: "plus", size: 52) { store.newTab(isPrivate: privateMode); store.showSwitcher = false }
                        Button { Haptics.tap(); store.showSwitcher = false } label: { Text("完成").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).padding(.horizontal, 22).frame(height: 48) }
                            .lunoGlass(Capsule())
                    }
                }.padding(.bottom, 20)
            }
        }
        .onAppear { privateMode = store.current?.isPrivate ?? false }
        .alert("分组名称", isPresented: Binding(get: { groupTarget != nil }, set: { if !$0 { groupTarget = nil } })) {
            TextField("例如：作业", text: $groupName)
            Button("确定") { groupTarget?.group = groupName.isEmpty ? nil : groupName; store.persistSoon(); groupName = "" }
            Button("取消", role: .cancel) {}
        }
    }

    private var sections: [(String, [Tab])] {
        let names = Array(Set(shown.compactMap(\.group))).sorted()
        var out: [(String, [Tab])] = []
        let ungrouped = shown.filter { $0.group == nil }
        if !ungrouped.isEmpty { out.append(("", ungrouped)) }
        for n in names { out.append((n, shown.filter { $0.group == n })) }
        return out
    }

    private func card(_ t: Tab) -> some View {
        Button {
            Haptics.soft(); store.selectTab(t); store.showSwitcher = false
        } label: {
            ZStack(alignment: .bottom) {
                Group {
                    if let img = t.thumbnail { Image(uiImage: img).resizable().scaledToFill() }
                    else { LinearGradient(colors: [theme.glow.opacity(0.4), theme.accent.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: t.isBlank ? "plus" : "globe").font(.system(size: 28, weight: .light)).foregroundStyle(theme.inkSoft)) }
                }
                .frame(height: 190).frame(maxWidth: .infinity).clipped()
                HStack(spacing: 8) {
                    Text(t.displayTitle).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { Haptics.tap(); withAnimation(.snappy) { store.close(t) } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.inkSoft).frame(width: 22, height: 22).background(.thinMaterial, in: Circle())
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).frame(height: 38).frame(maxWidth: .infinity).background(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(t.id == store.selectedID ? theme.accent : theme.inkSoft.opacity(0.15), lineWidth: t.id == store.selectedID ? 2 : 0.5))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { groupTarget = t } label: { Label("加入分组…", systemImage: "folder.badge.plus") }
            if t.group != nil { Button { t.group = nil } label: { Label("移出分组", systemImage: "folder.badge.minus") } }
            if let u = t.url { Button { UIPasteboard.general.string = u.absoluteString } label: { Label("拷贝链接", systemImage: "doc.on.doc") } }
            Button(role: .destructive) { store.close(t) } label: { Label("关闭", systemImage: "xmark") }
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}
