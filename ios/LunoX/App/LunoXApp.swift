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
                .environmentObject(store)
                .environmentObject(store.settings)
                .environmentObject(store.router)
                .environmentObject(store.edge)
                .environmentObject(store.offline)
                .environmentObject(store.downloads)
                .environmentObject(store.extensions)
                .environmentObject(lock)
                .onOpenURL { url in
                    if store.settings.applySetupLink(url) { store.router.apply(); Haptics.ok() }
                    else if url.scheme == "http" || url.scheme == "https" { store.newTab(url: url) }
                }
                .onChange(of: phase) { _, p in
                    if p == .background { store.persistNow(); if store.settings.prefs.appLock { lock.lock() } }
                    if p == .active { Task { await store.edge.resume() } }
                    if p == .active, store.settings.prefs.appLock { lock.unlockIfNeeded() }
                }
        }
    }
}

struct ThemedRoot: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var lock: AppLock
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let theme = settings.theme
        ZStack {
            RootView()
            if settings.prefs.appLock && (lock.locked || phase != .active) { LockView() }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme)
        .tint(theme.accent)
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
