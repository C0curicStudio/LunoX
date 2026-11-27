import SwiftUI

struct ExtensionsView: View {
    @EnvironmentObject var ext: ExtensionManager
    @EnvironmentObject var store: BrowserStore
    @State private var showAdd = false
    @State private var text = ""
    @State private var urlText = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            Section(footer: Text("支持 Greasemonkey/Tampermonkey 的 .user.js 脚本与 LunoX JSON 扩展。Chrome 的 .crx 扩展依赖 Blink 引擎，无法在 iOS 上运行。新开的标签页会应用变更。")) {
                ForEach($ext.items) { $e in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $e.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).font(.system(size: 16, weight: .medium))
                                if !e.desc.isEmpty { Text(e.desc).font(.caption).foregroundStyle(.secondary) }
                                Text("v\(e.version)\(e.builtin ? " · 内置" : "")").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .swipeActions { if !e.builtin { Button(role: .destructive) { ext.remove(e) } label: { Label("删除", systemImage: "trash") } } }
                }
            }
        }
        .navigationTitle("扩展与脚本")
        .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    Section("从网址安装") {
                        TextField("https://…/script.user.js", text: $urlText).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button(busy ? "下载中…" : "下载并安装") { Task { await installURL() } }.disabled(urlText.isEmpty || busy)
                    }
                    Section("或粘贴脚本 / manifest") {
                        TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).frame(minHeight: 180)
                        Button("安装") { do { try ext.install(text: text); showAdd = false; text = "" } catch { self.error = error.localizedDescription } }.disabled(text.isEmpty)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                .navigationTitle("添加扩展").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { showAdd = false } }
            }
        }
    }

    private func installURL() async {
        guard let u = URL(string: urlText), u.scheme == "https" || u.scheme == "http" else { error = "网址无效"; return }
        busy = true; defer { busy = false }
        do {
            var data: Data
            do { data = try await URLSession.shared.data(from: u).0 }
            catch { data = try await store.gateway.fetch(u, maxBytes: 2_000_000).0 }   // direct failed → fetch via the server
            guard let s = String(data: data, encoding: .utf8) else { error = "不是文本文件"; return }
            try ext.install(text: s); showAdd = false; urlText = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
