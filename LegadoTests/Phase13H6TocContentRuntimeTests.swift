import XCTest
@testable import Legado

final class Phase13H6TocContentRuntimeTests: XCTestCase {

    func testTocParserV2ParsesSinglePageChapters() throws {
        let source = BookSource(
            bookSourceName: "H6单页目录",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: ".title@text",
                chapterUrl: "a@href"
            )
        )

        let html = """
        <html><body>
          <div class="chapter"><a href="/c1"><span class="title">第一章</span></a></div>
          <div class="chapter"><a href="/c2"><span class="title">第二章</span></a></div>
        </body></html>
        """

        let context = makeTocContext(source: source, body: html, responseURL: "https://example.com/book/1/catalog")
        let result = try BookChapterParserV2.parsePage(
            html: html,
            bookUrl: "https://example.com/book/1",
            context: context,
            bookName: "遮天",
            bookAuthor: "辰东",
            tocUrl: "https://example.com/book/1/catalog"
        )

        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[0].title, "第一章")
        XCTAssertEqual(result.chapters[0].url, "https://example.com/c1")
        XCTAssertTrue(result.nextTocUrls.isEmpty)
    }

    func testTocParserV2ExtractsNextTocURLsForMultiPageCatalog() throws {
        let source = BookSource(
            bookSourceName: "H6多页目录",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: ".title@text",
                chapterUrl: "a@href",
                nextTocUrl: ".pager .next@href"
            )
        )

        let html = """
        <html><body>
          <div class="chapter"><a href="/c1"><span class="title">第一章</span></a></div>
          <div class="pager"><a class="next" href="/book/1/catalog?page=2">下一页</a></div>
        </body></html>
        """

        let context = makeTocContext(source: source, body: html, responseURL: "https://example.com/book/1/catalog")
        let result = try BookChapterParserV2.parsePage(
            html: html,
            bookUrl: "https://example.com/book/1",
            context: context,
            tocUrl: "https://example.com/book/1/catalog"
        )

        XCTAssertEqual(result.chapters.count, 1)
        XCTAssertEqual(result.nextTocUrls, ["https://example.com/book/1/catalog?page=2"])
    }

    func testTocParserV2KeepsChapterWhenChapterURLIsEmpty() throws {
        let source = BookSource(
            bookSourceName: "H6空目录链接",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: ".title@text",
                chapterUrl: ""
            )
        )

        let html = """
        <html><body>
          <div class="chapter"><span class="title">第一章</span></div>
        </body></html>
        """

        let context = makeTocContext(source: source, body: html, responseURL: "https://example.com/book/1/catalog")
        let result = try BookChapterParserV2.parsePage(
            html: html,
            bookUrl: "https://example.com/book/1",
            context: context,
            tocUrl: "https://example.com/book/1/catalog"
        )

        XCTAssertEqual(result.chapters.count, 1)
        XCTAssertEqual(result.chapters[0].title, "第一章")
        XCTAssertEqual(result.chapters[0].url, "https://example.com/book/1/catalog")
    }

    func testContentParserV2ParsesSinglePageContent() throws {
        let source = BookSource(
            bookSourceName: "H6单页正文",
            bookSourceUrl: "https://example.com",
            ruleContent: ContentRule(
                content: ".content@html"
            )
        )

        let html = """
        <html><body>
          <div class="content"><p>第一段</p><p>第二段</p></div>
        </body></html>
        """
        let chapter = makeChapter(url: "https://example.com/c1")
        let context = makeContentContext(
            source: source,
            chapter: chapter,
            body: html,
            responseURL: "https://example.com/c1"
        )

        let result = try ChapterContentParserV2.parsePage(html: html, chapter: chapter, context: context)

        XCTAssertTrue(result.content.content.contains("第一段"))
        XCTAssertTrue(result.content.content.contains("第二段"))
        XCTAssertTrue(result.nextContentURLs.isEmpty)
    }

    func testContentParserV2ExtractsNextContentURLsForMultiPageContent() throws {
        let source = BookSource(
            bookSourceName: "H6多页正文",
            bookSourceUrl: "https://example.com",
            ruleContent: ContentRule(
                content: ".content@html",
                nextContentUrl: ".pager .next@href"
            )
        )

        let html = """
        <html><body>
          <div class="content"><p>第一页</p></div>
          <div class="pager"><a class="next" href="/c1?page=2">下一页</a></div>
        </body></html>
        """
        let chapter = makeChapter(url: "https://example.com/c1")
        let context = makeContentContext(
            source: source,
            chapter: chapter,
            body: html,
            responseURL: "https://example.com/c1"
        )

        let result = try ChapterContentParserV2.parsePage(html: html, chapter: chapter, context: context)

        XCTAssertTrue(result.content.content.contains("第一页"))
        XCTAssertEqual(result.nextContentURLs, ["https://example.com/c1?page=2"])
        XCTAssertEqual(result.content.nextPageUrl, "https://example.com/c1?page=2")
    }

    func testContentParserV2DoesNotTreatNextChapterAsNextPage() throws {
        let source = BookSource(
            bookSourceName: "H6下一章防误判",
            bookSourceUrl: "https://example.com",
            ruleContent: ContentRule(
                content: ".content@html",
                nextContentUrl: ".next@href"
            )
        )

        let html = """
        <html><body>
          <div class="content"><p>当前正文</p></div>
          <a class="next" href="/c2">下一章</a>
        </body></html>
        """
        let chapter = makeChapter(url: "https://example.com/c1")
        let context = makeContentContext(
            source: source,
            chapter: chapter,
            body: html,
            responseURL: "https://example.com/c1",
            nextChapterURL: "https://example.com/c2"
        )

        let result = try ChapterContentParserV2.parsePage(html: html, chapter: chapter, context: context)

        XCTAssertTrue(result.content.content.contains("当前正文"))
        XCTAssertTrue(result.nextContentURLs.isEmpty)
        XCTAssertNil(result.content.nextPageUrl)
    }

    private func makeTocContext(source: BookSource, body: String, responseURL: String) -> ParserStageContextV2 {
        let requestContext = LegadoRequestContextV2(source: source)
        let runtimeStore = requestContext.makeBookRuntimeStore(
            sourceVariables: [:],
            bookVariables: ["name": "遮天", "author": "辰东"],
            fallbackVariables: ["name": "遮天", "author": "辰东"]
        )
        let detail = BookDetail(
            bookUrl: "https://example.com/book/1",
            name: "遮天",
            author: "辰东",
            tocUrl: "https://example.com/book/1/catalog",
            origin: source.bookSourceUrl,
            sourceVariables: [:],
            bookVariables: runtimeStore.snapshot(for: .book, includeInherited: true),
            variables: runtimeStore.snapshot(for: .book, includeInherited: true)
        )
        let responseContext = makeResponseContext(body: body, responseURL: responseURL)
        return StageRuntimeFactoryV2.makeTocContext(
            source: source,
            requestContext: requestContext,
            variableStore: runtimeStore,
            bookDetail: detail,
            responseContext: responseContext
        )
    }

    private func makeContentContext(
        source: BookSource,
        chapter: BookChapter,
        body: String,
        responseURL: String,
        nextChapterURL: String? = nil
    ) -> ParserStageContextV2 {
        let requestContext = LegadoRequestContextV2(source: source)
        let runtimeStore = requestContext.makeChapterRuntimeStore(
            sourceVariables: [:],
            bookVariables: ["name": "遮天", "author": "辰东"],
            chapterVariables: chapter.chapterVariables,
            fallbackVariables: chapter.variables
        )
        let responseContext = makeResponseContext(body: body, responseURL: responseURL)
        return StageRuntimeFactoryV2.makeContentContext(
            source: source,
            requestContext: requestContext,
            variableStore: runtimeStore,
            chapter: chapter,
            responseContext: responseContext,
            nextChapterUrl: nextChapterURL
        )
    }

    private func makeResponseContext(body: String, responseURL: String) -> LegadoResponseContextV2 {
        LegadoResponseContextV2(
            response: HTTPResponse(
                data: Data(body.utf8),
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                url: URL(string: responseURL),
                requestURL: URL(string: responseURL),
                message: "OK",
                textOverride: body
            ),
            descriptor: LegadoRequestDescriptorV2(
                resolvedURL: responseURL,
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
                responseType: "text/html",
                cookieJarEnabled: true,
                timeoutSeconds: 12,
                followRedirects: true,
                transportPreference: "automatic"
            ),
            requestUrl: responseURL,
            responseUrl: responseURL,
            baseUrl: responseURL,
            transportKind: .http,
            attemptCount: 1
        )
    }

    private func makeChapter(url: String) -> BookChapter {
        BookChapter(
            index: 0,
            title: "第一章",
            url: url,
            baseUrl: "https://example.com/book/1/catalog",
            bookUrl: "https://example.com/book/1",
            sourceVariables: [:],
            bookVariables: ["name": "遮天", "author": "辰东"],
            chapterVariables: [:],
            variables: ["name": "遮天", "author": "辰东"]
        )
    }
}
