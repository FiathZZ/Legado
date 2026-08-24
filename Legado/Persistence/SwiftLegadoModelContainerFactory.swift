import Foundation
import SwiftData

// MARK: - SwiftData Schemas
enum LegadoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            BookEntity.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self
        ]
    }

    @Model
    final class BookSourceEntity {
        @Attribute(.unique) var bookSourceUrl: String
        var bookSourceName: String
        var bookSourceGroup: String?
        var bookSourceType: Int
        var bookUrlPattern: String?
        var enabled: Bool
        var enabledExplore: Bool
        var bookSourceComment: String?
        var lastUpdateTime: Int64
        var loginUrl: String?
        var loginUi: String?
        var loginCheckJs: String?
        var coverDecodeJs: String?
        var header: String?
        var cookieJar: String?
        var concurrentRate: String?
        var searchUrl: String?
        var exploreUrl: String?
        var ruleSearchJSON: String?
        var ruleExploreJSON: String?
        var ruleBookInfoJSON: String?
        var ruleTocJSON: String?
        var ruleContentJSON: String?

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
            self.searchUrl = searchUrl
            self.exploreUrl = exploreUrl
            self.ruleSearchJSON = ruleSearchJSON
            self.ruleExploreJSON = ruleExploreJSON
            self.ruleBookInfoJSON = ruleBookInfoJSON
            self.ruleTocJSON = ruleTocJSON
            self.ruleContentJSON = ruleContentJSON
        }
    }

    @Model
    final class BookEntity {
        @Attribute(.unique) var bookUrl: String
        var name: String
        var author: String
        var coverUrl: String?
        var intro: String?
        var kind: String?
        var wordCount: String?
        var lastChapter: String?
        var updateTime: String?
        var tocUrl: String?
        var currentChapterIndex: Int
        var currentChapterName: String?
        var totalChapterCount: Int
        var hasNewChapter: Bool
        var sourceUrl: String
        var addedTime: Date
        var lastReadTime: Date?

        init(
            bookUrl: String,
            name: String,
            author: String,
            coverUrl: String? = nil,
            intro: String? = nil,
            kind: String? = nil,
            wordCount: String? = nil,
            lastChapter: String? = nil,
            updateTime: String? = nil,
            tocUrl: String? = nil,
            currentChapterIndex: Int = 0,
            currentChapterName: String? = nil,
            totalChapterCount: Int = 0,
            hasNewChapter: Bool = false,
            sourceUrl: String,
            addedTime: Date = .now,
            lastReadTime: Date? = nil
        ) {
            self.bookUrl = bookUrl
            self.name = name
            self.author = author
            self.coverUrl = coverUrl
            self.intro = intro
            self.kind = kind
            self.wordCount = wordCount
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
        }
    }

    @Model
    final class TocCacheEntity {
        @Attribute(.unique) var cacheKey: String
        var bookUrl: String
        var chaptersJson: String
        var cachedAt: Date

        init(cacheKey: String, bookUrl: String, chaptersJson: String, cachedAt: Date = .now) {
            self.cacheKey = cacheKey
            self.bookUrl = bookUrl
            self.chaptersJson = chaptersJson
            self.cachedAt = cachedAt
        }
    }

    @Model
    final class ReplaceRuleEntity {
        @Attribute(.unique) var id: String
        var name: String
        var isEnabled: Bool
        var isRegex: Bool
        var pattern: String
        var replacement: String
        var scope: String
        var order: Int
        var addedTime: Date

        init(
            id: String,
            name: String,
            isEnabled: Bool,
            isRegex: Bool,
            pattern: String,
            replacement: String,
            scope: String,
            order: Int,
            addedTime: Date = .now
        ) {
            self.id = id
            self.name = name
            self.isEnabled = isEnabled
            self.isRegex = isRegex
            self.pattern = pattern
            self.replacement = replacement
            self.scope = scope
            self.order = order
            self.addedTime = addedTime
        }
    }
}

enum LegadoSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            BookEntity.self,
            BookGroup.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self
        ]
    }

    @Model
    final class BookSourceEntity {
        @Attribute(.unique) var bookSourceUrl: String
        var bookSourceName: String
        var bookSourceGroup: String?
        var bookSourceType: Int
        var bookUrlPattern: String?
        var enabled: Bool
        var enabledExplore: Bool
        var bookSourceComment: String?
        var lastUpdateTime: Int64
        var loginUrl: String?
        var loginUi: String?
        var loginCheckJs: String?
        var coverDecodeJs: String?
        var header: String?
        var cookieJar: String?
        var concurrentRate: String?
        var searchUrl: String?
        var exploreUrl: String?
        var ruleSearchJSON: String?
        var ruleExploreJSON: String?
        var ruleBookInfoJSON: String?
        var ruleTocJSON: String?
        var ruleContentJSON: String?

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
            self.searchUrl = searchUrl
            self.exploreUrl = exploreUrl
            self.ruleSearchJSON = ruleSearchJSON
            self.ruleExploreJSON = ruleExploreJSON
            self.ruleBookInfoJSON = ruleBookInfoJSON
            self.ruleTocJSON = ruleTocJSON
            self.ruleContentJSON = ruleContentJSON
        }
    }

    @Model
    final class BookEntity {
        @Attribute(.unique) var bookUrl: String
        var name: String
        var author: String
        var coverUrl: String?
        var intro: String?
        var kind: String?
        var wordCount: String?
        var lastChapter: String?
        var updateTime: String?
        var tocUrl: String?
        var currentChapterIndex: Int
        var currentChapterName: String?
        var totalChapterCount: Int
        var hasNewChapter: Bool
        var sourceUrl: String
        var addedTime: Date
        var lastReadTime: Date?
        @Attribute(originalName: "group") private var groupMask: Int64?

        init(
            bookUrl: String,
            name: String,
            author: String,
            coverUrl: String? = nil,
            intro: String? = nil,
            kind: String? = nil,
            wordCount: String? = nil,
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
            group: Int64 = 0
        ) {
            self.bookUrl = bookUrl
            self.name = name
            self.author = author
            self.coverUrl = coverUrl
            self.intro = intro
            self.kind = kind
            self.wordCount = wordCount
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
            self.groupMask = group
        }
    }

    @Model
    final class BookGroup {
        @Attribute(.unique) var groupId: Int64
        var groupName: String
        var order: Int
        var show: Bool

        init(groupId: Int64, groupName: String, order: Int = 0, show: Bool = true) {
            self.groupId = groupId
            self.groupName = groupName
            self.order = order
            self.show = show
        }
    }
}

enum LegadoSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            BookEntity.self,
            BookGroup.self,
            BookmarkEntity.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self
        ]
    }

    @Model
    final class BookSourceEntity {
        @Attribute(.unique) var bookSourceUrl: String
        var bookSourceName: String
        var bookSourceGroup: String?
        var bookSourceType: Int
        var bookUrlPattern: String?
        var enabled: Bool
        var enabledExplore: Bool
        var bookSourceComment: String?
        var lastUpdateTime: Int64
        var loginUrl: String?
        var loginUi: String?
        var loginCheckJs: String?
        var coverDecodeJs: String?
        var header: String?
        var cookieJar: String?
        var concurrentRate: String?
        var searchUrl: String?
        var exploreUrl: String?
        var ruleSearchJSON: String?
        var ruleExploreJSON: String?
        var ruleBookInfoJSON: String?
        var ruleTocJSON: String?
        var ruleContentJSON: String?

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
            self.searchUrl = searchUrl
            self.exploreUrl = exploreUrl
            self.ruleSearchJSON = ruleSearchJSON
            self.ruleExploreJSON = ruleExploreJSON
            self.ruleBookInfoJSON = ruleBookInfoJSON
            self.ruleTocJSON = ruleTocJSON
            self.ruleContentJSON = ruleContentJSON
        }
    }

    @Model
    final class BookEntity {
        @Attribute(.unique) var bookUrl: String
        var name: String
        var author: String
        var coverUrl: String?
        var intro: String?
        var kind: String?
        var wordCount: String?
        var lastChapter: String?
        var updateTime: String?
        var tocUrl: String?
        var currentChapterIndex: Int
        var currentChapterName: String?
        var totalChapterCount: Int
        var hasNewChapter: Bool
        var sourceUrl: String
        var addedTime: Date
        var lastReadTime: Date?
        @Attribute(originalName: "group") private var groupMask: Int64?

        init(
            bookUrl: String,
            name: String,
            author: String,
            coverUrl: String? = nil,
            intro: String? = nil,
            kind: String? = nil,
            wordCount: String? = nil,
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
            group: Int64 = 0
        ) {
            self.bookUrl = bookUrl
            self.name = name
            self.author = author
            self.coverUrl = coverUrl
            self.intro = intro
            self.kind = kind
            self.wordCount = wordCount
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
            self.groupMask = group
        }
    }

    @Model
    final class BookGroup {
        @Attribute(.unique) var groupId: Int64
        var groupName: String
        var order: Int
        var show: Bool

        init(groupId: Int64, groupName: String, order: Int = 0, show: Bool = true) {
            self.groupId = groupId
            self.groupName = groupName
            self.order = order
            self.show = show
        }
    }
}

enum LegadoSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            BookEntity.self,
            BookGroup.self,
            BookmarkEntity.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self
        ]
    }

    @Model
    final class BookSourceEntity {
        @Attribute(.unique) var bookSourceUrl: String
        var bookSourceName: String
        var bookSourceGroup: String?
        var bookSourceType: Int
        var bookUrlPattern: String?
        var enabled: Bool
        var enabledExplore: Bool
        var bookSourceComment: String?
        var lastUpdateTime: Int64
        var loginUrl: String?
        var loginUi: String?
        var loginCheckJs: String?
        var coverDecodeJs: String?
        var header: String?
        var cookieJar: String?
        var concurrentRate: String?
        var searchUrl: String?
        var exploreUrl: String?
        var ruleSearchJSON: String?
        var ruleExploreJSON: String?
        var ruleBookInfoJSON: String?
        var ruleTocJSON: String?
        var ruleContentJSON: String?

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
            self.searchUrl = searchUrl
            self.exploreUrl = exploreUrl
            self.ruleSearchJSON = ruleSearchJSON
            self.ruleExploreJSON = ruleExploreJSON
            self.ruleBookInfoJSON = ruleBookInfoJSON
            self.ruleTocJSON = ruleTocJSON
            self.ruleContentJSON = ruleContentJSON
        }
    }

    @Model
    final class BookEntity {
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
        var lastChapter: String?
        var updateTime: String?
        var tocUrl: String?
        var currentChapterIndex: Int
        var currentChapterName: String?
        var totalChapterCount: Int
        var hasNewChapter: Bool
        var sourceUrl: String
        var addedTime: Date
        var lastReadTime: Date?
        @Attribute(originalName: "group") private var groupMask: Int64?

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
            self.groupMask = group
        }
    }

    @Model
    final class BookGroup {
        @Attribute(.unique) var groupId: Int64
        var groupName: String
        var order: Int
        var show: Bool

        init(groupId: Int64, groupName: String, order: Int = 0, show: Bool = true) {
            self.groupId = groupId
            self.groupName = groupName
            self.order = order
            self.show = show
        }
    }
}

enum LegadoSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            RuleSubEntity.self,
            BookEntity.self,
            BookGroup.self,
            BookmarkEntity.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self
        ]
    }
}

enum LegadoSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            RuleSubEntity.self,
            BookEntity.self,
            BookGroup.self,
            BookmarkEntity.self,
            ReadRecordEntity.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self
        ]
    }
}

enum LegadoSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookSourceEntity.self,
            RuleSubEntity.self,
            BookEntity.self,
            BookGroup.self,
            BookmarkEntity.self,
            ReadRecordEntity.self,
            TocCacheEntity.self,
            ReplaceRuleEntity.self,
            RssSourceEntity.self,
            RssArticleEntity.self
        ]
    }
}

enum LegadoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            LegadoSchemaV1.self,
            LegadoSchemaV2.self,
            LegadoSchemaV3.self,
            LegadoSchemaV4.self,
            LegadoSchemaV5.self,
            LegadoSchemaV6.self,
            LegadoSchemaV7.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LegadoSchemaV1.self, toVersion: LegadoSchemaV2.self),
            .lightweight(fromVersion: LegadoSchemaV2.self, toVersion: LegadoSchemaV3.self),
            .lightweight(fromVersion: LegadoSchemaV3.self, toVersion: LegadoSchemaV4.self),
            .lightweight(fromVersion: LegadoSchemaV4.self, toVersion: LegadoSchemaV5.self),
            .lightweight(fromVersion: LegadoSchemaV5.self, toVersion: LegadoSchemaV6.self),
            .lightweight(fromVersion: LegadoSchemaV6.self, toVersion: LegadoSchemaV7.self)
        ]
    }
}

// MARK: - ModelContainer Factory
enum LegadoModelContainerFactory {
    static let schema = Schema(versionedSchema: LegadoSchemaV7.self)

    static func makeModelContainer(
        isStoredInMemoryOnly: Bool = false,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(
                nil,
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                nil,
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(
            for: schema,
            migrationPlan: LegadoMigrationPlan.self,
            configurations: configuration
        )
    }
}
