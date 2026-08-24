import Foundation
import SwiftData

// MARK: - RssArticleEntity
/// RSS 文章持久化实体。
///
/// SwiftData 当前不支持声明复合唯一键，这里用 `origin + link` 组合成稳定唯一键。
@Model
final class RssArticleEntity {
    @Attribute(.unique) var articleKey: String
    var origin: String
    var sort: String
    var title: String
    var order: Int64
    var link: String
    var pubDate: String?
    var articleDescription: String?
    var content: String?
    var image: String?
    var group: String
    var read: Bool
    var variable: String?

    init(
        origin: String,
        sort: String = "",
        title: String,
        order: Int64 = 0,
        link: String,
        pubDate: String? = nil,
        articleDescription: String? = nil,
        content: String? = nil,
        image: String? = nil,
        group: String = "默认分组",
        read: Bool = false,
        variable: String? = nil
    ) {
        self.articleKey = Self.makeArticleKey(origin: origin, link: link)
        self.origin = origin
        self.sort = sort
        self.title = title
        self.order = order
        self.link = link
        self.pubDate = pubDate
        self.articleDescription = articleDescription
        self.content = content
        self.image = image
        self.group = group
        self.read = read
        self.variable = variable
    }

    static func makeArticleKey(origin: String, link: String) -> String {
        "\(origin)\n\(link)"
    }
}
