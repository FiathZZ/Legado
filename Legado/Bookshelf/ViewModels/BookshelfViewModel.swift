import Foundation
import SwiftData
import Combine
import SwiftUI

enum BookshelfSortMode: Int, CaseIterable, Identifiable {
    case updateTime = 0
    case recentRead = 1
    case addedTime = 2
    case bookName = 3
    case manual = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .updateTime:
            return "更新时间"
        case .recentRead:
            return "最近阅读"
        case .addedTime:
            return "添加时间"
        case .bookName:
            return "书名"
        case .manual:
            return "手动排序"
        }
    }

    var subtitle: String {
        switch self {
        case .updateTime:
            return "按最新章节更新时间"
        case .recentRead:
            return "最近阅读的书优先"
        case .addedTime:
            return "最近加入书架优先"
        case .bookName:
            return "按书名排序"
        case .manual:
            return "按拖拽结果排序"
        }
    }
}

// MARK: - 书架 ViewModel
@MainActor
final class BookshelfViewModel: ObservableObject {
    private enum Constants {
        static let sortModeKey = "Legado.Bookshelf.SortMode"
    }

    // MARK: 状态
    @Published var books: [BookEntity] = []
    @Published private(set) var displayBooks: [BookEntity] = []
    @Published private(set) var groups: [BookGroup] = []
    @Published var isCheckingUpdates: Bool = false
    @Published var updatedCount: Int = 0
    @Published var isEditing: Bool = false
    @Published private(set) var selectedBookURLs: Set<String> = []
    @Published var selectedGroupID: Int64? = nil {
        didSet {
            guard oldValue != selectedGroupID else { return }
            applyPresentation()
        }
    }
    @Published var sortMode: BookshelfSortMode = .updateTime {
        didSet {
            guard oldValue != sortMode else { return }
            UserDefaults.standard.set(sortMode.rawValue, forKey: Constants.sortModeKey)
            applyPresentation()
        }
    }

    // MARK: 配置
    /// 检查更新时的最大并发数
    var maxUpdateConcurrency: Int = 3

    private(set) var modelContext: ModelContext
    private var cancellables: Set<AnyCancellable> = []

    // MARK: 初始化
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let storedMode = BookshelfSortMode(rawValue: UserDefaults.standard.integer(forKey: Constants.sortModeKey)) {
            self.sortMode = storedMode
        }
        NotificationCenter.default.publisher(for: .bookshelfDataDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadBooks()
            }
            .store(in: &cancellables)
        loadBooks()
    }

    // MARK: 加载书架
    func loadBooks() {
        let bookDescriptor = FetchDescriptor<BookEntity>()
        books = (try? modelContext.fetch(bookDescriptor)) ?? []
        selectedBookURLs.formIntersection(Set(books.map(\.bookUrl)))

        let groupDescriptor = FetchDescriptor<BookGroup>(
            sortBy: [
                SortDescriptor(\.order, order: .forward),
                SortDescriptor(\.groupName, order: .forward)
            ]
        )
        groups = (try? modelContext.fetch(groupDescriptor)) ?? []

        if let selectedGroupID,
           !visibleGroups.contains(where: { $0.groupId == selectedGroupID }) {
            self.selectedGroupID = nil
        } else {
            applyPresentation()
        }
    }

    // MARK: 书架展示状态
    var visibleGroups: [BookGroup] {
        groups.filter(\.show)
    }

    var hasShelfBooks: Bool {
        !books.isEmpty
    }

    var selectedGroupName: String {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.groupId == selectedGroupID }) else {
            return "全部"
        }
        return group.groupName
    }

    var activeSortMode: BookshelfSortMode {
        resolvedSortMode
    }

    func selectGroup(_ groupID: Int64?) {
        selectedGroupID = groupID
    }

    // MARK: 分组管理
    @discardableResult
    func createGroup(named name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        let nextGroupID = BookGroup.nextGroupID(existingIDs: groups.map(\.groupId))
        guard nextGroupID > 0 else { return false }

        let nextOrder = (groups.map(\.order).max() ?? -1) + 1
        modelContext.insert(
            BookGroup(
                groupId: nextGroupID,
                groupName: trimmedName,
                order: nextOrder
            )
        )
        try? modelContext.save()
        loadBooks()
        return true
    }

    func renameGroup(_ group: BookGroup, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != group.groupName else { return }
        group.groupName = trimmedName
        try? modelContext.save()
        loadBooks()
    }

    func setGroupVisibility(_ group: BookGroup, isVisible: Bool) {
        guard group.show != isVisible else { return }
        group.show = isVisible
        if !isVisible, selectedGroupID == group.groupId {
            selectedGroupID = nil
        }
        try? modelContext.save()
        loadBooks()
    }

    func deleteGroup(_ group: BookGroup) {
        books.forEach { $0.removeGroup(group.groupId) }
        if selectedGroupID == group.groupId {
            selectedGroupID = nil
        }
        modelContext.delete(group)
        try? modelContext.save()
        loadBooks()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var reorderedGroups = groups
        reorderedGroups.move(fromOffsets: source, toOffset: destination)
        for (index, group) in reorderedGroups.enumerated() {
            group.order = index
        }
        try? modelContext.save()
        loadBooks()
    }

    func setGroupSortMode(_ mode: BookshelfSortMode?, for group: BookGroup) {
        group.bookSort = mode?.rawValue
        try? modelContext.save()
        loadBooks()
    }

    func toggleGroup(_ groupID: Int64, for book: BookEntity) {
        if book.hasGroup(groupID) {
            book.removeGroup(groupID)
        } else {
            book.addGroup(groupID)
        }
        try? modelContext.save()
        loadBooks()
    }

    // MARK: 批量编辑
    var selectedBooks: [BookEntity] {
        books.filter { selectedBookURLs.contains($0.bookUrl) }
    }

    var hasSelection: Bool {
        !selectedBookURLs.isEmpty
    }

    var isAllDisplayBooksSelected: Bool {
        !displayBooks.isEmpty && Set(displayBooks.map(\.bookUrl)).isSubset(of: selectedBookURLs)
    }

    func enterEditMode() {
        isEditing = true
        selectedBookURLs.removeAll()
    }

    func exitEditMode() {
        isEditing = false
        selectedBookURLs.removeAll()
    }

    func toggleSelection(for book: BookEntity) {
        if selectedBookURLs.contains(book.bookUrl) {
            selectedBookURLs.remove(book.bookUrl)
        } else {
            selectedBookURLs.insert(book.bookUrl)
        }
    }

    func toggleSelectAllDisplayBooks() {
        let displayBookURLs = Set(displayBooks.map(\.bookUrl))
        guard !displayBookURLs.isEmpty else { return }
        if displayBookURLs.isSubset(of: selectedBookURLs) {
            selectedBookURLs.subtract(displayBookURLs)
        } else {
            selectedBookURLs.formUnion(displayBookURLs)
        }
    }

    func deleteSelectedBooks() {
        let booksToDelete = selectedBooks
        guard !booksToDelete.isEmpty else { return }
        removeBooksAndCaches(booksToDelete)
        exitEditMode()
    }

    func isGroupAppliedToAllSelectedBooks(_ groupID: Int64) -> Bool {
        let books = selectedBooks
        guard !books.isEmpty else { return false }
        return books.allSatisfy { $0.hasGroup(groupID) }
    }

    func toggleGroupForSelectedBooks(_ groupID: Int64) {
        let books = selectedBooks
        guard !books.isEmpty else { return }
        let shouldRemove = isGroupAppliedToAllSelectedBooks(groupID)
        for book in books {
            if shouldRemove {
                book.removeGroup(groupID)
            } else {
                book.addGroup(groupID)
            }
        }
        try? modelContext.save()
        loadBooks()
        exitEditMode()
    }

    // MARK: 自定义书籍信息
    func updateCustomInfo(
        for book: BookEntity,
        customCoverUrl: String,
        customIntro: String,
        customTag: String
    ) {
        book.customCoverUrl = normalizeOptionalText(customCoverUrl)
        book.customIntro = normalizeOptionalText(customIntro)
        book.customTag = normalizeOptionalText(customTag)
        try? modelContext.save()
        loadBooks()
    }

    func resetCustomInfo(for book: BookEntity) {
        book.customCoverUrl = nil
        book.customIntro = nil
        book.customTag = nil
        try? modelContext.save()
        loadBooks()
    }

    // MARK: 加入书架
    func addBook(detail: BookDetail, sourceUrl: String) {
        let detailURL = detail.bookUrl
        let predicate = #Predicate<BookEntity> { $0.bookUrl == detailURL }
        var descriptor = FetchDescriptor<BookEntity>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.update(from: detail)
            if existing.manualOrder == 0 {
                existing.manualOrder = nextManualOrder()
            }
        } else {
            let entity = BookEntity(detail: detail, sourceUrl: sourceUrl)
            entity.manualOrder = nextManualOrder()
            modelContext.insert(entity)
        }

        try? modelContext.save()
        loadBooks()
    }

    // MARK: 是否已在书架
    func isInShelf(bookUrl: String) -> Bool {
        books.contains { $0.bookUrl == bookUrl }
    }

    // MARK: 获取书架中的书籍实体
    func bookEntity(for bookUrl: String) -> BookEntity? {
        books.first { $0.bookUrl == bookUrl }
    }

    // MARK: 移除书籍
    func removeBook(_ entity: BookEntity) {
        removeBooksAndCaches([entity])
    }

    /// Removes the shelf records and all offline data associated with each record. Keeping this
    /// in the view model makes swipe deletion, batch deletion, and reader-menu removal share the
    /// same cleanup contract.
    private func removeBooksAndCaches(_ entities: [BookEntity]) {
        guard !entities.isEmpty else { return }

        for entity in entities {
            clearCaches(for: entity)
            modelContext.delete(entity)
        }
        try? modelContext.save()
        loadBooks()
    }

    /// Deletes both cache stores for a shelf entry before its identity is discarded.
    private func clearCaches(for entity: BookEntity) {
        ChapterCacheStore.clear(
            bookKey: ChapterCacheStore.makeKey(
                sourceUrl: entity.sourceUrl,
                bookUrl: entity.bookUrl
            )
        )
        deleteTocCache(for: entity.bookUrl)
    }

    /// Deletes the SwiftData TOC cache identified by the same book URL used while loading it.
    private func deleteTocCache(for bookUrl: String) {
        let cacheKey = TocCacheEntity.cacheKey(for: bookUrl)
        let predicate = #Predicate<TocCacheEntity> { entity in
            entity.cacheKey == cacheKey
        }
        let descriptor = FetchDescriptor<TocCacheEntity>(predicate: predicate)
        guard let cachedEntities = try? modelContext.fetch(descriptor) else { return }
        cachedEntities.forEach(modelContext.delete)
    }

    // MARK: 更新阅读进度
    func updateReadProgress(bookUrl: String, chapterIndex: Int, chapterName: String) {
        guard let entity = books.first(where: { $0.bookUrl == bookUrl }) else { return }
        entity.currentChapterIndex = chapterIndex
        entity.currentChapterName = chapterName
        entity.lastReadTime = .now
        entity.hasNewChapter = false
        try? modelContext.save()
        loadBooks()
    }

    /// 标记书籍已读，清除书架上的“有更新”角标。
    func markAsRead(bookUrl: String) {
        guard let entity = books.first(where: { $0.bookUrl == bookUrl }) else { return }
        guard entity.hasNewChapter else { return }
        entity.hasNewChapter = false
        try? modelContext.save()
        loadBooks()
    }

    /// 切换书籍书源并同步当前阅读定位。
    @discardableResult
    func changeBookSource(
        currentBookUrl: String,
        newDetail: BookDetail,
        newSource: BookSource,
        targetChapterIndex: Int,
        targetChapterName: String?,
        totalChapterCount: Int
    ) -> BookEntity? {
        let currentEntity = books.first(where: { $0.bookUrl == currentBookUrl })
        let duplicateEntity = books.first(where: {
            $0.bookUrl == newDetail.bookUrl && $0.bookUrl != currentBookUrl
        })

        let entity: BookEntity
        if let currentEntity {
            if let duplicateEntity, duplicateEntity !== currentEntity {
                duplicateEntity.addedTime = min(duplicateEntity.addedTime, currentEntity.addedTime)
                duplicateEntity.group |= currentEntity.group
                duplicateEntity.manualOrder = min(duplicateEntity.manualOrder, currentEntity.manualOrder)
                clearCaches(for: currentEntity)
                modelContext.delete(currentEntity)
                entity = duplicateEntity
            } else {
                entity = currentEntity
            }
        } else if let duplicateEntity {
            entity = duplicateEntity
        } else {
            let created = BookEntity(detail: newDetail, sourceUrl: newSource.bookSourceUrl)
            modelContext.insert(created)
            entity = created
        }

        entity.bookUrl = newDetail.bookUrl
        entity.name = newDetail.name
        entity.author = newDetail.author
        entity.coverUrl = newDetail.coverUrl
        entity.intro = newDetail.intro
        entity.kind = newDetail.kind
        entity.wordCount = newDetail.wordCount
        entity.lastChapter = newDetail.lastChapter
        entity.updateTime = newDetail.updateTime
        entity.tocUrl = newDetail.tocUrl
        entity.sourceUrl = newSource.bookSourceUrl
        entity.currentChapterIndex = targetChapterIndex
        entity.currentChapterName = targetChapterName
        entity.totalChapterCount = totalChapterCount
        entity.lastReadTime = .now
        entity.hasNewChapter = false
        if entity.manualOrder == 0 {
            entity.manualOrder = nextManualOrder()
        }

        try? modelContext.save()
        loadBooks()
        return books.first(where: { $0.bookUrl == newDetail.bookUrl })
    }

    // MARK: 检查所有书籍更新（启动时调用）
    /// 并发检查书架中所有书籍是否有新章节，最大并发数由 maxUpdateConcurrency 控制
    func checkUpdates(allSources: [BookSource]) async {
        guard !books.isEmpty else { return }
        isCheckingUpdates = true
        updatedCount = 0
        defer { isCheckingUpdates = false }

        struct BookSnapshot: Sendable {
            let bookURL: String
            let lastChapter: String?
            let sourceURL: String
        }

        let snapshots = books.map {
            BookSnapshot(bookURL: $0.bookUrl, lastChapter: $0.lastChapter, sourceURL: $0.sourceUrl)
        }

        let semaphore = AsyncSemaphore(max: maxUpdateConcurrency)
        var updatedDetails: [(bookURL: String, detail: BookDetail)] = []

        await withTaskGroup(of: (String, BookDetail)?.self) { group in
            for snapshot in snapshots {
                group.addTask {
                    var acquiredPermit = false
                    do {
                        try await semaphore.acquire()
                        acquiredPermit = true

                        guard !Task.isCancelled else {
                            if acquiredPermit {
                                await semaphore.release()
                            }
                            return nil
                        }

                        guard let source = allSources.first(where: { $0.bookSourceUrl == snapshot.sourceURL }),
                              source.enabled else {
                            if acquiredPermit {
                                await semaphore.release()
                            }
                            return nil
                        }

                        let webBook = WebBook(bookSource: source)
                        defer { webBook.shutdown() }
                        let detail = try await webBook.getBookInfo(bookUrl: snapshot.bookURL)
                        if acquiredPermit {
                            await semaphore.release()
                            acquiredPermit = false
                        }
                        if detail.lastChapter != snapshot.lastChapter {
                            return (snapshot.bookURL, detail)
                        }
                    } catch {
                        if acquiredPermit {
                            await semaphore.release()
                        }
                    }
                    return nil
                }
            }

            for await result in group {
                if let pair = result {
                    updatedDetails.append((bookURL: pair.0, detail: pair.1))
                }
            }
        }

        for pair in updatedDetails {
            if let entity = books.first(where: { $0.bookUrl == pair.bookURL }) {
                entity.update(from: pair.detail)
                entity.hasNewChapter = true
                updatedCount += 1
            }
        }
        if !updatedDetails.isEmpty {
            try? modelContext.save()
        }
        loadBooks()
    }

    func moveDisplayBooks(from source: IndexSet, to destination: Int) {
        var allBooksInManualOrder = books.sorted { lhs, rhs in
            compareManualOrder(lhs: lhs, rhs: rhs)
        }
        let displayIDs = Set(displayBooks.map(\.bookUrl))
        guard !displayIDs.isEmpty else { return }

        var visibleBooks = allBooksInManualOrder.filter { displayIDs.contains($0.bookUrl) }
        visibleBooks.move(fromOffsets: source, toOffset: destination)

        var iterator = visibleBooks.makeIterator()
        for index in allBooksInManualOrder.indices {
            guard displayIDs.contains(allBooksInManualOrder[index].bookUrl),
                  let nextVisibleBook = iterator.next() else {
                continue
            }
            allBooksInManualOrder[index] = nextVisibleBook
        }

        for (index, book) in allBooksInManualOrder.enumerated() {
            book.manualOrder = index
        }
        try? modelContext.save()
        loadBooks()
    }

    private func applyPresentation() {
        let filteredBooks: [BookEntity]
        if let selectedGroupID {
            filteredBooks = books.filter { $0.hasGroup(selectedGroupID) }
        } else {
            filteredBooks = books
        }

        let effectiveSortMode = resolvedSortMode
        displayBooks = filteredBooks.sorted { lhs, rhs in
            sortBooks(lhs: lhs, rhs: rhs, mode: effectiveSortMode)
        }
    }

    private var resolvedSortMode: BookshelfSortMode {
        guard let selectedGroupID,
              let overrideRawValue = groups.first(where: { $0.groupId == selectedGroupID })?.bookSort,
              let overrideMode = BookshelfSortMode(rawValue: overrideRawValue) else {
            return sortMode
        }
        return overrideMode
    }

    private func sortBooks(lhs: BookEntity, rhs: BookEntity, mode: BookshelfSortMode) -> Bool {
        switch mode {
        case .recentRead:
            if compareRecentRead(lhs: lhs, rhs: rhs) {
                return true
            }
            if compareRecentRead(lhs: rhs, rhs: lhs) {
                return false
            }
            return compareManualOrder(lhs: lhs, rhs: rhs)
        case .addedTime:
            if lhs.addedTime != rhs.addedTime {
                return lhs.addedTime > rhs.addedTime
            }
            return compareManualOrder(lhs: lhs, rhs: rhs)
        case .bookName:
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison == .orderedSame {
                return compareManualOrder(lhs: lhs, rhs: rhs)
            }
            return comparison == .orderedAscending
        case .manual:
            return compareManualOrder(lhs: lhs, rhs: rhs)
        case .updateTime:
            if compareUpdateActivity(lhs: lhs, rhs: rhs) {
                return true
            }
            if compareUpdateActivity(lhs: rhs, rhs: lhs) {
                return false
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func compareUpdateActivity(lhs: BookEntity, rhs: BookEntity) -> Bool {
        let lhsDate = lhs.lastReadTime ?? lhs.addedTime
        let rhsDate = rhs.lastReadTime ?? rhs.addedTime
        return lhsDate > rhsDate
    }

    private func compareRecentRead(lhs: BookEntity, rhs: BookEntity) -> Bool {
        let lhsDate = lhs.lastReadTime ?? .distantPast
        let rhsDate = rhs.lastReadTime ?? .distantPast
        return lhsDate > rhsDate
    }

    private func compareManualOrder(lhs: BookEntity, rhs: BookEntity) -> Bool {
        if lhs.manualOrder != rhs.manualOrder {
            return lhs.manualOrder < rhs.manualOrder
        }
        if lhs.addedTime != rhs.addedTime {
            return lhs.addedTime < rhs.addedTime
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func nextManualOrder() -> Int {
        (books.map(\.manualOrder).max() ?? -1) + 1
    }

    private func normalizeOptionalText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - AsyncSemaphore
/// 基于 actor 的异步信号量，用于控制并发任务数
actor AsyncSemaphore {
    private let max: Int
    private var current: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(max: Int) {
        self.max = max
    }

    func acquire() async throws {
        try Task.checkCancellation()

        if current < max {
            current += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        } else if current > 0 {
            current -= 1
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
