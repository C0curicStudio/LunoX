import SwiftUI
import LocalAuthentication

@main
struct LunoXApp: App {
    @StateObject private var store = BrowserStore()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .onAppear { BrowserStoreHolder.shared = store }
                .environmentObject(store)
                .environmentObject(store.settings)
                .environmentObject(store.router)
                .environmentObject(store.edge)
                .environmentObject(store.news)
                .environmentObject(store.offline)
                .environmentObject(store.downloads)
                .environmentObject(store.extensions)
                .environmentObject(lock)
                .onOpenURL { url in
                    if store.applyPairing(url) { Haptics.ok() }
                    else if url.scheme == "http" || url.scheme == "https" { store.newTab(url: url) }
                }
                .onChange(of: phase) { _, p in
                    if p == .background { store.persistNow(); if store.settings.prefs.appLock { lock.lock() } }
                    if p == .active { Task { await store.edge.resume() }; store.hy2.warm() }
                    if p == .active, store.settings.prefs.appLock { lock.unlockIfNeeded() }
                }
        }
    }
}

struct ThemedRoot: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var store: BrowserStore
    @Environment(\.colorScheme) private var system
    @Environment(\.scenePhase) private var phase
    @StateObject private var splash = SplashController()

    private var effective: ColorScheme { settings.prefs.appearance.forced ?? system }

    var body: some View {
        let theme = settings.family.resolve(effective)
        ZStack {
            RootView()
            if settings.prefs.appLock && (lock.locked || phase != .active) { LockView().transition(.opacity) }
            if !splash.finished { SplashView(c: splash).zIndex(100) }
        }
        .task { await splash.run(store: store) }
        .environment(\.theme, theme)
        .preferredColorScheme(settings.prefs.appearance.forced)
        .tint(theme.accent)
        .animation(.easeInOut(duration: 0.35), value: theme)       // day/night + theme changes cross-fade
        .onAppear { store.applyAppearance(settings.prefs.appearance); store.applyTheme(theme) }
        .onChange(of: settings.prefs.appearance) { _, a in store.applyAppearance(a) }
        .onChange(of: theme) { _, t in store.applyTheme(t) }
        .onChange(of: settings.prefs.autoDarkPages) { _, _ in store.applyTheme(theme) }
    }
}

@MainActor
final class AppLock: ObservableObject {
    @Published var locked = true
    private var busy = false
    func lock() { locked = true }
    func unlockIfNeeded() {
        guard locked, !busy else { return }
        busy = true
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 LunoX") { ok, _ in
            Task { @MainActor in self.busy = false; if ok { self.locked = false } }
        }
    }
}

struct LockView: View {
    @EnvironmentObject var lock: AppLock
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 34, weight: .light))
                Text("LunoX 已锁定").font(.system(.title3, design: .rounded, weight: .semibold))
                Button("解锁") { lock.unlockIfNeeded() }.buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule())
            }.foregroundStyle(theme.ink)
        }
    }
}
