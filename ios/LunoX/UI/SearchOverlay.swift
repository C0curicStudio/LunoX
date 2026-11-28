import SwiftUI
import UIKit

/// Becomes first responder only once it is really in a window (asking earlier is silently ignored by iOS).
final class FocusField: UITextField {
    private var pending = true
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, pending else { return }
        pending = false
        for delay in [0.05, 0.35] {   // second attempt covers the overlay's transition animation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                self.becomeFirstResponder(); self.selectAll(nil)
            }
        }
    }
}

struct OmniField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    func makeUIView(context: Context) -> UITextField {
        let f = FocusField()
        f.placeholder = placeholder
        f.keyboardType = .webSearch; f.returnKeyType = .go
        f.autocapitalizationType = .none; f.autocorrectionType = .no; f.spellCheckingType = .no
        f.clearButtonMode = .whileEditing
        f.font = UIFont.rounded(size: 17, weight: .medium)
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return f
    }
    func updateUIView(_ f: UITextField, context: Context) { if f.text != text { f.text = text } }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var p: OmniField
        init(_ p: OmniField) { self.p = p }
        @objc func changed(_ f: UITextField) { p.text = f.text ?? "" }
        func textFieldShouldReturn(_ f: UITextField) -> Bool { p.onSubmit(); return true }
    }
}
extension UIFont {
    static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    }
}

struct Suggestion: Identifiable, Hashable {
    enum Kind { case go, search, bookmark, history, offline, remote, ai }
    var id: String { "\(kind)|\(value)|\(title)" }
    var kind: Kind
    var title: String
    var subtitle = ""
    var value: String
}

struct SearchOverlay: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    var ns: Namespace.ID
    var close: () -> Void
    @State private var text = ""
    @State private var remote: [String] = []
    @State private var task: Task<Void, Never>?
    @State private var showAI = false
    @State private var aiQuestion = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.ultraThinMaterial).overlay(theme.bgTop.opacity(0.55)).ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 14) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { r in
                            Button { pick(r) } label: { row(r) }.buttonStyle(PressableStyle(scale: 0.98))
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 70)
                }
                .scrollDismissesKeyboard(.interactively)
                .animation(Motion.snappy, value: rows.map(\.id))
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSoft)
                    OmniField(text: $text, placeholder: "搜索或输入网址", onSubmit: { submit() })
                        .frame(height: 24)
                    Button("取消", action: close).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accent)
                }
                .padding(.horizontal, 18).frame(height: 52)
                .lunoGlass(Capsule())
                .matchedGeometryEffect(id: "omni", in: ns, isSource: true)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .onAppear { text = tab.isBlank ? "" : (tab.url?.absoluteString ?? "") }
        .onChange(of: text) { _, v in queryRemote(v) }
        .sheet(isPresented: $showAI) { AIAssistantView(tab: tab, initialQuestion: aiQuestion).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
    }

    private var rows: [Suggestion] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != tab.url?.absoluteString else { return recents }
        var out: [Suggestion] = []
        if aiRoutes(q) {
            out.append(Suggestion(kind: .ai, title: "问 AI：\(q)", subtitle: "联网搜索并回答 · 也可以直接带你去网站", value: q))
        }
        let isURL = URLResolver.resolve(q, engine: settings.engine).map { $0.host != URLResolver.search(q, settings.engine)?.host } ?? false
        if !isURL, settings.prefs.smartDirect, let t = SmartSearch.resolve(q) {
            out.append(Suggestion(kind: .go, title: t.isSearch ? "在\(t.name)搜索「\(t.query)」" : "打开 \(t.name)", subtitle: "直达 · \(t.url.displayHost)", value: q))
            out.append(Suggestion(kind: .search, title: q, subtitle: "\(settings.engine.name) 搜索", value: q))
        } else {
            out.append(Suggestion(kind: isURL ? .go : .search, title: q, subtitle: isURL ? "打开网址" : "\(settings.engine.name) 搜索", value: q))
        }
        let lower = q.lowercased()
        out += store.bookmarks.filter { $0.title.lowercased().contains(lower) || $0.url.lowercased().contains(lower) }.prefix(3)
            .map { Suggestion(kind: .bookmark, title: $0.title, subtitle: $0.url, value: $0.url) }
        out += store.offline.pages.filter { $0.title.lowercased().contains(lower) || $0.url.lowercased().contains(lower) }.prefix(2)
            .map { Suggestion(kind: .offline, title: $0.title, subtitle: "离线可用", value: $0.url) }
        out += store.history.filter { $0.title.lowercased().contains(lower) || $0.url.lowercased().contains(lower) }.prefix(3)
            .map { Suggestion(kind: .history, title: $0.title, subtitle: $0.url, value: $0.url) }
        out += remote.prefix(5).map { Suggestion(kind: .remote, title: $0, value: $0) }
        if !aiRoutes(q), settings.prefs.aiEnabled && settings.gatewayConfigured && q.count > 1 { out.append(Suggestion(kind: .ai, title: "问 AI：\(q)", subtitle: "联网搜索并总结", value: q)) }
        return out
    }
    private var recents: [Suggestion] {
        store.history.prefix(6).map { Suggestion(kind: .history, title: $0.title, subtitle: URL(string: $0.url)?.displayHost ?? "", value: $0.url) }
    }

    private func row(_ r: Suggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(r.kind)).frame(width: 24).foregroundStyle(r.kind == .ai ? theme.accent : theme.inkSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(theme.ink).lineLimit(1)
                if !r.subtitle.isEmpty { Text(r.subtitle).font(.system(size: 12)).foregroundStyle(theme.inkSoft).lineLimit(1) }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
    }
    private func icon(_ k: Suggestion.Kind) -> String {
        switch k { case .go: "arrow.up.right"; case .search, .remote: "magnifyingglass"; case .bookmark: "star.fill"; case .history: "clock"; case .offline: "arrow.down.circle"; case .ai: "sparkles" }
    }

    private func pick(_ r: Suggestion) {
        if r.kind == .ai { aiQuestion = r.value; showAI = true; return }
        go(r.value, smart: r.kind != .search)         // choosing the plain search row means "do not redirect"
    }
    /// A clear question / request, and the assistant is available: it answers instead of a search engine.
    private func aiRoutes(_ q: String) -> Bool {
        settings.prefs.aiRouting && settings.prefs.aiEnabled && settings.gatewayConfigured && QuestionIntent.isQuestion(q)
    }
    private func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiRoutes(q) { aiQuestion = q; showAI = true } else { go(text) }
    }
    private func go(_ s: String, smart: Bool = true) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        store.open(s, smart: smart); close()
    }
    private func queryRemote(_ q: String) {
        task?.cancel()
        if let t = SmartSearch.resolve(q), settings.prefs.smartDirect { Prefetch.dns(t.url.host) }
        else if let u = URLResolver.resolve(q, engine: settings.engine), u.host != URLResolver.search(q, settings.engine)?.host { Prefetch.dns(u.host) }
        guard settings.prefs.searchSuggest, q.count >= 2, !tab.isPrivate else { remote = []; return }
        task = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let r = await store.suggest(q, engine: settings.engine)
            if !Task.isCancelled { remote = r }
        }
    }
}
