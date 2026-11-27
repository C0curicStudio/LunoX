import Foundation
import WebKit

/// Compiles a tracker/ad rule list once and reuses it for every tab.
@MainActor
final class ContentBlocker {
    private(set) var list: WKContentRuleList?
    private static let id = "lunox.trackers.v1"

    private static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "googletagservices.com",
        "adservice.google.com", "adnxs.com", "adsrvr.org", "taboola.com", "outbrain.com", "criteo.com", "criteo.net",
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "mixpanel.com", "segment.io", "amplitude.com",
        "connect.facebook.net", "pixel.facebook.com", "analytics.twitter.com", "ads-twitter.com", "ads.linkedin.com",
        "bat.bing.com", "clarity.ms", "moatads.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "adsafeprotected.com", "2mdn.net", "amazon-adsystem.com", "yieldmo.com", "bidswitch.net", "mathtag.com",
        "hm.baidu.com", "cnzz.com", "umeng.com", "gdt.qq.com", "pos.baidu.com", "cpro.baidu.com", "ads.tiktok.com",
    ]
    private static let hideSelectors = [
        "[id^='google_ads']", "[class*='adsbygoogle']", "ins.adsbygoogle", "[id*='taboola']", "[class*='outbrain']",
        "iframe[src*='doubleclick.net']", "[data-ad-slot]",
    ]

    func prepare() async {
        var rules: [[String: Any]] = Self.domains.map {
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: $0), "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": Self.hideSelectors.joined(separator: ",")]])
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else { return }
        list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: Self.id, encodedContentRuleList: json)
    }
}
