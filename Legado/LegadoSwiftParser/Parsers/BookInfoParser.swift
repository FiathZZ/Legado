import Foundation
import SwiftSoup

// MARK: - BookInfoParser（书籍详情解析）

/// 解析书籍详情页，提取书籍元数据
public nonisolated struct BookInfoParser {

    /// 解析书籍详情页
    /// - Parameters:
    ///   - html: 书籍详情页 HTML 或 JSON
    ///   - bookSource: 书源配置
    ///   - bookUrl: 书籍详情页 URL（用作唯一标识）
    ///   - baseUrl: 基础 URL
    /// - Returns: 书籍详情
    public static func parse(
        html: String,
        bookSource: BookSource,
        bookUrl: String,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil,
        bookName: String = "",
        bookAuthor: String = "",
        bookKind: String = ""
    ) throws -> BookDetail {
        guard let rule = bookSource.ruleBookInfo else {
            return BookDetail(bookUrl: bookUrl, origin: bookSource.bookSourceUrl)
        }

        ParserLog.debug(
            "BookInfoParser",
            "parse start source=\(bookSource.bookSourceName) bookUrl=\(bookUrl) baseUrl=\(baseUrl)"
        )

        let runtimeStore = variableStore ?? ParserVariableStore(writeScope: .book)
        var book = BookDetail(bookUrl: bookUrl, origin: bookSource.bookSourceUrl)
        var regexInitCaptures: [String] = []
        var analyzer: AnalyzeRule?

        func refreshContext(_ targetAnalyzer: AnalyzeRule? = analyzer) {
            refreshBookContext(
                analyzer: targetAnalyzer,
                runtimeStore: runtimeStore,
                book: book,
                fallbackName: bookName,
                fallbackAuthor: bookAuthor,
                fallbackKind: bookKind
            )
        }

        func requireAnalyzer() -> AnalyzeRule {
            if let analyzer {
                return analyzer
            }
            let created = AnalyzeRule(
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore
            )
            analyzer = created
            refreshContext(created)
            return created
        }

        refreshContext(nil)

        // 执行 init 规则（对应 legado 的 `infoRule.init`）：
        // 该规则可将解析上下文缩小到页面的某个子节点区域，避免书名、作者等规则在全页匹配到错误内容
        var parsableHtml = html
        if let initRule = rule.`init`, !initRule.isEmpty {
            let trimmedHtml = html.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentIsJson = trimmedHtml.hasPrefix("{") || trimmedHtml.hasPrefix("[")
            var matched = false

            if applyInitPutOptionsIfNeeded(
                html: html,
                rule: initRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                analyzerProvider: requireAnalyzer
            ) {
                matched = true
            }

            // JS init rule: execute and use result as parsableHtml
            let initRuleType = RuleAnalyzer.ruleType(for: initRule)
            if !matched, initRuleType == .javascript || initRule.contains("<js>") {
                if let jsValue = try? evaluateInitRuleValue(
                    html: html,
                    rule: initRule,
                    baseUrl: baseUrl,
                    source: bookSource,
                    variableStore: runtimeStore,
                    book: book,
                    fallbackName: bookName,
                    fallbackAuthor: bookAuthor,
                    fallbackKind: bookKind,
                    analyzerProvider: requireAnalyzer
                ),
                   let serializedValue = jsonString(from: jsValue),
                   !serializedValue.isEmpty {
                    parsableHtml = serializedValue
                    matched = true
                } else if let jsResult = try? requireAnalyzer().getString(content: html, rule: initRule),
                          !jsResult.isEmpty {
                    parsableHtml = jsResult
                    matched = true
                }
            } else if !matched, contentIsJson && initRuleType != .css && initRuleType != .xpath {
                let cleanedInitRule = RuleAnalyzer.cleanRule(initRule)
                if let objects = try? JSONPathParser.getObjects(from: html, rule: cleanedInitRule),
                   let firstObject = objects.first,
                   let objectString = jsonString(from: firstObject) {
                    parsableHtml = objectString
                    matched = true
                }
            } else if !matched, let captures = extractRegexInitCaptures(from: html, rule: initRule), !captures.isEmpty {
                regexInitCaptures = captures
                matched = true
            }

            if !matched {
                do {
                    let initElements = try requireAnalyzer().getElements(content: html, rule: initRule)
                    if let firstElement = initElements.first {
                        parsableHtml = (try? firstElement.outerHtml()) ?? html
                        matched = true
                    }
                } catch {
                    ParserLog.debug(
                        "BookInfoParser",
                        "init element scope failed rule=\(ParserLog.preview(initRule)) error=\(error.localizedDescription)"
                    )
                }
            }
            ParserLog.debug(
                "BookInfoParser",
                "init rule=\(ParserLog.preview(initRule)) matched=\(matched) parsableChars=\(parsableHtml.count)"
            )
        }

        mergeTopLevelJSONScalars(from: parsableHtml, into: runtimeStore)
        if parsableHtml != html {
            mergeTopLevelJSONScalars(from: html, into: runtimeStore)
        }

        // 提取书名
        if let nameRule = rule.name, !nameRule.isEmpty {
            book.name = try resolveFieldString(
                content: parsableHtml,
                rule: nameRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                analyzerProvider: requireAnalyzer
            )
        }

        // 提取作者
        if let authorRule = rule.author, !authorRule.isEmpty {
            book.author = try resolveFieldString(
                content: parsableHtml,
                rule: authorRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                analyzerProvider: requireAnalyzer
            )
        }

        // 提取简介
        if let introRule = rule.intro, !introRule.isEmpty {
            book.intro = HtmlFormatter.format(
                try resolveFieldString(
                    content: parsableHtml,
                    rule: introRule,
                    baseUrl: baseUrl,
                    source: bookSource,
                    variableStore: runtimeStore,
                    regexCaptures: regexInitCaptures,
                    analyzerProvider: requireAnalyzer
                )
            )
        }

        // 提取分类
        if let kindRule = rule.kind, !kindRule.isEmpty {
            book.kind = try resolveFieldString(
                content: parsableHtml,
                rule: kindRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                analyzerProvider: requireAnalyzer
            )
        }
        refreshContext()

        // 提取最新章节
        if let lastChapterRule = rule.lastChapter, !lastChapterRule.isEmpty {
            book.lastChapter = try resolveFieldString(
                content: parsableHtml,
                rule: lastChapterRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                analyzerProvider: requireAnalyzer
            )
        }

        // 提取更新时间
        if let updateTimeRule = rule.updateTime, !updateTimeRule.isEmpty {
            book.updateTime = try resolveFieldString(
                content: parsableHtml,
                rule: updateTimeRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                analyzerProvider: requireAnalyzer
            )
        }

        // 提取封面 URL（封面通常在详情页主区域，使用 parsableHtml）
        if let coverRule = rule.coverUrl, !coverRule.isEmpty {
            let rawUrl = try resolveFieldString(
                content: parsableHtml,
                rule: coverRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                isURL: true,
                analyzerProvider: requireAnalyzer
            )
            book.coverUrl = rawUrl
            ParserLog.debug(
                "BookInfoParser",
                "cover raw=\(ParserLog.preview(rawUrl)) resolved=\(ParserLog.preview(book.coverUrl))"
            )
        }

        // 提取目录页 URL。
        // 对 QB 男生 / 松鹤这一类详情 JSON，`tocUrl` 依赖 `init` 后子节点里的 `resourceID`，
        // 因此优先在 `parsableHtml` 上下文中计算，再回退到整页 html。
        var resolvedTocFromRule = false
        if let tocUrlRule = rule.tocUrl, !tocUrlRule.isEmpty {
            var rawUrl = ""

            if let literalRendered = renderDirectLiteralURLRuleIfNeeded(
                content: parsableHtml,
                rule: tocUrlRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore
            ), isValidResolvedURL(literalRendered) {
                rawUrl = literalRendered
            }

            if parsableHtml != html {
                let scopedUrl = try resolveFieldString(
                    content: parsableHtml,
                    rule: tocUrlRule,
                    baseUrl: baseUrl,
                    source: bookSource,
                    variableStore: runtimeStore,
                    regexCaptures: regexInitCaptures,
                    isURL: true,
                    analyzerProvider: requireAnalyzer
                )
                if isValidResolvedURL(scopedUrl) {
                    rawUrl = scopedUrl
                } else {
                    ParserLog.debug(
                        "BookInfoParser",
                        "toc scoped invalid value=\(ParserLog.preview(scopedUrl)) rule=\(ParserLog.preview(tocUrlRule))"
                    )
                }
            }

            if rawUrl.isEmpty {
                let pageUrl = try resolveFieldString(
                    content: html,
                    rule: tocUrlRule,
                    baseUrl: baseUrl,
                    source: bookSource,
                    variableStore: runtimeStore,
                    regexCaptures: regexInitCaptures,
                    isURL: true,
                    analyzerProvider: requireAnalyzer
                )
                if isValidResolvedURL(pageUrl) {
                    rawUrl = pageUrl
                } else if !pageUrl.isEmpty {
                    ParserLog.debug(
                        "BookInfoParser",
                        "toc page invalid value=\(ParserLog.preview(pageUrl)) rule=\(ParserLog.preview(tocUrlRule))"
                    )
                }
            }

            rawUrl = recoverLiteralTocURLIfNeeded(
                currentURL: rawUrl,
                rule: tocUrlRule,
                pageBaseURL: baseUrl,
                sourceBaseURL: bookSource.bookSourceUrl,
                variableStore: runtimeStore
            )

            if !isValidResolvedURL(rawUrl),
               let inferredTocURL = inferTocURL(from: html, baseUrl: baseUrl, bookUrl: bookUrl) {
                rawUrl = inferredTocURL
                ParserLog.debug(
                    "BookInfoParser",
                    "toc inferred fallback=\(ParserLog.preview(rawUrl)) rule=\(ParserLog.preview(tocUrlRule))"
                )
            }

            resolvedTocFromRule = !rawUrl.isEmpty
            book.tocUrl = rawUrl.isEmpty ? baseUrl : rawUrl
            refreshContext()
            ParserLog.debug(
                "BookInfoParser",
                "toc raw=\(ParserLog.preview(rawUrl)) resolved=\(ParserLog.preview(book.tocUrl)) fallbackBase=\(rawUrl.isEmpty)"
            )
        } else {
            book.tocUrl = baseUrl
            refreshContext()
            ParserLog.debug("BookInfoParser", "toc missing rule fallback baseUrl=\(baseUrl)")
        }

        if shouldRejectLikelySearchPage(
            book: book,
            baseUrl: baseUrl,
            fallbackName: bookName,
            fallbackAuthor: bookAuthor,
            resolvedTocFromRule: resolvedTocFromRule
        ) {
            ParserLog.debug(
                "BookInfoParser",
                "detail rejected as likely search page baseUrl=\(ParserLog.preview(baseUrl)) name=\(ParserLog.preview(book.name)) author=\(ParserLog.preview(book.author)) tocUrl=\(ParserLog.preview(book.tocUrl))"
            )
            throw ParserError.parsingFailed("详情地址疑似仍是搜索页")
        }

        // 提取字数
        if let wordCountRule = rule.wordCount, !wordCountRule.isEmpty {
            book.wordCount = try resolveFieldString(
                content: parsableHtml,
                rule: wordCountRule,
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: runtimeStore,
                regexCaptures: regexInitCaptures,
                analyzerProvider: requireAnalyzer
            )
        }

        ParserLog.debug(
            "BookInfoParser",
            "parse done name=\(ParserLog.preview(book.name)) author=\(ParserLog.preview(book.author)) kind=\(ParserLog.preview(book.kind)) lastChapter=\(ParserLog.preview(book.lastChapter)) tocUrl=\(ParserLog.preview(book.tocUrl))"
        )
        book.sourceVariables = runtimeStore.snapshot(for: .source, includeInherited: false)
        book.bookVariables = runtimeStore.snapshot(for: .book, includeInherited: false)
        book.variables = runtimeStore.snapshot(for: .book, includeInherited: true)

        return book
    }

    private static func jsonString(from value: Any) -> String? {
        let normalizedValue = normalizeJSONObject(value)
        if JSONSerialization.isValidJSONObject(normalizedValue),
           let data = try? JSONSerialization.data(withJSONObject: normalizedValue),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        if let string = value as? String {
            return string
        }
        return JSONPathParser.stringify(normalizedValue)
    }

    private static func extractRegexInitCaptures(from html: String, rule: String) -> [String]? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(":") else { return nil }
        if let metaCaptures = extractMetaPropertyInitCaptures(from: html, rule: trimmed) {
            return metaCaptures
        }
        let pattern = String(trimmed.dropFirst())
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsHTML = html as NSString
        let searchRange = NSRange(location: 0, length: nsHTML.length)
        guard let match = regex.firstMatch(in: html, range: searchRange) else {
            return nil
        }
        var captures: [String] = []
        captures.reserveCapacity(match.numberOfRanges)
        for index in 0..<match.numberOfRanges {
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let stringRange = Range(captureRange, in: html) else {
                captures.append("")
                continue
            }
            captures.append(String(html[stringRange]))
        }
        return captures
    }

    private static func extractMetaPropertyInitCaptures(from html: String, rule: String) -> [String]? {
        let normalizedRule = rule.replacingOccurrences(of: #"\""#, with: "\"")
        guard normalizedRule.hasPrefix(":<meta"),
              normalizedRule.contains(#"content="([^"]*)""#) else {
            return nil
        }

        guard let propertyRegex = try? NSRegularExpression(pattern: #"property="([^"]+)""#),
              let htmlRegex = try? NSRegularExpression(
                pattern: #"<meta\b[^>]*property\s*=\s*['"]([^'"]+)['"][^>]*content\s*=\s*['"]([^'"]*)['"][^>]*>"#,
                options: [.caseInsensitive]
              ) else {
            return nil
        }

        let nsRule = normalizedRule as NSString
        let ruleMatches = propertyRegex.matches(
            in: normalizedRule,
            range: NSRange(location: 0, length: nsRule.length)
        )
        let propertyNames = ruleMatches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            return nsRule.substring(with: match.range(at: 1)).lowercased()
        }
        guard !propertyNames.isEmpty else { return nil }

        let nsHTML = html as NSString
        let htmlMatches = htmlRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !htmlMatches.isEmpty else { return nil }

        var metaMap: [String: (tag: String, content: String)] = [:]
        for match in htmlMatches where match.numberOfRanges > 2 {
            let property = nsHTML.substring(with: match.range(at: 1)).lowercased()
            guard metaMap[property] == nil else { continue }
            let tag = nsHTML.substring(with: match.range(at: 0))
            let content = nsHTML.substring(with: match.range(at: 2))
            metaMap[property] = (tag, content)
        }

        var fullMatchParts: [String] = []
        var captures: [String] = [""]
        captures.reserveCapacity(propertyNames.count + 1)
        for property in propertyNames {
            guard let entry = metaMap[property] else { return nil }
            fullMatchParts.append(entry.tag)
            captures.append(entry.content)
        }
        captures[0] = fullMatchParts.joined()
        return captures
    }

    private static func applyInitPutOptionsIfNeeded(
        html: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        analyzerProvider: () -> AnalyzeRule
    ) -> Bool {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return false }

        let (cleanRule, putMap) = RuleAnalyzer.extractPutOptions(trimmedRule)
        guard cleanRule.isEmpty, !putMap.isEmpty else { return false }

        for (key, valueRule) in putMap {
            let resolvedValue = (try? extractRuleString(
                html: html,
                rule: valueRule,
                baseUrl: baseUrl,
                source: source,
                variableStore: variableStore,
                analyzerProvider: analyzerProvider
            )) ?? valueRule
            variableStore.put(key, value: resolvedValue, scope: .book)
        }

        return true
    }

    private static func resolveFieldString(
        content: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        regexCaptures: [String],
        isURL: Bool = false,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return "" }

        if !regexCaptures.isEmpty,
           trimmedRule.contains("$"),
           !trimmedRule.contains("<js>"),
           !trimmedRule.lowercased().contains("@js:"),
           !RuleAnalyzer.containsTemplate(trimmedRule) {
            let rendered = RuleAnalyzer.substituteRegexCaptures(trimmedRule, captures: regexCaptures)
            if !rendered.contains("@"), !rendered.contains("##"), !rendered.contains("||"), !rendered.contains("&&"), !rendered.contains("@@"), !rendered.contains("%%") {
                if isURL {
                    return AnalyzeUrl.postProcessExtractedURL(rendered, baseUrl: baseUrl)
                }
                return rendered
            }
            return try extractRuleString(
                html: content,
                rule: rendered,
                baseUrl: baseUrl,
                source: source,
                variableStore: variableStore,
                isUrl: isURL,
                analyzerProvider: analyzerProvider
            )
        }

        return try extractRuleString(
            html: content,
            rule: trimmedRule,
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore,
            isUrl: isURL,
            analyzerProvider: analyzerProvider
        )
    }

    private static func normalizeJSONObject(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var normalized: [String: Any] = [:]
            for (key, nestedValue) in dict {
                normalized[key] = normalizeJSONObject(nestedValue)
            }
            return normalized
        case let dict as NSDictionary:
            var normalized: [String: Any] = [:]
            for (key, nestedValue) in dict {
                guard let stringKey = key as? String else { continue }
                normalized[stringKey] = normalizeJSONObject(nestedValue)
            }
            return normalized
        case let array as [Any]:
            return array.map(normalizeJSONObject)
        case let array as NSArray:
            return array.map(normalizeJSONObject)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    private static func evaluateInitRuleValue(
        html: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        book: BookDetail,
        fallbackName: String,
        fallbackAuthor: String,
        fallbackKind: String,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> Any? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let (prefixRule, jsCode) = RuleAnalyzer.extractJS(trimmedRule)
        if prefixRule == nil,
           let jsCode,
           trimmedRule.contains("<js>") || trimmedRule.hasPrefix("@js:") {
            let parser = JavaScriptParser(baseUrl: baseUrl, source: source, variableStore: variableStore)
            parser.updateContextContent(html)
            injectBookContext(
                parser: parser,
                variableStore: variableStore,
                book: book,
                fallbackName: fallbackName,
                fallbackAuthor: fallbackAuthor,
                fallbackKind: fallbackKind
            )
            if let directValue = try? parser.evaluateValue(script: jsCode, result: html) {
                return directValue
            }
            return try evaluatePureJSInitFallback(
                parser: parser,
                html: html,
                rule: rule
            )
        }

        return try analyzerProvider().getValue(content: html, rule: rule)
    }

    private static func evaluatePureJSInitFallback(
        parser: JavaScriptParser,
        html: String,
        rule: String
    ) throws -> Any? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let (prefixRule, jsCode) = RuleAnalyzer.extractJS(trimmedRule)
        guard prefixRule == nil,
              let jsCode,
              trimmedRule.contains("<js>") || trimmedRule.hasPrefix("@js:") else {
            return nil
        }

        let rawLines = jsCode
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = rawLines.last else { return nil }
        guard let trailingSplit = trailingStatementSplit(in: lastLine) else {
            return nil
        }

        let prefixLines = rawLines.dropLast().joined(separator: "\n")
        let trailingLine = trailingSplit.prefix.isEmpty
            ? "var __LegadoInitValue = (\(trailingSplit.candidate));"
            : "\(trailingSplit.prefix); var __LegadoInitValue = (\(trailingSplit.candidate));"
        let body = [prefixLines, trailingLine]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let rewrittenScript = """
        (function() {
        \(body)
        return __LegadoInitValue;
        })()
        """
        return try parser.evaluateValue(script: rewrittenScript, result: html)
    }

    private static func extractRuleString(
        html: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        isUrl: Bool = false,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> String {
        let values = try extractRuleStringList(
            html: html,
            rule: rule,
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore,
            isUrl: isUrl,
            analyzerProvider: analyzerProvider
        )
        return values.first ?? ""
    }

    private static func extractRuleStringList(
        html: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        isUrl: Bool = false,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> [String] {
        if let directResults = try directExtractRuleStringList(
            html: html,
            rule: rule,
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore,
            isUrl: isUrl
        ) {
            return directResults
        }
        return try analyzerProvider().getStringList(content: html, rule: rule, isUrl: isUrl)
    }

    private static func directExtractRuleStringList(
        html: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore,
        isUrl: Bool
    ) throws -> [String]? {
        try ParserRuleRuntime.directExtractStringList(
            content: html,
            rule: rule,
            context: .init(baseUrl: baseUrl, source: source, variableStore: variableStore),
            isUrl: isUrl
        )
    }

    private static func directRenderTemplateRule(
        content: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore
    ) throws -> String? {
        try ParserRuleRuntime.directRenderTemplateRule(
            content: content,
            rule: rule,
            context: .init(baseUrl: baseUrl, source: source, variableStore: variableStore)
        )
    }

    private static func renderDirectLiteralURLRuleIfNeeded(
        content: String,
        rule: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore
    ) -> String? {
        ParserRuleRuntime.renderDirectLiteralURLIfNeeded(
            content: content,
            rule: rule,
            context: .init(baseUrl: baseUrl, source: source, variableStore: variableStore)
        )
    }

    private static func renderSimpleLiteralTemplateFallback(
        rule: String,
        variableStore: ParserVariableStore
    ) -> String? {
        ParserRuleRuntime.renderSimpleLiteralTemplateFallback(rule: rule, variableStore: variableStore)
    }

    private static func preferredLiteralURLBaseURL(
        renderedRule: String,
        pageBaseURL: String,
        sourceBaseURL: String
    ) -> String {
        ParserRuleRuntime.preferredLiteralURLBaseURL(
            renderedRule: renderedRule,
            pageBaseURL: pageBaseURL,
            sourceBaseURL: sourceBaseURL
        )
    }

    private static func recoverLiteralTocURLIfNeeded(
        currentURL: String,
        rule: String,
        pageBaseURL: String,
        sourceBaseURL: String,
        variableStore: ParserVariableStore
    ) -> String {
        ParserRuleRuntime.recoverLiteralURLIfNeeded(
            currentURL: currentURL,
            rule: rule,
            pageBaseURL: pageBaseURL,
            sourceBaseURL: sourceBaseURL,
            variableStore: variableStore
        )
    }

    private static func normalizedURLIdentity(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string?.lowercased() ?? trimmed.lowercased()
        }
        return trimmed.lowercased()
    }

    private static func rebaseResolvedURLIfNeeded(
        currentURL: String,
        pageBaseURL: String,
        preferredBaseURL: String
    ) -> String? {
        guard let currentComponents = URLComponents(string: currentURL),
              let pageURL = URL(string: pageBaseURL),
              let preferredURL = URL(string: preferredBaseURL),
              let currentHost = currentComponents.host?.lowercased(),
              let pageHost = pageURL.host?.lowercased(),
              let preferredHost = preferredURL.host?.lowercased(),
              currentHost == pageHost,
              currentHost != preferredHost else {
            return nil
        }

        let pagePath = pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard pagePath.isEmpty || pagePath == "index.html" else {
            return nil
        }

        var rebound = currentComponents
        rebound.scheme = preferredURL.scheme
        rebound.host = preferredURL.host
        rebound.port = preferredURL.port
        let reboundURL = rebound.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isValidResolvedURL(reboundURL) ? reboundURL : nil
    }

    private static func extractJSONPathStrings(from content: String, rule: String) throws -> [String] {
        try ParserRuleRuntime.extractJSONPathStrings(from: content, rule: rule)
    }

    private static func jsonCandidateStrings(from content: String) -> [String] {
        ParserRuleRuntime.jsonCandidateStrings(from: content)
    }

    private static func directEvaluateTemplateExpression(
        content: String,
        expression: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore
    ) throws -> String? {
        try ParserRuleRuntime.directEvaluateTemplateExpression(
            content: content,
            expression: expression,
            context: .init(baseUrl: baseUrl, source: source, variableStore: variableStore)
        )
    }

    private static func simpleTemplateVariableKey(_ expression: String) -> String? {
        ParserRuleRuntime.simpleTemplateVariableKey(expression)
    }

    private static func mergeTopLevelJSONScalars(
        from content: String,
        into variableStore: ParserVariableStore
    ) {
        for candidate in jsonCandidateStrings(from: content) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                continue
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
            return
        }
    }

    private static func bookTemplateVariableKey(_ expression: String) -> String? {
        ParserRuleRuntime.bookTemplateVariableKey(expression)
    }

    private static func canUseDirectRuleExtraction(_ rule: String) -> Bool {
        ParserRuleRuntime.canUseDirectRuleExtraction(rule)
    }

    private static func trailingStatementSplit(in line: String) -> (prefix: String, candidate: String)? {
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var segmentStart = line.startIndex

        for index in line.indices {
            let character = line[index]

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
            case ";":
                if parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    segmentStart = line.index(after: index)
                }
            default:
                break
            }
        }

        let candidate = String(line[segmentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.hasSuffix("}"),
              !candidate.hasSuffix("{") else {
            return nil
        }

        var prefix = String(line[..<segmentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.hasSuffix(";") {
            prefix.removeLast()
            prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (prefix, candidate)
    }

    private static func isValidResolvedURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let urlPart = AnalyzeUrl.extractedLiteralURLPart(from: trimmed)
        let validationTarget = urlPart.isEmpty ? trimmed : urlPart
        let lowered = validationTarget.lowercased()
        let invalidValues: Set<String> = [
            "url", "href", "src", "#", "javascript:", "javascript:;", "javascript:void(0)", "javascript:void(0);",
            "about:blank", "[]", "%5b%5d", "null", "undefined"
        ]
        guard !invalidValues.contains(lowered) else { return false }
        guard !looksLikeStructuredSelectorRule(validationTarget) else { return false }
        guard !lowered.hasPrefix("javascript:") else { return false }
        guard !lowered.contains("undefined") && !lowered.contains("null") else { return false }
        guard !lowered.contains("[]") && !lowered.contains("%5b%5d") else { return false }
        guard !trimmed.contains("{{"), !trimmed.contains("}}") else { return false }
        guard !lowered.hasSuffix("/url"), !lowered.hasSuffix("/href"), !lowered.hasSuffix("/src") else { return false }
        guard !lowered.contains("/novels//") && !lowered.contains("/novel//") else { return false }
        if validationTarget.hasPrefix("/") || validationTarget.hasPrefix("?") || validationTarget.hasPrefix("../") || validationTarget.hasPrefix("./") {
            return true
        }
        if validationTarget.hasPrefix("//"), !validationTarget.hasPrefix("///") {
            return false
        }
        if lowered.hasPrefix("https://minipapi.sfacg.com/pas/mpapi/novels/") && !lowered.contains("/dirs") {
            let suffix = lowered.replacingOccurrences(of: "https://minipapi.sfacg.com/pas/mpapi/novels/", with: "")
            if suffix.isEmpty || suffix.hasPrefix("?") || suffix.hasPrefix("/") {
                return false
            }
        }
        return true
    }

    private static func looksLikeStructuredSelectorRule(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("@css:") || lowered.hasPrefix("@xpath:") || lowered.hasPrefix("@json:") {
            return true
        }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/html") {
            return true
        }
        if trimmed.contains("@href") || trimmed.contains("@src") || trimmed.contains("@text") {
            return true
        }
        if trimmed.contains("text()") || trimmed.contains("::") {
            return true
        }
        return false
    }

    private static func inferTocURL(from html: String, baseUrl: String, bookUrl: String) -> String? {
        if let sfacgTocURL = inferSfacgMiniTocURL(bookUrl: bookUrl) {
            return sfacgTocURL
        }

        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        do {
            let document = try SwiftSoup.parse(html, baseUrl)
            defer { _ = document.empty() }

            let candidates = try document.select("a[href]").array()
            let keywords = ["目录", "章节", "列表", "catalog", "contents", "chapters", "mulu"]

            let scored = try candidates.compactMap { element -> (String, Int)? in
                let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidResolvedURL(href) else { return nil }

                let loweredHref = href.lowercased()
                let textScore = keywords.contains(where: { text.contains($0) }) ? 4 : 0
                let hrefScore = keywords.contains(where: { loweredHref.contains($0) }) ? 2 : 0
                let detailPenalty = (text.contains("阅读") || text.contains("正文")) ? -3 : 0
                let totalScore = textScore + hrefScore + detailPenalty
                guard totalScore > 0 else { return nil }

                let resolved = AnalyzeUrl.postProcessExtractedURL(href, baseUrl: baseUrl)
                guard isValidResolvedURL(resolved) else { return nil }
                return (resolved, totalScore)
            }

            let resolved = scored.max(by: { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.count < rhs.0.count
                }
                return lhs.1 < rhs.1
            })?.0

            guard let resolved, isValidResolvedURL(resolved) else { return nil }
            return resolved
        } catch {
            return nil
        }
    }

    private static func inferSfacgMiniTocURL(bookUrl: String) -> String? {
        let pattern = #"https?://minipapi\.sfacg\.com/pas/mpapi/novels/(\d+)(?:[/?].*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: bookUrl, range: NSRange(bookUrl.startIndex..., in: bookUrl)),
              let idRange = Range(match.range(at: 1), in: bookUrl) else {
            return nil
        }

        let novelID = String(bookUrl[idRange])
        return "https://minipapi.sfacg.com/pas/mpapi/novels/\(novelID)/dirs"
    }

    private static func shouldRejectLikelySearchPage(
        book: BookDetail,
        baseUrl: String,
        fallbackName: String,
        fallbackAuthor: String,
        resolvedTocFromRule: Bool
    ) -> Bool {
        guard !resolvedTocFromRule else { return false }
        guard looksLikeSearchPageURL(baseUrl) else { return false }

        let trimmedName = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallbackName = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallbackAuthor = fallbackAuthor.trimmingCharacters(in: .whitespacesAndNewlines)

        let reusedSearchIdentity = (trimmedName.isEmpty || trimmedName == normalizedFallbackName)
            && (trimmedAuthor.isEmpty || trimmedAuthor == normalizedFallbackAuthor)
        guard reusedSearchIdentity else { return false }

        let extractedSignals = [
            book.intro,
            book.kind,
            book.coverUrl,
            book.lastChapter,
            book.updateTime,
            book.wordCount
        ]
        let hasMeaningfulDetailSignal = extractedSignals.contains {
            guard let value = $0?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
            return value.lowercased() != "null" && value.lowercased() != "undefined"
        }
        if hasMeaningfulDetailSignal {
            return false
        }

        let normalizedBaseURL = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBookURL = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedBookURL.isEmpty, normalizedBookURL == normalizedBaseURL {
            return false
        }

        let normalizedTocURL = (book.tocUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTocURL.isEmpty,
           normalizedTocURL != normalizedBaseURL,
           !looksLikeSearchPageURL(normalizedTocURL) {
            return false
        }

        return true
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

    private static func injectBookContext(
        parser: JavaScriptParser,
        variableStore: ParserVariableStore,
        book: BookDetail,
        fallbackName: String,
        fallbackAuthor: String,
        fallbackKind: String
    ) {
        let name = book.name.isEmpty ? fallbackName : book.name
        let author = book.author.isEmpty ? fallbackAuthor : book.author
        let kind = (book.kind?.isEmpty == false ? book.kind : fallbackKind) ?? ""

        parser.injectBook(
            bookUrl: book.bookUrl,
            name: name,
            author: author,
            kind: kind,
            tocUrl: book.tocUrl ?? "",
            bookVariables: variableStore.snapshot(for: .book, includeInherited: true)
        )
    }

    private static func refreshBookContext(
        analyzer: AnalyzeRule?,
        runtimeStore: ParserVariableStore,
        book: BookDetail,
        fallbackName: String,
        fallbackAuthor: String,
        fallbackKind: String
    ) {
        let name = book.name.isEmpty ? fallbackName : book.name
        let author = book.author.isEmpty ? fallbackAuthor : book.author
        let kind = (book.kind?.isEmpty == false ? book.kind : fallbackKind) ?? ""

        runtimeStore.put("bookUrl", value: book.bookUrl, scope: .book)
        if !name.isEmpty {
            runtimeStore.put("name", value: name, scope: .book)
        }
        if !author.isEmpty {
            runtimeStore.put("author", value: author, scope: .book)
        }
        if !kind.isEmpty {
            runtimeStore.put("kind", value: kind, scope: .book)
        }
        if let tocUrl = book.tocUrl, !tocUrl.isEmpty {
            runtimeStore.put("tocUrl", value: tocUrl, scope: .book)
        }

        if let analyzer {
            analyzer.injectBookVariable(
                bookUrl: book.bookUrl,
                name: name,
                author: author,
                kind: kind,
                tocUrl: book.tocUrl ?? "",
                bookVariables: runtimeStore.snapshot(for: .book, includeInherited: true)
            )
        }
    }
}
