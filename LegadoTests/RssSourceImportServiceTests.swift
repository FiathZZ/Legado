import Foundation
import SwiftData
import XCTest
@testable import Legado

final class RssSourceImportServiceTests: XCTestCase {
    private let miaogongziSubscriptionURL = "yuedu://rsssource/importonline?src=http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"

    func testParseSubscriptionURLExtractsSourceParameter() throws {
        let service = RssSourceImportService()

        let remoteURL = try service.parseSubscriptionURL(
            miaogongziSubscriptionURL
        )

        XCTAssertEqual(
            remoteURL.absoluteString,
            "http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"
        )
    }

    func testParseSubscriptionURLAcceptsFullWidthInput() throws {
        let service = RssSourceImportService()

        let remoteURL = try service.parseSubscriptionURL(
            "yuedu：//rsssource/importonline？src=http：//yuedu。miaogongzi。net/shuyuan/miaogongziDY。json"
        )

        XCTAssertEqual(
            remoteURL.absoluteString,
            "http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json"
        )
    }

    @MainActor
    func testImportTextRejectsNonRssJSON() async throws {
        let service = RssSourceImportService()
        let context = try makeInMemoryContext()
        let invalidPayload = """
        [
          {
            "bookSourceUrl": "https://example.com/book-source",
            "bookSourceName": "普通书源"
          }
        ]
        """

        do {
            _ = try await service.importSources(from: invalidPayload, into: context)
            XCTFail("expected invalid RSS payload to fail")
        } catch let error as RssSourceImportError {
            guard case .parseError = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testImportLocalFilePersistsRssSourceEntities() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let payload = """
        [
          {
            "sourceUrl": "https://example.com/local-rss",
            "sourceName": "本地 RSS"
          }
        ]
        """
        try Data(payload.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let service = RssSourceImportService()
        let context = try makeInMemoryContext()

        let imported = try await service.importSources(fromFile: fileURL, into: context)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.sourceName, "本地 RSS")
    }

    @MainActor
    func testImportSubscriptionURLParsesRssSourceListWithoutCrashing() async throws {
        let context = try makeInMemoryContext()
        let expectedRemoteURL = URL(string: "http://yuedu.miaogongzi.net/shuyuan/miaogongziDY.json")!
        let remotePayload = """
        [
          {
            "sourceUrl": "https://rss.example.com/feed-1.xml",
            "sourceName": "苗公子一号",
            "sortUrl": "全部::https://rss.example.com/feed-1.xml"
          },
          {
            "sourceUrl": "https://rss.example.com/feed-2.xml",
            "sourceName": "苗公子二号",
            "ruleArticles": "item",
            "ruleTitle": "title",
            "ruleLink": "link"
          }
        ]
        """
        var requestedURLs: [URL] = []
        let service = RssSourceImportService(
            remoteDataLoader: { url in
                requestedURLs.append(url)
                return Data(remotePayload.utf8)
            }
        )

        let imported = try await service.importSources(from: miaogongziSubscriptionURL, into: context)
        let persisted = try context.fetch(FetchDescriptor<RssSourceEntity>())

        XCTAssertEqual(requestedURLs, [expectedRemoteURL])
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported.map(\.sourceName), ["苗公子一号", "苗公子二号"])
        XCTAssertEqual(persisted.map(\.sourceUrl), [
            "https://rss.example.com/feed-1.xml",
            "https://rss.example.com/feed-2.xml"
        ])
    }

    @MainActor
    func testImportSubscriptionURLParsesRealMiaogongziPayload() async throws {
        let context = try makeInMemoryContext()
        let remotePayload = """
        [
          {
            "articleStyle": 0,
            "customOrder": 3,
            "enableJs": true,
            "enabled": true,
            "enabledCookieJar": false,
            "header": "{\\"User-Agent\\":\\"Mozilla/5.0\\"}",
            "lastUpdateTime": 1675946926480,
            "loadWithBaseUrl": true,
            "preload": false,
            "ruleArticles": "id.content@h3",
            "ruleLink": "a@href",
            "ruleTitle": "a@textNodes",
            "showWebLog": false,
            "singleUrl": true,
            "sortUrl": "首页::http://yuedu.miaogongzi.net/gx.html",
            "sourceGroup": "书源",
            "sourceIcon": "data:image/png;base64,AAA",
            "sourceName": "喵公子书源管理",
            "sourceUrl": "http://yuedu.miaogongzi.net/gx.html",
            "type": 0
          }
        ]
        """
        let service = RssSourceImportService(
            remoteDataLoader: { _ in
                Data(remotePayload.utf8)
            }
        )

        let imported = try await service.importSources(from: miaogongziSubscriptionURL, into: context)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.sourceName, "喵公子书源管理")
        XCTAssertEqual(imported.first?.sourceUrl, "http://yuedu.miaogongzi.net/gx.html")
        XCTAssertEqual(imported.first?.sortUrl, "首页::http://yuedu.miaogongzi.net/gx.html")
        XCTAssertTrue(imported.first?.singleUrl ?? false)
        XCTAssertEqual(imported.first?.ruleArticles, "id.content@h3")
        XCTAssertEqual(imported.first?.ruleTitle, "a@textNodes")
        XCTAssertEqual(imported.first?.ruleLink, "a@href")
    }

    func testLoadImportableSourcesSupportsSourceUrlsCollection() async throws {
        let collectionPayload = """
        {
          "sourceUrls": [
            "https://cdn.example.com/a.json",
            "https://cdn.example.com/b.json"
          ]
        }
        """
        let payloadByURL: [String: String] = [
            "https://cdn.example.com/a.json": """
            [
              {
                "sourceUrl": "https://rss.example.com/a.xml",
                "sourceName": "A 源"
              }
            ]
            """,
            "https://cdn.example.com/b.json": """
            [
              {
                "sourceUrl": "https://rss.example.com/b.xml",
                "sourceName": "B 源"
              }
            ]
            """
        ]
        var requestedURLs: [String] = []
        let service = RssSourceImportService(
            remoteDataLoader: { url in
                requestedURLs.append(url.absoluteString)
                if url.absoluteString == "https://subscription.example.com/rss.json" {
                    return Data(collectionPayload.utf8)
                }
                guard let payload = payloadByURL[url.absoluteString] else {
                    throw URLError(.badURL)
                }
                return Data(payload.utf8)
            }
        )

        let payloads = try await service.loadImportableSources(from: "https://subscription.example.com/rss.json")

        XCTAssertEqual(requestedURLs, [
            "https://subscription.example.com/rss.json",
            "https://cdn.example.com/a.json",
            "https://cdn.example.com/b.json"
        ])
        XCTAssertEqual(payloads.map(\.sourceName), ["A 源", "B 源"])
        XCTAssertEqual(payloads.map(\.sourceUrl), [
            "https://rss.example.com/a.xml",
            "https://rss.example.com/b.xml"
        ])
    }

    @MainActor
    private func makeInMemoryContext() throws -> ModelContext {
        let container = try LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}
