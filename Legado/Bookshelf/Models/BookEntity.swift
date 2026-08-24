import SwiftData
import Foundation

// MARK: - BookEntity
/// 书架中已加入书籍的 SwiftData 持久化实体
@Model
final class BookEntity {

    // MARK: 基础信息
    @Attribute(.unique) var bookUrl: String
    var name: String
    var author: String
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var wordCount: String?
    var customCoverUrl: String?
    var customIntro: String?
    var customTag: String?

    // MARK: 章节信息
    var lastChapter: String?
    var updateTime: String?
    var tocUrl: String?
    var currentChapterIndex: Int
    var currentChapterName: String?
    /// 总章节数（用于判断是否读完）
    var totalChapterCount: Int
    /// 是否存在未读的新章节
    var hasNewChapter: Bool

    // MARK: 来源信息
    var sourceUrl: String

    // MARK: 时间记录
    var addedTime: Date
    var lastReadTime: Date?
    /// 手动排序持久化存储。Phase 9I 升级时允许旧库缺省为 nil，以便顺利迁移。
    @Attribute(originalName: "manualOrder") private var manualOrderValue: Int?
    /// 书架分组位掩码持久化存储；旧库升级时允许缺省为 nil。
    @Attribute(originalName: "group") private var groupMask: Int64?

    var manualOrder: Int {
        get { manualOrderValue ?? Self.defaultManualOrder(from: addedTime) }
        set { manualOrderValue = newValue }
    }

    /// 书架分组位掩码；0 表示未加入任何分组。
    var group: Int64 {
        get { groupMask ?? 0 }
        set { groupMask = newValue }
    }

    // MARK: Init
    init(
        bookUrl: String,
        name: String,
        author: String,
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        wordCount: String? = nil,
        customCoverUrl: String? = nil,
        customIntro: String? = nil,
        customTag: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        tocUrl: String? = nil,
        currentChapterIndex: Int = 0,
        currentChapterName: String? = nil,
        totalChapterCount: Int = 0,
        hasNewChapter: Bool = false,
        sourceUrl: String,
        addedTime: Date = .now,
        lastReadTime: Date? = nil,
        manualOrder: Int? = nil,
        group: Int64 = 0
    ) {
        self.bookUrl = bookUrl
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.wordCount = wordCount
        self.customCoverUrl = customCoverUrl
        self.customIntro = customIntro
        self.customTag = customTag
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.tocUrl = tocUrl
        self.currentChapterIndex = currentChapterIndex
        self.currentChapterName = currentChapterName
        self.totalChapterCount = totalChapterCount
        self.hasNewChapter = hasNewChapter
        self.sourceUrl = sourceUrl
        self.addedTime = addedTime
        self.lastReadTime = lastReadTime
        self.manualOrderValue = manualOrder
        self.groupMask = group
    }

    // MARK: 与 BookDetail 互转

    convenience init(detail: BookDetail, sourceUrl: String) {
        self.init(
            bookUrl: detail.bookUrl,
            name: detail.name,
            author: detail.author,
            coverUrl: detail.coverUrl,
            intro: detail.intro,
            kind: detail.kind,
            wordCount: detail.wordCount,
            lastChapter: detail.lastChapter,
            updateTime: detail.updateTime,
            tocUrl: detail.tocUrl,
            sourceUrl: sourceUrl
        )
    }

    func toBookDetail() -> BookDetail {
        BookDetail(
            bookUrl: bookUrl,
            name: name,
            author: author,
            coverUrl: effectiveCoverUrl,
            intro: effectiveIntro,
            kind: kind,
            lastChapter: lastChapter,
            updateTime: updateTime,
            tocUrl: tocUrl,
            wordCount: wordCount,
            origin: sourceUrl
        )
    }

    /// 用最新 BookDetail 更新字段（不改变加入时间和阅读进度）
    func update(from detail: BookDetail) {
        if detail.lastChapter != lastChapter {
            hasNewChapter = true
        }
        name = detail.name
        author = detail.author
        coverUrl = detail.coverUrl
        intro = detail.intro
        kind = detail.kind
        wordCount = detail.wordCount
        lastChapter = detail.lastChapter
        updateTime = detail.updateTime
        tocUrl = detail.tocUrl
    }

    var effectiveCoverUrl: String? {
        let trimmedCustomCoverUrl = customCoverUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCustomCoverUrl, !trimmedCustomCoverUrl.isEmpty {
            return trimmedCustomCoverUrl
        }
        return coverUrl
    }

    var effectiveIntro: String? {
        let trimmedCustomIntro = customIntro?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCustomIntro, !trimmedCustomIntro.isEmpty {
            return trimmedCustomIntro
        }
        return intro
    }

    var effectiveTag: String? {
        let trimmedCustomTag = customTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCustomTag, !trimmedCustomTag.isEmpty {
            return trimmedCustomTag
        }
        return nil
    }

    func addGroup(_ groupId: Int64) {
        guard groupId > 0 else { return }
        group |= groupId
    }

    func removeGroup(_ groupId: Int64) {
        guard groupId > 0 else { return }
        group &= ~groupId
    }

    func hasGroup(_ groupId: Int64) -> Bool {
        guard groupId > 0 else { return false }
        return (group & groupId) != 0
    }

    private static func defaultManualOrder(from addedTime: Date) -> Int {
        let milliseconds = Int(addedTime.timeIntervalSince1970 * 1000)
        return max(milliseconds, 0)
    }
}
