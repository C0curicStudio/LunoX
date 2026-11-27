import Foundation
import WebKit

struct DownloadItem: Identifiable {
    let id = UUID()
    var name: String
    var progress: Double = 0
    var fileURL: URL?
    var failed = false
    var done = false
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published var items: [DownloadItem] = []
    private var map: [ObjectIdentifier: UUID] = [:]
    private var obs: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func attach(_ d: WKDownload) {
        d.delegate = self
        let item = DownloadItem(name: d.originalRequest?.url?.lastPathComponent ?? "下载")
        items.insert(item, at: 0)
        let key = ObjectIdentifier(d)
        map[key] = item.id
        obs[key] = d.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let v = p.fractionCompleted
            Task { @MainActor in self?.update(key) { $0.progress = v } }
        }
    }

    private func update(_ k: ObjectIdentifier, _ f: (inout DownloadItem) -> Void) {
        guard let id = map[k], let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let safe = suggestedFilename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let base = (safe.isEmpty ? "download" : safe) as NSString
        var dest = Paths.downloads.appendingPathComponent(base as String)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = Paths.downloads.appendingPathComponent("\(base.deletingPathExtension) (\(n))" + (base.pathExtension.isEmpty ? "" : ".\(base.pathExtension)")); n += 1
        }
        let key = ObjectIdentifier(download)
        let final = dest
        Task { @MainActor in self.update(key) { $0.name = final.lastPathComponent; $0.fileURL = final } }
        completionHandler(dest)
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        Task { @MainActor in
            self.update(key) { $0.done = true; $0.progress = 1 }
            self.obs[key] = nil; Haptics.ok()
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        Task { @MainActor in self.update(key) { $0.failed = true }; self.obs[key] = nil }
    }

    func remove(_ item: DownloadItem) {
        if let u = item.fileURL { try? FileManager.default.removeItem(at: u) }
        items.removeAll { $0.id == item.id }
    }
}
