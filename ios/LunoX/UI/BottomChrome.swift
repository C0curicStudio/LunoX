import SwiftUI

/// Floating glass chrome: address capsule + action capsule. Collapses to a pill while scrolling down.
struct BottomChrome: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    var ns: Namespace.ID
    var searching: Bool
    var onSearch: () -> Void
    var onSite: () -> Void
    var onMenu: () -> Void
    var onTabs: () -> Void
    var onReader: () -> Void
    var onTranslate: () -> Void
    @State private var reloadTick = 0

    var body: some View {
        let collapsed = store.barsCollapsed && !tab.isBlank
        GlassGroup(spacing: 14) {
            VStack(spacing: 10) {
                omnibox(collapsed: collapsed)
                if !collapsed { actions.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .padding(.horizontal, collapsed ? 80 : 16)
        .padding(.bottom, 6)
        .opacity(searching ? 0 : 1).scaleEffect(searching ? 0.96 : 1, anchor: .bottom)
        .animation(Motion.bouncy, value: collapsed)
        .animation(Motion.snappy, value: tab.canTranslate)
        .animation(Motion.snappy, value: tab.readable)
        .animation(Motion.snappy, value: tab.translated)
    }

    private func omnibox(collapsed: Bool) -> some View {
        ZStack {
            // the whole capsule is a single tap target; the small buttons sit on top of it
            Button { Haptics.soft(); if collapsed { store.setBars(collapsed: false) } else { onSearch() } } label: {
                Color.clear.contentShape(Capsule())
            }.buttonStyle(.plain)

            HStack(spacing: 10) {
                if !collapsed {
                    Button { Haptics.tap(); onSite() } label: { siteIcon.frame(width: 30, height: 36).contentShape(Rectangle()) }.buttonStyle(PressableStyle(scale: 0.85))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Text(tab.isBlank ? "搜索或输入网址" : (tab.url?.displayHost ?? ""))
                    .font(.system(size: collapsed ? 13 : 16, weight: .medium, design: .rounded)).contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: tab.url)
                    .foregroundStyle(tab.isBlank ? theme.inkSoft : theme.ink)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                    .allowsHitTesting(false)
                if !collapsed && (tab.canTranslate || tab.translated) {
                    Button { Haptics.tap(); onTranslate() } label: {
                        Group {
                            if tab.translating { ProgressView().controlSize(.small) }
                            else { Image(systemName: tab.translated ? "character.bubble.fill" : "character.bubble").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent) }
                        }.frame(width: 34, height: 40).contentShape(Rectangle())
                    }.buttonStyle(PressableStyle(scale: 0.85)).transition(.scale.combined(with: .opacity))
                }
                if !collapsed && tab.readable && !tab.isLoading {
                    Button { Haptics.tap(); onReader() } label: {
                        Image(systemName: "text.page").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).frame(width: 34, height: 40).contentShape(Rectangle())
                    }.buttonStyle(PressableStyle(scale: 0.85)).transition(.scale.combined(with: .opacity))
                }
                if !collapsed && !tab.isBlank {
                    Button { Haptics.tap(); reloadTick += 1; tab.isLoading ? tab.stop() : tab.reload() } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.inkSoft).frame(width: 34, height: 40).contentShape(Rectangle())
                            .contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: reloadTick)
                    }.buttonStyle(PressableStyle(scale: 0.85)).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, collapsed ? 14 : 12)
        }
        .frame(height: collapsed ? 34 : 52)
        .overlay(alignment: .bottom) { progressLine }
        .clipShape(Capsule())
        .lunoGlass(Capsule())
        .matchedGeometryEffect(id: "omni", in: ns, isSource: !searching)
    }

    @ViewBuilder private var progressLine: some View {
        if tab.isLoading && tab.progress < 1 {
            GeometryReader { g in
                Capsule().fill(theme.accent).frame(width: max(8, g.size.width * tab.progress), height: 2.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .animation(.easeOut(duration: 0.25), value: tab.progress)
            }.allowsHitTesting(false)
        }
    }

    @ViewBuilder private var siteIcon: some View {
        if tab.isBlank {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
        } else if let f = tab.favicon {
            Image(uiImage: f).resizable().scaledToFit().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: tab.secure ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tab.secure ? theme.inkSoft : .orange)
        }
    }

    private var actions: some View {
        HStack {
            bar("chevron.left", on: tab.canGoBack) { tab.goBack() }
            bar("chevron.right", on: tab.canGoForward) { tab.goForward() }
            bar("plus", on: true) { store.newTab(isPrivate: tab.isPrivate) }
            ZStack {
                bar("square.on.square", on: true) { onTabs() }
                Text("\(store.tabs.filter { $0.isPrivate == tab.isPrivate }.count)").contentTransition(.numericText())
                    .font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).offset(x: 0.5, y: 1.5).allowsHitTesting(false)
            }
            bar("ellipsis", on: true, action: onMenu)
        }
        .padding(.horizontal, 10).frame(height: 52)
        .lunoGlass(Capsule())
    }

    private func bar(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
                .foregroundStyle(on ? theme.ink : theme.inkSoft.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(PressableStyle(scale: 0.88)).disabled(!on)
    }
}
