import Foundation

// MARK: - StageRuntimeFactoryV2

/// V2 runtime 工厂。
///
/// H4 开始它除了装配 `RuleRuntimeV2` 之外，也统一负责把“请求响应 / 缓存 HTML / 业务语义对象”
/// 组织成阶段上下文。这样 `WebBookV2` 只需要表达业务编排，不再手工拼 request/base/redirect/info/toc 中间态。
nonisolated enum StageRuntimeFactoryV2 {
    private static func makeTransfer(
        bookUrl: String? = nil,
        infoHtml: String? = nil,
        tocUrl: String? = nil,
        tocHtml: String? = nil,
        nextChapterUrl: String? = nil,
        redirectUrl: String? = nil,
        responseBody: String? = nil
    ) -> ParserStageTransferV2 {
        ParserStageTransferV2(
            bookUrl: bookUrl,
            infoHtml: infoHtml,
            tocUrl: tocUrl,
            tocHtml: tocHtml,
            nextChapterUrl: nextChapterUrl,
            redirectUrl: redirectUrl,
            responseBody: responseBody
        )
    }

    static func makeSearchContext(
        source: BookSource,
        requestContext: LegadoRequestContextV2,
        variableStore: ParserVariableStore,
        responseContext: LegadoResponseContextV2
    ) -> ParserStageContextV2 {
        ParserStageContextV2(
            stage: .search,
            source: source,
            baseUrl: responseContext.baseUrl,
            requestUrl: responseContext.requestUrl,
            responseUrl: responseContext.responseUrl,
            variableStore: variableStore,
            requestContext: requestContext,
            runtimeTrace: requestContext.runtimeTrace,
            transfer: makeTransfer(
                redirectUrl: responseContext.responseUrl,
                responseBody: responseContext.text
            )
        )
    }

    static func makeDetailContext(
        source: BookSource,
        requestContext: LegadoRequestContextV2,
        variableStore: ParserVariableStore,
        bookUrl: String,
        seedDetail: BookDetail? = nil,
        responseContext: LegadoResponseContextV2? = nil,
        cachedHTML: String? = nil
    ) -> ParserStageContextV2 {
        let responseBaseURL = responseContext?.baseUrl ?? bookUrl
        let responseURL = responseContext?.responseUrl ?? bookUrl
        let infoHTML = responseContext?.text ?? cachedHTML
        var detail = seedDetail ?? BookDetail(
            bookUrl: bookUrl,
            origin: requestContext.activeSourceURL,
            sourceVariables: variableStore.snapshot(for: .source, includeInherited: false),
            bookVariables: variableStore.snapshot(for: .book, includeInherited: true),
            variables: variableStore.snapshot(for: .book, includeInherited: true)
        )
        detail.infoHtml = infoHTML

        return ParserStageContextV2(
            stage: .detail,
            source: source,
            baseUrl: responseBaseURL,
            requestUrl: responseContext?.requestUrl,
            responseUrl: responseURL,
            variableStore: variableStore,
            requestContext: requestContext,
            runtimeTrace: requestContext.runtimeTrace,
            bookDetail: detail,
            transfer: makeTransfer(
                bookUrl: bookUrl,
                infoHtml: infoHTML,
                redirectUrl: responseURL,
                responseBody: infoHTML
            )
        )
    }

    static func makeTocContext(
        source: BookSource,
        requestContext: LegadoRequestContextV2,
        variableStore: ParserVariableStore,
        bookDetail: BookDetail,
        responseContext: LegadoResponseContextV2? = nil,
        cachedHTML: String? = nil
    ) -> ParserStageContextV2 {
        let tocURL = bookDetail.tocUrl ?? bookDetail.bookUrl
        let responseBaseURL = responseContext?.baseUrl ?? tocURL
        let responseURL = responseContext?.responseUrl ?? tocURL
        let tocHTML = responseContext?.text ?? cachedHTML
        var detail = bookDetail
        detail.tocHtml = tocHTML

        return ParserStageContextV2(
            stage: .toc,
            source: source,
            baseUrl: responseBaseURL,
            requestUrl: responseContext?.requestUrl,
            responseUrl: responseURL,
            variableStore: variableStore,
            requestContext: requestContext,
            runtimeTrace: requestContext.runtimeTrace,
            bookDetail: detail,
            transfer: makeTransfer(
                bookUrl: bookDetail.bookUrl,
                infoHtml: bookDetail.infoHtml,
                tocUrl: tocURL,
                tocHtml: tocHTML,
                redirectUrl: responseURL,
                responseBody: tocHTML
            )
        )
    }

    static func makeContentContext(
        source: BookSource,
        requestContext: LegadoRequestContextV2,
        variableStore: ParserVariableStore,
        chapter: BookChapter,
        responseContext: LegadoResponseContextV2,
        nextChapterUrl: String? = nil
    ) -> ParserStageContextV2 {
        ParserStageContextV2(
            stage: .content,
            source: source,
            baseUrl: responseContext.baseUrl,
            requestUrl: responseContext.requestUrl,
            responseUrl: responseContext.responseUrl,
            variableStore: variableStore,
            requestContext: requestContext,
            runtimeTrace: requestContext.runtimeTrace,
            chapter: chapter,
            transfer: makeTransfer(
                bookUrl: chapter.bookUrl,
                tocUrl: chapter.baseUrl,
                nextChapterUrl: nextChapterUrl,
                redirectUrl: responseContext.responseUrl,
                responseBody: responseContext.text
            )
        )
    }

    static func makeRuleRuntime(from stageContext: ParserStageContextV2) -> RuleRuntimeV2 {
        RuleRuntimeV2(stageContext: stageContext)
    }
}
