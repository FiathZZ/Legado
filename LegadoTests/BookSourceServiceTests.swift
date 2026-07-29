import Foundation
import XCTest
@testable import Legado

final class BookSourceServiceTests: XCTestCase {
    func testParseSubscriptionURLAcceptsBookSourceHost() throws {
        let url = try BookSourceService.parseSubscriptionURL(
            "yuedu://booksource/importonline?src=https://example.com/a.json"
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/a.json")
    }

    func testParseSubscriptionURLAcceptsRssSourceHostForCompatibility() throws {
        let url = try BookSourceService.parseSubscriptionURL(
            "yuedu://rsssource/importonline?src=http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"
        )

        XCTAssertEqual(
            url.absoluteString,
            "http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"
        )
    }

    func testParseSubscriptionURLNormalizesFullWidthPunctuation() throws {
        let url = try BookSourceService.parseSubscriptionURL(
            "yuedu：//rsssource/importonline？src=http：//yuedu。miaogongzi。net/shuyuan/miaogongziDY。json"
        )

        XCTAssertEqual(
            url.absoluteString,
            "http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"
        )
    }

    func testImportFromSubscriptionRejectsRssSourceSubscriptionWithClearMessage() async {
        do {
            _ = try await BookSourceService.importFromSubscription(
                "yuedu://rsssource/importonline?src=http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"
            )
            XCTFail("expected rss source subscription to be rejected")
        } catch let error as BookSourceServiceError {
            guard case .unsupportedSubscriptionType(let type) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(type, "RSS")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testParseSubscriptionURLRejectsUnsupportedHost() {
        XCTAssertThrowsError(
            try BookSourceService.parseSubscriptionURL(
                "yuedu://theme/importonline?src=https://example.com/a.json"
            )
        ) { error in
            guard case BookSourceServiceError.invalidSubscriptionURL = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testNormalizedImportURLStringRemovesThinSpace() {
        let input = "yuedu：//rsssource/importonline？src=http：//example。com/test。\u{2006}json"
        XCTAssertEqual(
            input.normalizedImportURLString(),
            "yuedu://rsssource/importonline?src=http://example.com/test.json"
        )
    }

    func testImportFromJSONTextDecodesStringEncodedRules() throws {
        let text = #"""
        [{
          "bookSourceName": "字符串规则书源",
          "bookSourceUrl": "https://example.com",
          "searchUrl": "/search?keyword={{key}}",
          "ruleSearch": "{\"bookList\":\"$.data\",\"name\":\"$.name\",\"bookUrl\":\"$.url\"}",
          "ruleToc": "{\"chapterList\":\"$.chapters\",\"chapterName\":\"$.title\",\"chapterUrl\":\"$.url\"}"
        }]
        """#

        let sources = try BookSourceService.importFromJSONText(text)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].ruleSearch?.bookList, "$.data")
        XCTAssertEqual(sources[0].ruleToc?.chapterList, "$.chapters")
    }

    func testImportFromJSONTextDecodesStringTimestampFromLegadoSubscription() throws {
        let text = #"""
        [{
          "bookSourceName": "瀚海书阁",
          "bookSourceUrl": "https://www.txtdd.top",
          "lastUpdateTime": "1772491176767",
          "ruleSearch": {"bookList":"@css:div.result","name":"h3@text","bookUrl":"a@href"},
          "searchUrl": "https://www.txtdd.top/search.html?keyword={{key}}"
        }]
        """#

        let sources = try BookSourceService.importFromJSONText(text)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].lastUpdateTime, 1_772_491_176_767)
    }

    func testImportFromJSONTextTreatsEmptyRuleArrayAsUnconfigured() throws {
        let text = #"""
        [{
          "bookSourceName": "空发现规则书源",
          "bookSourceUrl": "https://example.com",
          "ruleExplore": [],
          "searchUrl": "/search?keyword={{key}}"
        }]
        """#

        let sources = try BookSourceService.importFromJSONText(text)

        XCTAssertEqual(sources.count, 1)
        XCTAssertNil(sources[0].ruleExplore)
    }
}
