import Foundation
import Combine

struct TestResult {
    let source: BookSource
    let success: Bool
    let message: String
    let duration: TimeInterval
}

@MainActor
class BookSourceBatchTester: ObservableObject {
    @Published var results: [TestResult] = []
    @Published var isRunning = false
    @Published var progress: Double = 0

    func testSources(_ sources: [BookSource], keyword: String = "斗罗大陆") async {
        isRunning = true
        results = []

        for (index, source) in sources.enumerated() {
            let result = await testSingleSource(source, keyword: keyword)
            results.append(result)
            progress = Double(index + 1) / Double(sources.count)
        }

        isRunning = false
    }

    private func testSingleSource(_ source: BookSource, keyword: String) async -> TestResult {
        let start = Date()
        let webBook = WebBook(bookSource: source)

        do {
            // 1. 搜索
            let books = try await webBook.searchBook(keyword: keyword)
            guard let book = books.first else {
                return TestResult(source: source, success: false,
                                message: "搜索无结果", duration: Date().timeIntervalSince(start))
            }

            // 2. 详情
            let detail = try await webBook.getBookInfo(bookUrl: book.bookUrl,
                                                       variables: book.variables,
                                                       sourceVariables: book.sourceVariables,
                                                       bookVariables: book.bookVariables,
                                                       name: book.name,
                                                       author: book.author,
                                                       kind: book.kind ?? "")

            // 3. 目录
            let chapters = try await webBook.getTocList(
                tocUrl: detail.tocUrl ?? book.bookUrl,
                bookUrl: book.bookUrl,
                maxPages: 20,
                cachedTocHtml: detail.tocHtml,
                variables: detail.variables,
                sourceVariables: detail.sourceVariables,
                bookVariables: detail.bookVariables,
                name: detail.name,
                author: detail.author,
                kind: detail.kind ?? ""
            )
            guard let chapter = chapters.first else {
                return TestResult(source: source, success: false,
                                message: "目录为空", duration: Date().timeIntervalSince(start))
            }

            // 4. 内容
            _ = try await webBook.getContent(chapter: chapter,
                                             nextChapterUrl: chapters.dropFirst().first?.url,
                                             variables: detail.variables)

            return TestResult(source: source, success: true,
                            message: "成功", duration: Date().timeIntervalSince(start))
        } catch {
            return TestResult(source: source, success: false,
                            message: error.localizedDescription,
                            duration: Date().timeIntervalSince(start))
        }
    }
}
