import Foundation
import SwiftData
import XCTest
@testable import Legado

final class BackupRestoreTests: XCTestCase {
    @MainActor
    func testBackupAndRestoreRoundTripPreservesAllEntities() async throws {
        let sourceContainer = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let sourceContext = ModelContext(sourceContainer)
        sourceContext.autosaveEnabled = false

        seedSourceData(in: sourceContext)

        let backupURL = try await BackupManager().createBackup(modelContext: sourceContext)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let extractedURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extractedURL) }
        try BackupZipArchive.extractArchive(at: backupURL, to: extractedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent(BackupJSONFile.bookSource).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent(BackupJSONFile.bookshelf).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent(BackupJSONFile.bookGroup).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent(BackupJSONFile.bookmark).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent(BackupJSONFile.replaceRule).path))

        let restoredContainer = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let restoredContext = ModelContext(restoredContainer)
        restoredContext.autosaveEnabled = false

        try await RestoreManager().restoreFromBackup(url: backupURL, modelContext: restoredContext)

        let sources = try restoredContext.fetch(FetchDescriptor<BookSourceEntity>())
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.bookSourceName, "测试书源")

        let books = try restoredContext.fetch(FetchDescriptor<BookEntity>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.currentChapterIndex, 12)
        XCTAssertEqual(books.first?.group, 1)
        XCTAssertEqual(books.first?.customCoverUrl, "https://cover.test/custom.jpg")
        XCTAssertEqual(books.first?.customIntro, "自定义简介")
        XCTAssertEqual(books.first?.customTag, "收藏")

        let groups = try restoredContext.fetch(FetchDescriptor<BookGroup>())
        XCTAssertEqual(groups.map(\.groupName), ["收藏"])

        let bookmarks = try restoredContext.fetch(FetchDescriptor<BookmarkEntity>())
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.chapterName, "第13章")

        let rules = try restoredContext.fetch(FetchDescriptor<ReplaceRuleEntity>())
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.name, "过滤广告")
    }

    @MainActor
    func testRestoreMergesWithoutDeletingExistingEntities() async throws {
        let backupContainer = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backupContext = ModelContext(backupContainer)
        backupContext.autosaveEnabled = false

        seedSourceData(in: backupContext)
        let backupURL = try await BackupManager().createBackup(modelContext: backupContext)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let targetContainer = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let targetContext = ModelContext(targetContainer)
        targetContext.autosaveEnabled = false

        targetContext.insert(
            BookSourceEntity(
                bookSourceUrl: "https://source.existing",
                bookSourceName: "现有书源"
            )
        )
        targetContext.insert(
            BookEntity(
                bookUrl: "https://book.existing",
                name: "现有书籍",
                author: "作者甲",
                sourceUrl: "https://source.existing"
            )
        )
        try targetContext.save()

        try await RestoreManager().restoreFromBackup(url: backupURL, modelContext: targetContext)

        let sources = try targetContext.fetch(FetchDescriptor<BookSourceEntity>())
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.contains(where: { $0.bookSourceUrl == "https://source.existing" }))
        XCTAssertTrue(sources.contains(where: { $0.bookSourceUrl == "https://source.test" }))

        let books = try targetContext.fetch(FetchDescriptor<BookEntity>())
        XCTAssertEqual(books.count, 2)
        XCTAssertTrue(books.contains(where: { $0.bookUrl == "https://book.existing" }))
        XCTAssertTrue(books.contains(where: { $0.bookUrl == "https://book.test" }))
    }

    @MainActor
    func testRestoreSkipsMissingJSONFiles() async throws {
        let sourcePayload = [
            BookSourceBackupRecord(
                entity: BookSourceEntity(
                    bookSourceUrl: "https://source.partial",
                    bookSourceName: "单文件书源"
                )
            )
        ]
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-partial-\(UUID().uuidString).zip", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let data = try BackupCoding.makeEncoder().encode(sourcePayload)
        try BackupZipArchive.createArchive(
            entries: [BackupArchiveEntry(path: BackupJSONFile.bookSource, data: data)],
            to: archiveURL
        )

        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        try await RestoreManager().restoreFromBackup(url: archiveURL, modelContext: context)

        let sources = try context.fetch(FetchDescriptor<BookSourceEntity>())
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.bookSourceName, "单文件书源")

        let books = try context.fetch(FetchDescriptor<BookEntity>())
        XCTAssertTrue(books.isEmpty)
        let bookmarks = try context.fetch(FetchDescriptor<BookmarkEntity>())
        XCTAssertTrue(bookmarks.isEmpty)
    }

    @MainActor
    private func seedSourceData(in context: ModelContext) {
        let source = BookSourceEntity(
            bookSourceUrl: "https://source.test",
            bookSourceName: "测试书源",
            enabledExplore: true,
            searchUrl: "https://source.test/search"
        )
        let book = BookEntity(
            bookUrl: "https://book.test",
            name: "测试小说",
            author: "作者乙",
            coverUrl: "https://cover.test/original.jpg",
            intro: "原始简介",
            customCoverUrl: "https://cover.test/custom.jpg",
            customIntro: "自定义简介",
            customTag: "收藏",
            currentChapterIndex: 12,
            currentChapterName: "第13章",
            totalChapterCount: 200,
            hasNewChapter: false,
            sourceUrl: source.bookSourceUrl,
            group: 1
        )
        let group = BookGroup(groupId: 1, groupName: "收藏", order: 0, show: true)
        let bookmark = BookmarkEntity(
            id: "bookmark-1",
            bookUrl: book.bookUrl,
            chapterIndex: 12,
            chapterName: "第13章",
            bookText: "测试片段",
            content: "备注"
        )
        let replaceRule = ReplaceRuleEntity(
            id: "rule-1",
            name: "过滤广告",
            isEnabled: true,
            isRegex: false,
            pattern: "广告",
            replacement: "",
            scope: ReplaceRule.ReplaceScope.content.rawValue,
            order: 0
        )

        context.insert(source)
        context.insert(book)
        context.insert(group)
        context.insert(bookmark)
        context.insert(replaceRule)
        try? context.save()
    }

    private func makeTemporaryDirectory() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
