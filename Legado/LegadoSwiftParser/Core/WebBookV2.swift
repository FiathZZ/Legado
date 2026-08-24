import Foundation

// MARK: - WebBookV2

/// Android 对齐式 V2 编排层。
///
/// H4 之后，这里只保留 search / detail / toc / content 的阶段编排职责：
/// - 准备阶段输入与变量域
/// - 判断复用缓存 HTML 还是发起请求
/// - 接住 executor 产出的标准响应上下文并切到对应 parser
/// - 保留少量仍属于业务流的高层 fallback
///
/// 请求细节、规则执行细节和 parser 细节都继续留在下层：
/// - URL 规则解释：`AnalyzeUrlV2`
/// - 请求执行：`RequestExecutorV2`
/// - 内容规则 runtime：`RuleRuntimeV2`
/// - 阶段解析：`*ParserV2`
///
/// 这样 `WebBookV2` 可以更接近 Android `WebBook.kt`：只组织阶段，
/// 不再自行理解 retry、cookie、redirect、WebView 恢复、响应规范化等 transport 实现。
nonisolated final class WebBookV2 {
    typealias TocFetchMode = WebBook.TocFetchMode
    typealias ContentFetchMode = WebBook.ContentFetchMode

    let bookSource: BookSource
    private let loginManager: LoginManager
    private let requestExecutor: RequestExecutorV2
    private var requestContext: LegadoRequestContextV2

    init(
        bookSource: BookSource,
        maximumRequestTimeout: TimeInterval = 60,
        allowsWebViewRequests: Bool = true,
        allowsAutomaticWebViewRecovery: Bool = true,
        requestExecutor: RequestExecutorV2? = nil,
        runtimeTrace: RuntimeTraceV2? = nil
    ) {
        self.bookSource = bookSource
        self.loginManager = LoginManager.shared
        // 搜索会并行执行多个书源；HTTPClient 的默认请求头是可变状态，不能在书源间共享。
        self.requestExecutor = requestExecutor ?? RequestExecutorV2(
            httpClient: HTTPClient(),
            cookieJarEnabled: bookSource.enabledCookieJar
        )
        self.requestContext = LegadoRequestContextV2(
            source: bookSource,
            variableStore: ParserVariableStore(writeScope: .source),
            maximumRequestTimeout: max(1, maximumRequestTimeout),
            allowsWebViewRequests: allowsWebViewRequests,
            allowsAutomaticWebViewRecovery: allowsAutomaticWebViewRecovery,
            runtimeTrace: runtimeTrace
        )
    }

    // V2 runtime 是纯解析编排对象，释放时不需要回到默认 MainActor。
    // 批量 compare 会短时间创建/销毁大量 WebBookV2；显式 nonisolated 可避开
    // Swift 并发运行时在析构路径上的 TaskLocal 清理坏释放。
    nonisolated deinit {}

    func shutdown() {
        requestExecutor.shutdown()
    }

    private func ensureAuthenticatedIfNeeded() async throws {
        guard let js = bookSource.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines), !js.isEmpty else {
            return
        }

        let isValid = await loginManager.validateSession(for: bookSource)
        guard isValid else {
            throw ParserError.loginRequired("书源 \(bookSource.bookSourceName) 需要先登录后才能继续访问")
        }
    }

    private func activeBookSource() -> BookSource {
        requestContext.source
    }

    /// 为当前阶段构造统一的 Android 风格 URL runtime。
    ///
    /// H2 之后，`WebBookV2` 不再在各个阶段方法里分散解释 URL 规则，
    /// 而是统一把输入交给 `AnalyzeUrlV2`，由它产出 request / descriptor。
    private func makeAnalyzeURLRuntime(
        rule: String,
        baseUrl: String,
        key: String = "",
        page: Int = 1,
        variableStore: ParserVariableStore? = nil
    ) -> AnalyzeUrlV2 {
        AnalyzeUrlV2(
            rule: rule,
            key: key,
            page: page,
            baseUrl: baseUrl,
            headerString: bookSource.header,
            source: activeBookSource(),
            variableStore: variableStore
        )
    }

    /// 执行一次阶段请求，并把更新后的 request context 接回编排层。
    ///
    /// 每个阶段都只和“标准 response context”交互，避免请求层实现细节重新长回 `WebBookV2`。
    private func executeStageRequest(
        analyzeUrlRuntime: AnalyzeUrlV2,
        transportPreference: HTTPRequest.TransportPreference = .automatic,
        webJs: String? = nil,
        sourceRegex: String? = nil
    ) async throws -> LegadoResponseContextV2 {
        let execution = try await requestExecutor.execute(
            analyzeUrlRuntime: analyzeUrlRuntime,
            context: requestContext,
            transportPreference: transportPreference,
            webJs: webJs,
            sourceRegex: sourceRegex,
            timeout: requestContext.maximumRequestTimeout
        )
        requestContext = execution.updatedContext
        return try applyLoginCheckIfNeeded(
            to: execution.responseContext,
            analyzeUrlRuntime: analyzeUrlRuntime
        )
    }

    /// Applies Android-style `loginCheckJs` after transport and before stage parsing.
    ///
    /// Android exposes the fetched response as `result`/`StrResponse`, so a source can inspect
    /// status, headers, URL and body, then either keep the original response, return a rewritten
    /// body, or reject the page as not logged in. V2 keeps that semantic at the request boundary
    /// so search/detail/toc/content parsers all consume the same checked response context.
    private func applyLoginCheckIfNeeded(
        to responseContext: LegadoResponseContextV2,
        analyzeUrlRuntime: AnalyzeUrlV2
    ) throws -> LegadoResponseContextV2 {
        guard let js = activeBookSource().loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !js.isEmpty else {
            return responseContext
        }

        let parser = JavaScriptParser(
            baseUrl: responseContext.baseUrl,
            source: activeBookSource(),
            variableStore: analyzeUrlRuntime.variableStore ?? requestContext.variableStore,
            requestURL: responseContext.requestUrl,
            requestHeaders: analyzeUrlRuntime.requestHeaders
        )
        parser.updateContextContent(responseContext.text ?? "")

        let action = try parser.evaluateLoginCheck(
            script: js,
            response: responseContext.response,
            fallbackRequestURL: analyzeUrlRuntime.urlString
        )

        switch action {
        case .keepOriginal:
            return responseContext
        case .rewriteBody(let body):
            var rewrittenResponse = responseContext.response
            rewrittenResponse.textOverride = body
            var rewrittenContext = responseContext
            rewrittenContext.response = rewrittenResponse
            rewrittenContext.bodySize = body.data(using: String.Encoding.utf8)?.count ?? body.utf8.count
            return rewrittenContext
        case .reject:
            throw ParserError.loginRequired("书源 \(bookSource.bookSourceName) 登录校验失败")
        }
    }

    private func requireResponseBody(
        from responseContext: LegadoResponseContextV2,
        failureMessage: String
    ) throws -> String {
        guard let html = responseContext.text else {
            throw ParserError.parsingFailed(failureMessage)
        }
        return html
    }

    private func makeBookDetailSeed(
        bookUrl: String,
        tocUrl: String? = nil,
        name: String,
        author: String,
        kind: String,
        sourceVariables: [String: String],
        bookVariables: [String: String],
        variables: [String: String]
    ) -> BookDetail {
        BookDetail(
            bookUrl: bookUrl,
            name: name,
            author: author,
            kind: kind,
            tocUrl: tocUrl,
            origin: requestContext.activeSourceURL,
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            variables: variables
        )
    }

    nonisolated func searchBook(
        keyword: String,
        page: Int = 1,
        maximumResults: Int? = nil
    ) async throws -> [SearchBook] {
        guard let searchUrlRule = bookSource.searchUrl, !searchUrlRule.isEmpty else {
            throw ParserError.invalidRule("书源未配置搜索 URL")
        }
        try await ensureAuthenticatedIfNeeded()

        let runtimeStore = requestContext.makeSourceRuntimeStore()
        let analyzeUrlRuntime = makeAnalyzeURLRuntime(
            rule: searchUrlRule,
            baseUrl: requestContext.activeSourceURL,
            key: keyword,
            page: page,
            variableStore: runtimeStore
        )
        let responseContext = try await executeStageRequest(
            analyzeUrlRuntime: analyzeUrlRuntime,
            transportPreference: .preferThirdParty
        )
        let html = try requireResponseBody(from: responseContext, failureMessage: "无法解析响应内容")

        let stageContext = StageRuntimeFactoryV2.makeSearchContext(
            source: activeBookSource(),
            requestContext: requestContext,
            variableStore: runtimeStore,
            responseContext: responseContext
        )
        return try BookListParserV2.parseSearchResult(
            html: html,
            context: stageContext,
            maximumCount: maximumResults
        )
    }

    func getExploreMenu() -> [ExploreMenuItem] {
        guard let exploreUrlString = bookSource.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !exploreUrlString.isEmpty else {
            return []
        }

        if exploreUrlString.first == "[" {
            return parseExploreMenuJSON(from: exploreUrlString) ?? []
        }

        if exploreUrlString.hasPrefix("@js:") {
            return parseJavaScriptExploreMenu(from: exploreUrlString) ?? []
        }

        let normalizedExploreURL = exploreUrlString.replacingOccurrences(of: "&&", with: "\n")
        return normalizedExploreURL
            .components(separatedBy: .newlines)
            .compactMap { line -> ExploreMenuItem? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else { return nil }

                let parts = trimmedLine.components(separatedBy: "::")
                if parts.count >= 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = parts[1...].joined(separator: "::").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !url.isEmpty else { return nil }
                    return ExploreMenuItem(title: name, url: url)
                }

                return ExploreMenuItem(title: trimmedLine, url: trimmedLine)
            }
    }

    func getExploreCategories() -> [(name: String, url: String)] {
        getExploreMenu().compactMap { item in
            guard let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }
            return (item.title, url)
        }
    }

    func applyExploreMenuAction(
        _ action: String,
        infoMap: [String: String]
    ) throws {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else { return }

        let parser = JavaScriptParser(
            baseUrl: requestContext.activeSourceURL,
            source: activeBookSource(),
            variableStore: requestContext.variableStore,
            requestURL: requestContext.activeSourceURL,
            requestHeaders: requestContext.resolvedSourceHeaders(),
            initialInfoMap: infoMap
        )
        _ = try parser.evaluate(script: trimmedAction)
    }

    func getExploreList(url: String, page: Int = 1) async throws -> [SearchBook] {
        try await ensureAuthenticatedIfNeeded()

        let runtimeStore = requestContext.makeSourceRuntimeStore()
        var analyzeUrlRuntime = makeAnalyzeURLRuntime(
            rule: url,
            baseUrl: requestContext.activeSourceURL,
            page: page,
            variableStore: runtimeStore
        )
        try await bootstrapExploreCookieIfNeeded(
            originalRule: url,
            resolvedURL: analyzeUrlRuntime.urlString
        )

        // The source URL can establish a cookie needed by `{{cookie.getKey(...)}}`.
        // Recreate AnalyzeUrl after the bootstrap so it evaluates the template against the
        // freshly persisted cookie instead of sending the original empty query parameter.
        analyzeUrlRuntime = makeAnalyzeURLRuntime(
            rule: url,
            baseUrl: requestContext.activeSourceURL,
            page: page,
            variableStore: runtimeStore
        )
        let responseContext = try await executeStageRequest(
            analyzeUrlRuntime: analyzeUrlRuntime,
            transportPreference: .preferThirdParty
        )
        let html = try requireResponseBody(from: responseContext, failureMessage: "无法解析探索页内容")
        let stageContext = StageRuntimeFactoryV2.makeSearchContext(
            source: activeBookSource(),
            requestContext: requestContext,
            variableStore: runtimeStore,
            responseContext: responseContext
        )
        return try BookListParserV2.parseExploreResult(html: html, context: stageContext)
    }

    /// Establishes a source session before an explore request whose URL needs a cookie value.
    ///
    /// Dynamic explore menus are evaluated before any network request. Some Android-compatible
    /// sources, including the supplied Qidian filter source, interpolate `_csrfToken` from
    /// `cookie.getKey(...)` directly into their category URL. On a fresh iOS install that cookie
    /// does not exist yet, and Qidian responds with a successful HTTP status but a JSON failure
    /// payload. The source root is tried first, then its own empty-key search route when the root
    /// does not issue the required cookie. Both requests run through the normal cookie jar, and
    /// this remains limited to an actually missing `cookie.getKey` template so ordinary explore
    /// sources do not gain an extra request.
    private func bootstrapExploreCookieIfNeeded(
        originalRule: String,
        resolvedURL: String
    ) async throws {
        guard bookSource.enabledCookieJar,
              let requiredCookie = requiredCookieTemplate(in: originalRule),
              CookieManager.shared.getCookieKey(requiredCookie.name, domain: requiredCookie.domain).isEmpty else {
            return
        }

        let rootURL = sourceURLForCookieBootstrap()
        guard !rootURL.isEmpty,
              rootURL != resolvedURL else {
            return
        }

        let bootstrapRuntime = makeAnalyzeURLRuntime(
            rule: rootURL,
            baseUrl: requestContext.activeSourceURL,
            variableStore: requestContext.makeSourceRuntimeStore()
        )
        _ = try await executeStageRequest(
            analyzeUrlRuntime: bootstrapRuntime,
            transportPreference: .preferThirdParty
        )

        guard CookieManager.shared.getCookieKey(requiredCookie.name, domain: requiredCookie.domain).isEmpty,
              let searchRule = bookSource.searchUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !searchRule.isEmpty else {
            return
        }

        // A blank key deliberately preserves the source's own search URL shape. Qidian's
        // `/so/.html?pageNum=1` response is a 404 page, but it establishes `_csrfToken`; we
        // intentionally ignore its body and rely only on the standard cookie response handling.
        let searchBootstrapRuntime = makeAnalyzeURLRuntime(
            rule: searchRule,
            baseUrl: requestContext.activeSourceURL,
            key: "",
            page: 1,
            variableStore: requestContext.makeSourceRuntimeStore()
        )
        _ = try await executeStageRequest(
            analyzeUrlRuntime: searchBootstrapRuntime,
            transportPreference: .preferThirdParty
        )
    }

    /// Reads the Android URL-template shape `{{cookie.getKey("domain", "name")}}`.
    /// The parser only needs the first required cookie because one bootstrap response updates
    /// the shared source cookie jar before the complete URL rule is evaluated again.
    private func requiredCookieTemplate(in rule: String) -> (domain: String, name: String)? {
        let pattern = #"\{\{\s*cookie\.getKey\(\s*[\"']([^\"']+)[\"']\s*,\s*[\"']([^\"']+)[\"']\s*\)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: rule,
                range: NSRange(rule.startIndex..., in: rule)
              ),
              let domainRange = Range(match.range(at: 1), in: rule),
              let nameRange = Range(match.range(at: 2), in: rule) else {
            return nil
        }

        let domain = String(rule[domainRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(rule[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, !name.isEmpty else { return nil }
        return (domain, name)
    }

    /// `bookSourceUrl` may contain a fragment used solely to distinguish source variants.
    /// Drop that marker for the bootstrap request while keeping the regular source runtime URL
    /// unchanged for all subsequent relative URL resolution.
    private func sourceURLForCookieBootstrap() -> String {
        var components = URLComponents(string: requestContext.activeSourceURL)
        components?.fragment = nil
        return components?.string ?? requestContext.activeSourceURL
    }

    nonisolated func getBookInfo(
        bookUrl: String,
        baseUrl: String? = nil,
        cachedInfoHtml: String? = nil,
        variables: [String: String] = [:],
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        name: String = "",
        author: String = "",
        kind: String = ""
    ) async throws -> BookDetail {
        try await ensureAuthenticatedIfNeeded()

        let runtimeStore = requestContext.makeBookRuntimeStore(
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            fallbackVariables: variables
        )
        let resolvedBaseURL = baseUrl ?? requestContext.activeSourceURL
        let seededDetail = makeBookDetailSeed(
            bookUrl: bookUrl,
            name: name,
            author: author,
            kind: kind,
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            variables: variables
        )

        if let cachedInfoHtml, !cachedInfoHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cachedContext = StageRuntimeFactoryV2.makeDetailContext(
                source: activeBookSource(),
                requestContext: requestContext,
                variableStore: runtimeStore,
                bookUrl: bookUrl,
                seedDetail: seededDetail,
                cachedHTML: cachedInfoHtml
            )
            var detail = try BookInfoParserV2.parse(
                html: cachedInfoHtml,
                bookUrl: bookUrl,
                context: cachedContext,
                bookName: name,
                bookAuthor: author,
                bookKind: kind
            )
            detail.infoHtml = cachedContext.infoHtml
            if detail.tocUrl == detail.bookUrl {
                detail.tocHtml = cachedContext.infoHtml
            }
            return detail
        }

        let analyzeUrlRuntime = makeAnalyzeURLRuntime(
            rule: bookUrl,
            baseUrl: resolvedBaseURL,
            variableStore: runtimeStore
        )
        let responseContext = try await executeStageRequest(
            analyzeUrlRuntime: analyzeUrlRuntime,
            webJs: bookSource.ruleContent?.webJs,
            sourceRegex: bookSource.ruleContent?.sourceRegex
        )
        let html = try requireResponseBody(from: responseContext, failureMessage: "无法解析书籍详情页")

        let stageContext = StageRuntimeFactoryV2.makeDetailContext(
            source: activeBookSource(),
            requestContext: requestContext,
            variableStore: runtimeStore,
            bookUrl: bookUrl,
            seedDetail: seededDetail,
            responseContext: responseContext
        )
        var detail = try BookInfoParserV2.parse(
            html: html,
            bookUrl: bookUrl,
            context: stageContext,
            bookName: name,
            bookAuthor: author,
            bookKind: kind
        )
        detail.infoHtml = stageContext.infoHtml
        if detail.tocUrl == detail.bookUrl {
            detail.tocHtml = stageContext.infoHtml
        }
        return detail
    }

    nonisolated func getTocList(
        tocUrl: String,
        bookUrl: String,
        maxPages: Int = 20,
        cachedTocHtml: String? = nil,
        variables: [String: String] = [:],
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        name: String = "",
        author: String = "",
        kind: String = "",
        fetchMode: TocFetchMode = .full
    ) async throws -> [BookChapter] {
        try await ensureAuthenticatedIfNeeded()

        var allChapterLists: [[BookChapter]] = []
        let runtimeStore = requestContext.makeBookRuntimeStore(
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            fallbackVariables: variables
        )
        let normalizedBookURL = normalizeTocURL(bookUrl, bookUrl: bookUrl, variableStore: runtimeStore)
        var normalizedTocURL = normalizeTocURL(tocUrl, bookUrl: bookUrl, variableStore: runtimeStore)
        var detail = makeBookDetailSeed(
            bookUrl: bookUrl,
            tocUrl: normalizedTocURL,
            name: name,
            author: author,
            kind: kind,
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            variables: variables
        )

        // `cachedTocHtml` belongs to the detail that originally supplied `tocUrl`.
        // A pre-update refresh is explicitly allowed to rotate that URL (Qidian does this),
        // so parsing the old detail HTML as though it were the new catalogue page produces an
        // empty TOC and incorrectly rejects an otherwise valid source. Android fetches the
        // refreshed URL; do the same here.
        var effectiveCachedTocHtml = cachedTocHtml

        // Android runs ruleToc.preUpdateJs before each directory refresh. Its
        // refreshTocUrl() bridge re-fetches book info because many sources rotate
        // their catalog URL. Previously iOS ignored this hook entirely.
        if let refreshedDetail = try await runTocPreUpdateIfNeeded(
            bookUrl: bookUrl,
            detail: detail,
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            variables: variables
        ) {
            detail = refreshedDetail
            effectiveCachedTocHtml = nil
            let refreshedTocURL = refreshedDetail.tocUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !refreshedTocURL.isEmpty {
                normalizedTocURL = normalizeTocURL(
                    refreshedTocURL,
                    bookUrl: bookUrl,
                    variableStore: runtimeStore
                )
                detail.tocUrl = normalizedTocURL
            }
        }
        var currentUrl: String? = normalizedTocURL
        var currentBaseUrl = normalizedTocURL.isEmpty ? fallbackTocBaseURL(bookUrl: bookUrl) : normalizedTocURL
        var pageCount = 0
        var visitedPageURLs: Set<String> = []

        if let effectiveCachedTocHtml, !effectiveCachedTocHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stageContext = StageRuntimeFactoryV2.makeTocContext(
                source: activeBookSource(),
                requestContext: requestContext,
                variableStore: runtimeStore,
                bookDetail: detail,
                cachedHTML: effectiveCachedTocHtml
            )
            let parsed = try BookChapterParserV2.parsePage(
                html: effectiveCachedTocHtml,
                bookUrl: bookUrl,
                context: stageContext,
                bookName: name,
                bookAuthor: author,
                bookKind: kind,
                tocUrl: normalizedTocURL,
                bookVariables: runtimeStore.snapshot(for: .book, includeInherited: true)
            )
            let pageHasChapters = !parsed.chapters.isEmpty
            if pageHasChapters {
                allChapterLists.append(parsed.chapters)
            }
            let nextURLs = sanitizePaginationURLs(
                parsed.nextTocUrls,
                baseUrl: normalizedTocURL,
                currentURL: normalizedTocURL,
                visitedPageURLs: visitedPageURLs
            )
            let shouldStopAfterCachedPage = pageHasChapters && shouldStopTocPagination(
                allChapterLists,
                bookUrl: normalizedBookURL,
                fetchMode: fetchMode
            )
            if pageHasChapters || !nextURLs.isEmpty {
                visitedPageURLs.insert(normalizedURLIdentity(normalizedTocURL))
                currentBaseUrl = normalizedTocURL
                pageCount = 1
                let limitedNextURLs = limitedTocPaginationURLs(
                    nextURLs,
                    remainingPages: maxPages - pageCount,
                    fetchMode: fetchMode
                )
                if shouldStopAfterCachedPage {
                    currentUrl = nil
                } else if shouldFetchTocPagesInParallel(limitedNextURLs, fetchMode: fetchMode) {
                    let pageLists = try await fetchParallelTocPages(
                        urls: limitedNextURLs,
                        bookUrl: bookUrl,
                        sourceVariables: runtimeStore.snapshot(for: .source, includeInherited: false),
                        bookVariables: runtimeStore.snapshot(for: .book, includeInherited: false),
                        name: name,
                        author: author,
                        kind: kind,
                        tocUrl: normalizedTocURL
                    )
                    allChapterLists.append(contentsOf: pageLists)
                    pageCount += limitedNextURLs.count
                    currentUrl = nil
                } else {
                    currentUrl = limitedNextURLs.first
                }
            }
        }

        while let url = currentUrl, pageCount < maxPages {
            try Task.checkCancellation()
            let normalizedCurrentURL = normalizeTocURL(
                url,
                bookUrl: bookUrl,
                baseUrl: currentBaseUrl,
                variableStore: runtimeStore
            )
            let currentIdentity = normalizedURLIdentity(normalizedCurrentURL)
            guard visitedPageURLs.insert(currentIdentity).inserted else {
                currentUrl = nil
                continue
            }
            pageCount += 1

            let analyzeUrlRuntime = makeAnalyzeURLRuntime(
                rule: normalizedCurrentURL,
                baseUrl: currentBaseUrl,
                variableStore: runtimeStore
            )
            let responseContext = try await executeStageRequest(analyzeUrlRuntime: analyzeUrlRuntime)
            let html = try requireResponseBody(from: responseContext, failureMessage: "无法解析目录页")
            currentBaseUrl = responseContext.baseUrl

            let stageContext = StageRuntimeFactoryV2.makeTocContext(
                source: activeBookSource(),
                requestContext: requestContext,
                variableStore: runtimeStore,
                bookDetail: detail,
                responseContext: responseContext
            )
            let parsed = try BookChapterParserV2.parsePage(
                html: html,
                bookUrl: bookUrl,
                context: stageContext,
                bookName: name,
                bookAuthor: author,
                bookKind: kind,
                tocUrl: normalizedTocURL,
                bookVariables: runtimeStore.snapshot(for: .book, includeInherited: true)
            )
            let pageHasChapters = !parsed.chapters.isEmpty
            if pageHasChapters {
                allChapterLists.append(parsed.chapters)
            }
            let nextURLs = sanitizePaginationURLs(
                parsed.nextTocUrls,
                baseUrl: currentBaseUrl,
                currentURL: normalizedCurrentURL,
                visitedPageURLs: visitedPageURLs
            )
            let shouldStopAfterCurrentPage = pageHasChapters && shouldStopTocPagination(
                allChapterLists,
                bookUrl: normalizedBookURL,
                fetchMode: fetchMode
            )
            if shouldStopAfterCurrentPage {
                currentUrl = nil
            } else if !nextURLs.isEmpty {
                let limitedNextURLs = limitedTocPaginationURLs(
                    nextURLs,
                    remainingPages: maxPages - pageCount,
                    fetchMode: fetchMode
                )
                if shouldFetchTocPagesInParallel(limitedNextURLs, fetchMode: fetchMode) {
                    let pageLists = try await fetchParallelTocPages(
                        urls: limitedNextURLs,
                        bookUrl: bookUrl,
                        sourceVariables: runtimeStore.snapshot(for: .source, includeInherited: false),
                        bookVariables: runtimeStore.snapshot(for: .book, includeInherited: false),
                        name: name,
                        author: author,
                        kind: kind,
                        tocUrl: normalizedTocURL
                    )
                    allChapterLists.append(contentsOf: pageLists)
                    pageCount += limitedNextURLs.count
                    currentUrl = nil
                } else {
                    currentUrl = limitedNextURLs.first
                }
            } else {
                currentUrl = nil
            }
        }

        let mergedChapters = BookChapterParserV2.mergeChapters(allChapterLists)
        guard !mergedChapters.isEmpty else {
            throw ParserError.parsingFailed("目录为空")
        }
        return mergedChapters
    }

    private func runTocPreUpdateIfNeeded(
        bookUrl: String,
        detail: BookDetail,
        sourceVariables: [String: String],
        bookVariables: [String: String],
        variables: [String: String]
    ) async throws -> BookDetail? {
        guard let preUpdateJS = activeBookSource().ruleToc?.preUpdateJs?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !preUpdateJS.isEmpty else {
            return nil
        }

        guard preUpdateJS.contains("java.refreshTocUrl()") else {
            ParserLog.debug(
                "WebBookV2",
                "skip unsupported preUpdateJs source=\(activeBookSource().bookSourceName) rule=\(ParserLog.preview(preUpdateJS))"
            )
            return nil
        }

        ParserLog.debug("WebBookV2", "refresh toc URL via preUpdateJs source=\(activeBookSource().bookSourceName)")
        return try await getBookInfo(
            bookUrl: bookUrl,
            baseUrl: bookUrl,
            variables: variables,
            sourceVariables: sourceVariables,
            bookVariables: bookVariables,
            name: detail.name,
            author: detail.author,
            kind: detail.kind ?? ""
        )
    }

    nonisolated func getContent(
        chapter: BookChapter,
        maxPages: Int = 10,
        nextChapterUrl: String? = nil,
        variables: [String: String] = [:],
        fetchMode: ContentFetchMode = .full
    ) async throws -> ChapterContent {
        try await ensureAuthenticatedIfNeeded()

        var pages: [ChapterContent] = []
        var mergedVariables = variables
        for (key, value) in chapter.variables {
            mergedVariables[key] = value
        }
        let runtimeStore = requestContext.makeChapterRuntimeStore(
            sourceVariables: chapter.sourceVariables,
            bookVariables: chapter.bookVariables,
            chapterVariables: chapter.chapterVariables,
            fallbackVariables: mergedVariables
        )
        let initialBaseURL = chapter.baseUrl.isEmpty ? requestContext.activeSourceURL : chapter.baseUrl
        var currentUrl: String? = AnalyzeUrlV2.postProcessExtractedURL(
            chapter.url,
            baseUrl: initialBaseURL,
            variableStore: runtimeStore
        )
        var currentBaseUrl = initialBaseURL
        var pageCount = 0
        var visitedPageURLs: Set<String> = []
        let nextChapterIdentity = normalizedNextChapterIdentity(
            nextChapterUrl,
            baseUrl: currentUrl ?? initialBaseURL
        )

        while let url = currentUrl, pageCount < maxPages {
            try Task.checkCancellation()
            let normalizedURL = AnalyzeUrlV2.postProcessExtractedURL(url, baseUrl: currentBaseUrl, variableStore: runtimeStore)
            let pageIdentity = normalizedURLIdentity(normalizedURL)
            guard visitedPageURLs.insert(pageIdentity).inserted else {
                currentUrl = nil
                continue
            }
            pageCount += 1

            let analyzeUrlRuntime = makeAnalyzeURLRuntime(
                rule: normalizedURL,
                baseUrl: currentBaseUrl,
                variableStore: runtimeStore
            )
            let responseContext = try await executeStageRequest(
                analyzeUrlRuntime: analyzeUrlRuntime,
                webJs: bookSource.ruleContent?.webJs,
                sourceRegex: bookSource.ruleContent?.sourceRegex
            )
            let html = try requireResponseBody(from: responseContext, failureMessage: "无法解析正文页")
            currentBaseUrl = responseContext.baseUrl

            let stageContext = StageRuntimeFactoryV2.makeContentContext(
                source: activeBookSource(),
                requestContext: requestContext,
                variableStore: runtimeStore,
                chapter: chapter,
                responseContext: responseContext,
                nextChapterUrl: nextChapterUrl
            )
            let pageResult = try ChapterContentParserV2.parsePage(
                html: html,
                chapter: chapter,
                context: stageContext
            )
            if !pageResult.content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pageResult.content.contentType != "text" {
                pages.append(pageResult.content)
            }

            let shouldStopAfterCurrentPage = shouldStopContentPagination(pages, fetchMode: fetchMode)
            if shouldStopAfterCurrentPage {
                currentUrl = nil
            } else if !pageResult.nextContentURLs.isEmpty {
                let limitedNextURLs = limitedContentPaginationURLs(
                    sanitizeContentPaginationURLs(
                        pageResult.nextContentURLs,
                        baseUrl: currentBaseUrl,
                        currentURL: normalizedURL,
                        visitedPageURLs: visitedPageURLs,
                        nextChapterIdentity: nextChapterIdentity
                    ),
                    remainingPages: maxPages - pageCount,
                    fetchMode: fetchMode
                )
                if shouldFetchContentPagesInParallel(limitedNextURLs, fetchMode: fetchMode) {
                    let parallelPages = try await fetchParallelContentPages(
                        urls: limitedNextURLs,
                        chapter: chapter,
                        sourceVariables: runtimeStore.snapshot(for: .source, includeInherited: false),
                        bookVariables: runtimeStore.snapshot(for: .book, includeInherited: false),
                        chapterVariables: runtimeStore.snapshot(for: .chapter, includeInherited: false),
                        nextChapterUrl: nextChapterUrl
                    )
                    pages.append(contentsOf: parallelPages)
                    pageCount += limitedNextURLs.count
                    currentUrl = nil
                } else {
                    currentUrl = limitedNextURLs.first
                }
            } else {
                currentUrl = nil
            }
        }

        let mergedContent = ChapterContentParserV2.mergePages(pages)
        if chapter.isVolume == false,
           mergedContent.contentType == "text",
           mergedContent.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ParserError.parsingFailed("正文为空")
        }
        return mergedContent
    }

    private func fetchParallelTocPages(
        urls: [String],
        bookUrl: String,
        sourceVariables: [String: String],
        bookVariables: [String: String],
        name: String,
        author: String,
        kind: String,
        tocUrl: String
    ) async throws -> [[BookChapter]] {
        guard !urls.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, [BookChapter]).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { [self] in
                    try Task.checkCancellation()
                    let runtimeStore = ParserVariableStore(
                        sourceValues: sourceVariables,
                        bookValues: bookVariables,
                        writeScope: .book
                    )
                    let analyzeUrlRuntime = makeAnalyzeURLRuntime(
                        rule: url,
                        baseUrl: requestContext.activeSourceURL,
                        variableStore: runtimeStore
                    )
                    let responseContext = try await executeStageRequest(analyzeUrlRuntime: analyzeUrlRuntime)
                    guard let html = responseContext.text else { return (index, []) }

                    let detail = makeBookDetailSeed(
                        bookUrl: bookUrl,
                        tocUrl: tocUrl,
                        name: name,
                        author: author,
                        kind: kind,
                        sourceVariables: sourceVariables,
                        bookVariables: bookVariables,
                        variables: runtimeStore.snapshot(for: .book, includeInherited: true)
                    )
                    let stageContext = StageRuntimeFactoryV2.makeTocContext(
                        source: activeBookSource(),
                        requestContext: requestContext,
                        variableStore: runtimeStore,
                        bookDetail: detail,
                        responseContext: responseContext
                    )
                    let parsed = try BookChapterParserV2.parsePage(
                        html: html,
                        bookUrl: bookUrl,
                        context: stageContext,
                        bookName: name,
                        bookAuthor: author,
                        bookKind: kind,
                        tocUrl: tocUrl,
                        bookVariables: runtimeStore.snapshot(for: .book, includeInherited: true)
                    )
                    return (index, parsed.chapters)
                }
            }

            var collected: [(Int, [BookChapter])] = []
            for try await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func fetchParallelContentPages(
        urls: [String],
        chapter: BookChapter,
        sourceVariables: [String: String],
        bookVariables: [String: String],
        chapterVariables: [String: String],
        nextChapterUrl: String?
    ) async throws -> [ChapterContent] {
        guard !urls.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, ChapterContent).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { [self] in
                    try Task.checkCancellation()

                    let runtimeStore = ParserVariableStore(
                        sourceValues: sourceVariables,
                        bookValues: bookVariables,
                        chapterValues: chapterVariables,
                        writeScope: .chapter
                    )
                    let analyzeUrlRuntime = makeAnalyzeURLRuntime(
                        rule: url,
                        baseUrl: chapter.baseUrl.isEmpty ? requestContext.activeSourceURL : chapter.baseUrl,
                        variableStore: runtimeStore
                    )
                    let responseContext = try await executeStageRequest(
                        analyzeUrlRuntime: analyzeUrlRuntime,
                        webJs: bookSource.ruleContent?.webJs,
                        sourceRegex: bookSource.ruleContent?.sourceRegex
                    )
                    guard let html = responseContext.text else { return (index, ChapterContent(title: chapter.title)) }

                    let stageContext = StageRuntimeFactoryV2.makeContentContext(
                        source: activeBookSource(),
                        requestContext: requestContext,
                        variableStore: runtimeStore,
                        chapter: chapter,
                        responseContext: responseContext,
                        nextChapterUrl: nextChapterUrl
                    )
                    let content = try ChapterContentParserV2.parsePage(
                        html: html,
                        chapter: chapter,
                        context: stageContext
                    ).content
                    return (index, content)
                }
            }

            var collected: [(Int, ChapterContent)] = []
            for try await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func sanitizeContentPaginationURLs(
        _ urls: [String],
        baseUrl: String,
        currentURL: String,
        visitedPageURLs: Set<String>,
        nextChapterIdentity: String?
    ) -> [String] {
        var seen: Set<String> = []
        var sanitized: [String] = []

        for url in urls {
            for candidate in AnalyzeUrlV2.postProcessExtractedURLs(url, baseUrl: baseUrl) {
                let identity = normalizedURLIdentity(candidate)
                guard identity != normalizedURLIdentity(currentURL),
                      !visitedPageURLs.contains(identity) else {
                    continue
                }
                if let nextChapterIdentity, identity == nextChapterIdentity {
                    continue
                }
                if seen.insert(identity).inserted {
                    sanitized.append(candidate)
                }
            }
        }
        return sanitized
    }

    private func limitedContentPaginationURLs(
        _ urls: [String],
        remainingPages: Int,
        fetchMode: ContentFetchMode
    ) -> [String] {
        let allowedCount: Int
        switch fetchMode {
        case .full:
            allowedCount = remainingPages
        case let .validation(maximumPages, _):
            allowedCount = min(remainingPages, maximumPages)
        }
        guard allowedCount > 0 else { return [] }
        return Array(urls.prefix(allowedCount))
    }

    private func shouldFetchContentPagesInParallel(_ urls: [String], fetchMode: ContentFetchMode) -> Bool {
        guard urls.count > 1 else { return false }
        switch fetchMode {
        case .full:
            return true
        case .validation:
            return false
        }
    }

    private func shouldStopContentPagination(_ pages: [ChapterContent], fetchMode: ContentFetchMode) -> Bool {
        switch fetchMode {
        case .full:
            return false
        case let .validation(maximumPages, minimumCharacterCount):
            guard !pages.isEmpty else { return false }
            if pages.count >= maximumPages {
                return true
            }
            let mergedContent = ChapterContentParserV2.mergePages(pages)
            if mergedContent.contentType != "text" {
                return true
            }
            let trimmedContent = mergedContent.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedContent.count >= minimumCharacterCount
        }
    }

    private func normalizedNextChapterIdentity(_ nextChapterUrl: String?, baseUrl: String) -> String? {
        guard let nextChapterUrl,
              !nextChapterUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalized = AnalyzeUrlV2.postProcessExtractedURL(nextChapterUrl, baseUrl: baseUrl)
        guard !normalized.isEmpty else { return nil }
        return normalizedURLIdentity(normalized)
    }

    private func fallbackTocBaseURL(bookUrl: String) -> String {
        let trimmedBookURL = bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBookURL.isEmpty ? requestContext.activeSourceURL : trimmedBookURL
    }

    private func normalizeTocURL(
        _ rawURL: String,
        bookUrl: String,
        baseUrl: String? = nil,
        variableStore: ParserVariableStore? = nil
    ) -> String {
        let trimmedBaseURL = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackBaseURL = trimmedBaseURL.isEmpty ? fallbackTocBaseURL(bookUrl: bookUrl) : trimmedBaseURL
        let normalized = AnalyzeUrlV2.postProcessExtractedURL(rawURL, baseUrl: fallbackBaseURL, variableStore: variableStore)
        if normalized.isEmpty {
            return rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    private func sanitizePaginationURLs(
        _ urls: [String],
        baseUrl: String,
        currentURL: String,
        visitedPageURLs: Set<String>
    ) -> [String] {
        var seen: Set<String> = []
        var sanitized: [String] = []

        for url in urls {
            for candidate in AnalyzeUrlV2.postProcessExtractedURLs(url, baseUrl: baseUrl) {
                let identity = normalizedURLIdentity(candidate)
                guard identity != normalizedURLIdentity(currentURL),
                      !visitedPageURLs.contains(identity) else {
                    continue
                }
                if seen.insert(identity).inserted {
                    sanitized.append(candidate)
                }
            }
        }
        return sanitized
    }

    private func limitedTocPaginationURLs(
        _ urls: [String],
        remainingPages: Int,
        fetchMode: TocFetchMode
    ) -> [String] {
        let allowedCount: Int
        switch fetchMode {
        case .full:
            allowedCount = remainingPages
        case let .validation(minimumChapterCount, _):
            allowedCount = min(remainingPages, max(1, minimumChapterCount))
        }
        guard allowedCount > 0 else { return [] }
        return Array(urls.prefix(allowedCount))
    }

    private func shouldFetchTocPagesInParallel(_ urls: [String], fetchMode: TocFetchMode) -> Bool {
        guard urls.count > 1 else { return false }
        switch fetchMode {
        case .full:
            return true
        case .validation:
            return false
        }
    }

    private func shouldStopTocPagination(
        _ chapterLists: [[BookChapter]],
        bookUrl: String,
        fetchMode: TocFetchMode
    ) -> Bool {
        switch fetchMode {
        case .full:
            return false
        case let .validation(minimumChapterCount, minimumUsableChapterCount):
            let mergedChapters = BookChapterParserV2.mergeChapters(chapterLists)
            guard mergedChapters.count >= minimumChapterCount else {
                return false
            }
            let usableChapterCount = mergedChapters.filter { chapter in
                let pageURL = chapter.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallbackTocBaseURL(bookUrl: bookUrl)
                    : chapter.baseUrl
                return isUsableChapterReference(chapter, pageURL: pageURL, bookUrl: bookUrl)
            }.count
            return usableChapterCount >= minimumUsableChapterCount
        }
    }

    private func isMeaningfulTocPage(_ chapters: [BookChapter], pageURL: String, bookUrl: String) -> Bool {
        guard !chapters.isEmpty else { return false }

        let usableCount = chapters.filter {
            isUsableChapterReference($0, pageURL: pageURL, bookUrl: bookUrl)
        }.count

        if chapters.count == 1 {
            return usableCount == 1
        }

        return usableCount > 0
    }

    private func isUsableChapterReference(_ chapter: BookChapter, pageURL: String, bookUrl: String) -> Bool {
        guard !chapter.isVolume else { return false }

        let trimmed = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if trimmed.hasPrefix("javascript:") {
                return false
            }
            if !trimmed.contains("://") && !trimmed.hasPrefix("/") && trimmed.contains("#") {
                return false
            }
            if !urlsEquivalent(trimmed, pageURL) && !urlsEquivalent(trimmed, bookUrl) {
                return true
            }
            if looksLikeChapterPath(trimmed, pageURL: pageURL, bookUrl: bookUrl) {
                return true
            }
        }

        return hasDistinctChapterContext(chapter)
    }

    private func hasDistinctChapterContext(_ chapter: BookChapter) -> Bool {
        if !chapter.chapterVariables.isEmpty {
            return true
        }

        for (key, value) in chapter.variables where !value.isEmpty {
            if chapter.bookVariables[key] != value || chapter.sourceVariables[key] != value {
                return true
            }
        }

        return false
    }

    private func urlsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalizedURLIdentity(lhs) == normalizedURLIdentity(rhs)
    }

    /// Android 对很多分页目录会保留相对章节链接，例如 `/109/109408/28306533.html` 或 `28306533.html`。
    /// 这些链接即便与当前目录页同域，也仍然是可阅读章节，不应因为“不够绝对”而整页判废。
    private func looksLikeChapterPath(_ candidate: String, pageURL: String, bookUrl: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("javascript:") else { return false }
        guard !trimmed.hasPrefix("#") else { return false }
        guard trimmed != "/" else { return false }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return true
        }

        if trimmed.contains("://") {
            return false
        }

        let pagePath = URL(string: pageURL)?.path ?? ""
        let bookPath = URL(string: bookUrl)?.path ?? ""
        if pagePath.hasSuffix(trimmed) || bookPath.hasSuffix(trimmed) {
            return false
        }

        let looksLikeHTML = trimmed.contains(".html") || trimmed.contains(".htm") || trimmed.contains(".json")
        let looksLikeNumberedPath = trimmed.range(of: #"\d"#, options: .regularExpression) != nil
        return looksLikeHTML || looksLikeNumberedPath
    }

    private func normalizedURLIdentity(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let components = URLComponents(string: trimmed) else {
            return trimmed
        }

        var normalized = components
        normalized.scheme = normalized.scheme?.lowercased()
        normalized.host = normalized.host?.lowercased()
        return normalized.string ?? trimmed
    }

    private func parseExploreMenuJSON(from rawValue: String) -> [ExploreMenuItem]? {
        guard rawValue.hasPrefix("["),
              rawValue.hasSuffix("]"),
              let data = rawValue.data(using: .utf8) else {
            return nil
        }

        do {
            let definitions = try JSONDecoder().decode([ExploreCategoryDefinition].self, from: data)
            return definitions.compactMap { definition in
                let name = definition.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }

                let resolvedURL = definition.url?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ExploreMenuItem(
                    title: name,
                    url: resolvedURL?.isEmpty == true ? nil : resolvedURL,
                    type: definition.type,
                    choices: definition.chars ?? [],
                    defaultValue: definition.defaultValue,
                    action: definition.action
                )
            }
        } catch {
            ParserLog.debug(
                "WebBookV2",
                "parse explore categories json failed source=\(bookSource.bookSourceName) error=\(error.localizedDescription)"
            )
            return []
        }
    }

    /// Some Android sources generate discovery menus dynamically through `exploreUrl: @js:`.
    /// Execute that rule before category parsing so the normal explore request pipeline can use
    /// the resulting URLs without treating JavaScript as a literal URL.
    private func parseJavaScriptExploreMenu(from rawValue: String) -> [ExploreMenuItem]? {
        let script = String(rawValue.dropFirst("@js:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return [] }

        let parser = JavaScriptParser(
            baseUrl: requestContext.activeSourceURL,
            source: activeBookSource(),
            variableStore: requestContext.variableStore,
            requestURL: requestContext.activeSourceURL,
            requestHeaders: requestContext.resolvedSourceHeaders()
        )

        do {
            let output = try parser.evaluate(script: script)
            return parseExploreMenuJSON(from: output) ?? []
        } catch {
            ParserLog.debug(
                "WebBookV2",
                "execute explore JavaScript failed source=\(bookSource.bookSourceName) error=\(error.localizedDescription)"
            )
            return []
        }
    }

    private struct ExploreCategoryDefinition: Decodable {
        let title: String
        let url: String?
        let type: String?
        let chars: [String]?
        let defaultValue: String?
        let action: String?

        enum CodingKeys: String, CodingKey {
            case title
            case name
            case url
            case type
            case chars
            case defaultValue = "default"
            case action
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let value = try? container.decode(String.self) {
                self.title = value
                self.url = value
                self.type = nil
                self.chars = nil
                self.defaultValue = nil
                self.action = nil
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
                ?? container.decodeIfPresent(String.self, forKey: .name)
                ?? ""
            self.url = try container.decodeIfPresent(String.self, forKey: .url)
            self.type = try container.decodeIfPresent(String.self, forKey: .type)
            self.chars = try container.decodeIfPresent([String].self, forKey: .chars)
            self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
            self.action = try container.decodeIfPresent(String.self, forKey: .action)
        }
    }
}
