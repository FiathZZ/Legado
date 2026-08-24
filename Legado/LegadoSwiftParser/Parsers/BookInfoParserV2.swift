import Foundation

// MARK: - BookInfoParserV2

/// V2 详情解析器。
///
/// H5 这里保持“统一 runtime、复用成熟字段提取”的策略：
/// - `RuleRuntimeV2` 负责把 search/detail 连续上下文先灌进来
/// - 详情字段解析仍复用已经验证过的旧 `BookInfoParser`
/// - V2 额外收口 search -> detail 传递的 `infoHtml` / `book` / `baseUrl` 语义
nonisolated struct BookInfoParserV2 {
    static func parse(
        html: String,
        bookUrl: String,
        context: ParserStageContextV2,
        bookName: String = "",
        bookAuthor: String = "",
        bookKind: String = ""
    ) throws -> BookDetail {
        let runtime = StageRuntimeFactoryV2.makeRuleRuntime(from: context)
        let source = context.source
        let effectiveBookURL = resolvedBookURL(bookUrl: bookUrl, context: context)
        let effectiveBaseURL = resolvedBaseURL(for: effectiveBookURL, context: context)
        let fallbackName = preferredName(bookName, context: context)
        let fallbackAuthor = preferredAuthor(bookAuthor, context: context)
        let fallbackKind = preferredKind(bookKind, context: context)

        runtime.injectBookVariable(
            bookUrl: effectiveBookURL,
            name: fallbackName,
            author: fallbackAuthor,
            kind: fallbackKind,
            tocUrl: context.tocUrl ?? context.bookDetail?.tocUrl ?? "",
            bookVariables: context.variableStore.snapshot(for: .book, includeInherited: true)
        )

        var detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: effectiveBookURL,
            baseUrl: effectiveBaseURL,
            variableStore: context.variableStore,
            bookName: fallbackName,
            bookAuthor: fallbackAuthor,
            bookKind: fallbackKind
        )

        detail.infoHtml = context.infoHtml ?? html
        if detail.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail.bookUrl = effectiveBookURL
        }
        if detail.origin.isEmpty {
            detail.origin = source.bookSourceUrl
        }
        if detail.tocUrl == detail.bookUrl {
            detail.tocHtml = detail.infoHtml
        }

        return detail
    }

    private static func resolvedBookURL(bookUrl: String, context: ParserStageContextV2) -> String {
        let candidates = [
            bookUrl,
            context.bookUrl,
            context.bookDetail?.bookUrl,
            context.redirectUrl,
            context.responseUrl,
            context.baseUrl
        ]
        return candidates
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func resolvedBaseURL(for bookURL: String, context: ParserStageContextV2) -> String {
        let candidates = [
            context.redirectUrl,
            context.responseUrl,
            context.baseUrl,
            bookURL
        ]
        return candidates
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            .first(where: { !$0.isEmpty }) ?? bookURL
    }

    private static func preferredName(_ explicit: String, context: ParserStageContextV2) -> String {
        let candidates = [
            explicit,
            context.bookDetail?.name ?? "",
            context.variableStore.get("name")
        ]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func preferredAuthor(_ explicit: String, context: ParserStageContextV2) -> String {
        let candidates = [
            explicit,
            context.bookDetail?.author ?? "",
            context.variableStore.get("author")
        ]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func preferredKind(_ explicit: String, context: ParserStageContextV2) -> String {
        let candidates = [
            explicit,
            context.bookDetail?.kind ?? "",
            context.variableStore.get("kind")
        ]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
