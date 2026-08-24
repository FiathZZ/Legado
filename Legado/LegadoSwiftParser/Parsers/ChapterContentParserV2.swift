import Foundation

// MARK: - ChapterContentParserV2

/// V2 正文解析器。
///
/// H6 明确把正文链路拆成三层责任：
/// 1. 抽取：当前页如何从 `content` 规则里拿到正文主体
/// 2. 结构：`nextContentUrl` 如何作为“下一页入口”暴露给上层编排
/// 3. 净化：拼页后的全文后处理继续复用成熟实现
///
/// 当前页正文抽取和净化仍复用旧 `ChapterContentParser`，但 `nextContentUrl` 会先通过统一
/// `RuleRuntimeV2` 解析并做“下一章误判”过滤，避免分页结构语义继续散在旧链路里。
nonisolated struct ChapterContentParserV2 {
    struct PageResult {
        let content: ChapterContent
        let nextContentURLs: [String]
    }

    static func parse(
        html: String,
        chapter: BookChapter,
        context: ParserStageContextV2
    ) throws -> ChapterContent {
        try parsePage(html: html, chapter: chapter, context: context).content
    }

    static func parsePage(
        html: String,
        chapter: BookChapter,
        context: ParserStageContextV2
    ) throws -> PageResult {
        guard let rule = context.source.ruleContent else {
            return PageResult(content: ChapterContent(title: chapter.title), nextContentURLs: [])
        }

        let runtime = StageRuntimeFactoryV2.makeRuleRuntime(from: context)
        runtime.injectBookVariable(
            bookUrl: chapter.bookUrl,
            name: context.variableStore.get("name"),
            author: context.variableStore.get("author"),
            kind: context.variableStore.get("kind"),
            tocUrl: context.tocUrl ?? chapter.baseUrl,
            bookVariables: context.variableStore.snapshot(for: .book, includeInherited: true)
        )
        runtime.injectChapterVariable(chapter: chapter, nextChapterUrl: context.nextChapterUrl)
        runtime.updateContextContent(html)

        let parsed = try ChapterContentParser.parse(
            html: html,
            bookSource: context.source,
            chapter: chapter,
            baseUrl: context.baseUrl,
            variableStore: context.variableStore
        )
        let nextContentURLs = try extractNextContentURLs(
            html: html,
            rule: rule,
            runtime: runtime,
            baseUrl: context.baseUrl,
            currentURL: context.redirectUrl ?? context.responseUrl ?? context.baseUrl,
            nextChapterUrl: context.nextChapterUrl
        )

        var effectiveContent = parsed
        if !nextContentURLs.isEmpty {
            effectiveContent.nextPageUrl = nextContentURLs.joined(separator: "\n")
        } else {
            effectiveContent.nextPageUrl = nil
        }

        return PageResult(content: effectiveContent, nextContentURLs: nextContentURLs)
    }

    static func mergePages(_ pages: [ChapterContent]) -> ChapterContent {
        ChapterContentParser.mergePages(pages)
    }

    private static func extractNextContentURLs(
        html: String,
        rule: ContentRule,
        runtime: RuleRuntimeV2,
        baseUrl: String,
        currentURL: String,
        nextChapterUrl: String?
    ) throws -> [String] {
        guard let nextRule = rule.nextContentUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nextRule.isEmpty else {
            return []
        }

        let currentIdentity = normalizedURLIdentity(currentURL)
        let nextChapterIdentity = normalizedURLIdentity(
            AnalyzeUrlV2.postProcessExtractedURL(nextChapterUrl ?? "", baseUrl: baseUrl, variableStore: runtime.variableStore)
        )
        let rawValues = try runtime.getStringList(content: html, rule: nextRule, isUrl: false)

        var seen: Set<String> = []
        var urls: [String] = []
        for rawValue in rawValues {
            for candidate in AnalyzeUrlV2.postProcessExtractedURLs(rawValue, baseUrl: baseUrl, variableStore: runtime.variableStore) {
                let identity = normalizedURLIdentity(candidate)
                guard !identity.isEmpty, identity != currentIdentity else {
                    continue
                }
                guard nextChapterIdentity.isEmpty || identity != nextChapterIdentity else {
                    continue
                }
                if seen.insert(identity).inserted {
                    urls.append(candidate)
                }
            }
        }

        return urls
    }

    private static func normalizedURLIdentity(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let components = URLComponents(string: trimmed) else { return trimmed }

        var normalized = components
        normalized.scheme = normalized.scheme?.lowercased()
        normalized.host = normalized.host?.lowercased()
        return normalized.string ?? trimmed
    }
}
