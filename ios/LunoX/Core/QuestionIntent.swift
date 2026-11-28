import Foundation

/// Decides whether what was typed in the address bar is a question or a request for an assistant ("怎么…", "为什么…", "how do I …",
/// "打开 SwiftUI 官方文档", "总结一下这个页面") rather than keywords for a search engine. Conservative: short keyword queries stay ordinary searches.
enum QuestionIntent {
    private static let zhStarts = ["怎么", "怎样", "如何", "为什么", "为何", "什么是", "是什么", "什么叫", "哪个", "哪些", "哪里", "谁是", "多少", "几个", "能不能", "可不可以",
                                   "是否", "有没有", "请问", "帮我", "给我", "介绍一下", "解释", "讲讲", "说说", "比较", "对比", "推荐", "教我", "告诉我", "帮忙", "总结", "翻译", "写一个", "写一段", "查一下", "查查"]
    private static let zhEnds = ["吗", "呢", "怎么办", "有什么区别", "是什么", "怎么样", "好不好", "行不行", "对不对", "吧"]
    private static let enStarts = ["how ", "why ", "what ", "who ", "when ", "where ", "which ", "can ", "could ", "should ", "would ", "is ", "are ", "does ", "do ", "did ",
                                   "explain ", "compare ", "tell me", "help me", "give me", "summarize", "translate", "write ", "find me", "show me"]
    private static let navVerbs = ["打开", "带我去", "访问", "进入", "前往", "跳转到", "open ", "go to ", "take me to", "navigate to"]
    private static let pageWords = ["这个页面", "这页", "本页", "当前页面", "这篇", "此页", "这个网站", "这个网页", "this page", "this article", "this site", "this website", "the page"]

    private static func looksLikeAddress(_ q: String) -> Bool {
        q.contains("://") || q.range(of: #"^[\w.\-]+\.[A-Za-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil
    }

    /// A natural-language question or request.
    static func isQuestion(_ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 4, !looksLikeAddress(q), SmartSearch.resolve(q) == nil, !q.lowercased().contains("site:") else { return false }
        let l = q.lowercased()
        if l.hasSuffix("?") || l.hasSuffix("？") { return true }
        if zhStarts.contains(where: { l.hasPrefix($0) }) { return true }
        if q.unicodeScalars.contains(where: { $0.value >= 0x2E80 }), q.count >= 6, zhEnds.contains(where: { l.hasSuffix($0) }) { return true }
        if enStarts.contains(where: { l.hasPrefix($0) }), l.split(separator: " ").count >= 3 { return true }
        return wantsNavigation(q)
    }

    /// "Take me to …": the assistant should find the site and open it.
    static func wantsNavigation(_ raw: String) -> Bool {
        let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard l.count >= 4, !looksLikeAddress(l) else { return false }
        return navVerbs.contains { l.hasPrefix($0) } || l.hasSuffix("官网在哪") || l.hasSuffix("官网地址")
    }

    /// The question is about the page that is open.
    static func refersToPage(_ raw: String) -> Bool {
        let l = raw.lowercased()
        return pageWords.contains { l.contains($0) }
    }
}
