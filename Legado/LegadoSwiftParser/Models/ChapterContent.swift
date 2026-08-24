import Foundation

// MARK: - ChapterContent
/// 章节正文内容
public nonisolated struct ChapterContent: Sendable {
    /// 章节标题
    public var title: String
    /// 正文内容（纯文本）
    public var content: String
    /// 下一页 URL（分页加载时使用）
    public var nextPageUrl: String?
    /// 媒体 URL 列表，主要用于音频书源和图片书源。
    public var mediaURLs: [String]
    /// 内容类型：text / audio / image。
    public var contentType: String
    /// 字数统计
    public var wordCount: Int {
        return content.count
    }

    public init(
        title: String = "",
        content: String = "",
        nextPageUrl: String? = nil,
        mediaURLs: [String] = [],
        contentType: String = "text"
    ) {
        self.title = title
        self.content = content
        self.nextPageUrl = nextPageUrl
        self.mediaURLs = mediaURLs
        self.contentType = contentType
    }
}

// MARK: - SearchBook
public nonisolated struct SearchBookOrigin: Hashable, Sendable {
    public var url: String
    public var name: String
    /// Each source owns a different detail URL and rule-variable snapshot. Keeping only the
    /// source URL made a merged search row always open the first source's book URL.
    public var bookUrl: String
    public var infoHtml: String?
    public var sourceVariables: [String: String]
    public var bookVariables: [String: String]
    public var variables: [String: String]

    public init(
        url: String,
        name: String,
        bookUrl: String = "",
        infoHtml: String? = nil,
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        variables: [String: String] = [:]
    ) {
        self.url = url
        self.name = name
        self.bookUrl = bookUrl
        self.infoHtml = infoHtml
        self.sourceVariables = sourceVariables
        self.bookVariables = bookVariables
        self.variables = variables
    }

    // A merged result has one candidate per source. The detail URL and runtime variables are
    // payload for that source, not its identity, and may legitimately change between searches.
    public static func == (lhs: SearchBookOrigin, rhs: SearchBookOrigin) -> Bool {
        normalizedSourceURL(lhs.url) == normalizedSourceURL(rhs.url)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Self.normalizedSourceURL(url))
    }

    private static func normalizedSourceURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

/// 搜索结果书籍信息
public nonisolated struct SearchBook: Identifiable, Sendable {
    /// 唯一标识（用于 List 渲染，避免多书源结果 id 碰撞导致 UI 错乱）
    public var id: UUID
    /// 书籍详情页 URL
    public var bookUrl: String
    /// 书名
    public var name: String
    /// 作者
    public var author: String
    /// 封面 URL
    public var coverUrl: String?
    /// 简介
    public var intro: String?
    /// 分类
    public var kind: String?
    /// 最新章节名
    public var lastChapter: String?
    /// 更新时间
    public var updateTime: String?
    /// 字数
    public var wordCount: String?
    /// 书源 URL（origin）
    public var origin: String
    /// 书源名称（用于搜索结果列表展示来源）
    public var sourceName: String
    /// 同名同作者书籍在其他书源中的来源信息
    public var sourceOrigins: [SearchBookOrigin]
    /// 搜索结果页复用的详情 HTML 缓存
    public var infoHtml: String?
    /// 书源级变量快照
    public var sourceVariables: [String: String]
    /// 书籍级变量快照
    public var bookVariables: [String: String]
    /// 规则运行时变量（用于 legado 的 `@put` / `java.get`）
    public var variables: [String: String]

    public init(
        bookUrl: String = "",
        name: String = "",
        author: String = "",
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        wordCount: String? = nil,
        origin: String = "",
        sourceName: String = "",
        sourceOrigins: [SearchBookOrigin] = [],
        infoHtml: String? = nil,
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        variables: [String: String] = [:]
    ) {
        self.id = UUID()
        self.bookUrl = bookUrl
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.wordCount = wordCount
        self.origin = origin
        self.sourceName = sourceName
        self.sourceOrigins = sourceOrigins
        self.infoHtml = infoHtml
        self.sourceVariables = sourceVariables
        self.bookVariables = bookVariables
        self.variables = variables
    }
}
