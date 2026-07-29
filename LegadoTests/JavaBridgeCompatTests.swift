import XCTest
import Foundation
import GCDWebServer
@testable import Legado

final class JavaBridgeCompatTests: XCTestCase {
    override func tearDownWithError() throws {
        CookieManager.shared.clearCookies(domain: "example.com")
        CookieManager.shared.clearCookies(domain: "sub.example.com")
    }

    func testMD5Encode16UsesMiddleSixteenCharacters() {
        let bridge = makeBridge()
        let full = bridge.md5Encode("test")

        XCTAssertEqual(bridge.md5Encode16("test"), String(full.dropFirst(8).prefix(16)))
    }

    func testDigestBase64StrMatchesHexDigestPayload() throws {
        let bridge = makeBridge()
        let hex = bridge.digestHex("test", "MD5")
        let base64 = bridge.digestBase64Str("test", "MD5")

        XCTAssertEqual(base64, try data(fromHex: hex).base64EncodedString())
    }

    func testHMacBase64MatchesHexDigestPayload() throws {
        let bridge = makeBridge()
        let hex = bridge.HMacHex("payload", "SHA256", "secret")
        let base64 = bridge.HMacBase64("payload", "SHA256", "secret")

        XCTAssertEqual(base64, try data(fromHex: hex).base64EncodedString())
    }

    func testHMacHexAcceptsAndroidStyleHmacAlgorithmNames() {
        let bridge = makeBridge()

        XCTAssertEqual(
            bridge.HMacHex("payload", "HmacSHA256", "secret"),
            bridge.HMacHex("payload", "SHA256", "secret")
        )
        XCTAssertEqual(
            bridge.HMacHex("payload", "HmacMD5", "secret"),
            bridge.HMacHex("payload", "MD5", "secret")
        )
    }

    func testByteArrayRoundTripSupportsUTF8AndGBK() throws {
        let bridge = makeBridge()

        let utf8Bytes = bridge.strToBytes("hello")
        XCTAssertEqual(bridge.bytesToStr(utf8Bytes), "hello")

        let gbkBytes = bridge.strToBytes("中文测试", "GBK")
        XCTAssertEqual(bridge.bytesToStr(gbkBytes, "GBK"), "中文测试")
    }

    func testDecodeByteArrayHelpersAndCharsetBase64Decode() throws {
        let bridge = makeBridge()
        let gbkData = try gb18030Data(for: "阶段八")
        let gbkBase64 = gbkData.base64EncodedString()

        let decodedBytes = bridge.base64DecodeToByteArray("aGVsbG8=")
        XCTAssertEqual(bridge.bytesToStr(decodedBytes), "hello")

        let hexBytes = bridge.hexDecodeToByteArray("68656c6c6f")
        XCTAssertEqual(bridge.bytesToStr(hexBytes), "hello")

        XCTAssertEqual(bridge.base64Decode(gbkBase64, "GBK"), "阶段八")
    }

    func testGetCookieOverloadExtractsSpecificValue() {
        CookieManager.shared.parseCookieString("auth=1; token=xyz", domain: "example.com")
        let bridge = makeBridge()

        XCTAssertEqual(bridge.getCookie("https://example.com", "token"), "xyz")
        XCTAssertEqual(bridge.getCookie("example.com", "auth"), "1")
        XCTAssertEqual(bridge.getCookie("example.com", "missing"), "")
    }

    func testBookSourceEnabledCookieJarDefaultsToTrueWhenMissing() throws {
        let json = """
        {
          "bookSourceName": "测试源",
          "bookSourceUrl": "https://example.com",
          "searchUrl": "/search"
        }
        """

        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        XCTAssertTrue(source.enabledCookieJar)
    }

    func testBookSourceEnabledCookieJarRespectsExplicitFalse() throws {
        let json = """
        {
          "bookSourceName": "测试源",
          "bookSourceUrl": "https://example.com",
          "enabledCookieJar": false,
          "searchUrl": "/search"
        }
        """

        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        XCTAssertFalse(source.enabledCookieJar)
    }

    func testHTMLFormatKeepsImageTag() {
        let bridge = makeBridge()
        let html = "<div>Hello&nbsp;<img src='cover.jpg'> <b>World</b></div>"

        XCTAssertEqual(bridge.htmlFormat(html), "Hello <img src='cover.jpg'> World")
    }

    func testToURLParsesAbsoluteAndRelativeURLs() {
        let bridge = makeBridge()

        let absolute = bridge.toURL("https://example.com:8080/path?q=1#frag")
        XCTAssertEqual(absolute["protocol"] as? String, "https")
        XCTAssertEqual(absolute["host"] as? String, "example.com")
        XCTAssertEqual(absolute["path"] as? String, "/path")
        XCTAssertEqual(absolute["query"] as? String, "q=1")
        XCTAssertEqual(absolute["ref"] as? String, "frag")

        let relative = bridge.toURL("../next?chapter=2#part", "https://example.com/books/1/index.html")
        XCTAssertEqual(relative["protocol"] as? String, "https")
        XCTAssertEqual(relative["host"] as? String, "example.com")
        XCTAssertEqual(relative["path"] as? String, "/books/next")
        XCTAssertEqual(relative["query"] as? String, "chapter=2")
        XCTAssertEqual(relative["ref"] as? String, "part")
    }

    func testGetRequestURLNormalizesRootURLWithTrailingSlash() {
        let bridge = JavaBridge(
            baseUrl: "https://example.com",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com",
            requestHeaders: [:]
        )

        XCTAssertEqual(bridge.getRequestURL(), "https://example.com/")
    }

    func testParserJSContextSeesNormalizedRequestURL() throws {
        let parser = JavaScriptParser(
            baseUrl: "https://example.com",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com",
            requestHeaders: [:]
        )

        let result = try parser.evaluate(
            script: "String(java.getRequestURL())"
        )

        XCTAssertEqual(result, "https://example.com/")
    }

    func testJavaGetElementReturnsSingleMatchedValue() throws {
        let parser = JavaScriptParser(
            baseUrl: "https://qubook.org/booknv/111305.html",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://qubook.org/booknv/111305.html",
            requestHeaders: [:]
        )
        parser.updateContextContent("""
        <html><body><div class="pagination"><a><b></b><b>共3页</b></a><a><b>尾页</b></a></div></body></html>
        """)

        let result = try parser.evaluate(
            script: "String(java.getElement('@@class.pagination@a.0@b.1'))"
        )

        XCTAssertEqual(result, "共3页")
    }

    func testOrgJsoupCompatSupportsSelectAndRemove() throws {
        let parser = makeParser()
        let result = try parser.evaluate(
            script: """
            (function() {
                var doc = org.jsoup.Jsoup.parse('<div><input name="_token" value="abc"><div class="line">keep</div><div class="line hide">drop</div></div>');
                var token = doc.select('input[name=_token]').attr('value');
                doc.select('.hide').remove();
                return JSON.stringify({
                    token: token,
                    lineText: doc.select('.line').text(),
                    html: doc.html()
                });
            })()
            """
        )

        let payload = try XCTUnwrap(result.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])

        XCTAssertEqual(parsed["token"], "abc")
        XCTAssertEqual(parsed["lineText"], "keep")
        let normalizedHTML = try XCTUnwrap(parsed["html"]).replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        XCTAssertEqual(
            normalizedHTML,
            #"<html><head></head><body><div><inputname="_token"value="abc"/><divclass="line">keep</div></div></body></html>"#
        )
    }

    func testPackagesOrgJsoupAliasAndImportClassWork() throws {
        let parser = makeParser()
        let result = try parser.evaluate(
            script: """
            (function() {
                importClass(org.jsoup.Jsoup);
                var doc = Packages.org.jsoup.Jsoup.parse('<div><script>window.flag = 1;</script><a href="/next">Next</a></div>');
                return JSON.stringify({
                    href: doc.select('a').attr('href'),
                    data: doc.select('script').data()
                });
            })()
            """
        )

        XCTAssertEqual(result, #"{"href":"/next","data":"window.flag = 1;"}"#)
    }

    func testAjaxBridgeCanFetchSynchronouslyWhenParserRunsOnMainThread() throws {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/token",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                html: #"<input name="_token" value="abc123">"#
            )!
        }
        try server.start(options: [
            GCDWebServerOption_Port: 21330,
            GCDWebServerOption_BindToLocalhost: true,
            GCDWebServerOption_AutomaticallySuspendInBackground: false
        ])
        defer { server.stop() }
        let baseURL = try XCTUnwrap(server.serverURL)

        let parser = JavaScriptParser(
            baseUrl: baseURL.absoluteString,
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: baseURL.absoluteString,
            requestHeaders: [:]
        )

        let result = try parser.evaluate(
            script: """
            (function() {
                var html = java.ajax('\(baseURL.appendingPathComponent("token").absoluteString)');
                return html.indexOf('abc123') >= 0 ? 'ok' : html;
            })()
            """
        )

        XCTAssertEqual(result, "ok")
    }

    func testConnectRawRequestURLUsesFinalRedirectedURL() throws {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/redirect",
            request: GCDWebServerRequest.self
        ) { request in
            let response = GCDWebServerResponse(statusCode: 302)
            response.setValue(
                request.url.deletingLastPathComponent().appendingPathComponent("final").absoluteString,
                forAdditionalHeader: "Location"
            )
            return response
        }
        server.addHandler(
            forMethod: "GET",
            path: "/final",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(text: "ok")!
        }
        try server.start(options: [
            GCDWebServerOption_Port: 21331,
            GCDWebServerOption_BindToLocalhost: true,
            GCDWebServerOption_AutomaticallySuspendInBackground: false
        ])
        defer { server.stop() }
        let baseURL = try XCTUnwrap(server.serverURL)
        let redirectURL = baseURL.appendingPathComponent("redirect").absoluteString
        let finalURL = baseURL.appendingPathComponent("final").absoluteString

        let parser = JavaScriptParser(
            baseUrl: baseURL.absoluteString,
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: baseURL.absoluteString,
            requestHeaders: [:]
        )

        let result = try parser.evaluate(
            script: """
            (function() {
                return java.connect('\(redirectURL)').raw().request().url();
            })()
            """
        )

        XCTAssertEqual(result, finalURL)
    }

    func testHTTPClientRewritesPOSTToGETAcross301Redirect() async throws {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "POST",
            path: "/redirect",
            request: GCDWebServerDataRequest.self
        ) { request in
            let response = GCDWebServerResponse(statusCode: 301)
            response.setValue(
                request.url.deletingLastPathComponent().appendingPathComponent("final").absoluteString,
                forAdditionalHeader: "Location"
            )
            return response
        }
        server.addHandler(
            forMethod: "GET",
            path: "/final",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(text: "GET")!
        }
        server.addHandler(
            forMethod: "POST",
            path: "/final",
            request: GCDWebServerDataRequest.self
        ) { request in
            let bodyRequest = request as? GCDWebServerDataRequest
            let body = bodyRequest.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            return GCDWebServerDataResponse(text: "POST|\(body)")!
        }
        try server.start(options: [
            GCDWebServerOption_Port: 21332,
            GCDWebServerOption_BindToLocalhost: true,
            GCDWebServerOption_AutomaticallySuspendInBackground: false
        ])
        defer { server.stop() }
        let baseURL = try XCTUnwrap(server.serverURL)

        let response = try await HTTPClient().send(
            request: HTTPRequest(
                url: baseURL.appendingPathComponent("redirect").absoluteString,
                method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data("query=%D5%DA%CC%EC".utf8),
                timeout: 10,
                followRedirects: true
            )
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.text, "GET")
    }

    func testHTTPClientPreservesPOSTBodyAcross307Redirect() async throws {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "POST",
            path: "/redirect307",
            request: GCDWebServerDataRequest.self
        ) { request in
            let response = GCDWebServerResponse(statusCode: 307)
            response.setValue(
                request.url.deletingLastPathComponent().appendingPathComponent("final307").absoluteString,
                forAdditionalHeader: "Location"
            )
            return response
        }
        server.addHandler(
            forMethod: "POST",
            path: "/final307",
            request: GCDWebServerDataRequest.self
        ) { request in
            let bodyRequest = request as? GCDWebServerDataRequest
            let body = bodyRequest.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            return GCDWebServerDataResponse(text: "POST|\(body)")!
        }
        try server.start(options: [
            GCDWebServerOption_Port: 21333,
            GCDWebServerOption_BindToLocalhost: true,
            GCDWebServerOption_AutomaticallySuspendInBackground: false
        ])
        defer { server.stop() }
        let baseURL = try XCTUnwrap(server.serverURL)

        let response = try await HTTPClient().send(
            request: HTTPRequest(
                url: baseURL.appendingPathComponent("redirect307").absoluteString,
                method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data("query=%D5%DA%CC%EC".utf8),
                timeout: 10,
                followRedirects: true
            )
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.text, "POST|query=%D5%DA%CC%EC")
    }

    func testGetWebViewUAReturnsUsableString() async {
        let bridge = makeBridge()
        let userAgent = await callOnBackground {
            bridge.getWebViewUA()
        }

        XCTAssertFalse(userAgent.isEmpty)
        XCTAssertTrue(userAgent.contains("Mozilla"))
    }

    func testWebViewGetOverrideUrlInterceptsMatchingRedirect() async {
        let bridge = makeBridge()
        let html = "<html><body>verification</body></html>"
        let redirectedURL = await callOnBackground {
            bridge.webViewGetOverrideUrl(
                html,
                "https://example.com/verify",
                "window.location.href = 'https://example.com/pass?token=1';",
                #"https://example\.com/pass\?token=1"#
            )
        }

        XCTAssertEqual(redirectedURL, "https://example.com/pass?token=1")
    }

    func testCompatMethodsAreCallableFromParserJSContext() throws {
        let parser = makeParser()
        let result = try parser.evaluate(
            script: """
            (function() {
                var u = java.toURL('https://example.com:8080/path?q=1#frag');
                var bytes = java.strToBytes('AZ');
                return JSON.stringify({
                    protocol: u.protocol,
                    host: u.host,
                    path: u.path,
                    query: u.query,
                    ref: u.ref,
                    bytes: bytes.join(',')
                });
            })()
            """
        )

        XCTAssertEqual(
            result,
            #"{"protocol":"https","host":"example.com","path":"/path","query":"q=1","ref":"frag","bytes":"65,90"}"#
        )
    }

    func testRSAPublicKeyDecryptStrSupportsRawBlockTransform() throws {
        let parser = makeParser()
        let result = try parser.evaluate(
            script: """
            (function() {
                var body = "ASDE5778NcXx7aJ7rSOlAHLZR65LUhPIgWu+jhp4bzc5wEKigUEd4zpDppRMF/mOONVtiVZ5xU7XiFpM2CgyZUCOkyXd3Ic5ClCJQBvRGuB2pBWhnNAxo5JY5PV+p0zMfCXqrMM4RlyfbjRRK8Gafr/d4qsTzQH/4c7sc6DT6QvBka5DeWluM86+RLL9Iu9Sqwjn7vz+m7HnDA5hdrbvEuA7P1lakLTAabOqurp7qSBb8tI96Wij1E7fNJjENPg6QDkOVFC4uWD5CdGVxNu6u80JoewKyesxUrXUFs+kHew82zsVWAkteKTNOvcHJZzyYPIa9Pr18QidoqAERrYJ8w==";
                var jmkey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjYFYoMbA0uW8by6+YIghxxsvibS9YW4yKVSulykAzZZwZ/+dNTkZ4inY7Pj08aksm6RCGKS6+WfvVQo/EdkcS5p2LY2/76qVzapyHsyQf/Pud6ATPKnwxNt/DaqjL35Z9K0NI/RF9x732RdIEOTKXppfRdzCa/1Ctm/5ZFilY8UmZsppkjDd3XkuPr3n3wVC8WFvqmdJ1N55prRlnaRaO+mIOXo3OsOzIxE5EdcE0TLT9OFZ3Wlbi3E0iI0v/ZsrWoL57YvLwo7BsARp7BansDCx8NZg6ObGQN/tNrE/nKqQTXeJjnFWXdLfhI7xivPPphkj5fNpiufIsIUEd7eXBwIDAQAB";
                var text = java.createAsymmetricCrypto("RSA")
                    .setPublicKey(java.base64DecodeToByteArray(jmkey))
                    .decryptStr(java.base64DecodeToByteArray(body));
                return text.indexOf("夜间的泰山") >= 0 ? "ok" : text.substring(0, 32);
            })()
            """
        )

        XCTAssertEqual(result, "ok")
    }

    func testAnalyzeURLPageChoicePatternMatchesAndroidBehavior() {
        let page1 = AnalyzeUrl(
            rule: "https://www.mingzw.net/mzwlist/{{key}}<,_{{page}}>.html",
            key: "遮天",
            page: 1,
            baseUrl: "https://www.mingzw.net"
        )
        let page2 = AnalyzeUrl(
            rule: "https://www.mingzw.net/mzwlist/{{key}}<,_{{page}}>.html",
            key: "遮天",
            page: 2,
            baseUrl: "https://www.mingzw.net"
        )

        XCTAssertEqual(page1.urlString, "https://www.mingzw.net/mzwlist/%E9%81%AE%E5%A4%A9.html")
        XCTAssertEqual(page2.urlString, "https://www.mingzw.net/mzwlist/%E9%81%AE%E5%A4%A9_2.html")
    }

    func testAnalyzeURLEmbeddedJavaScriptRunsBeforeURLParsing() {
        let variables = ParserVariableStore(writeScope: .source)
        let analyzed = AnalyzeUrl(
            rule: "https://example.com/search?q={{key}}\n@js:java.put('savedKey', key);result",
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com",
            source: nil,
            variableStore: variables
        )

        XCTAssertEqual(analyzed.urlString, "https://example.com/search?q=%E9%81%AE%E5%A4%A9")
        XCTAssertEqual(variables.get("savedKey"), "遮天")
        XCTAssertFalse(analyzed.urlString.contains("@js:"))
    }

    func testJavaPutStoresArraysLikeAndroidJSArrayToString() throws {
        let store = ParserVariableStore(writeScope: .source)
        let parser = JavaScriptParser(
            baseUrl: "https://example.com",
            source: nil,
            variableStore: store,
            requestURL: "https://example.com",
            requestHeaders: [:]
        )

        let result = try parser.evaluate(
            script: """
            (function() {
                java.put('tsign', ['SIGN123', '1712345678']);
                return java.get('tsign');
            })()
            """
        )

        XCTAssertEqual(result, "SIGN123,1712345678")
        XCTAssertEqual(store.get("tsign"), "SIGN123,1712345678")
    }

    func testAnalyzeURLTemplateSideEffectsCanUseSourceKeyAndCookieBridge() {
        let store = ParserVariableStore(writeScope: .source)
        CookieManager.shared.parseCookieString("session=1", domain: "www.banwenwu.com")

        let analyzed = AnalyzeUrl(
            rule: "{{url=source.getKey();cookie.removeCookie(url)}}\n/modules/article/search.php,{\"body\":\"searchkey={{key}}\",\"charset\":\"GBK\",\"method\":\"POST\"}",
            key: "遮天",
            page: 1,
            baseUrl: "https://www.banwenwu.com",
            source: BookSource(bookSourceName: "爱搬文屋", bookSourceUrl: "https://www.banwenwu.com#"),
            variableStore: store
        )

        XCTAssertEqual(analyzed.urlString, "https://www.banwenwu.com/modules/article/search.php")
        XCTAssertEqual(analyzed.method, .post)
        XCTAssertEqual(analyzed.charset.uppercased(), "GBK")
        XCTAssertEqual(CookieManager.shared.getCookieString(for: URL(string: "https://www.banwenwu.com")!), "")
    }

    func testCookieManagerAppliesParentDomainCookiesToSubdomainRequests() {
        CookieManager.shared.clearCookies(domain: "example.com")
        CookieManager.shared.parseCookieString("session=1; token=xyz", domain: "example.com")

        let cookieString = CookieManager.shared.getCookieString(for: URL(string: "https://api.example.com/search")!)

        XCTAssertEqual(cookieString, "session=1; token=xyz")
    }

    func testCookieManagerPreservesDeclaredParentDomainFromSubdomainResponse() {
        let domain = "cookie-domain.example.com"
        CookieManager.shared.clearCookies(domain: domain)
        defer { CookieManager.shared.clearCookies(domain: domain) }

        let cookie = HTTPCookie(properties: [
            .domain: ".\(domain)",
            .path: "/",
            .name: "_csrfToken",
            .value: "csrf-value"
        ])!

        CookieManager.shared.saveCookie(cookie, domain: "m.\(domain)")

        XCTAssertEqual(
            CookieManager.shared.getCookieKey("_csrfToken", domain: domain),
            "csrf-value"
        )
        XCTAssertEqual(
            CookieManager.shared.getCookieKey("_csrfToken", domain: "m.\(domain)"),
            "csrf-value"
        )
    }

    func testCookieManagerHandlesConcurrentCookieWrites() {
        let domain = "concurrent-cookie.example.com"
        CookieManager.shared.clearCookies(domain: domain)

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            CookieManager.shared.setCookie(
                name: "cookie\(index)",
                value: "value\(index)",
                domain: domain
            )
        }

        for index in 0..<200 {
            XCTAssertEqual(
                CookieManager.shared.getCookieValue(name: "cookie\(index)", domain: domain),
                "value\(index)"
            )
        }
        CookieManager.shared.clearCookies(domain: domain)
    }

    func testHTTPClientAddsAndroidStyleDefaultHeaders() throws {
        let analyzed = AnalyzeUrl(
            rule: "https://example.com/search",
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        let request = try analyzed.buildRequest()

        XCTAssertEqual(request.value(forHTTPHeaderField: "Keep-Alive"), "300")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connection"), "Keep-Alive")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testAnalyzeUrlEncodesFormBodyLikeAndroid() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","body":"query={{key}}&timestamp=1"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(analyzed.method, .post)
        XCTAssertEqual(analyzed.body, "query=%E9%81%AE%E5%A4%A9&timestamp=1")
    }

    func testAnalyzeUrlEncodesGBKFormBodyWithDeclaredCharset() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","charset":"GBK","body":"query={{key}}&timestamp=1"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(analyzed.method, .post)
        XCTAssertEqual(analyzed.charset.uppercased(), "GBK")
        XCTAssertEqual(analyzed.body, "query=%D5%DA%CC%EC&timestamp=1")
    }

    func testAnalyzeUrlEncodesGBKGETQueryWithDeclaredCharset() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search?query={{key}}&page=1,{"charset":"GBK"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(analyzed.method, .get)
        XCTAssertEqual(analyzed.charset.uppercased(), "GBK")
        XCTAssertEqual(analyzed.urlString, "https://example.com/search?query=%D5%DA%CC%EC&page=1")
    }

    func testAnalyzeUrlKeepsPreEncodedFormBodyStable() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","body":"query=%E9%81%AE%E5%A4%A9&timestamp=1"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(analyzed.body, "query=%E9%81%AE%E5%A4%A9&timestamp=1")
    }

    func testAnalyzeUrlDoesNotEncodeJSONBody() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"query\":\"遮天\"}"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(analyzed.body, #"{"query":"遮天"}"#)
    }

    func testAnalyzeUrlKeepsTemplateKeyRawInsideJSONBody() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"query\":\"{{key}}\"}"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )

        XCTAssertEqual(analyzed.body, #"{"query":"遮天"}"#)
    }

    func testAnalyzeUrlKeepsStructuredJSONBodyTemplateKeyRaw() throws {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","body":{"searchTerms":"{{key}}","pageNum":"{{page}}"}}"#,
            key: "遮天",
            page: 3,
            baseUrl: "https://example.com"
        )

        let body = try XCTUnwrap(analyzed.body)
        let payload = try XCTUnwrap(body.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(parsed["searchTerms"] as? String, "遮天")
        XCTAssertEqual(parsed["pageNum"] as? String, "3")
    }

    func testAnalyzeUrlDoesNotSplitPureJSURLOnQueryComma() {
        let source = BookSource(
            bookSourceName: "星空小说",
            bookSourceUrl: "https://api-bc.zonghengxiaoshuo.com",
            bookSourceComment: """
            api_Params = {
                "imei_ip":"",
                "book_privacy":"1",
                "read_preference":"0"
            };
            function sign($){
                s = $.replace(/&/g,"") + "d3dGiJc651gSQ8w1";
                return String(java.md5Encode(s));
            };
            function body($){
                if(!/app/.test(JSON.stringify($))){
                    if(/chapter/.test(link_Urlpath)){
                        api_Params = {};
                    }
                    $ = Object.assign(api_Params, $);
                } else {
                    $ = $;
                }
                s = Object.keys($).sort().map(key=>key+"="+$[key]).join('&');
                return String(s);
            };
            if(headers==""){
                link_Params.sign = sign(body(link_Params));
                burl = source.getKey();
                url = burl + link_Urlpath + body(link_Params);
            }
            """
        )

        let analyzed = AnalyzeUrl(
            rule: """
            @js:
            headers = "";
            link_Urlpath = "/api/v7/search/words?";
            link_Params = {
                "book_id":"143185,141577,150567,215243,211615,157237",
                "tab":"1",
                "gender":"0",
                "page":page,
                "wd":key
            };
            eval(String(source.bookSourceComment));
            """,
            key: "遮天",
            page: 1,
            baseUrl: source.bookSourceUrl,
            source: source
        )

        XCTAssertTrue(analyzed.urlString.contains("book_id=143185,141577,150567,215243,211615,157237"))
        XCTAssertTrue(analyzed.urlString.contains("&wd=%E9%81%AE%E5%A4%A9"))
        XCTAssertEqual(analyzed.method, .get)
        XCTAssertNil(analyzed.body)
    }

    func testRequestDescriptorCapturesAnalyzeUrlRequestShape() {
        let analyzed = AnalyzeUrl(
            rule: #"https://example.com/search,{"method":"POST","body":"query={{key}}","headers":{"X-Token":"abc"},"charset":"UTF-8","retry":2,"type":"hex"}"#,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com"
        )
        let request = HTTPClient.makeRequest(
            from: analyzed,
            timeout: 12,
            transportPreference: .preferThirdParty,
            enableCookieJar: false
        )

        let descriptor = HTTPClient.makeRequestDescriptor(from: analyzed, request: request)

        XCTAssertEqual(descriptor.resolvedURL, "https://example.com/search")
        XCTAssertEqual(descriptor.method, "POST")
        XCTAssertEqual(descriptor.headerKeys, ["Content-Type", "X-Token"])
        XCTAssertEqual(descriptor.bodyPreview, "query=%E9%81%AE%E5%A4%A9")
        XCTAssertEqual(descriptor.bodyLength, 24)
        XCTAssertEqual(descriptor.charset, "UTF-8")
        XCTAssertEqual(descriptor.retryCount, 2)
        XCTAssertEqual(descriptor.responseType, "hex")
        XCTAssertFalse(descriptor.cookieJarEnabled)
        XCTAssertEqual(descriptor.timeoutSeconds, 12)
        XCTAssertEqual(descriptor.transportPreference, "preferThirdParty")
    }

    func testJavaGetStringCanReadCurrentResultJSONDuringJSRule() throws {
        let parser = JavaScriptParser(
            baseUrl: "https://example.com/search",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com/search",
            requestHeaders: [:]
        )
        parser.updateContextContent("not-json")

        let result = try parser.evaluate(
            script: """
            (function() {
                return java.getString('$.bid');
            })()
            """,
            result: #"{"bid":"abc123"}"#
        )

        XCTAssertEqual(result, "abc123")
    }

    func testLoginCheckResponseBridgeExposesLocationHeaderAndURLAccessor() throws {
        let source = BookSource(bookSourceName: "bridge", bookSourceUrl: "https://example.com")
        let parser = JavaScriptParser(
            baseUrl: "https://example.com",
            source: source,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com",
            requestHeaders: [:]
        )

        let response = HTTPResponse(
            data: Data(),
            statusCode: 302,
            headers: ["Location": "/search/result"],
            url: URL(string: "https://example.com/search"),
            requestURL: URL(string: "https://example.com/search"),
            message: "Found",
            headerValues: ["location": ["/search/result"]],
            textOverride: ""
        )

        let action = try parser.evaluateLoginCheck(
            script: """
            if (result.header("Location") === "/search/result" && result.url() === "https://example.com/search") {
                result;
            } else {
                false;
            }
            """,
            response: response,
            fallbackRequestURL: "https://example.com/search"
        )

        switch action {
        case .keepOriginal:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected response bridge to keep original response when URL/header accessors succeed")
        }
    }

    func testLoginCheckResponseBridgeAcceptsTrailingExpressionWithoutReturn() throws {
        let source = BookSource(bookSourceName: "bridge", bookSourceUrl: "https://example.com")
        let parser = JavaScriptParser(
            baseUrl: "https://example.com",
            source: source,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com",
            requestHeaders: [:]
        )

        let response = HTTPResponse(
            data: Data(),
            statusCode: 302,
            headers: ["Location": "/search/result"],
            url: URL(string: "https://example.com/search"),
            requestURL: URL(string: "https://example.com/search"),
            message: "Found",
            headerValues: ["location": ["/search/result"]],
            textOverride: ""
        )

        let action = try parser.evaluateLoginCheck(
            script: """
            if (result.header("Location") === "/search/result") {
                result
            } else {
                false
            }
            """,
            response: response,
            fallbackRequestURL: "https://example.com/search"
        )

        switch action {
        case .keepOriginal:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected loginCheckJs trailing expression to preserve original response")
        }
    }

    private func makeBridge() -> JavaBridge {
        JavaBridge(
            baseUrl: "https://example.com/books/1/index.html",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com/books/1/index.html",
            requestHeaders: [:]
        )
    }

    private func makeParser() -> JavaScriptParser {
        JavaScriptParser(
            baseUrl: "https://example.com/books/1/index.html",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com/books/1/index.html",
            requestHeaders: [:]
        )
    }

    private func gb18030Data(for string: String) throws -> Data {
        let encodingValue = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let encoding = String.Encoding(rawValue: encodingValue)
        guard let data = string.data(using: encoding) else {
            throw XCTSkip("Unable to encode GB18030 fixture")
        }
        return data
    }

    private func data(fromHex hex: String) throws -> Data {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else {
            throw NSError(domain: "JavaBridgeCompatTests", code: 1, userInfo: nil)
        }

        var bytes: [UInt8] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw NSError(domain: "JavaBridgeCompatTests", code: 2, userInfo: nil)
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func callOnBackground<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }
}
