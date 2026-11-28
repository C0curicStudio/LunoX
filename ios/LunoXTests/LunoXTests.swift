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
    func testQuestionIntent() {
        XCTAssertTrue(QuestionIntent.isQuestion("怎么给 SwiftUI 的 List 加下拉刷新"))
        XCTAssertTrue(QuestionIntent.isQuestion("为什么天空是蓝色的"))
        XCTAssertTrue(QuestionIntent.isQuestion("how do I center a div in css"))
        XCTAssertTrue(QuestionIntent.isQuestion("法语的过去时怎么用？"))
        XCTAssertTrue(QuestionIntent.isQuestion("打开 SwiftUI 官方文档"))
        XCTAssertTrue(QuestionIntent.wantsNavigation("打开 SwiftUI 官方文档"))
        XCTAssertFalse(QuestionIntent.isQuestion("swift 教程"))                   // keywords stay a search
        XCTAssertFalse(QuestionIntent.isQuestion("youtube"))                      // site name: direct
        XCTAssertFalse(QuestionIntent.isQuestion("example.com/path"))
        XCTAssertFalse(QuestionIntent.isQuestion("iphone 17"))
        XCTAssertTrue(QuestionIntent.refersToPage("总结一下这个页面"))
        XCTAssertFalse(QuestionIntent.refersToPage("今天天气"))
    }
    func testSmartSearch() {
        XCTAssertEqual(SmartSearch.resolve("youtube")?.url.host, "www.youtube.com")
        XCTAssertEqual(SmartSearch.resolve("YouTube")?.isSearch, false)
        let b = SmartSearch.resolve("b站 swift教程")
        XCTAssertEqual(b?.url.host, "search.bilibili.com"); XCTAssertEqual(b?.query, "swift教程"); XCTAssertEqual(b?.isSearch, true)
        XCTAssertEqual(SmartSearch.resolve("淘宝手机壳")?.query, "手机壳")
        XCTAssertEqual(SmartSearch.resolve("github swift package")?.url.host, "github.com")
        XCTAssertEqual(SmartSearch.resolve("知乎官网")?.url.host, "www.zhihu.com")
        XCTAssertEqual(SmartSearch.resolve("larousse bonjour")?.url.host, "www.larousse.fr")
        XCTAssertNil(SmartSearch.resolve("apple pie recipe"))                 // brand that is also a word: exact name only
        XCTAssertNil(SmartSearch.resolve("how to cancel youtube premium"))     // the site name is not the first word
        XCTAssertNil(SmartSearch.resolve("weather today"))
        XCTAssertNil(SmartSearch.resolve("site:youtube.com cats"))
        XCTAssertEqual(SmartSearch.resolve("apple")?.url.host, "www.apple.com")
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
