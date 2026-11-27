import SwiftUI

/// Site icon with a tasteful fallback (first letter on a tinted tile).
struct FaviconTile: View {
    var image: UIImage?
    var fallback: String
    var symbol: String? = nil
    var size: CGFloat = 28
    var radius: CGFloat? = nil
    @Environment(\.theme) private var theme
    var body: some View {
        let r = radius ?? size * 0.28
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous).fill(image == nil ? theme.accent.opacity(0.16) : Color(white: theme.scheme == .dark ? 0.93 : 1))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.14).clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(theme.accent)
            } else {
                Text(String(fallback.prefix(1)).uppercased()).font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(theme.accent)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).stroke(theme.inkSoft.opacity(0.14), lineWidth: 0.5))
    }
}

/// Full-screen stand-in for the live page; matched with a tab card so the page visibly shrinks into / grows out of it.
struct HeroSnapshot: View {
    @ObservedObject var tab: Tab
    var ns: Namespace.ID
    @Environment(\.theme) private var theme
    var body: some View {
        Group {
            if let img = tab.hero ?? tab.thumbnail { Image(uiImage: img).resizable().scaledToFill() } else { theme.background }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .ignoresSafeArea()
        .matchedGeometryEffect(id: tab.id, in: ns)
    }
}

/// Safari-like two-way pill with a sliding highlight.
struct SegmentPill: View {
    @Binding var selection: Int
    var items: [(String, String)]     // (icon, title)
    @Namespace private var ns
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                Button { Haptics.soft(); withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = i } } label: {
                    Label(it.1, systemImage: it.0).font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == i ? theme.ink : theme.inkSoft)
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background { if selection == i { Capsule().fill(theme.surface).shadow(color: .black.opacity(0.1), radius: 6, y: 2).matchedGeometryEffect(id: "pill", in: ns) } }
                }.buttonStyle(.plain)
            }
        }
        .padding(4).background(theme.inkSoft.opacity(0.14), in: Capsule())
    }
}
