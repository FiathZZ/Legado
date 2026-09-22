import Foundation
import Combine
import SwiftData

/// Visual state for the native reader's full-book cache action.
///
/// The completed state is only published after every chapter has a nonempty persisted cache
/// file. It is kept separate from the incremental chapter cache actions so the top-bar action
/// always reflects the complete-book contract.
enum ReaderBookCacheState: Equatable {
    case unavailable
    case available
    case downloading
    case completed

    static func resolve(isDownloading: Bool, isEntireBookCached: Bool, hasCompleteTableOfContents: Bool) -> Self {
        if isDownloading {
            return .downloading
        }
        if isEntireBookCached { return .completed }
        return hasCompleteTableOfContents ? .available : .unavailable
    }
}

// MARK: - 章节缓存条目
struct CachedChapter {
    var chapter: BookChapter
    var content: String?
    var mediaURLs: [String] = []
    var contentType: String = "text"
    var isLoading: Bool = false
    var error: String? = nil
}

struct BookSearchResult: Identifiable, Hashable {
    let chapterIndex: Int
    let chapterName: String
    let snippet: String

    var id: String {
        "\(chapterIndex)-\(chapterName)-\(snippet)"
    }
}

struct ReadAloudPayload: Sendable {
    let chapterTitle: String
    let text: String
}

// MARK: - 阅读器 ViewModel
@MainActor
final class ReaderViewModel: ObservableObject {

    // MARK: 状态
    @Published var currentIndex: Int
    @Published var cachedChapters: [Int: CachedChapter] = [:]
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var downloadProgress: Double? = nil
    @Published var isDownloading: Bool = false
    @Published var isEntireBookCached: Bool = false
    @Published var showChangeSource: Bool = false
    @Published var showBookmarkList: Bool = false
    @Published var showBookSearch: Bool = false
    @Published var toastMessage: String? = nil

    // MARK: 数据
    @Published private(set) var chapters: [BookChapter]
    let source: BookSource
    let bookName: String
    let bookAuthor: String
    let prefetchedBook: SearchBook?
    @Published private(set) var hasCompleteTableOfContents: Bool
    let bookEntity: BookEntity?
    var allSources: [BookSource]
    var onChangeSource: ((ChangeSourceSelection) -> Void)?
    private let modelContext: ModelContext?
    private let chapterCacheKey: String
    private let contentService: ReaderContentService
    private let progressService = ReaderProgressService()
    private let bookmarkService: ReaderBookmarkService
    private var cancellables: Set<AnyCancellable> = []

    var currentChapter: BookChapter? {
        guard currentIndex < chapters.count else { return nil }
        return chapters[currentIndex]
    }

    var currentBookURL: String {
        bookEntity?.bookUrl ?? chapters.first?.bookUrl ?? ""
    }

    var currentContent: String? {
        cachedChapters[currentIndex]?.content
    }

    var isAudioSource: Bool {
        source.bookSourceType == 1
    }

    var currentAudioChapter: AudioChapter? {
        guard isAudioSource,
              let cached = cachedChapters[currentIndex],
              let urlString = cached.mediaURLs.first ?? cached.content,
              let url = URL(string: urlString),
              !urlString.isEmpty else {
            return nil
        }
        return AudioChapter(id: currentIndex, title: chapters[currentIndex].title, url: url)
    }

    var isCurrentLoading: Bool {
        cachedChapters[currentIndex]?.isLoading ?? false
    }

    var entireBookCacheState: ReaderBookCacheState {
        ReaderBookCacheState.resolve(
            isDownloading: isDownloading,
            isEntireBookCached: isEntireBookCached,
            hasCompleteTableOfContents: hasCompleteTableOfContents
        )
    }

    // MARK: 初始化
    init(
        chapters: [BookChapter],
        source: BookSource,
        startIndex: Int = 0,
        bookEntity: BookEntity? = nil,
        modelContext: ModelContext? = nil,
        bookName: String,
        bookAuthor: String,
        allSources: [BookSource] = [],
        prefetchedBook: SearchBook? = nil,
        hasCompleteTableOfContents: Bool = true
    ) {
        let initialIndex = min(startIndex, max(0, chapters.count - 1))
        self.chapters = chapters
        self.source = source
        self.currentIndex = initialIndex
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        self.prefetchedBook = prefetchedBook
        self.hasCompleteTableOfContents = hasCompleteTableOfContents
        self.bookEntity = bookEntity
        self.allSources = allSources
        self.modelContext = modelContext
        let resolvedBookUrl = bookEntity?.bookUrl ?? chapters.first?.bookUrl ?? ""
        self.chapterCacheKey = ChapterCacheStore.makeKey(sourceUrl: source.bookSourceUrl, bookUrl: resolvedBookUrl)
        self.contentService = ReaderContentService(
            chapters: chapters,
            source: source,
            bookName: bookName,
            chapterCacheKey: self.chapterCacheKey,
            initialIndex: initialIndex,
            modelContext: modelContext
        )
        self.bookmarkService = ReaderBookmarkService(modelContext: modelContext)
        bindServices()
    }

    // MARK: 加载当前章节
    func loadCurrentChapter() async {
        await contentService.loadCurrentChapter(at: currentIndex)
        refreshCurrentError()
    }

    /// Replaces a temporary cache-only directory after the complete TOC arrives in background.
    func updateChapters(_ chapters: [BookChapter], hasCompleteTableOfContents: Bool? = nil) {
        guard !chapters.isEmpty else { return }
        self.chapters = chapters
        if let hasCompleteTableOfContents {
            self.hasCompleteTableOfContents = hasCompleteTableOfContents
        }
        contentService.updateChapters(chapters)
        currentIndex = min(currentIndex, chapters.count - 1)
    }

    // MARK: 跳转章节
    func goTo(index: Int, persistProgress: Bool = true) async {
        guard index >= 0, index < chapters.count else { return }
        currentIndex = index
        if persistProgress {
            saveReadingProgress()
        }
        await loadCurrentChapter()
    }

    func goNext() async {
        guard currentIndex + 1 < chapters.count else { return }
        await goTo(index: currentIndex + 1)
    }

    func goPrev() async {
        guard currentIndex > 0 else { return }
        await goTo(index: currentIndex - 1)
    }

    // MARK: 加载指定章节
    func loadChapter(at index: Int) async {
        await contentService.loadChapter(at: index)
        refreshCurrentError()
    }

    // MARK: 下载缓存
    func downloadChapters(count: Int?) async {
        await contentService.downloadChapters(from: currentIndex, count: count)
    }

    /// Downloads the complete table of contents from the first chapter, regardless of where the
    /// reader is currently positioned.
    func downloadEntireBook() async -> Bool {
        guard hasCompleteTableOfContents else {
            showUserMessage("目录未完整加载，不能缓存整本书")
            return false
        }
        await contentService.downloadEntireBook()
        return isEntireBookCached
    }

    // MARK: 下载选项（过滤不满足数量的选项）
    var downloadOptions: [(label: String, count: Int?)] {
        contentService.downloadOptions(for: currentIndex)
    }

    // MARK: 换源
    func changeSource(_ selection: ChangeSourceSelection) {
        contentService.clearChapterCache()
        onChangeSource?(selection)
    }

    // MARK: 书签
    @discardableResult
    func addBookmark(position: ReaderPosition? = nil, pageText: String? = nil) -> BookmarkEntity? {
        let bookmark = bookmarkService.addBookmark(
            bookUrl: currentBookURL,
            chapterIndex: currentIndex,
            pageIndex: position?.pageIndex,
            utf16Offset: position?.utf16Offset,
            chapterName: currentChapter?.title ?? "未知章节",
            pageText: pageText,
            currentContent: currentContent
        )
        guard let bookmark else { return nil }
        showToast("已添加书签")
        return bookmark
    }

    func bookmarks() -> [BookmarkEntity] {
        bookmarkService.bookmarks(for: currentBookURL)
    }

    func deleteBookmarks(at offsets: IndexSet, in bookmarks: [BookmarkEntity]) {
        bookmarkService.deleteBookmarks(at: offsets, in: bookmarks)
    }

    // MARK: 书内搜索
    func searchCachedChapters(keyword: String) -> [BookSearchResult] {
        contentService.searchCachedChapters(keyword: keyword)
    }

    func jumpToChapter(index: Int) async {
        await goTo(index: index)
    }

    func loadReadAloudPayload(startingAt startOffset: Int? = nil) async -> ReadAloudPayload? {
        await contentService.makeReadAloudPayload(for: currentIndex, startingAt: startOffset)
    }

    func advanceToNextChapterForReadAloud() async -> ReadAloudPayload? {
        guard currentIndex + 1 < chapters.count else { return nil }
        await goTo(index: currentIndex + 1)
        return await loadReadAloudPayload()
    }

    // MARK: 保存阅读进度
    func saveReadingProgress(position: ReaderPosition? = nil) {
        progressService.saveReadingProgress(
            bookEntity: bookEntity,
            chapters: chapters,
            currentIndex: currentIndex,
            currentPosition: position,
            bookURL: currentBookURL,
            modelContext: modelContext
        )
    }

    func restoredReadingPosition() -> ReaderPosition {
        let restored = progressService.restoreReadingProgress(
            bookURL: currentBookURL,
            fallbackChapterIndex: currentIndex
        )
        guard restored.chapterIndex == currentIndex else {
            return ReaderPosition(chapterIndex: currentIndex)
        }
        return restored
    }

    func showUserMessage(_ message: String) {
        showToast(message)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self?.toastMessage == message else { return }
            self?.toastMessage = nil
        }
    }

    private func bindServices() {
        contentService.$cachedChapters
            .sink { [weak self] chapters in
                self?.cachedChapters = chapters
                self?.refreshCurrentError()
            }
            .store(in: &cancellables)

        contentService.$downloadProgress
            .assign(to: &$downloadProgress)

        contentService.$isDownloading
            .assign(to: &$isDownloading)

        contentService.$isEntireBookCached
            .assign(to: &$isEntireBookCached)
    }

    private func refreshCurrentError() {
        errorMessage = cachedChapters[currentIndex]?.error
    }
}
