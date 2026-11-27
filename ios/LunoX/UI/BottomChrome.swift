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
        .opacity(searching ? 0 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: collapsed)
    }

    private func omnibox(collapsed: Bool) -> some View {
        HStack(spacing: 10) {
            if !collapsed {
                Button { Haptics.tap(); onSite() } label: { siteIcon }.buttonStyle(.plain)
            }
            Button(action: onSearch) {
                Text(tab.isBlank ? "搜索或输入网址" : (tab.url?.displayHost ?? ""))
                    .font(.system(size: collapsed ? 13 : 16, weight: .medium, design: .rounded))
                    .foregroundStyle(tab.isBlank ? theme.inkSoft : theme.ink)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            }.buttonStyle(.plain)
            if !collapsed && !tab.isBlank {
                Button { Haptics.tap(); tab.isLoading ? tab.stop() : tab.reload() } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.inkSoft)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, collapsed ? 14 : 18)
        .frame(height: collapsed ? 34 : 52)
        .overlay(alignment: .bottom) { progressLine }
        .clipShape(Capsule())
        .lunoGlass(Capsule())
        .matchedGeometryEffect(id: "omni", in: ns, isSource: !searching)
        .onTapGesture { if collapsed { store.setBars(collapsed: false) } }
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
                bar("square.on.square", on: true) { store.showSwitcher = true }
                Text("\(store.tabs.filter { $0.isPrivate == tab.isPrivate }.count)")
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
        }.buttonStyle(.plain).disabled(!on)
    }
}
