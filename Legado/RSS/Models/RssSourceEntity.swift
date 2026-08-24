import Foundation
import SwiftData

// MARK: - RssSourceEntity
/// RSS 订阅源持久化实体。
@Model
final class RssSourceEntity {
    @Attribute(.unique) var sourceUrl: String
    var sourceName: String
    var sourceIcon: String
    var sourceGroup: String?
    var sourceComment: String?
    var enabled: Bool
    var variableComment: String?
    var jsLib: String?
    var enabledCookieJar: Bool
    var concurrentRate: String?
    var header: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var sortUrl: String?
    var singleUrl: Bool
    var articleStyle: Int
    var ruleArticles: String?
    var ruleNextPage: String?
    var ruleTitle: String?
    var rulePubDate: String?
    var ruleDescription: String?
    var ruleImage: String?
    var ruleLink: String?
    var ruleContent: String?
    var contentWhitelist: String?
    var contentBlacklist: String?
    var shouldOverrideUrlLoading: String?
    var style: String?
    var enableJs: Bool
    var loadWithBaseUrl: Bool
    var injectJs: String?
    var lastUpdateTime: Int64
    var customOrder: Int

    init(
        sourceUrl: String,
        sourceName: String,
        sourceIcon: String = "",
        sourceGroup: String? = nil,
        sourceComment: String? = nil,
        enabled: Bool = true,
        variableComment: String? = nil,
        jsLib: String? = nil,
        enabledCookieJar: Bool = true,
        concurrentRate: String? = nil,
        header: String? = nil,
        loginUrl: String? = nil,
        loginUi: String? = nil,
        loginCheckJs: String? = nil,
        coverDecodeJs: String? = nil,
        sortUrl: String? = nil,
        singleUrl: Bool = false,
        articleStyle: Int = 0,
        ruleArticles: String? = nil,
        ruleNextPage: String? = nil,
        ruleTitle: String? = nil,
        rulePubDate: String? = nil,
        ruleDescription: String? = nil,
        ruleImage: String? = nil,
        ruleLink: String? = nil,
        ruleContent: String? = nil,
        contentWhitelist: String? = nil,
        contentBlacklist: String? = nil,
        shouldOverrideUrlLoading: String? = nil,
        style: String? = nil,
        enableJs: Bool = true,
        loadWithBaseUrl: Bool = true,
        injectJs: String? = nil,
        lastUpdateTime: Int64 = 0,
        customOrder: Int = 0
    ) {
        self.sourceUrl = sourceUrl
        self.sourceName = sourceName
        self.sourceIcon = sourceIcon
        self.sourceGroup = sourceGroup
        self.sourceComment = sourceComment
        self.enabled = enabled
        self.variableComment = variableComment
        self.jsLib = jsLib
        self.enabledCookieJar = enabledCookieJar
        self.concurrentRate = concurrentRate
        self.header = header
        self.loginUrl = loginUrl
        self.loginUi = loginUi
        self.loginCheckJs = loginCheckJs
        self.coverDecodeJs = coverDecodeJs
        self.sortUrl = sortUrl
        self.singleUrl = singleUrl
        self.articleStyle = articleStyle
        self.ruleArticles = ruleArticles
        self.ruleNextPage = ruleNextPage
        self.ruleTitle = ruleTitle
        self.rulePubDate = rulePubDate
        self.ruleDescription = ruleDescription
        self.ruleImage = ruleImage
        self.ruleLink = ruleLink
        self.ruleContent = ruleContent
        self.contentWhitelist = contentWhitelist
        self.contentBlacklist = contentBlacklist
        self.shouldOverrideUrlLoading = shouldOverrideUrlLoading
        self.style = style
        self.enableJs = enableJs
        self.loadWithBaseUrl = loadWithBaseUrl
        self.injectJs = injectJs
        self.lastUpdateTime = lastUpdateTime
        self.customOrder = customOrder
    }

    convenience init(payload: RssSourcePayload) {
        self.init(
            sourceUrl: payload.sourceUrl,
            sourceName: payload.sourceName,
            sourceIcon: payload.sourceIcon,
            sourceGroup: payload.sourceGroup,
            sourceComment: payload.sourceComment,
            enabled: payload.enabled,
            variableComment: payload.variableComment,
            jsLib: payload.jsLib,
            enabledCookieJar: payload.enabledCookieJar,
            concurrentRate: payload.concurrentRate,
            header: payload.header,
            loginUrl: payload.loginUrl,
            loginUi: payload.loginUi,
            loginCheckJs: payload.loginCheckJs,
            coverDecodeJs: payload.coverDecodeJs,
            sortUrl: payload.sortUrl,
            singleUrl: payload.singleUrl,
            articleStyle: payload.articleStyle,
            ruleArticles: payload.ruleArticles,
            ruleNextPage: payload.ruleNextPage,
            ruleTitle: payload.ruleTitle,
            rulePubDate: payload.rulePubDate,
            ruleDescription: payload.ruleDescription,
            ruleImage: payload.ruleImage,
            ruleLink: payload.ruleLink,
            ruleContent: payload.ruleContent,
            contentWhitelist: payload.contentWhitelist,
            contentBlacklist: payload.contentBlacklist,
            shouldOverrideUrlLoading: payload.shouldOverrideUrlLoading,
            style: payload.style,
            enableJs: payload.enableJs,
            loadWithBaseUrl: payload.loadWithBaseUrl,
            injectJs: payload.injectJs,
            lastUpdateTime: payload.lastUpdateTime,
            customOrder: payload.customOrder
        )
    }

    func update(from payload: RssSourcePayload) {
        sourceName = payload.sourceName
        sourceIcon = payload.sourceIcon
        sourceGroup = payload.sourceGroup
        sourceComment = payload.sourceComment
        enabled = payload.enabled
        variableComment = payload.variableComment
        jsLib = payload.jsLib
        enabledCookieJar = payload.enabledCookieJar
        concurrentRate = payload.concurrentRate
        header = payload.header
        loginUrl = payload.loginUrl
        loginUi = payload.loginUi
        loginCheckJs = payload.loginCheckJs
        coverDecodeJs = payload.coverDecodeJs
        sortUrl = payload.sortUrl
        singleUrl = payload.singleUrl
        articleStyle = payload.articleStyle
        ruleArticles = payload.ruleArticles
        ruleNextPage = payload.ruleNextPage
        ruleTitle = payload.ruleTitle
        rulePubDate = payload.rulePubDate
        ruleDescription = payload.ruleDescription
        ruleImage = payload.ruleImage
        ruleLink = payload.ruleLink
        ruleContent = payload.ruleContent
        contentWhitelist = payload.contentWhitelist
        contentBlacklist = payload.contentBlacklist
        shouldOverrideUrlLoading = payload.shouldOverrideUrlLoading
        style = payload.style
        enableJs = payload.enableJs
        loadWithBaseUrl = payload.loadWithBaseUrl
        injectJs = payload.injectJs
        lastUpdateTime = payload.lastUpdateTime
        customOrder = payload.customOrder
    }
}
