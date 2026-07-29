import XCTest
@testable import Legado

final class ExploreCategoryParserTests: XCTestCase {
    func testGetExploreCategoriesParsesMultilineDefinitions() {
        let source = makeSource(
            exploreUrl: """
            男生::https://example.com/boys
            女生::https://example.com/girls
            """
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let categories = webBook.getExploreCategories()

        XCTAssertEqual(categoryPairs(from: categories), [
            "男生::https://example.com/boys",
            "女生::https://example.com/girls"
        ])
    }

    func testGetExploreCategoriesParsesJSONArrayDefinitions() {
        let source = makeSource(
            exploreUrl: #"""
            [
              { "title": "玄幻", "url": "https://example.com/xuanhuan" },
              { "title": "排行", "url": "https://example.com/rank", "style": { "span": 2 } }
            ]
            """#
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let categories = webBook.getExploreCategories()

        XCTAssertEqual(categoryPairs(from: categories), [
            "玄幻::https://example.com/xuanhuan",
            "排行::https://example.com/rank"
        ])
    }

    func testGetExploreCategoriesExecutesJavaScriptMenuWithSourceVariables() {
        let source = BookSource(
            bookSourceName: "动态发现源",
            bookSourceUrl: "https://example.com/source",
            enabled: true,
            enabledExplore: true,
            jsLib: """
            function ensureFilters() {
                if (!source.getVariable()) {
                    source.setVariable(JSON.stringify({ sort: '玄幻' }));
                }
            }
            """,
            exploreUrl: """
            @js:
            ensureFilters();
            infoMap.save();
            JSON.stringify([
                { title: '月票榜', url: '/rank/month?page={{page}}' },
                { title: '筛选标题', url: null }
            ]);
            """
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        XCTAssertEqual(categoryPairs(from: webBook.getExploreCategories()), [
            "月票榜::/rank/month?page={{page}}"
        ])
    }

    func testDynamicExploreMenuSelectionExecutesSourceAction() throws {
        let source = BookSource(
            bookSourceName: "动态筛选源",
            bookSourceUrl: "https://example.com/filter-source",
            enabled: true,
            enabledExplore: true,
            jsLib: """
            function setOrder() {
                var values = JSON.parse(source.getVariable() || '{}');
                values.order = infoMap['排序'];
                source.setVariable(JSON.stringify(values));
                java.refreshExplore();
            }
            """,
            exploreUrl: """
            @js:
            var values = JSON.parse(source.getVariable() || '{}');
            JSON.stringify([
                { title: '排序', type: 'select', chars: ['人气', '时间'], default: '人气', action: 'setOrder()' },
                { title: values.order || '人气', url: '/category?page={{page}}' }
            ]);
            """
        )
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        XCTAssertEqual(webBook.getExploreMenu().first?.title, "排序")
        try webBook.applyExploreMenuAction("setOrder()", infoMap: ["排序": "时间"])

        XCTAssertEqual(webBook.getExploreCategories().first?.name, "时间")
    }

    /// Regression fixture for the supplied `🎆起点中文网(按钮筛选)` source.
    ///
    /// The source uses a fragment-bearing source URL, writes its selected values as one raw
    /// source variable JSON string, and returns category URLs that still contain rule templates.
    /// Keep those three details together: testing only the menu JSON misses the request URL that
    /// the Explore result screen actually sends.
    func testQidianDynamicFilterMenuKeepsSelectionAndBuildsUsableCategoryURL() throws {
        let source = qidianFilterSource()
        let webBook = WebBook(bookSource: source)
        defer { webBook.shutdown() }

        let initialMenu = webBook.getExploreMenu()
        let filters = initialMenu.filter(\.isSelection)
        XCTAssertEqual(filters.map(\.title), ["排序", "字数", "状态", "分类"])
        XCTAssertEqual(filters.first?.choices, ["人气", "时间", "字数", "收藏", "推荐", "点击"])

        let orderFilter = try XCTUnwrap(filters.first { $0.title == "排序" })
        try webBook.applyExploreMenuAction(
            try XCTUnwrap(orderFilter.action),
            infoMap: ["排序": "时间"]
        )

        let selectedMenu = webBook.getExploreMenu()
        let category = try XCTUnwrap(selectedMenu.first { $0.title == "🎆玄幻🎆" })
        let categoryURL = try XCTUnwrap(category.url)
        XCTAssertTrue(categoryURL.contains("catId=21"))
        XCTAssertTrue(categoryURL.contains("orderBy=4"))

        let request = AnalyzeUrlV2(
            rule: categoryURL,
            page: 1,
            baseUrl: source.bookSourceUrl,
            source: source,
            variableStore: ParserVariableStore(writeScope: .source)
        )
        XCTAssertEqual(
            request.urlString,
            "https://m.qidian.com/majax/category/list?catId=21&size=&isfinish=&gender=male&orderBy=4&pageNum=1&_csrfToken="
        )
        XCTAssertFalse(request.urlString.contains("#按钮筛选"))
        XCTAssertFalse(request.urlString.contains("{{"))
    }

    func testExploreBootstrapsMissingCookieTemplateBeforeRequestingQidianStyleCategory() async throws {
        let source = BookSource(
            bookSourceName: "起点 cookie 预热回归源",
            bookSourceUrl: "https://fixture.qidian.test#按钮筛选",
            enabled: true,
            enabledExplore: true,
            enabledCookieJar: true,
            searchUrl: "/so/{{key}}.html?pageNum={{page}}",
            ruleExplore: ExploreRule(
                bookList: "$.data.records",
                name: "$.bName",
                author: "$.bAuth",
                bookUrl: "https://fixture.qidian.test/book/{{$.bid}}"
            )
        )
        let sourceDomain = "fixture.qidian.test"
        CookieManager.shared.removeCookie(domain: sourceDomain)
        defer { CookieManager.shared.removeCookie(domain: sourceDomain) }

        let requestRecorder = ExploreRequestRecorder()
        let executor = RequestExecutorV2(
            httpClient: HTTPClient(),
            cookieJarEnabled: true,
            httpSender: { request, _ in
                requestRecorder.record(request.url)
                let responseURL = URL(string: request.url)!
                if request.url == "https://fixture.qidian.test" {
                    return HTTPResponse(
                        data: Data("<html>source root</html>".utf8),
                        statusCode: 200,
                        headers: ["Content-Type": "text/html"],
                        url: responseURL,
                        requestURL: responseURL,
                        message: "OK"
                    )
                }

                if request.url == "https://fixture.qidian.test/so/.html?pageNum=1" {
                    CookieManager.shared.setCookie(
                        name: "_csrfToken",
                        value: "fixture-token",
                        domain: sourceDomain
                    )
                    return HTTPResponse(
                        data: Data("<html>search bootstrap</html>".utf8),
                        statusCode: 404,
                        headers: ["Content-Type": "text/html"],
                        url: responseURL,
                        requestURL: responseURL,
                        message: "Not Found"
                    )
                }

                let isAuthorizedCategoryRequest = request.url.contains("_csrfToken=fixture-token")
                let body = isAuthorizedCategoryRequest
                    ? #"{"data":{"records":[{"bid":"1001","bName":"起点测试书","bAuth":"测试作者"}]}}"#
                    : #"{"code":1,"msg":"失败"}"#
                return HTTPResponse(
                    data: Data(body.utf8),
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    url: responseURL,
                    requestURL: responseURL,
                    message: "OK"
                )
            }
        )
        let webBook = WebBookV2(bookSource: source, requestExecutor: executor)
        defer { webBook.shutdown() }

        let books = try await webBook.getExploreList(
            url: "majax/category/list?catId=21&pageNum={{page}}&_csrfToken={{cookie.getKey(\"https://fixture.qidian.test\",\"_csrfToken\")}}"
        )

        XCTAssertEqual(requestRecorder.urls, [
            "https://fixture.qidian.test",
            "https://fixture.qidian.test/so/.html?pageNum=1",
            "https://fixture.qidian.test/majax/category/list?catId=21&pageNum=1&_csrfToken=fixture-token"
        ])
        XCTAssertEqual(books.map(\.name), ["起点测试书"])
        XCTAssertEqual(books.first?.bookUrl, "https://fixture.qidian.test/book/1001")
    }

    @MainActor
    func testExploreViewModelBuildsItemsWithoutEagerlyParsingCategories() throws {
        let source = makeSource(
            name: "发现源",
            group: "精选",
            exploreUrl: #"""
            [
              { "title": "热榜", "url": "https://example.com/hot" },
              { "title": "新书", "url": "https://example.com/new" }
            ]
            """#
        )
        let viewModel = ExploreViewModel()
        viewModel.updateSources([source])

        let section = try XCTUnwrap(viewModel.sections.first)
        let item = try XCTUnwrap(section.items.first)

        XCTAssertEqual(section.title, "精选")
        XCTAssertEqual(item.source.bookSourceName, "发现源")
        XCTAssertTrue(item.hasExploreRule)
    }

    @MainActor
    func testExploreViewModelShowsEverySourceWithoutExploreRule() throws {
        let source = BookSource(
            bookSourceName: "仅搜索书源",
            bookSourceUrl: "https://example.com/search-only",
            enabled: false,
            enabledExplore: false,
            exploreUrl: nil
        )
        let viewModel = ExploreViewModel()

        viewModel.updateSources([source])

        let item = try XCTUnwrap(viewModel.sections.first?.items.first)
        XCTAssertEqual(item.source.bookSourceName, "仅搜索书源")
        XCTAssertFalse(item.hasExploreRule)
        XCTAssertEqual(item.statusText, "书源已停用")
    }

    private func makeSource(
        name: String = "测试书源",
        group: String? = nil,
        exploreUrl: String
    ) -> BookSource {
        BookSource(
            bookSourceName: name,
            bookSourceUrl: "https://example.com/source",
            bookSourceGroup: group,
            enabled: true,
            enabledExplore: true,
            exploreUrl: exploreUrl
        )
    }

    private func categoryPairs(from categories: [(name: String, url: String)]) -> [String] {
        categories.map { "\($0.name)::\($0.url)" }
    }

    private func qidianFilterSource() -> BookSource {
        BookSource(
            bookSourceName: "🎆起点中文网(按钮筛选)",
            bookSourceUrl: "https://m.qidian.com#按钮筛选",
            enabled: true,
            enabledExplore: true,
            jsLib: """
            function csh() {
                var original = { orderBy: '人气', isfinish: '连载', size: '全部', sort: '🎆玄幻🎆' };
                try {
                    if (JSON.parse(source.getVariable()) == null) { error; }
                } catch (e) {
                    source.setVariable(JSON.stringify(original, null, 2));
                }
            }
            function Get(key) {
                return JSON.parse(source.getVariable())[key];
            }
            function show(value, key) {
                var data = JSON.parse(source.getVariable());
                data[key] = value;
                source.setVariable(JSON.stringify(data, null, 2));
                java.refreshExplore();
            }
            function createFilter(title, chars, defaultVal, paramKey, size) {
                return {
                    title: title,
                    type: 'select',
                    chars: chars,
                    default: defaultVal,
                    action: `show(infoMap['${title}'],'${paramKey}')`,
                    style: { layout_flexGrow: 1, layout_flexBasisPercent: size }
                };
            }
            """,
            exploreUrl: """
            @js:
            csh();
            var result = [];
            function push(title, url, size) {
                result.push({ title: title, url: url, style: { layout_flexGrow: 1, layout_flexBasisPercent: size } });
            }
            result.push(createFilter('排序', ['人气', '时间', '字数', '收藏', '推荐', '点击'], '人气', 'orderBy', 0.33));
            result.push(createFilter('字数', ['全部', '30万以下'], '全部', 'size', 0.33));
            result.push(createFilter('状态', ['连载', '完本'], '连载', 'isfinish', 0.33));
            result.push(createFilter('分类', ['🎆玄幻🎆', '🎆奇幻🎆'], '全部', 'sort', 0.33));
            var orderBy = { '人气': '', '时间': '4', '字数': '3', '收藏': '11', '推荐': '9', '点击': '1' };
            var size = { '全部': '', '30万以下': '1' };
            var isfinish = { '连载': '', '完本': '1' };
            var types = { '🎆玄幻🎆': 'catId=21', '🎆奇幻🎆': 'catId=1' };
            var sort = Get('sort');
            infoMap.save();
            Object.keys(types).forEach(function(title) {
                push(title, `majax/category/list?${types[title]}&size=${size[Get('size')]}&isfinish=${isfinish[Get('isfinish')]}&gender=male&orderBy=${orderBy[Get('orderBy')]}&pageNum={{page}}&_csrfToken={{cookie.getKey(\"https://qidian.com\",\"_csrfToken\")}}`, 1);
            });
            JSON.stringify(result);
            """
        )
    }

    private final class ExploreRequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedURLs: [String] = []

        var urls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedURLs
        }

        func record(_ url: String) {
            lock.lock()
            recordedURLs.append(url)
            lock.unlock()
        }
    }
}
