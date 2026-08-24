import Foundation
import SwiftSoup

// MARK: - BookListParserV2

/// V2 搜索/探索结果解析器。
///
/// H5 开始不再只是把旧 parser 包一层，而是统一由 `RuleRuntimeV2` 承接 Android 风格运行时：
/// - search/detail 共享 `baseUrl` / `result` / `book` / `infoHtml`
/// - `bookUrlPattern` 命中时把搜索结果页直接按详情页解析
/// - `bookList` 为空时允许结构化 fallback，而不是直接报空结果
/// - 字段级失败只丢当前字段，不中断整条书籍结果
nonisolated struct BookListParserV2 {
    static func parseSearchResult(
        html: String,
        context: ParserStageContextV2,
        maximumCount: Int? = nil
    ) throws -> [SearchBook] {
        try parse(
            html: html,
            context: context,
            isSearch: true,
            maximumCount: maximumCount
        )
    }

    static func parseExploreResult(
        html: String,
        context: ParserStageContextV2,
        maximumCount: Int? = nil
    ) throws -> [SearchBook] {
        try parse(
            html: html,
            context: context,
            isSearch: false,
            maximumCount: maximumCount
        )
    }

    // MARK: - Core

    private static func parse(
        html: String,
        context: ParserStageContextV2,
        isSearch: Bool,
        maximumCount: Int?
    ) throws -> [SearchBook] {
        let source = context.source
        let runtime = StageRuntimeFactoryV2.makeRuleRuntime(from: context)
        let responseURL = context.redirectUrl ?? context.responseUrl ?? context.baseUrl
        let baseURL = responseURL.isEmpty ? context.baseUrl : responseURL
        let rule = activeRule(from: source, isSearch: isSearch)

        ParserLog.debug(
            "BookListParserV2",
            "parse stage=\(context.stage.rawValue) source=\(source.bookSourceName) baseUrl=\(baseURL) responseUrl=\(ParserLog.preview(responseURL))"
        )

        if isSearch, matchesBookURLPattern(responseURL, source: source) {
            ParserLog.debug("BookListParserV2", "search response matched bookUrlPattern, parsing as detail page")
            if let fallbackBook = try parseDetailFallbackBook(
                html: html,
                context: context,
                runtime: runtime,
                responseURL: responseURL
            ) {
                return [fallbackBook]
            }
        }

        let collectionRule = normalizedCollectionRule(rule?.bookList)
        let collections = try extractCollections(
            html: html,
            collectionRule: collectionRule,
            runtime: runtime
        )
        let reverse = shouldReverseCollection(rule?.bookList)

        if collections.isEmpty {
            ParserLog.debug("BookListParserV2", "collection empty, attempting Android-style detail fallback")
            if let fallbackBook = try parseDetailFallbackBook(
                html: html,
                context: context,
                runtime: runtime,
                responseURL: responseURL
            ) {
                return [fallbackBook]
            }
            return []
        }

        var books: [SearchBook] = []
        books.reserveCapacity(maximumCount ?? collections.count)

        for (index, entry) in collections.enumerated() {
            if let maximumCount, books.count >= maximumCount {
                break
            }
            if let book = try parseCollectionItem(
                entry,
                index: index,
                html: html,
                context: context,
                runtime: runtime,
                rule: rule,
                responseURL: responseURL,
                baseURL: baseURL,
                isSearch: isSearch
            ) {
                books.append(book)
            }
        }

        books = deduplicate(books)
        if reverse {
            books.reverse()
        }

        ParserLog.debug("BookListParserV2", "books count=\(books.count)")
        return books
    }

    private static func parseCollectionItem(
        _ entry: Any,
        index: Int,
        html: String,
        context: ParserStageContextV2,
        runtime: RuleRuntimeV2,
        rule: SearchFieldRuleSet?,
        responseURL: String,
        baseURL: String,
        isSearch: Bool
    ) throws -> SearchBook? {
        let bookStore = context.variableStore.makeChildStore(
            writeScope: .book,
            inheritBookScope: false,
            resetRuleData: true
        )
        let itemRuntime = RuleRuntimeV2(
            stage: context.stage,
            baseUrl: baseURL,
            requestUrl: context.requestUrl,
            responseUrl: context.responseUrl,
            source: context.source,
            variableStore: bookStore,
            transfer: context.transfer
        )

        let itemContent = collectionContentString(from: entry)
        mergeTopLevelJSONScalars(from: itemContent, into: bookStore)
        if let scalarValues = itemScalarValues(from: entry) {
            for (key, value) in scalarValues {
                bookStore.put(key, value: value, scope: .book)
            }
        }

        var book = SearchBook(
            origin: context.source.bookSourceUrl,
            sourceName: context.source.bookSourceName
        )

        // Android 在列表解析中会按字段粒度容错，缺一个字段不应把整条结果打掉。
        book.name = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.name) ?? ""
        book.author = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.author) ?? ""
        book.intro = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.intro).map(HtmlFormatter.format)
        book.kind = safeJoinedString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.kind)
        book.lastChapter = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.lastChapter)
        book.updateTime = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.updateTime)
        book.wordCount = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.wordCount)
        book.coverUrl = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.coverUrl, isURL: true)

        let extractedBookURL = safeString(from: itemRuntime, entry: entry, content: itemContent, rule: rule?.bookUrl, isURL: true) ?? ""
        if !extractedBookURL.isEmpty {
            book.bookUrl = extractedBookURL
        } else if let inferredBookURL = inferBookURLFromItemContent(
            entry: entry,
            itemContent: itemContent,
            baseURL: baseURL,
            source: context.source,
            variableStore: bookStore,
            bookName: book.name
        ) {
            book.bookUrl = inferredBookURL
        } else if shouldUseResponseURLAsFallbackBookURL(responseURL: responseURL, source: context.source) {
            book.bookUrl = responseURL
        }

        let normalizedName = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty,
           let detailLikeBook = try parseCollectionItemAsDetailFallback(
            entry: entry,
            itemContent: itemContent,
            context: context,
            itemRuntime: itemRuntime,
            responseURL: responseURL,
            fallbackBookURL: book.bookUrl.isEmpty ? responseURL : book.bookUrl
           ) {
            return detailLikeBook
        }

        book.sourceVariables = bookStore.snapshot(for: .source, includeInherited: false)
        book.bookVariables = bookStore.snapshot(for: .book, includeInherited: false)
        book.variables = bookStore.snapshot(for: .book, includeInherited: true)

        if shouldCacheInfoHTML(for: book, responseURL: responseURL, source: context.source) {
            book.infoHtml = itemContent
        }

        ParserLog.debug(
            "BookListParserV2",
            "item[\(index)] name=\(ParserLog.preview(book.name)) author=\(ParserLog.preview(book.author)) bookUrl=\(ParserLog.preview(book.bookUrl))"
        )

        if isSearch,
           !isUsableSearchBookURL(book.bookUrl, responseURL: responseURL, source: context.source) {
            ParserLog.debug(
                "BookListParserV2",
                "drop search item[\(index)] unusable bookUrl=\(ParserLog.preview(book.bookUrl)) name=\(ParserLog.preview(book.name))"
            )
            return nil
        }

        guard !book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return book
    }

    private static func parseDetailFallbackBook(
        html: String,
        context: ParserStageContextV2,
        runtime: RuleRuntimeV2,
        responseURL: String
    ) throws -> SearchBook? {
        let bookURL = normalizedFallbackBookURL(responseURL: responseURL, context: context)
        guard !bookURL.isEmpty else { return nil }

        let fallbackDetail = try BookInfoParserV2.parse(
            html: html,
            bookUrl: bookURL,
            context: context
        )

        let trimmedName = fallbackDetail.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        var mergedVariables = fallbackDetail.variables
        mergedVariables["name"] = fallbackDetail.name
        if mergedVariables["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            mergedVariables["title"] = fallbackDetail.name
        }
        mergedVariables["author"] = fallbackDetail.author
        if let kind = fallbackDetail.kind, !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedVariables["kind"] = kind
        }
        if let intro = fallbackDetail.intro, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedVariables["intro"] = intro
        }
        if let tocUrl = fallbackDetail.tocUrl, !tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedVariables["tocUrl"] = tocUrl
        }

        var searchBook = SearchBook(
            bookUrl: fallbackDetail.bookUrl,
            name: fallbackDetail.name,
            author: fallbackDetail.author,
            coverUrl: fallbackDetail.coverUrl,
            intro: fallbackDetail.intro,
            kind: fallbackDetail.kind,
            lastChapter: fallbackDetail.lastChapter,
            updateTime: fallbackDetail.updateTime,
            wordCount: fallbackDetail.wordCount,
            origin: context.source.bookSourceUrl,
            sourceName: context.source.bookSourceName,
            infoHtml: html,
            sourceVariables: fallbackDetail.sourceVariables,
            bookVariables: fallbackDetail.bookVariables,
            variables: mergedVariables
        )

        if searchBook.bookUrl.isEmpty {
            searchBook.bookUrl = bookURL
        }

        let effectiveRuntimeBookURL = searchBook.bookUrl.isEmpty ? bookURL : searchBook.bookUrl
        runtime.injectBookVariable(
            bookUrl: effectiveRuntimeBookURL,
            name: searchBook.name,
            author: searchBook.author,
            kind: searchBook.kind ?? "",
            tocUrl: fallbackDetail.tocUrl ?? "",
            bookVariables: searchBook.variables
        )
        return searchBook
    }

    /// Android `BookList.getSearchItem()` 拿不到稳定列表字段时，并不会立刻放弃这一条结果：
    /// 搜索响应体有时本身就是“单本详情对象”或“列表项里嵌了 detail payload”，
    /// 这时会继续借助同一份运行时变量把详情字段补全后再生成 `SearchBook`。
    ///
    /// V2 这里不按源名特判，而是在“当前 item 已经提供可用 bookUrl 或具备 detail 字段”的前提下，
    /// 复用 `BookInfoParserV2` 的字段语义，把 item content 当成一页最小详情页来补齐 name/author/tocUrl。
    private static func parseCollectionItemAsDetailFallback(
        entry: Any,
        itemContent: String,
        context: ParserStageContextV2,
        itemRuntime: RuleRuntimeV2,
        responseURL: String,
        fallbackBookURL: String
    ) throws -> SearchBook? {
        let normalizedBookURL = fallbackBookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBookURL.isEmpty else { return nil }

        let itemContext = makeItemDetailContext(
            context: context,
            itemRuntime: itemRuntime,
            itemContent: itemContent,
            bookURL: normalizedBookURL,
            responseURL: responseURL
        )
        let detail = try BookInfoParserV2.parse(
            html: itemContent,
            bookUrl: normalizedBookURL,
            context: itemContext
        )
        let trimmedName = detail.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        return makeSearchBook(from: detail, html: itemContent, source: context.source)
    }

    // MARK: - Helpers

    private static func extractCollections(
        html: String,
        collectionRule: String?,
        runtime: RuleRuntimeV2
    ) throws -> [Any] {
        guard let collectionRule, !collectionRule.isEmpty else { return [] }

        let trimmedContent = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentIsJSON = trimmedContent.hasPrefix("{") || trimmedContent.hasPrefix("[")
        let ruleType = RuleAnalyzer.ruleType(for: collectionRule)

        // HTML 列表规则优先保留 Element，避免 `.item` 被结构化分支先降成字符串结果。
        if !contentIsJSON, ruleType != .jsonPath && ruleType != .javascript {
            let elements = try runtime.getElements(content: html, rule: collectionRule)
            if !elements.isEmpty {
                return elements
            }
        }

        if let structuredValue = try? runtime.resolveStructuredValue(content: html, rule: collectionRule) {
            let flattened = flattenStructuredCollections(from: structuredValue)
            if !flattened.isEmpty {
                return flattened
            }
        }

        let elements = try runtime.getElements(content: html, rule: collectionRule)
        if !elements.isEmpty {
            return elements
        }

        if let directJSON = try? runtime.getValue(content: html, rule: collectionRule) {
            let flattened = flattenStructuredCollections(from: directJSON)
            if !flattened.isEmpty {
                return flattened
            }
        }

        return []
    }

    private static func flattenStructuredCollections(from value: Any?) -> [Any] {
        guard let value else { return [] }
        if let array = value as? [Any] {
            if array.count == 1, let nested = array.first as? [Any] {
                return flattenStructuredCollections(from: nested)
            }
            return array.flatMap { item in
                if item is [String: Any] || item is NSDictionary || item is Element {
                    return [item]
                }
                if item is [Any] {
                    return flattenStructuredCollections(from: item)
                }
                return [item]
            }
        }
        if value is [String: Any] || value is NSDictionary || value is Element {
            return [value]
        }
        return []
    }

    private static func collectionContentString(from entry: Any) -> String {
        if let element = entry as? Element {
            return (try? element.outerHtml()) ?? ""
        }
        if JSONSerialization.isValidJSONObject(entry),
           let data = try? JSONSerialization.data(withJSONObject: entry),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return JSONPathParser.stringify(entry) ?? "\(entry)"
    }

    private static func itemScalarValues(from entry: Any) -> [String: String]? {
        let dictionary: [String: Any]?
        if let values = entry as? [String: Any] {
            dictionary = values
        } else if let values = entry as? NSDictionary {
            var bridged: [String: Any] = [:]
            for (key, value) in values {
                guard let key = key as? String else { continue }
                bridged[key] = value
            }
            dictionary = bridged
        } else {
            dictionary = nil
        }

        guard let dictionary else { return nil }
        var scalars: [String: String] = [:]
        for (key, value) in dictionary {
            switch value {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    scalars[key] = trimmed
                }
            case let number as NSNumber:
                scalars[key] = number.stringValue
            default:
                break
            }
        }
        return scalars
    }

    private static func safeString(
        from runtime: RuleRuntimeV2,
        entry: Any,
        content: String,
        rule: String?,
        isURL: Bool = false
    ) -> String? {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let value = try runtime.getString(item: entry, content: content, rule: rule, isUrl: isURL)
            return normalizedScalarFieldValue(value)
        } catch {
            ParserLog.debug(
                "BookListParserV2",
                "field failed rule=\(ParserLog.preview(rule)) isUrl=\(isURL) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Fields may pass through `<js>` chains that preserve a single JS string as a JSON literal
    /// (`"text"`). Android assigns the scalar value itself, so V2 trims only that outer
    /// serialization layer while leaving ordinary text, arrays and objects untouched.
    private static func normalizedScalarFieldValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\"",
              let data = trimmed.data(using: String.Encoding.utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let string = decoded as? String else {
            return value
        }
        return string
    }

    private static func safeJoinedString(
        from runtime: RuleRuntimeV2,
        entry: Any,
        content: String,
        rule: String?
    ) -> String? {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let values = try runtime.getStringList(item: entry, content: content, rule: rule)
            let filtered = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return filtered.isEmpty ? nil : filtered.joined(separator: ",")
        } catch {
            ParserLog.debug(
                "BookListParserV2",
                "list field failed rule=\(ParserLog.preview(rule)) error=\(error.localizedDescription)"
            )
            return nil
        }
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
            switch value {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    variableStore.put(key, value: trimmed, scope: .book)
                }
            case let number as NSNumber:
                variableStore.put(key, value: number.stringValue, scope: .book)
            default:
                break
            }
        }
    }

    private static func activeRule(from source: BookSource, isSearch: Bool) -> SearchFieldRuleSet? {
        if isSearch {
            return source.ruleSearch.map(SearchFieldRuleSet.init)
        }
        if let explore = source.ruleExplore,
           !(explore.bookList?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return SearchFieldRuleSet(explore)
        }
        return source.ruleSearch.map(SearchFieldRuleSet.init)
    }

    private static func normalizedCollectionRule(_ rule: String?) -> String? {
        guard let rule else { return nil }
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func shouldReverseCollection(_ rule: String?) -> Bool {
        rule?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") == true
    }

    private static func matchesBookURLPattern(_ url: String, source: BookSource) -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let pattern = source.bookUrlPattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty,
              pattern.uppercased() != "NONE",
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        return regex.firstMatch(
            in: trimmedURL,
            range: NSRange(trimmedURL.startIndex..., in: trimmedURL)
        ) != nil
    }

    private static func inferBookURLFromItemContent(
        entry: Any,
        itemContent: String,
        baseURL: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        bookName: String
    ) -> String? {
        let candidates = collectBookURLCandidates(
            entry: entry,
            itemContent: itemContent,
            baseURL: baseURL,
            variableStore: variableStore,
            bookName: bookName
        )

        let usable = candidates.filter {
            isUsableInferredBookURL($0, source: source)
        }
        if let matched = usable.first(where: { matchesBookURLPattern($0, source: source) }) {
            return matched
        }
        return usable.first
    }

    private static func collectBookURLCandidates(
        entry: Any,
        itemContent: String,
        baseURL: String,
        variableStore: ParserVariableStore,
        bookName: String
    ) -> [String] {
        var rawValues: [String] = []

        if let element = entry as? Element {
            rawValues.append(contentsOf: anchorHrefCandidates(from: element, bookName: bookName))
            rawValues.append(contentsOf: attributeURLCandidates(from: element))
        }

        rawValues.append(contentsOf: regexURLCandidates(from: itemContent))
        rawValues.append(contentsOf: jsonURLCandidates(from: entry))

        var seen: Set<String> = []
        var resolved: [String] = []
        for rawValue in rawValues {
            for candidate in AnalyzeUrlV2.postProcessExtractedURLs(rawValue, baseUrl: baseURL, variableStore: variableStore) {
                let normalized = normalizedURLString(candidate)
                guard !normalized.isEmpty else { continue }
                if seen.insert(normalized).inserted {
                    resolved.append(normalized)
                }
            }
        }
        return resolved
    }

    private static func anchorHrefCandidates(from element: Element, bookName: String) -> [String] {
        guard let anchors = try? element.select("a[href]") else { return [] }
        let normalizedName = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        var preferred: [String] = []
        var fallback: [String] = []

        for anchor in anchors.array() {
            guard let href = try? anchor.attr("href"),
                  !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedName.isEmpty, text.contains(normalizedName) || normalizedName.contains(text) {
                preferred.append(href)
            } else {
                fallback.append(href)
            }
        }

        return preferred + fallback
    }

    private static func attributeURLCandidates(from element: Element) -> [String] {
        let selectors = [
            "[href]",
            "[data-href]",
            "[data-url]",
            "[data-link]",
            "[url]",
            "[onclick]"
        ]
        var values: [String] = []

        for selector in selectors {
            guard let selected = try? element.select(selector) else { continue }
            for item in selected.array() {
                let attrName = selector
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let rawValue = try? item.attr(attrName),
                      !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                if attrName == "onclick" {
                    values.append(contentsOf: regexURLCandidates(from: rawValue))
                } else {
                    values.append(rawValue)
                }
            }
        }

        return values
    }

    private static func regexURLCandidates(from text: String) -> [String] {
        let patterns = [
            #"(?i)\bhref\s*=\s*["']([^"']+)["']"#,
            #"(?i)\b(?:data-href|data-url|data-link|url)\s*=\s*["']([^"']+)["']"#,
            #"(?i)newWebView\s*\(\s*["']([^"']+)["']"#,
            #"(?i)(?:location\.href|window\.location)\s*=\s*["']([^"']+)["']"#,
            #"["']((?:https?:)?//[^"']+)["']"#,
            #"["'](/[^"']+\.(?:html|htm|php|aspx?)(?:\?[^"']*)?)["']"#
        ]

        var values: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                let value = nsText.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    values.append(value)
                }
            }
        }
        return values
    }

    private static func jsonURLCandidates(from entry: Any) -> [String] {
        var values: [String] = []
        collectJSONURLCandidates(from: entry, keyPath: [], into: &values)
        return values
    }

    private static func collectJSONURLCandidates(from value: Any, keyPath: [String], into values: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                collectJSONURLCandidates(from: nestedValue, keyPath: keyPath + [key], into: &values)
            }
            return
        }
        if let dictionary = value as? NSDictionary {
            for (key, nestedValue) in dictionary {
                guard let key = key as? String else { continue }
                collectJSONURLCandidates(from: nestedValue, keyPath: keyPath + [key], into: &values)
            }
            return
        }
        if let array = value as? [Any] {
            for nestedValue in array {
                collectJSONURLCandidates(from: nestedValue, keyPath: keyPath, into: &values)
            }
            return
        }

        guard let string = value as? String else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = keyPath.last?.lowercased() ?? ""
        let urlKeyHints = ["url", "href", "link", "bookurl", "book_url", "detail", "readurl", "articleurl"]
        if urlKeyHints.contains(where: { key.contains($0) }) || looksLikeURLPayload(trimmed) {
            values.append(trimmed)
        }
    }

    private static func looksLikeURLPayload(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("//") {
            return true
        }
        guard value.hasPrefix("/") else { return false }
        return lowered.contains(".html")
            || lowered.contains(".htm")
            || lowered.contains(".php")
            || lowered.contains("/book/")
            || lowered.contains("/novel/")
            || lowered.contains("/b/")
            || lowered.contains("/info/")
    }

    private static func isUsableInferredBookURL(_ value: String, source: BookSource) -> Bool {
        let trimmed = normalizedURLString(value)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("javascript:")
            || lowered.hasPrefix("mailto:")
            || lowered.hasPrefix("tel:")
            || lowered.hasPrefix("#") {
            return false
        }
        if looksLikeStaticAssetURL(lowered) {
            return false
        }
        if looksLikeSearchPageURL(trimmed), !matchesBookURLPattern(trimmed, source: source) {
            return false
        }
        return true
    }

    private static func isUsableSearchBookURL(_ value: String, responseURL: String, source: BookSource) -> Bool {
        let trimmed = normalizedURLString(value)
        guard isUsableInferredBookURL(trimmed, source: source) else { return false }
        if urlsEquivalent(trimmed, responseURL),
           looksLikeSearchPageURL(responseURL),
           !matchesBookURLPattern(trimmed, source: source) {
            return false
        }
        return true
    }

    private static func looksLikeStaticAssetURL(_ loweredURL: String) -> Bool {
        let assetExtensions = [
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".ico",
            ".css", ".js", ".woff", ".woff2", ".ttf", ".otf"
        ]
        let path = URLComponents(string: loweredURL)?.path.lowercased() ?? loweredURL
        return assetExtensions.contains { path.hasSuffix($0) }
    }

    private static func shouldUseResponseURLAsFallbackBookURL(responseURL: String, source: BookSource) -> Bool {
        let trimmedURL = responseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return false }
        if !looksLikeSearchPageURL(trimmedURL) {
            return true
        }
        return matchesBookURLPattern(trimmedURL, source: source)
    }

    private static func shouldCacheInfoHTML(for book: SearchBook, responseURL: String, source: BookSource) -> Bool {
        let normalizedBookURL = normalizedURLString(book.bookUrl)
        let normalizedResponseURL = normalizedURLString(responseURL)
        if !normalizedBookURL.isEmpty, normalizedBookURL == normalizedResponseURL {
            return true
        }
        return matchesBookURLPattern(responseURL, source: source)
    }

    private static func normalizedFallbackBookURL(responseURL: String, context: ParserStageContextV2) -> String {
        let candidate = responseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            return candidate
        }
        return context.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeSearchPageURL(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let obviousPathHints = ["search", "sousuo", "sou", "query", "find"]
        if obviousPathHints.contains(where: { lowered.contains("/\($0)") || lowered.contains("\($0).") || lowered.contains("\($0)?") }) {
            return true
        }

        guard let components = URLComponents(string: value) else {
            return false
        }
        let searchKeys: Set<String> = ["searchkey", "search", "keyword", "key", "wd", "q", "query"]
        return (components.queryItems ?? []).contains { item in
            searchKeys.contains(item.name.lowercased())
        }
    }

    private static func urlsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedComparableURL(lhs)
        let right = normalizedComparableURL(rhs)
        return !left.isEmpty && left == right
    }

    private static func normalizedComparableURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let components = URLComponents(string: trimmed) else {
            return trimmed
        }

        var normalized = components
        normalized.scheme = normalized.scheme?.lowercased()
        normalized.host = normalized.host?.lowercased()
        if normalized.path != "/", normalized.path.hasSuffix("/") {
            normalized.path.removeLast()
        }
        return normalized.string ?? trimmed
    }

    private static func normalizedURLString(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicate(_ books: [SearchBook]) -> [SearchBook] {
        var seen: Set<String> = []
        var result: [SearchBook] = []
        result.reserveCapacity(books.count)

        for book in books {
            let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let bookURL = normalizedURLString(book.bookUrl)
            let key = [bookURL, name, author].joined(separator: "|")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(book)
        }

        return result
    }

    private static func makeItemDetailContext(
        context: ParserStageContextV2,
        itemRuntime: RuleRuntimeV2,
        itemContent: String,
        bookURL: String,
        responseURL: String
    ) -> ParserStageContextV2 {
        let sourceVariables = itemRuntime.variableStore.snapshot(for: .source, includeInherited: false)
        let bookVariables = itemRuntime.variableStore.snapshot(for: .book, includeInherited: false)
        let mergedVariables = itemRuntime.variableStore.snapshot(for: .book, includeInherited: true)
        let seed = BookDetail(
            bookUrl: bookURL,
            origin: context.source.bookSourceUrl,
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            variables: mergedVariables
        )
        return ParserStageContextV2(
            stage: .detail,
            source: context.source,
            baseUrl: responseURL.isEmpty ? context.baseUrl : responseURL,
            requestUrl: context.requestUrl,
            responseUrl: responseURL,
            variableStore: itemRuntime.variableStore,
            requestContext: context.requestContext,
            runtimeTrace: context.runtimeTrace,
            bookDetail: seed,
            transfer: ParserStageTransferV2(
                bookUrl: bookURL,
                infoHtml: itemContent,
                redirectUrl: responseURL,
                responseBody: itemContent
            )
        )
    }

    private static func makeSearchBook(from detail: BookDetail, html: String, source: BookSource) -> SearchBook {
        var mergedVariables = detail.variables
        mergedVariables["name"] = detail.name
        if mergedVariables["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            mergedVariables["title"] = detail.name
        }
        mergedVariables["author"] = detail.author
        if let kind = detail.kind, !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedVariables["kind"] = kind
        }
        if let tocUrl = detail.tocUrl, !tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedVariables["tocUrl"] = tocUrl
        }

        return SearchBook(
            bookUrl: detail.bookUrl,
            name: detail.name,
            author: detail.author,
            coverUrl: detail.coverUrl,
            intro: detail.intro,
            kind: detail.kind,
            lastChapter: detail.lastChapter,
            updateTime: detail.updateTime,
            wordCount: detail.wordCount,
            origin: source.bookSourceUrl,
            sourceName: source.bookSourceName,
            infoHtml: html,
            sourceVariables: detail.sourceVariables,
            bookVariables: detail.bookVariables,
            variables: mergedVariables
        )
    }
}

// MARK: - SearchFieldRuleSet

private nonisolated struct SearchFieldRuleSet {
    let bookList: String?
    let name: String?
    let author: String?
    let intro: String?
    let kind: String?
    let lastChapter: String?
    let updateTime: String?
    let bookUrl: String?
    let coverUrl: String?
    let wordCount: String?

    init(_ rule: SearchRule) {
        self.bookList = rule.bookList
        self.name = rule.name
        self.author = rule.author
        self.intro = rule.intro
        self.kind = rule.kind
        self.lastChapter = rule.lastChapter
        self.updateTime = rule.updateTime
        self.bookUrl = rule.bookUrl
        self.coverUrl = rule.coverUrl
        self.wordCount = rule.wordCount
    }

    init(_ rule: ExploreRule) {
        self.bookList = rule.bookList
        self.name = rule.name
        self.author = rule.author
        self.intro = rule.intro
        self.kind = rule.kind
        self.lastChapter = rule.lastChapter
        self.updateTime = rule.updateTime
        self.bookUrl = rule.bookUrl
        self.coverUrl = rule.coverUrl
        self.wordCount = rule.wordCount
    }
}
