import Foundation

// MARK: - LegadoRequestContextV2

/// V2 请求运行时上下文。
///
/// 这一层对应 Android `AnalyzeUrl` / `WebBook` 在单次请求前后共享的环境：
/// - 书源
/// - 当前活动 source URL
/// - 分层变量存储
/// - timeout / cookie / webView 能力开关
/// - trace 句柄
///
/// H1 先把这些能力显式化，后续 H2/H3 再继续把旧 `WebBook` 内部逻辑逐步下沉到这层。
nonisolated struct LegadoRequestContextV2: Sendable {
    var source: BookSource
    var sourceRuntimeContext: SourceRuntimeContext
    var variableStore: ParserVariableStore
    var maximumRequestTimeout: TimeInterval
    var allowsWebViewRequests: Bool
    var allowsAutomaticWebViewRecovery: Bool
    var runtimeTrace: RuntimeTraceV2?

    init(
        source: BookSource,
        sourceRuntimeContext: SourceRuntimeContext? = nil,
        variableStore: ParserVariableStore = ParserVariableStore(writeScope: .source),
        maximumRequestTimeout: TimeInterval = 60,
        allowsWebViewRequests: Bool = true,
        allowsAutomaticWebViewRecovery: Bool = true,
        runtimeTrace: RuntimeTraceV2? = nil
    ) {
        self.source = source
        self.sourceRuntimeContext = sourceRuntimeContext ?? SourceRuntimeContext(sourceURL: source.bookSourceUrl)
        self.variableStore = variableStore
        self.maximumRequestTimeout = maximumRequestTimeout
        self.allowsWebViewRequests = allowsWebViewRequests
        self.allowsAutomaticWebViewRecovery = allowsAutomaticWebViewRecovery
        self.runtimeTrace = runtimeTrace
    }

    var activeSourceURL: String {
        sourceRuntimeContext.currentSourceURL
    }

    /// 为单次请求生成 source 对齐后的默认请求头。
    ///
    /// Android `WebBook` 在真正发请求前会结合“当前已学习到的 source URL”
    /// 和书源 header 规则来准备默认头。这里把这一步显式挂到 request context，
    /// 让 `RequestExecutorV2` 可以独立完成 transport 配置，而不是再向 `WebBookV2` 反查。
    func resolvedSourceHeaders() -> [String: String] {
        HTTPClient.resolvedSourceHeaders(baseUrl: activeSourceURL, source: source)
    }

    /// 将书源里持久化的 cookieJar 回灌到执行层的 HTTPClient。
    ///
    /// 旧 `WebBook` 会在每次 active client 初始化时做这件事。H3 把语义收口到
    /// request context + executor，使“请求前的 cookie 环境准备”成为统一能力。
    func restoreCookieJarIfNeeded(into client: HTTPClient) {
        guard let cookieString = source.cookieJar,
              !cookieString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: activeSourceURL) else {
            return
        }
        client.cookieManager.parseCookieString(cookieString, domain: url.host ?? "")
    }

    mutating func seedSourceVariables(_ values: [String: String]) {
        guard !values.isEmpty else { return }
        variableStore.merge(values, into: .source)
    }

    mutating func learnRuntimeSource(from responseURL: URL?) {
        guard sourceRuntimeContext.learn(from: responseURL) else { return }
        var updatedSource = source
        let current = sourceRuntimeContext.currentSourceURL
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedSource.bookSourceUrl = current
        }
        source = updatedSource
    }

    func makeSourceRuntimeStore() -> ParserVariableStore {
        variableStore.cloned(writeScope: .source)
    }

    func makeBookRuntimeStore(
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        fallbackVariables: [String: String] = [:]
    ) -> ParserVariableStore {
        let store = ParserVariableStore(
            sourceValues: sourceVariables.isEmpty ? variableStore.snapshot(for: .source, includeInherited: false) : sourceVariables,
            ruleDataValues: [:],
            bookValues: bookVariables,
            chapterValues: [:],
            writeScope: .book
        )
        if !fallbackVariables.isEmpty {
            store.merge(fallbackVariables, into: .book)
        }
        return store
    }

    func makeChapterRuntimeStore(
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        chapterVariables: [String: String] = [:],
        fallbackVariables: [String: String] = [:]
    ) -> ParserVariableStore {
        let store = ParserVariableStore(
            sourceValues: sourceVariables.isEmpty ? variableStore.snapshot(for: .source, includeInherited: false) : sourceVariables,
            ruleDataValues: [:],
            bookValues: bookVariables,
            chapterValues: chapterVariables,
            writeScope: .chapter
        )
        if !fallbackVariables.isEmpty {
            store.merge(fallbackVariables, into: .chapter)
        }
        return store
    }
}
