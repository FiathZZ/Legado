import XCTest
@testable import Legado

final class Phase13H1V2RuntimeTests: XCTestCase {

    func testAnalyzeUrlV2WrapsLegacyRuleResolution() {
        let analyzeUrl = AnalyzeUrlV2(
            rule: "/search?q={key}&page={page}",
            key: "遮天",
            page: 3,
            baseUrl: "https://example.com"
        )

        XCTAssertTrue(analyzeUrl.urlString.contains("example.com"))
        XCTAssertTrue(analyzeUrl.urlString.contains("%E9%81%AE%E5%A4%A9"))
        XCTAssertTrue(analyzeUrl.urlString.contains("page=3"))
    }

    func testRequestContextV2CreatesScopedStores() {
        let source = BookSource(bookSourceName: "test", bookSourceUrl: "https://example.com")
        let requestContext = LegadoRequestContextV2(source: source)
        let sourceStore = requestContext.makeSourceRuntimeStore()
        let bookStore = requestContext.makeBookRuntimeStore(
            sourceVariables: ["token": "source"],
            bookVariables: ["bid": "123"],
            fallbackVariables: ["bookName": "遮天"]
        )
        let chapterStore = requestContext.makeChapterRuntimeStore(
            sourceVariables: ["token": "source"],
            bookVariables: ["bid": "123"],
            chapterVariables: ["cid": "1"],
            fallbackVariables: ["title": "第一章"]
        )

        XCTAssertEqual(sourceStore.writeScope, .source)
        XCTAssertEqual(bookStore.get("bid"), "123")
        XCTAssertEqual(bookStore.get("bookName"), "遮天")
        XCTAssertEqual(chapterStore.get("cid"), "1")
        XCTAssertEqual(chapterStore.get("title"), "第一章")
    }

    func testStageFactoryV2AssemblesSearchContext() {
        let source = BookSource(bookSourceName: "test", bookSourceUrl: "https://example.com")
        let trace = RuntimeTraceV2()
        let responseContext = LegadoResponseContextV2(
            response: HTTPResponse(
                data: Data("search-body".utf8),
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                url: URL(string: "https://mirror.example.com/search"),
                requestURL: URL(string: "https://example.com/search"),
                message: "OK",
                textOverride: "search-body"
            ),
            descriptor: LegadoRequestDescriptorV2(
                resolvedURL: "https://example.com/search",
                method: "GET",
                headerKeys: [],
                originalRulePreview: nil,
                bodyLength: 0,
                bodyPreview: nil,
                bodyHash: nil,
                charset: "UTF-8",
                webView: false,
                webJs: false,
                sourceRegex: false,
                retryCount: 0,
                responseType: nil,
                cookieJarEnabled: true,
                timeoutSeconds: 12,
                followRedirects: true,
                transportPreference: "preferThirdParty"
            ),
            requestUrl: "https://example.com/search",
            responseUrl: "https://mirror.example.com/search",
            baseUrl: "https://mirror.example.com/search",
            transportKind: .http,
            attemptCount: 1
        )
        let requestContext = LegadoRequestContextV2(
            source: source,
            variableStore: ParserVariableStore(sourceValues: ["token": "source"], writeScope: .source),
            runtimeTrace: trace
        )
        let sourceStore = requestContext.makeSourceRuntimeStore()
        let stageContext = StageRuntimeFactoryV2.makeSearchContext(
            source: source,
            requestContext: requestContext,
            variableStore: sourceStore,
            responseContext: responseContext
        )

        XCTAssertEqual(stageContext.stage, .search)
        XCTAssertEqual(stageContext.source.bookSourceUrl, "https://example.com")
        XCTAssertEqual(stageContext.baseUrl, "https://mirror.example.com/search")
        XCTAssertEqual(stageContext.redirectUrl, "https://mirror.example.com/search")
        XCTAssertEqual(stageContext.responseBody, "search-body")
        XCTAssertEqual(stageContext.requestContext?.activeSourceURL, "https://example.com")
        XCTAssertEqual(stageContext.variableStore.writeScope, .source)
        XCTAssertEqual(stageContext.runtimeTrace?.drain().count, 0)
    }

    func testStageFactoryV2CarriesDetailAndTocIntermediateState() {
        let source = BookSource(bookSourceName: "test", bookSourceUrl: "https://example.com")
        let requestContext = LegadoRequestContextV2(
            source: source,
            variableStore: ParserVariableStore(
                sourceValues: ["token": "source"],
                bookValues: ["bid": "42"],
                writeScope: .book
            )
        )
        let runtimeStore = requestContext.makeBookRuntimeStore(
            sourceVariables: ["token": "source"],
            bookVariables: ["bid": "42"],
            fallbackVariables: ["bookName": "遮天"]
        )
        let detailResponse = LegadoResponseContextV2(
            response: HTTPResponse(
                data: Data("detail-html".utf8),
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                url: URL(string: "https://mirror.example.com/book/1"),
                requestURL: URL(string: "https://example.com/book/1"),
                message: "OK",
                textOverride: "detail-html"
            ),
            descriptor: LegadoRequestDescriptorV2(
                resolvedURL: "https://example.com/book/1",
                method: "GET",
                headerKeys: [],
                originalRulePreview: nil,
                bodyLength: 0,
                bodyPreview: nil,
                bodyHash: nil,
                charset: "UTF-8",
                webView: false,
                webJs: false,
                sourceRegex: false,
                retryCount: 0,
                responseType: nil,
                cookieJarEnabled: true,
                timeoutSeconds: 12,
                followRedirects: true,
                transportPreference: "automatic"
            ),
            requestUrl: "https://example.com/book/1",
            responseUrl: "https://mirror.example.com/book/1",
            baseUrl: "https://mirror.example.com/book/1",
            transportKind: .http,
            attemptCount: 1
        )

        let detailContext = StageRuntimeFactoryV2.makeDetailContext(
            source: source,
            requestContext: requestContext,
            variableStore: runtimeStore,
            bookUrl: "https://example.com/book/1",
            responseContext: detailResponse
        )

        XCTAssertEqual(detailContext.bookUrl, "https://example.com/book/1")
        XCTAssertEqual(detailContext.infoHtml, "detail-html")
        XCTAssertEqual(detailContext.redirectUrl, "https://mirror.example.com/book/1")
        XCTAssertEqual(detailContext.bookDetail?.infoHtml, "detail-html")

        var detail = detailContext.bookDetail ?? BookDetail(bookUrl: "https://example.com/book/1")
        detail.tocUrl = "https://example.com/book/1/catalog"
        detail.infoHtml = detailContext.infoHtml

        let tocContext = StageRuntimeFactoryV2.makeTocContext(
            source: source,
            requestContext: requestContext,
            variableStore: runtimeStore,
            bookDetail: detail,
            cachedHTML: "toc-html"
        )

        XCTAssertEqual(tocContext.bookUrl, "https://example.com/book/1")
        XCTAssertEqual(tocContext.infoHtml, "detail-html")
        XCTAssertEqual(tocContext.tocUrl, "https://example.com/book/1/catalog")
        XCTAssertEqual(tocContext.tocHtml, "toc-html")
        XCTAssertEqual(tocContext.responseBody, "toc-html")
        XCTAssertEqual(tocContext.bookDetail?.tocHtml, "toc-html")
    }

    func testRequestDescriptorV2WrapsLegacyDescriptorFields() {
        let legacy = LegadoRequestDescriptor(
            resolvedURL: "https://example.com/search?q=遮天",
            method: "GET",
            headerKeys: ["User-Agent"],
            originalRulePreview: "/search?q={key}",
            bodyLength: 0,
            bodyPreview: nil,
            bodyHash: nil,
            charset: "UTF-8",
            webView: false,
            webJs: false,
            sourceRegex: false,
            retryCount: 0,
            responseType: "text/html",
            cookieJarEnabled: true,
            timeoutSeconds: 12,
            followRedirects: true,
            transportPreference: "preferThirdParty"
        )
        let descriptor = LegadoRequestDescriptorV2(legacy: legacy)

        XCTAssertEqual(descriptor.resolvedURL, legacy.resolvedURL)
        XCTAssertEqual(descriptor.method, "GET")
        XCTAssertEqual(descriptor.headerKeys, ["User-Agent"])
        XCTAssertEqual(descriptor.timeoutSeconds, 12)
        XCTAssertTrue(descriptor.cookieJarEnabled)
    }
}
