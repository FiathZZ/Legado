import XCTest
@testable import Legado

final class ParserVariableScopeTests: XCTestCase {
    func testParserVariableStoreResolvesChapterBookRuleDataSourcePrecedence() {
        let sourceStore = ParserVariableStore(
            values: [
                "shared": "source",
                "sourceOnly": "source"
            ],
            writeScope: .source
        )
        let runtimeStore = sourceStore.makeChildStore(writeScope: .ruleData, resetRuleData: true)
        runtimeStore.put("shared", value: "ruleData")
        runtimeStore.put("ruleOnly", value: "ruleData")
        runtimeStore.put("ruleWrite", value: "r")
        let bookStore = sourceStore.makeChildStore(
            writeScope: .book,
            inheritBookScope: false,
            resetRuleData: true,
            initialValues: [
                "shared": "book",
                "bookOnly": "book"
            ]
        )
        sourceStore.put("sourceWrite", value: "s")
        bookStore.put("bookWrite", value: "b")
        let chapterStore = bookStore.makeChildStore(
            writeScope: .chapter,
            inheritBookScope: true,
            initialValues: [
                "shared": "chapter",
                "chapterOnly": "chapter"
            ]
        )

        XCTAssertEqual(chapterStore.get("shared"), "chapter")
        XCTAssertEqual(chapterStore.get("bookOnly"), "book")
        XCTAssertEqual(runtimeStore.get("shared"), "ruleData")
        XCTAssertEqual(runtimeStore.get("ruleOnly"), "ruleData")
        XCTAssertEqual(chapterStore.get("sourceOnly"), "source")
        chapterStore.put("chapterWrite", value: "c")

        XCTAssertEqual(chapterStore.get("sourceWrite"), "s")
        XCTAssertEqual(chapterStore.get("bookWrite"), "b")
        XCTAssertEqual(chapterStore.get("chapterWrite"), "c")
        XCTAssertEqual(runtimeStore.get("ruleWrite"), "r")
        XCTAssertEqual(chapterStore.snapshot(for: .source, includeInherited: false)["sourceWrite"], "s")
        XCTAssertEqual(chapterStore.snapshot(for: .book, includeInherited: false)["bookWrite"], "b")
        XCTAssertEqual(chapterStore.snapshot(for: .chapter, includeInherited: false)["chapterWrite"], "c")
        XCTAssertNil(bookStore.snapshot(for: .book, includeInherited: false)["chapterWrite"])
    }

    func testMakeChildStoreResetRuleDataPreventsCrossItemLeaks() {
        let runtimeStore = ParserVariableStore(writeScope: .ruleData)
        runtimeStore.put("sharedTemp", value: "root")

        let firstItemStore = runtimeStore.makeChildStore(
            writeScope: .book,
            inheritBookScope: false,
            resetRuleData: true
        )
        XCTAssertEqual(firstItemStore.get("sharedTemp"), "")
        firstItemStore.put("sharedTemp", value: "item-1", scope: .ruleData)
        XCTAssertEqual(firstItemStore.get("sharedTemp"), "item-1")

        let secondItemStore = runtimeStore.makeChildStore(
            writeScope: .book,
            inheritBookScope: false,
            resetRuleData: true
        )
        XCTAssertEqual(secondItemStore.get("sharedTemp"), "")
    }

    func testSourceRuntimeStorePreservesAnalyzeUrlVariablesAcrossBookItems() {
        let sourceStore = ParserVariableStore(writeScope: .source)
        let runtimeStore = sourceStore.makeChildStore(writeScope: .source, resetRuleData: true)

        let analyzed = AnalyzeUrl(
            rule: """
            @js:
            java.put('tsign', ['SIGN123', '1712345678']);
            `https://example.com/search,{"method":"POST","body":"q=${key}"}`
            """,
            key: "遮天",
            page: 1,
            baseUrl: "https://example.com",
            source: nil,
            variableStore: runtimeStore
        )

        XCTAssertEqual(analyzed.urlString, "https://example.com/search")
        XCTAssertEqual(runtimeStore.get("tsign"), "SIGN123,1712345678")

        let bookStore = runtimeStore.makeChildStore(
            writeScope: .book,
            inheritBookScope: false,
            resetRuleData: true
        )

        XCTAssertEqual(bookStore.get("tsign"), "SIGN123,1712345678")
    }

    func testSubstituteGetVariablesUsesLayeredLookup() {
        let store = ParserVariableStore(
            sourceValues: ["token": "source-token"],
            ruleDataValues: ["ruleDataOnly": "rd"],
            bookValues: ["token": "book-token"],
            chapterValues: ["chapterId": "42"],
            writeScope: .chapter
        )

        let rendered = RuleAnalyzer.substituteGetVariables(
            "https://example.com/@get:{token}/@get:{chapterId}/@get:{ruleDataOnly}",
            variableStore: store
        )

        XCTAssertEqual(rendered, "https://example.com/book-token/42/rd")
    }

    func testBookChapterDecodesLegacyCacheWithoutLayeredVariables() throws {
        let legacyJSON = """
        {
          "index": 1,
          "title": "第1章",
          "url": "https://example.com/1",
          "baseUrl": "https://example.com",
          "bookUrl": "https://example.com/book",
          "isVolume": false,
          "isVip": false,
          "isPay": false,
          "variables": {
            "legacy": "value"
          }
        }
        """

        let chapter = try JSONDecoder().decode(BookChapter.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(chapter.variables["legacy"], "value")
        XCTAssertTrue(chapter.sourceVariables.isEmpty)
        XCTAssertTrue(chapter.bookVariables.isEmpty)
        XCTAssertTrue(chapter.chapterVariables.isEmpty)
    }
}
