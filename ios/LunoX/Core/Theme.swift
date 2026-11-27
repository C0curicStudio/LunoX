import SwiftUI

/// A resolved palette (one family in one appearance).
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let scheme: ColorScheme
    let bgTop: Color
    let bgBottom: Color
    let surface: Color      // cards / tiles (Safari-style grouped surface)
    let ink: Color
    let inkSoft: Color
    let accent: Color
    let glow: Color
    let shapeA: Color       // flat decorative shapes
    let shapeB: Color
    let shapeC: Color

    var background: LinearGradient { LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom) }
    static let fallback = ThemeFamily.all[0].light
}

/// One theme = a light and a dark variant; the app picks by the system (or forced) appearance.
struct ThemeFamily: Identifiable {
    let id: String
    let name: String
    let light: Theme
    let dark: Theme
    func resolve(_ s: ColorScheme) -> Theme { s == .dark ? dark : light }

    private static func mk(_ id: String, _ name: String, _ scheme: ColorScheme,
                           _ top: UInt32, _ bot: UInt32, _ surface: UInt32, _ ink: UInt32, _ soft: UInt32,
                           _ accent: UInt32, _ glow: UInt32, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> Theme {
        Theme(id: id, name: name, scheme: scheme, bgTop: Color(hex: top), bgBottom: Color(hex: bot), surface: Color(hex: surface),
              ink: Color(hex: ink), inkSoft: Color(hex: soft), accent: Color(hex: accent), glow: Color(hex: glow),
              shapeA: Color(hex: a), shapeB: Color(hex: b), shapeC: Color(hex: c))
    }
    private static func fam(_ id: String, _ name: String,
                            light l: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                            dark d: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)) -> ThemeFamily {
        ThemeFamily(id: id, name: name,
                    light: mk(id, name, .light, l.0, l.1, l.2, l.3, l.4, l.5, l.6, l.7, l.8, l.9),
                    dark: mk(id, name, .dark, d.0, d.1, d.2, d.3, d.4, d.5, d.6, d.7, d.8, d.9))
    }
    // (bgTop, bgBottom, surface, ink, inkSoft, accent, glow, shapeA, shapeB, shapeC)
    static let all: [ThemeFamily] = [
        fam("safari", "海盐蓝",
            light: (0xF5F7FB, 0xE8EEF9, 0xFFFFFF, 0x0F1115, 0x6C7280, 0x0A84FF, 0x7DB8FF, 0x0A84FF, 0x5AC8FA, 0xFFB340),
            dark: (0x0A0B10, 0x14161E, 0x1C1E27, 0xF5F6FA, 0x8C93A3, 0x4DA3FF, 0x1F5FB8, 0x2F7DE1, 0x38A8D8, 0xE59A2E)),
        fam("mint", "薄荷",
            light: (0xF2FBF9, 0xDDF2EC, 0xFFFFFF, 0x0E1A17, 0x5F7A74, 0x14B8A6, 0x7FE0D2, 0x14B8A6, 0xA3E635, 0xFF8A7A),
            dark: (0x07130F, 0x0E1F1B, 0x15261F, 0xE9FBF6, 0x7FA69C, 0x2DD4BF, 0x127A6E, 0x1FA394, 0x7CB518, 0xD9685A)),
        fam("sakura", "樱",
            light: (0xFFF6F9, 0xFBE4EE, 0xFFFFFF, 0x2A1520, 0x9B6B7E, 0xE5558A, 0xFFB3CF, 0xE5558A, 0xFFB38A, 0xB79CFF),
            dark: (0x1A0F15, 0x2A1520, 0x321B28, 0xFBEAF1, 0xB48499, 0xFF7AA8, 0x9B2D5C, 0xD9507F, 0xE08A5C, 0x8B6FE0)),
        fam("dusk", "暮光",
            light: (0xF6F3FF, 0xE6DFFB, 0xFFFFFF, 0x1A1230, 0x7A6C9E, 0x7C5CFF, 0xBDA9FF, 0x7C5CFF, 0xFF8A5C, 0xFF6FA5),
            dark: (0x110D1E, 0x1F1634, 0x281D40, 0xF2ECFF, 0x9C8BC4, 0xA78BFA, 0x5B3FC4, 0x7C5CFF, 0xE0704A, 0xD9578A)),
        fam("moss", "苔",
            light: (0xF4F7F1, 0xE1EAD9, 0xFFFFFF, 0x16200F, 0x6C7F5E, 0x4C8B3A, 0xB5D6A3, 0x4C8B3A, 0xE9C46A, 0xD9825B),
            dark: (0x0D130A, 0x172110, 0x1F2C16, 0xEEF6E7, 0x8CA67A, 0x7BC862, 0x3F7A2D, 0x5FA84A, 0xC9A64F, 0xC26A44)),
        fam("amber", "琥珀",
            light: (0xFFF9EC, 0xFBEBCB, 0xFFFFFF, 0x241907, 0x8F7A4F, 0xF59E0B, 0xFFD27A, 0xF59E0B, 0xEF5B3C, 0x2BB5A5),
            dark: (0x16100A, 0x241A0C, 0x2E2210, 0xFFF3DC, 0xB59B6A, 0xFBBF24, 0x9A6200, 0xD98A0A, 0xD9492A, 0x1F9486)),
    ]
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    var forced: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.fallback }
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
        .buttonStyle(PressableStyle(scale: 0.9))
        .disabled(!enabled)
        .lunoGlass(Circle())
    }
}


// MARK: - Motion helpers

/// Springy press feedback used by every tappable tile/card/button.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

extension View {
    /// Fade + rise in, one after another.
    func staggered(_ index: Int, _ shown: Bool, rise: CGFloat = 16) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .scaleEffect(shown ? 1 : 0.96)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(min(index, 14)) * 0.028), value: shown)
    }
}
