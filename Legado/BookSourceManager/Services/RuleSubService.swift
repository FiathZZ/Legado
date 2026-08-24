import Foundation
import SwiftData
import SwiftSoup

struct RuleSubUpdateSummary {
    let subscriptionID: String
    let importedCount: Int
    let addedCount: Int
    let contentKind: ContentKind
    let linkedBookSourceImportedCount: Int
    let linkedBookSourceAddedCount: Int

    enum ContentKind: Equatable {
        case bookSource
        case rssSource

        var displayName: String {
            switch self {
            case .bookSource:
                return "书源"
            case .rssSource:
                return "RSS 源"
            }
        }
    }
}

struct RuleSubBatchUpdateSummary {
    let updatedSubscriptionCount: Int
    let importedCount: Int
    let addedCount: Int
    let failedSubscriptionNames: [String]

    static let empty = RuleSubBatchUpdateSummary(
        updatedSubscriptionCount: 0,
        importedCount: 0,
        addedCount: 0,
        failedSubscriptionNames: []
    )
}

enum RuleSubService {
    private static let autoUpdateInterval: TimeInterval = 24 * 60 * 60

    @MainActor
    static func fetchAll(in context: ModelContext) -> [RuleSubEntity] {
        let descriptor = FetchDescriptor<RuleSubEntity>(
            sortBy: [
                SortDescriptor(\.order, order: .forward),
                SortDescriptor(\.name, order: .forward)
            ]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func updateSubscription(
        _ sub: RuleSubEntity,
        in context: ModelContext
    ) async throws -> RuleSubUpdateSummary {
        let normalizedURL = try normalizedSubscriptionURL(from: sub.url)
        let parsedSubscription = try? BookSourceService.parseSubscription(normalizedURL)
        let summary: RuleSubUpdateSummary

        switch parsedSubscription?.kind {
        case .rssSource:
            let existingURLs = fetchRssSourceURLSet(in: context)
            let importedSources = try await RssSourceImportService().importSources(from: normalizedURL, into: context)
            let addedCount = Set(importedSources.map(\.sourceUrl)).subtracting(existingURLs).count
            let existingBookSourceURLs = BookSourceRepository.fetchURLSet(in: context)
            let linkedBookSources = await RssLinkedBookSourceImporter().importLinkedBookSources(
                from: importedSources,
                into: context
            )
            let linkedBookSourceAddedCount = Set(linkedBookSources.map(\.bookSourceUrl))
                .subtracting(existingBookSourceURLs)
                .count
            summary = RuleSubUpdateSummary(
                subscriptionID: sub.id,
                importedCount: importedSources.count,
                addedCount: addedCount,
                contentKind: .rssSource,
                linkedBookSourceImportedCount: linkedBookSources.count,
                linkedBookSourceAddedCount: linkedBookSourceAddedCount
            )
        case .bookSource, .none:
            let existingURLs = BookSourceRepository.fetchURLSet(in: context)
            let importedSources = try await fetchBookSources(for: normalizedURL)
            BookSourceRepository.merge(sources: importedSources, in: context)
            let addedCount = Set(importedSources.map(\.bookSourceUrl)).subtracting(existingURLs).count
            summary = RuleSubUpdateSummary(
                subscriptionID: sub.id,
                importedCount: importedSources.count,
                addedCount: addedCount,
                contentKind: .bookSource,
                linkedBookSourceImportedCount: 0,
                linkedBookSourceAddedCount: 0
            )
        }

        sub.url = normalizedURL
        sub.lastUpdateTime = .now
        try context.save()
        ParserLog.debug(
            "RuleSubService",
            "updated name=\(sub.name) kind=\(summary.contentKind.displayName) imported=\(summary.importedCount) added=\(summary.addedCount) linkedBookSources=\(summary.linkedBookSourceImportedCount)"
        )

        return summary
    }

    @MainActor
    static func updateAllSubscriptions(
        subs: [RuleSubEntity],
        in context: ModelContext,
        onlyAutoUpdate: Bool,
        onlyDue: Bool = false
    ) async -> RuleSubBatchUpdateSummary {
        let targets = subs.filter { sub in
            (!onlyAutoUpdate || sub.autoUpdate) && (!onlyDue || needsAutoUpdate(sub))
        }
        guard !targets.isEmpty else { return .empty }

        var updatedSubscriptionCount = 0
        var importedCount = 0
        var addedCount = 0
        var failedSubscriptionNames: [String] = []

        for sub in targets {
            do {
                let summary = try await updateSubscription(sub, in: context)
                updatedSubscriptionCount += 1
                importedCount += summary.importedCount
                addedCount += summary.addedCount
            } catch {
                failedSubscriptionNames.append(sub.name)
                ParserLog.debug(
                    "RuleSubService",
                    "update failed name=\(sub.name) error=\(error.localizedDescription)"
                )
            }
        }

        return RuleSubBatchUpdateSummary(
            updatedSubscriptionCount: updatedSubscriptionCount,
            importedCount: importedCount,
            addedCount: addedCount,
            failedSubscriptionNames: failedSubscriptionNames
        )
    }

    static func needsAutoUpdate(_ sub: RuleSubEntity, now: Date = .now) -> Bool {
        guard sub.autoUpdate else { return false }
        guard let lastUpdateTime = sub.lastUpdateTime else { return true }
        return now.timeIntervalSince(lastUpdateTime) >= autoUpdateInterval
    }

    static func normalizedSubscriptionURL(from rawValue: String) throws -> String {
        let trimmed = rawValue
            .normalizedImportURLString()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BookSourceServiceError.invalidRemoteURL
        }
        if trimmed.hasPrefix("yuedu://") {
            _ = try BookSourceService.parseSubscription(trimmed)
            return trimmed
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw BookSourceServiceError.invalidRemoteURL
        }
        return trimmed
    }

    static func suggestedName(for urlString: String) -> String {
        if urlString.hasPrefix("yuedu://"),
           let remoteURL = try? BookSourceService.parseSubscription(urlString).remoteURL,
           let host = remoteURL.host,
           !host.isEmpty {
            return host
        }
        if let url = URL(string: urlString),
           let host = url.host,
           !host.isEmpty {
            return host
        }
        return "书源订阅"
    }

    @MainActor
    private static func fetchRssSourceURLSet(in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<RssSourceEntity>()
        let entities = (try? context.fetch(descriptor)) ?? []
        return Set(entities.map(\.sourceUrl))
    }

    private static func fetchBookSources(for urlString: String) async throws -> [BookSource] {
        if urlString.hasPrefix("yuedu://") {
            return try await BookSourceService.importFromSubscription(urlString)
        }
        return try await BookSourceService.importFromHTTPURL(urlString)
    }
}

struct RssLinkedBookSourceImporter {
    func importLinkedBookSources(
        from rssSources: [RssSourceEntity],
        into context: ModelContext
    ) async -> [BookSource] {
        do {
            let bookSources = try await loadLinkedBookSources(from: rssSources)
            guard !bookSources.isEmpty else { return [] }
            BookSourceRepository.merge(sources: bookSources, in: context)
            return bookSources
        } catch {
            ParserLog.debug(
                "RuleSubService",
                "linked book source import skipped error=\(error.localizedDescription)"
            )
            return []
        }
    }

    func loadLinkedBookSources(from rssSources: [RssSourceEntity]) async throws -> [BookSource] {
        let importURLs = try await discoverBookSourceImportURLs(from: rssSources)
        guard !importURLs.isEmpty else { return [] }

        var mergedSourcesByURL: [String: BookSource] = [:]
        for importURL in importURLs {
            let sources = try await BookSourceService.importFromAnyURLString(importURL)
            for source in sources {
                mergedSourcesByURL[source.bookSourceUrl] = source
            }
        }
        return Array(mergedSourcesByURL.values)
            .sorted { $0.bookSourceUrl < $1.bookSourceUrl }
    }

    private func discoverBookSourceImportURLs(from rssSources: [RssSourceEntity]) async throws -> [String] {
        var discovered: [String] = []
        var seen: Set<String> = []

        for rssSource in rssSources {
            guard let pageURL = URL(string: rssSource.sourceUrl.normalizedImportURLString()) else {
                continue
            }
            guard ["http", "https", "file"].contains(pageURL.scheme?.lowercased() ?? "") else {
                continue
            }

            let html = try await loadText(from: pageURL)
            for importURL in extractBookSourceImportURLs(from: html, baseURL: pageURL) {
                if seen.insert(importURL).inserted {
                    discovered.append(importURL)
                }
            }
        }

        return discovered
    }

    private func loadText(from url: URL) async throws -> String {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (responseData, _) = try await URLSession.shared.data(from: url)
            data = responseData
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func extractBookSourceImportURLs(from html: String, baseURL: URL) -> [String] {
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return [] }
        guard let anchors = try? document.select("a[href]").array() else { return [] }

        var results: [String] = []
        var seen: Set<String> = []

        for anchor in anchors {
            guard let href = try? anchor.attr("href"),
                  !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let absoluteHref: String
            if href.hasPrefix("yuedu://") {
                absoluteHref = href
            } else {
                absoluteHref = ((try? anchor.attr("abs:href")) ?? href)
            }

            let normalized = absoluteHref
                .normalizedImportURLString()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            if normalized.hasPrefix("yuedu://") {
                guard let parsed = try? BookSourceService.parseSubscription(normalized),
                      parsed.kind == .bookSource else {
                    continue
                }
                if seen.insert(normalized).inserted {
                    results.append(normalized)
                }
                continue
            }

            guard let url = URL(string: normalized),
                  ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            let lowercasedPath = url.path.lowercased()
            guard lowercasedPath.hasSuffix(".json") || lowercasedPath.hasSuffix(".txt") else {
                continue
            }
            if seen.insert(url.absoluteString).inserted {
                results.append(url.absoluteString)
            }
        }

        return results
    }
}
