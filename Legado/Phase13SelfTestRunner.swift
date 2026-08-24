import Foundation

#if DEBUG
enum Phase13SelfTestRunner {
    private struct Report: Codable {
        let xpathOK: Bool
        let xpathHrefs: [String]
        let xpathTitles: [String]
        let jsonJsOK: Bool
        let chapterTitles: [String]
        let chapterURLs: [String]
        let bookKind: String
        let error: String?
    }

    static func runIfNeeded() async -> Bool {
        guard ProcessInfo.processInfo.environment["PHASE13_SELF_TEST"] == "1" else {
            return false
        }

        let report = run()
        emit(report)
        exit((report.xpathOK && report.jsonJsOK) ? 0 : 1)
    }

    private static func run() -> Report {
        do {
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

            let source = BookSource(
                bookSourceName: "Phase13D Self Test",
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

            let expectedHrefs = [
                "https://example.com/chapter-1",
                "https://example.com/chapter-2"
            ]
            let expectedTitles = ["第1章", "第2章"]
            let expectedChapterTitles = ["玄幻:第一章", "玄幻:第二章"]
            let expectedChapterURLs = expectedHrefs
            let actualChapterTitles = parsed.chapters.map(\.title)
            let actualChapterURLs = parsed.chapters.map(\.url)
            let actualBookKind = parsed.chapters.first?.bookVariables["kind"] ?? ""

            return Report(
                xpathOK: hrefs == expectedHrefs && titles == expectedTitles,
                xpathHrefs: hrefs,
                xpathTitles: titles,
                jsonJsOK: actualChapterTitles == expectedChapterTitles
                    && actualChapterURLs == expectedChapterURLs
                    && actualBookKind == "玄幻",
                chapterTitles: actualChapterTitles,
                chapterURLs: actualChapterURLs,
                bookKind: actualBookKind,
                error: nil
            )
        } catch {
            return Report(
                xpathOK: false,
                xpathHrefs: [],
                xpathTitles: [],
                jsonJsOK: false,
                chapterTitles: [],
                chapterURLs: [],
                bookKind: "",
                error: error.localizedDescription
            )
        }
    }

    private static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        if let data = try? encoder.encode(report),
           let json = String(data: data, encoding: .utf8),
           let output = "PHASE13_SELF_TEST_RESULT=\(json)\n".data(using: .utf8) {
            FileHandle.standardOutput.write(output)
            try? FileHandle.standardOutput.synchronize()
        }
    }
}
#endif
