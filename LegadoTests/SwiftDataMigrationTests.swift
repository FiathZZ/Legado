import Foundation
import SwiftData
import XCTest
@testable import Legado

final class SwiftDataMigrationTests: XCTestCase {
    func testLegacyV1StoreMigratesAndKeepsPersistence() throws {
        let storeURL = try makeStoreURL()

        try seedV1Store(at: storeURL)

        let migratedContext = try makeCurrentContext(storeURL: storeURL)

        let migratedSources = try migratedContext.fetch(FetchDescriptor<BookSourceEntity>())
        XCTAssertEqual(migratedSources.count, 1)
        XCTAssertEqual(migratedSources.first?.bookSourceName, "旧书源")

        let migratedBooks = try migratedContext.fetch(FetchDescriptor<BookEntity>())
        let legacyBook = try XCTUnwrap(migratedBooks.first)
        XCTAssertEqual(legacyBook.name, "旧书籍")
        XCTAssertEqual(legacyBook.group, 0)
        XCTAssertGreaterThan(legacyBook.manualOrder, 0)

        let newSource = BookSourceEntity(
            bookSourceUrl: "https://example.com/source/new",
            bookSourceName: "新书源"
        )
        let newBook = BookEntity(
            bookUrl: "https://example.com/book/new",
            name: "新书籍",
            author: "作者乙",
            sourceUrl: newSource.bookSourceUrl
        )
        let group = BookGroup(groupId: 1, groupName: "收藏")
        newBook.addGroup(group.groupId)

        migratedContext.insert(newSource)
        migratedContext.insert(newBook)
        migratedContext.insert(group)
        try migratedContext.save()

        let reopenedContext = try makeCurrentContext(storeURL: storeURL)

        let reopenedSources = try reopenedContext.fetch(FetchDescriptor<BookSourceEntity>())
        XCTAssertEqual(Set(reopenedSources.map(\.bookSourceName)), ["旧书源", "新书源"])

        let reopenedBooks = try reopenedContext.fetch(FetchDescriptor<BookEntity>())
        XCTAssertEqual(reopenedBooks.count, 2)

        let reopenedLegacyBook = try XCTUnwrap(reopenedBooks.first(where: { $0.bookUrl == "https://example.com/book/legacy" }))
        XCTAssertEqual(reopenedLegacyBook.group, 0)
        XCTAssertNil(reopenedLegacyBook.customCoverUrl)
        XCTAssertNil(reopenedLegacyBook.customIntro)
        XCTAssertNil(reopenedLegacyBook.customTag)
        XCTAssertGreaterThan(reopenedLegacyBook.manualOrder, 0)

        let reopenedNewBook = try XCTUnwrap(reopenedBooks.first(where: { $0.bookUrl == "https://example.com/book/new" }))
        XCTAssertTrue(reopenedNewBook.hasGroup(1))
        reopenedNewBook.customCoverUrl = "https://example.com/custom-cover.jpg"
        reopenedNewBook.customIntro = "自定义简介"
        reopenedNewBook.customTag = "必读"
        try reopenedContext.save()

        let customFieldContext = try makeCurrentContext(storeURL: storeURL)
        let customFieldBook = try XCTUnwrap(
            customFieldContext.fetch(FetchDescriptor<BookEntity>()).first(where: { $0.bookUrl == "https://example.com/book/new" })
        )
        XCTAssertEqual(customFieldBook.customCoverUrl, "https://example.com/custom-cover.jpg")
        XCTAssertEqual(customFieldBook.customIntro, "自定义简介")
        XCTAssertEqual(customFieldBook.customTag, "必读")

        let reopenedGroups = try reopenedContext.fetch(FetchDescriptor<BookGroup>())
        XCTAssertEqual(reopenedGroups.map(\.groupName), ["收藏"])
    }

    func testV4StoreMigratesManualOrderAndPhase9Entities() throws {
        let storeURL = try makeStoreURL()
        let seededAddedTime = Date(timeIntervalSince1970: 1_710_000_000)
        let expectedManualOrder = max(Int(seededAddedTime.timeIntervalSince1970 * 1000), 0)

        try seedV4Store(at: storeURL, addedTime: seededAddedTime)

        let migratedContext = try makeCurrentContext(storeURL: storeURL)
        let migratedBooks = try migratedContext.fetch(FetchDescriptor<BookEntity>())
        let legacyBook = try XCTUnwrap(migratedBooks.first(where: { $0.bookUrl == "https://example.com/book/v4" }))
        XCTAssertEqual(legacyBook.name, "V4 书籍")
        XCTAssertEqual(legacyBook.manualOrder, expectedManualOrder)
        XCTAssertTrue(legacyBook.hasGroup(1))

        let migratedGroups = try migratedContext.fetch(FetchDescriptor<BookGroup>())
        let legacyGroup = try XCTUnwrap(migratedGroups.first(where: { $0.groupId == 1 }))
        XCTAssertNil(legacyGroup.bookSort)

        let ruleSub = RuleSubEntity(
            name: "默认订阅",
            url: "https://example.com/subscription.json",
            autoUpdate: true,
            order: 0
        )
        migratedContext.insert(ruleSub)
        legacyGroup.bookSort = BookshelfSortMode.manual.rawValue
        legacyBook.manualOrder = 7
        try migratedContext.save()

        let reopenedContext = try makeCurrentContext(storeURL: storeURL)
        let reopenedBook = try XCTUnwrap(
            reopenedContext.fetch(FetchDescriptor<BookEntity>())
                .first(where: { $0.bookUrl == "https://example.com/book/v4" })
        )
        XCTAssertEqual(reopenedBook.manualOrder, 7)

        let reopenedGroup = try XCTUnwrap(
            reopenedContext.fetch(FetchDescriptor<BookGroup>())
                .first(where: { $0.groupId == 1 })
        )
        XCTAssertEqual(reopenedGroup.bookSort, BookshelfSortMode.manual.rawValue)

        let reopenedRuleSubs = try reopenedContext.fetch(FetchDescriptor<RuleSubEntity>())
        XCTAssertEqual(reopenedRuleSubs.map(\.name), ["默认订阅"])
    }

    func testV6StoreMigratesToV7AndSupportsRSSPersistence() throws {
        let storeURL = try makeStoreURL()

        try seedV6Store(at: storeURL)

        let migratedContext = try makeCurrentContext(storeURL: storeURL)
        let migratedSources = try migratedContext.fetch(FetchDescriptor<BookSourceEntity>())
        XCTAssertEqual(migratedSources.map(\.bookSourceName), ["V6 书源"])

        let rssSource = RssSourceEntity(
            sourceUrl: "https://example.com/rss",
            sourceName: "示例 RSS",
            ruleArticles: "item",
            ruleTitle: "title"
        )
        let rssArticle = RssArticleEntity(
            origin: rssSource.sourceUrl,
            title: "文章标题",
            link: "https://example.com/rss/article-1"
        )

        migratedContext.insert(rssSource)
        migratedContext.insert(rssArticle)
        try migratedContext.save()

        let reopenedContext = try makeCurrentContext(storeURL: storeURL)
        let reopenedRssSources = try reopenedContext.fetch(FetchDescriptor<RssSourceEntity>())
        let reopenedRssArticles = try reopenedContext.fetch(FetchDescriptor<RssArticleEntity>())

        XCTAssertEqual(reopenedRssSources.map(\.sourceName), ["示例 RSS"])
        XCTAssertEqual(reopenedRssArticles.map(\.title), ["文章标题"])
        XCTAssertEqual(reopenedRssArticles.first?.origin, "https://example.com/rss")
    }

    private func seedV1Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: LegadoSchemaV1.self)
        let configuration = ModelConfiguration(
            nil,
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let source = LegadoSchemaV1.BookSourceEntity(
            bookSourceUrl: "https://example.com/source/legacy",
            bookSourceName: "旧书源"
        )
        let book = LegadoSchemaV1.BookEntity(
            bookUrl: "https://example.com/book/legacy",
            name: "旧书籍",
            author: "作者甲",
            sourceUrl: source.bookSourceUrl
        )

        context.insert(source)
        context.insert(book)
        try context.save()
    }

    private func seedV4Store(at storeURL: URL, addedTime: Date) throws {
        let schema = Schema(versionedSchema: LegadoSchemaV4.self)
        let configuration = ModelConfiguration(
            nil,
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let source = LegadoSchemaV4.BookSourceEntity(
            bookSourceUrl: "https://example.com/source/v4",
            bookSourceName: "V4 书源"
        )
        let group = LegadoSchemaV4.BookGroup(
            groupId: 1,
            groupName: "历史分组",
            order: 0,
            show: true
        )
        let book = LegadoSchemaV4.BookEntity(
            bookUrl: "https://example.com/book/v4",
            name: "V4 书籍",
            author: "作者丙",
            coverUrl: nil,
            intro: nil,
            kind: nil,
            wordCount: nil,
            customCoverUrl: nil,
            customIntro: nil,
            customTag: nil,
            lastChapter: nil,
            updateTime: nil,
            tocUrl: nil,
            currentChapterIndex: 0,
            currentChapterName: nil,
            totalChapterCount: 0,
            hasNewChapter: false,
            sourceUrl: source.bookSourceUrl,
            addedTime: addedTime,
            lastReadTime: nil,
            group: 1
        )

        context.insert(source)
        context.insert(group)
        context.insert(book)
        try context.save()
    }

    private func seedV6Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: LegadoSchemaV6.self)
        let configuration = ModelConfiguration(
            nil,
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let source = BookSourceEntity(
            bookSourceUrl: "https://example.com/source/v6",
            bookSourceName: "V6 书源"
        )
        context.insert(source)
        try context.save()
    }

    private func makeCurrentContext(storeURL: URL) throws -> ModelContext {
        let container = try LegadoModelContainerFactory.makeModelContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Legado.sqlite")
    }
}
