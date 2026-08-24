import Foundation

// MARK: - LegadoResponseContextV2

/// V2 请求响应上下文。
///
/// 这一层对应 Android `WebBook` 请求阶段拿到的“标准 response 包装”。
/// H3 开始，V2 不再让 search / detail / toc / content 各自拼接响应字段，
/// 而是统一由 `RequestExecutorV2` 在 transport 完成后构造这一份上下文：
/// - 原始 `HTTPResponse`
/// - 触发本次请求的 descriptor
/// - request / response / base URL
/// - transport 类型、尝试次数、redirect 结果
/// - 已标准化的状态码、头、消息、responseType
///
/// 这样后续 H4/H5 即使继续拆 parser / rule runtime，也不用再反复关心请求层细节。
nonisolated struct LegadoResponseContextV2: Sendable {
    enum TransportKind: String, Codable, Sendable {
        case http
        case webView
        case webViewRecoveredHTML
        case webViewRecoveredURL
    }

    struct TraceSummary: Codable, Sendable {
        var requestUrl: String
        var responseUrl: String
        var baseUrl: String
        var statusCode: Int
        var transportKind: String
        var attemptCount: Int
        var wasRedirected: Bool
        var bodySize: Int
        var responseType: String?
        var charset: String
    }

    var response: HTTPResponse
    var descriptor: LegadoRequestDescriptorV2
    var requestUrl: String
    var responseUrl: String
    var baseUrl: String
    var statusCode: Int
    var headers: [String: String]
    var message: String
    var responseType: String?
    var charset: String
    var transportKind: TransportKind
    var attemptCount: Int
    var bodySize: Int
    var wasRedirected: Bool

    var text: String? {
        response.text
    }

    var traceSummary: TraceSummary {
        TraceSummary(
            requestUrl: requestUrl,
            responseUrl: responseUrl,
            baseUrl: baseUrl,
            statusCode: statusCode,
            transportKind: transportKind.rawValue,
            attemptCount: attemptCount,
            wasRedirected: wasRedirected,
            bodySize: bodySize,
            responseType: responseType,
            charset: charset
        )
    }

    init(
        response: HTTPResponse,
        descriptor: LegadoRequestDescriptorV2,
        requestUrl: String,
        responseUrl: String,
        baseUrl: String,
        transportKind: TransportKind,
        attemptCount: Int
    ) {
        self.response = response
        self.descriptor = descriptor
        self.requestUrl = requestUrl
        self.responseUrl = responseUrl
        self.baseUrl = baseUrl
        self.statusCode = response.statusCode
        self.headers = response.headers
        self.message = response.message
        self.responseType = descriptor.responseType
        self.charset = descriptor.charset
        self.transportKind = transportKind
        self.attemptCount = attemptCount
        self.bodySize = response.data.count
        self.wasRedirected = requestUrl != responseUrl
    }
}
