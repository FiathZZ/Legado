import XCTest
import Foundation
import Network
@testable import Legado

final class WebBookLoginCheckTests: XCTestCase {
    private let sessionKey = "Legado.LoginSessions"

    override func tearDownWithError() throws {
        CookieManager.shared.clearCookies(domain: "127.0.0.1")
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    func testBrowserRecoveryHeuristicsDetectsCloudflareChallenge() {
        XCTAssertTrue(
            BrowserRecoveryHeuristics.shouldAttemptRecovery(
                statusCode: 503,
                server: "cloudflare",
                mitigationHeader: "",
                body: "<html><title>Just a moment...</title><script>window._cf_chl_opt={};</script></html>"
            )
        )
    }

    func testBrowserRecoveryHeuristicsDetectsScriptRedirectChallenge() {
        XCTAssertTrue(
            BrowserRecoveryHeuristics.shouldAttemptRecovery(
                statusCode: 200,
                server: "openresty",
                mitigationHeader: "",
                body: """
                <html><head><title>Redirecting...</title></head><body>
                <script>
                document.write(`<a id="x" href="/next"></a>`);
                document.getElementById("x").click();
                window.location.replace("https://router.parklogic.com/next");
                </script>
                </body></html>
                """
            )
        )
    }

    func testBrowserRecoveryHeuristicsIgnoresOrdinaryHTML() {
        XCTAssertFalse(
            BrowserRecoveryHeuristics.shouldAttemptRecovery(
                statusCode: 200,
                server: "nginx",
                mitigationHeader: "",
                body: "<html><body><div class='result'>normal page</div></body></html>"
            )
        )
    }

    func testSearchBookSupportsAndroidStyleResultBodyFunction() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/search.json": .json(
                    #"{"items":[{"name":"original","author":"before","bookUrl":"https://example.com/original"}]}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Search LoginCheck",
            bookSourceUrl: server.baseURL.absoluteString,
            loginCheckJs: """
            if (result.body().indexOf('original') >= 0 && result.code() == 200) {
                return '{"items":[{"name":"rewritten","author":"tester","bookUrl":"https://example.com/book"}]}';
            }
            return false;
            """,
            searchUrl: server.url(path: "/search.json").absoluteString,
            ruleSearch: SearchRule(
                bookList: "$.items",
                name: "$.name",
                author: "$.author",
                bookUrl: "$.bookUrl"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let books = try await webBook.searchBook(keyword: "phase8")

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "rewritten")
        XCTAssertEqual(books.first?.author, "tester")
        XCTAssertEqual(books.first?.bookUrl, "https://example.com/book")
    }

    func testRuntimeSourceContextPromotesCrossDomainResponseForJSAndFollowupRequests() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/search.json": .json(
                    #"{"items":[{"name":"book","author":"tester","bookUrl":"/detail.json"}]}"#
                ),
                "/detail.json": .json(
                    #"{"name":"runtime detail","author":"runtime author","tocUrl":"/toc.json"}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        let source = BookSource(
            bookSourceName: "Runtime Source Promotion",
            bookSourceUrl: "https://legacy.example.com",
            searchUrl: server.url(path: "/search.json").absoluteString,
            ruleSearch: SearchRule(
                bookList: "$.items",
                name: "@js:source.getKey()",
                author: "$.author",
                bookUrl: "$.bookUrl"
            ),
            ruleBookInfo: BookInfoRule(
                name: "$.name",
                author: "$.author",
                tocUrl: "$.tocUrl"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let books = try await webBook.searchBook(keyword: "phase13")
        let detail = try await webBook.getBookInfo(bookUrl: "/detail.json")

        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, server.baseURL.absoluteString)
        XCTAssertEqual(detail.name, "runtime detail")
        XCTAssertEqual(detail.author, "runtime author")
        XCTAssertEqual(detail.tocUrl, server.url(path: "/toc.json").absoluteString)
        XCTAssertEqual(detail.origin, server.baseURL.absoluteString)
    }

    func testSearchBookFallsBackToDetailParsingWhenSearchResponseIsDirectDetailPage() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/search.json": .json(
                    #"{"name":"fallback detail","author":"tester","tocUrl":"/toc.json","coverUrl":"/cover.jpg"}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        let source = BookSource(
            bookSourceName: "Search Detail Fallback",
            bookSourceUrl: server.baseURL.absoluteString,
            bookUrlPattern: #"http://127\.0\.0\.1:\d+/search\.json"#,
            searchUrl: server.url(path: "/search.json").absoluteString,
            ruleSearch: SearchRule(
                bookList: "$.items",
                name: "$.name",
                author: "$.author",
                bookUrl: "$.bookUrl"
            ),
            ruleBookInfo: BookInfoRule(
                name: "$.name",
                author: "$.author",
                coverUrl: "$.coverUrl",
                tocUrl: "$.tocUrl"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let books = try await webBook.searchBook(keyword: "phase13")

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "fallback detail")
        XCTAssertEqual(books.first?.author, "tester")
        XCTAssertEqual(books.first?.bookUrl, server.url(path: "/search.json").absoluteString)
        XCTAssertEqual(books.first?.coverUrl, server.url(path: "/cover.jpg").absoluteString)
        XCTAssertEqual(books.first?.origin, server.baseURL.absoluteString)
        XCTAssertTrue(books.first?.infoHtml?.contains("fallback detail") == true)
    }

    func testSearchBookRunsJSOnRawHrefBeforeURLNormalization() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/search.html": .html(
                    """
                    <html>
                      <body>
                        <div class="item">
                          <a href="/book/1">遮天</a>
                        </div>
                      </body>
                    </html>
                    """
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        let source = BookSource(
            bookSourceName: "RawHref Search",
            bookSourceUrl: server.baseURL.absoluteString,
            searchUrl: server.url(path: "/search.html").absoluteString,
            ruleSearch: SearchRule(
                bookList: ".item",
                name: "a@text",
                lastChapter: "a@href<js>'\(server.baseURL.absoluteString)' + result</js>",
                bookUrl: "a@href"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let books = try await webBook.searchBook(keyword: "phase13")

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookUrl, server.url(path: "/book/1").absoluteString)
        XCTAssertEqual(books.first?.lastChapter, server.url(path: "/book/1").absoluteString)
    }

    func testHTTPClientShutdownDoesNotInvalidateSharedTransportForInFlightRequests() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/slow.json": .json(
                    #"{"ok":true}"#,
                    delayMilliseconds: 350
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        let request = HTTPRequest(
            url: server.url(path: "/slow.json").absoluteString,
            timeout: 2,
            transportPreference: .preferThirdParty
        )
        let requestClient = HTTPClient()
        let shutdownClient = HTTPClient()

        async let responseTask: HTTPResponse = requestClient.send(request: request)

        try await Task.sleep(nanoseconds: 80_000_000)
        shutdownClient.shutdown()

        let response = try await responseTask

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.text, #"{"ok":true}"#)
    }

    func testGetBookInfoPreservesOriginalBodyWhenScriptReturnsResponseObject() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/detail.json": .json(
                    #"{"name":"detail original","author":"detail author","tocUrl":"https://example.com/toc"}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Detail LoginCheck",
            bookSourceUrl: server.baseURL.absoluteString,
            loginCheckJs: """
            if (result.url.indexOf('/detail.json') >= 0 && result.code() == 200 && result.statusCode() == 200) {
                return result;
            }
            return false;
            """,
            ruleBookInfo: BookInfoRule(
                name: "$.name",
                author: "$.author",
                tocUrl: "$.tocUrl"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let detail = try await webBook.getBookInfo(bookUrl: server.url(path: "/detail.json").absoluteString)

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(detail.name, "detail original")
        XCTAssertEqual(detail.author, "detail author")
        XCTAssertEqual(detail.tocUrl, "https://example.com/toc")
    }

    func testGetTocListSupportsHeaderInspectionWithoutBodyRewrite() async throws {
        let contentURL = "https://example.com/content-1"
        let server = try LocalHTTPJSONServer(
            routes: [
                "/toc.json": .json(
                    #"{"chapters":[{"title":"第1章","url":"\#(contentURL)"},{"title":"第2章","url":"https://example.com/content-2"}]}"#,
                    headers: ["X-Phase": "toc"]
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "TOC LoginCheck",
            bookSourceUrl: server.baseURL.absoluteString,
            loginCheckJs: """
            if (result.headers().get('X-Phase') == 'toc' && result.url.indexOf('/toc.json') >= 0) {
                return true;
            }
            return false;
            """,
            ruleToc: TocRule(
                chapterList: "$.chapters",
                chapterName: "$.title",
                chapterUrl: "$.url"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: server.url(path: "/toc.json").absoluteString,
            bookUrl: "https://example.com/book"
        )

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.first?.title, "第1章")
        XCTAssertEqual(chapters.first?.url, contentURL)
    }

    func testGetTocListSplitsAndMergesMultipleNextTocURLs() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/toc-1.json": .json(
                    """
                    {"chapters":[{"title":"第1章","url":"https://example.com/c1"},{"title":"第2章","url":"https://example.com/c2"}],"next":"/toc-2.json\\n/toc-3.json"}
                    """
                ),
                "/toc-2.json": .json(
                    #"{"chapters":[{"title":"第3章","url":"https://example.com/c3"}]}"#
                ),
                "/toc-3.json": .json(
                    #"{"chapters":[{"title":"第4章","url":"https://example.com/c4"}]}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "TOC Pagination",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleToc: TocRule(
                chapterList: "$.chapters",
                chapterName: "$.title",
                chapterUrl: "$.url",
                nextTocUrl: "$.next"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: server.url(path: "/toc-1.json").absoluteString,
            bookUrl: "https://example.com/book"
        )

        XCTAssertEqual(server.requestCount, 3)
        XCTAssertEqual(chapters.map(\.title), ["第1章", "第2章", "第3章", "第4章"])
    }

    func testGetTocListValidationModeStopsAfterMinimumReadableChapters() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/toc-1.json": .json(
                    #"{"chapters":[{"title":"第1章","url":"https://example.com/c1"},{"title":"第2章","url":"https://example.com/c2"}],"next":"/toc-2.json"}"#
                ),
                "/toc-2.json": .json(
                    #"{"chapters":[{"title":"第3章","url":"https://example.com/c3"}],"next":"/toc-3.json"}"#
                ),
                "/toc-3.json": .json(
                    #"{"chapters":[{"title":"第4章","url":"https://example.com/c4"}]}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "TOC Validation Mode",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleToc: TocRule(
                chapterList: "$.chapters",
                chapterName: "$.title",
                chapterUrl: "$.url",
                nextTocUrl: "$.next"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: server.url(path: "/toc-1.json").absoluteString,
            bookUrl: "https://example.com/book",
            fetchMode: .validation()
        )

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(chapters.map(\.title), ["第1章", "第2章"])
    }

    /// `java.refreshTocUrl()` refreshes the book detail before loading the directory. The old
    /// detail HTML must not be treated as the newly refreshed directory page: Qidian-style
    /// sources rotate their catalogue URL and otherwise end up incorrectly reported as empty.
    func testGetTocListDiscardsStaleCachedTocHTMLAfterRefreshTocURL() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/book.json": .json(#"{\"tocUrl\":\"/fresh-toc.json\"}"#),
                "/fresh-toc.json": .json(
                    #"{\"chapters\":[{\"title\":\"第1章\",\"url\":\"/chapter-1.json\"}]}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Refresh TOC URL",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleBookInfo: BookInfoRule(tocUrl: "$.tocUrl"),
            ruleToc: TocRule(
                chapterList: "$.chapters",
                chapterName: "$.title",
                chapterUrl: "$.url",
                preUpdateJs: "java.refreshTocUrl()"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: server.url(path: "/stale-toc.json").absoluteString,
            bookUrl: server.url(path: "/book.json").absoluteString,
            cachedTocHtml: #"{\"chapters\":[]}"#
        )

        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(chapters.map(\.title), ["第1章"])
        XCTAssertEqual(chapters.first?.url, server.url(path: "/chapter-1.json").absoluteString)
    }

    func testGetTocListKeepsSingleChapterWhenChapterContextExists() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/toc.json": .json(
                    #"{"chapters":[{"title":"只有一章","url":"/toc.json","chapterId":"1001"}]}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let tocURL = server.url(path: "/toc.json").absoluteString
        let source = BookSource(
            bookSourceName: "TOC Single With Context",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleToc: TocRule(
                chapterList: "$.chapters",
                chapterName: "$.title",
                chapterUrl: "$.url"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: tocURL,
            bookUrl: "https://example.com/book",
            variables: ["chapterId": "1001"]
        )

        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.title, "只有一章")
    }

    func testGetBookInfoFallsBackWhenCachedFragmentProducesBracketPlaceholderTocURL() async throws {
        let detailHTML = #"""
        {
          "novelId": [],
          "novelName": "遮天",
          "authorName": "辰东"
        }
        """#
        let fullDetailHTML = #"""
        {
          "links": [
            { "title": "目录", "href": "/novel/123/chapters?readNum=1" }
          ],
          "novelName": "遮天",
          "authorName": "辰东"
        }
        """#
        let server = try LocalHTTPJSONServer(
            routes: [
                "/detail": .json(fullDetailHTML)
            ]
        )
        try server.start()
        defer { server.stop() }

        let source = BookSource(
            bookSourceName: "猫眼看书缓存回退测试源",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleBookInfo: BookInfoRule(
                name: "$..novelName",
                author: "$..authorName"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let detail = try await webBook.getBookInfo(
            bookUrl: server.url(path: "/detail").absoluteString,
            cachedInfoHtml: detailHTML,
            name: "遮天",
            author: "辰东"
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.tocUrl, server.url(path: "/detail").absoluteString)
    }

    func testGetTocListFallsBackInvalidPlaceholderChapterURLsToCurrentPageWhenNoContextExists() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/dirs": .json(
                    #"{"data":{"volumeList":[{"chapterList":[{"title":"第一章","chapId":[]},{"title":"第二章","chapId":[]}]}]}}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "SF轻小说 JSON 目录测试源",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleToc: TocRule(
                chapterList: "$.data.volumeList[*].chapterList[*]",
                chapterName: "$.title",
                chapterUrl: "https://minipapi.sfacg.com/pas/mpapi/Chaps/{{$.chapId}}?expand=content"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: server.url(path: "/dirs").absoluteString,
            bookUrl: "https://minipapi.sfacg.com/pas/mpapi/novels/42"
        )

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].url, server.url(path: "/dirs").absoluteString)
        XCTAssertEqual(chapters[1].url, server.url(path: "/dirs").absoluteString)
    }

    /// Android accepts directory entries produced by a source even when their URL intentionally
    /// points back to the catalogue page. This is common in mixed volume/chapter catalogues:
    /// the source's content rule supplies the final reading route. iOS must keep those entries
    /// instead of rejecting the whole source with its own `usable=0` diagnostic.
    func testGetTocListKeepsMixedCatalogEntriesWhenLinksEqualCatalogURL() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/catalog": .html(
                    """
                    <div class="_chapterBar_fps9g_592">第一卷</div>
                    <div class="y-list__item"><a href="/catalog"><h2>第一章 开始</h2></a></div>
                    <div class="y-list__item"><a href="/catalog"><h2>第二章 继续</h2></a></div>
                    """
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "起点混合目录回归源",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleToc: TocRule(
                chapterList: ".y-list__item,._chapterBar_fps9g_592",
                chapterName: "h2@text||text",
                chapterUrl: "href",
                isVolume: "textNodes\n@js:\nresult=result?true:false;\nresult;"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let chapters = try await webBook.getTocList(
            tocUrl: server.url(path: "/catalog").absoluteString,
            bookUrl: server.url(path: "/book/42").absoluteString
        )

        XCTAssertEqual(chapters.map(\.title), ["第一卷", "第一章 开始", "第二章 继续"])
        XCTAssertEqual(chapters.dropFirst().map(\.url), [
            server.url(path: "/catalog").absoluteString,
            server.url(path: "/catalog").absoluteString
        ])
    }

    func testPostProcessExtractedURLKeepsOnlyFirstDirtyPaginationCandidate() {
        let candidate = AnalyzeUrl.postProcessExtractedURL(
            """
            /toc?page=2
            //cdn.example.com/toc?page=3
            value="www.example.com/toc?page=4"
            """,
            baseUrl: "https://book.example.com/detail/1"
        )

        XCTAssertEqual(candidate, "https://www.example.com/toc?page=4")
    }

    func testGetContentSupportsAndroidStyleResultBodyProperty() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/content.json": .json(#"{"content":"before"}"#)
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Content LoginCheck",
            bookSourceUrl: server.baseURL.absoluteString,
            loginCheckJs: """
            if (result.body.indexOf('before') >= 0 && result.text.indexOf('before') >= 0) {
                return '{"content":"rewritten chapter"}';
            }
            return false;
            """,
            ruleContent: ContentRule(content: "$.content")
        )
        let chapter = BookChapter(
            index: 0,
            title: "第1章",
            url: server.url(path: "/content.json").absoluteString,
            baseUrl: server.baseURL.absoluteString,
            bookUrl: "https://example.com/book"
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let content = try await webBook.getContent(chapter: chapter)

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(content.title, "第1章")
        XCTAssertEqual(content.content, "rewritten chapter")
    }

    func testChapterContentParserKeepsMainParagraphsFromHTML() throws {
        let source = BookSource(
            bookSourceName: "HTML Content",
            bookSourceUrl: "https://example.com",
            ruleContent: ContentRule(content: "#content@html")
        )
        let chapter = BookChapter(
            index: 0,
            title: "正文章",
            url: "https://example.com/chapter-1",
            baseUrl: "https://example.com/chapter-1",
            bookUrl: "https://example.com/book"
        )
        let html = """
        <html><body>
        <div id="content">
          <p>第一段正文。</p>
          <p>第二段正文。</p>
          <div>上一章</div>
          <div>点击下一页继续阅读</div>
        </div>
        </body></html>
        """

        let content = try ChapterContentParser.parse(
            html: html,
            bookSource: source,
            chapter: chapter,
            baseUrl: "https://example.com/chapter-1"
        )

        XCTAssertTrue(content.content.contains("第一段正文。"))
        XCTAssertTrue(content.content.contains("第二段正文。"))
        XCTAssertFalse(content.content.contains("上一章"))
        XCTAssertFalse(content.content.contains("点击下一页继续阅读"))
    }

    func testGetContentMergesPaginatedHTMLPages() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/chapter-1": .json(
                    #"{"html":"<div id='content'><p>第一页正文。</p></div>","next":"<a class='page' href='/chapter-2'>2</a>\n<a class='page' href='/chapter-3'>3</a>"}"#
                ),
                "/chapter-2": .json(
                    #"{"html":"<div id='content'><p>第二页正文。</p></div>"}"#
                ),
                "/chapter-3": .json(
                    #"{"html":"<div id='content'><p>第三页正文。</p></div>"}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Paginated Content",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleContent: ContentRule(
                content: "$.html",
                nextContentUrl: "$.next"
            )
        )
        let chapter = BookChapter(
            index: 0,
            title: "第1章",
            url: server.url(path: "/chapter-1").absoluteString,
            baseUrl: server.baseURL.absoluteString,
            bookUrl: "https://example.com/book"
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let content = try await webBook.getContent(chapter: chapter)

        XCTAssertEqual(server.requestCount, 3)
        XCTAssertTrue(content.content.contains("第一页正文。"))
        XCTAssertTrue(content.content.contains("第二页正文。"))
        XCTAssertTrue(content.content.contains("第三页正文。"))
    }

    func testGetContentStopsPaginationAtNextChapterURL() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/chapter-1": .json(
                    #"{"html":"<div id='content'><p>第一页正文。</p></div>","next":"<a id='next' href='/chapter-1-2'>下一页</a>"}"#
                ),
                "/chapter-1-2": .json(
                    #"{"html":"<div id='content'><p>第二页正文。</p></div>","next":"<a id='next' href='/chapter-2'>下一章</a>"}"#
                ),
                "/chapter-2": .json(
                    #"{"html":"<div id='content'><p>下一章正文不应合并。</p></div>"}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Next Chapter Stop",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleContent: ContentRule(
                content: "$.html",
                nextContentUrl: "$.next"
            )
        )
        let chapter = BookChapter(
            index: 0,
            title: "第1章",
            url: server.url(path: "/chapter-1").absoluteString,
            baseUrl: server.baseURL.absoluteString,
            bookUrl: "https://example.com/book"
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let content = try await webBook.getContent(
            chapter: chapter,
            nextChapterUrl: server.url(path: "/chapter-2").absoluteString
        )

        XCTAssertEqual(server.requestCount, 2)
        XCTAssertTrue(content.content.contains("第一页正文。"))
        XCTAssertTrue(content.content.contains("第二页正文。"))
        XCTAssertFalse(content.content.contains("下一章正文不应合并。"))
    }

    func testGetContentValidationModeStopsAfterFirstReadablePage() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/chapter-1": .json(
                    #"{"html":"<div id='content'><p>第一页正文。</p></div>","next":"<a id='next' href='/chapter-1-2'>下一页</a>"}"#
                ),
                "/chapter-1-2": .json(
                    #"{"html":"<div id='content'><p>第二页正文不应请求。</p></div>"}"#
                )
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Content Validation Mode",
            bookSourceUrl: server.baseURL.absoluteString,
            ruleContent: ContentRule(
                content: "$.html",
                nextContentUrl: "$.next"
            )
        )
        let chapter = BookChapter(
            index: 0,
            title: "第1章",
            url: server.url(path: "/chapter-1").absoluteString,
            baseUrl: server.baseURL.absoluteString,
            bookUrl: "https://example.com/book"
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let content = try await webBook.getContent(
            chapter: chapter,
            fetchMode: .validation()
        )

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertTrue(content.content.contains("第一页正文。"))
        XCTAssertFalse(content.content.contains("第二页正文不应请求。"))
    }

    func testBookChapterParserPreservesHTMLPureJSChapterObjectArray() throws {
        let source = BookSource(
            bookSourceName: "HTML Pure JS TOC",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: """
                @js:
                list = [];
                J = org.jsoup.Jsoup.parse(result);
                Array.from(J.select('a')).forEach(function(a) {
                    list.push({
                        text: a.text(),
                        href: a.attr('href')
                    });
                });
                list
                """,
                chapterName: "text",
                chapterUrl: "href"
            )
        )

        let result = try BookChapterParser.parse(
            html: """
            <div class="toc">
              <a href="/c1.html">第一章</a>
              <a href="/c2.html">第二章</a>
            </div>
            """,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/book/1/"
        )

        XCTAssertEqual(result.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.chapters.map(\.url), [
            "https://example.com/c1.html",
            "https://example.com/c2.html"
        ])
    }

    func testBookChapterParserPreservesJSONPureJSChapterObjectArray() throws {
        let source = BookSource(
            bookSourceName: "JSON Pure JS TOC",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: """
                @js:
                let list = [];
                JSON.parse(result).list.forEach(function(volume) {
                    volume.bookChapters.forEach(function(chapter) {
                        list.push({
                            name: chapter.name,
                            url: '/chapter/' + chapter.id + '.html',
                            info: '字数:' + chapter.wordCount
                        });
                    });
                });
                list
                """,
                chapterName: "name",
                chapterUrl: "url",
                updateTime: "info"
            )
        )

        let result = try BookChapterParser.parse(
            html: """
            {
              "list": [
                {
                  "name": "正文卷",
                  "bookChapters": [
                    { "name": "第一章", "id": 1, "wordCount": 1000 },
                    { "name": "第二章", "id": 2, "wordCount": 1200 }
                  ]
                }
              ]
            }
            """,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc"
        )

        XCTAssertEqual(result.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.chapters.map(\.url), [
            "https://example.com/chapter/1.html",
            "https://example.com/chapter/2.html"
        ])
        XCTAssertEqual(result.chapters.map { $0.updateTime ?? "" }, ["字数:1000", "字数:1200"])
    }

    func testBookChapterParserCapturesTrailingMultilineMapExpressionForJSONToc() throws {
        let source = BookSource(
            bookSourceName: "JSON Multiline Map TOC",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: """
                @js:
                $ = JSON.parse(result).data;
                bid = $.book_id;
                $.chapters.map(chapter => {
                    chapter.url = '/chapter/' + bid + '/' + chapter.id + '.html';
                    return chapter;
                });
                """,
                chapterName: "name",
                chapterUrl: "url"
            )
        )

        let result = try BookChapterParser.parse(
            html: """
            {
              "data": {
                "book_id": 42,
                "chapters": [
                  { "name": "第一章", "id": 1 },
                  { "name": "第二章", "id": 2 }
                ]
              }
            }
            """,
            bookSource: source,
            bookUrl: "https://example.com/book/42",
            baseUrl: "https://example.com/toc"
        )

        XCTAssertEqual(result.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.chapters.map(\.url), [
            "https://example.com/chapter/42/1.html",
            "https://example.com/chapter/42/2.html"
        ])
    }

    func testThrownLoginCheckStillFailsAsLoginRequired() async throws {
        let server = try LocalHTTPJSONServer(
            routes: [
                "/search.json": .json(#"{"items":[]}"#)
            ]
        )
        try server.start()
        defer { server.stop() }

        seedAuthenticatedSession(for: server.baseURL)
        let source = BookSource(
            bookSourceName: "Rejected LoginCheck",
            bookSourceUrl: server.baseURL.absoluteString,
            loginCheckJs: """
            if (result.body().indexOf('missing') >= 0) {
                return true;
            }
            throw 'login expired';
            """,
            searchUrl: server.url(path: "/search.json").absoluteString,
            ruleSearch: SearchRule(
                bookList: "$.items",
                name: "$.name",
                author: "$.author",
                bookUrl: "$.bookUrl"
            )
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        do {
            _ = try await webBook.searchBook(keyword: "phase8")
            XCTFail("Expected loginCheckJs to reject the response")
        } catch let error as ParserError {
            guard case .loginRequired(let message) = error else {
                XCTFail("Expected loginRequired, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("登录校验失败"))
        }
    }

    private func seedAuthenticatedSession(for baseURL: URL) {
        guard let host = baseURL.host else {
            XCTFail("Missing host for \(baseURL)")
            return
        }
        CookieManager.shared.parseCookieString("auth=1", domain: host)
        let session = LoginSession(
            sourceURL: baseURL.absoluteString,
            loggedInAt: Date(),
            lastValidatedAt: nil,
            values: ["auth": "1"]
        )
        guard let data = try? JSONEncoder().encode([baseURL.absoluteString: session]) else {
            XCTFail("Unable to encode login session for \(baseURL)")
            return
        }
        UserDefaults.standard.set(data, forKey: sessionKey)
    }
}

private final class LocalHTTPJSONServer {
    struct Route {
        let statusCode: Int
        let body: String
        let delayMilliseconds: UInt64
        let headers: [String: String]

        static func json(
            _ body: String,
            statusCode: Int = 200,
            delayMilliseconds: UInt64 = 0,
            headers: [String: String] = [:]
        ) -> Route {
            Route(
                statusCode: statusCode,
                body: body,
                delayMilliseconds: delayMilliseconds,
                headers: headers.merging(["Content-Type": "application/json; charset=utf-8"]) { current, _ in current }
            )
        }

        static func html(
            _ body: String,
            statusCode: Int = 200,
            delayMilliseconds: UInt64 = 0,
            headers: [String: String] = [:]
        ) -> Route {
            Route(
                statusCode: statusCode,
                body: body,
                delayMilliseconds: delayMilliseconds,
                headers: headers.merging(["Content-Type": "text/html; charset=utf-8"]) { current, _ in current }
            )
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Legado.tests.LocalHTTPJSONServer")
    private let routes: [String: Route]
    private let requestLock = NSLock()
    private var internalRequestCount = 0

    var requestCount: Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        return internalRequestCount
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    init(routes: [String: Route]) throws {
        self.routes = routes
        self.listener = try Self.makeListener()
    }

    func url(path: String) -> URL {
        baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startupError = error
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            throw NSError(
                domain: "LocalHTTPJSONServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Listener startup timed out"]
            )
        }
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.receive(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            self.requestLock.lock()
            self.internalRequestCount += 1
            self.requestLock.unlock()

            let path = self.parsePath(from: data) ?? "/"
            let route = self.routes[path] ?? .json(#"{"error":"not found"}"#, statusCode: 404)
            let bodyData = Data(route.body.utf8)
            var headerLines = [
                "HTTP/1.1 \(route.statusCode) \(Self.reasonPhrase(for: route.statusCode))",
                "Content-Length: \(bodyData.count)",
                "Connection: close"
            ]
            for (key, value) in route.headers {
                headerLines.append("\(key): \(value)")
            }
            let header = (headerLines + ["", ""]).joined(separator: "\r\n")
            var responseData = Data(header.utf8)
            responseData.append(bodyData)
            let sendResponse = {
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            if route.delayMilliseconds > 0 {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(Int(route.delayMilliseconds))) {
                    sendResponse()
                }
            } else {
                sendResponse()
            }
        }
    }

    private func parsePath(from data: Data?) -> String? {
        guard let data, let request = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let requestLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }
        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else { return nil }
        let target = String(components[1])
        return URL(string: "http://127.0.0.1\(target)")?.path ?? target
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 404:
            return "Not Found"
        default:
            return "Status"
        }
    }

    private static func makeListener() throws -> NWListener {
        var lastError: Error?
        for portValue in UInt16(21110)...UInt16(21210) {
            do {
                return try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: portValue)!)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "LocalHTTPJSONServer",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unable to allocate test port"]
        )
    }
}
