import Foundation

// MARK: - ParserStageKindV2

/// V2 parser/runtime 链路中的阶段标识。
///
/// H1 先显式把 search/detail/toc/content 的上下文边界抽出来，
/// 避免旧链路继续把阶段状态散落在 `WebBook` 和各 parser 的局部变量中。
nonisolated enum ParserStageKindV2: String, Sendable {
    case search
    case detail
    case toc
    case content
    case explore
}

// MARK: - ParserStageTransferV2

/// 阶段间传递的中间态快照。
///
/// Android `WebBook` 在 search -> detail -> toc -> content 切换时，
/// 实际上会持续复用一批“上一阶段拿到、下一阶段继续消费”的状态：
/// - `bookUrl`：书籍主链接，detail/toc/content 都可能继续引用
/// - `infoHtml`：搜索结果复用详情 HTML、详情阶段缓存 HTML
/// - `tocUrl` / `tocHtml`：目录阶段的目标链接与可复用 HTML
/// - `redirectUrl`：请求实际落地 URL，对齐 Android 的 redirect/baseUrl 语义
/// - `responseBody`：当前阶段拿到的原始文本响应，便于 parser 与 fallback 共享同一份输入
///
/// H4 开始统一把这些值收口到一处，避免它们继续散落在 `WebBookV2` 的局部变量里。
nonisolated struct ParserStageTransferV2: Sendable {
    var bookUrl: String?
    var infoHtml: String?
    var tocUrl: String?
    var tocHtml: String?
    var nextChapterUrl: String?
    var redirectUrl: String?
    var responseBody: String?

    init(
        bookUrl: String? = nil,
        infoHtml: String? = nil,
        tocUrl: String? = nil,
        tocHtml: String? = nil,
        nextChapterUrl: String? = nil,
        redirectUrl: String? = nil,
        responseBody: String? = nil
    ) {
        self.bookUrl = bookUrl
        self.infoHtml = infoHtml
        self.tocUrl = tocUrl
        self.tocHtml = tocHtml
        self.nextChapterUrl = nextChapterUrl
        self.redirectUrl = redirectUrl
        self.responseBody = responseBody
    }
}

// MARK: - ParserStageContextV2

/// V2 阶段解析上下文。
///
/// 这一层对应 Android `WebBook` 在阶段切换时携带的运行时状态：
/// - 当前书源
/// - 当前阶段
/// - baseUrl / requestUrl / responseUrl
/// - 阶段间传递的中间态快照
/// - 分层变量存储
/// - 书籍 / 章节语义快照
///
/// H1 不要求这里立刻承载所有 Android 语义，但必须先把“阶段边界”显式化。
nonisolated struct ParserStageContextV2: Sendable {
    var stage: ParserStageKindV2
    var source: BookSource
    var baseUrl: String
    var requestUrl: String?
    var responseUrl: String?
    var variableStore: ParserVariableStore
    var requestContext: LegadoRequestContextV2?
    var runtimeTrace: RuntimeTraceV2?
    var bookDetail: BookDetail?
    var chapter: BookChapter?
    var transfer: ParserStageTransferV2

    var bookUrl: String? { transfer.bookUrl }
    var infoHtml: String? { transfer.infoHtml }
    var tocUrl: String? { transfer.tocUrl }
    var tocHtml: String? { transfer.tocHtml }
    var nextChapterUrl: String? { transfer.nextChapterUrl }
    var redirectUrl: String? { transfer.redirectUrl }
    var responseBody: String? { transfer.responseBody }

    init(
        stage: ParserStageKindV2,
        source: BookSource,
        baseUrl: String,
        requestUrl: String? = nil,
        responseUrl: String? = nil,
        variableStore: ParserVariableStore = ParserVariableStore(),
        requestContext: LegadoRequestContextV2? = nil,
        runtimeTrace: RuntimeTraceV2? = nil,
        bookDetail: BookDetail? = nil,
        chapter: BookChapter? = nil,
        transfer: ParserStageTransferV2 = ParserStageTransferV2()
    ) {
        self.stage = stage
        self.source = source
        self.baseUrl = baseUrl
        self.requestUrl = requestUrl
        self.responseUrl = responseUrl
        self.variableStore = variableStore
        self.requestContext = requestContext
        self.runtimeTrace = runtimeTrace
        self.bookDetail = bookDetail
        self.chapter = chapter
        self.transfer = transfer
    }
}
