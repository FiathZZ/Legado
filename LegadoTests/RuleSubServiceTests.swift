import SwiftData
import XCTest
@testable import Legado

final class RuleSubServiceTests: XCTestCase {
    func testNormalizedSubscriptionURLAcceptsFullWidthRssSubscription() throws {
        let normalized = try RuleSubService.normalizedSubscriptionURL(
            from: "yuedu：//rsssource/importonline？src=http：//example。com/rss。json"
        )

        XCTAssertEqual(
            normalized,
            "yuedu://rsssource/importonline?src=http://example.com/rss.json"
        )
    }

    @MainActor
    func testUpdateSubscriptionPersistsRssSources() async throws {
        let remotePayload = """
        [
          {
            "sourceUrl": "https://example.com/rss/source-1",
            "sourceName": "测试 RSS"
          }
        ]
        """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data(remotePayload.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let subscription = RuleSubEntity(
            name: "RSS 订阅",
            url: "yuedu://rsssource/importonline?src=\(fileURL.absoluteString)"
        )
        context.insert(subscription)
        try context.save()

        let summary = try await RuleSubService.updateSubscription(subscription, in: context)
        let rssSources = try context.fetch(FetchDescriptor<RssSourceEntity>())

        XCTAssertEqual(summary.contentKind, .rssSource)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.addedCount, 1)
        XCTAssertEqual(summary.linkedBookSourceImportedCount, 0)
        XCTAssertEqual(summary.linkedBookSourceAddedCount, 0)
        XCTAssertEqual(rssSources.map(\.sourceName), ["测试 RSS"])
        XCTAssertNotNil(subscription.lastUpdateTime)
    }

    @MainActor
    func testUpdateSubscriptionImportsLinkedBookSourcesFromRssLandingPage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bookSourceListAURL = temporaryDirectory.appendingPathComponent("source-a.json")
        let bookSourceListBURL = temporaryDirectory.appendingPathComponent("source-b.json")
        let landingPageURL = temporaryDirectory.appendingPathComponent("gx.html")
        let rssPayloadURL = temporaryDirectory.appendingPathComponent("rss-source.json")

        let bookSourceListA = """
        [
          {
            "bookSourceUrl": "https://example.com/book-source-a",
            "bookSourceName": "书源 A"
          },
          {
            "bookSourceUrl": "https://example.com/book-source-b",
            "bookSourceName": "书源 B"
          }
        ]
        """
        let bookSourceListB = """
        [
          {
            "bookSourceUrl": "https://example.com/book-source-b",
            "bookSourceName": "书源 B"
          }
        ]
        """
        let landingPage = """
        <html>
        <body>
          <a href="yuedu://booksource/importonline?src=\(bookSourceListAURL.absoluteString)">导入 A</a>
          <a href="yuedu://booksource/importonline?src=\(bookSourceListBURL.absoluteString)">导入 B</a>
        </body>
        </html>
        """
        let rssPayload = """
        [
          {
            "sourceUrl": "\(landingPageURL.absoluteString)",
            "sourceName": "喵公子书源管理"
          }
        ]
        """

        try Data(bookSourceListA.utf8).write(to: bookSourceListAURL)
        try Data(bookSourceListB.utf8).write(to: bookSourceListBURL)
        try Data(landingPage.utf8).write(to: landingPageURL)
        try Data(rssPayload.utf8).write(to: rssPayloadURL)

        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let subscription = RuleSubEntity(
            name: "RSS 订阅",
            url: "yuedu://rsssource/importonline?src=\(rssPayloadURL.absoluteString)"
        )
        context.insert(subscription)
        try context.save()

        let summary = try await RuleSubService.updateSubscription(subscription, in: context)
        let importedBookSources = try context.fetch(FetchDescriptor<BookSourceEntity>())
            .map { $0.toBookSource() }
            .sorted { $0.bookSourceUrl < $1.bookSourceUrl }

        XCTAssertEqual(summary.contentKind, .rssSource)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.linkedBookSourceImportedCount, 2)
        XCTAssertEqual(summary.linkedBookSourceAddedCount, 2)
        XCTAssertEqual(importedBookSources.map(\.bookSourceUrl), [
            "https://example.com/book-source-a",
            "https://example.com/book-source-b"
        ])
    }
}
