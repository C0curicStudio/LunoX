import SwiftUI
import WebKit
import AVKit

/// Reads the signed-in feed (X, Instagram) from a hidden page that uses the browser's own cookies and proxy route,
/// and hands the posts to native views. No private API, no tokens: if the site changes its markup the page simply opens as a web page.
@MainActor
final class SocialLoader: ObservableObject {
    enum State { case loading, ready, needsLogin, failed }
    @Published var posts: [TPost] = []
    @Published var state: State = .loading
    @Published var busy = false

    private let route: TemplateRoute
    private let dataStore: WKWebsiteDataStore
    private var web: WKWebView?
    private var running = true

    init(route: TemplateRoute, dataStore: WKWebsiteDataStore) { self.route = route; self.dataStore = dataStore }

    func stop() { running = false; web?.stopLoading(); web?.removeFromSuperview(); web = nil }

    private func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: CGRect(x: -3000, y: 0, width: 430, height: 1000), configuration: cfg)   // laid out like a phone, but off screen
        w.alpha = 0.02; w.isUserInteractionEnabled = false; w.isOpaque = false
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window?.insertSubview(w, at: 0)
        return w
    }

    func run() async {
        state = .loading; running = true
        let w = makeWeb(); web = w
        w.load(URLRequest(url: route.url))
        var stable = 0
        for _ in 0..<26 where running {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let r = await extract() else { continue }
            if r.login && r.posts.isEmpty { state = .needsLogin; if stable > 2 { return } ; stable += 1; continue }
            if !r.posts.isEmpty {
                let grew = r.posts.count != posts.count
                withAnimation(Motion.smooth) { posts = merge(posts, r.posts) }
                state = .ready
                stable = grew ? 0 : stable + 1
                if stable >= 3 || posts.count >= 12 { return }
            }
        }
        if posts.isEmpty && state != .needsLogin { state = .failed }
    }

    func loadMore() async {
        guard !busy, state == .ready, let w = web else { return }
        busy = true; defer { busy = false }
        _ = try? await w.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); 1")
        for _ in 0..<6 where running {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let r = await extract(), r.posts.count > posts.count { withAnimation(Motion.smooth) { posts = merge(posts, r.posts) }; return }
        }
    }

    private func merge(_ old: [TPost], _ new: [TPost]) -> [TPost] {
        var seen = Set(old.map(\.id)); var out = old
        for p in new where seen.insert(p.id).inserted { out.append(p) }
        return out
    }

    private func extract() async -> (posts: [TPost], login: Bool)? {
        guard let w = web else { return nil }
        let js = route.platform == .x ? Self.xJS : Self.igJS
        guard let s = (try? await w.evaluateJavaScript(js)) as? String, let d = s.data(using: .utf8) else { return nil }
        return await Task.detached { Self.parse(d) }.value
    }

    nonisolated static func parse(_ d: Data) -> (posts: [TPost], login: Bool)? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let login = (j["login"] as? Bool) ?? false
        let arr = (j["p"] as? [[String: Any]]) ?? []
        let posts: [TPost] = arr.compactMap { x in
            guard let id = x["id"] as? String, !id.isEmpty else { return nil }
            func str(_ k: String) -> String { (x[k] as? String) ?? "" }
            return TPost(id: id, name: str("name"), handle: str("handle"), avatar: str("avatar"), text: str("text"),
                         images: ((x["images"] as? [String]) ?? []).filter { $0.hasPrefix("http") }, poster: str("poster"), video: str("video"), time: str("time"),
                         replies: str("replies"), reposts: str("reposts"), likes: str("likes"), url: str("url"))
        }
        return (posts, login)
    }

    // The two extractors read what a reader sees (articles, avatars, pictures, counts). Selectors are the sites' stable test hooks / semantic tags.
    static let xJS = #"""
    (function(){var out=[];
      document.querySelectorAll('article[data-testid="tweet"]').forEach(function(a){try{
        var t=a.querySelector('[data-testid="tweetText"]'), un=a.querySelector('[data-testid="User-Name"]');
        var names=un?un.innerText.split('\n').filter(Boolean):[];
        var handle='';names.forEach(function(x){if(!handle&&x.charAt(0)==='@')handle=x;});
        var te=a.querySelector('time'), link=te&&te.closest('a'), href=link?link.getAttribute('href'):'';
        var m=href.match(/status\/(\d+)/); if(!m)return;
        var av=a.querySelector('[data-testid="Tweet-User-Avatar"] img');
        var imgs=[].map.call(a.querySelectorAll('[data-testid="tweetPhoto"] img'),function(i){return i.src.replace(/name=\w+/,'name=large');});
        var v=a.querySelector('video');
        function c(id){var e=a.querySelector('[data-testid="'+id+'"]');return e?(e.innerText||'').trim():'';}
        out.push({id:m[1],name:names[0]||'',handle:handle,avatar:av?av.src:'',text:t?t.innerText:'',images:imgs,poster:v?(v.poster||''):'',video:'',
          time:te?te.getAttribute('datetime'):'',replies:c('reply'),reposts:c('retweet'),likes:c('like'),url:'https://x.com'+href});
      }catch(e){}});
      var login=!!document.querySelector('[data-testid="loginButton"],a[href="/login"],input[autocomplete="username"]')||/\/(login|i\/flow)/.test(location.pathname);
      return JSON.stringify({p:out,login:login});})()
    """#

    static let igJS = #"""
    (function(){var out=[],seen={};
      document.querySelectorAll('article').forEach(function(a){try{
        var pl=a.querySelector('a[href*="/p/"],a[href*="/reel/"]'); if(!pl)return;
        var m=(pl.getAttribute('href')||'').match(/\/(p|reel)\/([^\/?]+)/); if(!m||seen[m[2]])return; seen[m[2]]=1;
        var hdr=a.querySelector('header'), un=hdr&&hdr.querySelector('a[href^="/"]'), handle=un?(un.getAttribute('href')||'').replace(/\//g,''):'';
        var av=hdr&&hdr.querySelector('img');
        var imgs=[].filter.call(a.querySelectorAll('img'),function(i){return i!==av&&(i.naturalWidth||i.width)>150;}).map(function(i){return i.currentSrc||i.src;});
        var v=a.querySelector('video'), te=a.querySelector('time'), cap=a.querySelector('h1')||a.querySelector('span[dir="auto"]');
        out.push({id:m[2],name:handle,handle:handle?'@'+handle:'',avatar:av?av.src:'',text:cap?cap.innerText:'',images:imgs.slice(0,1),poster:v?(v.poster||''):'',video:'',
          time:te?te.getAttribute('datetime'):'',replies:'',reposts:'',likes:'',url:'https://www.instagram.com'+pl.getAttribute('href')});
      }catch(e){}});
      if(!out.length){document.querySelectorAll('a[href*="/p/"],a[href*="/reel/"]').forEach(function(l){var i=l.querySelector('img'),m=(l.getAttribute('href')||'').match(/\/(p|reel)\/([^\/?]+)/);
        if(i&&m&&!seen[m[2]]){seen[m[2]]=1;out.push({id:m[2],name:'',handle:'',avatar:'',text:i.alt||'',images:[i.currentSrc||i.src],poster:'',video:'',time:'',replies:'',reposts:'',likes:'',url:'https://www.instagram.com'+l.getAttribute('href')});}});}
      var login=!!document.querySelector('input[name="username"],input[name="password"]')||/\/accounts\/login/.test(location.pathname);
      return JSON.stringify({p:out,login:login&&!out.length});})()
    """#
}

// MARK: - views

struct SocialTemplateView: View {
    @ObservedObject var tab: Tab
    let route: TemplateRoute
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @State private var loader: SocialLoader?

    var body: some View {
        Group {
            if case .watch(let id) = route.kind { TweetView(tab: tab, route: route, id: id) }
            else if let l = loader { SocialFeed(tab: tab, route: route, loader: l) }
            else { theme.background }
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: route.url) {
            guard case .feed = route.kind else { return }
            let l = SocialLoader(route: route, dataStore: store.dataStore(isPrivate: tab.isPrivate)); loader = l
            tab.title = route.platform.name
            await l.run()
        }
        .onDisappear { loader?.stop() }
    }
}

private struct SocialFeed: View {
    @ObservedObject var tab: Tab
    let route: TemplateRoute
    @ObservedObject var loader: SocialLoader
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme

    private var title: String {
        if case .feed(let q) = route.kind, let q { return q }
        return route.platform == .x ? "主页" : "Instagram"
    }
    private var gridMode: Bool { loader.posts.count > 0 && loader.posts.allSatisfy { $0.handle.isEmpty } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: route.platform.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(route.platform.tint)
                    Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(1)
                    Spacer()
                    Button { Haptics.tap(); tab.navigate(route.url, forceWeb: true) } label: {
                        Label("原网页", systemImage: "safari").font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12).frame(height: 32).background(theme.surface, in: Capsule()).foregroundStyle(theme.accent)
                    }.buttonStyle(PressableStyle(scale: 0.92))
                }.padding(.bottom, 14)

                switch loader.state {
                case .needsLogin: loginCard
                case .failed: failureCard
                default:
                    if loader.posts.isEmpty { skeleton }
                    else if gridMode { grid }
                    else {
                        ForEach(Array(loader.posts.enumerated()), id: \.element.id) { i, p in
                            PostCard(post: p, platform: route.platform, index: i) { open(p) }
                                .onAppear { if i >= loader.posts.count - 3 { Task { await loader.loadMore() } } }
                        }
                        if loader.busy { ProgressView().frame(maxWidth: .infinity).padding(20) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 58).padding(.bottom, 150)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 28).onChanged { g in
            if abs(g.translation.height) > abs(g.translation.width) { store.setBars(collapsed: g.translation.height < 0) }
        })
        .refreshable { await loader.run() }
    }

    private func open(_ p: TPost) {
        guard let u = URL(string: p.url) else { return }
        Haptics.soft()
        tab.navigate(u, forceWeb: route.platform != .x)      // X posts have a native detail page; Instagram posts open on the web
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(loader.posts) { p in
                Button { open(p) } label: {
                    RemoteImage(url: p.images.first).aspectRatio(1, contentMode: .fill).frame(minHeight: 0).clipped()
                }.buttonStyle(PressableStyle(scale: 0.96))
                .onAppear { if p.id == loader.posts.last?.id { Task { await loader.loadMore() } } }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var skeleton: some View {
        VStack(spacing: 22) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(theme.surface).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5).fill(theme.surface).frame(width: 140, height: 13)
                        RoundedRectangle(cornerRadius: 5).fill(theme.surface).frame(height: 13)
                        RoundedRectangle(cornerRadius: 16).fill(theme.surface).frame(height: 190)
                    }
                }
            }
        }.phaseAnimator([0.45, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
    }

    private var loginCard: some View {
        VStack(spacing: 14) {
            Image(systemName: route.platform.icon).font(.system(size: 38)).foregroundStyle(route.platform.tint)
            Text("登录 \(route.platform.name) 后显示原生界面").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
            Text("登录只在这台手机的浏览器里进行，账号密码不会经过任何其他地方。登录完成后自动切换到原生界面。")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft).multilineTextAlignment(.center)
            Button {
                Haptics.soft(); tab.pendingNative = true; tab.navigate(route.platform.loginURL, forceWeb: true)
            } label: { Text("登录").font(.system(size: 16, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity).frame(height: 46) }
                .buttonStyle(.borderedProminent).tint(route.platform.tint)
        }.padding(22).frame(maxWidth: .infinity).background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous)).padding(.top, 30)
    }

    private var failureCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.bubble").font(.system(size: 34, weight: .light)).foregroundStyle(theme.inkSoft)
            Text("没能读取到内容").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(theme.ink)
            HStack(spacing: 10) {
                Button("重试") { Task { await loader.run() } }.buttonStyle(.borderedProminent).tint(theme.accent)
                Button("打开原网页") { tab.navigate(route.url, forceWeb: true) }.buttonStyle(.bordered).tint(theme.accent)
            }
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }
}

struct PostCard: View {
    let post: TPost
    let platform: SitePlatform
    let index: Int
    let tap: () -> Void
    @State private var on = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: post.avatar.isEmpty ? nil : post.avatar).frame(width: 42, height: 42).clipShape(Circle())
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text(post.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.ink).lineLimit(1)
                        Text([post.handle, Self.ago(post.time)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft).lineLimit(1)
                    }
                    if !post.text.isEmpty { Text(post.text).font(.system(size: 15, design: .rounded)).foregroundStyle(theme.ink).multilineTextAlignment(.leading).lineLimit(12) }
                    media
                    if !(post.replies + post.reposts + post.likes).isEmpty {
                        HStack(spacing: 22) {
                            stat("bubble.left", post.replies); stat("arrow.2.squarepath", post.reposts); stat("heart", post.likes)
                        }.padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 14).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(theme.inkSoft.opacity(0.15)).frame(height: 0.5) }
        }.buttonStyle(PressableStyle(scale: 0.985)).staggered(index, on).onAppear { on = true }
    }

    @ViewBuilder private var media: some View {
        if !post.poster.isEmpty {
            ZStack {
                RemoteImage(url: post.poster).aspectRatio(16.0 / 10.0, contentMode: .fill)
                Image(systemName: "play.fill").font(.system(size: 22)).foregroundStyle(.white).frame(width: 54, height: 54).background(.black.opacity(0.55), in: Circle())
            }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if post.images.count == 1 {
            RemoteImage(url: post.images[0]).aspectRatio(platform == .instagram ? 4.0 / 5.0 : 16.0 / 10.0, contentMode: .fill)
                .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if post.images.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                ForEach(Array(post.images.prefix(4).enumerated()), id: \.offset) { _, u in RemoteImage(url: u).aspectRatio(1, contentMode: .fill).clipped() }
            }.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func stat(_ icon: String, _ v: String) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 13)); Text(v).font(.system(size: 12, design: .rounded)) }.foregroundStyle(theme.inkSoft)
    }

    static func ago(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }; if s < 3600 { return "\(s / 60)分钟" }; if s < 86400 { return "\(s / 3600)小时" }
        if s < 86400 * 30 { return "\(s / 86400)天" }
        let df = DateFormatter(); df.dateFormat = "M月d日"; return df.string(from: d)
    }
}

/// One public post on X: loaded through X's embed endpoint, so it needs no sign-in. Photos and video play natively.
private struct TweetView: View {
    @ObservedObject var tab: Tab
    let route: TemplateRoute
    let id: String
    @EnvironmentObject var store: BrowserStore
    @Environment(\.theme) private var theme
    @State private var post: TPost?
    @State private var failed = false
    @State private var player: AVPlayer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "text.bubble.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(SitePlatform.x.tint)
                    Text("帖子").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
                    Spacer()
                    Button { Haptics.tap(); tab.navigate(route.url, forceWeb: true) } label: {
                        Label("原网页", systemImage: "safari").font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12).frame(height: 32).background(theme.surface, in: Capsule()).foregroundStyle(theme.accent)
                    }.buttonStyle(PressableStyle(scale: 0.92))
                }
                if let p = post {
                    HStack(spacing: 12) {
                        RemoteImage(url: p.avatar).frame(width: 48, height: 48).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(theme.ink)
                            Text(p.handle).font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft)
                        }
                    }
                    Text(p.text).font(.system(size: 18, design: .rounded)).foregroundStyle(theme.ink).textSelection(.enabled)
                    if let player { VideoPlayer(player: player).aspectRatio(16.0 / 9.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
                    else if !p.poster.isEmpty { RemoteImage(url: p.poster).aspectRatio(16.0 / 9.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
                    ForEach(p.images, id: \.self) { u in RemoteImage(url: u).aspectRatio(4.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
                    HStack(spacing: 22) {
                        Label(p.likes, systemImage: "heart"); Label(p.replies, systemImage: "bubble.left")
                    }.font(.system(size: 13, design: .rounded)).foregroundStyle(theme.inkSoft)
                } else if failed {
                    Text("这条帖子无法读取（可能已删除或需要登录）").foregroundStyle(theme.inkSoft).padding(.top, 40)
                    Button("打开原网页") { tab.navigate(route.url, forceWeb: true) }.buttonStyle(.borderedProminent).tint(theme.accent)
                } else { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
            }.padding(.horizontal, 16).padding(.top, 58).padding(.bottom, 150)
        }
        .task(id: id) {
            if let p = await store.templates.tweet(id: id) {
                withAnimation(Motion.smooth) { post = p }
                tab.title = "\(p.name)：\(p.text.prefix(40))"
                if let first = p.images.first ?? (p.poster.isEmpty ? nil : p.poster) { tab.templateReady(thumb: first) }
                if let v = URL(string: p.video), !p.video.isEmpty { let pl = AVPlayer(url: v); player = pl }
            } else { failed = true }
        }
        .onDisappear { player?.pause() }
    }
}
