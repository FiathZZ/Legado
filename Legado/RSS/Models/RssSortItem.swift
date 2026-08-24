import Foundation

// MARK: - RssSortItem
/// RSS 分类项。
struct RssSortItem: Identifiable, Hashable, Sendable {
    let name: String
    let url: String

    var id: String {
        "\(name)\n\(url)"
    }
}

// MARK: - RssArticleSummary
/// RSS 文章统一输出模型，供列表页与阅读页复用。
struct RssArticleSummary: Identifiable, Hashable, Sendable {
    let origin: String
    let sortName: String
    let title: String
    let link: String
    let pubDate: String?
    let articleDescription: String?
    let content: String?
    let image: String?
    let variableValues: [String: String]

    var id: String {
        RssArticleEntity.makeArticleKey(origin: origin, link: link)
    }

    func makeEntity(order: Int64, group: String = "默认分组") -> RssArticleEntity {
        RssArticleEntity(
            origin: origin,
            sort: sortName,
            title: title,
            order: order,
            link: link,
            pubDate: pubDate,
            articleDescription: articleDescription,
            content: content,
            image: image,
            group: group,
            variable: RssArticleSummary.encodeVariables(variableValues)
        )
    }

    func updatingEntity(_ entity: RssArticleEntity, order: Int64) {
        entity.origin = origin
        entity.sort = sortName
        entity.title = title
        entity.order = order
        entity.link = link
        entity.pubDate = pubDate
        entity.articleDescription = articleDescription
        entity.content = content
        entity.image = image
        entity.variable = RssArticleSummary.encodeVariables(variableValues)
    }

    func articleVariableStore() -> ParserVariableStore {
        ParserVariableStore(values: variableValues, writeScope: .ruleData)
    }

    private static func encodeVariables(_ values: [String: String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

// MARK: - RssArticlePage
/// RSS 文章列表分页结果。
struct RssArticlePage: Sendable {
    let articles: [RssArticleSummary]
    let nextPageURL: String?
    let requestURL: String
    let responseURL: String
}

// MARK: - RssContentResult
/// RSS 正文解析结果。
struct RssContentResult: Sendable {
    let title: String
    let content: String?
    let html: String?
    let articleURL: String
    let baseURL: String?
    let shouldFallbackToWebView: Bool
}
