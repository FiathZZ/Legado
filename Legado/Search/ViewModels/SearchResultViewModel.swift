import Foundation
import Combine

nonisolated enum SearchMatchMode: String, CaseIterable, Identifiable, Sendable {
    case contains
    case exact

    static let defaultValue: Self = .contains

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: "搜索"
        case .exact: "精准搜索"
        }
    }
}

nonisolated struct SourceSearchOutcome: Identifiable, Sendable {
    enum Status: Sendable {
        case found(Int)
        case empty
        case failed(String)
    }

    let sourceURL: String
    let sourceName: String
    let status: Status
    let books: [SearchBook]

    var id: String { sourceURL }
}

nonisolated struct SourceOperationTimeoutError: LocalizedError, Sendable {
    let seconds: Int

    var errorDescription: String? {
        "书源操作超时（超过 \(seconds) 秒），已停止该书源"
    }
}

/// Returns at the deadline even when a third-party rule or WebView ignores cooperative
/// cancellation. Callers must also shut down the owning WebBook after a timeout.
nonisolated enum SourceOperationDeadline {
    nonisolated static func run<Value: Sendable>(
        seconds: Int,
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let coordinator = Coordinator<Value>(seconds: seconds, priority: priority)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await coordinator.start(operation: operation, continuation: continuation)
                }
            }
        }, onCancel: {
            Task {
                await coordinator.cancel()
            }
        })
    }

    private actor Coordinator<Value: Sendable> {
        private let seconds: Int
        private let priority: TaskPriority
        private var continuation: CheckedContinuation<Value, Error>?
        private var operationTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var isCancelled = false

        init(seconds: Int, priority: TaskPriority) {
            self.seconds = seconds
            self.priority = priority
        }

        func start(
            operation: @escaping @Sendable () async throws -> Value,
            continuation: CheckedContinuation<Value, Error>
        ) {
            guard !isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }

            self.continuation = continuation
            operationTask = Task.detached(priority: priority) { [weak self] in
                do {
                    let value = try await operation()
                    await self?.finish(.success(value), cancelOperation: false)
                } catch {
                    await self?.finish(.failure(error), cancelOperation: false)
                }
            }
            timeoutTask = Task(priority: .utility) { [weak self, seconds] in
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                await self?.timeout()
            }
        }

        func cancel() {
            isCancelled = true
            finish(.failure(CancellationError()), cancelOperation: true)
        }

        private func timeout() {
            finish(
                .failure(SourceOperationTimeoutError(seconds: seconds)),
                cancelOperation: true
            )
        }

        private func finish(_ result: Result<Value, Error>, cancelOperation: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            if cancelOperation {
                operationTask?.cancel()
            }
            operationTask = nil
            continuation.resume(with: result)
        }
    }
}

/// A prepared snapshot that can be assigned to SwiftUI state without performing result work on
/// the main actor. SearchBook is already Sendable because it crosses the source task group.
private nonisolated struct SourceSearchSnapshot: Sendable {
    let results: [SearchBook]
    let outcomes: [SourceSearchOutcome]
    let finishedSources: Int
}

/// Owns result deduplication and ordering for one search. This actor deliberately keeps large
/// result-array work off SearchResultViewModel's MainActor while preserving completion ordering.
private actor SourceSearchResultAccumulator {
    private var results: [SearchBook] = []
    private var outcomes: [SourceSearchOutcome] = []
    private var finishedSources = 0

    func append(_ outcome: SourceSearchOutcome, keyword: String) -> SourceSearchSnapshot {
        results = Self.mergeAndSort(existing: results, incoming: outcome.books, keyword: keyword)
        outcomes.append(outcome)
        finishedSources += 1
        return snapshot()
    }

    func snapshot() -> SourceSearchSnapshot {
        SourceSearchSnapshot(
            results: results,
            outcomes: outcomes,
            finishedSources: finishedSources
        )
    }

    private static func mergeAndSort(
        existing: [SearchBook],
        incoming: [SearchBook],
        keyword: String
    ) -> [SearchBook] {
        var merged: [String: SearchBook] = [:]
        for book in existing + incoming {
            let key = "\(book.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{1F}\(book.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            var candidate = book
            if candidate.sourceOrigins.isEmpty {
                candidate.sourceOrigins = [Self.origin(from: book)]
            }

            guard var existing = merged[key] else {
                merged[key] = candidate
                continue
            }

            for source in candidate.sourceOrigins where !existing.sourceOrigins.contains(source) {
                existing.sourceOrigins.append(source)
            }
            merged[key] = existing
        }

        let normalizedKeyword = keyword.lowercased()
        return merged.values.sorted { left, right in
            let leftScore = Self.matchScore(left, keyword: normalizedKeyword)
            let rightScore = Self.matchScore(right, keyword: normalizedKeyword)
            if leftScore != rightScore {
                return leftScore < rightScore
            }
            if left.sourceOrigins.count != right.sourceOrigins.count {
                return left.sourceOrigins.count > right.sourceOrigins.count
            }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
    }

    private static func origin(from book: SearchBook) -> SearchBookOrigin {
        SearchBookOrigin(
            url: book.origin,
            name: book.sourceName,
            bookUrl: book.bookUrl,
            infoHtml: book.infoHtml,
            sourceVariables: book.sourceVariables,
            bookVariables: book.bookVariables,
            variables: book.variables
        )
    }

    private static func matchScore(_ book: SearchBook, keyword: String) -> Int {
        let name = book.name.lowercased()
        let author = book.author.lowercased()
        if name == keyword { return 0 }
        if author == keyword { return 1 }
        if name.hasPrefix(keyword) { return 2 }
        if author.hasPrefix(keyword) { return 3 }
        return 4
    }
}

// MARK: - 搜索结果 ViewModel
/// 并发从多个书源搜索。
///
/// 规则解析包含 HTML 与 JavaScript 的同步计算；使用与 Android `AppConst.MAX_THREAD`
/// 一致的受控线程池上限。单个书源仍有超时和其自身的并发/限速配置。
@MainActor
final class SearchResultViewModel: ObservableObject {

    private static let defaultMaxConcurrency = 6
    private static let maximumConcurrency = 9
    private static let perSourceSearchTimeoutSeconds = 3
    private static let resultPublishDelayNanoseconds: UInt64 = 200_000_000

    // MARK: 状态
    @Published var results: [SearchBook] = []
    @Published var isSearching: Bool = false
    @Published var finishedSources: Int = 0
    @Published var totalSources: Int = 0
    @Published var errorMessage: String? = nil
    @Published var sourceOutcomes: [SourceSearchOutcome] = []

    // MARK: 配置
    /// 最大并发搜索数。默认 6、最多 9，与 Android 的 AppConst.MAX_THREAD 对齐。
    var maxConcurrency: Int {
        get {
            let configured = UserDefaults.standard
                .integer(forKey: "SearchMaxConcurrency")
                .nonZeroOrDefault(Self.defaultMaxConcurrency)
            return min(max(configured, 1), Self.maximumConcurrency)
        }
        set {
            UserDefaults.standard.set(
                min(max(newValue, 1), Self.maximumConcurrency),
                forKey: "SearchMaxConcurrency"
            )
        }
    }

    private var searchTask: Task<Void, Never>?
    private var activeSearchID: UUID?
    private var currentSearchKeyword = ""
    private var pendingSnapshot: SourceSearchSnapshot?
    private var resultPublishTask: Task<Void, Never>?
    private let inFlightWebBooks = InFlightWebBookRegistry()

    deinit {
        let registry = inFlightWebBooks
        searchTask?.cancel()
        resultPublishTask?.cancel()
        Task {
            await registry.shutdownAll()
        }
        Task { @MainActor in
            ParserLog.debug("SearchResultViewModel", "deinit called")
        }
    }

    // MARK: 搜索入口
    func search(
        keyword: String,
        sources: [BookSource],
        matchMode: SearchMatchMode = SearchMatchMode.defaultValue
    ) {
        // 取消上次未完成的搜索
        searchTask?.cancel()
        Task {
            await inFlightWebBooks.shutdownAll()
        }
        cleanupTransientResources()

        let searchID = UUID()
        activeSearchID = searchID
        currentSearchKeyword = keyword

        let enabledSources = sources.filter { $0.enabled && $0.searchUrl != nil }
        guard !enabledSources.isEmpty else {
            errorMessage = "没有可用的书源，请先在书源管理中导入并启用书源"
            activeSearchID = nil
            return
        }

        results = []
        sourceOutcomes = []
        finishedSources = 0
        pendingSnapshot = nil
        totalSources = enabledSources.count
        isSearching = true
        errorMessage = nil

        // 在创建 Task 前读取配置值，避免在 Task 内捕获 self 造成循环引用
        let concurrency = maxConcurrency
        let sourceTimeoutSeconds = Self.perSourceSearchTimeoutSeconds
        let semaphore = AsyncSemaphore(max: concurrency)
        let webBookRegistry = inFlightWebBooks
        let resultAccumulator = SourceSearchResultAccumulator()

        // 注意：不在此处 guard let self，避免 Task 闭包强引用 self 导致循环引用，
        // 使 deinit 永远不会被调用，从而阻止任务被取消。
        searchTask = Task { [weak self] in
            await withTaskGroup(of: SourceSearchOutcome.self) { group in
                for source in enabledSources {
                    group.addTask {
                        var acquiredPermit = false
                        do {
                            try await semaphore.acquire()
                            acquiredPermit = true

                            guard !Task.isCancelled else {
                                if acquiredPermit {
                                    await semaphore.release()
                                }
                                return SourceSearchOutcome(
                                    sourceURL: source.bookSourceUrl,
                                    sourceName: source.bookSourceName,
                                    status: .empty,
                                    books: []
                                )
                            }

                            let outcome = await Task.detached(priority: .userInitiated) {
                                await Self.searchSource(
                                    source: source,
                                    keyword: keyword,
                                    matchMode: matchMode,
                                    timeoutSeconds: sourceTimeoutSeconds,
                                    registry: webBookRegistry
                                )
                            }.value
                            if acquiredPermit {
                                await semaphore.release()
                                acquiredPermit = false
                            }
                            return outcome
                        } catch {
                            return SourceSearchOutcome(
                                sourceURL: source.bookSourceUrl,
                                sourceName: source.bookSourceName,
                                status: .failed(error.localizedDescription),
                                books: []
                            )
                        }
                    }
                }

                for await outcome in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    let snapshot = await resultAccumulator.append(outcome, keyword: keyword)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard self.activeSearchID == searchID else { return }
                        self.enqueue(snapshot, searchID: searchID)
                    }
                }

                if Task.isCancelled {
                    group.cancelAll()
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.activeSearchID == searchID else { return }
                self.publishPendingResults(searchID: searchID)
                self.isSearching = false
                self.searchTask = nil
                self.activeSearchID = nil
                self.cleanupTransientResources()
                if self.results.isEmpty {
                    let failureCount = self.sourceOutcomes.reduce(into: 0) { count, outcome in
                        if case .failed = outcome.status {
                            count += 1
                        }
                    }
                    self.errorMessage = failureCount == 0
                        ? "没有找到《\(keyword)》相关书籍"
                        : "没有找到《\(keyword)》相关书籍，\(failureCount) 个书源执行失败"
                }
            }
        }
    }

    /// Constructs the source runtime and runs parsing entirely outside the main actor. The UI
    /// task only receives the small, already-trimmed outcome produced here.
    private nonisolated static func searchSource(
        source: BookSource,
        keyword: String,
        matchMode: SearchMatchMode,
        timeoutSeconds: Int,
        registry: InFlightWebBookRegistry
    ) async -> SourceSearchOutcome {
        let webBook = WebBook(
            bookSource: source,
            maximumRequestTimeout: TimeInterval(timeoutSeconds)
        )
        await registry.insert(webBook)

        do {
            let allBooks = try await SourceOperationDeadline.run(seconds: timeoutSeconds) {
                try Task.checkCancellation()
                return try await webBook.searchBook(keyword: keyword)
            }
            let books = allBooks
                .filter { Self.matchesKeyword($0, keyword: keyword, mode: matchMode) }
                .map(Self.makeLightweightResult)
            await registry.shutdownAndRemove(webBook)
            return SourceSearchOutcome(
                sourceURL: source.bookSourceUrl,
                sourceName: source.bookSourceName,
                status: books.isEmpty ? .empty : .found(books.count),
                books: books
            )
        } catch {
            await registry.shutdownAndRemove(webBook)
            return SourceSearchOutcome(
                sourceURL: source.bookSourceUrl,
                sourceName: source.bookSourceName,
                status: .failed(error.localizedDescription),
                books: []
            )
        }
    }

    private func enqueue(_ snapshot: SourceSearchSnapshot, searchID: UUID) {
        pendingSnapshot = snapshot

        // Android 在单个书源完成后立即回传结果。首批命中直接显示，避免被慢书源或批处理延迟拖住。
        if results.isEmpty, !snapshot.results.isEmpty {
            publishPendingResults(searchID: searchID)
            return
        }

        guard resultPublishTask == nil else { return }
        resultPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.resultPublishDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.publishPendingResults(searchID: searchID)
        }
    }

    private func publishPendingResults(searchID: UUID) {
        guard activeSearchID == searchID else { return }
        resultPublishTask?.cancel()
        resultPublishTask = nil

        guard let snapshot = pendingSnapshot else { return }
        results = snapshot.results
        sourceOutcomes = snapshot.outcomes
        finishedSources = snapshot.finishedSources
        pendingSnapshot = nil
    }

    func stopSearch() {
        guard isSearching else { return }
        if let searchID = activeSearchID {
            publishPendingResults(searchID: searchID)
        }
        searchTask?.cancel()
        searchTask = nil
        activeSearchID = nil
        currentSearchKeyword = ""
        isSearching = false
        errorMessage = results.isEmpty ? "已停止搜索，尚未找到匹配书籍" : "已停止搜索，保留当前结果"
        Task {
            await inFlightWebBooks.shutdownAll()
        }
        cleanupTransientResources()
    }

    /// Stops work when this result screen is covered by a detail or reader screen.
    /// Keep only results already published to avoid a large pending snapshot being assigned on the UI executor.
    func stopSearchForNavigation() {
        guard isSearching else { return }
        searchTask?.cancel()
        searchTask = nil
        activeSearchID = nil
        currentSearchKeyword = ""
        resultPublishTask?.cancel()
        resultPublishTask = nil
        pendingSnapshot = nil
        isSearching = false

        let registry = inFlightWebBooks
        Task {
            await registry.shutdownAll()
        }
        cleanupTransientResources()
    }

    // MARK: 取消搜索
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        activeSearchID = nil
        resultPublishTask?.cancel()
        resultPublishTask = nil
        results.removeAll(keepingCapacity: false)
        sourceOutcomes.removeAll(keepingCapacity: false)
        finishedSources = 0
        pendingSnapshot = nil
        totalSources = 0
        errorMessage = nil
        isSearching = false
        Task {
            await inFlightWebBooks.shutdownAll()
        }
        cleanupTransientResources()
    }

    private nonisolated static func makeLightweightResult(_ book: SearchBook) -> SearchBook {
        var trimmed = book
        trimmed.infoHtml = nil
        return trimmed
    }

    nonisolated static func matchesKeyword(
        _ book: SearchBook,
        keyword: String,
        mode: SearchMatchMode
    ) -> Bool {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyword.isEmpty else { return false }

        switch mode {
        case .contains:
            return book.name.localizedCaseInsensitiveContains(normalizedKeyword)
                || book.author.localizedCaseInsensitiveContains(normalizedKeyword)
        case .exact:
            return book.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(normalizedKeyword) == .orderedSame
        }
    }

    private func cleanupTransientResources() {
        HeadlessWebView.shared.purge()
    }
}

// MARK: - Int helper
private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int {
        self == 0 ? defaultValue : self
    }
}
