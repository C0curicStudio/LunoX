import SwiftUI

/// "Offer to save this password?" capsule at the top of the page (like Safari's).
struct SavePasswordBar: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    var body: some View {
        if let p = store.savePrompt {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.update ? "更新「\(p.site)」的密码？" : "保存「\(p.site)」的密码？").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                        Text(p.user.isEmpty ? "只有密码" : p.user).font(.system(size: 12)).foregroundStyle(theme.inkSoft).lineLimit(1)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button { dismiss() } label: { pill("不保存", filled: false) }
                    Button { store.vault.neverSave(p.site); dismiss() } label: { pill("永不", filled: false) }
                    Button { store.vault.save(site: p.site, username: p.user, password: p.pass); Haptics.ok(); dismiss() } label: { pill(p.update ? "更新" : "保存", filled: true) }
                }
            }
            .padding(14).frame(maxWidth: 380).lunoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16).transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    private func pill(_ t: String, filled: Bool) -> some View {
        Text(t).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(filled ? .white : theme.ink)
            .frame(maxWidth: .infinity).frame(height: 36).background(filled ? theme.accent : theme.inkSoft.opacity(0.14), in: Capsule())
    }
    private func dismiss() { withAnimation(Motion.snappy) { store.savePrompt = nil } }
}

/// Sign-ins and accounts of the current site, one tap each, after Face ID.
struct LoginPicker: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var unlocked = false
    @State private var failed = false
    @State private var msg: String?
    private var host: String? { tab.url?.host }

    var body: some View {
        let vault = store.vault
        NavigationStack {
            List {
                if !unlocked {
                    Section { Button { Task { await unlock() } } label: { Label(failed ? "验证失败，点这里重试" : "用 Face ID 解锁", systemImage: "faceid") } }
                } else {
                    let creds = vault.logins(for: host), accts = vault.accounts(for: host)
                    if !creds.isEmpty {
                        Section("密码") {
                            ForEach(creds) { c in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) { Text(c.username.isEmpty ? "（无账号）" : c.username).font(.system(size: 16, weight: .medium)); Text(c.site).font(.caption).foregroundStyle(theme.inkSoft) }
                                    Spacer()
                                    Button("填充") { go { await tab.fillLogin(c, submit: false) } }.buttonStyle(.bordered)
                                    Button("登录") { go { await tab.fillLogin(c, submit: true) } }.buttonStyle(.borderedProminent)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !accts.isEmpty {
                        Section("账号（一键登录）") {
                            ForEach(accts) { a in
                                Button { go { await tab.loginWith(a) } } label: {
                                    HStack {
                                        Image(systemName: "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(theme.accent)
                                        VStack(alignment: .leading, spacing: 2) { Text(a.label).font(.system(size: 16, weight: .medium)); Text("保存于 \(a.savedAt.formatted(date: .abbreviated, time: .omitted)) · \(a.cookies.count) 个 Cookie").font(.caption).foregroundStyle(theme.inkSoft) }
                                        Spacer(); Text("登录").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                                    }
                                }.foregroundStyle(theme.ink)
                            }
                        }
                    }
                    Section {
                        Button { Task { if await vault.saveAccount(from: tab) != nil { msg = "已保存当前登录状态"; Haptics.ok() } else { msg = "当前页面还没有登录状态（没有 Cookie）"; Haptics.warn() } } } label: { Label("把当前登录状态保存为账号", systemImage: "person.badge.plus") }
                        if let h = host, !h.isEmpty, vault.logins(for: h).isEmpty {
                            Text("在登录页提交账号密码后，会问你要不要保存。").font(.footnote).foregroundStyle(theme.inkSoft)
                        }
                    } footer: { if let msg { Text(msg) } }
                }
            }
            .navigationTitle(vault.site(for: host)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .task { await unlock() }
    }

    private func unlock() async { unlocked = await store.vault.unlock(); failed = !unlocked }
    private func go(_ work: @escaping () async -> Void) { Task { await work(); dismiss() } }
}
