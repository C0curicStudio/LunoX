import Foundation
import WebKit

struct CachedPage: Codable, Identifiable, Hashable {
    var id: String            // sha256(url)
    var url: String
    var title: String
    var date: Date
    var size: Int
}

/// Stores WebKit web-archives of visited pages so they can be reopened without a network.
@MainActor
final class OfflineCache: ObservableObject {
    private let dir = Paths.dir("OfflinePages", excludeFromBackup: true)
    private let index = JSONFile<[CachedPage]>("offline-index.json")
    @Published private(set) var pages: [CachedPage]
    private var lastSaved: [String: Date] = [:]
    var limitBytes: Int = 300 * 1024 * 1024

    init() { pages = index.load([]).sorted { $0.date > $1.date } }

    static func key(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false); c?.fragment = nil
        return (c?.url?.absoluteString ?? url.absoluteString).sha256Hex
    }

    func has(_ url: URL) -> Bool { pages.contains { $0.id == Self.key(url) } }

    func save(url: URL, title: String, from webView: WKWebView) {
        let k = Self.key(url)
        if let t = lastSaved[k], Date().timeIntervalSince(t) < 300 { return }
        lastSaved[k] = Date()
        webView.createWebArchiveData { [weak self] result in
            guard let self, case .success(let data) = result, data.count < 12_000_000 else { return }
            Task { @MainActor in self.store(k, url: url, title: title, data: data) }
        }
    }

    private func store(_ k: String, url: URL, title: String, data: Data) {
        let f = dir.appendingPathComponent(k)
        DispatchQueue.global(qos: .utility).async { try? data.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        pages.removeAll { $0.id == k }
        pages.insert(CachedPage(id: k, url: url.absoluteString, title: title.isEmpty ? url.displayHost : title, date: Date(), size: data.count), at: 0)
        trim()
        index.save(pages)
    }

    func data(for url: URL) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(Self.key(url)))
    }

    func remove(_ p: CachedPage) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(p.id))
        pages.removeAll { $0.id == p.id }; index.save(pages)
    }

    func clear() {
        pages.forEach { try? FileManager.default.removeItem(at: dir.appendingPathComponent($0.id)) }
        pages = []; index.save(pages)
    }

    var totalBytes: Int { pages.reduce(0) { $0 + $1.size } }

    private func trim() {
        while totalBytes > limitBytes, let last = pages.last { remove(last) }
    }
}
