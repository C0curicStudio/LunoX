import UIKit

/// What the browser presents to websites. The goal is a browser that is *consistent* and ordinary, not a disguised one.
enum SafariUA {
    /// WebKit's default user agent for an app (`... Mobile/15E148`) lacks the `Version/x` and `Safari/x` tokens that real Safari sends.
    /// To a bot-defence system that looks like an embedded web view, which is exactly the kind of client it distrusts. This is the exact
    /// string Safari itself sends on this OS (the OS token in it is frozen by Apple at 18_6 from iOS 26 on).
    static var version: String {
        let p = UIDevice.current.systemVersion.split(separator: ".").map(String.init)
        return "\(p.first ?? "18").\(p.count > 1 ? p[1] : "0")"
    }
    static var osToken: String {
        let p = UIDevice.current.systemVersion.split(separator: ".").compactMap { Int($0) }
        let major = p.first ?? 18, minor = p.count > 1 ? p[1] : 0
        return major >= 26 ? "18_6" : "\(major)_\(minor)"
    }
    static var mobile: String {
        UIDevice.current.userInterfaceIdiom == .phone
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Mobile/15E148 Safari/604.1"
            : desktop      // iPad Safari identifies as a Mac
    }
    static var desktop: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }
}

/// Per-platform behaviour of the page helpers. Only things that would otherwise get in the way of signing in or break the page.
extension SiteProfile {
    /// Sign-in, OAuth, captcha and verification pages: the page helpers stay out of the way completely.
    static func isLoginPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        let h = (url.host ?? "").lowercased(), p = url.path.lowercased()
        if ["login.", "accounts.", "passport.", "auth.", "sso.", "id.", "signin.", "oauth."].contains(where: { h.hasPrefix($0) }) { return true }
        return ["/login", "/signin", "/sign-in", "/sign_in", "/oauth", "/sso", "/passport", "/auth", "/captcha", "/verify", "/account/login", "/session"].contains { p.contains($0) }
    }
}

struct SiteProfile {
    var removeLoginPrompts = true      // the "forced login pop-up" remover: never on sites whose whole point is signing in
    var removeAppPrompts = true        // "open in app" banners
    var note = ""

    static func forGroup(_ id: String?) -> SiteProfile {
        switch id {
        case "ai":
            // AI chat sites open their own sign-in dialogs and "Continue with Google/Apple" flows; removing a "login wall" there looks like a broken
            // page to the user and an incomplete sign-in to the site.
            return SiteProfile(removeLoginPrompts: false, removeAppPrompts: true, note: "AI 站点：保留它自己的登录弹窗和第三方登录")
        case "pay":
            return SiteProfile(removeLoginPrompts: false, removeAppPrompts: false, note: "账号与支付：不改页面")
        default:
            return SiteProfile()
        }
    }
}

extension Router {
    func profile(for host: String?) -> SiteProfile {
        guard let host else { return SiteProfile() }
        return SiteProfile.forGroup(group(for: URLResolver.registrableDomain(host), host: host)?.id)
    }
}
