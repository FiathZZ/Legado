import Foundation

// MARK: - BookDetail
/// 书籍详情信息
public nonisolated struct BookDetail: Sendable {
    /// 书籍详情页 URL（唯一标识）
    public var bookUrl: String
    /// 书名
    public var name: String
    /// 作者
    public var author: String
    /// 封面图片 URL
    public var coverUrl: String?
    /// 简介
    public var intro: String?
    /// 分类/标签
    public var kind: String?
    /// 最新章节名
    public var lastChapter: String?
    /// 更新时间
    public var updateTime: String?
    /// 目录页 URL
    public var tocUrl: String?
    /// 详情页 HTML 缓存，用于避免二次拉取详情页
    public var infoHtml: String?
    /// 目录页 HTML 缓存，用于 `tocUrl == bookUrl` 时复用详情页内容
    public var tocHtml: String?
    /// 字数
    public var wordCount: String?
    /// 书源 URL
    public var origin: String
    /// 书源级变量快照
    public var sourceVariables: [String: String]
    /// 书籍级变量快照
    public var bookVariables: [String: String]
    /// 规则运行时变量（用于 legado 的 `@put` / `java.get`）
    public var variables: [String: String]

    public init(
        bookUrl: String,
        name: String = "",
        author: String = "",
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        tocUrl: String? = nil,
        infoHtml: String? = nil,
        tocHtml: String? = nil,
        wordCount: String? = nil,
        origin: String = "",
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        variables: [String: String] = [:]
    ) {
        self.bookUrl = bookUrl
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.tocUrl = tocUrl
        self.infoHtml = infoHtml
        self.tocHtml = tocHtml
        self.wordCount = wordCount
        self.origin = origin
        self.sourceVariables = sourceVariables
        self.bookVariables = bookVariables
        self.variables = variables
    }
}
