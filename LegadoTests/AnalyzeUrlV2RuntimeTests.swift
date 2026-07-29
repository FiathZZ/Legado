import XCTest
@testable import Legado

final class AnalyzeUrlV2RuntimeTests: XCTestCase {

    func testPureJavaScriptRuleResolvesIntoRequestURL() {
        let runtime = AnalyzeUrlV2(
            rule: "@js:'/search?kw=' + key + '&page=' + page",
            key: "遮天",
            page: 2,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(runtime.method, .get)
        XCTAssertEqual(runtime.traceState.urlPart, "/search?kw=遮天&page=2")
        XCTAssertEqual(runtime.urlString, "https://example.com/search?kw=%E9%81%AE%E5%A4%A9&page=2")
    }

    func testEmbeddedJavaScriptUsesAndroidResultPipelining() {
        let runtime = AnalyzeUrlV2(
            rule: "<js>'/search?kw=' + key</js>@result&page=<1,2>",
            key: "凡人修仙传",
            page: 2,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(runtime.traceState.afterEmbeddedJavaScript, "/search?kw=凡人修仙传&page=<1,2>")
        XCTAssertEqual(runtime.traceState.afterTemplateExpansion, "/search?kw=凡人修仙传&page=2")
        XCTAssertEqual(runtime.urlString, "https://example.com/search?kw=%E5%87%A1%E4%BA%BA%E4%BF%AE%E4%BB%99%E4%BC%A0&page=2")
    }

    func testTemplateAndPagePatternFollowAndroidOrder() {
        let runtime = AnalyzeUrlV2(
            rule: "https://example.com/<first,second>?tab=<a,b>&keyword={{key}}&offset={{page+1}}",
            key: "大主宰",
            page: 2,
            baseUrl: "https://fallback.example.com"
        )

        XCTAssertEqual(runtime.traceState.afterTemplateExpansion, "https://example.com/second?tab=b&keyword=大主宰&offset=3")
        XCTAssertEqual(runtime.urlString, "https://example.com/second?tab=b&keyword=%E5%A4%A7%E4%B8%BB%E5%AE%B0&offset=3")
    }

    func testJsonOptionsProduceAndroidStyleDescriptor() {
        let runtime = AnalyzeUrlV2(
            rule: "/search,{\"method\":\"POST\",\"headers\":{\"X-Test\":\"1\"},\"body\":\"keyword={{key}}\",\"retry\":2,\"webView\":true,\"webJs\":\"document.title\",\"sourceRegex\":\"chapter\",\"webViewDelayTime\":600,\"charset\":\"gbk\"}",
            key: "斗破苍穹",
            page: 1,
            baseUrl: "https://example.com",
            headerString: "{\"User-Agent\":\"UA\"}"
        )
        let request = runtime.makeRequest(
            timeout: 30,
            transportPreference: .preferThirdParty,
            enableCookieJar: true
        )
        let descriptor = runtime.makeDescriptor(
            request: request,
            transportPreference: .preferThirdParty,
            cookieJarEnabled: true,
            followRedirects: true
        )

        XCTAssertEqual(runtime.method, .post)
        XCTAssertEqual(runtime.headers["User-Agent"], "UA")
        XCTAssertEqual(runtime.headers["X-Test"], "1")
        XCTAssertEqual(runtime.retryCount, 2)
        XCTAssertTrue(runtime.webView)
        XCTAssertEqual(runtime.webJs, "document.title")
        XCTAssertEqual(runtime.sourceRegex, "chapter")
        XCTAssertEqual(runtime.webViewDelayTime, 600)
        XCTAssertEqual(runtime.charset.uppercased(), "GBK")
        XCTAssertEqual(String(data: request.body ?? Data(), encoding: .ascii), "keyword=%B6%B7%C6%C6%B2%D4%F1%B7")
        XCTAssertEqual(descriptor.runtimeTrace?.urlPart, "/search")
        XCTAssertTrue(descriptor.runtimeTrace?.appliedOptions.contains("method") == true)
        XCTAssertTrue(descriptor.runtimeTrace?.appliedOptions.contains("webView") == true)
        XCTAssertEqual(descriptor.runtimeTrace?.resolvedURL, "https://example.com/search")
    }

    func testPureJavaScriptRuleDoesNotSilentlyFallBackToContextURLWhenJSKeepsDefaultURL() {
        let runtime = AnalyzeUrlV2(
            rule: """
            @js:
            java.ajax(source.key);
            url;
            """,
            key: "遮天",
            page: 1,
            baseUrl: "http://www.apap.net",
            source: BookSource(
                bookSourceName: "H4纯JS误回退测试源",
                bookSourceUrl: "http://www.apap.net",
                searchUrl: "/search"
            )
        )

        XCTAssertTrue(runtime.traceState.afterEmbeddedJavaScript.hasPrefix("@js:"))
        XCTAssertEqual(runtime.urlString, "http://www.apap.net/@js:")
    }

    func testPureJavaScriptRuleKeepsGeneratedQueryParametersAndOptions() {
        let runtime = AnalyzeUrlV2(
            rule: """
            @js:
            '/search?token=' + java.encodeURI('a+b=c') + '&keyword=' + key + ',{"method":"POST","body":"page=' + page + '"}'
            """,
            key: "遮天",
            page: 2,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(runtime.traceState.urlPart, "/search?token=a%2Bb%3Dc&keyword=遮天")
        XCTAssertEqual(runtime.urlString, "https://example.com/search?token=a%2Bb%3Dc&keyword=%E9%81%AE%E5%A4%A9")
        XCTAssertEqual(runtime.method, .post)
        XCTAssertEqual(runtime.body, "page=2")
    }
}
