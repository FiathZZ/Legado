import Foundation
import Combine
// MARK: - 书籍详情 ViewModel
/// 负责从书源加载完整的书籍详情
@MainActor
final class BookDetailViewModel: ObservableObject {
    private struct UsableSourceLoad: Sendable {
        let book: SearchBook
        let detail: BookDetail
    }

    // MARK: 状态
    @Published var detail: BookDetail?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published private(set) var didReceiveUsableDetail: Bool = false

    // MARK: 输入
    /// 来自搜索结果或书架的初始信息
    var searchBook: SearchBook
    private let allSources: [BookSource]
    private var preloadedChapters: [BookChapter]?
    private var resolvedSourceCacheKey: String?
    private var resolvedSourceCache: BookSource?

    // MARK: 初始化
    init(searchBook: SearchBook, allSources: [BookSource]) {
        self.searchBook = searchBook
        self.allSources = allSources
        // 用 SearchBook 的信息预填充，让 UI 可以立即展示部分内容
        self.detail = BookDetail(
            bookUrl: searchBook.bookUrl,
            name: searchBook.name,
            author: searchBook.author,
            coverUrl: searchBook.coverUrl,
            intro: searchBook.intro,
            kind: searchBook.kind,
            lastChapter: searchBook.lastChapter,
            updateTime: searchBook.updateTime,
            infoHtml: searchBook.infoHtml,
            wordCount: searchBook.wordCount,
            origin: searchBook.origin,
            sourceVariables: searchBook.sourceVariables,
            bookVariables: searchBook.bookVariables,
            variables: searchBook.variables
        )
        if LocalBookSupport.isLocalSource(searchBook.origin) {
            self.detail?.tocUrl = searchBook.bookUrl
        }
    }

    // MARK: 加载完整详情
    func loadDetail() async {
        if LocalBookSupport.isLocalSource(searchBook.origin) {
            isLoading = false
            errorMessage = nil
            detail?.tocUrl = searchBook.bookUrl
            didReceiveUsableDetail = true
            return
        }

        guard let candidate = sourceCandidate() else {
            isLoading = false
            errorMessage = "对应书源已被删除或禁用"
            return
        }

        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        guard !Task.isCancelled else { return }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let loaded = try await Self.loadUsableSource(candidate)
                return loaded
            }.value
            guard !Task.isCancelled else { return }
            searchBook = loaded.book
            detail = loaded.detail
            preloadedChapters = nil
            _tocViewModel = nil
            didReceiveUsableDetail = true
        } catch {
            didReceiveUsableDetail = false
            errorMessage = "加载详情失败，请重试或切换书源"
        }
    }

    // MARK: 目录 ViewModel（懒加载缓存，页面生命周期内复用）
    private var _tocViewModel: BookTocViewModel?
    func tocViewModel(bookshelfViewModel: BookshelfViewModel? = nil) -> BookTocViewModel? {
        guard let detail, let source = bookSource else { return nil }
        if _tocViewModel == nil {
            _tocViewModel = BookTocViewModel(
                detail: detail,
                source: source,
                bookshelfViewModel: bookshelfViewModel,
                prefetchedSearchBook: searchBook
            )
            if let preloadedChapters, !preloadedChapters.isEmpty {
                _tocViewModel?.setPreloadedChapters(preloadedChapters)
            }
        }
        _tocViewModel?.allSources = allSources
        return _tocViewModel
    }

    func clearTocCache() {
        _tocViewModel = nil
    }

    // MARK: 对应书源
    var bookSource: BookSource? {
        if LocalBookSupport.isLocalSource(searchBook.origin) {
            return LocalBookSupport.source()
        }
        if resolvedSourceCacheKey == searchBook.origin {
            return resolvedSourceCache
        }
        resolvedSourceCacheKey = searchBook.origin
        resolvedSourceCache = resolvedBookSource()
        return resolvedSourceCache
    }

    var availableSources: [BookSource] {
        allSources
    }

    private func resolvedBookSource() -> BookSource? {
        let normalizedOrigin = normalizedSourceURL(searchBook.origin)
        guard !normalizedOrigin.isEmpty else { return nil }
        return allSources.first {
            $0.enabled && normalizedSourceURL($0.bookSourceUrl) == normalizedOrigin
        }
    }

    private func sourceCandidate() -> (source: BookSource, book: SearchBook)? {
        let primary = SearchBookOrigin(
            url: searchBook.origin,
            name: searchBook.sourceName,
            bookUrl: searchBook.bookUrl,
            infoHtml: searchBook.infoHtml,
            sourceVariables: searchBook.sourceVariables,
            bookVariables: searchBook.bookVariables,
            variables: searchBook.variables
        )
        let sourcesByURL = allSources.reduce(into: [String: BookSource]()) { index, source in
            let key = normalizedSourceURL(source.bookSourceUrl)
            guard source.enabled, !key.isEmpty, index[key] == nil else { return }
            index[key] = source
        }
        var seen: Set<String> = []
        for origin in [primary] + searchBook.sourceOrigins {
            let normalizedOrigin = normalizedSourceURL(origin.url)
            guard !normalizedOrigin.isEmpty, seen.insert(normalizedOrigin).inserted else { continue }
            guard let source = sourcesByURL[normalizedOrigin] else {
                continue
            }
            var candidate = searchBook
            candidate.origin = source.bookSourceUrl
            candidate.sourceName = source.bookSourceName
            candidate.bookUrl = origin.bookUrl.isEmpty ? searchBook.bookUrl : origin.bookUrl
            candidate.infoHtml = origin.infoHtml
            candidate.sourceVariables = origin.sourceVariables
            candidate.bookVariables = origin.bookVariables
            candidate.variables = origin.variables
            return (source, candidate)
        }
        return nil
    }

    nonisolated private static func loadUsableSource(
        _ candidate: (source: BookSource, book: SearchBook)
    ) async throws -> UsableSourceLoad {
        guard !candidate.book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParserError.parsingFailed("书籍详情地址为空")
        }

        let webBook = WebBook(
            bookSource: candidate.source,
            maximumRequestTimeout: 3,
            allowsWebViewRequests: false,
            allowsAutomaticWebViewRecovery: false
        )
        defer { webBook.shutdown() }
        return try await SourceOperationDeadline.run(seconds: 3, priority: .utility) {
            let detail = try await webBook.getBookInfo(
                bookUrl: candidate.book.bookUrl,
                baseUrl: candidate.source.bookSourceUrl,
                cachedInfoHtml: candidate.book.infoHtml,
                variables: candidate.book.variables,
                sourceVariables: candidate.book.sourceVariables,
                bookVariables: candidate.book.bookVariables,
                name: candidate.book.name,
                author: candidate.book.author,
                kind: candidate.book.kind ?? ""
            )
            guard let tocUrl = detail.tocUrl, !tocUrl.isEmpty else {
                throw ParserError.parsingFailed("书源未返回目录")
            }
            return UsableSourceLoad(book: candidate.book, detail: detail)
        }
    }
    nonisolated private func normalizedSourceURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    nonisolated private static func hasUsableDetail(_ detail: BookDetail) -> Bool {
        [detail.intro, detail.lastChapter, detail.updateTime, detail.wordCount]
            .contains { value in
                !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
    }

    // MARK: 换源同步
    func applySourceSwitch(_ selection: ChangeSourceSelection) {
        searchBook = SearchBook(
            bookUrl: selection.detail.bookUrl,
            name: selection.detail.name,
            author: selection.detail.author,
            coverUrl: selection.detail.coverUrl,
            intro: selection.detail.intro,
            kind: selection.detail.kind,
            lastChapter: selection.detail.lastChapter,
            updateTime: selection.detail.updateTime,
            wordCount: selection.detail.wordCount,
            origin: selection.source.bookSourceUrl,
            sourceName: selection.source.bookSourceName,
            infoHtml: selection.detail.infoHtml,
            sourceVariables: selection.detail.sourceVariables,
            bookVariables: selection.detail.bookVariables,
            variables: selection.detail.variables
        )
        resolvedSourceCacheKey = nil
        resolvedSourceCache = nil
        detail = selection.detail
        preloadedChapters = selection.chapters
        _tocViewModel?.applySourceSwitch(selection)
        _tocViewModel = nil
    }
}
