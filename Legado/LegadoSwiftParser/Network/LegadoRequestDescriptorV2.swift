import Foundation

// MARK: - LegadoRequestDescriptorV2

/// V2 请求描述。
///
/// H1 先复用旧 `LegadoRequestDescriptor` 的稳定字段集合，
/// 但把它从 `HTTPClient.swift` 的巨型文件中抽离出来，作为 V2 请求链路的显式模型。
nonisolated struct LegadoRequestDescriptorV2: Codable, Sendable {
    var resolvedURL: String
    var method: String
    var headerKeys: [String]
    var originalRulePreview: String?
    var bodyLength: Int
    var bodyPreview: String?
    var bodyHash: String?
    var charset: String
    var webView: Bool
    var webJs: Bool
    var sourceRegex: Bool
    var retryCount: Int
    var responseType: String?
    var cookieJarEnabled: Bool
    var timeoutSeconds: Double
    var followRedirects: Bool
    var transportPreference: String
    var sourceHeaderKeys: [String]
    var runtimeTrace: AnalyzeUrlV2.TraceState?

    init(
        resolvedURL: String,
        method: String,
        headerKeys: [String],
        originalRulePreview: String?,
        bodyLength: Int,
        bodyPreview: String?,
        bodyHash: String?,
        charset: String,
        webView: Bool,
        webJs: Bool,
        sourceRegex: Bool,
        retryCount: Int,
        responseType: String?,
        cookieJarEnabled: Bool,
        timeoutSeconds: Double,
        followRedirects: Bool,
        transportPreference: String,
        sourceHeaderKeys: [String] = [],
        runtimeTrace: AnalyzeUrlV2.TraceState? = nil
    ) {
        self.resolvedURL = resolvedURL
        self.method = method
        self.headerKeys = headerKeys
        self.originalRulePreview = originalRulePreview
        self.bodyLength = bodyLength
        self.bodyPreview = bodyPreview
        self.bodyHash = bodyHash
        self.charset = charset
        self.webView = webView
        self.webJs = webJs
        self.sourceRegex = sourceRegex
        self.retryCount = retryCount
        self.responseType = responseType
        self.cookieJarEnabled = cookieJarEnabled
        self.timeoutSeconds = timeoutSeconds
        self.followRedirects = followRedirects
        self.transportPreference = transportPreference
        self.sourceHeaderKeys = sourceHeaderKeys
        self.runtimeTrace = runtimeTrace
    }

    init(legacy: LegadoRequestDescriptor) {
        self.init(
            resolvedURL: legacy.resolvedURL,
            method: legacy.method,
            headerKeys: legacy.headerKeys,
            originalRulePreview: legacy.originalRulePreview,
            bodyLength: legacy.bodyLength,
            bodyPreview: legacy.bodyPreview,
            bodyHash: legacy.bodyHash,
            charset: legacy.charset,
            webView: legacy.webView,
            webJs: legacy.webJs,
            sourceRegex: legacy.sourceRegex,
            retryCount: legacy.retryCount,
            responseType: legacy.responseType,
            cookieJarEnabled: legacy.cookieJarEnabled,
            timeoutSeconds: legacy.timeoutSeconds,
            followRedirects: legacy.followRedirects,
            transportPreference: legacy.transportPreference,
            sourceHeaderKeys: [],
            runtimeTrace: nil
        )
    }
}
