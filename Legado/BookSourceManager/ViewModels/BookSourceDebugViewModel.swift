import Foundation
import Combine

@MainActor
final class BookSourceDebugViewModel: ObservableObject {
    let source: BookSource

    @Published var keyword: String = ""
    @Published var isWorking: Bool = false
    @Published var currentAction: String = ""
    @Published var searchResults: [SearchBook] = []
    @Published var selectedBook: SearchBook?
    @Published var detail: BookDetail?
    @Published var chapters: [BookChapter] = []
    @Published var selectedChapter: BookChapter?
    @Published var chapterContent: ChapterContent?
    @Published var messages: [String] = []

    init(source: BookSource) {
        self.source = source
    }

    func search() async {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else {
            appendMessage("请输入搜索关键字")
            return
        }

        resetAfterSearch()
        await run(action: "搜索") {
            appendMessage("开始搜索：\(trimmedKeyword)")
            let webBook = WebBook(bookSource: source)
            let books = try await webBook.searchBook(keyword: trimmedKeyword)
            searchResults = books
            appendMessage("搜索完成，共 \(books.count) 条结果")
            if let first = books.first {
                select(book: first)
                appendMessage("已选中首条结果：\(first.name)")
            }
        }
    }

    func select(book: SearchBook) {
        selectedBook = book
        detail = nil
        chapters = []
        selectedChapter = nil
        chapterContent = nil
    }

    func loadDetail() async {
        guard let book = selectedBook else {
            appendMessage("请先选择搜索结果")
            return
        }

        guard !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendMessage("当前结果没有解析出 bookUrl，请查看控制台日志 `[LegadoParser]`")
            return
        }

        await run(action: "详情") {
            appendMessage("开始解析详情：\(book.name)")
            let webBook = WebBook(bookSource: source)
            let parsedDetail = try await webBook.getBookInfo(
                bookUrl: book.bookUrl,
                variables: book.variables,
                sourceVariables: book.sourceVariables,
                bookVariables: book.bookVariables,
                name: book.name,
                author: book.author,
                kind: book.kind ?? ""
            )
            detail = parsedDetail
            appendMessage("详情解析完成：tocUrl=\(parsedDetail.tocUrl ?? "空")")
        }
    }

    func loadToc() async {
        guard let detail else {
            appendMessage("请先解析书籍详情")
            return
        }

        guard let tocUrl = detail.tocUrl, !tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendMessage("当前详情没有解析出 tocUrl")
            return
        }

        await run(action: "目录") {
            appendMessage("开始解析目录：\(tocUrl)")
            let webBook = WebBook(bookSource: source)
            let parsedChapters = try await webBook.getTocList(
                tocUrl: tocUrl,
                bookUrl: detail.bookUrl,
                variables: detail.variables,
                sourceVariables: detail.sourceVariables,
                bookVariables: detail.bookVariables,
                name: detail.name,
                author: detail.author,
                kind: detail.kind ?? ""
            )
            chapters = parsedChapters
            selectedChapter = parsedChapters.first(where: { !$0.isVolume }) ?? parsedChapters.first
            if let selectedChapter {
                appendMessage("目录解析完成，共 \(parsedChapters.count) 章，已选中：\(selectedChapter.title)")
            } else {
                appendMessage("目录解析完成，但没有有效章节")
            }
        }
    }

    func select(chapter: BookChapter) {
        selectedChapter = chapter
        chapterContent = nil
    }

    func loadContent() async {
        guard let chapter = selectedChapter else {
            appendMessage("请先选择章节")
            return
        }

        guard !chapter.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendMessage("当前章节没有解析出 url")
            return
        }

        await run(action: "正文") {
            appendMessage("开始解析正文：\(chapter.title)")
            let webBook = WebBook(bookSource: source)
            let content = try await webBook.getContent(chapter: chapter)
            chapterContent = content
            appendMessage("正文解析完成，长度 \(content.content.count) 字")
        }
    }

    private func resetAfterSearch() {
        searchResults = []
        selectedBook = nil
        detail = nil
        chapters = []
        selectedChapter = nil
        chapterContent = nil
    }

    private func run(action: String, operation: () async throws -> Void) async {
        isWorking = true
        currentAction = action
        defer {
            isWorking = false
            currentAction = ""
        }

        do {
            try await operation()
        } catch {
            appendMessage("\(action)失败：\(error.localizedDescription)")
        }
    }

    private func appendMessage(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        messages.insert("[\(timestamp)] \(message)", at: 0)
    }
}
