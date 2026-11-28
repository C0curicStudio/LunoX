import SwiftUI
import NaturalLanguage
import Translation

enum LanguageUtil {
    static let supported: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("fr", "Français"), ("ja", "日本語"), ("ko", "한국어"),
        ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский"), ("pt", "Português"), ("it", "Italiano"), ("ar", "العربية"),
    ]
    static func family(_ code: String) -> String { String(code.lowercased().split(separator: "-").first ?? "") }
    static func same(_ a: String, _ b: String) -> Bool { family(a) == family(b) }
    static func name(_ code: String) -> String { supported.first { $0.code == code }?.name ?? Locale.current.localizedString(forLanguageCode: code) ?? code }

    static func target(_ pref: String) -> String { pref.isEmpty ? systemTarget() : pref }

    /// Default translation target = the phone's first preferred language.
    static func systemTarget() -> String {
        let l = Locale.preferredLanguages.first ?? "zh-Hans"
        if l.hasPrefix("zh-Hant") || l.hasPrefix("zh-TW") || l.hasPrefix("zh-HK") || l.hasPrefix("zh-MO") { return "zh-Hant" }
        if l.hasPrefix("zh") { return "zh-Hans" }
        let f = family(l)
        return supported.contains { $0.code == f } ? f : "en"
    }

    /// On-device language identification (NaturalLanguage).
    static func detect(_ text: String) -> (code: String, confidence: Double)? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(1500)))
        guard let d = r.dominantLanguage, d != .undetermined else { return nil }
        return (d.rawValue, r.languageHypotheses(withMaximum: 1)[d] ?? 0)
    }
}

/// Bridges "translate these strings" to the system Translation framework (iOS 18+, on-device) via a SwiftUI host view.
@MainActor
final class TranslationCoordinator: ObservableObject {
    struct Job: Identifiable {
        let id = UUID()
        var texts: [String]
        var source: String?
        var target: String
        var done: ([String]?) -> Void
    }
    @Published var job: Job?
    var lastError = ""

    func run(texts: [String], source: String?, target: String) async -> [String]? {
        await withCheckedContinuation { (c: CheckedContinuation<[String]?, Never>) in
            let once = Once(c)
            job = Job(texts: texts, source: source, target: target, done: { once.resume($0) })
            lastError = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                if self?.job != nil { self?.lastError = "超时（没有收到系统的翻译回应）" }
                once.resume(nil)
                if self?.job != nil { self?.job = nil }
            }
        }
    }
}

@available(iOS 18.0, *)
struct TranslationHost: ViewModifier {
    @ObservedObject var coord: TranslationCoordinator
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: coord.job?.id) { _, id in
                guard id != nil, let j = coord.job else { return }
                let src = j.source.map { Locale.Language(identifier: $0) }
                let tgt = Locale.Language(identifier: j.target)
                if var c = config, c.source == src, c.target == tgt { c.invalidate(); config = c }
                else { config = TranslationSession.Configuration(source: src, target: tgt) }
            }
            .translationTask(config) { session in
                guard let j = await MainActor.run(body: { coord.job }) else { return }
                do {
                    let reqs = j.texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    let res = try await session.translations(from: reqs)
                    var out = j.texts
                    for r in res { if let i = r.clientIdentifier.flatMap({ Int($0) }), i < out.count { out[i] = r.targetText } }
                    await MainActor.run { j.done(out); coord.job = nil }
                } catch {
                    await MainActor.run { coord.lastError = error.localizedDescription; j.done(nil); coord.job = nil }
                }
            }
    }
}

extension View {
    @ViewBuilder func translationHost(_ coord: TranslationCoordinator) -> some View {
        if #available(iOS 18.0, *) { self.modifier(TranslationHost(coord: coord)) } else { self }
    }
}

/// Apple's on-device Translation framework only. The server AI is used solely when the user opted in (older iOS / unsupported pair).
@MainActor
final class Translator: ObservableObject {
    let coord = TranslationCoordinator()
    private let gateway: GatewayClient
    var allowAIFallback = false
    init(gateway: GatewayClient) { self.gateway = gateway }

    /// Cached per (target, text): a sentence is translated once, ever. Misses go to Apple's on-device model in one deduplicated batch.
    func translate(_ texts: [String], source: String?, target: String) async -> [String]? {
        let cache = TranslationCache.shared
        var out = texts
        var misses: [String: [Int]] = [:]
        for (i, t) in texts.enumerated() {
            if let c = cache.get(t, target) { out[i] = c } else { misses[t, default: []].append(i) }
        }
        if misses.isEmpty { return out }
        let uniq = Array(misses.keys)
        var got: [String]?
        if #available(iOS 18.0, *), let r = await coord.run(texts: uniq, source: source, target: target), r.count == uniq.count { got = r }
        if got == nil, allowAIFallback { got = try? await gateway.translateBatch(uniq, target: target) }   // page text never leaves the phone unless the user opted in
        guard let g = got, g.count == uniq.count else { return nil }
        cache.put(Array(zip(uniq, g)), target: target)
        for (u, t) in zip(uniq, g) { for i in misses[u] ?? [] { out[i] = t } }
        return out
    }
}
}


/// Translations survive restarts (and are shared by pages and the news screen), so a page or headline seen before appears translated at once.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()
    private var map: [String: String]
    private let file = JSONFile<[String: String]>("translation-cache.json")
    private var pending: Task<Void, Never>?
    private init() { map = file.load([:]) }

    func get(_ text: String, _ target: String) -> String? { map[target + "\u{1}" + text] }
    func put(_ pairs: [(String, String)], target: String) {
        for (a, b) in pairs where !b.isEmpty { map[target + "\u{1}" + a] = b }
        if map.count > 24_000 { for k in map.keys.prefix(6_000) { map[k] = nil } }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.file.save(self.map)
        }
    }
}
