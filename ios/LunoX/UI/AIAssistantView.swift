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

/// The assistant is just an input bar at the bottom of the screen (like Chrome's). The answer streams into a small card above it;
/// there is no separate screen. Tap outside, swipe down or press ✕ to put it away.
struct AIQuickBar: View {
    @ObservedObject var tab: Tab
    var initialQuestion: String = ""
    var onClose: () -> Void
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    @StateObject private var model = AssistantModel()
    @State private var input = ""
    @State private var showAgent = false
    @FocusState private var focus: Bool

    private var hasPage: Bool { !tab.isBlank }
    private var answer: AMessage? { model.messages.last { $0.role == .assistant } }
    private var showCard: Bool { model.busy || !(answer?.text.isEmpty ?? true) || !settings.gatewayConfigured }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(showCard ? 0.18 : 0.001).ignoresSafeArea()
                .onTapGesture { close() }
                .animation(.easeInOut(duration: 0.2), value: showCard)
            VStack(spacing: 10) {
                if showCard { card.transition(.move(edge: .bottom).combined(with: .opacity)) }
                bar
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 40 { close() } })
        }
        .animation(Motion.snappy, value: showCard)
        .sheet(isPresented: $showAgent) { AIPanel(tab: tab, initialQuestion: "", initialMode: .agent).presentationDetents([.large]) }
        .onAppear { if !initialQuestion.isEmpty { send(initialQuestion) } else { focus = true } }
        .onDisappear { model.cancel() }
    }

    // MARK: the answer

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
                Text(answer?.note ?? "AI").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(theme.inkSoft)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(theme.inkSoft.opacity(0.6)) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !settings.gatewayConfigured {
                        Label("还没有连接服务器：AI 需要先配对（设置 › 网络）。", systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
                    }
                    if let a = answer {
                        if a.text.isEmpty { if model.busy { ProgressView().padding(.vertical, 6) } }
                        else {
                            Text((try? AttributedString(markdown: a.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(a.text))
                                .font(.system(size: 16, design: .rounded)).foregroundStyle(theme.ink).lineSpacing(4).textSelection(.enabled)
                        }
                        ForEach(a.opens) { o in
                            Button { Haptics.soft(); openHere(o.url) } label: {
                                HStack(spacing: 8) { Image(systemName: "arrow.up.right.circle.fill"); Text("打开 \(o.title)").lineLimit(1); Spacer() }
                                    .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 10).background(theme.accent, in: Capsule())
                            }.buttonStyle(PressableStyle(scale: 0.98))
                        }
                        if !a.sources.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(a.sources.enumerated()), id: \.offset) { i, s in
                                        Button { Haptics.tap(); openNew(s.url) } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("[\(i + 1)] \(s.title)").font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                                Text(URL(string: s.url)?.displayHost ?? "").font(.system(size: 11)).foregroundStyle(theme.inkSoft)
                                            }.frame(width: 160, alignment: .leading).padding(9).background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(theme.ink)
                                        }.buttonStyle(PressableStyle(scale: 0.97))
                                    }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
        }
        .padding(14).frame(maxWidth: .infinity)
        .lunoGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: the input

    private var bar: some View {
        HStack(spacing: 10) {
            Menu {
                if hasPage { Button { showAgent = true } label: { Label("让 AI 操作这个网页", systemImage: "wand.and.stars") } }
                if hasPage { Button { close(); Task { await tab.translate() } } label: { Label("翻译这个页面", systemImage: "character.bubble") } }
                if let q = model.messages.last(where: { $0.role == .user })?.text, let u = URLResolver.search(q, settings.engine) {
                    Button { openNew(u.absoluteString) } label: { Label("用搜索引擎搜这个问题", systemImage: "magnifyingglass") }
                }
                if !model.messages.isEmpty { Button(role: .destructive) { model.reset() } label: { Label("新对话", systemImage: "square.and.pencil") } }
            } label: { Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.accent).frame(width: 36, height: 44) }
            TextField(hasPage ? "问 AI（会读这个页面），或说“打开…”" : "问 AI，或说“打开…”", text: $input)
                .focused($focus).submitLabel(.send).onSubmit { send(input) }
                .font(.system(size: 16, design: .rounded))
            Button { model.busy ? model.cancel() : send(input) } label: {
                Image(systemName: model.busy ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(input.trimmingCharacters(in: .whitespaces).isEmpty && !model.busy ? theme.inkSoft.opacity(0.4) : theme.accent, in: Circle())
            }.disabled(!model.busy && input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 8).padding(.trailing, 8).frame(height: 52)
        .lunoGlass(Capsule())
    }

    // MARK: actions

    private func close() { focus = false; onClose() }
    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        input = ""
        model.send(t, usePage: hasPage, tab: tab, store: store) { u in openHere(u.absoluteString) }
    }
    private func openHere(_ s: String) {
        guard let u = URL(string: s) else { return }
        close(); store.showSwitcher = false
        tab.navigate(u)
    }
    private func openNew(_ s: String) {
        guard let u = URL(string: s) else { return }
        close(); store.showSwitcher = false
        store.newTab(url: u, isPrivate: tab.isPrivate)
    }
}
