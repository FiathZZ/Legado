import Foundation

// MARK: - BookChapter
/// 章节目录条目
public nonisolated struct BookChapter: Codable, Identifiable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case index
        case title
        case url
        case baseUrl
        case bookUrl
        case isVolume
        case isVip
        case isPay
        case updateTime
        case wordCount
        case sourceVariables
        case bookVariables
        case chapterVariables
        case variables
    }

    public var id: String { url.isEmpty ? "\(index)" : url }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(url)
    }

    public static func == (lhs: BookChapter, rhs: BookChapter) -> Bool {
        lhs.index == rhs.index && lhs.url == rhs.url
    }
    /// 章节序号（从 0 开始）
    public var index: Int
    /// 章节名称
    public var title: String
    /// 章节详情页 URL
    public var url: String
    /// 请求时使用的基础 URL
    public var baseUrl: String
    /// 所属书籍 URL
    public var bookUrl: String
    /// 是否为卷标题
    public var isVolume: Bool
    /// 是否为 VIP 章节
    public var isVip: Bool
    /// 是否需要付费
    public var isPay: Bool
    /// 更新时间
    public var updateTime: String?
    /// 章节字数
    public var wordCount: Int?
    /// 书源级变量快照
    public var sourceVariables: [String: String]
    /// 书籍级变量快照
    public var bookVariables: [String: String]
    /// 章节级变量快照
    public var chapterVariables: [String: String]
    /// 规则运行时变量（用于 legado 的 `@put` / `java.get`）
    public var variables: [String: String]

    public init(
        index: Int = 0,
        title: String = "",
        url: String = "",
        baseUrl: String = "",
        bookUrl: String = "",
        isVolume: Bool = false,
        isVip: Bool = false,
        isPay: Bool = false,
        updateTime: String? = nil,
        wordCount: Int? = nil,
        sourceVariables: [String: String] = [:],
        bookVariables: [String: String] = [:],
        chapterVariables: [String: String] = [:],
        variables: [String: String] = [:]
    ) {
        self.index = index
        self.title = title
        self.url = url
        self.baseUrl = baseUrl
        self.bookUrl = bookUrl
        self.isVolume = isVolume
        self.isVip = isVip
        self.isPay = isPay
        self.updateTime = updateTime
        self.wordCount = wordCount
        self.sourceVariables = sourceVariables
        self.bookVariables = bookVariables
        self.chapterVariables = chapterVariables
        self.variables = variables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        bookUrl = try container.decodeIfPresent(String.self, forKey: .bookUrl) ?? ""
        isVolume = try container.decodeIfPresent(Bool.self, forKey: .isVolume) ?? false
        isVip = try container.decodeIfPresent(Bool.self, forKey: .isVip) ?? false
        isPay = try container.decodeIfPresent(Bool.self, forKey: .isPay) ?? false
        updateTime = try container.decodeIfPresent(String.self, forKey: .updateTime)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
        sourceVariables = try container.decodeIfPresent([String: String].self, forKey: .sourceVariables) ?? [:]
        bookVariables = try container.decodeIfPresent([String: String].self, forKey: .bookVariables) ?? [:]
        chapterVariables = try container.decodeIfPresent([String: String].self, forKey: .chapterVariables) ?? [:]
        variables = try container.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(baseUrl, forKey: .baseUrl)
        try container.encode(bookUrl, forKey: .bookUrl)
        try container.encode(isVolume, forKey: .isVolume)
        try container.encode(isVip, forKey: .isVip)
        try container.encode(isPay, forKey: .isPay)
        try container.encodeIfPresent(updateTime, forKey: .updateTime)
        try container.encodeIfPresent(wordCount, forKey: .wordCount)
        try container.encode(sourceVariables, forKey: .sourceVariables)
        try container.encode(bookVariables, forKey: .bookVariables)
        try container.encode(chapterVariables, forKey: .chapterVariables)
        try container.encode(variables, forKey: .variables)
    }
}
