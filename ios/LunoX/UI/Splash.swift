import SwiftUI

/// The app icon, drawn (crisp at any size): indigo gradient, soft glow, white crescent.
struct SplashArt: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 1024
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1A1A48), Color(hex: 0x5242D8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0x6670D8).opacity(0.85), .clear], center: UnitPoint(x: 0.6, y: 0.43), startRadius: 0, endRadius: 360 * s)
                ZStack {
                    Circle().fill(Color(hex: 0xF7F7FB)).frame(width: 524 * s, height: 524 * s).position(x: 512 * s, y: 513 * s)
                    Circle().fill(.black).frame(width: 470 * s, height: 470 * s).position(x: 615 * s, y: 440 * s).blendMode(.destinationOut)
                }
                .frame(width: g.size.width, height: g.size.height)
                .compositingGroup()
                .shadow(color: .white.opacity(0.3), radius: 40 * s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Cold-start splash: continues the system launch screen (icon in the middle), the icon then grows until it fills the whole screen and
/// stays there until the app has finished restoring tabs and loading the first page / caches; then it fades away.
@MainActor
final class SplashController: ObservableObject {
    enum Phase { case icon, full, done }
    @Published var phase: Phase = .icon
    @Published var finished = false

    init() {
        #if DEBUG
        if Demo.value("demo") != nil || ProcessInfo.processInfo.arguments.contains("-nosplash") { phase = .done; finished = true }
        #endif
    }

    private func pageReady(_ store: BrowserStore) -> Bool {
        guard let t = store.current else { return true }
        if t.isBlank || t.template != nil { return true }
        return t.progress >= 0.8 || (t.webView?.url != nil && !t.isLoading)
    }

    func run(store: BrowserStore) async {
        guard !finished else { return }
        let t0 = Date()
        try? await Task.sleep(nanoseconds: 140_000_000)
        withAnimation(.spring(response: 0.7, dampingFraction: 0.88)) { phase = .full }
        // hold until tabs are restored, the first page has loaded and the caches are in; never longer than 6 seconds
        while Date().timeIntervalSince(t0) < 6 {
            if Date().timeIntervalSince(t0) > 1.4, store.ready, pageReady(store) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        withAnimation(.easeInOut(duration: 0.5)) { phase = .done }
        try? await Task.sleep(nanoseconds: 650_000_000)
        finished = true
    }
}

struct SplashView: View {
    @ObservedObject var c: SplashController
    var body: some View {
        GeometryReader { g in
            let side = max(g.size.width, g.size.height)
            ZStack {
                Color("LaunchBackground")
                SplashArt()
                    .frame(width: c.phase == .icon ? 120 : side, height: c.phase == .icon ? 120 : side)
                    .clipShape(RoundedRectangle(cornerRadius: c.phase == .icon ? 26.8 : 0, style: .continuous))
                    .phaseAnimator(c.phase == .full ? [1.0, 1.025] : [1.0]) { v, p in v.scaleEffect(p) } animation: { _ in .easeInOut(duration: 1.4) }
            }
            .frame(width: g.size.width, height: g.size.height)
            .opacity(c.phase == .done ? 0 : 1)
            .scaleEffect(c.phase == .done ? 1.08 : 1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(c.phase != .done)
    }
}
