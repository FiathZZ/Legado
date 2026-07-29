import AVFoundation
import SwiftData
import XCTest
@testable import Legado

private actor TocRequestCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

final class ReaderServicesTests: XCTestCase {
    @MainActor
    func testConcurrentTocLoadsShareOneRequestAndCacheWrite() async throws {
        let container = try SwiftLegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let bookshelf = BookshelfViewModel(modelContext: context)
        let detail = BookDetail(
            bookUrl: "https://example.com/books/concurrent",
            name: "测试书",
            author: "作者",
            tocUrl: "https://example.com/toc"
        )
        let source = BookSource(bookSourceName: "测试书源", bookSourceUrl: "https://example.com")
        let fetchedChapters = [BookChapter(index: 0, title: "第一章", url: "/chapter/1")]
        let requestCounter = TocRequestCounter()
        let viewModel = BookTocViewModel(
            detail: detail,
            source: source,
            bookshelfViewModel: bookshelf,
            tocRequestLoader: { _, _ in
                await requestCounter.increment()
                try await Task.sleep(for: .milliseconds(20))
                return fetchedChapters
            }
        )

        async let first: Void = viewModel.loadToc()
        async let second: Void = viewModel.loadToc()
        _ = await (first, second)

        XCTAssertEqual(await requestCounter.currentValue(), 1)
        XCTAssertEqual(viewModel.chapters, fetchedChapters)
        let caches = try context.fetch(FetchDescriptor<TocCacheEntity>())
        XCTAssertEqual(caches.count, 1)
        XCTAssertEqual(caches.first?.toChapters(), fetchedChapters)
    }

    @MainActor
    func testExpiredTocCacheReturnsBeforeBackgroundRefreshCompletes() async throws {
        let container = try SwiftLegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let bookshelf = BookshelfViewModel(modelContext: context)
        let detail = BookDetail(
            bookUrl: "https://example.com/books/expired-cache",
            name: "测试书",
            author: "作者",
            tocUrl: "https://example.com/toc"
        )
        let source = BookSource(bookSourceName: "测试书源", bookSourceUrl: "https://example.com")
        let cachedChapters = [BookChapter(index: 0, title: "缓存章节", url: "/cached/1")]
        let refreshedChapters = [BookChapter(index: 0, title: "刷新章节", url: "/refreshed/1")]
        let cachedData = try JSONEncoder().encode(cachedChapters)
        context.insert(
            TocCacheEntity(
                cacheKey: TocCacheEntity.cacheKey(for: detail.bookUrl),
                bookUrl: detail.bookUrl,
                chaptersJson: String(decoding: cachedData, as: UTF8.self),
                cachedAt: .distantPast
            )
        )
        try context.save()

        let requestCounter = TocRequestCounter()
        let viewModel = BookTocViewModel(
            detail: detail,
            source: source,
            bookshelfViewModel: bookshelf,
            tocRequestLoader: { _, _ in
                await requestCounter.increment()
                try await Task.sleep(for: .milliseconds(500))
                return refreshedChapters
            }
        )

        let start = Date()
        await viewModel.loadToc()

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(viewModel.chapters, cachedChapters)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(await requestCounter.currentValue(), 1)
        XCTAssertEqual(viewModel.chapters, refreshedChapters)
    }

    @MainActor
    func testSourceSwitchReplacesTocCacheForSameBookURL() throws {
        let container = try SwiftLegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let bookshelf = BookshelfViewModel(modelContext: context)
        let bookURL = "https://example.com/books/42"
        let originalDetail = BookDetail(bookUrl: bookURL, name: "测试书", author: "作者", tocUrl: "https://example.com/toc")
        let originalSource = BookSource(bookSourceName: "旧书源", bookSourceUrl: "https://old.example.com")
        let originalChapters = [BookChapter(index: 0, title: "旧章节", url: "/old/1")]
        let originalData = try JSONEncoder().encode(originalChapters)
        context.insert(
            TocCacheEntity(
                cacheKey: TocCacheEntity.cacheKey(for: bookURL),
                bookUrl: bookURL,
                chaptersJson: String(decoding: originalData, as: UTF8.self)
            )
        )
        try context.save()

        let viewModel = BookTocViewModel(
            detail: originalDetail,
            source: originalSource,
            bookshelfViewModel: bookshelf
        )
        let newChapters = [BookChapter(index: 0, title: "新章节", url: "/new/1")]
        viewModel.applySourceSwitch(
            ChangeSourceSelection(
                source: BookSource(bookSourceName: "新书源", bookSourceUrl: "https://new.example.com"),
                searchBook: SearchBook(bookUrl: bookURL, name: "测试书", author: "作者"),
                detail: BookDetail(bookUrl: bookURL, name: "测试书", author: "作者", tocUrl: "https://example.com/toc"),
                chapters: newChapters,
                targetIndex: 0
            )
        )

        let caches = try context.fetch(FetchDescriptor<TocCacheEntity>())
        XCTAssertEqual(caches.count, 1)
        XCTAssertEqual(caches.first?.toChapters()?.first?.title, "新章节")
    }

    func testTocCachePolicyRejectsOversizedChapterVariablesBeforeEncoding() {
        let oversizedValue = String(
            repeating: "x",
            count: TocCachePolicy.maximumEstimatedBytes
        )
        let chapters = [
            BookChapter(
                index: 0,
                title: "第1章",
                url: "/chapter/1",
                variables: ["payload": oversizedValue]
            )
        ]

        XCTAssertFalse(TocCachePolicy.shouldPersist(chapters))

        var didAttemptEncoding = false
        let encoded = TocCachePolicy.encodedDataIfSafe(chapters) {
            didAttemptEncoding = true
            return Data()
        }
        XCTAssertNil(encoded)
        XCTAssertFalse(didAttemptEncoding)
    }

    func testTocCachePolicyAllowsOrdinaryChapterList() {
        XCTAssertTrue(
            TocCachePolicy.shouldPersist([
                BookChapter(index: 0, title: "第1章", url: "/chapter/1")
            ])
        )
    }

    func testReplaceRuleImportAcceptsAndroidRuleArray() throws {
        let payload = #"""
        [{
          "id": 3067,
          "name": "起点段落净化",
          "group": "起点",
          "pattern": "广告：(\\w+)",
          "replacement": "@js:result.replace('广告：', '')",
          "scopeTitle": false,
          "scopeContent": true,
          "isEnabled": true,
          "isRegex": true,
          "order": 9
        }]
        """#

        let rules = try ReplaceRule.importRules(from: payload)

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, "3067")
        XCTAssertEqual(rules[0].name, "起点段落净化")
        XCTAssertEqual(rules[0].scope, .content)
        XCTAssertEqual(rules[0].replacement, "@js:result.replace('广告：', '')")
    }

    func testJavaScriptReplaceRuleEvaluatesEachRegexMatchAsResult() {
        let rule = ReplaceRule(
            pattern: "广告：[A-Za-z]+",
            replacement: "@js:result.replace('广告：', '')",
            scope: .content
        )

        let result = ReaderContentService.applyReplaceRule(
            "正文 广告：Alpha 广告：Beta",
            rule: rule,
            source: BookSource(bookSourceName: "起点", bookSourceUrl: "https://qidian.com")
        )

        XCTAssertEqual(result, "正文 Alpha Beta")
    }

    func testCachedContentReplacementRemovesBrowserReaderModeNotice() {
        let notice = "请关闭浏览器阅读模式后查看本章节，否则将出现无法翻页或章节内容丢失等现象"
        let rule = ReplaceRule(
            pattern: notice,
            replacement: "",
            scope: .content
        )

        let result = ReaderContentService.applyCachedContentReplacement(
            "\(notice)\n这里才是正文",
            source: BookSource(bookSourceName: "测试书源", bookSourceUrl: "https://example.com"),
            rules: [rule]
        )

        XCTAssertEqual(result, "\n这里才是正文")
    }

    func testCachedContentReplacementRemovesBrowserReaderModeNoticeWithoutUserRule() {
        let notice = "请关闭浏览器阅读模式后查看本章节，否则将出现无法翻页或章节内容丢失等现象。"

        let result = ReaderContentService.applyCachedContentReplacement(
            "\(notice)\n这里才是正文",
            source: BookSource(bookSourceName: "测试书源", bookSourceUrl: "https://example.com"),
            rules: []
        )

        XCTAssertEqual(result, "\n这里才是正文")
    }

    func testReplaceRulePreservesAndroidScopeAndDisabledTarget() throws {
        let scoped = try ReplaceRule.importRules(from: #"""
        [{"scope":"起点","excludeScope":"测试书","scopeTitle":false,"scopeContent":true,"pattern":"广告","replacement":""}]
        """#).first!
        XCTAssertTrue(scoped.applies(toBookName: "大奉打更人", sourceName: "起点", sourceURL: "https://qidian.com"))
        XCTAssertFalse(scoped.applies(toBookName: "测试书", sourceName: "起点", sourceURL: "https://qidian.com"))

        let disabled = try ReplaceRule.importRules(from: #"""
        [{"scopeTitle":false,"scopeContent":false,"pattern":"广告","replacement":""}]
        """#).first!
        XCTAssertEqual(disabled.scope, .none)
    }

    func testBookmarkSnippetNormalizesWhitespaceAndFallsBack() {
        XCTAssertEqual(
            ReaderBookmarkService.makeSnippet(from: "  第一段 \n\n 第二段\t第三段  ", limit: 50),
            "第一段 第二段 第三段"
        )
        XCTAssertEqual(ReaderBookmarkService.makeSnippet(from: "   \n\t ", limit: 50), "暂无摘要")
        XCTAssertEqual(ReaderBookmarkService.makeSnippet(from: "1234567890", limit: 4), "1234")
    }

    func testReaderDownloadOptionsMatchRemainingChapterCount() {
        let manyOptions = ReaderContentService.makeDownloadOptions(totalChapterCount: 180, currentIndex: 10)
        XCTAssertEqual(manyOptions.map { $0.label }, ["向下缓存20章", "向下缓存100章", "全部缓存"])
        XCTAssertEqual(manyOptions.map { $0.count ?? -1 }, [20, 100, -1])

        let fewOptions = ReaderContentService.makeDownloadOptions(totalChapterCount: 15, currentIndex: 5)
        XCTAssertEqual(fewOptions.map { $0.label }, ["全部缓存"])
        XCTAssertEqual(fewOptions.first?.count, nil)
    }

    func testEntireBookCacheStateDisablesDownloadAfterCompletion() {
        XCTAssertEqual(
            ReaderBookCacheState.resolve(isDownloading: false, isEntireBookCached: false),
            .available
        )
        XCTAssertEqual(
            ReaderBookCacheState.resolve(isDownloading: true, isEntireBookCached: false),
            .downloading
        )
        XCTAssertEqual(
            ReaderBookCacheState.resolve(isDownloading: false, isEntireBookCached: true),
            .completed
        )
    }

    func testReaderContextSnippetAddsEllipsisAndCondensesWhitespace() {
        let prefix = String(repeating: "前文", count: 30)
        let suffix = String(repeating: "后文", count: 30)
        let text = "\(prefix)   关键字   在这里\(suffix)"
        let range = text.range(of: "关键字")
        XCTAssertNotNil(range)

        let snippet = ReaderContentService.makeContextSnippet(in: text, around: range!)
        XCTAssertTrue(snippet.contains("关键字"))
        XCTAssertTrue(snippet.hasPrefix("..."))
        XCTAssertTrue(snippet.hasSuffix("..."))
        XCTAssertFalse(snippet.contains("  "))
    }

    func testTTSNormalizationAndRateMappingAreDeterministic() {
        XCTAssertEqual(
            TTSManager.normalizeSpeechText(" \r\n第一行\r第二行\n "),
            "第一行\n第二行"
        )

        let slow = TTSManager.avSpeechRate(for: 0.5)
        let medium = TTSManager.avSpeechRate(for: 1.0)
        let fast = TTSManager.avSpeechRate(for: 2.0)

        XCTAssertLessThan(slow, medium)
        XCTAssertLessThan(medium, fast)
        XCTAssertGreaterThanOrEqual(slow, AVSpeechUtteranceMinimumSpeechRate)
        XCTAssertLessThanOrEqual(fast, AVSpeechUtteranceMaximumSpeechRate)
    }

    @MainActor
    func testTTSRateChangeRestartDoesNotAdvanceChapter() {
        let manager = TTSManager()
        var finishedCount = 0
        manager.onChapterFinished = {
            finishedCount += 1
        }

        manager.startReading(text: "第一句。第二句。", bookName: "测试书", chapterTitle: "第1章")
        manager.setRate(1.5)
        manager.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: "旧语句"))

        XCTAssertEqual(finishedCount, 0)
    }

    @MainActor
    func testTTSStopClosesControlBar() {
        let manager = TTSManager()

        manager.startReading(text: "第一句。", bookName: "测试书", chapterTitle: "第1章")
        XCTAssertTrue(manager.isControlVisible)

        manager.stop()

        XCTAssertFalse(manager.isControlVisible)
        XCTAssertFalse(manager.isPlaying)
    }

    @MainActor
    func testProgressServiceUpdatesBookEntityState() throws {
        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let book = BookEntity(
            bookUrl: "https://book.test",
            name: "测试小说",
            author: "作者",
            currentChapterIndex: 0,
            currentChapterName: "第1章",
            hasNewChapter: true,
            sourceUrl: "https://source.test"
        )
        context.insert(book)

        let chapters = [
            BookChapter(index: 0, title: "第1章"),
            BookChapter(index: 1, title: "第2章"),
            BookChapter(index: 2, title: "第3章")
        ]

        ReaderProgressService().saveReadingProgress(
            bookEntity: book,
            chapters: chapters,
            currentIndex: 2,
            bookURL: book.bookUrl,
            modelContext: context
        )

        XCTAssertEqual(book.currentChapterIndex, 2)
        XCTAssertEqual(book.currentChapterName, "第3章")
        XCTAssertFalse(book.hasNewChapter)
        XCTAssertNotNil(book.lastReadTime)
    }

    @MainActor
    func testProgressServiceImmediatelyPersistsFullReadingPosition() throws {
        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let bookURL = "reader-progress-immediate-save-test"
        let book = BookEntity(
            bookUrl: bookURL,
            name: "测试小说",
            author: "作者",
            currentChapterIndex: 0,
            currentChapterName: "第1章",
            hasNewChapter: true,
            sourceUrl: "https://source.test"
        )
        context.insert(book)

        let chapters = [
            BookChapter(index: 0, title: "第1章"),
            BookChapter(index: 1, title: "第2章"),
            BookChapter(index: 2, title: "第3章")
        ]
        let position = ReaderPosition(chapterIndex: 2, pageIndex: 5, utf16Offset: 960)
        let service = ReaderProgressService()

        service.saveReadingProgress(
            bookEntity: book,
            chapters: chapters,
            currentIndex: 0,
            currentPosition: position,
            bookURL: bookURL,
            modelContext: context
        )

        XCTAssertEqual(book.currentChapterIndex, 2)
        XCTAssertEqual(book.currentChapterName, "第3章")
        XCTAssertEqual(service.restoreReadingProgress(bookURL: bookURL, fallbackChapterIndex: 0), position)

        UserDefaults.standard.removeObject(forKey: "reader.progress.position.\(bookURL)")
    }

    func testLayoutConfigurationNormalizesBodyIndentation() {
        let configuration = ReaderLayoutConfiguration(
            viewportSize: CGSize(width: 320, height: 480),
            paragraphIndentCount: 1
        )

        XCTAssertEqual(
            configuration.normalizedBody("　　第一段\n  第二段\n第三段"),
            "　第一段\n　第二段\n　第三段"
        )
    }
}
