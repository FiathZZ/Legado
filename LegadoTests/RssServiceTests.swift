import Foundation
import Network
import XCTest
@testable import Legado

final class RssServiceTests: XCTestCase {
    func testSortResolverSupportsStaticEntries() async throws {
        let source = RssSourceEntity(
            sourceUrl: "https://example.com/root/feed.xml",
            sourceName: "测试 RSS",
            sortUrl: "全部::/all.xml\n技术::https://example.com/tech.xml"
        )

        let sorts = try await RssSortResolver().resolveSorts(for: source)

        XCTAssertEqual(sorts.map(\.name), ["全部", "技术"])
        XCTAssertEqual(sorts.map(\.url), ["https://example.com/all.xml", "https://example.com/tech.xml"])
    }

    func testSortResolverSupportsJavaScriptEntries() async throws {
        let source = RssSourceEntity(
            sourceUrl: "https://example.com",
            sourceName: "测试 RSS",
            sortUrl: #"@js:'全部::' + result + '/feed&&推荐::/featured'"#
        )

        let sorts = try await RssSortResolver().resolveSorts(for: source)

        XCTAssertEqual(sorts.map(\.name), ["全部", "推荐"])
        XCTAssertEqual(sorts.map(\.url), ["https://example.com/feed", "https://example.com/featured"])
    }

    func testDefaultParserParsesStandardRSSFeed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel>
            <title>示例</title>
            <item>
              <title>第一篇</title>
              <link>https://example.com/articles/1</link>
              <description><![CDATA[<p>摘要</p>]]></description>
              <content:encoded><![CDATA[<div><img src="/cover.jpg" />正文内容</div>]]></content:encoded>
              <pubDate>Tue, 21 Apr 2026 09:00:00 GMT</pubDate>
            </item>
          </channel>
        </rss>
        """

        let articles = try RssDefaultParser().parse(
            data: Data(xml.utf8),
            source: RssSourceEntity(sourceUrl: "https://example.com/feed.xml", sourceName: "默认解析"),
            sortName: "全部"
        )

        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles.first?.title, "第一篇")
        XCTAssertEqual(articles.first?.link, "https://example.com/articles/1")
        XCTAssertEqual(articles.first?.content, #"<div><img src="/cover.jpg" />正文内容</div>"#)
        XCTAssertEqual(articles.first?.image, "https://example.com/cover.jpg")
    }

    func testDefaultParserRetriesMalformedRSSWithHTMLEntitiesAndBareAmpersands() throws {
        let xml = """
        <rss><channel><item>
          <title>阅读 &amp; RSS&nbsp;测试</title>
          <link>https://example.com/article?id=1&from=rss</link>
          <description><![CDATA[<p>原样保留 A & B</p>]]></description>
        </item></channel></rss>
        """

        let articles = try RssDefaultParser().parse(
            data: Data(xml.utf8),
            source: RssSourceEntity(sourceUrl: "https://example.com/feed.xml", sourceName: "兼容解析"),
            sortName: "全部"
        )

        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles.first?.title, "阅读 & RSS 测试")
        XCTAssertEqual(articles.first?.link, "https://example.com/article?id=1&from=rss")
        XCTAssertEqual(articles.first?.articleDescription, "<p>原样保留 A & B</p>")
    }

    func testFetchArticlesUsesRuleParserAndSupportsPageNextRule() async throws {
        let html = """
        <html><body>
          <article><h2>第一条</h2><a href="/article-1">查看</a></article>
          <article><h2>第二条</h2><a href="/article-2">查看</a></article>
        </body></html>
        """
        let server = try LocalHTTPTextServer(
            routes: [
                "/rss?page=1": .html(html),
                "/rss?page=2": .html(html)
            ]
        )
        try server.start()
        defer { server.stop() }

        let source = RssSourceEntity(
            sourceUrl: server.baseURL.absoluteString,
            sourceName: "规则 RSS",
            sortUrl: server.url(path: "/rss?page={page}").absoluteString,
            ruleArticles: "article",
            ruleNextPage: "PAGE",
            ruleTitle: "h2@text",
            ruleLink: "a@href"
        )

        let page = try await RssService().fetchArticles(
            from: source,
            sort: RssSortItem(name: "全部", url: source.sortUrl ?? source.sourceUrl),
            page: 2
        )

        XCTAssertEqual(page.articles.map(\.title), ["第一条", "第二条"])
        XCTAssertEqual(page.articles.map(\.link), [server.url(path: "/article-1").absoluteString, server.url(path: "/article-2").absoluteString])
        XCTAssertEqual(page.nextPageURL, server.url(path: "/rss?page=2").absoluteString)
    }

    func testFetchContentFallsBackToRuleContentWhenInlineFeedContentMissing() async throws {
        let articleHTML = """
        <html><body><div class="entry">这里是正文</div></body></html>
        """
        let server = try LocalHTTPTextServer(
            routes: [
                "/article-1": .html(articleHTML)
            ]
        )
        try server.start()
        defer { server.stop() }

        let source = RssSourceEntity(
            sourceUrl: server.baseURL.absoluteString,
            sourceName: "正文 RSS",
            ruleContent: ".entry@text"
        )
        let article = RssArticleSummary(
            origin: source.sourceUrl,
            sortName: "全部",
            title: "正文测试",
            link: server.url(path: "/article-1").absoluteString,
            pubDate: nil,
            articleDescription: nil,
            content: nil,
            image: nil,
            variableValues: [:]
        )

        let result = try await RssService().fetchContent(for: article, source: source)

        XCTAssertEqual(result.content, "这里是正文")
        XCTAssertFalse(result.shouldFallbackToWebView)
    }
}

private final class LocalHTTPTextServer {
    struct Route {
        let statusCode: Int
        let body: String
        let headers: [String: String]

        static func html(_ body: String, statusCode: Int = 200, headers: [String: String] = [:]) -> Route {
            Route(
                statusCode: statusCode,
                body: body,
                headers: headers.merging(["Content-Type": "text/html; charset=utf-8"]) { current, _ in current }
            )
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Legado.tests.LocalHTTPTextServer")
    private let routes: [String: Route]

    init(routes: [String: Route]) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.routes = routes
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    func url(path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!
    }

    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                semaphore.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        XCTAssertEqual(semaphore.wait(timeout: .now() + 3), .success)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let route = self.routes[path] ?? Route(statusCode: 404, body: "Not Found", headers: ["Content-Type": "text/plain; charset=utf-8"])
            let response = self.makeResponse(route: route)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func makeResponse(route: Route) -> Data {
        let bodyData = Data(route.body.utf8)
        var headerLines = [
            "HTTP/1.1 \(route.statusCode) OK",
            "Content-Length: \(bodyData.count)"
        ]
        headerLines.append(contentsOf: route.headers.map { "\($0.key): \($0.value)" })
        headerLines.append("")
        headerLines.append("")

        var response = Data(headerLines.joined(separator: "\r\n").utf8)
        response.append(bodyData)
        return response
    }
}
