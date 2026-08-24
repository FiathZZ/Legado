import Foundation
import SwiftData

// MARK: - RssService
/// RSS 主业务服务，负责列表请求、正文请求与 SwiftData 落库。
struct RssService {
    private let defaultParser = RssDefaultParser()
    private let ruleParser = RssRuleParser()

    func fetchArticles(
        from source: RssSourceEntity,
        sort: RssSortItem,
        page: Int
    ) async throws -> RssArticlePage {
        let adapter = source.asBookSourceAdapter()
        let analyzeUrl = AnalyzeUrl(
            rule: sort.url,
            page: page,
            baseUrl: source.sourceUrl,
            headerString: source.header,
            source: adapter
        )
        let response = try await send(analyzeUrl: analyzeUrl, source: source)
        let responseText = response.text ?? String(decoding: response.data, as: UTF8.self)
        let requestURL = analyzeUrl.urlString
        let responseURL = response.url?.absoluteString ?? requestURL

        if let articleRule = source.ruleArticles?.trimmingCharacters(in: .whitespacesAndNewlines),
           !articleRule.isEmpty {
            return try ruleParser.parse(
                body: responseText,
                source: source,
                sortName: sort.name,
                requestURL: requestURL,
                responseURL: responseURL
            )
        }

        let articles = try defaultParser.parse(data: response.data, source: source, sortName: sort.name)
        return RssArticlePage(
            articles: articles,
            nextPageURL: nil,
            requestURL: requestURL,
            responseURL: responseURL
        )
    }

    func fetchContent(
        for article: RssArticleSummary,
        source: RssSourceEntity
    ) async throws -> RssContentResult {
        if let inlineContent = preferredInlineContent(for: article) {
            return RssContentResult(
                title: article.title,
                content: inlineContent,
                html: article.content ?? article.articleDescription,
                articleURL: article.link,
                baseURL: source.loadWithBaseUrl ? article.link : nil,
                shouldFallbackToWebView: false
            )
        }

        let contentRule = source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !contentRule.isEmpty else {
            return RssContentResult(
                title: article.title,
                content: nil,
                html: nil,
                articleURL: article.link,
                baseURL: source.loadWithBaseUrl ? article.link : nil,
                shouldFallbackToWebView: true
            )
        }

        let adapter = source.asBookSourceAdapter()
        let analyzeUrl = AnalyzeUrl(
            rule: article.link,
            baseUrl: source.sourceUrl,
            headerString: source.header,
            source: adapter,
            variableStore: article.articleVariableStore()
        )
        let response = try await send(analyzeUrl: analyzeUrl, source: source)
        let responseText = response.text ?? String(decoding: response.data, as: UTF8.self)
        let finalURL = response.url?.absoluteString ?? article.link
        let analyzeRule = AnalyzeRule(
            baseUrl: finalURL,
            source: adapter,
            variableStore: article.articleVariableStore()
        )
        let parsed = try analyzeRule.getString(content: responseText, rule: contentRule)
        let normalized = parsed.trimmingCharacters(in: .whitespacesAndNewlines)

        return RssContentResult(
            title: article.title,
            content: normalized.isEmpty ? nil : HtmlFormatter.format(normalized),
            html: normalized.isEmpty ? nil : parsed,
            articleURL: article.link,
            baseURL: source.loadWithBaseUrl ? finalURL : nil,
            shouldFallbackToWebView: normalized.isEmpty
        )
    }

    @MainActor
    func upsertArticles(
        _ articles: [RssArticleSummary],
        source: RssSourceEntity,
        sortName: String,
        into context: ModelContext
    ) throws -> [RssArticleEntity] {
        let descriptor = FetchDescriptor<RssArticleEntity>()
        let existing = (try? context.fetch(descriptor)) ?? []
        var existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.articleKey, $0) })
        var persisted: [RssArticleEntity] = []

        for (index, article) in articles.enumerated() {
            let key = RssArticleEntity.makeArticleKey(origin: article.origin, link: article.link)
            let entity: RssArticleEntity
            if let existingEntity = existingMap[key] {
                article.updatingEntity(existingEntity, order: Int64(index))
                existingEntity.sort = sortName
                entity = existingEntity
            } else {
                entity = article.makeEntity(order: Int64(index))
                entity.sort = sortName
                context.insert(entity)
                existingMap[key] = entity
            }
            persisted.append(entity)
        }

        try context.save()
        return persisted
    }

    private func send(analyzeUrl: AnalyzeUrl, source: RssSourceEntity) async throws -> HTTPResponse {
        let client = HTTPClient()
        let sourceHeaders = HTTPClient.resolvedSourceHeaders(
            baseUrl: source.sourceUrl,
            source: source.asBookSourceAdapter()
        )
        for (key, value) in sourceHeaders {
            client.defaultHeaders[key] = value
        }

        let request = HTTPClient.makeRequest(from: analyzeUrl)
        let limiter = ConcurrentRateLimiter(sourceKey: source.sourceUrl, concurrentRate: source.concurrentRate)
        return try await limiter.withLimit {
            try await client.send(request: request)
        }
    }

    private func preferredInlineContent(for article: RssArticleSummary) -> String? {
        if let content = article.content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return HtmlFormatter.format(content)
        }
        if let description = article.articleDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return HtmlFormatter.format(description)
        }
        return nil
    }
}

// MARK: - Helpers
enum RssURLHelper {
    static func absoluteURL(_ value: String, baseURL: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if let resolved = URL(string: trimmed, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString {
            return resolved
        }
        return AnalyzeUrl.postProcessExtractedURL(trimmed, baseUrl: baseURL)
    }
}

extension RssSourceEntity {
    func asBookSourceAdapter() -> BookSource {
        BookSource(
            bookSourceName: sourceName,
            bookSourceUrl: sourceUrl,
            bookSourceGroup: sourceGroup,
            enabled: enabled,
            bookSourceComment: sourceComment,
            loginUrl: loginUrl,
            loginUi: loginUi,
            loginCheckJs: loginCheckJs,
            coverDecodeJs: coverDecodeJs,
            header: header,
            concurrentRate: concurrentRate,
            jsLib: jsLib,
            lastUpdateTime: lastUpdateTime
        )
    }
}
