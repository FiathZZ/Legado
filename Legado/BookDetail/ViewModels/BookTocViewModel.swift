import Foundation
import Combine
import SwiftData

typealias TocRequestLoader = (BookDetail, BookSource) async throws -> [BookChapter]

// MARK: - 目录 ViewModel
@MainActor
final class BookTocViewModel: ObservableObject {

    private enum CachePolicy {
        static let ttl: TimeInterval = 7 * 24 * 60 * 60
    }

    @Published var chapters: [BookChapter] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    private var detail: BookDetail
    var source: BookSource
    weak var bookshelfViewModel: BookshelfViewModel?
    var allSources: [BookSource] = []
    private var modelContext: ModelContext? { bookshelfViewModel?.modelContext }
    private var tocLoadTask: Task<Void, Never>?
    private var tocRefreshTask: Task<Void, Never>?
    private var tocRefreshID: UUID?
    private var tocLoadGeneration = UUID()
    private let tocRequestLoader: TocRequestLoader?
    private let prefetchedSearchBook: SearchBook?

    init(
        detail: BookDetail,
        source: BookSource,
        bookshelfViewModel: BookshelfViewModel? = nil,
        tocRequestLoader: TocRequestLoader? = nil,
        prefetchedSearchBook: SearchBook? = nil
    ) {
        self.detail = detail
        self.source = source
        self.bookshelfViewModel = bookshelfViewModel
        self.tocRequestLoader = tocRequestLoader
        self.prefetchedSearchBook = prefetchedSearchBook
    }

    func loadToc() async {
        // Swift actors are reentrant at every await. Keep one task for this view model so
        // repeated .task/onAppear calls cannot independently insert the same cache key.
        if let tocLoadTask {
            await tocLoadTask.value
            return
        }

        let generation = tocLoadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadTocOnce(generation: generation)
        }
        tocLoadTask = task
        await task.value
        if tocLoadGeneration == generation {
            tocLoadTask = nil
        }
    }

    /// Restores locally available TOC/body state before any network request starts.
    @discardableResult
    func restoreCachedChaptersIfAvailable() -> Bool {
        guard chapters.isEmpty else { return true }
        if let cached = loadCachedChapters() {
            chapters = cached.chapters
            syncChapterCount()
            errorMessage = nil
            if cached.isExpired, !LocalBookSupport.isLocalSource(source.bookSourceUrl) {
                refreshCachedTocInBackground(generation: tocLoadGeneration)
            }
            return true
        }
        guard let fallback = loadCachedCurrentChapterFallback() else { return false }
        chapters = fallback
        syncChapterCount()
        errorMessage = nil
        if !LocalBookSupport.isLocalSource(source.bookSourceUrl) {
            refreshCachedTocInBackground(generation: tocLoadGeneration)
        }
        return true
    }

    private func loadTocOnce(generation: UUID) async {
        guard generation == tocLoadGeneration, !Task.isCancelled else { return }
        guard chapters.isEmpty else { return }
        if restoreCachedChaptersIfAvailable() {
            return
        }

        if LocalBookSupport.isLocalSource(source.bookSourceUrl) {
            errorMessage = chapters.isEmpty ? "本地书目录尚未生成" : nil
            return
        }

        await refreshTocFromNetwork(generation: generation)
    }

    /// Refreshes an expired directory without delaying a reader that can already use its cache.
    private func refreshCachedTocInBackground(generation: UUID) {
        guard tocRefreshTask == nil else { return }
        let refreshID = UUID()
        tocRefreshID = refreshID
        tocRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshTocFromNetwork(generation: generation)
            guard self.tocRefreshID == refreshID else { return }
            self.tocRefreshTask = nil
            self.tocRefreshID = nil
        }
    }

    func makeReaderViewModel(startIndex: Int = 0) -> (vm: ReaderViewModel, bookID: String)? {
        guard !chapters.isEmpty else { return nil }
        let entity = bookshelfViewModel?.bookEntity(for: detail.bookUrl)
        let ctx = bookshelfViewModel?.modelContext
        let vm = ReaderViewModel(
            chapters: chapters,
            source: source,
            startIndex: startIndex,
            bookEntity: entity,
            modelContext: ctx,
            bookName: detail.name,
            bookAuthor: detail.author,
            allSources: allSources,
            prefetchedBook: prefetchedSearchBook
        )
        return (vm, detail.bookUrl)
    }

    /// Reuses the successful source-selection probe instead of immediately issuing the same
    /// directory request again when the detail view is opened.
    func setPreloadedChapters(_ chapters: [BookChapter]) {
        guard self.chapters.isEmpty, !chapters.isEmpty else { return }
        self.chapters = chapters
        errorMessage = nil
        saveChaptersToCache(chapters, bookUrl: detail.bookUrl)
        syncChapterCount()
    }

    /// Applies Android-compatible title replacement rules when rendering the table of contents.
    func displayChapterTitle(_ title: String) -> String {
        guard let modelContext else { return title }
        let store = ReplaceRuleStore(modelContext: modelContext)
        let enabledRules = store.fetchEnabled()
        let convertedRules = enabledRules.map { $0.toReplaceRule }
        let titleRules = convertedRules.filter { rule in
            rule().scope == .title || rule().scope == .all
        }
        let matchingRules = titleRules.filter { rule in
            rule().applies(
                toBookName: detail.name,
                sourceName: source.bookSourceName,
                sourceURL: source.bookSourceUrl
            )
        }
        let rules = matchingRules.sorted { $0().order < $1().order }

        return rules.reduce(title) { current, rule in
            ReaderContentService.applyReplaceRule(current, rule: rule(), source: source)
        }
    }

    func applySourceSwitch(_ selection: ChangeSourceSelection) {
        let oldBookUrl = detail.bookUrl
        tocLoadGeneration = UUID()
        tocLoadTask?.cancel()
        tocLoadTask = nil
        tocRefreshTask?.cancel()
        tocRefreshTask = nil
        tocRefreshID = nil
        detail = selection.detail
        source = selection.source
        chapters = selection.chapters
        errorMessage = nil

        let generation = tocLoadGeneration
        let encodingTask = Task.detached(priority: .utility) {
            TocCachePolicy.encodedDataIfSafe(selection.chapters)
        }
        Task { [weak self] in
            guard let data = await encodingTask.value,
                  let self,
                  self.tocLoadGeneration == generation else { return }
            self.replaceTocCache(
                removingBookUrl: oldBookUrl,
                bookUrl: selection.detail.bookUrl,
                encodedData: data
            )
        }
        syncChapterCount()
    }

    private func refreshTocFromNetwork(generation: UUID) async {
        guard generation == tocLoadGeneration, !Task.isCancelled else { return }
        guard let tocUrl = detail.tocUrl, !tocUrl.isEmpty else {
            errorMessage = "书籍未提供目录地址"
            return
        }

        let requestDetail = detail
        let requestSource = source

        isLoading = true
        defer {
            if generation == tocLoadGeneration {
                isLoading = false
            }
        }
        errorMessage = nil

        do {
            let fetched: [BookChapter]
            if let tocRequestLoader {
                fetched = try await tocRequestLoader(requestDetail, requestSource)
            } else {
                fetched = try await Task.detached(priority: .userInitiated) {
                    let webBook = WebBook(bookSource: requestSource)
                    defer { webBook.shutdown() }
                    return try await webBook.getTocList(
                        tocUrl: tocUrl,
                        bookUrl: requestDetail.bookUrl,
                        cachedTocHtml: requestDetail.tocHtml,
                        variables: requestDetail.variables,
                        sourceVariables: requestDetail.sourceVariables,
                        bookVariables: requestDetail.bookVariables,
                        name: requestDetail.name,
                        author: requestDetail.author,
                        kind: requestDetail.kind ?? ""
                    )
                }.value
            }
            guard generation == tocLoadGeneration else { return }
            chapters = fetched
            saveChaptersToCache(fetched, bookUrl: requestDetail.bookUrl)
            syncChapterCount()
            if chapters.isEmpty {
                errorMessage = "未能获取到目录，请检查书源配置"
            }
        } catch {
            guard generation == tocLoadGeneration else { return }
            if chapters.isEmpty {
                errorMessage = "加载目录失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadCachedChapters() -> (chapters: [BookChapter], isExpired: Bool)? {
        guard let modelContext else { return nil }
        let key = TocCacheEntity.cacheKey(for: detail.bookUrl)
        let predicate = #Predicate<TocCacheEntity> { entity in
            entity.cacheKey == key
        }
        var descriptor = FetchDescriptor<TocCacheEntity>(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let entity = try? modelContext.fetch(descriptor).first,
              let chapters = entity.toChapters(),
              !chapters.isEmpty else {
            return nil
        }

        let isExpired = entity.cachedAt.addingTimeInterval(CachePolicy.ttl) < .now
        return (chapters, isExpired)
    }

    private func loadCachedCurrentChapterFallback() -> [BookChapter]? {
        guard let bookshelfViewModel,
              let entity = bookshelfViewModel.bookEntity(for: detail.bookUrl) else {
            return nil
        }

        let currentIndex = max(entity.currentChapterIndex, 0)
        let cacheKey = ChapterCacheStore.makeKey(
            sourceUrl: source.bookSourceUrl,
            bookUrl: detail.bookUrl
        )
        guard ChapterCacheStore.hasNonEmptyContent(bookKey: cacheKey, index: currentIndex) else {
            return nil
        }

        return (0...currentIndex).map { index in
            BookChapter(
                index: index,
                title: index == currentIndex
                    ? (entity.currentChapterName ?? "第\(index + 1)章")
                    : "第\(index + 1)章",
                url: "",
                bookUrl: detail.bookUrl
            )
        }
    }

    private func saveChaptersToCache(_ chapters: [BookChapter], bookUrl: String) {
        let generation = tocLoadGeneration
        let encodingTask = Task.detached(priority: .utility) {
            TocCachePolicy.encodedDataIfSafe(chapters)
        }
        Task { [weak self] in
            guard let data = await encodingTask.value,
                  let self,
                  self.tocLoadGeneration == generation else { return }
            self.replaceTocCache(
                removingBookUrl: nil,
                bookUrl: bookUrl,
                encodedData: data
            )
        }
    }

    /// Applies cache deletion and insertion/update in one transaction. SwiftData's unique
    /// `cacheKey` is otherwise vulnerable to a delete-save-insert-save source-switch sequence.
    private func replaceTocCache(
        removingBookUrl: String?,
        bookUrl: String,
        encodedData: Data
    ) {
        guard let modelContext,
              let json = String(data: encodedData, encoding: .utf8) else {
            return
        }

        if let removingBookUrl,
           TocCacheEntity.cacheKey(for: removingBookUrl) != TocCacheEntity.cacheKey(for: bookUrl) {
            let oldKey = TocCacheEntity.cacheKey(for: removingBookUrl)
            let oldPredicate = #Predicate<TocCacheEntity> { entity in
                entity.cacheKey == oldKey
            }
            if let staleCaches = try? modelContext.fetch(FetchDescriptor<TocCacheEntity>(predicate: oldPredicate)) {
                staleCaches.forEach(modelContext.delete)
            }
        }

        let key = TocCacheEntity.cacheKey(for: bookUrl)
        let predicate = #Predicate<TocCacheEntity> { entity in
            entity.cacheKey == key
        }
        var descriptor = FetchDescriptor<TocCacheEntity>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.bookUrl = bookUrl
            existing.chaptersJson = json
            existing.cachedAt = .now
        } else {
            modelContext.insert(TocCacheEntity(cacheKey: key, bookUrl: bookUrl, chaptersJson: json))
        }

        do {
            try modelContext.save()
        } catch {
            ParserLog.debug(
                "BookTocViewModel",
                "save toc cache failed book=\(ParserLog.preview(bookUrl)) error=\(error.localizedDescription)"
            )
        }
    }

    private func syncChapterCount() {
        if let entity = bookshelfViewModel?.bookEntity(for: detail.bookUrl) {
            entity.totalChapterCount = chapters.count
            try? bookshelfViewModel?.modelContext.save()
            bookshelfViewModel?.loadBooks()
        }
    }
}

/// SwiftData stores the directory as one JSON string. A malformed source can attach a large
/// runtime payload to every chapter, making an otherwise valid directory hundreds of megabytes.
/// Estimate the encoded size without constructing that JSON so a cache write can never abort the
/// reader for a non-essential optimization.
enum TocCachePolicy {
    static let maximumEstimatedBytes = 8 * 1024 * 1024
    private static let maximumChapterCount = 100_000

    nonisolated static func shouldPersist(_ chapters: [BookChapter]) -> Bool {
        guard chapters.count <= maximumChapterCount else { return false }

        var estimatedBytes = 2 // JSON array brackets
        for chapter in chapters {
            let addition = estimatedBytes.addingReportingOverflow(estimatedJSONBytes(for: chapter))
            if addition.overflow || addition.partialValue > maximumEstimatedBytes {
                return false
            }
            estimatedBytes = addition.partialValue
        }
        return true
    }

    nonisolated static func encodedDataIfSafe(
        _ chapters: [BookChapter],
        encoder: (() throws -> Data)? = nil
    ) -> Data? {
        guard shouldPersist(chapters) else { return nil }
        if let encoder {
            return try? encoder()
        }
        return try? JSONEncoder().encode(chapters)
    }

    nonisolated private static func estimatedJSONBytes(for chapter: BookChapter) -> Int {
        var size = 96 // object keys, punctuation, booleans and numeric fields
        size += estimatedBytes(for: chapter.title)
        size += estimatedBytes(for: chapter.url)
        size += estimatedBytes(for: chapter.baseUrl)
        size += estimatedBytes(for: chapter.bookUrl)
        size += estimatedBytes(for: chapter.updateTime ?? "")
        size += estimatedBytes(for: chapter.sourceVariables)
        size += estimatedBytes(for: chapter.bookVariables)
        size += estimatedBytes(for: chapter.chapterVariables)
        size += estimatedBytes(for: chapter.variables)
        return size
    }

    nonisolated private static func estimatedBytes(for values: [String: String]) -> Int {
        values.reduce(into: 2) { total, entry in
            total += estimatedBytes(for: entry.key)
            total += estimatedBytes(for: entry.value)
            total += 4
        }
    }

    nonisolated private static func estimatedBytes(for value: String) -> Int {
        // JSON escaping can expand quotes, backslashes and control characters. Two bytes per
        // UTF-8 byte is conservative while avoiding a second copy of the source string.
        let multiplication = value.utf8.count.multipliedReportingOverflow(by: 2)
        guard !multiplication.overflow,
              multiplication.partialValue <= Int.max - 4 else {
            return Int.max
        }
        return multiplication.partialValue + 4
    }
}
