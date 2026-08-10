import XCTest
@testable import Legado

final class MemoryLeakSearchChangeSourceTests: XCTestCase {
    func testAlamofireSessionCreationGateRejectsTaskSetupAfterShutdown() {
        let gate = AlamofireRequestCreationGate()
        let setupStarted = expectation(description: "request setup started")
        let releaseSetup = DispatchSemaphore(value: 0)
        let shutdownFinished = expectation(description: "shutdown finished")

        DispatchQueue.global(qos: .utility).async {
            _ = gate.withRequestCreation {
                setupStarted.fulfill()
                releaseSetup.wait()
                return true
            }
        }

        wait(for: [setupStarted], timeout: 1)

        DispatchQueue.global(qos: .utility).async {
            gate.shutdown()
            shutdownFinished.fulfill()
        }

        XCTAssertFalse(
            XCTWaiter().wait(for: [shutdownFinished], timeout: 0.05) == .completed,
            "shutdown 不能抢在正在进行的 session task 创建之前"
        )

        releaseSetup.signal()
        wait(for: [shutdownFinished], timeout: 1)
        XCTAssertNil(gate.withRequestCreation { true })
    }

    private static let keyword = "遮天"
    private static let author = "辰东"

    func testAsyncSemaphoreAcquireThrowsOnCancellation() async throws {
        let semaphore = AsyncSemaphore(max: 1)
        try await semaphore.acquire()

        let waiter = Task { () -> Error? in
            do {
                try await semaphore.acquire()
                return nil
            } catch {
                return error
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        let error = await waiter.value
        await semaphore.release()

        XCTAssertNotNil(error)
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
    }

    @MainActor
    func testSourceSearchDeadlineSkipsNonCooperativeOperation() async {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await SourceOperationDeadline.run(seconds: 0) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        continuation.resume()
                    }
                }
                return "late result"
            }
            XCTFail("deadline should return an error")
        } catch {
            XCTAssertLessThan(
                startedAt.duration(to: clock.now),
                .milliseconds(200),
                "deadline must not wait for an operation that ignores cancellation"
            )
        }
    }

    @MainActor
    func testSourceSearchDeadlineRunsOperationAwayFromMainThread() async throws {
        let ranOnMainThread = try await SourceOperationDeadline.run(seconds: 1) {
            Thread.isMainThread
        }

        XCTAssertFalse(
            ranOnMainThread,
            "书源请求和规则解析不能占用 UI 主线程"
        )
    }

    @MainActor
    func testSearchResultViewModelDeallocatesAfterCancel_withSourcesFromJSON_keyword遮天() async throws {
        let sources = try Self.loadSearchSources(limit: 12)
        XCTAssertGreaterThanOrEqual(sources.count, 8, "需要足够多的书源来覆盖排队取消路径")

        HeadlessWebView.shared.purge()

        weak var weakViewModel: SearchResultViewModel?
        var viewModel: SearchResultViewModel? = SearchResultViewModel()
        weakViewModel = viewModel
        viewModel?.maxConcurrency = 1
        viewModel?.search(keyword: Self.keyword, sources: sources)

        try await Task.sleep(for: .milliseconds(250))

        viewModel?.cancel()
        viewModel = nil

        try await assertReleased(weakViewModel, timeout: .seconds(5))
        XCTAssertNil(weakViewModel)
    }

    @MainActor
    func testSearchResultViewModelStopsForNavigationWithoutDiscardingPublishedResults() {
        let viewModel = SearchResultViewModel()
        let publishedResult = SearchBook(
            bookUrl: "https://example.com/book/1",
            name: "遮天",
            author: "辰东",
            origin: "https://example.com/source"
        )
        viewModel.results = [publishedResult]
        viewModel.isSearching = true

        viewModel.stopSearchForNavigation()

        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.results.map(\.bookUrl), [publishedResult.bookUrl])
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testChangeSourceSearchWithoutCandidateRestrictionUsesAllEnabledSources() {
        let current = BookSource(
            bookSourceName: "当前源",
            bookSourceUrl: "https://current.example",
            searchUrl: "/search?q={{key}}"
        )
        let alternative = BookSource(
            bookSourceName: "备用源",
            bookSourceUrl: "https://alternative.example",
            searchUrl: "/search?q={{key}}"
        )

        let viewModel = ChangeSourceViewModel(
            bookName: "遮天",
            bookAuthor: "辰东",
            allSources: [current, alternative],
            currentSourceURL: current.bookSourceUrl,
            currentSourceName: current.bookSourceName
        )

        XCTAssertEqual(
            viewModel.searchableSourceURLs,
            [alternative.bookSourceUrl],
            "换源搜索不能被本次搜索结果的书源集合限制"
        )
    }

    @MainActor
    func testChangeSourceKeepsMergedSearchOriginsAsImmediateCandidates() {
        let current = BookSource(
            bookSourceName: "当前源",
            bookSourceUrl: "https://current.example",
            searchUrl: "/search?q={{key}}"
        )
        let alternative = BookSource(
            bookSourceName: "备用源",
            bookSourceUrl: "https://alternative.example",
            searchUrl: "/search?q={{key}}"
        )
        let prefetched = SearchBook(
            bookUrl: "/book/current",
            name: "遮天",
            author: "辰东",
            origin: current.bookSourceUrl,
            sourceName: current.bookSourceName,
            sourceOrigins: [
                SearchBookOrigin(
                    url: current.bookSourceUrl,
                    name: current.bookSourceName,
                    bookUrl: "/book/current"
                ),
                SearchBookOrigin(
                    url: alternative.bookSourceUrl,
                    name: alternative.bookSourceName,
                    bookUrl: "/book/alternative"
                )
            ]
        )

        let viewModel = ChangeSourceViewModel(
            bookName: prefetched.name,
            bookAuthor: prefetched.author,
            allSources: [current, alternative],
            prefetchedBook: prefetched,
            currentSourceURL: current.bookSourceUrl,
            currentSourceName: current.bookSourceName
        )

        XCTAssertEqual(viewModel.results.count, 1)
        XCTAssertEqual(viewModel.results.first?.source.bookSourceUrl, alternative.bookSourceUrl)
        XCTAssertEqual(viewModel.results.first?.searchBook.bookUrl, "/book/alternative")
    }

    @MainActor
    func testChangeSourceViewModelDeallocatesAfterCancel_withSourcesFromJSON_keyword遮天() async throws {
        let sources = try Self.loadSearchSources(limit: 12)
        XCTAssertGreaterThanOrEqual(sources.count, 8, "需要足够多的书源来覆盖排队取消路径")

        HeadlessWebView.shared.purge()

        weak var weakViewModel: ChangeSourceViewModel?
        var viewModel: ChangeSourceViewModel? = ChangeSourceViewModel(
            bookName: Self.keyword,
            bookAuthor: Self.author,
            allSources: sources,
            currentSourceURL: sources.first?.bookSourceUrl,
            currentSourceName: sources.first?.bookSourceName ?? "",
            currentChapterTitle: "第1章",
            currentChapterIndex: 0,
            currentChapterCount: 1_000
        )
        weakViewModel = viewModel
        viewModel?.startSearch()

        try await Task.sleep(for: .milliseconds(250))

        viewModel?.cancel()
        viewModel = nil

        try await assertReleased(weakViewModel, timeout: .seconds(5))
        XCTAssertNil(weakViewModel)
    }

    @MainActor
    private func assertReleased<Object: AnyObject>(
        _ object: @autoclosure @escaping () -> Object?,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if object() == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            await Task.yield()
        }

        XCTFail("对象在超时后仍未释放")
    }

    private static func loadSearchSources(limit: Int) throws -> [BookSource] {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("书源.json")
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([BookSource].self, from: data)
        return Array(
            decoded
                .filter { $0.enabled && $0.bookSourceType == 0 && ($0.searchUrl?.isEmpty == false) }
                .prefix(limit)
        )
    }
}
