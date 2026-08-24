import Foundation
import SwiftSoup

// MARK: - RssRuleParser
/// 基于 legado 规则引擎的 RSS 解析器。
struct RssRuleParser {
    func parse(
        body: String,
        source: RssSourceEntity,
        sortName: String,
        requestURL: String,
        responseURL: String
    ) throws -> RssArticlePage {
        let adapter = source.asBookSourceAdapter()
        let baseURL = responseURL.isEmpty ? requestURL : responseURL
        let rootStore = ParserVariableStore(writeScope: .ruleData)
        let listRule = source.ruleArticles?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !listRule.isEmpty else {
            throw ParserError.invalidRule("RSS 列表规则为空")
        }

        let shouldReverse = listRule.hasPrefix("-")
        let effectiveListRule = shouldReverse ? String(listRule.dropFirst()) : listRule
        let analyzeRule = AnalyzeRule(baseUrl: baseURL, source: adapter, variableStore: rootStore)
        let elements = try analyzeRule.getElements(content: body, rule: effectiveListRule)
        let nextPageURL = try resolveNextPage(body: body, source: source, baseURL: baseURL, adapter: adapter)

        var articles = try elements.compactMap { element in
            try parseItem(
                element: element,
                source: source,
                sortName: sortName,
                baseURL: baseURL,
                adapter: adapter
            )
        }

        if shouldReverse {
            articles.reverse()
        }

        return RssArticlePage(
            articles: articles,
            nextPageURL: nextPageURL,
            requestURL: requestURL,
            responseURL: responseURL
        )
    }

    private func parseItem(
        element: Element,
        source: RssSourceEntity,
        sortName: String,
        baseURL: String,
        adapter: BookSource
    ) throws -> RssArticleSummary? {
        let store = ParserVariableStore(writeScope: .ruleData)
        let analyzeRule = AnalyzeRule(baseUrl: baseURL, source: adapter, variableStore: store)

        let title = try analyzeRule.getString(element: element, rule: source.ruleTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }

        let pubDate = try optionalRuleValue(source.rulePubDate, using: analyzeRule, element: element, isURL: false)
        let description = try optionalRuleValue(source.ruleDescription, using: analyzeRule, element: element, isURL: false)
        let image = try optionalRuleValue(source.ruleImage, using: analyzeRule, element: element, isURL: true)
        let rawLink = try optionalRuleValue(source.ruleLink, using: analyzeRule, element: element, isURL: true) ?? baseURL
        let link = RssURLHelper.absoluteURL(rawLink, baseURL: baseURL)

        return RssArticleSummary(
            origin: source.sourceUrl,
            sortName: sortName,
            title: HtmlFormatter.format(title),
            link: link.isEmpty ? baseURL : link,
            pubDate: normalizedOptional(pubDate),
            articleDescription: normalizedOptional(description),
            content: nil,
            image: normalizedOptional(image),
            variableValues: store.snapshot(for: .ruleData, includeInherited: true)
        )
    }

    private func optionalRuleValue(
        _ rule: String?,
        using analyzeRule: AnalyzeRule,
        element: Element,
        isURL: Bool
    ) throws -> String? {
        guard let rule,
              !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try analyzeRule.getString(element: element, rule: rule, isUrl: isURL)
    }

    private func resolveNextPage(
        body: String,
        source: RssSourceEntity,
        baseURL: String,
        adapter: BookSource
    ) throws -> String? {
        guard let ruleNextPage = source.ruleNextPage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ruleNextPage.isEmpty else {
            return nil
        }

        if ruleNextPage.uppercased() == "PAGE" {
            return baseURL
        }

        let analyzeRule = AnalyzeRule(baseUrl: baseURL, source: adapter, variableStore: ParserVariableStore(writeScope: .ruleData))
        let value = try analyzeRule.getString(content: body, rule: ruleNextPage, isUrl: true)
        let resolved = RssURLHelper.absoluteURL(value, baseURL: baseURL)
        return resolved.isEmpty ? nil : resolved
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
