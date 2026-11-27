import SwiftUI

/// LunoX design language: quiet, lots of air, one accent, glass on top of content.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let scheme: ColorScheme
    let bgTop: Color
    let bgBottom: Color
    let ink: Color
    let inkSoft: Color
    let accent: Color
    let glow: Color

    var background: LinearGradient { LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom) }

    static let mist = Theme(id: "mist", name: "薄雾", scheme: .light, bgTop: Color(hex: 0xF6F7FB), bgBottom: Color(hex: 0xE9ECF6), ink: Color(hex: 0x14161F), inkSoft: Color(hex: 0x6B7084), accent: Color(hex: 0x4F63FF), glow: Color(hex: 0x9FB0FF))
    static let ink = Theme(id: "ink", name: "墨夜", scheme: .dark, bgTop: Color(hex: 0x0E1016), bgBottom: Color(hex: 0x171A24), ink: Color(hex: 0xF2F3F8), inkSoft: Color(hex: 0x8A90A6), accent: Color(hex: 0x8C9BFF), glow: Color(hex: 0x3A46B8))
    static let aurora = Theme(id: "aurora", name: "极光", scheme: .dark, bgTop: Color(hex: 0x07151C), bgBottom: Color(hex: 0x0E2A2B), ink: Color(hex: 0xEAFBF6), inkSoft: Color(hex: 0x7FA6A0), accent: Color(hex: 0x3EE6B5), glow: Color(hex: 0x1AA6B7))
    static let sakura = Theme(id: "sakura", name: "樱", scheme: .light, bgTop: Color(hex: 0xFFF6F8), bgBottom: Color(hex: 0xFBE6EE), ink: Color(hex: 0x2A1620), inkSoft: Color(hex: 0x9B6B7E), accent: Color(hex: 0xE5558A), glow: Color(hex: 0xFFB3CF))
    static let moss = Theme(id: "moss", name: "苔", scheme: .light, bgTop: Color(hex: 0xF4F7F1), bgBottom: Color(hex: 0xE3EBDD), ink: Color(hex: 0x16200F), inkSoft: Color(hex: 0x6C7F5E), accent: Color(hex: 0x4C8B3A), glow: Color(hex: 0xB5D6A3))
    static let dusk = Theme(id: "dusk", name: "暮", scheme: .dark, bgTop: Color(hex: 0x1A1226), bgBottom: Color(hex: 0x2B1830), ink: Color(hex: 0xF7ECFF), inkSoft: Color(hex: 0xA088B3), accent: Color(hex: 0xFF8A5C), glow: Color(hex: 0x8B3FD1))
    static let all = [mist, ink, aurora, sakura, moss, dusk]
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.mist }
extension EnvironmentValues { var theme: Theme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }

// MARK: - Liquid Glass (iOS 26+) with a refined material fallback for iOS 17-25

extension View {
    @ViewBuilder
    func lunoGlass<S: Shape>(_ shape: S, interactive: Bool = true, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
            } else {
                self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            }
        } else {
            self.legacyGlass(shape, tint: tint)
        }
        #else
        self.legacyGlass(shape, tint: tint)
        #endif
    }

    func legacyGlass<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.18), in: shape)
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// Groups glass shapes so they blend/morph on iOS 26; plain container before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

struct GlassIconButton: View {
    let system: String
    var size: CGFloat = 44
    var enabled = true
    var badge: String? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? theme.ink : theme.inkSoft.opacity(0.5))
                .frame(width: size, height: size)
                .overlay(alignment: .center) {
                    if let badge { Text(badge).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(theme.ink) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .lunoGlass(Circle())
    }
}
