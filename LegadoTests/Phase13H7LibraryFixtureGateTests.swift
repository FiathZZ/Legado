import XCTest
import SwiftSoup
import GCDWebServer
@testable import Legado

final class Phase13H7LibraryFixtureGateTests: XCTestCase {
    private enum FixtureAttribution: String {
        case paritySample = "parity-sample"
        case parserImplementationGap = "parser-implementation-gap"
        case runtimeEngineGap = "runtime-engine-gap"
    }

    private enum FixtureRecommendation: String {
        case patchCurrentImplementation = "补现有实现"
        case sourceIntegration = "源码集成"
        case replaceLibrary = "替换库"
    }

    private struct XPathFixture {
        let name: String
        let androidCapabilitySample: String
        let html: String
        let rule: String
        let baseURL: String
        let usesElementContext: Bool
        let elementSelector: String?
        let expectedAndroid: [String]
        let expectedIOSCurrent: [String]
        let attribution: FixtureAttribution
        let recommendation: FixtureRecommendation
    }

    private struct JSONPathFixture {
        let name: String
        let androidCapabilitySample: String
        let rule: String
        let expectedAndroid: [String]
        let expectedIOSCurrentVariants: [[String]]
        let attribution: FixtureAttribution
        let recommendation: FixtureRecommendation
        let boundaryDescription: String
        let shouldDifferFromAndroidInCurrentRun: Bool
    }

    private enum JSExpectation {
        case string(String)
        case errorContains(String)
    }

    private struct JSRuntimeFixture {
        let name: String
        let androidCapabilitySample: String
        let expectedAndroid: String
        let expectedIOSCurrent: JSExpectation
        let attribution: FixtureAttribution
        let recommendation: FixtureRecommendation
        let execute: (GCDWebServer) throws -> String
    }

    func testXPathFixtureGateCharacterizesLibraryBoundary() throws {
        let fixtures: [XPathFixture] = [
            XPathFixture(
                name: "complex predicate keeps nested condition and href output",
                androidCapabilitySample: "AnalyzeByXPath + JXDocument can evaluate nested predicates and attribute output in one pass.",
                html: """
                <html><body>
                  <div class="book" data-rank="1">
                    <span class="flag" data-kind="vip"></span>
                    <a href="/book/1">遮天</a>
                  </div>
                  <div class="book" data-rank="2">
                    <span class="flag" data-kind="free"></span>
                    <a href="/book/2">凡人修仙传</a>
                  </div>
                </body></html>
                """,
                rule: "//div[@class='book'][span/@data-kind='vip']/a/@href",
                baseURL: "https://example.com/library/index.html",
                usesElementContext: false,
                elementSelector: nil,
                expectedAndroid: ["https://example.com/book/1"],
                expectedIOSCurrent: ["https://example.com/book/1"],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation
            ),
            XPathFixture(
                name: "relative context keeps current node as xpath root",
                androidCapabilitySample: "AnalyzeByXPath can continue XPath evaluation from an Element / JXNode context.",
                html: """
                <ul class="catalog">
                  <li class="chapter"><a href="/c1">第一章</a></li>
                  <li class="chapter hot"><a href="/c2">第二章</a></li>
                </ul>
                """,
                rule: "./a/text()",
                baseURL: "https://example.com/book/1",
                usesElementContext: true,
                elementSelector: "li.hot",
                expectedAndroid: ["第二章"],
                expectedIOSCurrent: ["第二章"],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation
            ),
            XPathFixture(
                name: "attribute output resolves relative src with base url",
                androidCapabilitySample: "Android path chain can emit attribute values and callers then resolve them against response URL.",
                html: """
                <html><body>
                  <article>
                    <img class="cover" src="../images/cover.jpg">
                  </article>
                </body></html>
                """,
                rule: "//img[@class='cover']/@src",
                baseURL: "https://example.com/books/detail/index.html",
                usesElementContext: false,
                elementSelector: nil,
                expectedAndroid: ["https://example.com/books/images/cover.jpg"],
                expectedIOSCurrent: ["https://example.com/books/images/cover.jpg"],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation
            ),
            XPathFixture(
                name: "table fragment normalization keeps detached td queryable",
                androidCapabilitySample: "AnalyzeByXPath wraps trailing td/tr fragments before JXDocument parsing.",
                html: "<td><a href='/c1'>第一章</a></td>",
                rule: "//a/text()",
                baseURL: "https://example.com/book/1/catalog",
                usesElementContext: false,
                elementSelector: nil,
                expectedAndroid: ["第一章"],
                expectedIOSCurrent: ["第一章"],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation
            ),
            XPathFixture(
                name: "xml input keeps xpath attribute extraction available",
                androidCapabilitySample: "Android falls back to XML parser for xml-like payloads before XPath selection.",
                html: """
                <?xml version="1.0" encoding="utf-8"?>
                <feed>
                  <item href="/chapter/9">终章</item>
                </feed>
                """,
                rule: "//item/@href",
                baseURL: "https://example.com/api/feed.xml",
                usesElementContext: false,
                elementSelector: nil,
                expectedAndroid: ["https://example.com/chapter/9"],
                expectedIOSCurrent: ["https://example.com/chapter/9"],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation
            )
        ]

        for fixture in fixtures {
            let actual: [String]
            if fixture.usesElementContext {
                let document = try SwiftSoup.parseBodyFragment(fixture.html)
                let selector = try XCTUnwrap(fixture.elementSelector)
                let element = try XCTUnwrap(try document.select(selector).first())
                actual = try XPathParser.getStringList(from: element, rule: fixture.rule, baseUrl: fixture.baseURL)
            } else {
                actual = try XPathParser.getStringList(from: fixture.html, rule: fixture.rule, baseUrl: fixture.baseURL)
            }
            XCTAssertEqual(actual, fixture.expectedIOSCurrent, fixtureDebugSummary(
                category: "XPath",
                name: fixture.name,
                androidCapabilitySample: fixture.androidCapabilitySample,
                expectedAndroid: fixture.expectedAndroid,
                expectedIOSCurrent: fixture.expectedIOSCurrent,
                attribution: fixture.attribution,
                recommendation: fixture.recommendation
            ))
            if fixture.attribution == .paritySample {
                XCTAssertEqual(actual, fixture.expectedAndroid, "XPath fixture '\(fixture.name)' should still match the Android capability sample.")
            }
        }
    }

    func testJSONPathFixtureGateCharacterizesParserBoundary() throws {
        let json = """
        {
          "library": {
            "featured": {
              "author": "辰东",
              "chapters": [
                {"title": "序章"},
                {"title": "第一章"}
              ]
            }
          },
          "books": [
            {
              "title": "遮天",
              "kind": "vip",
              "score": 9.7,
              "tags": ["vip", "hot"],
              "author": "辰东",
              "chapters": [
                {"title": "第一章"},
                {"title": "第二章"}
              ]
            },
            {
              "title": "仙逆",
              "kind": "free",
              "score": 8.6,
              "tags": ["free"],
              "author": "耳根",
              "chapters": [
                {"title": "启程"}
              ]
            },
            {
              "title": "斗破苍穹",
              "kind": "vip",
              "score": 7.8,
              "tags": ["ranked"],
              "author": "天蚕土豆",
              "chapters": [
                {"title": "乌坦城"}
              ]
            }
          ],
          "matrix": [
            [1, 2],
            [3, 4],
            [5, 6]
          ]
        }
        """

        let fixtures: [JSONPathFixture] = [
            JSONPathFixture(
                name: "recursive descent returns authors from nested objects",
                androidCapabilitySample: "Jayway JsonPath supports $..author recursive descent across object and array layers with stable traversal order.",
                rule: "$..author",
                expectedAndroid: ["辰东", "辰东", "耳根", "天蚕土豆"],
                expectedIOSCurrentVariants: [
                    ["辰东", "辰东", "耳根", "天蚕土豆"],
                    ["辰东", "耳根", "天蚕土豆", "辰东"]
                ],
                attribution: .parserImplementationGap,
                recommendation: .patchCurrentImplementation,
                boundaryDescription: "Recursive descent author ordering is not stable across runs; current traversal can flip between featured-first and books-first output instead of preserving Android's stable recursive order.",
                shouldDifferFromAndroidInCurrentRun: false
            ),
            JSONPathFixture(
                name: "recursive nested array flatten keeps chapter titles in order",
                androidCapabilitySample: "Jayway JsonPath can continue into nested arrays after recursive hits, e.g. $..chapters[*].title, while preserving stable recursive order.",
                rule: "$..chapters[*].title",
                expectedAndroid: ["序章", "第一章", "第一章", "第二章", "启程", "乌坦城"],
                expectedIOSCurrentVariants: [
                    ["序章", "第一章", "第一章", "第二章", "启程", "乌坦城"],
                    ["第一章", "第二章", "启程", "乌坦城", "序章", "第一章"]
                ],
                attribution: .parserImplementationGap,
                recommendation: .patchCurrentImplementation,
                boundaryDescription: "Recursive chapter title ordering is not stable across runs; current implementation may visit the books array before the featured branch, which does not align with Android's stable recursive ordering.",
                shouldDifferFromAndroidInCurrentRun: false
            ),
            JSONPathFixture(
                name: "simple filter equality still matches vip books",
                androidCapabilitySample: "Jayway JsonPath filter equality on string fields is part of Android's baseline rule set.",
                rule: "$.books[?(@.kind=='vip')].title",
                expectedAndroid: ["遮天", "斗破苍穹"],
                expectedIOSCurrentVariants: [["遮天", "斗破苍穹"]],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation,
                boundaryDescription: "Matches Android baseline.",
                shouldDifferFromAndroidInCurrentRun: false
            ),
            JSONPathFixture(
                name: "wildcard plus nested array indexing remains available",
                androidCapabilitySample: "Jayway JsonPath supports wildcard array expansion followed by nested indexing.",
                rule: "$.matrix[*][0]",
                expectedAndroid: ["1", "3", "5"],
                expectedIOSCurrentVariants: [["1", "3", "5"]],
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation,
                boundaryDescription: "Matches Android baseline.",
                shouldDifferFromAndroidInCurrentRun: false
            ),
            JSONPathFixture(
                name: "numeric comparison filter is still missing",
                androidCapabilitySample: "Jayway JsonPath supports comparison operators such as >= inside filters.",
                rule: "$.books[?(@.score>=9)].title",
                expectedAndroid: ["遮天"],
                expectedIOSCurrentVariants: [[]],
                attribution: .parserImplementationGap,
                recommendation: .patchCurrentImplementation,
                boundaryDescription: "Numeric comparison filters are still unsupported in the current parser implementation.",
                shouldDifferFromAndroidInCurrentRun: true
            ),
            JSONPathFixture(
                name: "filter path with nested array access is still missing",
                androidCapabilitySample: "Jayway JsonPath supports nested filter paths like @.tags[0] == 'vip'.",
                rule: "$.books[?(@.tags[0]=='vip')].title",
                expectedAndroid: ["遮天"],
                expectedIOSCurrentVariants: [[]],
                attribution: .parserImplementationGap,
                recommendation: .patchCurrentImplementation,
                boundaryDescription: "Nested filter path access is still unsupported in the current parser implementation.",
                shouldDifferFromAndroidInCurrentRun: true
            )
        ]

        for fixture in fixtures {
            let actual = try JSONPathParser.getStringList(from: json, rule: fixture.rule)
            XCTAssertTrue(fixture.expectedIOSCurrentVariants.contains(actual), fixtureDebugSummary(
                category: "JSONPath",
                name: fixture.name,
                androidCapabilitySample: fixture.androidCapabilitySample,
                expectedAndroid: fixture.expectedAndroid,
                expectedIOSCurrent: fixture.expectedIOSCurrentVariants.first ?? [],
                attribution: fixture.attribution,
                recommendation: fixture.recommendation,
                boundaryDescription: fixture.boundaryDescription,
                allowedIOSCurrentVariants: fixture.expectedIOSCurrentVariants
            ))
            switch fixture.attribution {
            case .paritySample:
                XCTAssertEqual(actual, fixture.expectedAndroid, "JSONPath fixture '\(fixture.name)' should still match the Android capability sample.")
            case .parserImplementationGap:
                if fixture.shouldDifferFromAndroidInCurrentRun {
                    XCTAssertNotEqual(actual, fixture.expectedAndroid, "JSONPath fixture '\(fixture.name)' should keep exposing the current parser gap until we explicitly close it.")
                } else {
                    XCTAssertTrue(
                        fixture.expectedIOSCurrentVariants.count > 1,
                        "JSONPath fixture '\(fixture.name)' should describe why it remains a parser gap even when one allowed run can match Android ordering."
                    )
                }
            case .runtimeEngineGap:
                XCTFail("JSONPath fixtures should not use runtime engine gap classification.")
            }
        }
    }

    func testJSRuntimeFixtureGateCharacterizesBridgeAndEngineBoundary() throws {
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
            response.setValue("redirect", forAdditionalHeader: "X-Phase")
            return response
        }
        server.addHandler(
            forMethod: "GET",
            path: "/final",
            request: GCDWebServerRequest.self
        ) { _ in
            let response = GCDWebServerDataResponse(text: "phase13h7-final")!
            response.setValue("final", forAdditionalHeader: "X-Phase")
            return response
        }
        try server.start(options: [
            GCDWebServerOption_Port: 21437,
            GCDWebServerOption_BindToLocalhost: true,
            GCDWebServerOption_AutomaticallySuspendInBackground: false
        ])
        defer { server.stop() }

        let baseURL = try XCTUnwrap(server.serverURL)
        let redirectURL = baseURL.appendingPathComponent("redirect").absoluteString
        let finalURL = baseURL.appendingPathComponent("final").absoluteString
        let fixtures: [JSRuntimeFixture] = [
            JSRuntimeFixture(
                name: "source book and variable bridge stay readable in JS",
                androidCapabilitySample: "Rhino runtime exposes source / book / java.put-get state to JS rules.",
                expectedAndroid: #"{"sourceKey":"https://example.com/source","sourceVar":"source-token","bookName":"遮天","saved":"detail"}"#,
                expectedIOSCurrent: .string(#"{"sourceKey":"https://example.com/source","sourceVar":"source-token","bookName":"遮天","saved":"detail"}"#),
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation,
                execute: { _ in
                    let store = ParserVariableStore(sourceValues: ["token": "source-token"], writeScope: .source)
                    let parser = JavaScriptParser(
                        baseUrl: "https://example.com/source",
                        source: BookSource(bookSourceName: "测试源", bookSourceUrl: "https://example.com/source"),
                        variableStore: store,
                        requestURL: "https://example.com/source",
                        requestHeaders: [:]
                    )
                    parser.injectBook(bookUrl: "https://example.com/book/1", name: "遮天", author: "辰东")
                    return try parser.evaluate(
                        script: """
                        (function() {
                            java.put('stage', 'detail');
                            return JSON.stringify({
                                sourceKey: source.getKey(),
                                sourceVar: source.getVariable('token'),
                                bookName: book.getVariable('name'),
                                saved: java.get('stage')
                            });
                        })()
                        """
                    )
                }
            ),
            JSRuntimeFixture(
                name: "request bridge returns normalized url and request headers",
                androidCapabilitySample: "Android JS bridge lets rules read request URL and serialized request headers.",
                expectedAndroid: "https://example.com/api/list?page=2|abc|UnitTest",
                expectedIOSCurrent: .string("https://example.com/api/list?page=2|abc|UnitTest"),
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation,
                execute: { _ in
                    let parser = JavaScriptParser(
                        baseUrl: "https://example.com",
                        source: nil,
                        variableStore: ParserVariableStore(writeScope: .source),
                        requestURL: "https://example.com/api/list?page=2",
                        requestHeaders: ["X-Token": "abc", "User-Agent": "UnitTest"]
                    )
                    return try parser.evaluate(
                        script: """
                        (function() {
                            var headers = JSON.parse(java.getRequestHeaders());
                            return java.getRequestURL() + "|" + headers["X-Token"] + "|" + headers["User-Agent"];
                        })()
                        """
                    )
                }
            ),
            JSRuntimeFixture(
                name: "response bridge keeps redirect headers when using no-follow get",
                androidCapabilitySample: "Android get/head helpers expose code, header lookup and requestUrl on redirect responses.",
                expectedAndroid: #"{"code":302,"location":"\#(finalURL)","requestUrl":"\#(redirectURL)","finalURL":"\#(redirectURL)"}"#,
                expectedIOSCurrent: .string(#"{"code":302,"location":"\#(finalURL)","requestUrl":"\#(redirectURL)","finalURL":"\#(redirectURL)"}"#),
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation,
                execute: { server in
                    let parser = JavaScriptParser(
                        baseUrl: redirectURL,
                        source: nil,
                        variableStore: ParserVariableStore(writeScope: .source),
                        requestURL: redirectURL,
                        requestHeaders: [:]
                    )
                    return try parser.evaluate(
                        script: """
                        (function() {
                            var response = java.get('\(redirectURL)', null);
                            return JSON.stringify({
                                code: response.code(),
                                location: response.headers('Location'),
                                requestUrl: response.request().url(),
                                finalURL: String(response.url)
                            });
                        })()
                        """
                    )
                }
            ),
            JSRuntimeFixture(
                name: "response requestUrl is still a function-shaped bridge field",
                androidCapabilitySample: "Android-side response objects are typically consumed as plain fields in JS snippets.",
                expectedAndroid: "string",
                expectedIOSCurrent: .string("function"),
                attribution: .parserImplementationGap,
                recommendation: .patchCurrentImplementation,
                execute: { _ in
                    let parser = JavaScriptParser(
                        baseUrl: redirectURL,
                        source: nil,
                        variableStore: ParserVariableStore(writeScope: .source),
                        requestURL: redirectURL,
                        requestHeaders: [:]
                    )
                    return try parser.evaluate(
                        script: """
                        (function() {
                            var response = java.get('\(redirectURL)', null);
                            return typeof response.requestUrl;
                        })()
                        """
                    )
                }
            ),
            JSRuntimeFixture(
                name: "document bridge keeps jsoup-like select remove and text semantics",
                androidCapabilitySample: "Rhino + jsoup runtime allows org.jsoup.Jsoup.parse(...).select(...).remove() document workflows.",
                expectedAndroid: #"{"token":"abc","lineText":"keep","html":"<html><head></head><body><div><input name=\"_token\" value=\"abc\" /><div class=\"line\">keep</div></div></body></html>"}"#,
                expectedIOSCurrent: .string(#"{"token":"abc","lineText":"keep","html":"<html><head></head><body><div><input name=\"_token\" value=\"abc\" /><div class=\"line\">keep</div></div></body></html>"}"#),
                attribution: .paritySample,
                recommendation: .patchCurrentImplementation,
                execute: { _ in
                    let parser = JavaScriptParser(
                        baseUrl: "https://example.com",
                        source: nil,
                        variableStore: ParserVariableStore(writeScope: .source),
                        requestURL: "https://example.com",
                        requestHeaders: [:]
                    )
                    return try parser.evaluate(
                        script: """
                        (function() {
                            var doc = org.jsoup.Jsoup.parse('<div><input name="_token" value="abc"><div class="line">keep</div><div class="line hide">drop</div></div>');
                            var token = doc.select('input[name=_token]').attr('value');
                            doc.select('.hide').remove();
                            var html = doc.outerHtml()
                                .replace(/>\\s+</g, '><')
                                .replace(/\\n/g, '')
                                .replace(/\\s{2,}/g, ' ')
                                .replace(/>\\s+/g, '>')
                                .replace(/\\s+</g, '<')
                                .trim();
                            return JSON.stringify({
                                token: token,
                                lineText: doc.select('.line').text(),
                                html: html
                            });
                        })()
                        """
                    )
                }
            ),
            JSRuntimeFixture(
                name: "Rhino-specific for each syntax still fails on JavaScriptCore",
                androidCapabilitySample: "Rhino runtime accepts legacy for each iteration syntax that some Android-side JS snippets still use.",
                expectedAndroid: "6",
                expectedIOSCurrent: .string(""),
                attribution: .runtimeEngineGap,
                recommendation: .replaceLibrary,
                execute: { _ in
                    let parser = JavaScriptParser(
                        baseUrl: "https://example.com",
                        source: nil,
                        variableStore: ParserVariableStore(writeScope: .source),
                        requestURL: "https://example.com",
                        requestHeaders: [:]
                    )
                    return try parser.evaluate(
                        script: """
                        (function() {
                            var total = 0;
                            for each (var item in [1, 2, 3]) {
                                total += item;
                            }
                            return String(total);
                        })()
                        """
                    )
                }
            ),
            JSRuntimeFixture(
                name: "Java Map style result.get access still fails on plain JS objects",
                androidCapabilitySample: "Rhino can expose host Map objects so result.get('id') keeps working in Android fixtures.",
                expectedAndroid: "3242532321",
                expectedIOSCurrent: .string(#"{"id":"3242532321"}"#),
                attribution: .runtimeEngineGap,
                recommendation: .sourceIntegration,
                execute: { _ in
                    let parser = JavaScriptParser(
                        baseUrl: "https://example.com",
                        source: nil,
                        variableStore: ParserVariableStore(writeScope: .source),
                        requestURL: "https://example.com",
                        requestHeaders: [:]
                    )
                    return try parser.evaluate(
                        script: """
                        (function() {
                            return result.get('id');
                        })()
                        """,
                        resultObject: ["id": "3242532321"]
                    )
                }
            )
        ]

        for fixture in fixtures {
            switch fixture.expectedIOSCurrent {
            case .string(let expected):
                let actual = try fixture.execute(server)
                XCTAssertEqual(actual, expected, fixtureDebugSummary(
                    category: "JS runtime",
                    name: fixture.name,
                    androidCapabilitySample: fixture.androidCapabilitySample,
                    expectedAndroid: [fixture.expectedAndroid],
                    expectedIOSCurrent: [expected],
                    attribution: fixture.attribution,
                    recommendation: fixture.recommendation
                ))
                if fixture.attribution == .paritySample {
                    XCTAssertEqual(actual, fixture.expectedAndroid, "JS runtime fixture '\(fixture.name)' should still match the Android capability sample.")
                } else {
                    XCTAssertNotEqual(actual, fixture.expectedAndroid, "JS runtime fixture '\(fixture.name)' should keep exposing the current boundary until we deliberately close it.")
                }
            case .errorContains(let messageFragment):
                XCTAssertThrowsError(
                    try fixture.execute(server),
                    fixtureDebugSummary(
                        category: "JS runtime",
                        name: fixture.name,
                        androidCapabilitySample: fixture.androidCapabilitySample,
                        expectedAndroid: [fixture.expectedAndroid],
                        expectedIOSCurrent: ["throws containing \(messageFragment)"],
                        attribution: fixture.attribution,
                        recommendation: fixture.recommendation
                    )
                ) { error in
                    let description = String(describing: error)
                    XCTAssertTrue(
                        description.localizedCaseInsensitiveContains(messageFragment),
                        "Expected JS runtime fixture '\(fixture.name)' to fail with fragment '\(messageFragment)', got: \(description)"
                    )
                }
            }
        }
    }

    private func fixtureDebugSummary(
        category: String,
        name: String,
        androidCapabilitySample: String,
        expectedAndroid: [String],
        expectedIOSCurrent: [String],
        attribution: FixtureAttribution,
        recommendation: FixtureRecommendation,
        boundaryDescription: String? = nil,
        allowedIOSCurrentVariants: [[String]]? = nil
    ) -> String {
        """
        [\(category)] \(name)
        Android sample: \(androidCapabilitySample)
        Android expected: \(expectedAndroid)
        iOS current: \(expectedIOSCurrent)
        Allowed iOS variants: \(allowedIOSCurrentVariants ?? [expectedIOSCurrent])
        Attribution: \(attribution.rawValue)
        Recommendation: \(recommendation.rawValue)
        Boundary: \(boundaryDescription ?? "n/a")
        """
    }
}
