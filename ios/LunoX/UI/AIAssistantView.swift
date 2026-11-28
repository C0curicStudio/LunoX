import SwiftUI

struct AMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var sources: [SearchHit] = []
    var opens: [AOpen] = []
    var note: String?
}
struct AOpen: Identifiable, Equatable { let id = UUID(); var url: String; var title: String }

/// One conversation. Questions about the open page use the page text; everything else is answered from a live web search with numbered sources.
/// When the user asks to be taken somewhere, the answer ends with the site to open (and it is opened).
@MainActor
final class AssistantModel: ObservableObject {
    @Published var messages: [AMessage] = []
    @Published var busy = false
    private var job: Task<Void, Never>?

    func cancel() { job?.cancel(); busy = false }
    func reset() { cancel(); messages = [] }

    func send(_ raw: String, usePage: Bool, tab: Tab, store: BrowserStore, open: @escaping (URL) -> Void) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let history = messages.suffix(6).map { ($0.role == .user ? "用户：" : "助手：") + String($0.text.prefix(500)) }.joined(separator: "\n")
        messages.append(AMessage(role: .user, text: text))
        messages.append(AMessage(role: .assistant, text: ""))
        let idx = messages.count - 1
        busy = true
        job = Task {
            defer { busy = false }
            do {
                let navigate = QuestionIntent.wantsNavigation(text)
                // With a page open the assistant reads it (live, at the moment of asking) unless the question is plainly about the wider web.
                let webWords = ["搜索", "联网", "最新", "新闻", "官网", "今天", "天气", "价格", "search", "latest", "news"].contains { text.lowercased().contains($0) }
                let hasPage = !tab.isBlank
                let onPage = hasPage && !navigate && (QuestionIntent.refersToPage(text) || (usePage && !webWords))
                var task: String, args: [String: Any]
                if onPage {
                    let page = await tab.pageText()
                    guard !page.isEmpty else { messages[idx].text = "当前页面没有可读取的文字。"; return }
                    let summarise = ["总结", "概括", "要点", "summar"].contains { text.lowercased().contains($0) }
                    task = summarise ? "summarize" : "ask"
                    args = ["text": page, "url": tab.url?.absoluteString ?? "", "title": tab.title]
                    if !summarise { args["question"] = text }
                    messages[idx].note = "基于当前页面"
                } else {
                    task = "search_answer"
                    var q = history.isEmpty ? text : "对话上文：\n\(history)\n\n当前问题：\(text)"
                    q += "\n\n（如果用户想去某个网站、官网、文档、下载页或商品页，请在回答末尾单独写一行 `OPEN: 网址 | 标题`，网址必须来自搜索结果；不需要时不要写。）"
                    args = ["question": q]
                    messages[idx].note = "已联网搜索"
                }
                for try await t in store.gateway.stream(task: task, args: args, sources: { [weak self] h in Task { @MainActor in self?.messages[idx].sources = h } }) {
                    messages[idx].text += t
                }
                // pull the "OPEN:" lines out of the answer
                var kept: [String] = [], opens: [AOpen] = []
                for line in messages[idx].text.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.uppercased().hasPrefix("OPEN:") {
                        let rest = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let parts = rest.components(separatedBy: "|")
                        let url = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " `<>()[]"))
                        if let u = URL(string: url), ["http", "https"].contains(u.scheme ?? ""), u.host != nil {
                            opens.append(AOpen(url: url, title: parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " `")) : u.displayHost))
                        }
                    } else { kept.append(line) }
                }
                messages[idx].text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                messages[idx].opens = opens
                if navigate, let first = opens.first, let u = URL(string: first.url) {
                    messages[idx].note = "已为你打开 \(u.displayHost)"
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    open(u)
                }
            } catch is CancellationError {
            } catch {
                messages[idx].text += (messages[idx].text.isEmpty ? "" : "\n\n") + "⚠️ \(error.localizedDescription)"
            }
        }
    }
}

/// The assistant, laid out like the one in Chrome's address bar: one input, streaming answer, sources, shortcuts for the open page.
struct AIAssistantView: View {
    @ObservedObject var tab: Tab
    var initialQuestion: String = ""
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AssistantModel()
    @State private var input = ""
    @State private var showAgent = false
    @State private var usePage = true
    @State private var pageChars = 0
    @FocusState private var focus: Bool

    private var hasPage: Bool { !tab.isBlank }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !settings.gatewayConfigured { notPaired }
                        if model.messages.isEmpty { welcome }
                        ForEach(model.messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 6).id("end")
                    }.padding(.horizontal, 16).padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            composer
        }
        .background(theme.background.ignoresSafeArea())
        .presentationBackground(.regularMaterial)
        .sheet(isPresented: $showAgent) { AIPanel(tab: tab, initialQuestion: "", initialMode: .agent).presentationDetents([.large]) }
        .onAppear { if !initialQuestion.isEmpty { send(initialQuestion) } else { focus = true }; scan() }
        .onChange(of: tab.url) { _, _ in scan() }
        .onChange(of: tab.isLoading) { _, l in if !l { scan() } }
        .onDisappear { model.cancel() }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
            Text("AI 助手").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
            Spacer()
            if !model.messages.isEmpty {
                Button { Haptics.tap(); model.reset() } label: { Image(systemName: "square.and.pencil").font(.system(size: 16)).foregroundStyle(theme.inkSoft).frame(width: 36, height: 36) }
            }
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(theme.inkSoft.opacity(0.6)).frame(width: 36, height: 36) }
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("想问什么，或者想去哪里？").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).padding(.top, 10)
            Text("我会联网搜索后回答并标注来源；说“打开…”我会直接带你过去。").font(.system(size: 14, design: .rounded)).foregroundStyle(theme.inkSoft)
            VStack(alignment: .leading, spacing: 8) {
                if hasPage {
                    chip("doc.text", "总结这个页面") { send("总结一下这个页面") }
                    chip("list.bullet", "这个页面的要点是什么？") { send("这个页面的要点是什么？") }
                    chip("character.bubble", "翻译这个页面") { dismiss(); Task { await tab.translate() } }
                }
                chip("globe", "今天有什么重要的科技新闻？") { send("今天有什么重要的科技新闻？") }
                chip("arrow.up.right", "打开 SwiftUI 官方文档") { send("打开 SwiftUI 官方文档") }
                if hasPage { chip("wand.and.stars", "让 AI 帮我操作这个网页…") { showAgent = true } }
            }
        }
    }

    private func chip(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 22).foregroundStyle(theme.accent); Text(title).font(.system(size: 15, design: .rounded)).foregroundStyle(theme.ink); Spacer() }
                .padding(.horizontal, 14).padding(.vertical, 11).background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(PressableStyle(scale: 0.98))
    }

    private var notPaired: some View {
        Label("还没有连接服务器：AI 需要先配对（设置 › 网络）。", systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
    }

    @ViewBuilder private func bubble(_ m: AMessage) -> some View {
        if m.role == .user {
            HStack { Spacer(minLength: 50)
                Text(m.text).font(.system(size: 16, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10).background(theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let n = m.note { Text(n).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.inkSoft) }
                if m.text.isEmpty { if model.busy { ProgressView().padding(.vertical, 6) } }
                else {
                    Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                        .font(.system(size: 16, design: .rounded)).foregroundStyle(theme.ink).lineSpacing(4).textSelection(.enabled)
                }
                ForEach(m.opens) { o in
                    Button { Haptics.soft(); openHere(o.url) } label: {
                        HStack(spacing: 8) { Image(systemName: "arrow.up.right.circle.fill"); Text("打开 \(o.title)").lineLimit(1); Spacer() }
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 11).background(theme.accent, in: Capsule())
                    }.buttonStyle(PressableStyle(scale: 0.98))
                }
                if !m.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(m.sources.enumerated()), id: \.offset) { i, s in
                                Button { Haptics.tap(); openNew(s.url) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("[\(i + 1)] \(s.title)").font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                        Text(URL(string: s.url)?.displayHost ?? "").font(.system(size: 11)).foregroundStyle(theme.inkSoft)
                                    }.frame(width: 170, alignment: .leading).padding(10).background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).foregroundStyle(theme.ink)
                                }.buttonStyle(PressableStyle(scale: 0.97))
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Live scan": re-read the page whenever it changes, so the chip always says what the assistant can see.
    private func scan() {
        guard hasPage else { pageChars = 0; return }
        Task { pageChars = await tab.pageText().count }
    }

    @ViewBuilder private var pageChip: some View {
        if hasPage {
            Button { Haptics.tap(); usePage.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: usePage ? "eye.fill" : "eye.slash").foregroundStyle(usePage ? theme.accent : theme.inkSoft)
                    Text(usePage ? "正在阅读：\(tab.displayTitle)" : "不读取当前页面").lineLimit(1)
                    if usePage, pageChars > 0 { Text("\(pageChars) 字").foregroundStyle(theme.inkSoft) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 7).background(theme.surface, in: Capsule())
            }.buttonStyle(PressableStyle(scale: 0.98)).padding(.horizontal, 12).padding(.top, 4)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) { pageChip; composerRow }
    }

    private var composerRow: some View {
        HStack(spacing: 10) {
            Menu {
                if hasPage { Button { showAgent = true } label: { Label("让 AI 操作这个网页", systemImage: "wand.and.stars") } }
                if hasPage { Button { dismiss(); Task { await tab.translate() } } label: { Label("翻译这个页面", systemImage: "character.bubble") } }
                Button { if let q = lastUserQuestion, let u = URLResolver.search(q, settings.engine) { openNew(u.absoluteString) } } label: { Label("用搜索引擎搜这个问题", systemImage: "magnifyingglass") }
            } label: { Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(theme.inkSoft.opacity(0.7)).frame(width: 36, height: 44) }
            TextField(hasPage && usePage ? "问关于这个页面的问题，或任何问题" : "问问 AI，或说“打开…”", text: $input, axis: .vertical)
                .lineLimit(1...4).focused($focus).submitLabel(.send).onSubmit { send(input) }
                .padding(.horizontal, 16).padding(.vertical, 11).background(theme.surface, in: Capsule())
            Button { model.busy ? model.cancel() : send(input) } label: {
                Image(systemName: model.busy ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44).background(theme.accent, in: Circle())
            }.disabled(!model.busy && input.trimmingCharacters(in: .whitespaces).isEmpty)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var lastUserQuestion: String? { model.messages.last { $0.role == .user }?.text }

    // MARK: actions

    private func send(_ text: String) {
        input = ""
        model.send(text, usePage: usePage, tab: tab, store: store) { u in openHere(u.absoluteString) }
    }
    private func openHere(_ s: String) {
        guard let u = URL(string: s) else { return }
        dismiss(); store.showSwitcher = false
        tab.navigate(u)
    }
    private func openNew(_ s: String) {
        guard let u = URL(string: s) else { return }
        dismiss(); store.showSwitcher = false
        store.newTab(url: u, isPrivate: tab.isPrivate)
    }
}
