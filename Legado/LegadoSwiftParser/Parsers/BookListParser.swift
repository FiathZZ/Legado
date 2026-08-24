import Foundation
import SwiftSoup

// MARK: - BookList（搜索/探索结果解析）

/// 解析搜索或探索结果，返回书籍列表
public nonisolated struct BookListParser {

    // MARK: - 搜索结果解析

    /// 解析搜索结果 HTML/JSON，返回书籍列表
    /// - Parameters:
    ///   - html: 搜索结果页 HTML 或 JSON
    ///   - bookSource: 书源配置
    ///   - baseUrl: 搜索请求的基础 URL
    /// - Returns: 搜索到的书籍列表
    public static func parseSearchResult(
        html: String,
        bookSource: BookSource,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil,
        maximumCount: Int? = nil
    ) throws -> [SearchBook] {
        guard let rule = bookSource.ruleSearch else { return [] }
        return try parseBookList(
            content: html,
            bookListRule: rule.bookList,
            nameRule: rule.name,
            authorRule: rule.author,
            introRule: rule.intro,
            kindRule: rule.kind,
            lastChapterRule: rule.lastChapter,
            updateTimeRule: rule.updateTime,
            bookUrlRule: rule.bookUrl,
            coverUrlRule: rule.coverUrl,
            wordCountRule: rule.wordCount,
            bookSource: bookSource,
            baseUrl: baseUrl,
            variableStore: variableStore,
            maximumCount: maximumCount
        )
    }

    /// 解析探索结果 HTML/JSON，返回书籍列表
    public static func parseExploreResult(
        html: String,
        bookSource: BookSource,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil,
        maximumCount: Int? = nil
    ) throws -> [SearchBook] {
        guard let rule = bookSource.ruleExplore else { return [] }
        return try parseBookList(
            content: html,
            bookListRule: rule.bookList,
            nameRule: rule.name,
            authorRule: rule.author,
            introRule: rule.intro,
            kindRule: rule.kind,
            lastChapterRule: rule.lastChapter,
            updateTimeRule: rule.updateTime,
            bookUrlRule: rule.bookUrl,
            coverUrlRule: rule.coverUrl,
            wordCountRule: rule.wordCount,
            bookSource: bookSource,
            baseUrl: baseUrl,
            variableStore: variableStore,
            maximumCount: maximumCount
        )
    }

    // MARK: - 私有实现

    private static func parseBookList(
        content: String,
        bookListRule: String?,
        nameRule: String?,
        authorRule: String?,
        introRule: String?,
        kindRule: String?,
        lastChapterRule: String?,
        updateTimeRule: String?,
        bookUrlRule: String?,
        coverUrlRule: String?,
        wordCountRule: String?,
        bookSource: BookSource,
        baseUrl: String,
        variableStore: ParserVariableStore?,
        maximumCount: Int?
    ) throws -> [SearchBook] {
        guard let listRule = bookListRule, !listRule.isEmpty else { return [] }
        let runtimeStore = variableStore ?? ParserVariableStore(writeScope: .ruleData)

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentIsJson = trimmedContent.hasPrefix("{") || trimmedContent.hasPrefix("[")
        let listRuleType = RuleAnalyzer.ruleType(for: listRule)

        ParserLog.debug(
            "BookListParser",
            "parse start source=\(bookSource.bookSourceName) isJson=\(contentIsJson) listRule=\(ParserLog.preview(listRule)) baseUrl=\(baseUrl)"
        )

        // 对 JSON 内容使用 JSON 路径提取书单，对 HTML 使用 CSS/XPath 元素提取
        if contentIsJson && listRuleType != .css && listRuleType != .xpath {
            return try parseBookListFromJSON(
                content: content,
                listRule: RuleAnalyzer.cleanRule(listRule),
                nameRule: nameRule,
                authorRule: authorRule,
                introRule: introRule,
                kindRule: kindRule,
                lastChapterRule: lastChapterRule,
                updateTimeRule: updateTimeRule,
                bookUrlRule: bookUrlRule,
                coverUrlRule: coverUrlRule,
                wordCountRule: wordCountRule,
                bookSource: bookSource,
                baseUrl: baseUrl,
                variableStore: runtimeStore,
                maximumCount: maximumCount
            )
        }

        let elements: [Element]
        switch listRuleType {
        case .css:
            elements = try CSSParser.getElements(from: content, rule: RuleAnalyzer.cleanRule(listRule), baseUrl: baseUrl)
        case .xpath:
            elements = try XPathParser.getElements(from: content, rule: listRule, baseUrl: baseUrl)
        case .default:
            let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: runtimeStore)
            elements = try analyzer.getElements(content: content, rule: listRule)
        case .jsonPath, .javascript:
            let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: runtimeStore)
            elements = try analyzer.getElements(content: content, rule: listRule)
        case .regex:
            elements = []
        }
        ParserLog.debug("BookListParser", "html elements count=\(elements.count)")

        return try Array(elements.prefix(maximumCount ?? elements.count)).enumerated().compactMap { index, element -> SearchBook? in
            let bookStore = runtimeStore.makeChildStore(
                writeScope: .book,
                inheritBookScope: false,
                resetRuleData: true
            )
            let itemHTML = try element.outerHtml()
            var book = SearchBook(
                origin: bookSource.bookSourceUrl,
                sourceName: bookSource.bookSourceName
            )
            var rawBookUrl = ""
            var rawCoverUrl = ""

            if let rule = nameRule, !rule.isEmpty {
                book.name = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore
                )
            }
            if let rule = authorRule, !rule.isEmpty {
                book.author = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore
                )
            }
            if let rule = introRule, !rule.isEmpty {
                book.intro = HtmlFormatter.format(
                    try extractHTMLField(
                        rule: rule,
                        element: element,
                        itemHTML: itemHTML,
                        baseUrl: baseUrl,
                        bookSource: bookSource,
                        variableStore: bookStore
                    )
                )
            }
            if let rule = kindRule, !rule.isEmpty {
                book.kind = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore
                )
            }
            if let rule = lastChapterRule, !rule.isEmpty {
                book.lastChapter = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore
                )
            }
            if let rule = updateTimeRule, !rule.isEmpty {
                book.updateTime = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore
                )
            }
            if let rule = bookUrlRule, !rule.isEmpty {
                rawBookUrl = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore,
                    isURL: true
                )
                book.bookUrl = correctedHTMLBookURL(
                    extractedURL: rawBookUrl,
                    bookURLRule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl
                )
            }
            if book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               shouldUseResponseURLAsFallbackBookURL(responseURL: baseUrl, bookSource: bookSource) {
                book.bookUrl = baseUrl
            }
            if let rule = coverUrlRule, !rule.isEmpty {
                rawCoverUrl = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore,
                    isURL: true
                )
                book.coverUrl = rawCoverUrl
            }
            if let rule = wordCountRule, !rule.isEmpty {
                book.wordCount = try extractHTMLField(
                    rule: rule,
                    element: element,
                    itemHTML: itemHTML,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: bookStore
                )
            }
            book.sourceVariables = bookStore.snapshot(for: .source, includeInherited: false)
            book.bookVariables = bookStore.snapshot(for: .book, includeInherited: false)
            book.variables = bookStore.snapshot(for: .book, includeInherited: true)

            ParserLog.debug(
                "BookListParser",
                "html[\(index)] name=\(ParserLog.preview(book.name)) author=\(ParserLog.preview(book.author)) rawBookUrl=\(ParserLog.preview(rawBookUrl)) bookUrl=\(ParserLog.preview(book.bookUrl)) rawCover=\(ParserLog.preview(rawCoverUrl))"
            )

            guard !book.name.isEmpty || !book.bookUrl.isEmpty else { return nil }
            if shouldCacheInfoHTML(for: book, responseURL: baseUrl, bookSource: bookSource) {
                book.infoHtml = itemHTML
            }
            return book
        }
    }

    // MARK: - JSON 路径书单解析

    /// 从 JSON 响应中按 JSONPath 规则提取书籍列表
    private static func parseBookListFromJSON(
        content: String,
        listRule: String,
        nameRule: String?,
        authorRule: String?,
        introRule: String?,
        kindRule: String?,
        lastChapterRule: String?,
        updateTimeRule: String?,
        bookUrlRule: String?,
        coverUrlRule: String?,
        wordCountRule: String?,
        bookSource: BookSource,
        baseUrl: String,
        variableStore: ParserVariableStore,
        maximumCount: Int?
    ) throws -> [SearchBook] {
        // Android BookList 会先经过 AnalyzeRule.getElements(ruleList)，让 `||/&&/@@`、
        // JSONPath、默认 JSON fallback 以及 JS 改写都走统一分发链路。
        // 直接调用 JSONPathParser 会吃不掉 `$..aladdin&&$.data`、`$.data.*`
        // 这类 Android 可过的组合规则。
        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: variableStore)
        var items = try extractJSONBookListItems(
            analyzer: analyzer,
            content: content,
            listRule: listRule
        )

        guard !items.isEmpty else { return [] }
        ParserLog.debug("BookListParser", "json items count=\(items.count)")

        return Array(items.prefix(maximumCount ?? items.count)).enumerated().compactMap { index, item -> SearchBook? in
            let bookStore = variableStore.makeChildStore(
                writeScope: .book,
                inheritBookScope: false,
                resetRuleData: true
            )
            let itemAnalyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: bookStore)
            var book = SearchBook(
                origin: bookSource.bookSourceUrl,
                sourceName: bookSource.bookSourceName
            )
            let itemJSON = jsonString(from: item)
            mergeTopLevelJSONScalars(from: itemJSON, into: bookStore)

            book.name = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: nameRule) ?? ""
            book.author = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: authorRule) ?? ""
            book.intro = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: introRule).map { HtmlFormatter.format($0) }
            book.kind = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: kindRule)
            book.lastChapter = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: lastChapterRule)
            book.updateTime = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: updateTimeRule)
            book.wordCount = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: wordCountRule)

            if let rule = bookUrlRule, !rule.isEmpty {
                let raw = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: rule, isUrl: true) ?? ""
                book.bookUrl = raw
            }
            if book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               shouldUseResponseURLAsFallbackBookURL(responseURL: baseUrl, bookSource: bookSource) {
                book.bookUrl = baseUrl
            }
            if let rule = coverUrlRule, !rule.isEmpty {
                let raw = jsonField(analyzer: itemAnalyzer, itemJSON: itemJSON, rule: rule, isUrl: true) ?? ""
                book.coverUrl = raw
            }
            book.sourceVariables = bookStore.snapshot(for: .source, includeInherited: false)
            book.bookVariables = bookStore.snapshot(for: .book, includeInherited: false)
            book.variables = bookStore.snapshot(for: .book, includeInherited: true)

            ParserLog.debug(
                "BookListParser",
                "json[\(index)] name=\(ParserLog.preview(book.name)) author=\(ParserLog.preview(book.author)) bookUrl=\(ParserLog.preview(book.bookUrl)) item=\(ParserLog.preview(itemJSON))"
            )

            guard !book.name.isEmpty || !book.bookUrl.isEmpty else { return nil }
            if shouldCacheInfoHTML(for: book, responseURL: baseUrl, bookSource: bookSource) {
                book.infoHtml = content
            }
            return book
        }
    }

    private static func shouldCacheInfoHTML(for book: SearchBook, responseURL: String, bookSource: BookSource) -> Bool {
        let normalizedResponseURL = normalizedURLString(responseURL)
        let normalizedBookURL = normalizedURLString(book.bookUrl)

        if !normalizedBookURL.isEmpty, normalizedBookURL == normalizedResponseURL {
            return true
        }

        guard let pattern = bookSource.bookUrlPattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty,
              pattern.uppercased() != "NONE" else {
            return false
        }

        return (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: responseURL,
            range: NSRange(responseURL.startIndex..., in: responseURL)
        ) != nil
    }

    private static func shouldUseResponseURLAsFallbackBookURL(responseURL: String, bookSource: BookSource) -> Bool {
        let normalizedResponseURL = normalizedURLString(responseURL)
        guard !normalizedResponseURL.isEmpty else { return false }

        if !looksLikeSearchPageURL(normalizedResponseURL) {
            return true
        }

        guard let pattern = bookSource.bookUrlPattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty,
              pattern.uppercased() != "NONE" else {
            return false
        }

        return (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: responseURL,
            range: NSRange(responseURL.startIndex..., in: responseURL)
        ) != nil
    }

    private static func looksLikeSearchPageURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let obviousPathHints = ["search", "sousuo", "sou", "query", "find"]
        if obviousPathHints.contains(where: { lowered.contains("/\($0)") || lowered.contains("\($0).") || lowered.contains("\($0)?") }) {
            return true
        }

        guard let components = URLComponents(string: trimmed) else {
            return false
        }

        let searchKeys: Set<String> = ["searchkey", "search", "keyword", "key", "wd", "q", "query"]
        return (components.queryItems ?? []).contains { item in
            searchKeys.contains(item.name.lowercased())
        }
    }

    private static func normalizedURLString(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeTopLevelJSONScalars(
        from content: String,
        into variableStore: ParserVariableStore
    ) {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return
        }

        for (key, value) in dictionary {
            let stringValue: String?
            switch value {
            case let string as String:
                stringValue = string.trimmingCharacters(in: .whitespacesAndNewlines)
            case let number as NSNumber:
                stringValue = number.stringValue
            default:
                stringValue = nil
            }

            guard let stringValue, !stringValue.isEmpty else { continue }
            variableStore.put(key, value: stringValue, scope: .book)
        }
    }

    private static func jsonField(
        analyzer: AnalyzeRule,
        itemJSON: String,
        rule: String?,
        isUrl: Bool = false
    ) -> String? {
        guard let rule = rule, !rule.isEmpty else { return nil }
        return try? analyzer.getString(content: itemJSON, rule: rule, isUrl: isUrl)
    }

    private static func jsonString(from item: Any) -> String {
        if JSONSerialization.isValidJSONObject(item),
           let data = try? JSONSerialization.data(withJSONObject: item),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return JSONPathParser.stringify(item) ?? "\(item)"
    }

    private static func extractHTMLField(
        rule: String,
        element: Element,
        itemHTML: String,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        isURL: Bool = false
    ) throws -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return "" }

        let resolvedRule = RuleAnalyzer.containsTemplate(trimmedRule)
            ? try renderHTMLTemplate(itemHTML: itemHTML, rule: trimmedRule, baseUrl: baseUrl, bookSource: bookSource, variableStore: variableStore)
            : trimmedRule
        let ruleType = RuleAnalyzer.ruleType(for: resolvedRule)
        let cleanedRule = RuleAnalyzer.cleanRule(resolvedRule)

        switch ruleType {
        case .css:
            return try CSSParser.getString(from: element, rule: cleanedRule, baseUrl: baseUrl)
        case .default:
            if let detachedValue = try detachedHTMLField(
                rule: resolvedRule,
                element: element,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: variableStore,
                isURL: isURL
            ) {
                return detachedValue
            }
            let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: variableStore)
            return try analyzer.getString(element: element, rule: resolvedRule, isUrl: isURL)
        case .xpath:
            // HTML 列表项里的 XPath 规则仍应对当前 item 作用，而不是退回整页 response。
            // 对搜索 `bookUrl` 来说，这一步决定了 `/book/.../` 是否能从当前命中 item 中正确抽出。
            return try XPathParser.getString(from: element, rule: resolvedRule, baseUrl: baseUrl)
        case .regex:
            return try RegexParser.getString(from: itemHTML, rule: cleanedRule)
        case .jsonPath, .javascript:
            let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: variableStore)
            return try analyzer.getString(content: itemHTML, rule: resolvedRule, isUrl: isURL)
        }
    }

    private static func renderHTMLTemplate(
        itemHTML: String,
        rule: String,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore
    ) throws -> String {
        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: variableStore)
        return try analyzer.renderTemplateRule(content: itemHTML, rule: rule)
    }

    private static func detachedHTMLField(
        rule: String,
        element: Element,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        isURL: Bool
    ) throws -> String? {
        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: variableStore)
        let context = try DetachedHTMLElementRuleContext(element: element, analyzer: analyzer, baseUrl: baseUrl)
        defer { context.cleanup() }
        let value = try context.getString(rule: rule, isUrl: isURL)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    /// 搜索列表 item 同时含封面、详情、最新章节等多个链接时，Android 会优先命中当前字段规则真正对应的详情入口。
    /// 旧 iOS 链路偶尔会把结果收敛到最新章节页或镜像详情页；这里只在“明显更像详情入口”时做无站点特判修正。
    private static func correctedHTMLBookURL(
        extractedURL: String,
        bookURLRule: String,
        element: Element,
        itemHTML: String,
        baseUrl: String
    ) -> String {
        let normalizedExtracted = extractedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentScore = htmlBookURLScore(normalizedExtracted, baseUrl: baseUrl)
        guard let bestCandidate = bestBookURLCandidate(from: element, baseUrl: baseUrl) else {
            return normalizedExtracted
        }

        let bestScore = htmlBookURLScore(bestCandidate, baseUrl: baseUrl)
        guard bestScore > currentScore else {
            return normalizedExtracted
        }

        let resolvedRule = bookURLRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedRule.contains("@href") || resolvedRule.contains("href") {
            ParserLog.debug(
                "BookListParser",
                "bookUrl corrected current=\(ParserLog.preview(normalizedExtracted)) candidate=\(ParserLog.preview(bestCandidate)) rule=\(ParserLog.preview(bookURLRule)) item=\(ParserLog.preview(itemHTML, limit: 120))"
            )
            return bestCandidate
        }

        return normalizedExtracted
    }

    private static func bestBookURLCandidate(from element: Element, baseUrl: String) -> String? {
        var bestURL: String?
        var bestScore = Int.min

        func consider(rawURL: String) {
            let candidates = AnalyzeUrl.postProcessExtractedURLs(rawURL, baseUrl: baseUrl, variableStore: nil)
            for candidate in candidates {
                let score = htmlBookURLScore(candidate, baseUrl: baseUrl)
                if score > bestScore {
                    bestScore = score
                    bestURL = candidate
                }
            }
        }

        // `class.list@tag.a` 这类规则会把当前 item 本身直接选成 `<a>`。
        // Android 在 item 级 `bookUrl` 求值时会优先保留这个当前详情入口，
        // 旧 iOS 纠偏只看子 `<a>`，会把根元素自己的 href 漏掉。
        if element.tagNameNormal().caseInsensitiveCompare("a") == .orderedSame,
           let currentHref = try? element.attr("href"),
           !currentHref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consider(rawURL: currentHref)
        }

        if let anchors = try? CSSParser.getElements(from: element, rule: "tag.a") {
            for anchor in anchors {
                guard let raw = try? anchor.attr("href") else { continue }
                consider(rawURL: raw)
            }
        }
        return bestURL
    }

    private static func htmlBookURLScore(_ value: String, baseUrl: String) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Int.min / 2 }

        let lowered = trimmed.lowercased()
        var score = 0

        if lowered.contains("/book/") {
            score += 80
        }
        if lowered.hasSuffix("/") {
            score += 40
        }
        if lowered.contains("/html/"), lowered.hasSuffix(".html") {
            score += 10
        }
        if lowered.range(of: #"/\d+\.html([?#].*)?$"#, options: .regularExpression) != nil {
            score -= 70
        }
        if lowered == baseUrl.lowercased() {
            score -= 40
        }
        if lowered.contains("search") || lowered.contains("s.php") {
            score -= 60
        }

        return score
    }

    private static func extractJSONBookListItems(
        analyzer: AnalyzeRule,
        content: String,
        listRule: String
    ) throws -> [Any] {
        if let direct = try? analyzer.resolveStructuredValue(content: content, rule: listRule) {
            let flattened = flattenJSONListItems(from: direct)
            if !flattened.isEmpty {
                return flattened
            }
        }

        var items = try JSONPathParser.getObjects(from: content, rule: listRule)
        if items.count == 1, let nested = items[0] as? [Any] {
            items = nested
        }
        return items
    }

    private static func flattenJSONListItems(from value: Any?) -> [Any] {
        guard let value else { return [] }

        if let array = value as? [Any] {
            if array.count == 1, let nested = array[0] as? [Any] {
                return nested
            }
            return array.flatMap { item in
                if item is [String: Any] {
                    return [item]
                }
                if item is [Any] {
                    return flattenJSONListItems(from: item)
                }
                return [item]
            }
        }

        if let dictionary = value as? [String: Any] {
            return [dictionary]
        }

        return []
    }

}
