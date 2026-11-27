import XCTest
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
    func testSetupLink() {
        let s = Settings()
        let pin = String(repeating: "ab", count: 32)
        XCTAssertTrue(s.applySetupLink(URL(string: "lunox://setup?host=1.2.3.4&port=9443&key=k&pin=\(pin)&edge=edge.example.com")!))
        XCTAssertEqual(s.prefs.gatewayPort, 9443); XCTAssertEqual(s.prefs.edgeHost, "edge.example.com")
        XCTAssertFalse(s.applySetupLink(URL(string: "lunox://setup?host=bad host&key=k&pin=\(pin)")!))
        XCTAssertFalse(s.applySetupLink(URL(string: "lunox://setup?host=1.2.3.4&key=k&pin=short")!))
    }
}
