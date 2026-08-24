import Foundation
import SwiftSoup

// MARK: - ChapterContentParser（正文内容解析）

/// 解析章节内容页，提取正文
public nonisolated struct ChapterContentParser {

    /// 解析章节内容页
    /// - Parameters:
    ///   - html: 章节内容页 HTML 或 JSON
    ///   - bookSource: 书源配置
    ///   - chapter: 当前章节信息
    ///   - baseUrl: 基础 URL
    /// - Returns: 章节内容（包括正文、下一页 URL）
    public static func parse(
        html: String,
        bookSource: BookSource,
        chapter: BookChapter,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil
    ) throws -> ChapterContent {
        guard let rule = bookSource.ruleContent else {
            return ChapterContent(title: chapter.title)
        }

        ParserLog.debug(
            "ChapterContentParser",
            "parse start source=\(bookSource.bookSourceName) chapter=\(ParserLog.preview(chapter.title)) baseUrl=\(baseUrl)"
        )

        let runtimeStore = variableStore ?? ParserVariableStore(writeScope: .chapter)
        var content = ChapterContent(title: chapter.title)
        var analyzer: AnalyzeRule?

        func requireAnalyzer() -> AnalyzeRule {
            if let analyzer {
                return analyzer
            }
            let created = AnalyzeRule(baseUrl: baseUrl, source: bookSource, variableStore: runtimeStore)
            analyzer = created
            return created
        }

        // 提取标题（若有）
        if let titleRule = rule.title, !titleRule.isEmpty {
            let parsedTitle = try extractRuleString(
                html: html,
                rule: titleRule,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                analyzerProvider: requireAnalyzer
            )
            if !parsedTitle.isEmpty {
                content.title = parsedTitle
            }
            ParserLog.debug("ChapterContentParser", "title=\(ParserLog.preview(content.title))")
        }

        // 音频书源：优先解析可播放媒体 URL，不走文本格式化链路。
        if bookSource.bookSourceType == 1 {
            let mediaRule = rule.content ?? chapter.url
            let mediaURLs = try extractRuleStringList(
                html: html,
                rule: mediaRule,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                isUrl: true,
                analyzerProvider: requireAnalyzer
            ).filter { !$0.isEmpty }
            content.mediaURLs = Array(NSOrderedSet(array: mediaURLs)) as? [String] ?? mediaURLs
            content.contentType = "audio"
            content.content = content.mediaURLs.first ?? ""
        }

        // 提取正文内容
        if let contentRule = rule.content, !contentRule.isEmpty {
            let rawSegments = try extractContentSegments(
                html: html,
                rule: contentRule,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                analyzerProvider: requireAnalyzer
            )
            ParserLog.debug(
                "ChapterContentParser",
                "content nodes=\(rawSegments.count) previews=\(rawSegments.prefix(3).map { ParserLog.preview($0, limit: 60) })"
            )

            var rawContent = joinContentSegments(rawSegments)

            if let imageDecode = rule.imageDecode?.trimmingCharacters(in: .whitespacesAndNewlines), !imageDecode.isEmpty {
                rawContent = try applyImageDecodeIfNeeded(
                    rawContent,
                    imageDecode: imageDecode,
                    baseUrl: baseUrl,
                    source: bookSource,
                    variableStore: runtimeStore
                )
            }

            rawContent = formatContent(
                rawContent,
                baseUrl: baseUrl,
                source: bookSource
            )

            // 应用来源正则过滤（书源广告过滤）
            if let sourceRegex = rule.sourceRegex, !sourceRegex.isEmpty {
                rawContent = (try? RegexParser.replace(rawContent, pattern: sourceRegex, replacement: "")) ?? rawContent
            }

            // 应用替换规则（格式化正文）
            if let replaceRegex = rule.replaceRegex, !replaceRegex.isEmpty {
                rawContent = applyReplaceRegex(rawContent, ruleString: replaceRegex)
            }

            if bookSource.bookSourceType == 0 {
                rawContent = reindentParagraphs(rawContent)
            }
            content.content = HtmlFormatter.normalizeContentText(rawContent, preserveImages: bookSource.bookSourceType == 2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if content.content.isEmpty, !rawSegments.isEmpty {
                content.content = rescueContentFromSegments(
                    rawSegments,
                    baseUrl: baseUrl,
                    source: bookSource,
                    sourceRegex: rule.sourceRegex,
                    replaceRegex: rule.replaceRegex
                )
            }
            if bookSource.bookSourceType == 2 {
                content.contentType = "image"
                content.mediaURLs = extractImageURLs(from: rawContent, baseUrl: baseUrl)
            }
            if content.content.isEmpty,
               bookSource.bookSourceType == 0,
               let recovered = recoverHTMLBodyContent(html: html, baseUrl: baseUrl),
               !recovered.isEmpty {
                content.content = recovered
            }
            ParserLog.debug("ChapterContentParser", "content chars=\(content.content.count)")
        }

        // 提取下一页 URL（分页内容）
        if let nextUrlRule = rule.nextContentUrl, !nextUrlRule.isEmpty {
            let rawValues = try extractRuleStringList(
                html: html,
                rule: nextUrlRule,
                baseUrl: baseUrl,
                bookSource: bookSource,
                variableStore: runtimeStore,
                analyzerProvider: requireAnalyzer
            )
            let nextPageURLs = rawValues.flatMap {
                AnalyzeUrl.postProcessExtractedURLs($0, baseUrl: baseUrl, variableStore: runtimeStore)
            }
            if !nextPageURLs.isEmpty {
                content.nextPageUrl = nextPageURLs.joined(separator: "\n")
            }
            ParserLog.debug(
                "ChapterContentParser",
                "next raw=\(rawValues.map { ParserLog.preview($0, limit: 80) }) cleaned=\(nextPageURLs.map { ParserLog.preview($0, limit: 80) })"
            )
        }

        ParserLog.debug(
            "ChapterContentParser",
            "parse done title=\(ParserLog.preview(content.title)) chars=\(content.content.count)"
        )
        return content
    }

    /// 合并多页内容（分页加载）
    /// - Parameter pages: 各页 ChapterContent 列表
    /// - Returns: 合并后的章节内容
    public static func mergePages(_ pages: [ChapterContent]) -> ChapterContent {
        guard !pages.isEmpty else { return ChapterContent() }
        let title = pages.first?.title ?? ""
        let contentType = pages.first?.contentType ?? "text"
        let mediaURLs = Array(NSOrderedSet(array: pages.flatMap(\.mediaURLs))) as? [String] ?? pages.flatMap(\.mediaURLs)
        var seenPages: Set<String> = []
        let combinedPages = pages.compactMap { page -> String? in
            let normalized = page.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            if seenPages.insert(normalized).inserted {
                return normalized
            }
            return nil
        }
        let combined = combinedPages.joined(separator: "\n\n")
        return ChapterContent(title: title, content: combined, mediaURLs: mediaURLs, contentType: contentType)
    }

    // MARK: - 私有方法

    /// 应用书源替换规则
    /// 替换规则格式：`##pattern##replacement`，多条用换行分隔
    private static func applyReplaceRegex(_ content: String, ruleString: String) -> String {
        let rules = ruleString.components(separatedBy: "\n").filter { !$0.isEmpty }
        var result = content
        for rule in rules {
            result = (try? RegexParser.applyReplaceRule(result, rule: rule)) ?? result
        }
        return result
    }

    private static func reindentParagraphs(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            guard !trimmed.hasPrefix("<img") else { return trimmed }
            guard !looksLikeChapterTitle(trimmed) else { return trimmed }
            return "　　" + trimmed
        }.joined(separator: "\n")
    }

    private static func looksLikeChapterTitle(_ line: String) -> Bool {
        // 匹配「第X章/节/篇/回/集/话/卷」格式
        if line.range(of: "第.+?[章节篇回集话卷]", options: .regularExpression) != nil {
            return true
        }

        // 纯大写英文字母行（英文书名、章节标识）
        if line == line.uppercased(), line.rangeOfCharacter(from: .letters) != nil {
            return true
        }

        return false
    }

    private static func recoverHTMLBodyContent(html: String, baseUrl: String) -> String? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else {
            return nil
        }
        guard let document = try? SwiftSoup.parse(html, baseUrl) else { return nil }
        defer { _ = document.empty() }

        let selectors = [
            "article", "main", "[id*=content]", "[class*=content]", "[class*=read]",
            "[class*=chapter]", "[class*=article]", "[class*=text]", "[class*=section]"
        ]

        var best = ""
        for selector in selectors {
            guard let elements = try? document.select(selector).array() else { continue }
            for element in elements {
                guard let text = cleanedReadableText(from: element), text.count > best.count else { continue }
                best = text
            }
        }

        guard best.count >= 120 else { return nil }
        return HtmlFormatter.normalizeContentText(reindentParagraphs(best)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedReadableText(from element: Element) -> String? {
        let paragraphs = (try? element.select("p").array()) ?? []
        var lines = paragraphs.compactMap { paragraph in
            (try? paragraph.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if lines.count < 3, let text = try? element.text() {
            lines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        guard !lines.isEmpty else { return nil }
        let noiseTerms = ["上一章", "下一章", "返回目录", "加入书签", "推荐阅读", "Loading..."]
        let cleaned = lines.filter { line in
            !noiseTerms.contains(where: { line.contains($0) })
        }.joined(separator: "\n")

        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 120 ? trimmed : nil
    }

    private static func applyImageDecodeIfNeeded(
        _ content: String,
        imageDecode: String,
        baseUrl: String,
        source: BookSource,
        variableStore: ParserVariableStore
    ) throws -> String {
        let parser = JavaScriptParser(baseUrl: baseUrl, source: source, variableStore: variableStore)
        parser.updateContextContent(content)
        let decoded = try parser.evaluate(script: imageDecode, result: content)
        return decoded.isEmpty ? content : decoded
    }

    private static func extractContentSegments(
        html: String,
        rule: String,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> [String] {
        let segments = try extractRuleStringList(
            html: html,
            rule: rule,
            baseUrl: baseUrl,
            bookSource: bookSource,
            variableStore: variableStore,
            analyzerProvider: analyzerProvider
        )
        if !segments.isEmpty {
            return segments
        }

        let single = try extractRuleString(
            html: html,
            rule: rule,
            baseUrl: baseUrl,
            bookSource: bookSource,
            variableStore: variableStore,
            analyzerProvider: analyzerProvider
        )
        return single.isEmpty ? [] : [single]
    }

    private static func extractRuleString(
        html: String,
        rule: String,
        baseUrl: String,
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        isUrl: Bool = false,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> String {
        let values = try extractRuleStringList(
            html: html,
            rule: rule,
            baseUrl: baseUrl,
            bookSource: bookSource,
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
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        isUrl: Bool = false,
        analyzerProvider: () -> AnalyzeRule
    ) throws -> [String] {
        if let directResults = try directExtractRuleStringList(
            html: html,
            rule: rule,
            baseUrl: baseUrl,
            bookSource: bookSource,
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
        bookSource: BookSource,
        variableStore: ParserVariableStore,
        isUrl: Bool
    ) throws -> [String]? {
        try ParserRuleRuntime.directExtractStringList(
            content: html,
            rule: rule,
            context: .init(
                baseUrl: baseUrl,
                source: bookSource,
                variableStore: variableStore
            ),
            isUrl: isUrl
        )
    }

    private static func canUseDirectRuleExtraction(_ rule: String) -> Bool {
        ParserRuleRuntime.canUseDirectRuleExtraction(rule)
    }

    private static func joinContentSegments(_ segments: [String]) -> String {
        guard !segments.isEmpty else { return "" }

        var collected: [String] = []
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if collected.last == trimmed { continue }
            collected.append(trimmed)
        }
        return collected.joined(separator: "\n")
    }

    private static func formatContent(
        _ rawContent: String,
        baseUrl: String,
        source: BookSource
    ) -> String {
        guard !rawContent.isEmpty else { return "" }

        if source.bookSourceType == 2 {
            return HtmlFormatter.formatKeepImages(rawContent, baseUrl: baseUrl)
        }

        if looksLikeHTML(rawContent) {
            return HtmlFormatter.format(rawContent)
        }

        return HtmlFormatter.normalizeContentText(rawContent)
    }

    private static func rescueContentFromSegments(
        _ segments: [String],
        baseUrl: String,
        source: BookSource,
        sourceRegex: String?,
        replaceRegex: String?
    ) -> String {
        let cleanedSegments = segments.compactMap { segment -> String? in
            var candidate = formatContent(segment, baseUrl: baseUrl, source: source)
            if let sourceRegex, !sourceRegex.isEmpty {
                candidate = (try? RegexParser.replace(candidate, pattern: sourceRegex, replacement: "")) ?? candidate
            }
            if let replaceRegex, !replaceRegex.isEmpty {
                candidate = applyReplaceRegex(candidate, ruleString: replaceRegex)
            }
            candidate = HtmlFormatter.normalizeContentText(candidate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }

        guard !cleanedSegments.isEmpty else { return "" }

        let joined = cleanedSegments.joined(separator: "\n")
        if source.bookSourceType == 0 {
            return reindentParagraphs(joined)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joined
    }

    private static func looksLikeHTML(_ content: String) -> Bool {
        content.range(of: #"<[a-zA-Z/][^>]*>"#, options: .regularExpression) != nil
    }

    private static func extractImageURLs(from content: String, baseUrl: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]+src=['\"]([^'\"]+)['\"]"#, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        return matches.compactMap { match in
            guard let srcRange = Range(match.range(at: 1), in: content) else { return nil }
            let raw = String(content[srcRange])
            guard let base = URL(string: baseUrl), let resolved = URL(string: raw, relativeTo: base) else {
                return raw
            }
            return resolved.absoluteString
        }
    }

}
