import Foundation

enum BackupJSONFile {
    static let bookSource = "bookSource.json"
    static let bookshelf = "bookshelf.json"
    static let bookGroup = "bookGroup.json"
    static let bookmark = "bookmark.json"
    static let replaceRule = "replaceRule.json"
}

struct BookSourceBackupRecord: Codable {
    let bookSourceUrl: String
    let bookSourceName: String
    let bookSourceGroup: String?
    let bookSourceType: Int
    let bookUrlPattern: String?
    let enabled: Bool
    let enabledExplore: Bool
    let bookSourceComment: String?
    let lastUpdateTime: Int64
    let loginUrl: String?
    let loginUi: String?
    let loginCheckJs: String?
    let coverDecodeJs: String?
    let header: String?
    let cookieJar: String?
    let concurrentRate: String?
    let searchUrl: String?
    let exploreUrl: String?
    let ruleSearchJSON: String?
    let ruleExploreJSON: String?
    let ruleBookInfoJSON: String?
    let ruleTocJSON: String?
    let ruleContentJSON: String?

    init(entity: BookSourceEntity) {
        self.bookSourceUrl = entity.bookSourceUrl
        self.bookSourceName = entity.bookSourceName
        self.bookSourceGroup = entity.bookSourceGroup
        self.bookSourceType = entity.bookSourceType
        self.bookUrlPattern = entity.bookUrlPattern
        self.enabled = entity.enabled
        self.enabledExplore = entity.enabledExplore
        self.bookSourceComment = entity.bookSourceComment
        self.lastUpdateTime = entity.lastUpdateTime
        self.loginUrl = entity.loginUrl
        self.loginUi = entity.loginUi
        self.loginCheckJs = entity.loginCheckJs
        self.coverDecodeJs = entity.coverDecodeJs
        self.header = entity.header
        self.cookieJar = entity.cookieJar
        self.concurrentRate = entity.concurrentRate
        self.searchUrl = entity.searchUrl
        self.exploreUrl = entity.exploreUrl
        self.ruleSearchJSON = entity.ruleSearchJSON
        self.ruleExploreJSON = entity.ruleExploreJSON
        self.ruleBookInfoJSON = entity.ruleBookInfoJSON
        self.ruleTocJSON = entity.ruleTocJSON
        self.ruleContentJSON = entity.ruleContentJSON
    }

    func makeEntity() -> BookSourceEntity {
        BookSourceEntity(
            bookSourceUrl: bookSourceUrl,
            bookSourceName: bookSourceName,
            bookSourceGroup: bookSourceGroup,
            bookSourceType: bookSourceType,
            bookUrlPattern: bookUrlPattern,
            enabled: enabled,
            enabledExplore: enabledExplore,
            bookSourceComment: bookSourceComment,
            lastUpdateTime: lastUpdateTime,
            loginUrl: loginUrl,
            loginUi: loginUi,
            loginCheckJs: loginCheckJs,
            coverDecodeJs: coverDecodeJs,
            header: header,
            cookieJar: cookieJar,
            concurrentRate: concurrentRate,
            searchUrl: searchUrl,
            exploreUrl: exploreUrl,
            ruleSearchJSON: ruleSearchJSON,
            ruleExploreJSON: ruleExploreJSON,
            ruleBookInfoJSON: ruleBookInfoJSON,
            ruleTocJSON: ruleTocJSON,
            ruleContentJSON: ruleContentJSON
        )
    }

    func apply(to entity: BookSourceEntity) {
        entity.bookSourceName = bookSourceName
        entity.bookSourceGroup = bookSourceGroup
        entity.bookSourceType = bookSourceType
        entity.bookUrlPattern = bookUrlPattern
        entity.enabled = enabled
        entity.enabledExplore = enabledExplore
        entity.bookSourceComment = bookSourceComment
        entity.lastUpdateTime = lastUpdateTime
        entity.loginUrl = loginUrl
        entity.loginUi = loginUi
        entity.loginCheckJs = loginCheckJs
        entity.coverDecodeJs = coverDecodeJs
        entity.header = header
        entity.cookieJar = cookieJar
        entity.concurrentRate = concurrentRate
        entity.searchUrl = searchUrl
        entity.exploreUrl = exploreUrl
        entity.ruleSearchJSON = ruleSearchJSON
        entity.ruleExploreJSON = ruleExploreJSON
        entity.ruleBookInfoJSON = ruleBookInfoJSON
        entity.ruleTocJSON = ruleTocJSON
        entity.ruleContentJSON = ruleContentJSON
    }
}

struct BookBackupRecord: Codable {
    let bookUrl: String
    let name: String
    let author: String
    let coverUrl: String?
    let intro: String?
    let kind: String?
    let wordCount: String?
    let customCoverUrl: String?
    let customIntro: String?
    let customTag: String?
    let lastChapter: String?
    let updateTime: String?
    let tocUrl: String?
    let currentChapterIndex: Int
    let currentChapterName: String?
    let totalChapterCount: Int
    let hasNewChapter: Bool
    let sourceUrl: String
    let addedTime: Date
    let lastReadTime: Date?
    let group: Int64

    init(entity: BookEntity) {
        self.bookUrl = entity.bookUrl
        self.name = entity.name
        self.author = entity.author
        self.coverUrl = entity.coverUrl
        self.intro = entity.intro
        self.kind = entity.kind
        self.wordCount = entity.wordCount
        self.customCoverUrl = entity.customCoverUrl
        self.customIntro = entity.customIntro
        self.customTag = entity.customTag
        self.lastChapter = entity.lastChapter
        self.updateTime = entity.updateTime
        self.tocUrl = entity.tocUrl
        self.currentChapterIndex = entity.currentChapterIndex
        self.currentChapterName = entity.currentChapterName
        self.totalChapterCount = entity.totalChapterCount
        self.hasNewChapter = entity.hasNewChapter
        self.sourceUrl = entity.sourceUrl
        self.addedTime = entity.addedTime
        self.lastReadTime = entity.lastReadTime
        self.group = entity.group
    }

    func makeEntity() -> BookEntity {
        BookEntity(
            bookUrl: bookUrl,
            name: name,
            author: author,
            coverUrl: coverUrl,
            intro: intro,
            kind: kind,
            wordCount: wordCount,
            customCoverUrl: customCoverUrl,
            customIntro: customIntro,
            customTag: customTag,
            lastChapter: lastChapter,
            updateTime: updateTime,
            tocUrl: tocUrl,
            currentChapterIndex: currentChapterIndex,
            currentChapterName: currentChapterName,
            totalChapterCount: totalChapterCount,
            hasNewChapter: hasNewChapter,
            sourceUrl: sourceUrl,
            addedTime: addedTime,
            lastReadTime: lastReadTime,
            group: group
        )
    }

    func apply(to entity: BookEntity) {
        entity.name = name
        entity.author = author
        entity.coverUrl = coverUrl
        entity.intro = intro
        entity.kind = kind
        entity.wordCount = wordCount
        entity.customCoverUrl = customCoverUrl
        entity.customIntro = customIntro
        entity.customTag = customTag
        entity.lastChapter = lastChapter
        entity.updateTime = updateTime
        entity.tocUrl = tocUrl
        entity.currentChapterIndex = currentChapterIndex
        entity.currentChapterName = currentChapterName
        entity.totalChapterCount = totalChapterCount
        entity.hasNewChapter = hasNewChapter
        entity.sourceUrl = sourceUrl
        entity.addedTime = addedTime
        entity.lastReadTime = lastReadTime
        entity.group = group
    }
}

struct BookGroupBackupRecord: Codable {
    let groupId: Int64
    let groupName: String
    let order: Int
    let show: Bool

    init(entity: BookGroup) {
        self.groupId = entity.groupId
        self.groupName = entity.groupName
        self.order = entity.order
        self.show = entity.show
    }

    func makeEntity() -> BookGroup {
        BookGroup(groupId: groupId, groupName: groupName, order: order, show: show)
    }

    func apply(to entity: BookGroup) {
        entity.groupName = groupName
        entity.order = order
        entity.show = show
    }
}

struct BookmarkBackupRecord: Codable {
    let id: String
    let bookUrl: String
    let chapterIndex: Int
    let pageIndex: Int?
    let utf16Offset: Int?
    let chapterName: String
    let bookText: String
    let content: String
    let time: Date

    init(entity: BookmarkEntity) {
        self.id = entity.id
        self.bookUrl = entity.bookUrl
        self.chapterIndex = entity.chapterIndex
        self.pageIndex = entity.pageIndex
        self.utf16Offset = entity.utf16Offset
        self.chapterName = entity.chapterName
        self.bookText = entity.bookText
        self.content = entity.content
        self.time = entity.time
    }

    func makeEntity() -> BookmarkEntity {
        BookmarkEntity(
            id: id,
            bookUrl: bookUrl,
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            utf16Offset: utf16Offset,
            chapterName: chapterName,
            bookText: bookText,
            content: content,
            time: time
        )
    }

    func apply(to entity: BookmarkEntity) {
        entity.bookUrl = bookUrl
        entity.chapterIndex = chapterIndex
        entity.pageIndex = pageIndex
        entity.utf16Offset = utf16Offset
        entity.chapterName = chapterName
        entity.bookText = bookText
        entity.content = content
        entity.time = time
    }
}

struct ReplaceRuleBackupRecord: Codable {
    let id: String
    let name: String
    let isEnabled: Bool
    let isRegex: Bool
    let pattern: String
    let replacement: String
    let scope: String
    let order: Int
    let addedTime: Date

    init(entity: ReplaceRuleEntity) {
        self.id = entity.id
        self.name = entity.name
        self.isEnabled = entity.isEnabled
        self.isRegex = entity.isRegex
        self.pattern = entity.pattern
        self.replacement = entity.replacement
        self.scope = entity.scope
        self.order = entity.order
        self.addedTime = entity.addedTime
    }

    func makeEntity() -> ReplaceRuleEntity {
        ReplaceRuleEntity(
            id: id,
            name: name,
            isEnabled: isEnabled,
            isRegex: isRegex,
            pattern: pattern,
            replacement: replacement,
            scope: scope,
            order: order,
            addedTime: addedTime
        )
    }

    func apply(to entity: ReplaceRuleEntity) {
        entity.name = name
        entity.isEnabled = isEnabled
        entity.isRegex = isRegex
        entity.pattern = pattern
        entity.replacement = replacement
        entity.scope = scope
        entity.order = order
        entity.addedTime = addedTime
    }
}

enum BackupCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
