import XCTest
@testable import Legado

final class Phase13H5SearchDetailRuntimeTests: XCTestCase {

    func testSearchParserV2TreatsBookUrlPatternMatchAsDetailPage() throws {
        let source = BookSource(
            bookSourceName: "H5详情回落测试源",
            bookSourceUrl: "https://example.com/source",
            bookUrlPattern: #"https://example\.com/book/\d+"#,
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text"
            ),
            ruleBookInfo: BookInfoRule(
                name: ".book-title@text",
                author: ".author@text",
                kind: ".kind@text",
                tocUrl: ".toc@href"
            )
        )

        let html = """
        <html>
          <body>
            <article class="detail">
              <h1 class="book-title">遮天</h1>
              <div class="author">辰东</div>
              <div class="kind">玄幻</div>
              <a class="toc" href="/book/1/catalog">目录</a>
            </article>
          </body>
        </html>
        """

        let context = makeSearchContext(source: source, responseURL: "https://example.com/book/1", body: html)
        let books = try BookListParserV2.parseSearchResult(html: html, context: context)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "遮天")
        XCTAssertEqual(books.first?.author, "辰东")
        XCTAssertEqual(books.first?.kind, "玄幻")
        XCTAssertEqual(books.first?.bookUrl, "https://example.com/book/1")
        XCTAssertEqual(books.first?.infoHtml, html)
    }

    func testSearchParserV2FallsBackToStructuredDetailWhenBookListIsEmpty() throws {
        let source = BookSource(
            bookSourceName: "H5结构化回落测试源",
            bookSourceUrl: "https://api.example.com",
            ruleSearch: SearchRule(
                bookList: "$.data.list[*]"
            ),
            ruleBookInfo: BookInfoRule(
                name: "$.data.title",
                author: "$.data.author",
                intro: "$.data.intro",
                tocUrl: "$.data.catalogUrl"
            )
        )

        let json = """
        {
          "data": {
            "title": "完美世界",
            "author": "辰东",
            "intro": "大荒少年",
            "catalogUrl": "/book/99/catalog"
          }
        }
        """

        let context = makeSearchContext(source: source, responseURL: "https://api.example.com/book/99", body: json)
        let books = try BookListParserV2.parseSearchResult(html: json, context: context)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "完美世界")
        XCTAssertEqual(books.first?.author, "辰东")
        XCTAssertEqual(books.first?.bookUrl, "https://api.example.com/book/99")
        XCTAssertEqual(books.first?.variables["title"], "完美世界")
    }

    func testSearchParserV2KeepsBookWhenOptionalFieldFails() throws {
        let source = BookSource(
            bookSourceName: "H5字段容错测试源",
            bookSourceUrl: "https://example.com",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text",
                author: ".author@text",
                kind: "@json:$.missing[*]",
                bookUrl: ".link@href"
            )
        )

        let html = """
        <html>
          <body>
            <div class="item">
              <a class="link" href="/book/7"></a>
              <span class="title">神墓</span>
              <span class="author">辰东</span>
            </div>
          </body>
        </html>
        """

        let context = makeSearchContext(
            source: source,
            responseURL: "https://example.com/search?key=%E7%A5%9E%E5%A2%93",
            body: html
        )
        let books = try BookListParserV2.parseSearchResult(html: html, context: context)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "神墓")
        XCTAssertEqual(books.first?.author, "辰东")
        XCTAssertEqual(books.first?.kind, nil)
        XCTAssertEqual(books.first?.bookUrl, "https://example.com/book/7")
    }

    func testSearchParserV2UsesStructuredItemContextForSingleObjectJSONList() throws {
        let source = BookSource(
            bookSourceName: "H9单对象JSON列表化测试源",
            bookSourceUrl: "https://api.example.com",
            ruleSearch: SearchRule(
                bookList: "data",
                name: "novelName",
                author: "authorName",
                intro: "summary",
                kind: "categoryNames.[*].className",
                bookUrl: "/novel/{{$.novelId}}?isSearch=1",
                wordCount: "wordNum"
            ),
            ruleBookInfo: BookInfoRule(
                init: "data",
                name: "novelName",
                author: "authorName",
                intro: "summary",
                kind: "categoryNames.[*].className",
                tocUrl: "/novel/{{$.novelId}}/chapters"
            )
        )

        let json = """
        {
          "data": {
            "novelId": 1001,
            "novelName": "遮天",
            "authorName": "辰东",
            "summary": "九龙拉棺",
            "wordNum": 123456,
            "categoryNames": [
              { "className": "玄幻" },
              { "className": "东方玄幻" }
            ]
          }
        }
        """

        let context = makeSearchContext(source: source, responseURL: "https://api.example.com/search?keyword=%E9%81%AE%E5%A4%A9", body: json)
        let books = try BookListParserV2.parseSearchResult(html: json, context: context)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "遮天")
        XCTAssertEqual(books.first?.author, "辰东")
        XCTAssertEqual(books.first?.kind, "玄幻,东方玄幻")
        XCTAssertEqual(books.first?.bookUrl, "https://api.example.com/novel/1001?isSearch=1")
        XCTAssertEqual(books.first?.wordCount, "123456")
        XCTAssertEqual(books.first?.variables["novelId"], "1001")
    }

    func testSearchParserV2FallsBackToDetailSemanticsForStructuredItemWithoutNameRuleHit() throws {
        let source = BookSource(
            bookSourceName: "H9结构化详情回落测试源",
            bookSourceUrl: "https://api.example.com",
            ruleSearch: SearchRule(
                bookList: "$.items[*]",
                name: "$.missing.name",
                author: "$.missing.author",
                bookUrl: "$.detailUrl"
            ),
            ruleBookInfo: BookInfoRule(
                init: "$.detail",
                name: "$.title",
                author: "$.writer",
                intro: "$.intro",
                tocUrl: "$.catalog"
            )
        )

        let json = """
        {
          "items": [
            {
              "detailUrl": "/book/88",
              "detail": {
                "title": "神墓",
                "writer": "辰东",
                "intro": "太古战争",
                "catalog": "/book/88/chapters"
              }
            }
          ]
        }
        """

        let context = makeSearchContext(source: source, responseURL: "https://api.example.com/search", body: json)
        let books = try BookListParserV2.parseSearchResult(html: json, context: context)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "神墓")
        XCTAssertEqual(books.first?.author, "辰东")
        XCTAssertEqual(books.first?.bookUrl, "https://api.example.com/book/88")
        XCTAssertEqual(books.first?.variables["tocUrl"], "https://api.example.com/book/88/chapters")
    }

    func testBookInfoParserV2PrefersStageContextForCachedSearchDetail() throws {
        let source = BookSource(
            bookSourceName: "H5详情上下文测试源",
            bookSourceUrl: "https://example.com/source",
            ruleBookInfo: BookInfoRule(
                name: ".book-title@text",
                author: ".book-author@text",
                tocUrl: ".toc-link@href"
            )
        )

        let html = """
        <html>
          <body>
            <section class="detail">
              <h1 class="book-title">遮天</h1>
              <div class="book-author">辰东</div>
              <a class="toc-link" href="/catalog/123">目录</a>
            </section>
          </body>
        </html>
        """

        let requestContext = LegadoRequestContextV2(source: source)
        let bookStore = requestContext.makeBookRuntimeStore(
            sourceVariables: [:],
            bookVariables: ["existing": "1"],
            fallbackVariables: ["name": "旧名", "author": "旧作者"]
        )
        let seed = BookDetail(
            bookUrl: "https://example.com/book/123",
            name: "旧名",
            author: "旧作者",
            origin: source.bookSourceUrl,
            sourceVariables: [:],
            bookVariables: ["existing": "1"],
            variables: ["existing": "1"]
        )
        let context = StageRuntimeFactoryV2.makeDetailContext(
            source: source,
            requestContext: requestContext,
            variableStore: bookStore,
            bookUrl: "https://example.com/book/123",
            seedDetail: seed,
            cachedHTML: html
        )

        let detail = try BookInfoParserV2.parse(
            html: html,
            bookUrl: "https://example.com/book/123",
            context: context
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.tocUrl, "https://example.com/catalog/123")
        XCTAssertEqual(detail.infoHtml, html)
        XCTAssertEqual(detail.bookVariables["existing"], "1")
    }

    private func makeSearchContext(source: BookSource, responseURL: String, body: String) -> ParserStageContextV2 {
        let requestContext = LegadoRequestContextV2(source: source)
        let sourceStore = requestContext.makeSourceRuntimeStore()
        let responseContext = LegadoResponseContextV2(
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

        return StageRuntimeFactoryV2.makeSearchContext(
            source: source,
            requestContext: requestContext,
            variableStore: sourceStore,
            responseContext: responseContext
        )
    }
}
