import XCTest
import UIKit
@testable import LunoX

final class URLResolverTests: XCTestCase {
    let g = SearchEngine.all[0]
    func testAddressBarInput() {
        XCTAssertEqual(URLResolver.resolve("example.com", engine: g)?.absoluteString, "https://example.com")
        XCTAssertEqual(URLResolver.resolve("https://a.com/x?y=1", engine: g)?.absoluteString, "https://a.com/x?y=1")
        XCTAssertEqual(URLResolver.resolve("localhost:3000", engine: g)?.absoluteString, "http://localhost:3000")
        XCTAssertTrue(URLResolver.resolve("法语 怎么说 你好", engine: g)!.absoluteString.hasPrefix("https://www.google.com/search?q="))
        XCTAssertTrue(URLResolver.resolve("a&b=c d", engine: g)!.absoluteString.contains("a%26b%3Dc%20d"))
    }
    func testDangerousSchemesBecomeSearches() {
        for s in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<script>1</script>", "blob:https://x/1"] {
            let u = URLResolver.resolve(s, engine: g)!
            XCTAssertEqual(u.host, "www.google.com", s)
        }
        XCTAssertNil(URLResolver.resolve("   ", engine: g))
    }
    func testRegistrableDomain() {
        XCTAssertEqual(URLResolver.registrableDomain("www.google.com"), "google.com")
        XCTAssertEqual(URLResolver.registrableDomain("a.b.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(URLResolver.registrableDomain("localhost"), "localhost")
    }
}

final class PinningTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Pinning.normalize("AB:cd:EF"), "abcdef")
        XCTAssertEqual(Pinning.normalize("zz xx").count, 0)
        XCTAssertEqual(Pinning.normalize(String(repeating: "A1", count: 32)).count, 64)
    }
}

@MainActor
final class ExtensionTests: XCTestCase {
    func testUserScriptHeader() {
        let src = """
        // ==UserScript==
        // @name  Hello World
        // @version 2.1
        // @match https://*.example.com/*
        // @exclude https://example.com/private/*
        // @run-at document-start
        // ==/UserScript==
        console.log('hi')
        """
        let e = ExtensionManager.parseUserScript(src)
        XCTAssertEqual(e.name, "Hello World"); XCTAssertEqual(e.version, "2.1")
        XCTAssertEqual(e.matches, ["https://*.example.com/*"]); XCTAssertEqual(e.excludes, ["https://example.com/private/*"])
        XCTAssertTrue(e.runAtStart)
    }
    func testWrapperEmbedsEscapedData() {
        let e = UserExtension(id: "x", name: "a\"b", matches: ["*://*/*"], js: "var a=1;", css: "body{color:red}")
        let w = ExtensionManager.wrap(e)
        XCTAssertTrue(w.contains("var a=1;")); XCTAssertTrue(w.contains("\"a\\\"b\"")); XCTAssertTrue(w.contains("body{color:red}"))
    }
}

@MainActor
final class ThemeTests: XCTestCase {
    func testThemesHaveUniqueIDs() { XCTAssertEqual(Set(ThemeFamily.all.map(\.id)).count, ThemeFamily.all.count) }
    func testEveryFamilyHasLightAndDark() {
        for f in ThemeFamily.all { XCTAssertEqual(f.light.scheme, .light, f.id); XCTAssertEqual(f.dark.scheme, .dark, f.id); XCTAssertEqual(f.resolve(.dark).id, f.id) }
    }
    func testParseColor() {
        XCTAssertNotNil(Tab.parseColor("#fff")); XCTAssertNotNil(Tab.parseColor("rgb(10, 20, 30)"))
        XCTAssertNil(Tab.parseColor("rgba(0, 0, 0, 0)")); XCTAssertNil(Tab.parseColor("transparent"))
    }
}

@MainActor
final class RouterTests: XCTestCase {
    func testCompanionDomainsCoverMainSite() {
        XCTAssertTrue(Router.companions["youtube.com"]!.contains("googlevideo.com"))
    }
    func testProbeUnreachableHostIsBlocked() async {
        let r = await Router.probeDirect(host: "no-such-host.invalid")
        XCTAssertFalse(r.ok)
    }
    func testPolicyGroups() {
        let s = Settings(); s.prefs.groupModes = [:]; s.prefs.groupDomains = [:]
        let r = Router(settings: s)
        XCTAssertEqual(r.policyMode("kimi.ai", host: "platform.kimi.ai"), .direct)       // domestic: never abroad
        XCTAssertEqual(r.policyMode("example.cn", host: "www.example.cn"), .direct)
        XCTAssertEqual(r.policyMode("paypal.com", host: "www.paypal.com"), .direct)       // payment: never abroad
        XCTAssertEqual(r.policyMode("google.com", host: "www.google.com"), .proxy)
        XCTAssertEqual(r.policyMode("openai.com", host: "chat.openai.com"), .proxy)
        XCTAssertNil(r.policyMode("github.com", host: "github.com"))                       // auto group
        XCTAssertNil(r.policyMode("unknown-site.org", host: "unknown-site.org"))
        s.prefs.groupDomains["social"] = ["my-site.com"]
        XCTAssertEqual(r.policyMode("my-site.com", host: "my-site.com"), .proxy)           // user added
        s.prefs.groupModes["cn"] = "auto"
        XCTAssertNil(r.policyMode("kimi.ai", host: "kimi.ai"))                             // user switched the group to auto
    }
    func testSetupLink() {
        let s = Settings()
        let pin = String(repeating: "ab", count: 32)
        XCTAssertTrue(s.applySetupLink(URL(string: "lunox://setup?host=1.2.3.4&port=9443&key=k&pin=\(pin)&edge=edge.example.com")!))
        XCTAssertEqual(s.prefs.gatewayPort, 9443); XCTAssertEqual(s.prefs.edgeHost, "edge.example.com")
        XCTAssertFalse(s.applySetupLink(URL(string: "lunox://setup?host=bad host&key=k&pin=\(pin)")!))
        XCTAssertFalse(s.applySetupLink(URL(string: "lunox://setup?host=1.2.3.4&key=k&pin=short")!))
    }
}

final class LanguageTests: XCTestCase {
    func testFamilyAndSame() {
        XCTAssertTrue(LanguageUtil.same("zh-Hans", "zh-Hant")); XCTAssertTrue(LanguageUtil.same("en-US", "en"))
        XCTAssertFalse(LanguageUtil.same("fr", "en"))
    }
    func testDetectsLanguages() {
        XCTAssertEqual(LanguageUtil.detect("The quick brown fox jumps over the lazy dog and keeps running through the forest.")?.code, "en")
        XCTAssertEqual(LanguageUtil.detect("Le renard brun rapide saute par-dessus le chien paresseux et court dans la forêt.")?.code, "fr")
        XCTAssertEqual(LanguageUtil.detect("今天天气很好，我们一起去公园散步，然后在附近的餐厅吃午饭。")?.code, "zh-Hans")
    }
    func testNamesAndTarget() {
        XCTAssertEqual(LanguageUtil.name("fr"), "Français")
        XCTAssertTrue(LanguageUtil.supported.contains { $0.code == LanguageUtil.systemTarget() })
    }
}

final class TemplateTests: XCTestCase {
    func testRoutes() {
        func k(_ s: String) -> TemplateKind? { TemplateRoute.match(URL(string: s)!)?.kind }
        XCTAssertEqual(k("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .watch(id: "dQw4w9WgXcQ"))
        XCTAssertEqual(k("https://youtu.be/dQw4w9WgXcQ"), .watch(id: "dQw4w9WgXcQ"))
        XCTAssertEqual(k("https://m.youtube.com/results?search_query=swift"), .feed(query: "swift"))
        XCTAssertEqual(k("https://youtube.com"), .feed(query: nil))
        XCTAssertEqual(k("https://www.bilibili.com/video/BV1nz4y1N7NZ/"), .watch(id: "BV1nz4y1N7NZ"))
        XCTAssertEqual(k("https://search.bilibili.com/all?keyword=swift"), .feed(query: "swift"))
        XCTAssertNil(k("https://www.youtube.com/@channel"))
        XCTAssertNil(k("https://example.com/watch?v=dQw4w9WgXcQ"))
    }
    func testSocialRoutes() {
        func r(_ s: String) -> TemplateRoute? { TemplateRoute.match(URL(string: s)!) }
        XCTAssertEqual(r("https://x.com/NASA/status/1234567890")?.kind, .watch(id: "1234567890"))
        XCTAssertEqual(r("https://x.com/home")?.kind, .feed(query: nil))
        XCTAssertEqual(r("https://twitter.com/NASA")?.kind, .feed(query: "@NASA"))
        XCTAssertEqual(r("https://x.com/search?q=swift")?.kind, .feed(query: "swift"))
        XCTAssertNil(r("https://x.com/settings"))
        XCTAssertEqual(r("https://www.instagram.com/")?.platform, .instagram)
        XCTAssertEqual(r("https://www.instagram.com/nasa/")?.kind, .feed(query: "@nasa"))
        XCTAssertEqual(r("https://www.instagram.com/p/ABC123/")?.kind, .feed(query: "帖子"))
        XCTAssertNil(r("https://www.instagram.com/accounts/login/"))
    }
    func testSocialParse() {
        let js = #"{"p":[{"id":"1","name":"A","handle":"@a","avatar":"https://x/a.jpg","text":"hi","images":["https://x/1.jpg","bad"],"poster":"","video":"","time":"2026-01-01T00:00:00.000Z","replies":"1","reposts":"2","likes":"3","url":"https://x.com/a/status/1"}],"login":false}"#.data(using: .utf8)!
        let r = SocialLoader.parse(js)
        XCTAssertEqual(r?.posts.count, 1); XCTAssertEqual(r?.posts.first?.images, ["https://x/1.jpg"]); XCTAssertEqual(r?.login, false)
        let t = #"{"id_str":"9","text":"hello","user":{"name":"N","screen_name":"n","profile_image_url_https":"https://p/n.jpg"},"favorite_count":12000,"mediaDetails":[{"type":"video","media_url_https":"https://p/poster.jpg","video_info":{"variants":[{"content_type":"video/mp4","bitrate":256000,"url":"https://v/lo.mp4"},{"content_type":"video/mp4","bitrate":832000,"url":"https://v/hi.mp4"}]}}]}"#.data(using: .utf8)!
        let p = SiteParse.syndicationTweet(t)
        XCTAssertEqual(p?.video, "https://v/hi.mp4"); XCTAssertEqual(p?.handle, "@n"); XCTAssertEqual(p?.likes, "1.2万")
    }
    func testYouTubeParse() {
        let html = #"<script>var ytInitialData = {"contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Hello"}]},"lengthText":{"simpleText":"1:02"},"viewCountText":{"simpleText":"5 views"},"ownerText":{"runs":[{"text":"Me"}]}}}]};</script>"#
        let items = SiteParse.youtubeVideos(SiteParse.ytInitialData(html))
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].title, "Hello"); XCTAssertEqual(items[0].duration, "1:02"); XCTAssertEqual(items[0].author, "Me")
    }
    func testBilibiliAndPipedParse() {
        let b = #"{"code":0,"data":{"result":[{"bvid":"BV1","title":"<em class=\"keyword\">swift</em> 入门","pic":"//i0.hdslb.com/a.jpg","author":"A","duration":"3:20","play":12345,"danmaku":7}]}}"#.data(using: .utf8)!
        let bi = SiteParse.bilibiliList(b)
        XCTAssertEqual(bi.first?.title, "swift 入门"); XCTAssertEqual(bi.first?.thumb, "https://i0.hdslb.com/a.jpg"); XCTAssertTrue(bi.first?.meta.contains("1.2万") == true)
        let p = try? JSONSerialization.jsonObject(with: #"[{"type":"stream","url":"/watch?v=DxgDeW-gIcU","title":"T","uploaderName":"U","duration":125,"views":1500}]"#.data(using: .utf8)!)
        XCTAssertEqual(SiteParse.pipedItems(p).first?.id, "DxgDeW-gIcU"); XCTAssertEqual(SiteParse.pipedItems(p).first?.duration, "2:05")
    }
    func testSafariUserAgentLooksLikeSafari() {
        let m = SafariUA.mobile, d = SafariUA.desktop
        XCTAssertTrue(d.contains("Version/") && d.hasSuffix("Safari/605.1.15"))
        if UIDevice.current.userInterfaceIdiom == .phone { XCTAssertTrue(m.contains("Mobile/15E148 Safari/604.1")); XCTAssertTrue(m.contains("Version/")) }
    }
    func testSiteProfiles() {
        XCTAssertFalse(SiteProfile.forGroup("ai").removeLoginPrompts)
        XCTAssertFalse(SiteProfile.forGroup("pay").removeAppPrompts)
        XCTAssertTrue(SiteProfile.forGroup(nil).removeLoginPrompts)
    }
    func testTrackingParams() {
        let u = URL(string: "https://example.com/a?id=5&utm_source=x&fbclid=abc&q=hi")!
        XCTAssertEqual(TrackingParams.clean(u)?.absoluteString, "https://example.com/a?id=5&q=hi")
        XCTAssertEqual(TrackingParams.clean(URL(string: "https://example.com/?utm_medium=a")!)?.absoluteString, "https://example.com/")
        XCTAssertNil(TrackingParams.clean(URL(string: "https://example.com/a?id=5")!))
        XCTAssertNil(TrackingParams.clean(URL(string: "https://example.com/a")!))
    }
    func testSiteSettingDecodesOldFiles() throws {
        let old = #"{"desktop":true,"javascript":true,"forceProxy":false}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(SiteSetting.self, from: old)
        XCTAssertTrue(s.desktop); XCTAssertFalse(s.fingerprintLoose); XCTAssertFalse(s.allowNags)
    }
    func testFingerprintScriptHasNoPlaceholders() {
        let src = FingerprintGuard.userScript(skip: ["example.com"]).source
        XCTAssertFalse(src.contains("SECRET")); XCTAssertFalse(src.contains("[LIST]")); XCTAssertTrue(src.contains("example.com")); XCTAssertTrue(src.contains(FingerprintGuard.messageName))
    }
    func testPrefsSurviveNewKeys() {
        struct Old: Codable { var a = 1 }
        struct New: Codable { var a = 1; var b = 9 }
        let d = try! JSONEncoder().encode(Old(a: 5))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-test-\(UUID().uuidString)")
        try! d.write(to: f)
        let base = (try! JSONSerialization.jsonObject(with: JSONEncoder().encode(New()))) as! [String: Any]
        let old = (try! JSONSerialization.jsonObject(with: Data(contentsOf: f))) as! [String: Any]
        let merged = try! JSONSerialization.data(withJSONObject: base.merging(old) { _, s in s })
        let v = try! JSONDecoder().decode(New.self, from: merged)
        XCTAssertEqual(v.a, 5); XCTAssertEqual(v.b, 9)
    }
}
