import Foundation

// MARK: - BookSource
/// 书源配置模型，对应 legado 的书源规则定义
public nonisolated struct BookSource: Codable, Sendable {
    // MARK: 基础信息
    /// 书源名称
    public var bookSourceName: String
    /// 书源 URL（唯一标识）
    public var bookSourceUrl: String
    /// 书源分组
    public var bookSourceGroup: String?
    /// 书源类型：0=文本，1=音频，2=图片
    public var bookSourceType: Int
    /// 详情页 URL 正则，用于识别搜索结果页直接返回详情页的场景
    public var bookUrlPattern: String?
    /// 是否启用
    public var enabled: Bool
    /// 是否启用探索
    public var enabledExplore: Bool
    /// 书源注释
    public var bookSourceComment: String?
    /// 登录 URL
    public var loginUrl: String?
    /// 登录用户信息（JSON 格式）
    public var loginUi: String?
    /// 登录检测 JS
    public var loginCheckJs: String?
    /// 封面图片二次解密 JS（对应 legado `coverDecodeJs`）
    public var coverDecodeJs: String?
    /// 自定义请求头（JSON 格式）
    public var header: String?
    /// Cookie 字符串
    public var cookieJar: String?
    /// 是否启用 Android legado 风格的自动 CookieJar 保存/回灌
    public var enabledCookieJar: Bool
    /// 并发/速率限制，兼容 legado `concurrentRate` 字段
    public var concurrentRate: String?
    /// 共享 JS 库（注入到每次 JS 执行上下文）
    public var jsLib: String?
    /// 最后更新时间（毫秒时间戳）
    public var lastUpdateTime: Int64

    /// 是否为漫画源（图片类型，或分组/名称含"漫画"）
    public var isMangaSource: Bool {
        if bookSourceType == 2 { return true }
        let mangaKeyword = "漫画"
        if bookSourceName.contains(mangaKeyword) { return true }
        if bookSourceGroup?.contains(mangaKeyword) == true { return true }
        return false
    }

    // MARK: 搜索规则
    /// 搜索 URL 规则
    public var searchUrl: String?
    /// 搜索规则
    public var ruleSearch: SearchRule?

    // MARK: 探索规则
    /// 探索 URL（JSON 格式）
    public var exploreUrl: String?
    /// 探索规则
    public var ruleExplore: ExploreRule?

    // MARK: 书籍信息规则
    public var ruleBookInfo: BookInfoRule?

    // MARK: 目录规则
    public var ruleToc: TocRule?

    // MARK: 内容规则
    public var ruleContent: ContentRule?

    public init(
        bookSourceName: String,
        bookSourceUrl: String,
        bookSourceGroup: String? = nil,
        bookSourceType: Int = 0,
        bookUrlPattern: String? = nil,
        enabled: Bool = true,
        enabledExplore: Bool = true,
        bookSourceComment: String? = nil,
        loginUrl: String? = nil,
        loginUi: String? = nil,
        loginCheckJs: String? = nil,
        coverDecodeJs: String? = nil,
        header: String? = nil,
        cookieJar: String? = nil,
        enabledCookieJar: Bool = true,
        concurrentRate: String? = nil,
        jsLib: String? = nil,
        lastUpdateTime: Int64 = 0,
        searchUrl: String? = nil,
        ruleSearch: SearchRule? = nil,
        exploreUrl: String? = nil,
        ruleExplore: ExploreRule? = nil,
        ruleBookInfo: BookInfoRule? = nil,
        ruleToc: TocRule? = nil,
        ruleContent: ContentRule? = nil
    ) {
        self.bookSourceName = bookSourceName
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceGroup = bookSourceGroup
        self.bookSourceType = bookSourceType
        self.bookUrlPattern = bookUrlPattern
        self.enabled = enabled
        self.enabledExplore = enabledExplore
        self.bookSourceComment = bookSourceComment
        self.loginUrl = loginUrl
        self.loginUi = loginUi
        self.loginCheckJs = loginCheckJs
        self.coverDecodeJs = coverDecodeJs
        self.header = header
        self.cookieJar = cookieJar
        self.enabledCookieJar = enabledCookieJar
        self.concurrentRate = concurrentRate
        self.jsLib = jsLib
        self.lastUpdateTime = lastUpdateTime
        self.searchUrl = searchUrl
        self.ruleSearch = ruleSearch
        self.exploreUrl = exploreUrl
        self.ruleExplore = ruleExplore
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
    }

    enum CodingKeys: String, CodingKey {
        case bookSourceName
        case bookSourceUrl
        case bookSourceGroup
        case bookSourceType
        case bookUrlPattern
        case enabled
        case enabledExplore
        case bookSourceComment
        case loginUrl
        case loginUi
        case loginCheckJs
        case coverDecodeJs
        case header
        case cookieJar
        case enabledCookieJar
        case concurrentRate
        case jsLib
        case lastUpdateTime
        case searchUrl
        case ruleSearch
        case exploreUrl
        case ruleExplore
        case ruleBookInfo
        case ruleToc
        case ruleContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bookSourceName = try container.decode(String.self, forKey: .bookSourceName)
        self.bookSourceUrl = try container.decode(String.self, forKey: .bookSourceUrl)
        self.bookSourceGroup = try container.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        self.bookSourceType = try container.decodeIfPresent(Int.self, forKey: .bookSourceType) ?? 0
        self.bookUrlPattern = try container.decodeIfPresent(String.self, forKey: .bookUrlPattern)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.enabledExplore = try container.decodeIfPresent(Bool.self, forKey: .enabledExplore) ?? true
        self.bookSourceComment = try container.decodeIfPresent(String.self, forKey: .bookSourceComment)
        self.loginUrl = try container.decodeIfPresent(String.self, forKey: .loginUrl)
        self.loginUi = try container.decodeIfPresent(String.self, forKey: .loginUi)
        self.loginCheckJs = try container.decodeIfPresent(String.self, forKey: .loginCheckJs)
        self.coverDecodeJs = try container.decodeIfPresent(String.self, forKey: .coverDecodeJs)
        self.header = try container.decodeIfPresent(String.self, forKey: .header)
        self.cookieJar = try container.decodeIfPresent(String.self, forKey: .cookieJar)
        self.enabledCookieJar = try container.decodeIfPresent(Bool.self, forKey: .enabledCookieJar) ?? true
        self.concurrentRate = try container.decodeIfPresent(String.self, forKey: .concurrentRate)
        self.jsLib = try container.decodeIfPresent(String.self, forKey: .jsLib)
        self.lastUpdateTime = try Self.decodeInt64(from: container, forKey: .lastUpdateTime) ?? 0
        self.searchUrl = try container.decodeIfPresent(String.self, forKey: .searchUrl)
        self.ruleSearch = try Self.decodeRule(SearchRule.self, from: container, forKey: .ruleSearch)
        self.exploreUrl = try container.decodeIfPresent(String.self, forKey: .exploreUrl)
        self.ruleExplore = try Self.decodeRule(ExploreRule.self, from: container, forKey: .ruleExplore)
        self.ruleBookInfo = try Self.decodeRule(BookInfoRule.self, from: container, forKey: .ruleBookInfo)
        self.ruleToc = try Self.decodeRule(TocRule.self, from: container, forKey: .ruleToc)
        self.ruleContent = try Self.decodeRule(ContentRule.self, from: container, forKey: .ruleContent)
    }

    private static func decodeRule<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> T? {
        guard container.contains(key), !(try container.decodeNil(forKey: key)) else {
            return nil
        }
        if let rule = try? container.decode(T.self, forKey: key) {
            return rule
        }
        if let array = try? container.nestedUnkeyedContainer(forKey: key), array.isAtEnd {
            return nil
        }

        let rawRule = try container.decode(String.self, forKey: key)
        guard let data = rawRule.data(using: .utf8) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "书源规则不是有效的 UTF-8 JSON 字符串"
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "书源规则 JSON 无效：\(error.localizedDescription)"
            )
        }
    }

    private static func decodeInt64(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int64? {
        guard container.contains(key), !(try container.decodeNil(forKey: key)) else {
            return nil
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key),
           let integer = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return integer
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "字段 \(key.stringValue) 必须是整数或整数文本"
        )
    }
}

// MARK: - SearchRule
/// 搜索规则
public nonisolated struct SearchRule: Codable, Sendable {
    /// 搜索结果书籍列表选择器
    public var bookList: String?
    /// 书名规则
    public var name: String?
    /// 作者规则
    public var author: String?
    /// 简介规则
    public var intro: String?
    /// 分类规则
    public var kind: String?
    /// 最新章节规则
    public var lastChapter: String?
    /// 更新时间规则
    public var updateTime: String?
    /// 书籍详情页 URL 规则
    public var bookUrl: String?
    /// 封面 URL 规则
    public var coverUrl: String?
    /// 字数规则
    public var wordCount: String?
    /// 关键字检测规则
    public var checkKeyWord: String?

    public init(
        bookList: String? = nil,
        name: String? = nil,
        author: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        bookUrl: String? = nil,
        coverUrl: String? = nil,
        wordCount: String? = nil,
        checkKeyWord: String? = nil
    ) {
        self.bookList = bookList
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.wordCount = wordCount
        self.checkKeyWord = checkKeyWord
    }
}

// MARK: - ExploreRule
/// 发现/探索规则（继承搜索规则的字段）
public nonisolated struct ExploreRule: Codable, Sendable {
    /// 书籍列表选择器
    public var bookList: String?
    /// 书名规则
    public var name: String?
    /// 作者规则
    public var author: String?
    /// 简介规则
    public var intro: String?
    /// 分类规则
    public var kind: String?
    /// 最新章节规则
    public var lastChapter: String?
    /// 更新时间规则
    public var updateTime: String?
    /// 书籍详情页 URL 规则
    public var bookUrl: String?
    /// 封面 URL 规则
    public var coverUrl: String?
    /// 字数规则
    public var wordCount: String?

    public init(
        bookList: String? = nil,
        name: String? = nil,
        author: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        bookUrl: String? = nil,
        coverUrl: String? = nil,
        wordCount: String? = nil
    ) {
        self.bookList = bookList
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.wordCount = wordCount
    }
}

// MARK: - BookInfoRule
/// 书籍详情规则
public nonisolated struct BookInfoRule: Codable, Sendable {
    /// 详情页初始化规则（JS 或 URL，用于在解析前执行）
    public var `init`: String?
    /// 书名规则
    public var name: String?
    /// 作者规则
    public var author: String?
    /// 简介规则
    public var intro: String?
    /// 分类规则
    public var kind: String?
    /// 最新章节规则
    public var lastChapter: String?
    /// 更新时间规则
    public var updateTime: String?
    /// 封面 URL 规则
    public var coverUrl: String?
    /// 目录页 URL 规则
    public var tocUrl: String?
    /// 字数规则
    public var wordCount: String?
    /// 是否可重命名
    public var canReName: String?
    /// 下载 URL 规则
    public var downloadUrls: String?

    public init(
        init initRule: String? = nil,
        name: String? = nil,
        author: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        coverUrl: String? = nil,
        tocUrl: String? = nil,
        wordCount: String? = nil,
        canReName: String? = nil,
        downloadUrls: String? = nil
    ) {
        self.`init` = initRule
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.coverUrl = coverUrl
        self.tocUrl = tocUrl
        self.wordCount = wordCount
        self.canReName = canReName
        self.downloadUrls = downloadUrls
    }
}

// MARK: - TocRule
/// 目录规则
public nonisolated struct TocRule: Codable, Sendable {
    /// 章节列表选择器
    public var chapterList: String?
    /// 章节名称规则
    public var chapterName: String?
    /// 章节 URL 规则
    public var chapterUrl: String?
    /// 是否为卷名规则
    public var isVolume: String?
    /// 是否为 VIP 章节规则
    public var isVip: String?
    /// 是否需要付费规则
    public var isPay: String?
    /// 更新时间规则
    public var updateTime: String?
    /// 下一页目录 URL 规则
    public var nextTocUrl: String?
    /// 解析前执行的 JS
    public var preUpdateJs: String?
    /// 章节名称格式化 JS
    public var formatJs: String?

    public init(
        chapterList: String? = nil,
        chapterName: String? = nil,
        chapterUrl: String? = nil,
        isVolume: String? = nil,
        isVip: String? = nil,
        isPay: String? = nil,
        updateTime: String? = nil,
        nextTocUrl: String? = nil,
        preUpdateJs: String? = nil,
        formatJs: String? = nil
    ) {
        self.chapterList = chapterList
        self.chapterName = chapterName
        self.chapterUrl = chapterUrl
        self.isVolume = isVolume
        self.isVip = isVip
        self.isPay = isPay
        self.updateTime = updateTime
        self.nextTocUrl = nextTocUrl
        self.preUpdateJs = preUpdateJs
        self.formatJs = formatJs
    }
}

// MARK: - ContentRule
/// 正文内容规则
public nonisolated struct ContentRule: Codable, Sendable {
    /// 正文内容规则
    public var content: String?
    /// 标题规则
    public var title: String?
    /// 下一页 URL 规则
    public var nextContentUrl: String?
    /// 网页 JS（用于动态页面）
    public var webJs: String?
    /// 书源正则（过滤广告等）
    public var sourceRegex: String?
    /// 替换规则
    public var replaceRegex: String?
    /// 图片样式
    public var imageStyle: String?
    /// 图片解码方式
    public var imageDecode: String?
    /// 付费阅读操作
    public var payAction: String?

    public init(
        content: String? = nil,
        title: String? = nil,
        nextContentUrl: String? = nil,
        webJs: String? = nil,
        sourceRegex: String? = nil,
        replaceRegex: String? = nil,
        imageStyle: String? = nil,
        imageDecode: String? = nil,
        payAction: String? = nil
    ) {
        self.content = content
        self.title = title
        self.nextContentUrl = nextContentUrl
        self.webJs = webJs
        self.sourceRegex = sourceRegex
        self.replaceRegex = replaceRegex
        self.imageStyle = imageStyle
        self.imageDecode = imageDecode
        self.payAction = payAction
    }
}
