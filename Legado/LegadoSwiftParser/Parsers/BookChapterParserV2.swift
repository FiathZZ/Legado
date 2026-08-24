import Foundation

// MARK: - BookChapterParserV2

/// V2 目录解析器。
///
/// H6 的目标不是重写所有字段提取细节，而是把 Android 目录阶段真正需要统一的语义
/// 收口到一处：
/// - `RuleRuntimeV2` 统一承接 `infoHtml` / `tocHtml` / `book` / `result`
/// - `nextTocUrl` 从目录页结构里单独解析，供 `WebBookV2` 决定串行还是并发翻页
/// - “可用章节”判定和空链接保留语义交给上层编排，不再让 parser 与翻页流程互相穿透
///
/// 章节字段本身仍复用已验证过的旧 `BookChapterParser`，避免 H6 同时引入大面积字段回归。
nonisolated struct BookChapterParserV2 {
    struct PageResult {
        let chapters: [BookChapter]
        let nextTocUrls: [String]
    }

    static func parse(
        html: String,
        bookUrl: String,
        context: ParserStageContextV2,
        bookName: String = "",
        bookAuthor: String = "",
        bookKind: String = "",
        tocUrl: String = "",
        bookVariables: [String: String] = [:]
    ) throws -> (chapters: [BookChapter], nextTocUrls: [String]) {
        let page = try parsePage(
            html: html,
            bookUrl: bookUrl,
            context: context,
            bookName: bookName,
            bookAuthor: bookAuthor,
            bookKind: bookKind,
            tocUrl: tocUrl,
            bookVariables: bookVariables
        )
        return (page.chapters, page.nextTocUrls)
    }

    static func parsePage(
        html: String,
        bookUrl: String,
        context: ParserStageContextV2,
        bookName: String = "",
        bookAuthor: String = "",
        bookKind: String = "",
        tocUrl: String = "",
        bookVariables: [String: String] = [:]
    ) throws -> PageResult {
        guard let rule = context.source.ruleToc else {
            return PageResult(chapters: [], nextTocUrls: [])
        }

        let runtime = StageRuntimeFactoryV2.makeRuleRuntime(from: context)
        let effectiveBookURL = firstNonEmpty(
            bookUrl,
            context.bookUrl,
            context.bookDetail?.bookUrl
        )
        let effectiveTocURL = firstNonEmpty(
            tocUrl,
            context.tocUrl,
            context.bookDetail?.tocUrl,
            context.baseUrl
        )
        let fallbackName = firstNonEmpty(bookName, context.bookDetail?.name, context.variableStore.get("name"))
        let fallbackAuthor = firstNonEmpty(bookAuthor, context.bookDetail?.author, context.variableStore.get("author"))
        let fallbackKind = firstNonEmpty(bookKind, context.bookDetail?.kind, context.variableStore.get("kind"))
        let mergedBookVariables = bookVariables.isEmpty
            ? context.variableStore.snapshot(for: .book, includeInherited: true)
            : bookVariables

        runtime.injectBookVariable(
            bookUrl: effectiveBookURL,
            name: fallbackName,
            author: fallbackAuthor,
            kind: fallbackKind,
            tocUrl: effectiveTocURL,
            bookVariables: mergedBookVariables
        )
        runtime.updateContextContent(html)

        // TOC item rules run with Android's current page URL as `baseUrl`, not the
        // source root. JSON directory sources rely on this for templates such as
        // `{{baseUrl.replace('?paging=0','')}}/{{$.chapter_id}}`.
        let tocPageBaseURL = firstNonEmpty(context.redirectUrl, context.responseUrl, effectiveTocURL, context.baseUrl)

        let nextTocUrls = try extractNextTocURLs(
            html: html,
            rule: rule,
            runtime: runtime,
            baseUrl: tocPageBaseURL,
            currentURL: tocPageBaseURL
        )

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: context.source,
            bookUrl: effectiveBookURL,
            baseUrl: tocPageBaseURL,
            variableStore: context.variableStore,
            bookName: fallbackName,
            bookAuthor: fallbackAuthor,
            bookKind: fallbackKind,
            tocUrl: effectiveTocURL,
            bookVariables: mergedBookVariables
        )

        let effectiveNextTocURLs = nextTocUrls.isEmpty ? parsed.nextTocUrls : nextTocUrls
        return PageResult(chapters: parsed.chapters, nextTocUrls: effectiveNextTocURLs)
    }

    static func mergeChapters(_ chapterLists: [[BookChapter]]) -> [BookChapter] {
        BookChapterParser.mergeChapters(chapterLists)
    }

    private static func extractNextTocURLs(
        html: String,
        rule: TocRule,
        runtime: RuleRuntimeV2,
        baseUrl: String,
        currentURL: String
    ) throws -> [String] {
        guard let nextRule = rule.nextTocUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nextRule.isEmpty else {
            return []
        }

        let rawValues = try runtime.getStringList(content: html, rule: nextRule, isUrl: false)
        var seen: Set<String> = []
        var urls: [String] = []

        for rawValue in rawValues {
            for candidate in AnalyzeUrlV2.postProcessExtractedURLs(rawValue, baseUrl: baseUrl, variableStore: runtime.variableStore) {
                let identity = normalizedURLIdentity(candidate)
                guard !identity.isEmpty, identity != normalizedURLIdentity(currentURL) else {
                    continue
                }
                if seen.insert(identity).inserted {
                    urls.append(candidate)
                }
            }
        }

        return urls
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
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
