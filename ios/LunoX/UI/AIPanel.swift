import SwiftUI

enum AIMode: String, CaseIterable, Identifiable {
    case summarize = "总结", ask = "提问", search = "搜索", translate = "翻译", agent = "自动化"
    var id: String { rawValue }
}

@MainActor
final class AIModel: ObservableObject {
    @Published var output = ""
    @Published var sources: [SearchHit] = []
    @Published var busy = false
    @Published var steps: [String] = []
    @Published var confirm: String?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var job: Task<Void, Never>?

    func cancel() { job?.cancel(); busy = false; continuation?.resume(returning: false); continuation = nil; confirm = nil }
    func answer(_ ok: Bool) { continuation?.resume(returning: ok); continuation = nil; confirm = nil }

    func run(mode: AIMode, input: String, tab: Tab, store: BrowserStore, stepByStep: Bool) {
        cancel(); output = ""; sources = []; steps = []; busy = true
        job = Task {
            defer { busy = false }
            do {
                switch mode {
                case .search:
                    try await stream(store, "search_answer", ["question": input])
                case .summarize, .ask, .translate:
                    let text = await tab.pageText()
                    guard !text.isEmpty else { output = "当前页面没有可读取的文字。"; return }
                    var args: [String: Any] = ["text": text, "url": tab.url?.absoluteString ?? "", "title": tab.title]
                    if mode == .ask { args["question"] = input }
                    try await stream(store, mode == .summarize ? "summarize" : mode == .ask ? "ask" : "translate", args)
                case .agent:
                    try await agent(goal: input, tab: tab, store: store, stepByStep: stepByStep)
                }
            } catch is CancellationError {
            } catch { output += (output.isEmpty ? "" : "\n\n") + "⚠️ \(error.localizedDescription)" }
        }
    }

    private func stream(_ store: BrowserStore, _ task: String, _ args: [String: Any]) async throws {
        for try await t in store.gateway.stream(task: task, args: args, sources: { [weak self] h in Task { @MainActor in self?.sources = h } }) { output += t }
    }

    /// Plan → (confirm) → act loop. Sensitive fields are never typed; payments/deletes need explicit approval.
    private func agent(goal: String, tab: Tab, store: BrowserStore, stepByStep: Bool) async throws {
        var history: [String] = []
        for round in 1...8 {
            try Task.checkCancellation()
            guard let snap = await tab.snapshot() else { output = "无法读取当前页面。"; return }
            let plan = try await store.gateway.act(args: ["goal": goal, "url": tab.url?.absoluteString ?? "", "title": tab.title, "text": snap.text, "history": history])
            steps.append("\(round). \(plan.thought)")
            if plan.done { output = plan.answer.isEmpty ? "完成。" : plan.answer; return }
            if plan.actions.isEmpty { output = "AI 没有给出可执行的步骤。"; return }
            for a in plan.actions {
                try Task.checkCancellation()
                let desc = describe(a)
                let sensitive = a.id.map { snap.sensitive.contains($0) } ?? false
                if a.type == "type", sensitive { output = "该输入框涉及密码或敏感信息，已停止。请手动完成。"; return }
                let risky = stepByStep || sensitive || a.type == "goto" || a.submit == true
                if risky {
                    confirm = desc + (sensitive ? "（敏感操作）" : "")
                    let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in continuation = c }
                    if !ok { output = "已取消。"; return }
                }
                steps.append("   → \(desc)")
                if a.type == "goto", let s = a.url, let u = URL(string: s) { tab.navigate(u) }
                else { history.append("\(desc): \(await tab.run(a))") }
                if a.type == "goto" { history.append(desc) }
                try await Task.sleep(nanoseconds: 900_000_000)
            }
            for _ in 0..<20 where tab.isLoading { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        output = "已达到步骤上限，请查看页面当前状态。"
    }

    private func describe(_ a: AgentAction) -> String {
        switch a.type {
        case "click": return "点击元素 [\(a.id ?? 0)]"
        case "type": return "在 [\(a.id ?? 0)] 输入「\(a.text ?? "")」" + (a.submit == true ? " 并提交" : "")
        case "scroll": return "滚动 \(a.dy ?? 0)"
        case "goto": return "打开 \(a.url ?? "")"
        case "extract": return "读取元素 [\(a.id ?? 0)]"
        default: return a.type
        }
    }
}

struct AIPanel: View {
    @ObservedObject var tab: Tab
    var initialQuestion: String
    var initialMode: AIMode
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @Environment(\.theme) private var theme
    @StateObject private var model = AIModel()
    @State private var mode: AIMode = .summarize
    @State private var input = ""
    @State private var stepByStep = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) { ForEach(AIMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !settings.gatewayConfigured {
                        Label("请先在 设置 › 网络与线路 完成服务器配对", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if mode == .agent && !model.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) { ForEach(model.steps, id: \.self) { Text($0).font(.footnote).foregroundStyle(theme.inkSoft) } }
                    }
                    if !model.output.isEmpty { Text((try? AttributedString(markdown: model.output, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(model.output)).textSelection(.enabled).font(.system(size: 16, design: .rounded)).lineSpacing(4) }
                    else if model.busy { ProgressView().padding(.top, 20) }
                    if !model.sources.isEmpty {
                        Divider()
                        ForEach(Array(model.sources.enumerated()), id: \.offset) { i, s in
                            Button { store.newTab(url: URL(string: s.url)); store.showSwitcher = false } label: {
                                VStack(alignment: .leading, spacing: 2) { Text("[\(i + 1)] \(s.title)").font(.system(size: 14, weight: .medium)); Text(URL(string: s.url)?.displayHost ?? "").font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }

            if let c = model.confirm {
                VStack(spacing: 10) {
                    Text("AI 想要：\(c)").font(.system(size: 14, weight: .medium)).multilineTextAlignment(.center)
                    HStack { Button("拒绝", role: .cancel) { model.answer(false) }.buttonStyle(.bordered); Button("允许") { model.answer(true) }.buttonStyle(.borderedProminent) }
                }.padding().frame(maxWidth: .infinity).background(.thinMaterial)
            }

            VStack(spacing: 10) {
                if mode == .agent { Toggle("每一步都确认", isOn: $stepByStep).font(.footnote) }
                HStack(spacing: 10) {
                    if needsInput { TextField(placeholder, text: $input, axis: .vertical).lineLimit(1...3).padding(.horizontal, 16).padding(.vertical, 11).background(.thinMaterial, in: Capsule()) }
                    else { Spacer() }
                    Button { model.busy ? model.cancel() : go() } label: {
                        Image(systemName: model.busy ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44).background(theme.accent, in: Circle())
                    }.disabled(!model.busy && needsInput && input.isEmpty)
                }
            }.padding(16)
        }
        .navigationTitle("AI 助手").navigationBarTitleDisplayMode(.inline)
        .presentationBackground(.regularMaterial)
        .onAppear { mode = initialMode; input = initialQuestion; if !initialQuestion.isEmpty { go() } }
        .onDisappear { model.cancel() }
    }

    private var needsInput: Bool { mode == .ask || mode == .search || mode == .agent }
    private var placeholder: String { mode == .ask ? "关于这个页面，问点什么…" : mode == .search ? "搜索并让 AI 总结…" : "告诉 AI 要做什么，例如：搜索 xxx 并打开第一条" }
    private func go() { model.run(mode: mode, input: input, tab: tab, store: store, stepByStep: stepByStep) }
}
