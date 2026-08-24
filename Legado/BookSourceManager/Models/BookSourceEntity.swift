import SwiftData
import Foundation
import Combine

// MARK: - BookSourceEntity
/// SwiftData 持久化实体，对应书源配置。
/// 嵌套规则结构体（SearchRule、TocRule 等）序列化为 JSON 字符串存储，
/// 通过计算属性提供与 BookSource 结构体的互转。
@Model
final class BookSourceEntity {

    // MARK: 基础信息
    @Attribute(.unique) var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int
    var bookUrlPattern: String?
    var enabled: Bool
    var enabledExplore: Bool
    var bookSourceComment: String?
    var lastUpdateTime: Int64

    // MARK: 认证与请求头
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var header: String?
    var cookieJar: String?
    var concurrentRate: String?
    var jsLib: String?

    // MARK: 搜索 / 探索 URL
    var searchUrl: String?
    var exploreUrl: String?

    // MARK: 规则 JSON（嵌套结构体序列化存储）
    var ruleSearchJSON: String?
    var ruleExploreJSON: String?
    var ruleBookInfoJSON: String?
    var ruleTocJSON: String?
    var ruleContentJSON: String?

    // MARK: Init
    init(
        bookSourceUrl: String,
        bookSourceName: String,
        bookSourceGroup: String? = nil,
        bookSourceType: Int = 0,
        bookUrlPattern: String? = nil,
        enabled: Bool = true,
        enabledExplore: Bool = true,
        bookSourceComment: String? = nil,
        lastUpdateTime: Int64 = 0,
        loginUrl: String? = nil,
        loginUi: String? = nil,
        loginCheckJs: String? = nil,
        coverDecodeJs: String? = nil,
        header: String? = nil,
        cookieJar: String? = nil,
        concurrentRate: String? = nil,
        jsLib: String? = nil,
        searchUrl: String? = nil,
        exploreUrl: String? = nil,
        ruleSearchJSON: String? = nil,
        ruleExploreJSON: String? = nil,
        ruleBookInfoJSON: String? = nil,
        ruleTocJSON: String? = nil,
        ruleContentJSON: String? = nil
    ) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.bookSourceGroup = bookSourceGroup
        self.bookSourceType = bookSourceType
        self.bookUrlPattern = bookUrlPattern
        self.enabled = enabled
        self.enabledExplore = enabledExplore
        self.bookSourceComment = bookSourceComment
        self.lastUpdateTime = lastUpdateTime
        self.loginUrl = loginUrl
        self.loginUi = loginUi
        self.loginCheckJs = loginCheckJs
        self.coverDecodeJs = coverDecodeJs
        self.header = header
        self.cookieJar = cookieJar
        self.concurrentRate = concurrentRate
        self.jsLib = jsLib
        self.searchUrl = searchUrl
        self.exploreUrl = exploreUrl
        self.ruleSearchJSON = ruleSearchJSON
        self.ruleExploreJSON = ruleExploreJSON
        self.ruleBookInfoJSON = ruleBookInfoJSON
        self.ruleTocJSON = ruleTocJSON
        self.ruleContentJSON = ruleContentJSON
    }

    // MARK: 与 BookSource 结构体互转

    /// 从 BookSource 结构体创建实体
    convenience init(source: BookSource) {
        self.init(
            bookSourceUrl: source.bookSourceUrl,
            bookSourceName: source.bookSourceName,
            bookSourceGroup: source.bookSourceGroup,
            bookSourceType: source.bookSourceType,
            bookUrlPattern: source.bookUrlPattern,
            enabled: source.enabled,
            enabledExplore: source.enabledExplore,
            bookSourceComment: source.bookSourceComment,
            lastUpdateTime: source.lastUpdateTime,
            loginUrl: source.loginUrl,
            loginUi: source.loginUi,
            loginCheckJs: source.loginCheckJs,
            coverDecodeJs: source.coverDecodeJs,
            header: source.header,
            cookieJar: source.cookieJar,
            concurrentRate: source.concurrentRate,
            jsLib: source.jsLib,
            searchUrl: source.searchUrl,
            exploreUrl: source.exploreUrl,
            ruleSearchJSON: BookSourceEntity.encode(source.ruleSearch),
            ruleExploreJSON: BookSourceEntity.encode(source.ruleExplore),
            ruleBookInfoJSON: BookSourceEntity.encode(source.ruleBookInfo),
            ruleTocJSON: BookSourceEntity.encode(source.ruleToc),
            ruleContentJSON: BookSourceEntity.encode(source.ruleContent)
        )
    }

    /// 将实体转换为 BookSource 结构体
    func toBookSource() -> BookSource {
        BookSource(
            bookSourceName: bookSourceName,
            bookSourceUrl: bookSourceUrl,
            bookSourceGroup: bookSourceGroup,
            bookSourceType: bookSourceType,
            bookUrlPattern: bookUrlPattern,
            enabled: enabled,
            enabledExplore: enabledExplore,
            bookSourceComment: bookSourceComment,
            loginUrl: loginUrl,
            loginUi: loginUi,
            loginCheckJs: loginCheckJs,
            coverDecodeJs: coverDecodeJs,
            header: header,
            cookieJar: cookieJar,
            concurrentRate: concurrentRate,
            jsLib: jsLib,
            lastUpdateTime: lastUpdateTime,
            searchUrl: searchUrl,
            ruleSearch: BookSourceEntity.decode(ruleSearchJSON),
            exploreUrl: exploreUrl,
            ruleExplore: BookSourceEntity.decode(ruleExploreJSON),
            ruleBookInfo: BookSourceEntity.decode(ruleBookInfoJSON),
            ruleToc: BookSourceEntity.decode(ruleTocJSON),
            ruleContent: BookSourceEntity.decode(ruleContentJSON)
        )
    }

    /// 用 BookSource 的最新数据更新当前实体（不重新插入，原地更新）
    func update(from source: BookSource) {
        bookSourceName = source.bookSourceName
        bookSourceGroup = source.bookSourceGroup
        bookSourceType = source.bookSourceType
        bookUrlPattern = source.bookUrlPattern
        enabled = source.enabled
        enabledExplore = source.enabledExplore
        bookSourceComment = source.bookSourceComment
        lastUpdateTime = source.lastUpdateTime
        loginUrl = source.loginUrl
        loginUi = source.loginUi
        loginCheckJs = source.loginCheckJs
        coverDecodeJs = source.coverDecodeJs
        header = source.header
        cookieJar = source.cookieJar
        concurrentRate = source.concurrentRate
        jsLib = source.jsLib
        searchUrl = source.searchUrl
        exploreUrl = source.exploreUrl
        ruleSearchJSON = BookSourceEntity.encode(source.ruleSearch)
        ruleExploreJSON = BookSourceEntity.encode(source.ruleExplore)
        ruleBookInfoJSON = BookSourceEntity.encode(source.ruleBookInfo)
        ruleTocJSON = BookSourceEntity.encode(source.ruleToc)
        ruleContentJSON = BookSourceEntity.encode(source.ruleContent)
    }

    // MARK: 私有序列化辅助
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
