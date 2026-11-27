import SwiftUI
import WebKit

struct ReaderView: View {
    @ObservedObject var tab: Tab
    @Environment(\.theme) private var theme
    @State private var content: (title: String, html: String)?
    @State private var loading = true
    @State private var size = 19.0

    var body: some View {
        Group {
            if let c = content { ReaderWeb(html: page(c), dark: theme.scheme == .dark).ignoresSafeArea(edges: .bottom) }
            else if loading { ProgressView() }
            else { ContentUnavailableView("无法提取正文", systemImage: "text.page.slash", description: Text("这个页面不像一篇文章。")) }
        }
        .navigationTitle("阅读模式").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup { Button { size = max(14, size - 1) } label: { Image(systemName: "textformat.size.smaller") }; Button { size = min(30, size + 1) } label: { Image(systemName: "textformat.size.larger") } } }
        .task { content = await tab.readerContent(); loading = false }
    }

    private func page(_ c: (title: String, html: String)) -> String {
        let t = c.title.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <meta name=viewport content="width=device-width,initial-scale=1"><style>
        :root{color-scheme:light dark}body{font:\(Int(size))px/1.75 ui-serif,'New York',Georgia,serif;margin:0;padding:24px 22px 120px;max-width:680px;margin:auto;background:Canvas;color:CanvasText}
        h1{font:700 \(Int(size) + 9)px/1.25 -apple-system,system-ui;margin:12px 0 24px}img{max-width:100%;height:auto;border-radius:12px}a{color:#4F63FF}pre{overflow:auto;background:#8882;padding:12px;border-radius:10px}blockquote{margin:0;padding-left:16px;border-left:3px solid #8886;opacity:.85}
        </style><h1>\(t)</h1>\(c.html)
        """
    }
}

struct ReaderWeb: UIViewRepresentable {
    let html: String
    let dark: Bool
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false      // extracted content is sanitised AND script-less
        cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false; w.backgroundColor = .clear
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {
        w.overrideUserInterfaceStyle = dark ? .dark : .light
        w.loadHTMLString(html, baseURL: nil)
    }
}
