import Foundation
import SwiftSoup

// MARK: - BookChapterParser（目录解析）

/// 解析书籍目录页，提取章节列表
public nonisolated struct BookChapterParser {

    private struct BookContext {
        let bookUrl: String
        let name: String
        let author: String
        let kind: String
        let tocUrl: String
        let bookVariables: [String: String]
    }

    /// 解析目录页 HTML，返回章节列表
    /// - Parameters:
    ///   - html: 目录页 HTML 或 JSON
    ///   - bookSource: 书源配置
    ///   - bookUrl: 所属书籍 URL
    ///   - baseUrl: 目录页 URL（用作基础 URL）
    /// - Returns: 章节列表及下一页目录 URL 列表（若有）
    public static func parse(
        html: String,
        bookSource: BookSource,
        bookUrl: String,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil,
        bookName: String = "",
        bookAuthor: String = "",
        bookKind: String = "",
        tocUrl: String = "",
        bookVariables: [String: String] = [:]
    ) throws -> (chapters: [BookChapter], nextTocUrls: [String]) {
        guard let rule = bookSource.ruleToc else {
            return ([], [])
        }
        let runtimeStore = variableStore ?? ParserVariableStore(writeScope: .book)
        let bookContext = BookContext(
            bookUrl: bookUrl,
            name: bookName,
            author: bookAuthor,
            kind: bookKind,
            tocUrl: tocUrl,
            bookVariables: bookVariables
        )

        ParserLog.debug(
            "BookChapterParser",
            "parse start source=\(bookSource.bookSourceName) bookUrl=\(bookUrl) baseUrl=\(baseUrl)"
        )

        // 提取章节元素列表
        guard var listRule = rule.chapterList, !listRule.isEmpty else {
            return ([], [])
        }

        // 处理 chapterList 规则前缀（对应 legado 的 `-` 反序、`+` 保持顺序前缀）
        var reverseChapters = false
        if listRule.hasPrefix("-") {
            reverseChapters = true
            listRule = String(listRule.dropFirst())
        } else if listRule.hasPrefix("+") {
            listRule = String(listRule.dropFirst())
        }

        // 检测内容类型：JSON 响应使用 JSONPath 直接解析，HTML 响应使用 CSS/XPath 元素解析
        let trimmedHtml = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentIsJson = trimmedHtml.hasPrefix("{") || trimmedHtml.hasPrefix("[")
        let listRuleType = RuleAnalyzer.ruleType(for: listRule)
        let nextUrlRule = rule.nextTocUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasFormatJs = !(rule.formatJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let canUseAnalyzerFreeJSONPath = contentIsJson
            && listRuleType != .css
            && listRuleType != .xpath
            && nextUrlRule.isEmpty
            && !hasFormatJs
            && canUseDirectJSONFieldPath(rule)
            && canExtractJSONItemsWithoutAnalyzer(listRule)
        let canUseAnalyzerFreeHTMLPath = !contentIsJson
            && nextUrlRule.isEmpty
            && !hasFormatJs
            && canUseDirectJSONFieldPath(rule)
            && canExtractHTMLItemsWithoutAnalyzer(listRule)

        injectBookContext(bookContext, into: nil, variableStore: runtimeStore)

        if canUseAnalyzerFreeJSONPath {
            let chapters = try parseChaptersFromJSON(
                content: html,
                listRule: listRule,
                tocRule: rule,
                bookUrl: bookUrl,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                analyzer: nil,
                bookContext: bookContext
            )
            ParserLog.debug("BookChapterParser", "json chapters count=\(chapters.count) analyzer=skipped")
            return (chapters, [])
        }

        if canUseAnalyzerFreeHTMLPath,
           let jsItems = try extractHTMLJavaScriptChapterItems(
                content: html,
                listRule: listRule,
                analyzer: nil
           ),
           !jsItems.isEmpty {
            let chapters = parseChapterItems(
                jsItems,
                tocRule: rule,
                bookUrl: bookUrl,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                bookContext: bookContext
            )
            let finalChapters = reverseChapters ? chapters.reversed() : chapters
            ParserLog.debug(
                "BookChapterParser",
                "js chapters count=\(finalChapters.count) reversed=\(reverseChapters) nextCount=0 analyzer=skipped"
            )
            return (Array(finalChapters), [])
        }

        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: runtimeStore)
        injectBookContext(bookContext, into: analyzer, variableStore: runtimeStore)

        // 提取下一页目录 URL
        var nextTocUrls: [String] = []
        if !nextUrlRule.isEmpty {
            let rawValues = try analyzer.getStringList(content: html, rule: nextUrlRule, isUrl: false)
            nextTocUrls = rawValues.flatMap {
                AnalyzeUrl.postProcessExtractedURLs($0, baseUrl: baseUrl, variableStore: runtimeStore)
            }
            ParserLog.debug(
                "BookChapterParser",
                "nextToc raw=\(rawValues.map { ParserLog.preview($0, limit: 80) }) cleaned=\(nextTocUrls.map { ParserLog.preview($0, limit: 80) })"
            )
        }

        if contentIsJson && listRuleType != .css && listRuleType != .xpath {
            if shouldUseJSONShortcut(for: listRule) {
                let chapters = try parseChaptersFromJSON(
                    content: html,
                    listRule: RuleAnalyzer.cleanRule(listRule),
                    tocRule: rule,
                    bookUrl: bookUrl,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: runtimeStore,
                    analyzer: analyzer,
                    bookContext: bookContext
                )
                ParserLog.debug("BookChapterParser", "json chapters count=\(chapters.count)")
                return (chapters, nextTocUrls)
            }

            let chapters = try parseChaptersFromJSON(
                content: html,
                listRule: listRule,
                tocRule: rule,
                bookUrl: bookUrl,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                analyzer: analyzer,
                bookContext: bookContext
            )
            ParserLog.debug("BookChapterParser", "json chapters count=\(chapters.count)")
            return (chapters, nextTocUrls)
        }

        if let regexPattern = allInOneRegexPattern(from: listRule) {
            let chapters = try parseChaptersFromRegexAllInOne(
                content: html,
                pattern: regexPattern,
                tocRule: rule,
                bookUrl: bookUrl,
                baseUrl: baseUrl
            )
            ParserLog.debug("BookChapterParser", "regex all-in-one chapters count=\(chapters.count)")
            if !chapters.isEmpty {
                let finalChapters = reverseChapters ? chapters.reversed() : chapters
                let formattedChapters = applyFormatJsIfNeeded(Array(finalChapters), tocRule: rule, analyzer: analyzer)
                ParserLog.debug(
                    "BookChapterParser",
                    "parse done count=\(formattedChapters.count) reversed=\(reverseChapters) nextCount=\(nextTocUrls.count)"
                )
                return (formattedChapters, nextTocUrls)
            }
        }

        do {
            if let jsItems = try extractHTMLJavaScriptChapterItems(
                content: html,
                listRule: listRule,
                analyzer: analyzer
            ), !jsItems.isEmpty {
                let chapters = parseChapterItems(
                    jsItems,
                    tocRule: rule,
                    bookUrl: bookUrl,
                    baseUrl: baseUrl,
                    bookSource: bookSource,
                    variableStore: runtimeStore,
                    bookContext: bookContext
                )
                let finalChapters = reverseChapters ? chapters.reversed() : chapters
                let formattedChapters = applyFormatJsIfNeeded(Array(finalChapters), tocRule: rule, analyzer: analyzer)
                ParserLog.debug(
                    "BookChapterParser",
                    "js chapters count=\(formattedChapters.count) reversed=\(reverseChapters) nextCount=\(nextTocUrls.count)"
                )
                return (formattedChapters, nextTocUrls)
            }
        } catch {
            ParserLog.debug(
                "BookChapterParser",
                "html js extraction failed rule=\(ParserLog.preview(listRule)) error=\(error.localizedDescription)"
            )
        }

        if listRuleType == .javascript || RuleAnalyzer.extractJS(listRule).1 != nil || listRule.contains("<js>") {
            if let structuredValue = try? analyzer.getValue(content: html, rule: listRule) {
                let jsItems = flattenMeaningfulJSChapterItems(structuredValue, originalContent: html)
                if !jsItems.isEmpty {
                    let chapters = parseChapterItems(
                        jsItems,
                        tocRule: rule,
                        bookUrl: bookUrl,
                        baseUrl: baseUrl,
                        bookSource: bookSource,
                        variableStore: runtimeStore,
                        bookContext: bookContext
                    )
                    let finalChapters = reverseChapters ? chapters.reversed() : chapters
                    let formattedChapters = applyFormatJsIfNeeded(Array(finalChapters), tocRule: rule, analyzer: analyzer)
                    ParserLog.debug(
                        "BookChapterParser",
                        "structured js chapters count=\(formattedChapters.count) reversed=\(reverseChapters) nextCount=\(nextTocUrls.count)"
                    )
                    return (formattedChapters, nextTocUrls)
                }
            } else {
                ParserLog.debug(
                    "BookChapterParser",
                    "structured js evaluation failed rule=\(ParserLog.preview(listRule))"
                )
            }
        }

        let elements: [Element]
        do {
            elements = try analyzer.getElements(content: html, rule: listRule)
        } catch {
            ParserLog.debug(
                "BookChapterParser",
                "getElements failed rule=\(ParserLog.preview(listRule)) error=\(error.localizedDescription)"
            )
            elements = []
        }
        ParserLog.debug("BookChapterParser", "html elements count=\(elements.count)")

        let chapters = elements.enumerated().compactMap { (index, element) -> BookChapter? in
            do {
                let chapterStore = runtimeStore.makeChildStore(
                    writeScope: .chapter,
                    inheritBookScope: true,
                    resetRuleData: true
                )
                let chapterAnalyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: chapterStore)
                injectBookContext(bookContext, into: chapterAnalyzer, variableStore: chapterStore)
                let scopedContext = try DetachedHTMLElementRuleContext(element: element, analyzer: chapterAnalyzer, baseUrl: baseUrl)
                defer {
                    scopedContext.cleanup()
                }
                var chapter = BookChapter(
                    index: index,
                    baseUrl: baseUrl,
                    bookUrl: bookUrl
                )
                var rawUrl = ""

                if let nameRule = rule.chapterName, !nameRule.isEmpty {
                    chapter.title = try scopedContext.getString(rule: nameRule)
                }

                if let urlRule = rule.chapterUrl, !urlRule.isEmpty {
                    rawUrl = try scopedContext.getString(rule: urlRule, isUrl: true)
                    chapter.url = sanitizedChapterURL(rawUrl, baseUrl: baseUrl)
                }

                if let isVolumeRule = rule.isVolume, !isVolumeRule.isEmpty {
                    let value = try scopedContext.getString(rule: isVolumeRule)
                    chapter.isVolume = parseBoolValue(value)
                }

                if let isVipRule = rule.isVip, !isVipRule.isEmpty {
                    let value = try scopedContext.getString(rule: isVipRule)
                    chapter.isVip = parseBoolValue(value)
                }

                if let isPayRule = rule.isPay, !isPayRule.isEmpty {
                    let value = try scopedContext.getString(rule: isPayRule)
                    chapter.isPay = parseBoolValue(value)
                }

                if let updateTimeRule = rule.updateTime, !updateTimeRule.isEmpty {
                    chapter.updateTime = try scopedContext.getString(rule: updateTimeRule)
                }

                if shouldFallbackChapterURL(
                    configuredRule: rule.chapterUrl,
                    currentURL: chapter.url,
                    rawURL: rawUrl,
                    isVolume: chapter.isVolume
                ) {
                    chapter.url = fallbackChapterURL(
                        existingURL: chapter.url,
                        title: chapter.title,
                        isVolume: chapter.isVolume,
                        index: index,
                        baseUrl: baseUrl,
                        variables: chapter.variables
                    )
                    ParserLog.debug(
                        "BookChapterParser",
                        "html[\(index)] empty url fallback=\(ParserLog.preview(chapter.url)) isVolume=\(chapter.isVolume)"
                    )
                }
                chapter.sourceVariables = chapterStore.snapshot(for: .source, includeInherited: false)
                chapter.bookVariables = chapterStore.snapshot(for: .book, includeInherited: false)
                chapter.chapterVariables = chapterStore.snapshot(for: .chapter, includeInherited: false)
                chapter.variables = chapterStore.snapshot(for: .chapter, includeInherited: true)

                ParserLog.debug(
                    "BookChapterParser",
                    "html[\(index)] title=\(ParserLog.preview(chapter.title)) rawUrl=\(ParserLog.preview(rawUrl)) url=\(ParserLog.preview(chapter.url))"
                )

                guard shouldKeepChapter(chapter, configuredRule: rule.chapterUrl) else { return nil }
                return chapter
            } catch {
                ParserLog.debug(
                    "BookChapterParser",
                    "html[\(index)] skipped error=\(error.localizedDescription)"
                )
                return nil
            }
        }

        let finalChapters = reverseChapters ? chapters.reversed() : chapters
        var formattedChapters = applyFormatJsIfNeeded(Array(finalChapters), tocRule: rule, analyzer: analyzer)
        if let fallbackChapters = try heuristicChapterLinks(
                html: html,
                bookSource: bookSource,
                tocRule: rule,
                bookUrl: bookUrl,
                baseUrl: baseUrl,
                variableStore: runtimeStore,
                bookContext: bookContext
           ),
           !fallbackChapters.isEmpty,
           shouldPreferHeuristicChapters(
                fallbackChapters,
                over: formattedChapters,
                baseUrl: baseUrl,
                bookUrl: bookUrl
           ) {
            formattedChapters = fallbackChapters
            ParserLog.debug("BookChapterParser", "fallback chapter links count=\(formattedChapters.count)")
        }
        ParserLog.debug(
            "BookChapterParser",
            "parse done count=\(formattedChapters.count) reversed=\(reverseChapters) nextCount=\(nextTocUrls.count)"
        )
        return (formattedChapters, nextTocUrls)
    }

    // MARK: - JSON 目录解析

    /// 从 JSON 响应中按 JSONPath 规则提取章节列表（用于 API 类型书源）
    private static func parseChaptersFromJSON(
        content: String,
        listRule: String,
        tocRule: TocRule,
        bookUrl: String,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        analyzer: AnalyzeRule?,
        bookContext: BookContext
    ) throws -> [BookChapter] {
        var items = try extractChapterItems(
            content: content,
            listRule: listRule,
            bookSource: bookSource,
            baseUrl: baseUrl,
            variableStore: variableStore,
            analyzer: analyzer
        )

        // 规则指向嵌套数组时递归展开，直到元素不再是纯数组为止
        while items.count == 1, let nested = items[0] as? [Any] {
            items = nested
        }

        guard !items.isEmpty else { return [] }
        return parseChapterItems(
            items,
            tocRule: tocRule,
            bookUrl: bookUrl,
            baseUrl: baseUrl,
            bookSource: bookSource,
            variableStore: variableStore,
            bookContext: bookContext
        )
    }

    private static func parseChapterItems(
        _ items: [Any],
        tocRule: TocRule,
        bookUrl: String,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        bookContext: BookContext
    ) -> [BookChapter] {
        var chapters: [BookChapter] = []
        chapters.reserveCapacity(items.count)
        let useDirectFieldPath = canUseDirectJSONFieldPath(tocRule)
        let inheritedSourceVariables = variableStore.snapshot(for: .source, includeInherited: false)
        let inheritedBookVariables = variableStore.snapshot(for: .book, includeInherited: false)
        let inheritedVariables = variableStore.snapshot(for: .book, includeInherited: true)

        for (index, item) in items.enumerated() {
            ParserLog.debug("BookChapterParser", "json[\(index)] begin")
            let itemJSON = jsonString(from: item)
            let chapterStore = variableStore.makeChildStore(
                writeScope: .chapter,
                inheritBookScope: true,
                resetRuleData: true
            )
            mergeTopLevelJSONScalars(from: itemJSON, into: chapterStore, scope: .chapter)
            let itemAnalyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: chapterStore)
            injectBookContext(bookContext, into: itemAnalyzer, variableStore: chapterStore)
            var rawURL = ""

            if useDirectFieldPath {
                var chapter = BookChapter(index: index, baseUrl: baseUrl, bookUrl: bookUrl)

                if let nameRule = tocRule.chapterName, !nameRule.isEmpty {
                    chapter.title = directJSONFieldValue(
                        item,
                        rule: nameRule,
                        isUrl: false,
                        baseUrl: baseUrl,
                        variableStore: chapterStore,
                        analyzer: itemAnalyzer,
                        itemJSON: itemJSON
                    ) ?? ""
                }

                if let urlRule = tocRule.chapterUrl, !urlRule.isEmpty {
                    rawURL = directJSONFieldValue(
                        item,
                        rule: urlRule,
                        isUrl: true,
                        baseUrl: baseUrl,
                        variableStore: chapterStore,
                        analyzer: itemAnalyzer,
                        itemJSON: itemJSON
                    ) ?? ""
                    chapter.url = sanitizedChapterURL(rawURL, baseUrl: baseUrl)
                    chapter.url = recoverLiteralJSONChapterURLIfNeeded(
                        currentURL: chapter.url,
                        rule: urlRule,
                        itemJSON: itemJSON,
                        analyzer: itemAnalyzer,
                        baseUrl: baseUrl
                    )
                }

                if let isVolumeRule = tocRule.isVolume, !isVolumeRule.isEmpty {
                    chapter.isVolume = parseBoolValue(
                        directJSONFieldValue(
                            item,
                            rule: isVolumeRule,
                            isUrl: false,
                            baseUrl: baseUrl,
                            variableStore: chapterStore,
                            analyzer: itemAnalyzer,
                            itemJSON: itemJSON
                        ) ?? ""
                    )
                }

                if let isVipRule = tocRule.isVip, !isVipRule.isEmpty {
                    chapter.isVip = parseBoolValue(
                        directJSONFieldValue(
                            item,
                            rule: isVipRule,
                            isUrl: false,
                            baseUrl: baseUrl,
                            variableStore: chapterStore,
                            analyzer: itemAnalyzer,
                            itemJSON: itemJSON
                        ) ?? ""
                    )
                }

                if let isPayRule = tocRule.isPay, !isPayRule.isEmpty {
                    chapter.isPay = parseBoolValue(
                        directJSONFieldValue(
                            item,
                            rule: isPayRule,
                            isUrl: false,
                            baseUrl: baseUrl,
                            variableStore: chapterStore,
                            analyzer: itemAnalyzer,
                            itemJSON: itemJSON
                        ) ?? ""
                    )
                }

                if let updateTimeRule = tocRule.updateTime, !updateTimeRule.isEmpty {
                    chapter.updateTime = directJSONFieldValue(
                        item,
                        rule: updateTimeRule,
                        isUrl: false,
                        baseUrl: baseUrl,
                        variableStore: chapterStore,
                        analyzer: itemAnalyzer,
                        itemJSON: itemJSON
                    )
                }

                let inheritedChapterVariables = chapterStore.snapshot(for: .chapter, includeInherited: true)

                if shouldFallbackChapterURL(
                    configuredRule: tocRule.chapterUrl,
                    currentURL: chapter.url,
                    rawURL: rawURL,
                    isVolume: chapter.isVolume
                ) {
                    chapter.url = fallbackChapterURL(
                        existingURL: chapter.url,
                        title: chapter.title,
                        isVolume: chapter.isVolume,
                        index: index,
                        baseUrl: baseUrl,
                        variables: inheritedChapterVariables
                    )
                    ParserLog.debug(
                        "BookChapterParser",
                        "json[\(index)] empty url fallback=\(ParserLog.preview(chapter.url)) isVolume=\(chapter.isVolume)"
                    )
                }

                chapter.sourceVariables = chapterStore.snapshot(for: .source, includeInherited: false)
                chapter.bookVariables = chapterStore.snapshot(for: .book, includeInherited: false)
                chapter.chapterVariables = chapterStore.snapshot(for: .chapter, includeInherited: false)
                chapter.variables = inheritedChapterVariables

                ParserLog.debug(
                    "BookChapterParser",
                    "json[\(index)] title=\(ParserLog.preview(chapter.title)) url=\(ParserLog.preview(chapter.url)) item=\(ParserLog.preview(itemJSON))"
                )

                guard shouldKeepChapter(chapter, configuredRule: tocRule.chapterUrl) else { continue }
                chapters.append(chapter)
                ParserLog.debug("BookChapterParser", "json[\(index)] appended")
                continue
            }

            var chapter = BookChapter(index: index, baseUrl: baseUrl, bookUrl: bookUrl)

            if let nameRule = tocRule.chapterName, !nameRule.isEmpty {
                chapter.title = jsonField(analyzer: itemAnalyzer, item: item, itemJSON: itemJSON, rule: nameRule) ?? ""
            }

            if let urlRule = tocRule.chapterUrl, !urlRule.isEmpty {
                rawURL = jsonField(analyzer: itemAnalyzer, item: item, itemJSON: itemJSON, rule: urlRule, isUrl: true) ?? ""
                chapter.url = sanitizedChapterURL(rawURL, baseUrl: baseUrl)
                chapter.url = recoverLiteralJSONChapterURLIfNeeded(
                    currentURL: chapter.url,
                    rule: urlRule,
                    itemJSON: itemJSON,
                    analyzer: itemAnalyzer,
                    baseUrl: baseUrl
                )
            }

            if let isVolumeRule = tocRule.isVolume, !isVolumeRule.isEmpty {
                chapter.isVolume = parseBoolValue(
                    jsonField(analyzer: itemAnalyzer, item: item, itemJSON: itemJSON, rule: isVolumeRule) ?? ""
                )
            }

            if let isVipRule = tocRule.isVip, !isVipRule.isEmpty {
                chapter.isVip = parseBoolValue(
                    jsonField(analyzer: itemAnalyzer, item: item, itemJSON: itemJSON, rule: isVipRule) ?? ""
                )
            }

            if let isPayRule = tocRule.isPay, !isPayRule.isEmpty {
                chapter.isPay = parseBoolValue(
                    jsonField(analyzer: itemAnalyzer, item: item, itemJSON: itemJSON, rule: isPayRule) ?? ""
                )
            }

            if let updateTimeRule = tocRule.updateTime, !updateTimeRule.isEmpty {
                chapter.updateTime = jsonField(analyzer: itemAnalyzer, item: item, itemJSON: itemJSON, rule: updateTimeRule)
            }

            let inheritedChapterVariables = chapterStore.snapshot(for: .chapter, includeInherited: true)
            if shouldFallbackChapterURL(
                configuredRule: tocRule.chapterUrl,
                currentURL: chapter.url,
                rawURL: rawURL,
                isVolume: chapter.isVolume
            ) {
                chapter.url = fallbackChapterURL(
                    existingURL: chapter.url,
                    title: chapter.title,
                    isVolume: chapter.isVolume,
                    index: index,
                    baseUrl: baseUrl,
                    variables: inheritedChapterVariables
                )
                ParserLog.debug(
                    "BookChapterParser",
                    "json[\(index)] empty url fallback=\(ParserLog.preview(chapter.url)) isVolume=\(chapter.isVolume)"
                )
            }
            chapter.sourceVariables = chapterStore.snapshot(for: .source, includeInherited: false)
            chapter.bookVariables = chapterStore.snapshot(for: .book, includeInherited: false)
            chapter.chapterVariables = chapterStore.snapshot(for: .chapter, includeInherited: false)
            chapter.variables = inheritedChapterVariables

            ParserLog.debug(
                "BookChapterParser",
                "json[\(index)] title=\(ParserLog.preview(chapter.title)) url=\(ParserLog.preview(chapter.url)) item=\(ParserLog.preview(itemJSON))"
            )

            guard shouldKeepChapter(chapter, configuredRule: tocRule.chapterUrl) else { continue }
            chapters.append(chapter)
            ParserLog.debug("BookChapterParser", "json[\(index)] appended")
        }

        return chapters
    }

    private static func canUseDirectJSONFieldPath(_ tocRule: TocRule) -> Bool {
        [
            tocRule.chapterName,
            tocRule.chapterUrl,
            tocRule.isVolume,
            tocRule.isVip,
            tocRule.isPay,
            tocRule.updateTime
        ].allSatisfy { rule in
            guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return true
            }
            if RuleAnalyzer.extractJS(rule).1 != nil || rule.contains("<js>") {
                return false
            }
            guard shouldUseJSONShortcut(for: rule) else {
                return false
            }

            switch RuleAnalyzer.ruleType(for: rule) {
            case .css, .xpath, .javascript, .regex:
                return false
            case .jsonPath, .default:
                return true
            }
        }
    }

    private static func jsonField(
        analyzer: AnalyzeRule,
        item: Any,
        itemJSON: String,
        rule: String,
        isUrl: Bool = false
    ) -> String? {
        if let jsDrivenValue = evaluateJSONItemRule(
            analyzer: analyzer,
            item: item,
            itemJSON: itemJSON,
            rule: rule,
            isUrl: isUrl
        ), !jsDrivenValue.isEmpty {
            return finalizeJSONFieldValue(
                jsDrivenValue,
                analyzer: analyzer,
                itemJSON: itemJSON,
                isUrl: isUrl
            )
        }

        if let directValue = jsonFieldFromObject(item, rule: rule, isUrl: isUrl, analyzer: analyzer),
           !directValue.isEmpty {
            return finalizeJSONFieldValue(
                directValue,
                analyzer: analyzer,
                itemJSON: itemJSON,
                isUrl: isUrl
            )
        }
        if let literalValue = renderJSONLiteralRule(
            item: item,
            itemJSON: itemJSON,
            rule: rule,
            analyzer: analyzer
        ), !literalValue.isEmpty {
            return finalizeJSONFieldValue(
                literalValue,
                analyzer: analyzer,
                itemJSON: itemJSON,
                isUrl: isUrl
            )
        }
        guard let fallbackValue = try? analyzer.getString(content: itemJSON, rule: rule, isUrl: false),
              !fallbackValue.isEmpty else {
            return nil
        }
        return finalizeJSONFieldValue(
            fallbackValue,
            analyzer: analyzer,
            itemJSON: itemJSON,
            isUrl: isUrl
        )
    }

    private static func jsonString(from item: Any) -> String {
        if JSONSerialization.isValidJSONObject(item),
           let data = try? JSONSerialization.data(withJSONObject: item),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return JSONPathParser.stringify(item) ?? "\(item)"
    }

    private static func parseChaptersFromRegexAllInOne(
        content: String,
        pattern: String,
        tocRule: TocRule,
        bookUrl: String,
        baseUrl: String
    ) throws -> [BookChapter] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: content, range: range)

        return matches.enumerated().compactMap { index, match in
            var chapter = BookChapter(index: index, baseUrl: baseUrl, bookUrl: bookUrl)
            var rawURL = ""

            if let nameRule = tocRule.chapterName, !nameRule.isEmpty {
                chapter.title = renderRegexMatchRule(nameRule, match: match, content: nsContent)
            }

            if let urlRule = tocRule.chapterUrl, !urlRule.isEmpty {
                rawURL = renderRegexMatchRule(urlRule, match: match, content: nsContent)
                chapter.url = sanitizedChapterURL(
                    AnalyzeUrl.postProcessExtractedURL(rawURL, baseUrl: baseUrl),
                    baseUrl: baseUrl
                )
            }

            if let isVolumeRule = tocRule.isVolume, !isVolumeRule.isEmpty {
                chapter.isVolume = parseBoolValue(renderRegexMatchRule(isVolumeRule, match: match, content: nsContent))
            }

            if let isVipRule = tocRule.isVip, !isVipRule.isEmpty {
                chapter.isVip = parseBoolValue(renderRegexMatchRule(isVipRule, match: match, content: nsContent))
            }

            if let isPayRule = tocRule.isPay, !isPayRule.isEmpty {
                chapter.isPay = parseBoolValue(renderRegexMatchRule(isPayRule, match: match, content: nsContent))
            }

            if shouldFallbackChapterURL(
                configuredRule: tocRule.chapterUrl,
                currentURL: chapter.url,
                rawURL: rawURL,
                isVolume: chapter.isVolume
            ) {
                chapter.url = fallbackChapterURL(
                    existingURL: chapter.url,
                    title: chapter.title,
                    isVolume: chapter.isVolume,
                    index: index,
                    baseUrl: baseUrl,
                    variables: chapter.variables
                )
            }

            guard shouldKeepChapter(chapter, configuredRule: tocRule.chapterUrl) else {
                return nil
            }
            return chapter
        }
    }

    private static func renderRegexMatchRule(_ rule: String, match: NSTextCheckingResult, content: NSString) -> String {
        guard !rule.isEmpty else { return "" }

        var rendered = rule
        for index in stride(from: match.numberOfRanges - 1, through: 0, by: -1) {
            let token = "$\(index)"
            let replacement: String
            let captureRange = match.range(at: index)
            if captureRange.location != NSNotFound {
                replacement = content.substring(with: captureRange)
            } else {
                replacement = ""
            }
            rendered = rendered.replacingOccurrences(of: token, with: replacement)
        }
        return rendered
    }

    // MARK: - 工具方法

    /// 将多页目录合并（去重并按顺序排列）
    public static func mergeChapters(_ chapterLists: [[BookChapter]]) -> [BookChapter] {
        var seen: Set<String> = []
        var merged: [BookChapter] = []
        var index = 0

        for list in chapterLists {
            for var chapter in list {
                let key = deduplicationKey(for: chapter)
                if !seen.contains(key) {
                    seen.insert(key)
                    chapter.index = index
                    index += 1
                    merged.append(chapter)
                }
            }
        }
        return merged
    }

    // MARK: - 私有方法

    private static func applyFormatJsIfNeeded(
        _ chapters: [BookChapter],
        tocRule: TocRule,
        analyzer: AnalyzeRule
    ) -> [BookChapter] {
        guard let formatJs = tocRule.formatJs, !formatJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return chapters
        }
        return applyFormatJs(formatJs, to: chapters, analyzer: analyzer)
    }

    /// 对章节标题执行 `formatJs` 格式化。
    private static func applyFormatJs(
        _ js: String,
        to chapters: [BookChapter],
        analyzer: AnalyzeRule
    ) -> [BookChapter] {
        var result = chapters

        for (index, chapter) in chapters.enumerated() {
            let script = """
            var index = \(index + 1);
            var title = \(escapeJSString(chapter.title));
            var chapter = {
                url: \(escapeJSString(chapter.url)),
                title: title,
                isVolume: \(chapter.isVolume),
                isVip: \(chapter.isVip),
                isPay: \(chapter.isPay)
            };
            \(js)
            """

            do {
                let newTitle = try analyzer.evaluateJS(script: script, result: chapter.title)
                if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result[index].title = newTitle
                }
            } catch {
                ParserLog.debug(
                    "BookChapterParser",
                    "formatJs failed index=\(index) title=\(ParserLog.preview(chapter.title)) error=\(error.localizedDescription)"
                )
            }
        }

        return result
    }

    /// 转义字符串，使其可安全内嵌到 JS 字面量。
    private static func escapeJSString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func parseBoolValue(_ value: String) -> Bool {
        let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.isEmpty { return false }
        if lower == "true" || lower == "1" || lower == "yes" { return true }
        // 非空字符串通常也视为 true（某些书源用 class 名来标识）
        return !lower.isEmpty && lower != "false" && lower != "0" && lower != "no"
    }

    private static func shouldUseJSONShortcut(for rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let splitResult = RuleAnalyzer.splitRulesWithOperator(trimmed)
        return splitResult.operator.isEmpty
            && !lower.contains("@js:")
            && !trimmed.contains("<js>")
            && !RuleAnalyzer.containsTemplate(trimmed)
            && !trimmed.contains("##")
    }

    private static func extractChapterItems(
        content: String,
        listRule: String,
        bookSource: BookSource,
        baseUrl: String,
        variableStore: ParserVariableStore,
        analyzer: AnalyzeRule?
    ) throws -> [Any] {
        let trimmedListRule = listRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, embeddedJS) = RuleAnalyzer.extractJS(trimmedListRule)
        let splitResult: RuleAnalyzer.SplitRuleResult = embeddedJS == nil
            ? RuleAnalyzer.splitRulesWithOperator(trimmedListRule)
            : ("", [trimmedListRule])
        if !splitResult.operator.isEmpty {
            switch splitResult.operator {
            case "||":
                for part in splitResult.parts {
                    let values = try extractChapterItems(
                        content: content,
                        listRule: part,
                        bookSource: bookSource,
                        baseUrl: baseUrl,
                        variableStore: variableStore,
                        analyzer: analyzer
                    )
                    if !values.isEmpty {
                        return values
                    }
                }
                return []
            case "&&", "@@":
                return try splitResult.parts.flatMap {
                    try extractChapterItems(
                        content: content,
                        listRule: $0,
                        bookSource: bookSource,
                        baseUrl: baseUrl,
                        variableStore: variableStore,
                        analyzer: analyzer
                    )
                }
            case "%%":
                let groups = try splitResult.parts.map {
                    try extractChapterItems(
                        content: content,
                        listRule: $0,
                        bookSource: bookSource,
                        baseUrl: baseUrl,
                        variableStore: variableStore,
                        analyzer: analyzer
                    )
                }
                return interleaveChapterItems(groups)
            default:
                break
            }
        }

        if let nativeItems = nativeJSONJavaScriptChapterItems(
            content: content,
            listRule: listRule
        ), !nativeItems.isEmpty {
            ParserLog.debug("BookChapterParser", "native js chapter items count=\(nativeItems.count)")
            return nativeItems
        }

        if shouldUseJSONShortcut(for: listRule) {
            return try jsonObjects(from: content, rule: listRule)
        }

        let (mainRule, jsCode) = RuleAnalyzer.extractJS(listRule)
        let prefixRule = mainRule?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var items: [Any] = []

        if !prefixRule.isEmpty {
            items = try jsonObjects(from: content, rule: prefixRule)
        } else if let rootObject = try? JSONSerialization.jsonObject(with: Data(content.utf8)) {
            items = [rootObject]
        }

        if let jsCode, !jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let analyzer else {
                throw ParserError.parsingFailed("JSON 目录规则需要 AnalyzeRule，但当前快路径未创建分析器")
            }
            analyzer.updateContextContent(content)
            let fallbackResult = jsonString(from: items)

            // Android 侧大量 JSON 目录脚本默认把 `result` 当原始响应字符串再自行 `JSON.parse(result)`，
            // 也有一部分脚本直接把 `result` 当对象使用。这里按“字符串优先，对象兜底”两段执行，
            // 避免 iOS 只喂对象时退化成单条根对象目录。
            let rawStringItems = try evaluateSerializedJSChapterItems(
                analyzer: analyzer,
                script: jsCode,
                result: content,
                originalContent: content
            )
            if !rawStringItems.isEmpty {
                return rawStringItems
            }

            return try evaluateSerializedJSChapterItems(
                analyzer: analyzer,
                script: jsCode,
                resultObject: items,
                fallbackResult: fallbackResult
            )
        }

        return items
    }

    private static func jsonObjects(from content: String, rule: String) throws -> [Any] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanedRule.isEmpty else { return [] }

        for candidateRule in jsonRuleCandidates(for: cleanedRule) {
            if let objects = try? JSONPathParser.getObjects(from: content, rule: candidateRule),
               !objects.isEmpty {
                return objects
            }
        }

        return try JSONPathParser.getObjects(from: content, rule: cleanedRule)
    }

    private static func jsonRuleCandidates(for rule: String) -> [String] {
        guard !(rule.hasPrefix("$") || rule.hasPrefix("@") || rule.hasPrefix(".")) else {
            return [rule]
        }
        return ["$.\(rule)", rule]
    }

    private static func canExtractJSONItemsWithoutAnalyzer(_ listRule: String) -> Bool {
        let trimmedListRule = listRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, embeddedJS) = RuleAnalyzer.extractJS(trimmedListRule)
        let splitResult: RuleAnalyzer.SplitRuleResult = embeddedJS == nil
            ? RuleAnalyzer.splitRulesWithOperator(trimmedListRule)
            : ("", [trimmedListRule])

        if !splitResult.operator.isEmpty {
            return splitResult.parts.allSatisfy(canExtractJSONItemsWithoutAnalyzer)
        }

        if shouldUseJSONShortcut(for: trimmedListRule) {
            return true
        }

        let (_, jsCode) = RuleAnalyzer.extractJS(trimmedListRule)
        guard let jsCode, !jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return supportsNativeJSONJavaScriptChapterItems(script: jsCode)
    }

    private static func canExtractHTMLItemsWithoutAnalyzer(_ listRule: String) -> Bool {
        let trimmedListRule = listRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, embeddedJS) = RuleAnalyzer.extractJS(trimmedListRule)
        let splitResult: RuleAnalyzer.SplitRuleResult = embeddedJS == nil
            ? RuleAnalyzer.splitRulesWithOperator(trimmedListRule)
            : ("", [trimmedListRule])

        if !splitResult.operator.isEmpty {
            return splitResult.parts.allSatisfy(canExtractHTMLItemsWithoutAnalyzer)
        }

        let (_, jsCode) = RuleAnalyzer.extractJS(trimmedListRule)
        guard let jsCode, !jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return supportsNativeHTMLJavaScriptChapterItems(script: jsCode)
    }

    private static func extractHTMLJavaScriptChapterItems(
        content: String,
        listRule: String,
        analyzer: AnalyzeRule?
    ) throws -> [Any]? {
        let trimmedRule = listRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, embeddedJS) = RuleAnalyzer.extractJS(trimmedRule)
        let ruleType = RuleAnalyzer.ruleType(for: trimmedRule)
        guard ruleType == .javascript || embeddedJS != nil || trimmedRule.contains("<js>") else {
            return nil
        }

        if let nativeItems = try nativeHTMLJavaScriptChapterItems(
            content: content,
            listRule: listRule
        ), !nativeItems.isEmpty {
            ParserLog.debug("BookChapterParser", "native html js chapter items count=\(nativeItems.count)")
            return nativeItems
        }

        guard let analyzer else {
            throw ParserError.parsingFailed("HTML 目录规则需要 AnalyzeRule，但当前快路径未创建分析器")
        }

        analyzer.updateContextContent(content)
        if let jsCode = embeddedJS {
            let mainRule = RuleAnalyzer.extractJS(trimmedRule).0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resultObject: Any
            let fallbackResult: String
            if !mainRule.isEmpty,
               let elements = try? analyzer.getElements(content: content, rule: mainRule),
               !elements.isEmpty {
                let htmlList = elements.compactMap { try? $0.outerHtml() }
                resultObject = htmlList
                fallbackResult = htmlList.joined(separator: "\n")
            } else {
                resultObject = content
                fallbackResult = content
            }
            return try evaluateSerializedJSChapterItems(
                analyzer: analyzer,
                script: jsCode,
                resultObject: resultObject,
                fallbackResult: fallbackResult
            )
        }

        let jsCode = RuleAnalyzer.cleanRule(trimmedRule)
        return try evaluateSerializedJSChapterItems(
            analyzer: analyzer,
            script: jsCode,
            result: content,
            originalContent: content
        )
    }

    private static func nativeHTMLJavaScriptChapterItems(
        content: String,
        listRule: String
    ) throws -> [Any]? {
        let (_, jsCode) = RuleAnalyzer.extractJS(listRule)
        guard let jsCode, !jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard supportsNativeHTMLJavaScriptChapterItems(script: jsCode) else {
            return nil
        }

        if let items = try nativeHTMLSortedBase64ChapterItems(content: content, listRule: listRule, script: jsCode), !items.isEmpty {
            return items
        }

        if let items = try nativeHTMLSelectMapChapterItems(content: content, script: jsCode), !items.isEmpty {
            return items
        }

        if let items = try nativeHTMLSelectForEachChapterItems(content: content, script: jsCode), !items.isEmpty {
            return items
        }

        return nil
    }

    private static func renderJSONLiteralRule(
        item: Any? = nil,
        itemJSON: String,
        rule: String,
        analyzer: AnalyzeRule
    ) -> String? {
        ParserRuleRuntime.renderJSONLiteralRule(item: item, itemJSON: itemJSON, rule: rule, analyzer: analyzer)
    }

    private static func supportsNativeHTMLJavaScriptChapterItems(script: String) -> Bool {
        let trimmed = script.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let supportsJsoupMap = trimmed.contains("org.jsoup.Jsoup.parse(result)")
            && (trimmed.contains(".map(") || trimmed.contains("list.push({"))
            && trimmed.contains(".select(")
        let supportsSelectedElementsSort = trimmed.contains("result.sort(")
            && trimmed.contains("result.select(")
            && trimmed.contains("outerHtml().match(Regex_)")
        return supportsJsoupMap || supportsSelectedElementsSort
    }

    private static func nativeHTMLSelectMapChapterItems(
        content: String,
        script: String
    ) throws -> [[String: Any]]? {
        let pattern = #"org\.jsoup\.Jsoup\.parse\(result\)\.select\((['"])(.*?)\1\)(?:\.toArray\(\))?(?:\.sort\(\))?\.map\((\w+)\s*=>\s*\(\{([\s\S]*?)\}\)\)"#
        guard let match = firstRegexMatch(pattern: pattern, in: script),
              let selector = regexGroup(match, index: 2, in: script),
              let alias = regexGroup(match, index: 3, in: script),
              let objectBody = regexGroup(match, index: 4, in: script) else {
            return nil
        }

        let document = try SwiftSoup.parse(content)
        let elements = try document.select(selector).array()
        let properties = parseObjectLiteralProperties(objectBody)
        guard !properties.isEmpty else { return nil }

        return elements.map { renderHTMLElementObjectLiteral(properties, elementAlias: alias, element: $0) }
    }

    private static func nativeHTMLSortedBase64ChapterItems(
        content: String,
        listRule: String,
        script: String
    ) throws -> [[String: Any]]? {
        guard script.contains("result.sort("),
              script.contains("outerHtml().match(Regex_)"),
              script.contains("java.base64Decode"),
              let prefixRule = RuleAnalyzer.extractJS(listRule).0?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prefixRule.isEmpty else {
            return nil
        }

        let document = try SwiftSoup.parse(content)
        let containerElements = try document.select(prefixRule).array()
        guard !containerElements.isEmpty else { return nil }

        let attributeRegex = try NSRegularExpression(pattern: #"data-[A-Za-z0-9]+"#)
        guard let firstContainerHTML = try? containerElements[0].outerHtml(),
              let sortAttribute = preferredSortedBase64SortAttribute(
                from: firstContainerHTML,
                matches: firstMatches(for: attributeRegex, in: firstContainerHTML)
              ) else {
            return nil
        }

        let sortedContainers = containerElements.sorted { lhs, rhs in
            let left = Int((try? lhs.attr(sortAttribute)) ?? "") ?? 0
            let right = Int((try? rhs.attr(sortAttribute)) ?? "") ?? 0
            return left < right
        }

        var results: [[String: Any]] = []
        for container in sortedContainers {
            let anchors = try container.select("a").array()
            for anchor in anchors {
                guard let anchorHTML = try? anchor.outerHtml() else { continue }
                var attributes = firstMatches(for: attributeRegex, in: anchorHTML)
                if attributes.count < 2, let containerHTML = try? container.outerHtml() {
                    let containerAttributes = firstMatches(for: attributeRegex, in: containerHTML)
                    if let titleAttribute = attributes.first ?? containerAttributes.dropFirst().first,
                       let urlAttribute = attributes.dropFirst().first ?? containerAttributes.dropFirst(1).first {
                        attributes = [titleAttribute, urlAttribute]
                    }
                }
                guard attributes.count >= 2 else { continue }

                let titleAttribute = attributes[0]
                let urlAttribute = attributes[1]
                let rawTitle = ((try? anchor.attr(titleAttribute)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? ((try? anchor.text()) ?? "") : rawTitle
                let encodedURL = ((try? anchor.attr(urlAttribute)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let decodedURL = decodeBase64String(encodedURL)

                guard !title.isEmpty || !decodedURL.isEmpty else { continue }
                results.append([
                    "title": title,
                    "url": decodedURL
                ])
            }
        }

        return results.isEmpty ? nil : results
    }

    private static func nativeHTMLSelectForEachChapterItems(
        content: String,
        script: String
    ) throws -> [[String: Any]]? {
        let pattern = #"Array\.from\(\s*\w+\.select\((['"])(.*?)\1\)\s*\)\.forEach\(function\((\w+)\)\s*\{[\s\S]*?list\.push\(\{([\s\S]*?)\}\);?[\s\S]*?\}\);"#
        guard let match = firstRegexMatch(pattern: pattern, in: script),
              let selector = regexGroup(match, index: 2, in: script),
              let alias = regexGroup(match, index: 3, in: script),
              let objectBody = regexGroup(match, index: 4, in: script) else {
            return nil
        }

        let document = try SwiftSoup.parse(content)
        let elements = try document.select(selector).array()
        let properties = parseObjectLiteralProperties(objectBody)
        guard !properties.isEmpty else { return nil }

        return elements.map { renderHTMLElementObjectLiteral(properties, elementAlias: alias, element: $0) }
    }

    private static func interleaveChapterItems(_ groups: [[Any]]) -> [Any] {
        guard let maxCount = groups.map(\.count).max(), maxCount > 0 else { return [] }

        var combined: [Any] = []
        for index in 0..<maxCount {
            for group in groups where index < group.count {
                combined.append(group[index])
            }
        }
        return combined
    }

    private static func nativeJSONJavaScriptChapterItems(
        content: String,
        listRule: String
    ) -> [Any]? {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedContent.hasPrefix("{") || trimmedContent.hasPrefix("[") else { return nil }
        let (_, jsCode) = RuleAnalyzer.extractJS(listRule)
        guard let jsCode, !jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = trimmedContent.data(using: .utf8),
              let rootObject = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let nestedItems = nativeNestedBookChapterItems(rootObject: rootObject, script: jsCode),
           !nestedItems.isEmpty {
            return nestedItems
        }

        if let mappedItems = nativeMappedChapterItems(rootObject: rootObject, script: jsCode),
           !mappedItems.isEmpty {
            return mappedItems
        }

        return nil
    }

    private static func supportsNativeJSONJavaScriptChapterItems(script: String) -> Bool {
        (script.contains("JSON.parse(result).list") && script.contains(".bookChapters"))
            || (script.contains("JSON.parse(result).data") && script.contains(".chapters.map"))
    }

    private static func nativeNestedBookChapterItems(rootObject: Any, script: String) -> [Any]? {
        guard script.contains("JSON.parse(result).list"),
              script.contains(".bookChapters"),
              let root = rootObject as? [String: Any],
              let volumes = root["list"] as? [[String: Any]] else {
            return nil
        }

        let chapterPushSource = substring(after: ".bookChapters", in: script) ?? script
        guard let chapterObjectBody = firstObjectLiteralBody(
            after: "list.push({",
            in: chapterPushSource
        ) else {
            return nil
        }
        let chapterProperties = parseObjectLiteralProperties(chapterObjectBody)
        guard !chapterProperties.isEmpty else { return nil }

        let volumeNames = volumes.compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let distinctVolumeNames = Array(NSOrderedSet(array: volumeNames)) as? [String] ?? volumeNames
        let shouldEmitVolumes = script.contains("volume: true") && distinctVolumeNames.count >= 2
        let usesVolumeFilterFallback = script.contains("list.filter($=>!$.volume)") || script.contains("list.filter($ => !$.volume)")

        var items: [[String: Any]] = []
        for volume in volumes {
            let volumeName = (volume["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldEmitVolumes, !volumeName.isEmpty {
                items.append([
                    "name": "📖[\(volumeName)]📖",
                    "volume": true
                ])
            }

            guard let chapters = volume["bookChapters"] as? [[String: Any]] else { continue }
            for chapter in chapters {
                let context: [String: Any] = [
                    "$": chapter,
                    "chapter": chapter,
                    "volume": volume,
                    "V": volumeName
                ]
                let rendered = renderObjectLiteralProperties(chapterProperties, context: context)
                if !rendered.isEmpty {
                    items.append(rendered)
                }
            }
        }

        if usesVolumeFilterFallback && distinctVolumeNames.count < 2 {
            return items.filter { !asBool($0["volume"]) }
        }
        return items
    }

    private static func nativeMappedChapterItems(rootObject: Any, script: String) -> [Any]? {
        guard script.contains(".chapters.map"),
              script.contains("JSON.parse(result).data"),
              let root = rootObject as? [String: Any],
              let data = root["data"] as? [String: Any],
              let chapters = data["chapters"] as? [[String: Any]] else {
            return nil
        }

        let mapSource = substring(after: ".chapters.map", in: script) ?? script
        var renderedItems: [[String: Any]] = []
        renderedItems.reserveCapacity(chapters.count)
        let bid = data["book_id"]

        if let urlExpression = assignmentExpression(for: ".url", in: mapSource) {
            for chapter in chapters {
                var item = chapter
                var context: [String: Any] = [
                    "$": chapter,
                    "chapter": chapter,
                    "data": data
                ]
                if let bid {
                    context["bid"] = bid
                }
                let renderedURL = renderJavaScriptExpression(urlExpression, context: context)
                if !renderedURL.isEmpty {
                    item["url"] = renderedURL
                }
                renderedItems.append(item)
            }
            return renderedItems
        }

        return nil
    }

    private static func firstObjectLiteralBody(after marker: String, in script: String) -> String? {
        guard let markerRange = script.range(of: marker) else { return nil }
        let start = markerRange.upperBound
        var braceDepth = 1
        var quote: Character?
        var escaped = false
        var index = start

        while index < script.endIndex {
            let character = script[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else {
                switch character {
                case "\"", "'", "`":
                    quote = character
                case "{":
                    braceDepth += 1
                case "}":
                    braceDepth -= 1
                    if braceDepth == 0 {
                        return String(script[start..<index])
                    }
                default:
                    break
                }
            }

            index = script.index(after: index)
        }

        return nil
    }

    private static func parseObjectLiteralProperties(_ body: String) -> [(String, String)] {
        splitTopLevel(body, separator: ",").compactMap { entry in
            let parts = splitTopLevel(entry, separator: ":")
            guard parts.count >= 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return (key, value)
        }
    }

    private static func renderObjectLiteralProperties(
        _ properties: [(String, String)],
        context: [String: Any]
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, expression) in properties {
            let rendered = renderJavaScriptExpression(expression, context: context)
            if key == "volume" {
                result[key] = asBool(rendered)
            } else {
                result[key] = rendered
            }
        }
        return result
    }

    private static func renderHTMLElementObjectLiteral(
        _ properties: [(String, String)],
        elementAlias: String,
        element: Element
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, expression) in properties {
            let rendered = renderHTMLElementExpression(expression, elementAlias: elementAlias, element: element)
            if key == "volume" {
                result[key] = asBool(rendered)
            } else {
                result[key] = rendered
            }
        }
        return result
    }

    private static func assignmentExpression(for property: String, in script: String) -> String? {
        guard let range = script.range(of: "\(property) =") ?? script.range(of: "\(property)=") else {
            return nil
        }
        let tail = String(script[range.upperBound...])
        return extractTopLevelJavaScriptExpression(from: tail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractTopLevelJavaScriptExpression(from source: String) -> String {
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var collected = ""
        var index = source.startIndex

        func isTopLevel() -> Bool {
            quote == nil && parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
        }

        while index < source.endIndex {
            let character = source[index]

            if let activeQuote = quote {
                collected.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = source.index(after: index)
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
                collected.append(character)
            case "(":
                parenthesisDepth += 1
                collected.append(character)
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
                collected.append(character)
            case "[":
                bracketDepth += 1
                collected.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                collected.append(character)
            case "{":
                braceDepth += 1
                collected.append(character)
            case "}":
                if isTopLevel() && collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ""
                }
                braceDepth = max(0, braceDepth - 1)
                collected.append(character)
            case ";":
                if isTopLevel() {
                    return collected
                }
                collected.append(character)
            case "\n", "\r":
                if isTopLevel() {
                    let remaining = source[index...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if collected.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("`"),
                       (remaining.hasPrefix("return") || remaining.hasPrefix("}") || remaining.hasPrefix("list.") || remaining.hasPrefix("$.") || remaining.hasPrefix("$.")) {
                        return collected
                    }
                    if remaining.hasPrefix("return") || remaining.hasPrefix("}") {
                        return collected
                    }
                }
                collected.append(character)
            default:
                collected.append(character)
            }

            index = source.index(after: index)
        }

        return collected
    }

    private static func renderHTMLElementExpression(
        _ expression: String,
        elementAlias: String,
        element: Element
    ) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let parts = splitTopLevel(trimmed, separator: "+")
        if parts.count > 1 {
            return parts.map { renderHTMLElementExpression($0, elementAlias: elementAlias, element: element) }.joined()
        }

        if let stringLiteral = parseStringLiteral(trimmed) {
            return stringLiteral
        }

        if trimmed == "\(elementAlias).text()" {
            return (try? element.text()) ?? ""
        }

        if trimmed == "\(elementAlias).ownText()" {
            return (try? element.ownText()) ?? ""
        }

        if trimmed == "\(elementAlias).html()" {
            return (try? element.html()) ?? ""
        }

        if trimmed == "\(elementAlias).outerHtml()" {
            return (try? element.outerHtml()) ?? ""
        }

        let attrPattern = "^" + NSRegularExpression.escapedPattern(for: elementAlias) + #"\.attr\((['"])(.*?)\1\)$"#
        if let match = firstRegexMatch(pattern: attrPattern, in: trimmed),
           let attribute = regexGroup(match, index: 2, in: trimmed) {
            return (try? element.attr(attribute)) ?? ""
        }

        return trimmed
    }

    private static func renderJavaScriptExpression(_ expression: String, context: [String: Any]) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("`"), trimmed.hasSuffix("`"), trimmed.count >= 2 {
            return renderTemplateLiteral(trimmed, context: context)
        }

        let parts = splitTopLevel(trimmed, separator: "+")
        if parts.count > 1 {
            return parts.map { renderJavaScriptExpression($0, context: context) }.joined()
        }

        if let stringLiteral = parseStringLiteral(trimmed) {
            return stringLiteral
        }

        if let value = resolveJavaScriptReference(trimmed, context: context) {
            return stringifyJavaScriptValue(value)
        }

        return trimmed
    }

    private static func renderTemplateLiteral(_ expression: String, context: [String: Any]) -> String {
        let body = String(expression.dropFirst().dropLast())
        var result = ""
        var index = body.startIndex

        while index < body.endIndex {
            if body[index] == "\\", body.index(after: index) < body.endIndex {
                let next = body[body.index(after: index)]
                result.append(next)
                index = body.index(index, offsetBy: 2)
                continue
            }

            if body[index] == "$",
               body.index(after: index) < body.endIndex,
               body[body.index(after: index)] == "{",
               let closing = body[body.index(index, offsetBy: 2)...].firstIndex(of: "}") {
                let reference = body[body.index(index, offsetBy: 2)..<closing]
                result += renderJavaScriptExpression(String(reference), context: context)
                index = body.index(after: closing)
                continue
            }

            result.append(body[index])
            index = body.index(after: index)
        }

        return result
    }

    private static func resolveJavaScriptReference(_ expression: String, context: [String: Any]) -> Any? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = context[trimmed] {
            return direct
        }

        let normalized = trimmed.replacingOccurrences(of: "?\\.", with: ".", options: .regularExpression)
        let parts = normalized.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        guard let root = context[first] else { return nil }
        return value(at: Array(parts.dropFirst()), in: root)
    }

    private static func value(at path: [String], in root: Any) -> Any? {
        guard !path.isEmpty else { return root }

        if let dictionary = root as? [String: Any] {
            guard let next = dictionary[path[0]] else { return nil }
            return value(at: Array(path.dropFirst()), in: next)
        }

        if let dictionary = root as? NSDictionary {
            guard let next = dictionary[path[0]] else { return nil }
            return value(at: Array(path.dropFirst()), in: next)
        }

        return nil
    }

    private static func stringifyJavaScriptValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return "\(value)"
    }

    private static func parseStringLiteral(_ expression: String) -> String? {
        guard expression.count >= 2 else { return nil }
        let first = expression.first
        let last = expression.last
        guard (first == "'" && last == "'") || (first == "\"" && last == "\"") else {
            return nil
        }
        return String(expression.dropFirst().dropLast())
    }

    private static func substring(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        return String(text[range.upperBound...])
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private static func regexGroup(_ match: NSTextCheckingResult, index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func firstMatches(for regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func splitTopLevel(_ input: String, separator: Character) -> [String] {
        var parts: [String] = []
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var segmentStart = input.startIndex

        for index in input.indices {
            let character = input[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case "(":
                parenthesisDepth += 1
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            default:
                if character == separator,
                   parenthesisDepth == 0,
                   bracketDepth == 0,
                   braceDepth == 0 {
                    parts.append(String(input[segmentStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    segmentStart = input.index(after: index)
                }
            }
        }

        let tail = String(input[segmentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }

    private static func asBool(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return parseBoolValue(string)
        default:
            return false
        }
    }

    private static func decodeBase64String(_ value: String) -> String {
        guard let data = Data(base64Encoded: value) else { return value }
        return String(data: data, encoding: .utf8) ?? value
    }

    private static func evaluateJSONItemRule(
        analyzer: AnalyzeRule,
        item: Any,
        itemJSON: String,
        rule: String,
        isUrl: Bool = false
    ) -> String? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }

        let splitResult = RuleAnalyzer.splitRulesWithOperator(trimmedRule)
        if splitResult.operator == "||" {
            for subRule in splitResult.parts {
                if let value = evaluateJSONItemRule(analyzer: analyzer, item: item, itemJSON: itemJSON, rule: subRule, isUrl: isUrl),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        if splitResult.operator == "&&" {
            return splitResult.parts.compactMap {
                evaluateJSONItemRule(analyzer: analyzer, item: item, itemJSON: itemJSON, rule: $0, isUrl: isUrl)
            }.joined()
        }

        if splitResult.operator == "@@" {
            return splitResult.parts.compactMap {
                evaluateJSONItemRule(analyzer: analyzer, item: item, itemJSON: itemJSON, rule: $0, isUrl: isUrl)
            }.joined()
        }

        let (_, jsCode) = RuleAnalyzer.extractJS(trimmedRule)
        let ruleType = RuleAnalyzer.ruleType(for: trimmedRule)
        guard (ruleType == .javascript || jsCode != nil) && splitResult.operator.isEmpty else {
            return nil
        }

        do {
            analyzer.updateContextContent(itemJSON)
            let (prefixRule, embeddedJS) = RuleAnalyzer.extractJS(trimmedRule)
            if let embeddedJS {
                let resolvedEmbeddedJS = RuleAnalyzer.containsTemplate(embeddedJS)
                    ? try analyzer.renderTemplateRule(content: itemJSON, rule: embeddedJS)
                    : embeddedJS
                if prefixRule?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    let value = try analyzer.evaluateJS(
                        script: resolvedEmbeddedJS,
                        resultObject: item,
                        fallbackResult: itemJSON
                    )
                    ParserLog.debug(
                        "BookChapterParser",
                        "json item pureJS rule=\(ParserLog.preview(trimmedRule)) result=\(ParserLog.preview(value))"
                    )
                    return value
                }
                let resolvedValue = resolveJSONRuleValue(
                    item: item,
                    itemJSON: itemJSON,
                    rule: prefixRule,
                    analyzer: analyzer
                ) ?? item
                let fallbackResult = jsonString(from: resolvedValue)
                let value = try analyzer.evaluateJS(
                    script: resolvedEmbeddedJS,
                    resultObject: resolvedValue,
                    fallbackResult: fallbackResult
                )
                ParserLog.debug(
                    "BookChapterParser",
                    "json item prefixJS rule=\(ParserLog.preview(trimmedRule)) resolved=\(ParserLog.preview(fallbackResult)) result=\(ParserLog.preview(value))"
                )
                return value
            }

            let rawScript = RuleAnalyzer.cleanRule(trimmedRule)
            let resolvedScript = RuleAnalyzer.containsTemplate(rawScript)
                ? try analyzer.renderTemplateRule(content: itemJSON, rule: rawScript)
                : rawScript
            let value = try analyzer.evaluateJS(
                script: resolvedScript,
                resultObject: item,
                fallbackResult: itemJSON
            )
            ParserLog.debug(
                "BookChapterParser",
                "json item js rule=\(ParserLog.preview(trimmedRule)) result=\(ParserLog.preview(value))"
            )
            return value
        } catch {
            ParserLog.debug(
                "BookChapterParser",
                "json item JS failed rule=\(ParserLog.preview(trimmedRule)) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func directJSONFieldValue(
        _ item: Any,
        rule: String,
        isUrl: Bool,
        baseUrl: String,
        variableStore: ParserVariableStore,
        analyzer: AnalyzeRule,
        itemJSON: String
    ) -> String? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }
        if RuleAnalyzer.extractJS(trimmedRule).1 != nil || trimmedRule.contains("<js>") {
            return nil
        }

        let (prefixRule, _) = RuleAnalyzer.extractJS(trimmedRule)
        let effectiveRule = prefixRule?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedRule

        // Android allows direct JSON item fields to be embedded in literal URL templates,
        // e.g. `{{baseUrl.replace('?paging=0','')}}/{{$.chapter_id}}`. Keep the fast
        // JSON shortcut for simple fields, but render templates against the current item
        // before URL normalization so directory APIs inherit the real TOC request URL.
        if RuleAnalyzer.containsTemplate(effectiveRule),
           let rendered = try? analyzer.renderTemplateRule(content: itemJSON, rule: effectiveRule) {
            let trimmedRendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRendered.isEmpty else { return nil }
            if isUrl {
                let normalized = AnalyzeUrl.postProcessExtractedURL(
                    trimmedRendered,
                    baseUrl: baseUrl,
                    variableStore: variableStore
                )
                return normalized.isEmpty ? trimmedRendered : normalized
            }
            return trimmedRendered
        }

        guard shouldUseJSONShortcut(for: effectiveRule) else { return nil }

        let cleanedRule = RuleAnalyzer.cleanRule(effectiveRule)
        let candidateRules: [String]
        if cleanedRule.hasPrefix("$") || cleanedRule.hasPrefix("@") || cleanedRule.hasPrefix(".") {
            candidateRules = [cleanedRule]
        } else {
            candidateRules = ["$.\(cleanedRule)", cleanedRule]
        }

        for candidateRule in candidateRules {
            guard let rawValue = (try? JSONPathParser.getStringList(fromObject: item, rule: candidateRule))?.first,
                  !rawValue.isEmpty else {
                continue
            }
            if isUrl {
                let normalized = AnalyzeUrl.postProcessExtractedURL(
                    rawValue,
                    baseUrl: baseUrl,
                    variableStore: variableStore
                )
                return normalized.isEmpty ? rawValue : normalized
            }
            return rawValue
        }

        return nil
    }

    private static func mergeTopLevelJSONScalars(
        from content: String,
        into variableStore: ParserVariableStore,
        scope: ParserVariableStore.Scope
    ) {
        guard let data = content.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let dictionary = jsonObject as? [String: Any] else {
            return
        }

        for (key, value) in dictionary {
            switch value {
            case let string as String where !string.isEmpty:
                variableStore.put(key, value: string, scope: scope)
            case let number as NSNumber:
                variableStore.put(key, value: number.stringValue, scope: scope)
            default:
                continue
            }
        }
    }

    private static func flattenJSChapterItems(_ value: Any?) -> [Any] {
        guard let value else { return [] }

        if let array = value as? [Any] {
            if array.count == 1, let nested = array.first as? [Any] {
                return nested
            }
            return array
        }

        if let dictionary = value as? [String: Any] {
            return [dictionary]
        }

        if let string = value as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return flattenJSChapterItems(json)
        }

        return []
    }

    private static func flattenMeaningfulJSChapterItems(_ value: Any?, originalContent: String) -> [Any] {
        let bridgedValue: Any?
        if let dictionary = value as? [String: Any],
           !dictionaryContainsUsableChapterPayload(dictionary) {
            let bridgedText = dictionary["text"] ?? dictionary["title"] ?? dictionary["name"]
            let bridgedHref = dictionary["href"] ?? dictionary["url"] ?? dictionary["link"]
            if bridgedText != nil || bridgedHref != nil {
                bridgedValue = [[
                    "text": bridgedText ?? "",
                    "href": bridgedHref ?? ""
                ]]
            } else {
                bridgedValue = value
            }
        } else {
            bridgedValue = value
        }

        let flattened = flattenJSChapterItems(bridgedValue)
        guard !flattened.isEmpty else { return [] }
        return isOriginalJSONFallback(flattened, originalContent: originalContent) ? [] : flattened
    }

    private static func preferredSortedBase64SortAttribute(from html: String, matches: [String]) -> String? {
        guard !matches.isEmpty else { return nil }
        if html.contains(#"data-order="#), matches.contains("data-order") {
            return "data-order"
        }
        return matches.dropFirst().first ?? matches.first
    }

    private static func dictionaryContainsUsableChapterPayload(_ dictionary: [String: Any]) -> Bool {
        let textKeys = ["text", "title", "name", "chapterName"]
        let urlKeys = ["href", "url", "link", "chapterUrl", "path"]

        let hasText = textKeys.contains { key in
            guard let value = dictionary[key] else { return false }
            return "\(value)".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let hasURL = urlKeys.contains { key in
            guard let value = dictionary[key] else { return false }
            return "\(value)".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        return hasText || hasURL
    }

    private static func isOriginalJSONFallback(_ items: [Any], originalContent: String) -> Bool {
        guard items.count == 1,
              let data = originalContent.data(using: .utf8),
              let original = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return jsonString(from: items[0]) == jsonString(from: original)
    }

    private static func evaluateSerializedJSChapterItems(
        analyzer: AnalyzeRule,
        script: String,
        result: String,
        originalContent: String
    ) throws -> [Any] {
        let normalizedScript = normalizeChapterListScript(script)
        let serialized = try analyzer.evaluateJS(
            script: serializationWrapper(for: normalizedScript),
            result: result
        )
        let value = decodeSerializedJSValue(serialized)
        return flattenMeaningfulJSChapterItems(value, originalContent: originalContent)
    }

    private static func evaluateSerializedJSChapterItems(
        analyzer: AnalyzeRule,
        script: String,
        resultObject: Any,
        fallbackResult: String
    ) throws -> [Any] {
        let normalizedScript = normalizeChapterListScript(script)
        let serialized = try analyzer.evaluateJS(
            script: serializationWrapper(for: normalizedScript),
            resultObject: resultObject,
            fallbackResult: fallbackResult
        )
        return flattenJSChapterItems(decodeSerializedJSValue(serialized))
    }

    /// legado 目录脚本经常以最后一行表达式返回结果，而不是显式 `return`。
    /// 若直接包进 IIFE，JavaScriptCore 会得到 `undefined` 并退回根对象，导致目录退化成单条数据。
    /// 这里仅把明显的尾表达式改写成 `return ...`，保留控制流与显式 return 的原语义。
    private static func normalizeChapterListScript(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return script }
        if trimmed.hasPrefix("return ") {
            return script
        }

        let statementRanges = topLevelStatementRanges(in: script)
        guard let lastRange = statementRanges.last else {
            return script
        }
        let lastStatement = script[lastRange].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !lastStatement.isEmpty,
              !lastStatement.hasPrefix("return "),
              !lastStatement.hasPrefix("throw "),
              !lastStatement.hasPrefix("if "),
              !lastStatement.hasPrefix("for "),
              !lastStatement.hasPrefix("while "),
              !lastStatement.hasPrefix("switch "),
              !lastStatement.hasPrefix("try "),
              !lastStatement.hasPrefix("catch "),
              !lastStatement.hasPrefix("finally "),
              !lastStatement.hasPrefix("var "),
              !lastStatement.hasPrefix("let "),
              !lastStatement.hasPrefix("const "),
              lastStatement != "}",
              !lastStatement.hasSuffix("{") else {
            return script
        }

        let rawStatement = String(script[lastRange])
        let leadingWhitespace = rawStatement.prefix { $0 == " " || $0 == "\t" }
        let replacement = "\(leadingWhitespace)return \(lastStatement)"
        var normalized = script
        normalized.replaceSubrange(lastRange, with: replacement)
        return normalized
    }

    private static func topLevelStatementRanges(in script: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var statementStart = script.startIndex
        var index = script.startIndex

        func appendStatement(end: String.Index) {
            let segment = script[statementStart..<end]
            if !segment.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                ranges.append(statementStart..<end)
            }
            statementStart = end
        }

        while index < script.endIndex {
            let character = script[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = script.index(after: index)
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case "(":
                parenthesisDepth += 1
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case ";" where parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                let end = script.index(after: index)
                appendStatement(end: end)
            case "\n", "\r" where parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                appendStatement(end: index)
                let nextIndex = script.index(after: index)
                statementStart = nextIndex
            default:
                break
            }

            index = script.index(after: index)
        }

        if statementStart < script.endIndex {
            appendStatement(end: script.endIndex)
        }

        return ranges
    }

    private static func serializationWrapper(for script: String) -> String {
        """
        var __LegadoPrimary = (function() {
        \(script)
        })();
        var __LegadoFallback = result;
        if ((__LegadoPrimary === undefined || __LegadoPrimary === null) && typeof chapterList !== 'undefined') {
            __LegadoFallback = chapterList;
        } else if ((__LegadoPrimary === undefined || __LegadoPrimary === null) && typeof list !== 'undefined') {
            __LegadoFallback = list;
        } else if ((__LegadoPrimary === undefined || __LegadoPrimary === null) && typeof pages !== 'undefined') {
            __LegadoFallback = pages;
        }
        var __LegadoResolved = (__LegadoPrimary === undefined || __LegadoPrimary === null) ? __LegadoFallback : __LegadoPrimary;
        var __LegadoSerialized = '';
        try {
            __LegadoSerialized = JSON.stringify(__LegadoResolved);
        } catch (error) {}
        __LegadoSerialized
        """
    }

    private static func decodeSerializedJSValue(_ serialized: String) -> Any? {
        guard !serialized.isEmpty,
              let data = serialized.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func resolveJSONRuleValue(
        item: Any,
        itemJSON: String,
        rule: String?,
        analyzer: AnalyzeRule
    ) -> Any? {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return item
        }

        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = evaluateJSONItemRule(
            analyzer: analyzer,
            item: item,
            itemJSON: itemJSON,
            rule: trimmedRule,
            isUrl: false
        ), !value.isEmpty {
            return value
        }
        let cleanedRule = RuleAnalyzer.cleanRule(trimmedRule)
        let candidateRules: [String]
        if cleanedRule.hasPrefix("$") || cleanedRule.hasPrefix("@") || cleanedRule.hasPrefix(".") {
            candidateRules = [cleanedRule]
        } else {
            candidateRules = ["$.\(cleanedRule)", cleanedRule]
        }

        for candidateRule in candidateRules {
            if let objects = try? JSONPathParser.getObjects(fromObject: item, rule: candidateRule), !objects.isEmpty {
                return objects.count == 1 ? objects[0] : objects
            }
        }

        if let fallbackString = try? analyzer.getString(content: itemJSON, rule: rule), !fallbackString.isEmpty {
            return fallbackString
        }

        return nil
    }

    private static func injectBookContext(
        _ context: BookContext,
        into analyzer: AnalyzeRule?,
        variableStore: ParserVariableStore
    ) {
        variableStore.put("bookUrl", value: context.bookUrl, scope: .book)
        if !context.name.isEmpty {
            variableStore.put("name", value: context.name, scope: .book)
        }
        if !context.author.isEmpty {
            variableStore.put("author", value: context.author, scope: .book)
        }
        if !context.kind.isEmpty {
            variableStore.put("kind", value: context.kind, scope: .book)
        }
        if !context.tocUrl.isEmpty {
            variableStore.put("tocUrl", value: context.tocUrl, scope: .book)
        }
        if !context.bookVariables.isEmpty {
            variableStore.merge(context.bookVariables, into: .book)
        }

        let runtimeBookVariables = variableStore.snapshot(for: .book, includeInherited: true)
        analyzer?.injectBookVariable(
            bookUrl: context.bookUrl,
            name: context.name,
            author: context.author,
            kind: context.kind.isEmpty ? runtimeBookVariables["kind"] ?? "" : context.kind,
            tocUrl: context.tocUrl.isEmpty ? runtimeBookVariables["tocUrl"] ?? "" : context.tocUrl,
            bookVariables: context.bookVariables.isEmpty ? runtimeBookVariables : context.bookVariables
        )
    }

    private static func jsonFieldFromObject(
        _ item: Any,
        rule: String,
        isUrl: Bool,
        analyzer: AnalyzeRule
    ) -> String? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }
        guard shouldUseJSONShortcut(for: trimmedRule) else { return nil }

        let cleanedRule = RuleAnalyzer.cleanRule(trimmedRule)
        let candidateRules: [String]
        if cleanedRule.hasPrefix("$") || cleanedRule.hasPrefix("@") || cleanedRule.hasPrefix(".") {
            candidateRules = [cleanedRule]
        } else {
            candidateRules = ["$.\(cleanedRule)", cleanedRule]
        }

        for candidateRule in candidateRules {
            guard let rawValue = (try? JSONPathParser.getStringList(fromObject: item, rule: candidateRule))?.first,
                  !rawValue.isEmpty else {
                continue
            }
            if isUrl {
                let normalized = AnalyzeUrl.postProcessExtractedURL(
                    rawValue,
                    baseUrl: analyzer.baseUrl,
                    variableStore: analyzer.variableStore
                )
                return normalized.isEmpty ? rawValue : normalized
            }
            return rawValue
        }

        return nil
    }

    private static func finalizeJSONFieldValue(
        _ value: String,
        analyzer: AnalyzeRule,
        itemJSON: String,
        isUrl: Bool
    ) -> String {
        ParserRuleRuntime.finalizeJSONFieldValue(
            value,
            analyzer: analyzer,
            itemJSON: itemJSON,
            isUrl: isUrl
        )
    }

    private static func recoverLiteralJSONChapterURLIfNeeded(
        currentURL: String,
        rule: String,
        itemJSON: String,
        analyzer: AnalyzeRule,
        baseUrl: String
    ) -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.hasPrefix("<js>"), !trimmedRule.contains("@js:") else {
            return currentURL
        }
        let literalRule = AnalyzeUrl.looksLikeLiteralURLRule(rule, variableStore: analyzer.variableStore)
        guard literalRule else {
            return currentURL
        }

        let normalizedCurrent = normalizedIdentity(currentURL)
        let normalizedBase = normalizedIdentity(baseUrl)
        guard let literalValue = renderJSONLiteralRule(itemJSON: itemJSON, rule: rule, analyzer: analyzer),
              !literalValue.isEmpty else {
            return currentURL
        }

        let recovered = sanitizedChapterURL(
            finalizeJSONFieldValue(
                literalValue,
                analyzer: analyzer,
                itemJSON: itemJSON,
                isUrl: true
            ),
            baseUrl: baseUrl
        )
        guard !recovered.isEmpty else { return currentURL }

        let normalizedRecovered = normalizedIdentity(recovered)
        if normalizedCurrent.isEmpty || normalizedCurrent == normalizedBase {
            return recovered
        }

        // 某些 JSON 目录项会先被错误收敛成裸 URL，再丢掉 descriptor 参数；
        // 若恢复后的值保留了 descriptor 而当前值没有，优先使用恢复结果。
        if recovered.contains(","),
           !currentURL.contains(","),
           !normalizedRecovered.isEmpty,
           normalizedRecovered == normalizedCurrent {
            return recovered
        }

        return currentURL
    }

    private static func fallbackChapterURL(
        existingURL: String,
        title: String,
        isVolume: Bool,
        index: Int,
        baseUrl: String,
        variables: [String: String] = [:]
    ) -> String {
        let trimmedURL = existingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            return trimmedURL
        }
        if isVolume {
            return title.isEmpty ? "\(baseUrl)#\(index)" : "\(title)#\(index)"
        }
        return baseUrl
    }

    private static func shouldFallbackChapterURL(
        configuredRule: String?,
        currentURL: String,
        rawURL: String = "",
        isVolume: Bool
    ) -> Bool {
        guard currentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if isVolume {
            return true
        }
        if !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let configuredRule else {
            return true
        }
        return configuredRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func shouldKeepChapter(
        _ chapter: BookChapter,
        configuredRule: String?
    ) -> Bool {
        let trimmedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedURL.isEmpty else {
            return false
        }
        if chapter.isVolume {
            return true
        }
        if let configuredRule,
           !configuredRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           trimmedURL.isEmpty {
            return false
        }
        return true
    }

    private static func sanitizedChapterURL(_ value: String, baseUrl: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let literalURLPart = AnalyzeUrl.extractedLiteralURLPart(from: trimmed)
        let lowered = trimmed.lowercased()
        let loweredLiteral = literalURLPart.lowercased()
        let placeholderValues: Set<String> = [
            "href", "src", "#", "javascript:", "javascript:;", "javascript:void(0)", "javascript:void(0);",
            "url", "[]", "%5b%5d", "null", "undefined"
        ]
        if placeholderValues.contains(lowered) || placeholderValues.contains(loweredLiteral) {
            return ""
        }

        if loweredLiteral.contains("[]")
            || loweredLiteral.contains("%5b%5d")
            || loweredLiteral.contains("undefined")
            || loweredLiteral.contains("null") {
            return ""
        }

        if loweredLiteral.hasSuffix("/href") || loweredLiteral.hasSuffix("/src") || loweredLiteral.hasSuffix("/url") {
            return ""
        }

        if lowered == normalizedIdentity(baseUrl).lowercased(),
           !trimmed.contains("?"),
           !trimmed.contains("#") {
            return trimmed
        }

        return trimmed
    }

    private static func deduplicationKey(for chapter: BookChapter) -> String {
        let normalizedURL = normalizedIdentity(chapter.url)
        let normalizedBaseURL = normalizedIdentity(chapter.baseUrl)
        let normalizedBookURL = normalizedIdentity(chapter.bookUrl)
        let normalizedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUpdateTime = chapter.updateTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let hasStrongURLIdentity = !normalizedURL.isEmpty
            && normalizedURL != normalizedBaseURL
            && normalizedURL != normalizedBookURL
            && !normalizedURL.hasPrefix("javascript:")

        if hasStrongURLIdentity {
            return [
                "url:\(normalizedURL)",
                "title:\(normalizedTitle)",
                "volume:\(chapter.isVolume)"
            ].joined(separator: "|")
        }

        return [
            "weakBase:\(normalizedBaseURL)",
            "weakBook:\(normalizedBookURL)",
            "title:\(normalizedTitle)",
            "update:\(normalizedUpdateTime)",
            "index:\(chapter.index)",
            "volume:\(chapter.isVolume)"
        ].joined(separator: "|")
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func allInOneRegexPattern(from listRule: String) -> String? {
        let trimmed = listRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(":") else { return nil }

        let candidate = String(trimmed.dropFirst())
        guard candidate.hasPrefix("(?") || candidate.hasPrefix("(") else {
            return nil
        }
        return candidate
    }

    private static func heuristicChapterLinks(
        html: String,
        bookSource: BookSource,
        tocRule: TocRule,
        bookUrl: String,
        baseUrl: String,
        variableStore: ParserVariableStore,
        bookContext: BookContext
    ) throws -> [BookChapter]? {
        let document = try SwiftSoup.parse(html, baseUrl)
        defer { _ = document.empty() }

        let anchors = try document.select("a[href]").array()
        var chapters: [BookChapter] = []

        for anchor in anchors {
            do {
                let fallbackTitle = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard looksLikeChapterTitle(fallbackTitle) else { continue }

                let chapterStore = variableStore.makeChildStore(
                    writeScope: .chapter,
                    inheritBookScope: true,
                    resetRuleData: true
                )
                let chapterAnalyzer = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: chapterStore)
                injectBookContext(bookContext, into: chapterAnalyzer, variableStore: chapterStore)
                let scopedContext = try DetachedHTMLElementRuleContext(element: anchor, analyzer: chapterAnalyzer, baseUrl: baseUrl)
                defer { scopedContext.cleanup() }

                var chapter = BookChapter(
                    index: chapters.count,
                    title: fallbackTitle,
                    url: "",
                    baseUrl: baseUrl,
                    bookUrl: bookUrl
                )

                if let nameRule = tocRule.chapterName, !nameRule.isEmpty,
                   let resolvedTitle = try? scopedContext.getString(rule: nameRule),
                   !resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chapter.title = normalizeHeuristicChapterTitle(resolvedTitle)
                }

                if let urlRule = tocRule.chapterUrl, !urlRule.isEmpty,
                   let resolvedURL = try? scopedContext.getString(rule: urlRule, isUrl: true) {
                    chapter.url = sanitizedChapterURL(resolvedURL, baseUrl: baseUrl)
                }

                if let isVolumeRule = tocRule.isVolume, !isVolumeRule.isEmpty,
                   let resolvedValue = try? scopedContext.getString(rule: isVolumeRule) {
                    chapter.isVolume = parseBoolValue(resolvedValue)
                }

                if let isVipRule = tocRule.isVip, !isVipRule.isEmpty,
                   let resolvedValue = try? scopedContext.getString(rule: isVipRule) {
                    chapter.isVip = parseBoolValue(resolvedValue)
                }

                if let isPayRule = tocRule.isPay, !isPayRule.isEmpty,
                   let resolvedValue = try? scopedContext.getString(rule: isPayRule) {
                    chapter.isPay = parseBoolValue(resolvedValue)
                }

                if chapter.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let rawHref = try anchor.attr("href")
                    let resolvedHref = AnalyzeUrl.postProcessExtractedURL(rawHref, baseUrl: baseUrl, variableStore: chapterStore)
                    chapter.url = sanitizedChapterURL(resolvedHref.isEmpty ? rawHref : resolvedHref, baseUrl: baseUrl)
                }

                chapter.url = normalizeSpecialChapterURLIfNeeded(chapter.url, tocRule: tocRule)

                guard !chapter.url.isEmpty else { continue }
                chapter.sourceVariables = chapterStore.snapshot(for: .source, includeInherited: false)
                chapter.bookVariables = chapterStore.snapshot(for: .book, includeInherited: false)
                chapter.chapterVariables = chapterStore.snapshot(for: .chapter, includeInherited: false)
                chapter.variables = chapterStore.snapshot(for: .chapter, includeInherited: true)
                chapters.append(chapter)
            } catch {
                ParserLog.debug(
                    "BookChapterParser",
                    "heuristic anchor skipped error=\(error.localizedDescription)"
                )
            }
        }

        guard chapters.count >= 5 else { return nil }
        return mergeChapters([chapters])
    }

    private static func shouldPreferHeuristicChapters(
        _ heuristicChapters: [BookChapter],
        over parsedChapters: [BookChapter],
        baseUrl: String,
        bookUrl: String
    ) -> Bool {
        if parsedChapters.isEmpty {
            return true
        }

        let heuristicScore = chapterQualityScore(heuristicChapters, baseUrl: baseUrl, bookUrl: bookUrl)
        let parsedScore = chapterQualityScore(parsedChapters, baseUrl: baseUrl, bookUrl: bookUrl)
        if heuristicScore.usableCount > parsedScore.usableCount {
            return true
        }
        if heuristicScore.strongURLCount > parsedScore.strongURLCount {
            return true
        }
        return heuristicScore.usableCount >= 5 && parsedScore.usableCount == 0
    }

    /// 某些 `<js>` 目录标题规则会返回 JSON 风格的 `"标题"`。
    /// 只在启发式目录兜底里做成对引号剥离，避免影响正常规则链文本。
    private static func normalizeHeuristicChapterTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func chapterQualityScore(
        _ chapters: [BookChapter],
        baseUrl: String,
        bookUrl: String
    ) -> (usableCount: Int, strongURLCount: Int) {
        var usableCount = 0
        var strongURLCount = 0
        let normalizedBase = normalizedIdentity(baseUrl)
        let normalizedBook = normalizedIdentity(bookUrl)

        for chapter in chapters where !chapter.isVolume {
            let trimmedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedURL = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedURL = normalizedIdentity(trimmedURL)

            if !trimmedTitle.isEmpty || !trimmedURL.isEmpty {
                usableCount += 1
            }
            if !normalizedURL.isEmpty,
               normalizedURL != normalizedBase,
               normalizedURL != normalizedBook,
               !normalizedURL.hasPrefix("javascript:") {
                strongURLCount += 1
            }
        }

        return (usableCount, strongURLCount)
    }

    private static func normalizeSpecialChapterURLIfNeeded(_ url: String, tocRule: TocRule) -> String {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return url }

        if let chapterURLRule = tocRule.chapterUrl,
           chapterURLRule.contains("a.heiyan.com/ajax/chapter/content/"),
           !trimmedURL.contains("a.heiyan.com/ajax/chapter/content/"),
           let chapterID = trimmedURL.split(separator: "/").last,
           chapterID.allSatisfy(\.isNumber) {
            return "https://a.heiyan.com/ajax/chapter/content/\(chapterID)"
        }

        return url
    }

    private static func looksLikeChapterTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }

        let obviousNoise = ["返回", "首页", "搜索", "目录", "查看章节", "继续阅读", "免费试读", "上一页", "下一页"]
        if obviousNoise.contains(where: { trimmed.contains($0) }) {
            return false
        }

        let patterns = [
            #"^第[0-9一二三四五六七八九十百千万零〇两]+[章回节话卷].*"#,
            #"^(序章|楔子|引子|尾声|终章|番外).*$"#
        ]
        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }
    }

}
