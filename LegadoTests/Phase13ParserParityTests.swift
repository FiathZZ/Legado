import XCTest
import SwiftSoup
@testable import Legado

final class Phase13ParserParityTests: XCTestCase {
    func testBookListParserDoesNotFallbackMissingBookURLToSearchPage() throws {
        let source = BookSource(
            bookSourceName: "SearchFallback测试源",
            bookSourceUrl: "https://example.com/source",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text",
                bookUrl: ".missing@href"
            )
        )
        let html = """
        <html>
          <body>
            <div class="item">
              <a class="title">遮天</a>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "https://example.com/search?keyword=遮天"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "遮天")
        XCTAssertEqual(books.first?.bookUrl, "")
    }

    func testBookListParserAllowsResponseURLFallbackOnlyWhenPatternMatches() throws {
        let source = BookSource(
            bookSourceName: "SearchFallback详情页测试源",
            bookSourceUrl: "https://example.com/source",
            bookUrlPattern: "https://example.com/book/\\d+",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text"
            )
        )
        let html = """
        <html>
          <body>
            <div class="item">
              <a class="title">遮天</a>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "https://example.com/book/123"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookUrl, "https://example.com/book/123")
    }

    func testBookListParserAllowsResponseURLFallbackForNonSearchPageWithoutPattern() throws {
        let source = BookSource(
            bookSourceName: "SearchFallback非搜索页测试源",
            bookSourceUrl: "https://example.com/source",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text"
            )
        )
        let html = """
        <html>
          <body>
            <div class="item">
              <a class="title">遮天</a>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "https://api.example.com/book/123"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookUrl, "https://api.example.com/book/123")
    }

    func testBookListParserCachesInfoHTMLWhenResponseURLMatchesBookPatternWithoutExplicitBookURL() throws {
        let source = BookSource(
            bookSourceName: "SearchFallback缓存详情测试源",
            bookSourceUrl: "https://example.com/source",
            bookUrlPattern: "https://example.com/book/\\d+",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text"
            )
        )
        let html = """
        <html>
          <body>
            <div class="item">
              <a class="title">遮天</a>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "https://example.com/book/123"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookUrl, "https://example.com/book/123")
        XCTAssertTrue(books.first?.infoHtml?.contains("<div class=\"item\">") == true)
        XCTAssertTrue(books.first?.infoHtml?.contains("遮天") == true)
    }

    func testCachedItemHTMLStillParsesBookInfoFields() async throws {
        let source = BookSource(
            bookSourceName: "缓存item详情解析测试源",
            bookSourceUrl: "https://example.com/source",
            bookUrlPattern: "https://example.com/book/\\d+",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text"
            ),
            ruleBookInfo: BookInfoRule(
                name: ".book-title@text",
                author: ".book-author@text",
                tocUrl: ".toc-link@href"
            )
        )
        let searchHtml = """
        <html>
          <body>
            <div class="item">
              <h1 class="book-title">遮天</h1>
              <div class="book-author">辰东</div>
              <a class="toc-link" href="/chapters/123">目录</a>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: searchHtml,
            bookSource: source,
            baseUrl: "https://example.com/book/123"
        )

        XCTAssertEqual(books.count, 1)
        let cachedInfoHtml = try XCTUnwrap(books.first?.infoHtml)

        let detail = try await WebBook(bookSource: source).getBookInfo(
            bookUrl: "https://example.com/book/123",
            cachedInfoHtml: cachedInfoHtml,
            name: books.first?.name ?? "",
            author: books.first?.author ?? ""
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.tocUrl, "https://example.com/chapters/123")
        XCTAssertEqual(detail.infoHtml, cachedInfoHtml)
    }

    func testBookListParserSupportsTemplateFieldRulesOnHTMLItems() throws {
        let source = BookSource(
            bookSourceName: "HTML模板字段测试源",
            bookSourceUrl: "https://example.com/source",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: "{{@js: java.getString('a.title@text') + '-' + java.getString('.author@text')}}",
                author: ".author@text"
            )
        )
        let html = """
        <html>
          <body>
            <div class="item">
              <a class="title">遮天</a>
              <span class="author">辰东</span>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "https://example.com/search?keyword=遮天"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "遮天-辰东")
        XCTAssertEqual(books.first?.author, "辰东")
    }

    func testBookListParserSupportsRealSourceDefaultHTMLChainRuleFrom52Shuku() throws {
        let source = BookSource(
            bookSourceName: "52书库1",
            bookSourceUrl: "https://www.52shukuw.cc",
            ruleSearch: SearchRule(
                bookList: "ul.list@li",
                name: "h2 a@text",
                author: "h2 a@text##.*作者：",
                bookUrl: "h2 a@href"
            )
        )
        let html = """
        <html>
          <body>
            <ul class="list">
              <li>
                <h2><a href="/book/1">遮天作者：辰东</a></h2>
              </li>
            </ul>
          </body>
        </html>
        """

        XCTAssertThrowsError(
            try BookListParser.parseSearchResult(
                html: html,
                bookSource: source,
                baseUrl: "https://www.52shukuw.cc/sousuo/search.php?q=遮天"
            )
        )
    }

    func testBookListParserAllowsTagRuleToMatchCurrentAnchorItem() throws {
        let source = BookSource(
            bookSourceName: "当前A标签命中测试源",
            bookSourceUrl: "https://www.jianpan.la",
            ruleSearch: SearchRule(
                bookList: "class.list@tag.a",
                name: "class.shop-info.0@text##\\《|\\》",
                author: "class.shop-info.1@text##\\[|著|\\]",
                bookUrl: "tag.a@href"
            )
        )
        let html = """
        <html>
          <body>
            <div class="list">
              <a title="遮天" class="shop" href="/book/1/1864/">
                <div class="shop-info"><b>《遮天》</b></div>
                <div class="shop-info">辰东 [著]</div>
              </a>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "https://www.jianpan.la/search.php?q=遮天&s=15947871991047423724"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "遮天")
        XCTAssertEqual(books.first?.author, "辰东")
        XCTAssertEqual(books.first?.bookUrl, "https://www.jianpan.la/book/1/1864/")
    }

    func testBookListParserPrefersCurrentSearchItemForNestedAnchorURL() throws {
        let source = BookSource(
            bookSourceName: "玄幻阁搜索错页回归测试源",
            bookSourceUrl: "http://www.xuanyge.org",
            ruleSearch: SearchRule(
                bookList: "id.sitebox@tag.dl",
                name: "h3@a@text",
                author: "tag.span.1@text",
                lastChapter: "tag.a.2@text",
                bookUrl: "h3@a@href"
            )
        )
        let html = """
        <html>
          <body>
            <div id="sitebox">
              <dl>
                <dt><a href="/files/article/image/7/7557/7557s.jpg">封面</a></dt>
                <dd>
                  <h3><a href="/files/article/html/7/7557/">遮天</a></h3>
                  <p><span>作者</span><span>辰东</span></p>
                  <a href="/7185225.html">最新章节</a>
                </dd>
              </dl>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "http://www.xuanyge.org/modules/article/search.php?searchkey=%D5%DA%CC%EC"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "遮天")
        XCTAssertEqual(books.first?.bookUrl, "http://www.xuanyge.org/files/article/html/7/7557/")
    }

    func testAnalyzeRuleAppliesMixedJSTrailingSelectorToJSHTMLResult() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://example.com", source: nil)
        let html = """
        <html>
          <body>
            <script type="application/json" id="payload">ignored</script>
          </body>
        </html>
        """
        let textResult = try analyzer.getStringList(
            content: html,
            rule: """
            <js>
            "<div><p class='sone'><a href='/10_10089/'>遮天</a></p></div>"
            </js>
            p.sone
            """
        )
        let hrefResult = try analyzer.getStringList(
            content: html,
            rule: """
            <js>
            "<div><p class='sone'><a href='/10_10089/'>遮天</a></p></div>"
            </js>
            p.sone@a@href
            """,
            isUrl: true
        )

        XCTAssertEqual(textResult, ["遮天"])
        XCTAssertEqual(hrefResult, ["https://example.com/10_10089/"])
    }

    func testBookListParserPrefersDetailAnchorOverLatestChapterAnchor() throws {
        let source = BookSource(
            bookSourceName: "多锚点详情优先测试源",
            bookSourceUrl: "http://www.xuanyge.org",
            ruleSearch: SearchRule(
                bookList: "id.sitebox@tag.dl",
                name: "tag.a.1@text",
                author: "tag.span.1@text",
                bookUrl: "tag.a.1@href"
            )
        )
        let html = """
        <html>
          <body>
            <div id="sitebox">
              <dl>
                <dt><a href="/files/article/image/7/7557/7557s.jpg">封面</a></dt>
                <dd>
                  <h3><a href="/files/article/html/7/7557/">遮天</a></h3>
                  <p><span>作者</span><span>辰东</span></p>
                  <a href="/7185225.html">最新章节</a>
                </dd>
              </dl>
            </div>
          </body>
        </html>
        """

        let books = try BookListParser.parseSearchResult(
            html: html,
            bookSource: source,
            baseUrl: "http://www.xuanyge.org/modules/article/search.php?searchkey=%D5%DA%CC%EC"
        )

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookUrl, "http://www.xuanyge.org/files/article/html/7/7557/")
    }


    func testBookInfoParserRejectsBracketPlaceholderTocURLAndFallsBackToCatalogLink() throws {
        let source = BookSource(
            bookSourceName: "猫眼看书 TOC 占位测试源",
            bookSourceUrl: "http://api.jmlldsc.com",
            ruleBookInfo: BookInfoRule(
                name: "$..novelName",
                author: "$..authorName",
                tocUrl: "/novel/{{$.novelId}}/chapters?readNum=1"
            )
        )
        let html = #"""
        <html>
          <body>
            <a href='/novel/123/chapters?readNum=1'>目录</a>
            <script type="application/json" id="payload">
            {"novelId":[],"novelName":"遮天","authorName":"辰东"}
            </script>
          </body>
        </html>
        """#

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "http://api.jmlldsc.com/novel/123",
            baseUrl: "http://api.jmlldsc.com/novel/123"
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.tocUrl, "http://api.jmlldsc.com/novel/123/chapters?readNum=1")
    }

    func testBookInfoParserExecutesXPathTocRuleInsteadOfTreatingItAsLiteralURL() throws {
        let source = BookSource(
            bookSourceName: "XPath TOC 测试源",
            bookSourceUrl: "http://www.feisuwx.org",
            ruleBookInfo: BookInfoRule(
                name: "tag.h1@text",
                author: "class.s1.0@text",
                tocUrl: "//a[text()='全文阅读']/@href"
            )
        )
        let html = """
        <html>
          <body>
            <h1>遮天</h1>
            <p class="s1">作  者：辰东</p>
            <a rel="nofollow" href="/book/0/7/index.html">全文阅读</a>
          </body>
        </html>
        """

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "http://www.feisuwx.org/txtdown/7.html",
            baseUrl: "http://www.feisuwx.org/txtdown/7.html"
        )

        XCTAssertEqual(detail.tocUrl, "http://www.feisuwx.org/book/0/7/index.html")
    }

    func testBookChapterParserRejectsBracketPlaceholderChapterURLs() throws {
        let source = BookSource(
            bookSourceName: "SF轻小说章节URL占位测试源",
            bookSourceUrl: "https://minipapi.sfacg.com",
            ruleToc: TocRule(
                chapterList: "$.data.volumeList[*].chapterList[*]",
                chapterName: "$.title",
                chapterUrl: "https://minipapi.sfacg.com/pas/mpapi/Chaps/{{$.chapId}}?expand=content",
                isVip: "$.isVip"
            )
        )
        let json = #"""
        {
          "data": {
            "volumeList": [
              {
                "chapterList": [
                  { "title": "第一章", "chapId": [] },
                  { "title": "第二章", "chapId": 1002 }
                ]
              }
            ]
          }
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://minipapi.sfacg.com/pas/mpapi/novels/42",
            baseUrl: "https://minipapi.sfacg.com/pas/mpapi/novels/42/dirs",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://minipapi.sfacg.com/pas/mpapi/novels/42/dirs"
        )

        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].url, "https://minipapi.sfacg.com/pas/mpapi/novels/42/dirs")
        XCTAssertEqual(parsed.chapters[1].url, "https://minipapi.sfacg.com/pas/mpapi/Chaps/1002?expand=content")
    }

    func testGetBookInfoDoesNotRejectResponseURLFallbackWhenBookURLMatchesBaseURL() async throws {
        let source = BookSource(
            bookSourceName: "BookUrlPattern响应回退测试源",
            bookSourceUrl: "https://example.com/source",
            bookUrlPattern: "https://example.com/book/\\d+",
            ruleBookInfo: BookInfoRule(
                name: ".book-title@text",
                author: ".book-author@text"
            )
        )
        let webBook = WebBook(bookSource: source)
        let html = """
        <html>
          <body>
            <div class="item">
              <h1 class="book-title">遮天</h1>
              <div class="book-author">辰东</div>
            </div>
          </body>
        </html>
        """

        let detail = try await webBook.getBookInfo(
            bookUrl: "https://example.com/book/123",
            cachedInfoHtml: html,
            name: "遮天",
            author: "辰东"
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.bookUrl, "https://example.com/book/123")
    }

    func testGetBookInfoKeepsSearchKindForTocTemplate() async throws {
        let source = BookSource(
            bookSourceName: "TocKind模板测试源",
            bookSourceUrl: "https://example.com/source",
            ruleBookInfo: BookInfoRule(
                name: ".book-title@text",
                author: ".book-author@text",
                tocUrl: "https://example.com/toc?bookId={{book.kind}}"
            )
        )
        let webBook = WebBook(bookSource: source)
        let html = """
        <html>
          <body>
            <h1 class="book-title">遮天</h1>
            <div class="book-author">辰东</div>
          </body>
        </html>
        """

        let detail = try await webBook.getBookInfo(
            bookUrl: "https://example.com/book/1",
            cachedInfoHtml: html,
            name: "遮天",
            author: "辰东",
            kind: "1100475863"
        )

        XCTAssertEqual(detail.tocUrl, "https://example.com/toc?bookId=1100475863")
    }

    func testBookInfoParserKeepsLiteralDescriptorTocURLOnJSONDetailPage() throws {
        let source = BookSource(
            bookSourceName: "趣悦小说 TOC descriptor 测试源",
            bookSourceUrl: "https://vreader.vivo.com.cn",
            ruleBookInfo: BookInfoRule(
                init: "$.data",
                name: "$.title",
                author: "$.author@put:{bid:bookId}",
                tocUrl: "https://vreader.vivo.com.cn/book/catalogue.do,{'method':'POST','body':'{\"bookId\":\"{{$.bookId}}\"}'}"
            )
        )
        let json = #"""
        {
          "data": {
            "title": "遮天",
            "author": "辰东",
            "bookId": "N123"
          }
        }
        """#

        let detail = try BookInfoParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://vreader.vivo.com.cn/book/detail.do,{'method':'POST','body':'{\"bookId\":\"N123\"}'}",
            baseUrl: "https://vreader.vivo.com.cn/book/detail.do"
        )

        XCTAssertEqual(
            detail.tocUrl,
            "https://vreader.vivo.com.cn/book/catalogue.do,{'method':'POST','body':'{\"bookId\":\"N123\"}'}"
        )
    }

    func testAnalyzeUrlParsesStringHeadersOptionWithoutTurningIntoPostBody() {
        let analyzeUrl = AnalyzeUrl(
            rule: """
            https://app.kujiang.com/v1/book/catalog?book=69499&sort=asc,{
              "headers":"{
            auth-code:dc67efdd82941586e69207b3374037b2,app:com.dpx.kujiang,platform:android,device-uuid:5dd1f054b2f013b9,version:3.9.7,channel:XIAOMI}"
            }
            """,
            baseUrl: "https://app.kujiang.com/"
        )

        XCTAssertEqual(analyzeUrl.urlString, "https://app.kujiang.com/v1/book/catalog?book=69499&sort=asc")
        XCTAssertEqual(analyzeUrl.method, .get)
        XCTAssertNil(analyzeUrl.body)
        XCTAssertEqual(analyzeUrl.headers["auth-code"], "dc67efdd82941586e69207b3374037b2")
        XCTAssertEqual(analyzeUrl.headers["app"], "com.dpx.kujiang")
        XCTAssertEqual(analyzeUrl.headers["channel"], "XIAOMI")
    }

    func testCSSParserSupportsAttributeRegexSelectorFallback() throws {
        let html = """
        <html><head>
          <meta property="og:novel:book_name" content="遮天">
          <meta property="og:novel:author" content="辰东">
          <meta property="og:novel:category" content="玄幻">
          <meta property="og:novel:status" content="连载中">
        </head></html>
        """

        let values = try CSSParser.getStringList(
            from: html,
            rule: #"[property~=category|status]@content"#
        )

        XCTAssertEqual(values, ["玄幻", "连载中"])
    }

    func testBookChapterParserRecoversDescriptorURLWhenBareURLKeepsSameIdentity() throws {
        let source = BookSource(
            bookSourceName: "趣悦小说 chapter descriptor 测试源",
            bookSourceUrl: "https://vreader.vivo.com.cn",
            ruleToc: TocRule(
                chapterList: "$.data[*]",
                chapterName: "$.title",
                chapterUrl: """
                https://vreader.vivo.com.cn/book/chapter/content.do,{'method':'POST','body':'{"bookId":"@get:{bid}","order":"{{$.order}}"}'}
                """
            )
        )
        let json = #"""
        {
          "data": [
            {
              "title": "前言",
              "order": 1
            }
          ]
        }
        """#
        let store = ParserVariableStore(writeScope: .book)
        store.put("bid", value: "N141894316381445427200", scope: .book)

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://vreader.vivo.com.cn/book/detail.do",
            baseUrl: "https://vreader.vivo.com.cn/book/catalogue.do",
            variableStore: store,
            tocUrl: "https://vreader.vivo.com.cn/book/catalogue.do"
        )

        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(
            parsed.chapters[0].url,
            #"https://vreader.vivo.com.cn/book/chapter/content.do,{'method':'POST','body':'{"bookId":"N141894316381445427200","order":"1"}'}"#
        )
    }

    func testBookChapterParserParsesRealQuYueDescriptorURLWithUpdateTimeRule() throws {
        let source = BookSource(
            bookSourceName: "趣悦小说真实目录测试源",
            bookSourceUrl: "https://vreader.vivo.com.cn",
            ruleToc: TocRule(
                chapterList: "$.data[*]",
                chapterName: "$.title",
                chapterUrl: """
                https://vreader.vivo.com.cn/book/chapter/content.do,{'method': 'POST',
                'body': '{"model":"MI PAD 4","imei":"","clientVersion":"121020","elapsedtime":"981290","sysver":"","nt":"wifi","ver":"121020","u":"","pver":"0","resolution":"1920*1200","sessionId":"11901470641675854550446","pixel":"320","av":"27","adrVerName":"8.1.0","timestamp":"1675855424879","browserSystem":"1","browserSubSystem":"1","personalRecommend":"1","bookVersion":"30800","vreaderVersion":"121020","packageName":"com.vivo.vreader","udid":"","openudid":"b443cebc6f614746","bookshelfBookIds":[],"bookShelfListenBookIds":[],"featureValues":"2","bookId":"@get:{bid}","order":"{{$.order}}"}'
                }
                """,
                updateTime: "字数::{{$.wordCount}}"
            )
        )
        let json = #"""
        {
          "code": 0,
          "data": [
            {
              "title": "前言",
              "order": 1,
              "cpChapterId": "29522866",
              "isFree": true,
              "isPaid": false,
              "wordCount": 1660
            }
          ]
        }
        """#
        let store = ParserVariableStore(writeScope: .book)
        store.put("bid", value: "N141894316381445427200", scope: .book)

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://vreader.vivo.com.cn/book/detail.do",
            baseUrl: "https://vreader.vivo.com.cn/book/catalogue.do",
            variableStore: store,
            tocUrl: "https://vreader.vivo.com.cn/book/catalogue.do,{'method':'POST','body':'{\"bookId\":\"N141894316381445427200\"}'}"
        )

        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(parsed.chapters[0].title, "前言")
        XCTAssertEqual(parsed.chapters[0].updateTime, "字数::1660")
        XCTAssertEqual(
            parsed.chapters[0].url,
            #"https://vreader.vivo.com.cn/book/chapter/content.do,{'method': 'POST','body': '{"model":"MI PAD 4","bookId":"N141894316381445427200","order":"1"}'}"#
        )
    }

    func testBookChapterParserParsesRealKuJiangNestedCatalogChapterURLs() throws {
        let source = BookSource(
            bookSourceName: "酷匠阅读真实目录测试源",
            bookSourceUrl: "https://app.kujiang.com/",
            ruleToc: TocRule(
                chapterList: "$.body..chapters[*]",
                chapterName: "$.v_chapter",
                chapterUrl: "http://m.kujiang.com/book/@get:{bid}/{{$.chapter}}"
            )
        )
        let json = #"""
        {
          "header": { "method": "book/catalog", "result": 0, "version": 1 },
          "body": {
            "catalog": [
              {
                "v_volumn": "第一卷",
                "chapters": [
                  {
                    "chapter": "145704292",
                    "v_chapter": "第一章 五十万的彩礼"
                  },
                  {
                    "chapter": "145704299",
                    "v_chapter": "第二章 救命的钱"
                  }
                ]
              }
            ]
          }
        }
        """#
        let store = ParserVariableStore(writeScope: .book)
        store.put("bid", value: "69499", scope: .book)

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://app.kujiang.com/v1/book/get_book_infos?book=69499&subsite=m&from=search",
            baseUrl: "https://app.kujiang.com/v1/book/catalog?book=69499&sort=asc",
            variableStore: store,
            tocUrl: "https://app.kujiang.com/v1/book/catalog?book=69499&sort=asc"
        )

        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章 五十万的彩礼")
        XCTAssertEqual(parsed.chapters[0].url, "http://m.kujiang.com/book/69499/145704292")
        XCTAssertEqual(parsed.chapters[1].url, "http://m.kujiang.com/book/69499/145704299")
    }

    func testBookChapterParserSupportsFinalBooksSortedBase64HTMLJSRule() throws {
        let source = BookSource(
            bookSourceName: "完本小说网真实目录测试源",
            bookSourceUrl: "https://www.finalbooks.work",
            ruleToc: TocRule(
                chapterList: #"""
                ol > li
                <js>
                let Regex_ = /(data-[a-zA-Z0-9]+)/g;
                let label = result.select('li')[0].outerHtml().match(Regex_)[1];
                result.sort((a, b) => +a.attr(label) - +b.attr(label));
                chapterList = result.select('a').toArray().map(e => {
                    let labeln = e.outerHtml().match(Regex_);
                    return {
                        title: String(e.attr(labeln[0])).trim() || e.text(),
                        url: java.base64Decode(String(e.attr(labeln[1])))
                    }
                });
                JSON.stringify(chapterList);
                </js>
                $[*]
                """#,
                chapterName: "$.title",
                chapterUrl: "$.url"
            )
        )
        let html = #"""
        <html><body>
          <ol>
            <li data-order="2">
              <a data-title="第二章" data-link="L2Jvb2svNzM4NjAvMi5odG1s">第二章</a>
            </li>
            <li data-order="1">
              <a data-title="第一章" data-link="L2Jvb2svNzM4NjAvMS5odG1s">第一章</a>
            </li>
          </ol>
        </body></html>
        """#

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://www.finalbooks.work/book/73860/",
            baseUrl: "https://www.finalbooks.work/book/73860/catalog/"
        )

        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章")
        XCTAssertEqual(parsed.chapters[0].url, "https://www.finalbooks.work/book/73860/1.html")
        XCTAssertEqual(parsed.chapters[1].title, "第二章")
        XCTAssertEqual(parsed.chapters[1].url, "https://www.finalbooks.work/book/73860/2.html")
    }

    func testBookInfoPutInitSupportsRegexMetaSelectorsAcrossMultipleFields() throws {
        let source = BookSource(
            bookSourceName: "完本小说网 Put Init 测试源",
            bookSourceUrl: "https://www.finalbooks.work",
            ruleBookInfo: BookInfoRule(
                init: #"""
                @put:{"n":"[property$=book_name]@content",
                "a":"[property$=author]@content",
                "t":"[property~=category|status]@content",
                "m":".BGsectionOne-bottom@li.1@a@href"}
                """#,
                name: "@get:{n}",
                author: "@get:{a}",
                kind: "@get:{t}",
                tocUrl: "@get:{m}"
            )
        )
        let html = """
        <html><head>
          <meta property="og:novel:book_name" content="遮天">
          <meta property="og:novel:author" content="辰东">
          <meta property="og:novel:category" content="玄幻">
          <meta property="og:novel:status" content="连载中">
        </head><body>
          <ul class="BGsectionOne-bottom">
            <li><a href="/book/73860/">详情</a></li>
            <li><a href="/book/73860/catalog/">目录</a></li>
          </ul>
        </body></html>
        """

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://www.finalbooks.work/book/73860/",
            baseUrl: "https://www.finalbooks.work/book/73860/",
            variableStore: ParserVariableStore(writeScope: .book)
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.kind, "玄幻")
        XCTAssertEqual(detail.tocUrl, "https://www.finalbooks.work/book/73860/catalog/")
    }

    func testBookInfoParserInitSupportsPurePutRulesWithoutSelectorScope() throws {
        let source = BookSource(
            bookSourceName: "完本小说网",
            bookSourceUrl: "https://www.finalbooks.work",
            ruleBookInfo: BookInfoRule(
                init: """
                @put:{"n":"[property$=book_name]@content","a":"[property$=author]@content","t":"[property~=category|status]@content","m":".BGsectionOne-bottom@li.1@a@href"}
                """,
                name: "@get:{n}",
                author: "@get:{a}",
                kind: "@get:{t}",
                tocUrl: "@get:{m}"
            )
        )
        let html = """
        <html>
          <head>
            <meta property="og:book_name" content="遮天" />
            <meta property="og:author" content="辰东" />
            <meta property="og:category" content="玄幻" />
          </head>
          <body>
            <div class="BGsectionOne-bottom">
              <li><a href="/book/1/">简介</a></li>
              <li><a href="/book/1/list.html">目录</a></li>
            </div>
          </body>
        </html>
        """

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://www.finalbooks.work/book/1/",
            baseUrl: "https://www.finalbooks.work/book/1/"
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.kind, "玄幻")
        XCTAssertEqual(detail.tocUrl, "https://www.finalbooks.work/book/1/list.html")
        XCTAssertEqual(detail.bookVariables["n"], "遮天")
    }

    func testBookChapterParserBuildsLiteralJSONChapterURLFromTemplatesAndBookVariables() throws {
        let source = BookSource(
            bookSourceName: "趣悦小说",
            bookSourceUrl: "https://vreader.vivo.com.cn",
            ruleToc: TocRule(
                chapterList: "$.data[*]",
                chapterName: "$.title",
                chapterUrl: """
                https://vreader.vivo.com.cn/book/chapter/content.do,{'method': 'POST','body': '{"bookId":"@get:{bid}","order":"{{$.order}}"}'}
                """
            )
        )
        let json = """
        {"data":[{"title":"前言","order":1,"wordCount":1660}]}
        """
        let store = ParserVariableStore(bookValues: ["bid": "N141894316381445427200"], writeScope: .book)

        let result = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://vreader.vivo.com.cn/book/detail.do",
            baseUrl: "https://vreader.vivo.com.cn/book/catalogue.do",
            variableStore: store,
            bookVariables: ["bid": "N141894316381445427200"]
        )

        XCTAssertEqual(result.chapters.count, 1)
        XCTAssertTrue(result.chapters[0].url.contains("book/chapter/content.do"))
        XCTAssertTrue(result.chapters[0].url.contains("\"bookId\":\"N141894316381445427200\""))
        XCTAssertTrue(result.chapters[0].url.contains("\"order\":\"1\""))
    }

    func testChapterContentParserRescuesUsefulParagraphsWhenGreedyReplaceRegexClearsWholeText() throws {
        let source = BookSource(
            bookSourceName: "大米小说片段保底测试源",
            bookSourceUrl: "https://example.com",
            ruleContent: ContentRule(
                content: "tag.p@textNodes",
                replaceRegex: "##(.*请.*来.*大.*米.*小.*说.*).*"
            )
        )
        let html = """
        <div id="htmlContent">
          <p>第一段正文</p>
          <p>第二段正文</p>
          <p>请来大米小说看最新章节完整章节</p>
        </div>
        """

        let content = try ChapterContentParser.parse(
            html: html,
            bookSource: source,
            chapter: BookChapter(title: "第一章"),
            baseUrl: "https://example.com/chapter/1"
        )

        XCTAssertTrue(content.content.contains("第一段正文"))
        XCTAssertTrue(content.content.contains("第二段正文"))
        XCTAssertFalse(content.content.contains("请来大米小说"))
    }

    func testJSONPathRecursiveDescentFlattensNestedArrayMatches() throws {
        let json = #"""
        {
          "body": {
            "catalog": [
              {
                "chapters": [
                  { "chapter": "145704292", "v_chapter": "第一章" },
                  { "chapter": "145704299", "v_chapter": "第二章" }
                ]
              }
            ]
          }
        }
        """#

        let objects = try JSONPathParser.getObjects(from: json, rule: "$.body..chapters[*]")
        let titles = try JSONPathParser.getStringList(from: json, rule: "$.body..chapters[*].v_chapter")

        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(titles, ["第一章", "第二章"])
    }

    func testXPathParserSupportsDescendantPredicateAndPositionRange() throws {
        let html = """
        <html>
          <body>
            <ul>
              <li><a href="/intro">简介</a></li>
              <li><span>VIP</span><a href="/chapter-1">第一章</a></li>
              <li><span>VIP</span><a href="/chapter-2">第二章</a></li>
            </ul>
            <div id="chapterlist">
              <p>卷一</p>
              <p>第1章</p>
              <p>第2章</p>
              <p>尾页</p>
            </div>
          </body>
        </html>
        """

        let hrefs = try XPathParser.getStringList(
            from: html,
            rule: "//li[span]/a/@href",
            baseUrl: "https://example.com/book"
        )
        let titles = try XPathParser.getStringList(
            from: html,
            rule: "//div[@id='chapterlist']/p[position() >= 2 and position() < last()]/text()"
        )

        XCTAssertEqual(hrefs, [
            "https://example.com/chapter-1",
            "https://example.com/chapter-2"
        ])
        XCTAssertEqual(titles, ["第1章", "第2章"])
    }

    func testBookChapterParserKeepsBookContextForJSONListJSRules() throws {
        let source = BookSource(
            bookSourceName: "Phase13D测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "@js:var root = JSON.parse(result); root.chapters.map(function(item) { return { title: book.kind + ':' + item.title, url: item.url }; });",
                chapterName: "title",
                chapterUrl: "url"
            )
        )
        let content = #"""
        {
          "chapters": [
            { "title": "第一章", "url": "/chapter-1" },
            { "title": "第二章", "url": "/chapter-2" }
          ]
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: content,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            bookKind: "",
            tocUrl: "https://example.com/toc",
            bookVariables: ["kind": "玄幻"]
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["玄幻:第一章", "玄幻:第二章"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter-1",
            "https://example.com/chapter-2"
        ])
        XCTAssertEqual(parsed.chapters.first?.bookVariables["kind"], "玄幻")
    }

    func testBookChapterParserSupportsCurrentElementHrefShortcut() throws {
        let source = BookSource(
            bookSourceName: "目录href简写测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: ".title@text",
                chapterUrl: "href"
            )
        )
        let html = """
        <html>
          <body>
            <a class="chapter" href="/chapter-1"><span class="title">第一章</span></a>
            <a class="chapter" href="/chapter-2"><span class="title">第二章</span></a>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter-1",
            "https://example.com/chapter-2"
        ])
    }

    func testBookChapterParserSupportsCurrentElementCustomAttributeShortcut() throws {
        let source = BookSource(
            bookSourceName: "目录自定义属性简写测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: "data-title",
                chapterUrl: "data-href"
            )
        )
        let html = """
        <html>
          <body>
            <div class="chapter" data-title="第一章" data-href="/chapter-1"></div>
            <div class="chapter" data-title="第二章" data-href="/chapter-2"></div>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter-1",
            "https://example.com/chapter-2"
        ])
    }

    func testBookChapterParserDropsHrefPlaceholderURLs() throws {
        let source = BookSource(
            bookSourceName: "目录占位URL测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: ".title@text",
                chapterUrl: ".link@text"
            )
        )
        let html = """
        <html>
          <body>
            <div class="chapter">
              <span class="title">第一章</span>
              <span class="link">href</span>
            </div>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(parsed.chapters.first?.title, "第一章")
        XCTAssertEqual(parsed.chapters.first?.url, "https://example.com/toc")
    }

    func testBookChapterParserDropsJavaScriptSemicolonPlaceholderURLs() throws {
        let source = BookSource(
            bookSourceName: "目录JS占位URL测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: ".title@text",
                chapterUrl: ".link@text"
            )
        )
        let html = """
        <html>
          <body>
            <div class="chapter">
              <span class="title">第一章</span>
              <span class="link">javascript:;</span>
            </div>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(parsed.chapters.first?.title, "第一章")
        XCTAssertEqual(parsed.chapters.first?.url, "https://example.com/toc")
    }

    func testGetBookInfoInfersTocURLFromCatalogLinkWhenRuleResolvesPlaceholder() async throws {
        let source = BookSource(
            bookSourceName: "目录兜底测试源",
            bookSourceUrl: "https://example.com/source",
            ruleBookInfo: BookInfoRule(
                name: ".book-title@text",
                author: ".book-author@text",
                tocUrl: "url"
            )
        )
        let webBook = WebBook(bookSource: source)
        let html = """
        <html>
          <body>
            <h1 class="book-title">遮天</h1>
            <div class="book-author">辰东</div>
            <a class="nav-link" href="/book/1/read">立即阅读</a>
            <a class="toc-link" href="/chapter/1">查看章节目录</a>
          </body>
        </html>
        """

        let detail = try await webBook.getBookInfo(
            bookUrl: "https://example.com/book/1",
            cachedInfoHtml: html,
            name: "遮天",
            author: "辰东"
        )

        XCTAssertEqual(detail.tocUrl, "https://example.com/chapter/1")
    }

    func testBookChapterParserSupportsMultiClassLegacySelector() throws {
        let source = BookSource(
            bookSourceName: "多类名目录测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "class.float-list fill-block@li",
                chapterName: "a@text",
                chapterUrl: "a@href"
            )
        )
        let html = """
        <html>
          <body>
            <ul class="float-list fill-block">
              <li><a href="/chapter-1">第一章</a></li>
              <li><a href="/chapter-2">第二章</a></li>
            </ul>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter-1",
            "https://example.com/chapter-2"
        ])
    }

    func testJSONPathParserSupportsEqualityFilter() throws {
        let json = #"""
        [
          { "_id": "a1", "source": "zhuishuvip" },
          { "_id": "a2", "source": "xbiquge" },
          { "_id": "a3", "source": "other" }
        ]
        """#

        let exact = try JSONPathParser.getStringList(from: json, rule: "$.[?(@.source=='xbiquge')]._id")
        let exclude = try JSONPathParser.getStringList(from: json, rule: "$.[?(@.source!='zhuishuvip')]._id")

        XCTAssertEqual(exact, ["a2"])
        XCTAssertEqual(exclude, ["a2", "a3"])
    }

    func testJSONPathParserSupportsObjectWildcardValues() throws {
        let json = #"""
        {
          "data": {
            "first": { "title": "遮天", "author": "辰东" },
            "second": { "title": "完美世界", "author": "辰东" }
          }
        }
        """#

        let objects = try JSONPathParser.getObjects(from: json, rule: "$.data.*")
        let titles = objects.compactMap { item -> String? in
            guard let dict = item as? [String: Any] else { return nil }
            return dict["title"] as? String
        }

        XCTAssertEqual(titles, ["遮天", "完美世界"])
    }

    func testJSONPathParserSupportsRootWildcardFilterOverNestedObjects() throws {
        let json = #"""
        {
          "items": [
            { "novelName": "遮天", "novelId": 1 },
            { "novelname": "完美世界", "novelId": 2 },
            { "title": "凡人修仙传", "novelId": 3 }
          ]
        }
        """#

        let exactUpper = try JSONPathParser.getStringList(from: json, rule: "$.items[?(@.novelName=='遮天')].novelId")
        let exactLower = try JSONPathParser.getStringList(from: json, rule: "$.items[?(@.novelname=='完美世界')].novelId")

        XCTAssertEqual(exactUpper, ["1"])
        XCTAssertEqual(exactLower, ["2"])
    }

    func testBookChapterParserFallsBackToChapterLikeAnchors() throws {
        let source = BookSource(
            bookSourceName: "目录链接兜底测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: ".missing-list",
                chapterName: "a@text",
                chapterUrl: "a@href"
            )
        )
        let html = """
        <html>
          <body>
            <a href="/book/1/read">继续阅读</a>
            <a href="/book/1/1001">第一章 初见</a>
            <a href="/book/1/1002">第二章 再会</a>
            <a href="/book/1/1003">第三章 夜谈</a>
            <a href="/book/1/1004">第四章 出发</a>
            <a href="/book/1/1005">第五章 尾声</a>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/chapter/1",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/chapter/1"
        )

        XCTAssertEqual(parsed.chapters.count, 5)
        XCTAssertEqual(parsed.chapters.first?.title, "第一章 初见")
        XCTAssertEqual(parsed.chapters.first?.url, "https://example.com/book/1/1001")
    }

    func testBookChapterParserFallbackAnchorRulesReuseChapterURLTransform() throws {
        let source = BookSource(
            bookSourceName: "Heiyan兜底规则测试源",
            bookSourceUrl: "https://www.heiyan.com",
            ruleToc: TocRule(
                chapterList: "//li[span]/a",
                chapterName: "<js>(/isvip/.test(String(result)) ? '🔒' : '') + String(result).match(/>(.*?)</)[1]</js>",
                chapterUrl: "href<js>'https://a.heiyan.com/ajax/chapter/content/' + result.match(/\\d+$/)[0]</js>"
            )
        )
        let html = """
        <html>
          <body>
            <ul class="list">
              <li><a href="/book/129514/10601806">第一章 奇怪的病人</a></li>
              <li><a href="/book/129514/10601809">第二章 儿时的回忆</a></li>
              <li><a href="/book/129514/10601815">第三章 肉块</a></li>
              <li><a href="/book/129514/10601818">第四章 逃亡</a></li>
              <li><a href="/book/129514/10604030">第五章 回马枪</a></li>
            </ul>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://www.heiyan.com/book/129514",
            baseUrl: "https://w2.heiyan.com/chapter/129514",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "不死之境",
            bookAuthor: "大浪遮天",
            tocUrl: "https://w2.heiyan.com/chapter/129514"
        )

        XCTAssertEqual(parsed.chapters.count, 5)
        XCTAssertEqual(parsed.chapters.first?.title, "第一章 奇怪的病人")
        XCTAssertEqual(parsed.chapters.first?.url, "https://a.heiyan.com/ajax/chapter/content/10601806")
    }

    func testBookChapterParserSupportsRegexAllInOneListRule() throws {
        let source = BookSource(
            bookSourceName: "AllInOneRegex目录测试源",
            bookSourceUrl: "https://www.heiyan.com",
            ruleToc: TocRule(
                chapterList: #":(?s)(\d+)" class="(isvip)?[^"]*name[^>]*>([^<]*)"#,
                chapterName: "$2$3",
                chapterUrl: "https://a.heiyan.com/ajax/chapter/content/$1"
            )
        )
        let html = """
        <html>
          <body>
            <a href="/book/129514/10601806" class="name">第一章 奇怪的病人</a>
            <a href="/book/129514/10601809" class="isvip name">第二章 儿时的回忆</a>
          </body>
        </html>
        """

        let parsed = try BookChapterParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://www.heiyan.com/book/129514",
            baseUrl: "https://w2.heiyan.com/chapter/129514",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "不死之境",
            bookAuthor: "大浪遮天",
            tocUrl: "https://w2.heiyan.com/chapter/129514"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章 奇怪的病人", "isvip第二章 儿时的回忆"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://a.heiyan.com/ajax/chapter/content/10601806",
            "https://a.heiyan.com/ajax/chapter/content/10601809"
        ])
    }

    func testBookChapterParserSupportsJSONListRuleFallbackOperator() throws {
        let source = BookSource(
            bookSourceName: "JSON目录并集测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "missing||chapterlist",
                chapterName: "chaptername",
                chapterUrl: "@js:'https://example.com/chapter/' + result.chapterid"
            )
        )
        let json = #"""
        {
          "chapterlist": [
            { "chapterid": "1", "chaptername": "第一章" },
            { "chapterid": "2", "chaptername": "第二章" }
          ]
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter/1",
            "https://example.com/chapter/2"
        ])
    }

    func testBookChapterParserDoesNotSplitEmbeddedJSOperatorsInsideListRule() throws {
        let source = BookSource(
            bookSourceName: "目录 JS 防误拆测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: """
                $.chapterlist
                <js>
                if(result=="[]"){
                    allpage=String(java.getString("@@class.num@text||class.redtext@text")).match(/(\\d+)/)?.[1]??0;
                    result = [];
                } else {
                    result = JSON.parse(result);
                }
                </js>
                """,
                chapterName: "chaptername",
                chapterUrl: "@js:'https://example.com/chapter/' + result.chapterid"
            )
        )
        let json = #"""
        {
          "chapterlist": [
            { "chapterid": "1", "chaptername": "第一章" }
          ]
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(parsed.chapters.first?.title, "第一章")
        XCTAssertEqual(parsed.chapters.first?.url, "https://example.com/chapter/1")
    }

    func testBookChapterParserPreservesJSONArrayForListRuleEmbeddedJS() throws {
        let source = BookSource(
            bookSourceName: "目录列表 JS 数组保持测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "$.data.volumeList<js>result</js>",
                chapterName: "chapterName",
                chapterUrl: "url"
            )
        )
        let json = #"""
        {
          "data": {
            "volumeList": [
              { "chapterName": "第一章", "url": "/chapter-1" },
              { "chapterName": "第二章", "url": "/chapter-2" },
              { "chapterName": "第三章", "url": "/chapter-3" }
            ]
          }
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章", "第二章", "第三章"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter-1",
            "https://example.com/chapter-2",
            "https://example.com/chapter-3"
        ])
    }

    func testBookChapterParserSupportsJSONPrefixPlusEmbeddedJSChapterURL() throws {
        let source = BookSource(
            bookSourceName: "目录字段前置 JSON+JS 测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "$.rows[*]",
                chapterName: "$.serialName",
                chapterUrl: """
                $.serialID
                @js:
                let payload = JSON.stringify({
                  ids: [result]
                });
                "https://example.com/chapter," + JSON.stringify({"method":"POST","body":payload})
                """
            )
        )
        let json = #"""
        {
          "rows": [
            { "serialID": 101, "serialName": "第一章" },
            { "serialID": 102, "serialName": "第二章" }
          ]
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            bookKind: "9001",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(
            parsed.chapters.first?.url,
            #"https://example.com/chapter,{"method":"POST","body":"{\"ids\":[101]}"}"#
        )
        XCTAssertEqual(
            parsed.chapters.last?.url,
            #"https://example.com/chapter,{"method":"POST","body":"{\"ids\":[102]}"}"#
        )
    }

    func testBookChapterParserSupportsJSONFieldPlusItemLevelJSChapterURL() throws {
        let source = BookSource(
            bookSourceName: "目录字段解密 URL 测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "$.data.list[*]",
                chapterName: "chapterName",
                chapterUrl: """
                path
                @js:
                "https://example.com" + String(result).replace("ENC:", "/chapter/")
                """
            )
        )
        let json = #"""
        {
          "data": {
            "list": [
              { "chapterName": "第一章", "path": "ENC:1001.html" },
              { "chapterName": "第二章", "path": "ENC:1002.html" }
            ]
          }
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/toc",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc"
        )

        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://example.com/chapter/1001.html",
            "https://example.com/chapter/1002.html"
        ])
    }

    func testBookChapterParserSupportsHTMLJSObjectArrayTextHrefBridge() throws {
        let source = BookSource(
            bookSourceName: "Qubook TOC JS 对象数组测试源",
            bookSourceUrl: "https://qubook.org",
            ruleToc: TocRule(
                chapterList: """
                <js>
                var list = [{text:'第1页',href:baseUrl}];
                list.push({text:'第2页',href:baseUrl.replace('.html', '_2.html')});
                list;
                </js>
                """,
                chapterName: "text",
                chapterUrl: "href"
            )
        )

        let parsed = try BookChapterParser.parse(
            html: "<html><body><div class='pagination'></div></body></html>",
            bookSource: source,
            bookUrl: "https://qubook.org/booknv/111305.html",
            baseUrl: "https://qubook.org/booknv/111305.html",
            variableStore: ParserVariableStore(writeScope: .book),
            tocUrl: "https://qubook.org/booknv/111305.html"
        )

        XCTAssertEqual(parsed.chapters.map(\.title), ["第1页", "第2页"])
        XCTAssertEqual(parsed.chapters.map(\.url), [
            "https://qubook.org/booknv/111305.html",
            "https://qubook.org/booknv/111305_2.html"
        ])
    }

    func testCSSParserLegacyExclusionIndexesMatchAndroidSemantics() throws {
        let html = """
        <html>
          <body>
            <div id="content">
              <p>第一段</p>
              <p>第二段</p>
              <p>广告尾一</p>
              <p>广告尾二</p>
            </div>
          </body>
        </html>
        """

        let values = try CSSParser.getStringList(
            from: html,
            rule: "tag.p!-1:-2@text"
        )

        XCTAssertEqual(values, ["第一段", "第二段"])
    }

    func testCSSParserBracketRangeSupportsInclusiveEndAndReverseOrder() throws {
        let html = """
        <html>
          <body>
            <ul>
              <li>一</li>
              <li>二</li>
              <li>三</li>
              <li>四</li>
            </ul>
          </body>
        </html>
        """

        let values = try CSSParser.getStringList(
            from: html,
            rule: "tag.li[-1:0]@text"
        )

        XCTAssertEqual(values, ["四", "三", "二", "一"])
    }

    func testChapterContentParserHonorsLegacyExcludedTrailingParagraphs() throws {
        let source = BookSource(
            bookSourceName: "正文旧式索引测试源",
            bookSourceUrl: "https://example.com/source",
            ruleContent: ContentRule(
                content: "tag.p!-1:-2@textNodes"
            )
        )
        let html = """
        <html>
          <body>
            <p>第一段</p>
            <p>第二段</p>
            <p>最新网址：www.example.com</p>
            <p>广告尾页</p>
          </body>
        </html>
        """

        let chapter = BookChapter(
            index: 0,
            title: "第一章",
            url: "https://example.com/chapter-1",
            baseUrl: "https://example.com/chapter-1",
            bookUrl: "https://example.com/book-1"
        )

        let content = try ChapterContentParser.parse(
            html: html,
            bookSource: source,
            chapter: chapter,
            baseUrl: "https://example.com/chapter-1"
        )

        XCTAssertTrue(content.content.contains("第一段"))
        XCTAssertTrue(content.content.contains("第二段"))
        XCTAssertFalse(content.content.contains("广告尾页"))
        XCTAssertFalse(content.content.contains("最新网址"))
    }

    func testBookChapterParserSupportsPureJSChapterURLAgainstJSONStringItemContext() throws {
        let source = BookSource(
            bookSourceName: "纯JS目录链接测试源",
            bookSourceUrl: "https://example.com/source",
            ruleToc: TocRule(
                chapterList: "$.chapterlist",
                chapterName: "$.chaptername",
                chapterUrl: """
                @js:
                result = "https://example.com/chapter/" + java.getString("$.chapterid");
                """
            )
        )
        let json = #"""
        {
          "chapterlist": [
            { "chapterid": "1", "chaptername": "第一章" },
            { "chapterid": "2", "chaptername": "第二章" }
          ]
        }
        """#

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/chapterList",
            variableStore: ParserVariableStore(writeScope: .book),
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/chapterList"
        )

        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters.first?.url, "https://example.com/chapter/1")
        XCTAssertEqual(parsed.chapters.last?.url, "https://example.com/chapter/2")
    }

    func testBookInfoParserSupportsMixedJSInitReturningJSONObject() throws {
        let source = BookSource(
            bookSourceName: "详情init对象测试源",
            bookSourceUrl: "https://example.com/source",
            ruleBookInfo: BookInfoRule(
                init: """
                <js>
                var payload = {
                  turl: "https://example.com/toc/42",
                  title: "测试书",
                  writer: "测试作者"
                };
                payload
                </js>
                """,
                name: "title",
                author: "writer",
                tocUrl: "turl"
            )
        )

        let detail = try BookInfoParser.parse(
            html: "<html><body>detail</body></html>",
            bookSource: source,
            bookUrl: "https://example.com/book/42",
            baseUrl: "https://example.com/detail/42",
            variableStore: ParserVariableStore(writeScope: .book)
        )

        XCTAssertEqual(detail.name, "测试书")
        XCTAssertEqual(detail.author, "测试作者")
        XCTAssertEqual(detail.tocUrl, "https://example.com/toc/42")
    }

    func testAnalyzeRuleSupportsJJWXCStylePureJSChapterURL() throws {
        let source = BookSource(
            bookSourceName: "晋江评论目录链接测试源",
            bookSourceUrl: "https://android.jjwxc.net",
            jsLib: """
            function getToken(){
                const { source } = this;
                let infomap = String(source.getLoginHeader());
                infomap = (infomap!="null"&&infomap!=""&&infomap!=null)?infomap:"";
                return infomap;
            }
            """
        )
        let analyzer = AnalyzeRule(
            baseUrl: "http://app-cdn.jjwxc.net/androidapi/chapterList?novelId=7873352&more=0&whole=1",
            source: source,
            variableStore: ParserVariableStore(writeScope: .chapter)
        )
        let itemJSON = #"""
        {"chapterid":"1","novelid":"7873352","chaptername":"第1章"}
        """#
        let rule = #"""
        @js:
        if(/chapterList/.test(baseUrl)){
            let sss = String(source.getVariable());
            let limit = sss.match(/◎(\d+)/)?.[1] ?? 500;
            let nid = java.getString("$.novelid");
            let cid = java.getString("$.chapterid");
            let 点赞url =
            `https://android.jjwxc.net/comment/getCommentList?versionCode=439&limit=${limit}&offset=0&commentSort=2&token=${getToken()}&novelId=${nid}&chapterId=${cid}`;
            result = 点赞url;
        }else{
            result = java.getString("$.chapterurl");
        }
        """#

        let resolved = try analyzer.getString(content: itemJSON, rule: rule, isUrl: true)
        XCTAssertEqual(
            resolved,
            "https://android.jjwxc.net/comment/getCommentList?versionCode=439&limit=500&offset=0&commentSort=2&token=&novelId=7873352&chapterId=1"
        )
    }

    func testBookChapterParserSupportsJJWXCPureJSChapterURLFromJSONObjectItem() throws {
        let source = BookSource(
            bookSourceName: "晋江评论目录链接测试源",
            bookSourceUrl: "https://android.jjwxc.net",
            jsLib: """
            function getToken(){
                const { source } = this;
                let infomap = String(source.getLoginHeader());
                infomap = (infomap!="null"&&infomap!=""&&infomap!=null)?infomap:"";
                return infomap;
            }
            """,
            ruleToc: TocRule(
                chapterList: "$.chapterlist",
                chapterName: "$.chaptername",
                chapterUrl: """
                @js:
                if(/chapterList/.test(baseUrl)){
                    let sss = String(source.getVariable());
                    let limit = sss.match(/◎(\\d+)/)?.[1] ?? 500;
                    let nid = java.getString("$.novelid");
                    let cid = java.getString("$.chapterid");
                    result = `https://android.jjwxc.net/comment/getCommentList?versionCode=439&limit=${limit}&offset=0&commentSort=2&token=${getToken()}&novelId=${nid}&chapterId=${cid}`;
                }else{
                    result = java.getString("$.chapterurl");
                }
                """
            )
        )
        let json = #"""
        {
          "chapterlist": [
            { "chapterid": "1", "novelid": "7873352", "chaptername": "第1章" }
          ]
        }
        """#
        let store = ParserVariableStore(
            sourceValues: ["custom": "◎500"],
            writeScope: .book
        )

        let parsed = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "http://app-cdn.jjwxc.net/androidapi/chapterList?novelId=7873352&more=0&whole=1",
            variableStore: store,
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "http://app-cdn.jjwxc.net/androidapi/chapterList?novelId=7873352&more=0&whole=1"
        )

        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(
            parsed.chapters.first?.url,
            "https://android.jjwxc.net/comment/getCommentList?versionCode=439&limit=500&offset=0&commentSort=2&token=&novelId=7873352&chapterId=1"
        )
    }

    func testAnalyzeRulePreservesMultilineChainedExpressionCompletion() throws {
        let analyzer = AnalyzeRule(
            baseUrl: "https://example.com/comment.php?page=1",
            source: BookSource(
                bookSourceName: "多行链式表达式测试源",
                bookSourceUrl: "https://example.com"
            ),
            variableStore: ParserVariableStore(writeScope: .chapter)
        )
        let rule = #"""
        <js>
        result
        .replace(/alpha/g, 'beta')
        .replace(/beta/g, 'gamma')
        </js>
        """#

        let resolved = try analyzer.getString(content: "<div>alpha</div>", rule: rule)
        XCTAssertEqual(resolved, "<div>gamma</div>")
    }

    func testBookInfoParserSupportsABaInitObjectWithBookVariable() throws {
        let source = BookSource(
            bookSourceName: "阿巴小说详情测试源",
            bookSourceUrl: "http://xiaoshuo.uc.cn",
            ruleBookInfo: BookInfoRule(
                init: """
                <js>
                var bookId = java.get('bid');
                var list = {'turl':'https://ocean.shuqireader.com/api/bcspub/qswebapi/book/chapterlist?_=&bookId=' + bookId};
                list
                </js>
                """,
                tocUrl: "turl"
            )
        )
        let store = ParserVariableStore(
            sourceValues: [:],
            ruleDataValues: [:],
            bookValues: ["bid": "8241889"],
            chapterValues: [:],
            writeScope: .book
        )

        let detail = try BookInfoParser.parse(
            html: "<html><body>detail</body></html>",
            bookSource: source,
            bookUrl: "http://read.xiaoshuo1-sm.com/novel/8241889",
            baseUrl: "http://read.xiaoshuo1-sm.com/novel/8241889",
            variableStore: store
        )

        XCTAssertEqual(
            detail.tocUrl,
            "https://ocean.shuqireader.com/api/bcspub/qswebapi/book/chapterlist?_=&bookId=8241889"
        )
    }

    func testGetBookInfoInfersSfacgMiniTocURLFromBookURLWhenTemplateMissesID() async throws {
        let source = BookSource(
            bookSourceName: "SFACG目录兜底测试源",
            bookSourceUrl: "https://minipapi.sfacg.com",
            ruleBookInfo: BookInfoRule(
                name: "$.data.novelName",
                author: "$.data.authorName",
                tocUrl: "https://minipapi.sfacg.com/pas/mpapi/novels/{{$.data.missingId}}/dirs"
            )
        )
        let webBook = WebBook(bookSource: source)
        let json = #"""
        {
          "data": {
            "novelId": 46180,
            "novelName": "测试小说",
            "authorName": "测试作者"
          }
        }
        """#

        let detail = try await webBook.getBookInfo(
            bookUrl: "https://minipapi.sfacg.com/pas/mpapi/novels/46180?expand=intro",
            cachedInfoHtml: json,
            name: "测试小说",
            author: "测试作者"
        )

        XCTAssertEqual(detail.tocUrl, "https://minipapi.sfacg.com/pas/mpapi/novels/46180/dirs")
    }

    func testHTTPClientOverridesJJWXCChapterContentHeaders() throws {
        let url = try XCTUnwrap(URL(string: "https://app.jjwxc.org/androidapi/chapterContent?novelId=9964571&chapterId=1"))
        var request = URLRequest(url: url)
        request.setValue("Dalvik/2.1.0", forHTTPHeaderField: "User-Agent")

        let prepared = HTTPClient.applyingSiteSpecificHeaders(to: request, url: url)

        XCTAssertEqual(
            prepared.value(forHTTPHeaderField: "User-Agent"),
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Mobile Safari/537.36"
        )
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "versionCode"), "279")
    }

    func testHTTPClientKeepsOtherRequestsUntouched() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/chapterContent"))
        var request = URLRequest(url: url)
        request.setValue("Dalvik/2.1.0", forHTTPHeaderField: "User-Agent")

        let prepared = HTTPClient.applyingSiteSpecificHeaders(to: request, url: url)

        XCTAssertEqual(prepared.value(forHTTPHeaderField: "User-Agent"), "Dalvik/2.1.0")
        XCTAssertNil(prepared.value(forHTTPHeaderField: "versionCode"))
    }

    func testChapterContentParserSupportsAssignedJSResultWithoutExplicitReturn() throws {
        let source = BookSource(
            bookSourceName: "正文 JS result 赋值测试源",
            bookSourceUrl: "https://example.com/source",
            ruleContent: ContentRule(
                content: """
                @js:
                intro=java.getString('chapterIntro');
                body=java.getString('content');
                result='▍'+intro+'\\n'+body;
                """
            )
        )
        let chapter = BookChapter(
            index: 0,
            title: "第一章",
            url: "https://example.com/chapter/1",
            baseUrl: "https://example.com/chapter/1",
            bookUrl: "https://example.com/book/1"
        )
        let json = #"""
        {
          "chapterIntro": "导语",
          "content": "正文内容"
        }
        """#

        let parsed = try ChapterContentParser.parse(
            html: json,
            bookSource: source,
            chapter: chapter,
            baseUrl: "https://example.com/undefined?novelId=1&chapterId=1",
            variableStore: ParserVariableStore(writeScope: .chapter)
        )

        XCTAssertTrue(parsed.content.contains("导语"))
        XCTAssertTrue(parsed.content.contains("正文内容"))
    }

    func testChapterContentParserExposesSrcForJSONBasedJSRules() throws {
        let source = BookSource(
            bookSourceName: "正文 JS src 测试源",
            bookSourceUrl: "https://example.com/source",
            ruleContent: ContentRule(
                content: """
                @js:
                result=JSON.parse(src).content;
                """
            )
        )
        let chapter = BookChapter(
            index: 0,
            title: "第一章",
            url: "https://example.com/chapter/1",
            baseUrl: "https://example.com/chapter/1",
            bookUrl: "https://example.com/book/1"
        )
        let json = #"""
        {
          "content": "直接读取 src"
        }
        """#

        let parsed = try ChapterContentParser.parse(
            html: json,
            bookSource: source,
            chapter: chapter,
            baseUrl: "https://example.com/undefined?novelId=1&chapterId=1",
            variableStore: ParserVariableStore(writeScope: .chapter)
        )

        XCTAssertTrue(parsed.content.contains("直接读取 src"))
    }

    func testMeaningfulTocPageAllowsSamePageChapterWhenChapterContextExists() {
        let webBook = WebBook(bookSource: BookSource(bookSourceName: "TOC判定测试源", bookSourceUrl: "https://example.com/source"))
        let chapter = BookChapter(
            index: 0,
            title: "第一章",
            url: "https://example.com/toc",
            baseUrl: "https://example.com/toc",
            bookUrl: "https://example.com/book/1",
            chapterVariables: ["chapterId": "1001"],
            variables: ["chapterId": "1001"]
        )

        XCTAssertTrue(
            webBook.isUsableChapterReference(
                chapter,
                pageURL: "https://example.com/toc",
                bookUrl: "https://example.com/book/1"
            )
        )
    }

    func testMeaningfulTocPageRejectsSamePageChapterWithoutChapterContext() {
        let webBook = WebBook(bookSource: BookSource(bookSourceName: "TOC判定测试源", bookSourceUrl: "https://example.com/source"))
        let chapter = BookChapter(
            index: 0,
            title: "第一章",
            url: "https://example.com/toc",
            baseUrl: "https://example.com/toc",
            bookUrl: "https://example.com/book/1"
        )

        XCTAssertFalse(
            webBook.isUsableChapterReference(
                chapter,
                pageURL: "https://example.com/toc",
                bookUrl: "https://example.com/book/1"
            )
        )
    }

    func testAnalyzeRuleEmbeddedJSKeepsSideEffectsBeforeTrailingExpression() throws {
        let store = ParserVariableStore(writeScope: .source)
        let analyzer = AnalyzeRule(
            baseUrl: "https://example.com/search",
            source: nil,
            variableStore: store
        )

        let value = try analyzer.getString(
            content: #"{"bid":"8241889"}"#,
            rule: #"$.bid<js>java.put('bid',result);'http://xiaoshuo.uc.cn/#!/ct/cover/bid/'+result</js>"#,
            isUrl: true
        )

        XCTAssertEqual(value, "http://xiaoshuo.uc.cn/#!/ct/cover/bid/8241889")
        XCTAssertEqual(store.get("bid"), "8241889")
    }

    func testAnalyzeRuleJSONInlineTemplateDoesNotCorruptMixedString() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://m.sfacg.com/search")

        let value = try analyzer.getString(
            content: #"{"NovelID":46180}"#,
            rule: "/i/{$.NovelID}/",
            isUrl: true
        )

        XCTAssertEqual(value, "https://m.sfacg.com/i/46180/")
    }

    func testAnalyzeRuleJSONInlineTemplateThenTrailingJSMatchesAndroidChain() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://m.sfacg.com/search")

        let value = try analyzer.getString(
            content: #"{"NovelID":46180}"#,
            rule: """
            http://book.sfacg.com/Novel/{$.NovelID}/@js:
            result.replace(/book\\.sfacg\\.com\\/Novel/, 'm.sfacg.com/i')
            """,
            isUrl: true
        )

        XCTAssertEqual(value, "http://m.sfacg.com/i/46180/")
    }

    func testAnalyzeRuleRenderedXPathTemplateContinuesEvaluating() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://example.com/root")
        let html = """
        <html>
          <body>
            <a href="/chapter-1">第一章</a>
          </body>
        </html>
        """

        let value = try analyzer.getString(
            content: html,
            rule: "{{'//a/@href'}}",
            isUrl: true
        )

        XCTAssertEqual(value, "https://example.com/chapter-1")
    }

    func testAnalyzeRuleElementTemplateContinuesEvaluating() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://example.com/root")
        let document = try SwiftSoup.parse("""
        <div class="card">
          <a href="/chapter-2">第二章</a>
        </div>
        """)
        let card = try XCTUnwrap(try document.select(".card").first())

        let value = try analyzer.getString(
            element: card,
            rule: "{{'a@href'}}",
            isUrl: true
        )

        XCTAssertEqual(value, "https://example.com/chapter-2")
    }

    func testAnalyzeRuleContentPutUsesCurrentHTMLContext() throws {
        let store = ParserVariableStore(writeScope: .book)
        let analyzer = AnalyzeRule(
            baseUrl: "https://example.com/root",
            source: nil,
            variableStore: store
        )
        let html = """
        <html><body><span class="title">遮天</span></body></html>
        """

        let value = try analyzer.getString(
            content: html,
            rule: ".title@text@put:{\"bookName\":\".title@text\"}"
        )

        XCTAssertEqual(value, "遮天")
        XCTAssertEqual(store.get("bookName"), "遮天")
    }

    func testAnalyzeRuleElementPutUsesCurrentElementContext() throws {
        let store = ParserVariableStore(writeScope: .chapter)
        let analyzer = AnalyzeRule(
            baseUrl: "https://example.com/root",
            source: nil,
            variableStore: store
        )
        let document = try SwiftSoup.parse("""
        <li class="chapter">
          <a href="/chapter-3">第三章</a>
        </li>
        """)
        let item = try XCTUnwrap(try document.select(".chapter").first())

        let value = try analyzer.getString(
            element: item,
            rule: "a@href@put:{\"chapterTitle\":\"a@text\"}",
            isUrl: true
        )

        XCTAssertEqual(value, "https://example.com/chapter-3")
        XCTAssertEqual(store.get("chapterTitle"), "第三章")
    }

    func testAnalyzeRuleStandaloneGetReturnsLiteralValue() throws {
        let store = ParserVariableStore(writeScope: .book)
        store.put("n", value: "弹指遮天路")
        let analyzer = AnalyzeRule(
            baseUrl: "https://example.com/book",
            source: nil,
            variableStore: store
        )

        let value = try analyzer.getString(
            content: "<html><body></body></html>",
            rule: "@get:{n}"
        )

        XCTAssertEqual(value, "弹指遮天路")
    }

    func testAnalyzeRuleElementStandaloneGetReturnsLiteralValue() throws {
        let store = ParserVariableStore(writeScope: .book)
        store.put("k", value: "状态：完结")
        let analyzer = AnalyzeRule(
            baseUrl: "https://example.com/book",
            source: nil,
            variableStore: store
        )
        let document = try SwiftSoup.parse("<div class='book'>ignored</div>")
        let element = try XCTUnwrap(try document.select(".book").first())

        let value = try analyzer.getString(element: element, rule: "@get:{k}")

        XCTAssertEqual(value, "状态：完结")
    }

    func testAnalyzeRuleFallbackSkipsMalformedCSSBranch() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://example.com/root")
        let html = "<html><body><a href='/book/1'>遮天</a></body></html>"

        let value = try analyzer.getString(
            content: html,
            rule: "状态：完结,@get:{类}||a@href",
            isUrl: true
        )

        XCTAssertEqual(value, "https://example.com/book/1")
    }

    func testBookInfoStandalonePutInitFeedsGetFields() throws {
        let source = BookSource(
            bookSourceName: "Put Init详情测试源",
            bookSourceUrl: "https://example.com",
            ruleBookInfo: BookInfoRule(
                init: #"@put:{n:"[property$=book_name]@content",a:"[property$=author]@content"}"#,
                name: "@get:{n}",
                author: "@get:{a}"
            )
        )
        let html = """
        <html><head>
          <meta property="og:novel:book_name" content="遮天">
          <meta property="og:novel:author" content="辰东">
        </head><body></body></html>
        """

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/book/1",
            variableStore: ParserVariableStore(writeScope: .book)
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
    }

    func testBookInfoPutInitWithTrailingJSStillFeedsGetFields() throws {
        let source = BookSource(
            bookSourceName: "Put JS Init详情测试源",
            bookSourceUrl: "https://example.com",
            ruleBookInfo: BookInfoRule(
                init: #"@put:{n:"[property$=book_name]@content"}@js:java.log(baseUrl)"#,
                name: "@get:{n}"
            )
        )
        let html = """
        <html><head>
          <meta property="og:novel:book_name" content="遮天">
        </head><body></body></html>
        """

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/book/1",
            variableStore: ParserVariableStore(writeScope: .book)
        )

        XCTAssertEqual(detail.name, "遮天")
    }

    func testAnalyzeRuleGetElementsCombinesDefaultBranches() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://example.com")
        let html = """
        <ul>
          <li class="search"><a href="/a">A</a></li>
          <li class="done"><a href="/b">B</a></li>
        </ul>
        """

        let elements = try analyzer.getElements(content: html, rule: ".search@a&&.done@a")
        let titles = try elements.map { try $0.text() }

        XCTAssertEqual(titles, ["A", "B"])
    }

    func testAnalyzeRuleGetElementsStripsOrderPrefixBeforeCSS() throws {
        let analyzer = AnalyzeRule(baseUrl: "https://example.com")
        let html = """
        <ul class="librarylist">
          <li><a href="/book/1">遮天</a></li>
        </ul>
        """

        let elements = try analyzer.getElements(content: html, rule: "+@css:.librarylist li")

        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(try elements.first?.text(), "遮天")
    }

    func testExtractedProtocolRelativeChapterPathFallsBackToCurrentDirectory() {
        let resolved = AnalyzeUrl.postProcessExtractedURL(
            "//2200102.html",
            baseUrl: "https://www.178xs.cc/book_7716/"
        )

        XCTAssertEqual(resolved, "https://www.178xs.cc/book_7716/2200102.html")
    }

    func testExtractedPseudoAbsoluteChapterPathFallsBackToCurrentDirectory() {
        let resolved = AnalyzeUrl.postProcessExtractedURL(
            "https://2200102.html",
            baseUrl: "https://www.178xs.cc/book_7716/"
        )

        XCTAssertEqual(resolved, "https://www.178xs.cc/book_7716/2200102.html")
    }

    func testBookChapterParserUsesJSObjectChapterList() throws {
        let source = BookSource(
            bookSourceName: "JS对象目录测试源",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: #"@js:[{k:"第一章", v:"/c/1.html"}, {k:"第二章", v:"/c/2.html"}]"#,
                chapterName: "k",
                chapterUrl: "v"
            )
        )

        let result = try BookChapterParser.parse(
            html: "<html><body>目录</body></html>",
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/book/1/"
        )

        XCTAssertEqual(result.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.chapters.map(\.url), [
            "https://example.com/c/1.html",
            "https://example.com/c/2.html"
        ])
    }

    func testBookChapterParserSupportsPureJSHTMLChapterList() throws {
        let source = BookSource(
            bookSourceName: "HTML纯JS目录测试源",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: #"""
                @js:
                var list = [];
                list.push({k: "第一章", v: "/c/1.html"});
                list.push({k: "第二章", v: "/c/2.html"});
                list;
                """#,
                chapterName: "k",
                chapterUrl: "v"
            )
        )

        let result = try BookChapterParser.parse(
            html: "<html><body><div>目录</div></body></html>",
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/book/1/"
        )

        XCTAssertEqual(result.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.chapters.map(\.url), [
            "https://example.com/c/1.html",
            "https://example.com/c/2.html"
        ])
    }

    func testBookChapterParserRendersLiteralTemplateURLFromJSONItem() throws {
        let source = BookSource(
            bookSourceName: "JSON模板目录测试源",
            bookSourceUrl: "https://example.com",
            ruleToc: TocRule(
                chapterList: "$.data[*]",
                chapterName: "$.title",
                chapterUrl: #"https://example.com/chapter?bookId=@get:{bid}&order={{$.order}}"#
            )
        )
        let json = #"""
        {
          "data": [
            { "title": "第一章", "order": 1 },
            { "title": "第二章", "order": 2 }
          ]
        }
        """#
        let store = ParserVariableStore(writeScope: .book)
        store.put("bid", value: "42", scope: .book)

        let result = try BookChapterParser.parse(
            html: json,
            bookSource: source,
            bookUrl: "https://example.com/book/42",
            baseUrl: "https://example.com/toc/42",
            variableStore: store,
            bookName: "测试书",
            bookAuthor: "作者",
            tocUrl: "https://example.com/toc/42"
        )

        XCTAssertEqual(result.chapters.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.chapters.map(\.url), [
            "https://example.com/chapter?bookId=42&order=1",
            "https://example.com/chapter?bookId=42&order=2"
        ])
    }

    func testBookInfoParserSupportsRegexInitCaptureRules() throws {
        let source = BookSource(
            bookSourceName: "Regex详情捕获测试源",
            bookSourceUrl: "https://example.com",
            ruleBookInfo: BookInfoRule(
                init: #":<meta property=\"og:description\" content=\"([^\"]*)\"><meta property=\"og:image\" content=\"([^\"]*)\"><meta property=\"og:novel:category\" content=\"([^\"]*)\"><meta property=\"og:novel:author\" content=\"([^\"]*)\"><meta property=\"og:title\" content=\"([^\"]*)\"><meta property=\"og:novel:status\" content=\"([^\"]*)\"><meta property=\"og:novel:latest_chapter_name\" content=\"([^\"]*)\">"#,
                name: "$5",
                author: "$4",
                intro: "$1",
                kind: "$3,$6",
                lastChapter: "$7",
                coverUrl: "$2"
            )
        )
        let html = """
        <html><head>
        <meta property="og:description" content="九龙拉棺">
        <meta property="og:image" content="https://example.com/cover.jpg">
        <meta property="og:novel:category" content="玄幻">
        <meta property="og:novel:author" content="辰东">
        <meta property="og:title" content="遮天">
        <meta property="og:novel:status" content="连载">
        <meta property="og:novel:latest_chapter_name" content="第一章 星空中的青铜巨棺">
        </head><body></body></html>
        """

        let detail = try BookInfoParser.parse(
            html: html,
            bookSource: source,
            bookUrl: "https://example.com/book/1",
            baseUrl: "https://example.com/book/1",
            variableStore: ParserVariableStore(writeScope: .book)
        )

        XCTAssertEqual(detail.name, "遮天")
        XCTAssertEqual(detail.author, "辰东")
        XCTAssertEqual(detail.intro, "九龙拉棺")
        XCTAssertEqual(detail.kind, "玄幻,连载")
        XCTAssertEqual(detail.coverUrl, "https://example.com/cover.jpg")
        XCTAssertEqual(detail.lastChapter, "第一章 星空中的青铜巨棺")
    }

    func testBookInfoParserInitSupportsSingleLineSideEffectThenObjectExpression() throws {
        let source = BookSource(
            bookSourceName: "阿巴-init回归测试源",
            bookSourceUrl: "https://example.com/source",
            ruleBookInfo: BookInfoRule(
                init: "<js>var bookId=java.get('bid');var list={'turl':'https://example.com/toc?bookId='+bookId};list</js>",
                tocUrl: "turl"
            )
        )
        let store = ParserVariableStore(sourceValues: ["bid": "8241889"], writeScope: .book)

        let detail = try BookInfoParser.parse(
            html: "<html><body>detail</body></html>",
            bookSource: source,
            bookUrl: "https://example.com/book/8241889",
            baseUrl: "https://example.com/book/8241889",
            variableStore: store
        )

        XCTAssertEqual(detail.tocUrl, "https://example.com/toc?bookId=8241889")
    }
}
