import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

private nonisolated enum LenientJSONParser {
    static func parse(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Try strict JSON first
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        // 2. Normalize single-quoted JSON (common in legado book sources)
        //    e.g. {'method':'POST','body':'keyword={{key}}'} -> {"method":"POST","body":"keyword={{key}}"}
        let normalized = normalizeSingleQuotedJSON(trimmed)
        if normalized != trimmed,
           let data = normalized.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        // 3. Use JavaScriptCore eval as last resort
        #if canImport(JavaScriptCore)
        let context = JSContext()
        let script = "JSON.stringify((\(trimmed)))"
        if let jsonText = context?.evaluateScript(script)?.toString(),
           jsonText != "undefined",
           !jsonText.isEmpty,
           let data = jsonText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        #endif
       
        return nil
    }

    /// Convert single-quoted JSON-like strings to valid double-quoted JSON.
    /// Handles: {'key':'value'}, {"key":'value'}, {'key':"value"}
    private static func normalizeSingleQuotedJSON(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        var inDoubleQuote = false
        var inSingleQuote = false

        while i < input.endIndex {
            let c = input[i]
            let next = input.index(after: i)

            if inDoubleQuote {
                if c == "\\" && next < input.endIndex {
                    result.append(c)
                    result.append(input[next])
                    i = input.index(after: next)
                    continue
                }
                if c == "\"" { inDoubleQuote = false }
                result.append(c)
            } else if inSingleQuote {
                if c == "\\" && next < input.endIndex {
                    result.append(c)
                    result.append(input[next])
                    i = input.index(after: next)
                    continue
                }
                if c == "'" {
                    inSingleQuote = false
                    result.append("\"")
                } else if c == "\"" {
                    // escape double quotes inside single-quoted string
                    result.append("\\\"")
                } else {
                    result.append(c)
                }
            } else {
                if c == "\"" {
                    inDoubleQuote = true
                    result.append(c)
                } else if c == "'" {
                    inSingleQuote = true
                    result.append("\"")
                } else {
                    result.append(c)
                }
            }
            i = next
        }
        return result
    }
}

// MARK: - HTTPMethod
public nonisolated enum HTTPMethod: String {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

// MARK: - HTTPRequest
/// HTTP 请求配置
public nonisolated struct HTTPRequest: Sendable {
    public enum TransportPreference {
        case automatic
        case preferThirdParty
    }

    public var url: String
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var charset: String
    public var followRedirects: Bool
    public var transportPreference: TransportPreference
    public var enableCookieJar: Bool

    public nonisolated init(
        url: String,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60,
        charset: String = "UTF-8",
        followRedirects: Bool = true,
        transportPreference: TransportPreference = .automatic,
        enableCookieJar: Bool = true
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.charset = charset
        self.followRedirects = followRedirects
        self.transportPreference = transportPreference
        self.enableCookieJar = enableCookieJar
    }
}

// MARK: - LegadoRequestDescriptor
/// 书源请求运行时的轻量描述，用于和 Android AnalyzeUrl / WebBook 请求链路做差异对齐。
public nonisolated struct LegadoRequestDescriptor: Codable, Sendable {
    public var resolvedURL: String
    public var method: String
    public var headerKeys: [String]
    public var originalRulePreview: String?
    public var bodyLength: Int
    public var bodyPreview: String?
    public var bodyHash: String?
    public var charset: String
    public var webView: Bool
    public var webJs: Bool
    public var sourceRegex: Bool
    public var retryCount: Int
    public var responseType: String?
    public var cookieJarEnabled: Bool
    public var timeoutSeconds: Double
    public var followRedirects: Bool
    public var transportPreference: String

    public init(
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
        transportPreference: String
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
    }
}

/// 当前任务上下文内的请求描述收集器，只在对比/调试链路开启时记录。
public nonisolated final class LegadoRequestTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [LegadoRequestDescriptor] = []

    public init() {}

    // 旧 trace collector 已不再依赖 TaskLocal，析构阶段也不应再被拉进并发运行时作用域清理。
    // 显式标成 nonisolated，避免 compare / test 高频创建时再次命中 StopLookupScope bad-free。
    nonisolated deinit {}

    public func append(_ descriptor: LegadoRequestDescriptor) {
        lock.lock()
        descriptors.append(descriptor)
        lock.unlock()
    }

    public func drain() -> [LegadoRequestDescriptor] {
        lock.lock()
        let current = descriptors
        descriptors.removeAll(keepingCapacity: true)
        lock.unlock()
        return current
    }
}

/// 旧链路请求 trace 辅助。
///
/// 这里不再使用 `@TaskLocal`。
/// 之前 compare / test 会把 collector 绑到异步作用域里，但在当前 Swift 并发运行时下，
/// `TaskLocal::StopLookupScope` 会在测试重启 / async 边界清理时触发 bad-free。
/// 现在统一改成由调用方显式持有并传递 collector，避免隐式作用域析构错配。
public nonisolated enum LegadoRequestTrace {
    public static func record(
        _ descriptor: LegadoRequestDescriptor,
        collector: LegadoRequestTraceCollector?
    ) {
        collector?.append(descriptor)
    }
}

// MARK: - HTTPResponse
/// HTTP 响应
public nonisolated struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    public var url: URL?
    public var requestURL: URL?
    public var message: String
    var headerValues: [String: [String]]
    var textOverride: String?

    /// 将响应 Data 解码为文本
    /// 自动处理 UTF-8 BOM、Content-Type 以及 HTML meta charset，并在乱码风险较高时回退到中文站点常见编码。
    public nonisolated var text: String? {
        if let textOverride {
            return textOverride
        }
        let contentType = headerValue(for: "Content-Type") ?? ""
        return HTTPClient.decodeResponse(data: data, contentTypeHeader: contentType)
    }

    public nonisolated init(
        data: Data,
        statusCode: Int,
        headers: [String: String],
        url: URL? = nil,
        requestURL: URL? = nil,
        message: String = "",
        headerValues: [String: [String]] = [:],
        textOverride: String? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
        self.requestURL = requestURL
        self.message = message
        self.headerValues = headerValues
        self.textOverride = textOverride
    }

    nonisolated func headerValue(for name: String) -> String? {
        let normalizedName = name.lowercased()
        if let values = headerValues[normalizedName], !values.isEmpty {
            return values.joined(separator: ", ")
        }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

// MARK: - HTTPClient
/// HTTP 客户端（基于 URLSession）
///
/// 支持：
/// - GET/POST 请求
/// - 自定义请求头
/// - Cookie 自动管理
/// - User-Agent 配置
/// - 超时配置
public nonisolated class HTTPClient {

    // MARK: - 属性

    public static let shared = HTTPClient()

    /// 默认 User-Agent
    public var userAgent: String = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// 默认请求头
    public var defaultHeaders: [String: String] = [:]

    /// Cookie 管理器
    public var cookieManager: CookieManager = .shared

    #if canImport(Alamofire)
    private let alamofireTransport = AlamofireTransport()
    #endif

    nonisolated(unsafe) private var didShutdown: Bool = false
    nonisolated(unsafe) private let shutdownLock = NSLock()

    // MARK: - 初始化

    public init(timeout: TimeInterval = 60) {
        _ = timeout
    }

    public nonisolated func shutdown() {
        shutdownLock.lock()
        if didShutdown {
            shutdownLock.unlock()
            return
        }
        didShutdown = true
        shutdownLock.unlock()
        #if canImport(Alamofire)
        alamofireTransport.shutdown()
        #endif
    }

    nonisolated deinit {
        shutdown()
    }

    // MARK: - AnalyzeUrl 复用辅助

    /// 根据 AnalyzeUrl 生成最终请求头，行为与 WebBook 主链路保持一致。
    public static func requestHeaders(for analyzeUrl: AnalyzeUrl) -> [String: String] {
        var requestHeaders = analyzeUrl.headers
        if analyzeUrl.method == .post, let bodyStr = analyzeUrl.body, requestHeaders["Content-Type"] == nil {
            let trimmed = bodyStr.trimmingCharacters(in: .whitespacesAndNewlines)
            let charset = AnalyzeUrl.normalizeCharsetName(analyzeUrl.charset)
            let normalizedCharset = charset.isEmpty ? "UTF-8" : charset
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                requestHeaders["Content-Type"] = "application/json; charset=\(normalizedCharset)"
            } else {
                requestHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=\(normalizedCharset)"
            }
        }
        return requestHeaders
    }

    /// 根据 AnalyzeUrlV2 生成最终请求头，供 V2 runtime 与旧 HTTPClient 执行层对接。
    static func requestHeaders(for analyzeUrlRuntime: AnalyzeUrlV2) -> [String: String] {
        analyzeUrlRuntime.requestHeaders
    }

    /// 根据 AnalyzeUrl 的 charset 编码请求体，复用主链路的非 UTF-8 处理逻辑。
    public static func requestBodyData(for analyzeUrl: AnalyzeUrl) -> Data? {
        guard let body = analyzeUrl.body else {
            return nil
        }

        let charset = AnalyzeUrl.normalizeCharsetName(analyzeUrl.charset)
        if charset.isEmpty || charset.caseInsensitiveCompare("UTF-8") == .orderedSame {
            return body.data(using: .utf8)
        }

        switch charset.lowercased() {
        case "gbk", "gb2312", "gb18030", "gb_2312-80", "chinese", "csgb2312":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return body.data(using: String.Encoding(rawValue: value))
        case "big5":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return body.data(using: String.Encoding(rawValue: value))
        default:
            return body.data(using: .utf8)
        }
    }

    /// 根据 AnalyzeUrlV2 的 charset 与 body 编码请求体。
    static func requestBodyData(for analyzeUrlRuntime: AnalyzeUrlV2) -> Data? {
        analyzeUrlRuntime.requestBodyData
    }

    /// 从 AnalyzeUrl 构造 HTTPRequest，供登录、JS Bridge 与 WebBook 主链路复用。
    public static func makeRequest(
        from analyzeUrl: AnalyzeUrl,
        timeout: TimeInterval = 60,
        transportPreference: HTTPRequest.TransportPreference = .automatic,
        enableCookieJar: Bool = true,
        followRedirects: Bool = true
    ) -> HTTPRequest {
        HTTPRequest(
            url: analyzeUrl.urlString,
            method: analyzeUrl.method,
            headers: requestHeaders(for: analyzeUrl),
            body: requestBodyData(for: analyzeUrl),
            timeout: timeout,
            charset: analyzeUrl.charset,
            followRedirects: followRedirects,
            transportPreference: transportPreference,
            enableCookieJar: enableCookieJar
        )
    }

    /// 从 AnalyzeUrl 与最终 HTTPRequest 构造可序列化请求描述，方便批量对比定位请求层差异。
    public static func makeRequestDescriptor(
        from analyzeUrl: AnalyzeUrl,
        request: HTTPRequest,
        webJs: String? = nil,
        sourceRegex: String? = nil
    ) -> LegadoRequestDescriptor {
        LegadoRequestDescriptor(
            resolvedURL: request.url,
            method: request.method.rawValue,
            headerKeys: request.headers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            originalRulePreview: analyzeUrl.originalRule.map { ParserLog.preview($0, limit: 220) },
            bodyLength: request.body?.count ?? 0,
            bodyPreview: bodyPreview(request.body, charset: request.charset),
            bodyHash: bodyHash(request.body),
            charset: request.charset,
            webView: analyzeUrl.webView,
            webJs: webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            sourceRegex: sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            retryCount: analyzeUrl.retryCount,
            responseType: analyzeUrl.responseType,
            cookieJarEnabled: request.enableCookieJar,
            timeoutSeconds: request.timeout,
            followRedirects: request.followRedirects,
            transportPreference: transportPreferenceName(request.transportPreference)
        )
    }

    private static func transportPreferenceName(_ preference: HTTPRequest.TransportPreference) -> String {
        switch preference {
        case .automatic:
            return "automatic"
        case .preferThirdParty:
            return "preferThirdParty"
        }
    }

    private static func bodyPreview(_ body: Data?, charset: String, limit: Int = 160) -> String? {
        guard let body, !body.isEmpty else {
            return nil
        }

        let decoded = decodeTextData(body, preferredCharset: charset) ?? body.base64EncodedString()
        let compact = decoded
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard compact.count > limit else {
            return compact
        }
        return String(compact.prefix(limit - 1)) + "…"
    }

    private static func bodyHash(_ body: Data?) -> String? {
        guard let body, !body.isEmpty else {
            return nil
        }

        // FNV-1a 64-bit is enough for trace correlation and keeps this helper dependency-free.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in body {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// 解析书源默认请求头，行为与 `WebBook` 主请求链路保持一致。
    public static func resolvedSourceHeaders(baseUrl: String, source: BookSource?) -> [String: String] {
        guard let source,
              let rawHeaderString = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHeaderString.isEmpty else {
            return [:]
        }

        let resolvedHeaderString: String?
        if rawHeaderString.hasPrefix("@js:") {
            let parser = JavaScriptParser(baseUrl: baseUrl, source: source)
            resolvedHeaderString = try? parser.evaluate(script: RuleAnalyzer.cleanRule(rawHeaderString))
            ParserLog.debug(
                "HTTPClient",
                "header js source=\(source.bookSourceName) raw=\(ParserLog.preview(rawHeaderString)) resolved=\(ParserLog.preview(resolvedHeaderString))"
            )
        } else {
            resolvedHeaderString = rawHeaderString
        }

        guard let resolvedHeaderString,
              !resolvedHeaderString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let headers = AnalyzeUrl.parseHeaderJSONPublic(resolvedHeaderString) else {
            return [:]
        }
        return headers
    }

    // MARK: - 响应解码

    /// 根据响应头与 HTML meta charset 检测文本编码。
    static func detectCharset(from data: Data, contentTypeHeader: String?) -> String.Encoding {
        let normalizedData = stripBOM(data)

        if let headerCharset = extractCharsetName(from: contentTypeHeader),
           let encoding = encoding(for: headerCharset) {
            return encoding
        }

        let prefixData = normalizedData.prefix(1024)
        let prefixText = String(data: prefixData, encoding: .ascii)
            ?? String(data: prefixData, encoding: .isoLatin1)
            ?? ""

        if let metaCharset = extractMetaCharset(from: prefixText),
           let encoding = encoding(for: metaCharset) {
            return encoding
        }

        return .utf8
    }

    static func decodeResponse(data: Data, contentTypeHeader: String?) -> String? {
        let normalizedData = stripBOM(data)
        let detectedEncoding = detectCharset(from: normalizedData, contentTypeHeader: contentTypeHeader)
        let candidates = deduplicatedEncodings([detectedEncoding, gb18030Encoding(), .isoLatin1])

        var bestCandidate: (encoding: String.Encoding, value: String, ratio: Double)?

        for (index, encoding) in candidates.enumerated() {
            guard let decoded = String(data: normalizedData, encoding: encoding) else {
                continue
            }

            let replacementRatio = replacementCharacterRatio(in: decoded)
            let isLastCandidate = index == candidates.count - 1
            if replacementRatio <= 0.05 || isLastCandidate {
                ParserLog.debug("HTTPClient", "charset detected: \(encodingName(for: encoding))")
                return decoded
            }

            if let currentBest = bestCandidate {
                if replacementRatio < currentBest.ratio {
                    bestCandidate = (encoding, decoded, replacementRatio)
                }
            } else {
                bestCandidate = (encoding, decoded, replacementRatio)
            }
        }

        if let bestCandidate {
            ParserLog.debug("HTTPClient", "charset detected: \(encodingName(for: bestCandidate.encoding))")
            return bestCandidate.value
        }

        return nil
    }

    /// 解码本地文本文件：
    /// 先尝试显式 charset，再优先按 UTF-8 读取，最后回退到现有响应解码策略。
    static func decodeTextData(
        _ data: Data,
        preferredCharset: String? = nil,
        contentTypeHeader: String? = nil
    ) -> String? {
        let normalizedData = stripBOM(data)

        if let preferredCharset,
           !preferredCharset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let encoding = encoding(for: preferredCharset),
           let text = String(data: normalizedData, encoding: encoding) {
            return text
        }

        if let utf8Text = String(data: normalizedData, encoding: .utf8),
           replacementCharacterRatio(in: utf8Text) <= 0.05 {
            return utf8Text
        }

        return decodeResponse(data: normalizedData, contentTypeHeader: contentTypeHeader)
            ?? String(data: normalizedData, encoding: .utf8)
            ?? String(data: normalizedData, encoding: .isoLatin1)
    }

    private static func stripBOM(_ data: Data) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.prefix(3).elementsEqual(bom) {
            return data.dropFirst(3)
        }
        return data
    }

    private static func extractCharsetName(from contentTypeHeader: String?) -> String? {
        guard let contentTypeHeader,
              let range = contentTypeHeader.range(of: "charset=", options: .caseInsensitive) else {
            return nil
        }

        let remainder = contentTypeHeader[range.upperBound...]
        let charset = remainder
            .split(whereSeparator: { ";,\"'".contains($0) || $0.isWhitespace })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let charset, !charset.isEmpty else {
            return nil
        }
        return charset
    }

    private static func extractMetaCharset(from htmlPrefix: String) -> String? {
        let patterns = [
            #"<meta[^>]*charset\s*=\s*[\"']?\s*([^\"'\s/>;]+)"#,
            #"<meta[^>]*http-equiv\s*=\s*[\"']content-type[\"'][^>]*content\s*=\s*[\"'][^\"']*charset\s*=\s*([^\"'\s/>;]+)"#,
            #"<meta[^>]*content\s*=\s*[\"'][^\"']*charset\s*=\s*([^\"'\s/>;]+)[\"'][^>]*http-equiv\s*=\s*[\"']content-type[\"']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(htmlPrefix.startIndex..., in: htmlPrefix)
            guard let match = regex.firstMatch(in: htmlPrefix, options: [], range: range),
                  let captureRange = Range(match.range(at: 1), in: htmlPrefix) else {
                continue
            }

            let charset = htmlPrefix[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !charset.isEmpty {
                return charset
            }
        }

        return nil
    }

    private static func encoding(for charset: String) -> String.Encoding? {
        switch charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb18030", "gb_2312-80", "chinese", "csgb2312":
            return gb18030Encoding()
        case "big5":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: value)
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        default:
            return .utf8
        }
    }

    private static func gb18030Encoding() -> String.Encoding {
        let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: value)
    }

    private static func deduplicatedEncodings(_ encodings: [String.Encoding]) -> [String.Encoding] {
        var seen: Set<UInt> = []
        var result: [String.Encoding] = []

        for encoding in encodings where seen.insert(encoding.rawValue).inserted {
            result.append(encoding)
        }

        return result
    }

    private static func replacementCharacterRatio(in string: String) -> Double {
        guard !string.isEmpty else {
            return 0
        }

        let replacementCount = string.reduce(into: 0) { count, character in
            if character == "\u{FFFD}" {
                count += 1
            }
        }
        return Double(replacementCount) / Double(string.count)
    }

    private static func encodingName(for encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8:
            return "utf-8"
        case .isoLatin1:
            return "iso-8859-1"
        default:
            if encoding == gb18030Encoding() {
                return "gb18030"
            }

            let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
            if cfEncoding != kCFStringEncodingInvalidId,
               let charsetName = CFStringConvertEncodingToIANACharSetName(cfEncoding) as String? {
                return charsetName.lowercased()
            }
            return "raw-\(encoding.rawValue)"
        }
    }

    // MARK: - 请求方法

    /// 发起 GET 请求
    /// - Parameters:
    ///   - url: 请求 URL
    ///   - headers: 附加请求头
    ///   - timeout: 超时时间（秒）
    /// - Returns: HTTP 响应
    public func get(
        url: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(url: url, method: .get, headers: headers, timeout: timeout)
        return try await send(request: request)
    }

    /// 发起 HEAD 请求。
    public func head(
        url: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 60,
        followRedirects: Bool = false
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(url: url, method: .head, headers: headers, timeout: timeout, followRedirects: followRedirects)
        return try await send(request: request)
    }

    /// 发起 POST 请求（表单）
    public func post(
        url: String,
        parameters: [String: String],
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> HTTPResponse {
        let bodyString = parameters.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        let body = bodyString.data(using: .utf8)
        var mergedHeaders = headers
        mergedHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        let request = HTTPRequest(url: url, method: .post, headers: mergedHeaders, body: body, timeout: timeout)
        return try await send(request: request)
    }

    /// 发起 POST 请求（JSON 体）
    public func postJSON(
        url: String,
        json: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: json)
        var mergedHeaders = headers
        mergedHeaders["Content-Type"] = "application/json"
        let request = HTTPRequest(url: url, method: .post, headers: mergedHeaders, body: body, timeout: timeout)
        return try await send(request: request)
    }

    /// 发起 POST 请求（原始 Data 体）
    public func post(
        url: String,
        body: Data,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(url: url, method: .post, headers: headers, body: body, timeout: timeout)
        return try await send(request: request)
    }

    /// 通用请求方法
    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        let prepared = try prepareURLRequest(for: request)
        let transport = try await performRequest(prepared.urlRequest, originalRequest: request)
        return finalizeResponse(
            data: transport.0,
            httpResponse: transport.1,
            originalURL: prepared.originalURL
        )
    }

    public func sendSync(request: HTTPRequest) throws -> HTTPResponse {
        let prepared = try prepareURLRequest(for: request)
        let transport = try performSyncRequest(prepared.urlRequest, originalRequest: request)
        return finalizeResponse(
            data: transport.0,
            httpResponse: transport.1,
            originalURL: prepared.originalURL
        )
    }

    private func performRequest(
        _ urlRequest: URLRequest,
        originalRequest: HTTPRequest
    ) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Alamofire)
        return try await alamofireTransport.send(
            request: urlRequest,
            followRedirects: originalRequest.followRedirects,
            timeout: originalRequest.timeout,
            enableCookieJar: originalRequest.enableCookieJar
        )
        #else
        throw ParserError.networkError("当前构建未集成 Alamofire")
        #endif
    }

    private func performSyncRequest(
        _ urlRequest: URLRequest,
        originalRequest: HTTPRequest
    ) throws -> (Data, HTTPURLResponse) {
        #if canImport(Alamofire)
        return try alamofireTransport.sendSync(
            request: urlRequest,
            followRedirects: originalRequest.followRedirects,
            timeout: originalRequest.timeout,
            enableCookieJar: originalRequest.enableCookieJar
        )
        #else
        throw ParserError.networkError("当前构建未集成 Alamofire")
        #endif
    }

    private func prepareURLRequest(for request: HTTPRequest) throws -> (urlRequest: URLRequest, originalURL: URL) {
        guard let url = URL(string: request.url) else {
            throw ParserError.invalidURL(request.url)
        }

        ParserLog.debug(
            "HTTPClient",
            "request method=\(request.method.rawValue) url=\(request.url) headers=\(request.headers.keys.sorted()) bodyBytes=\(request.body?.count ?? 0)"
        )

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in defaultHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if urlRequest.value(forHTTPHeaderField: "Keep-Alive") == nil {
            urlRequest.setValue("300", forHTTPHeaderField: "Keep-Alive")
        }
        if urlRequest.value(forHTTPHeaderField: "Connection") == nil {
            urlRequest.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        }
        if urlRequest.value(forHTTPHeaderField: "Cache-Control") == nil {
            urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        urlRequest = Self.applyingSiteSpecificHeaders(to: urlRequest, url: url)

        let cookieString = cookieManager.getCookieString(for: url)
        if !cookieString.isEmpty {
            urlRequest.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        urlRequest.httpBody = request.body
        return (urlRequest, url)
    }

    private func finalizeResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        originalURL: URL
    ) -> HTTPResponse {
        let finalURL = httpResponse.url ?? originalURL
        cookieManager.saveCookies(from: httpResponse, url: finalURL)

        let normalizedHeaders = Self.normalizeHeaders(httpResponse.allHeaderFields)
        let contentType = normalizedHeaders.headerValues["content-type"]?.joined(separator: ", ")
        let responseData: Data
        if Self.isZipContentType(contentType), let unzipped = Self.unzipFirstEntry(from: data) {
            ParserLog.debug("HTTPClient", "unzipped application/zip response bytes=\(data.count) -> \(unzipped.count)")
            responseData = unzipped
        } else {
            responseData = data
        }

        ParserLog.debug(
            "HTTPClient",
            "response status=\(httpResponse.statusCode) url=\(finalURL.absoluteString) bytes=\(responseData.count)"
        )
        return HTTPResponse(
            data: responseData,
            statusCode: httpResponse.statusCode,
            headers: normalizedHeaders.headers,
            url: finalURL,
            requestURL: originalURL,
            message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headerValues: normalizedHeaders.headerValues
        )
    }

    static func applyingSiteSpecificHeaders(to request: URLRequest, url: URL) -> URLRequest {
        var request = request
        guard let host = url.host?.lowercased() else { return request }

        // 晋江正文接口会校验浏览器 UA；沿用书源里的 Dalvik UA 会直接返回 2016「浏览器标识异常」。
        if host == "app.jjwxc.org", url.path == "/androidapi/chapterContent" {
            request.setValue(
                "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Mobile Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            if request.value(forHTTPHeaderField: "versionCode")?.isEmpty != false {
                request.setValue("279", forHTTPHeaderField: "versionCode")
            }
        }
        return request
    }

    private static func normalizeHeaders(_ rawHeaders: [AnyHashable: Any]) -> (headers: [String: String], headerValues: [String: [String]]) {
        var displayHeaders: [String: String] = [:]
        var headerValues: [String: [String]] = [:]
        var canonicalKeys: [String: String] = [:]

        for (key, value) in rawHeaders {
            guard let keyString = key as? String else { continue }
            let normalizedKey = keyString.lowercased()
            let values = normalizeHeaderValues(value)
            guard !values.isEmpty else { continue }

            headerValues[normalizedKey, default: []].append(contentsOf: values)

            if canonicalKeys[normalizedKey] == nil {
                canonicalKeys[normalizedKey] = keyString
            }
        }

        for (normalizedKey, values) in headerValues {
            guard let key = canonicalKeys[normalizedKey] else { continue }
            displayHeaders[key] = values.joined(separator: ", ")
        }

        return (displayHeaders, headerValues)
    }

    private static func normalizeHeaderValues(_ value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let strings as [String]:
            return strings
        case let number as NSNumber:
            return [number.stringValue]
        default:
            return ["\(value)"]
        }
    }

    /// 判断响应头是否表示 ZIP 内容。
    private static func isZipContentType(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/zip"
    }

    /// 从 ZIP 数据中提取指定路径的文件内容。
    public static func unzipEntry(from data: Data, path: String) -> Data? {
        let normalizedPath = normalizeZipPath(path)
        guard !normalizedPath.isEmpty else { return nil }

        var cursor = 0
        while cursor + 30 <= data.count {
            let signature = readUInt32LE(from: data, offset: cursor)
            guard signature == 0x04034B50 else {
                return nil
            }

            let compressionMethod = readUInt16LE(from: data, offset: cursor + 8)
            let compressedSize = Int(readUInt32LE(from: data, offset: cursor + 18))
            let uncompressedSize = Int(readUInt32LE(from: data, offset: cursor + 22))
            let fileNameLength = Int(readUInt16LE(from: data, offset: cursor + 26))
            let extraLength = Int(readUInt16LE(from: data, offset: cursor + 28))

            let nameStart = cursor + 30
            let nameEnd = nameStart + fileNameLength
            let extraEnd = nameEnd + extraLength
            let dataEnd = extraEnd + compressedSize
            guard dataEnd <= data.count else { return nil }

            let fileNameData = data.subdata(in: nameStart..<nameEnd)
            let fileName = normalizeZipPath(String(data: fileNameData, encoding: .utf8) ?? "")

            if fileName == normalizedPath {
                let fileData = data.subdata(in: extraEnd..<dataEnd)
                switch compressionMethod {
                case 0:
                    return fileData
                case 8:
                    return inflateRawDeflate(data: fileData, expectedSize: uncompressedSize)
                default:
                    return nil
                }
            }

            cursor = dataEnd
        }

        return nil
    }

    /// 从 ZIP 数据中提取指定路径文本，优先按响应头解码，再回退常见编码策略。
    public static func unzipEntryText(from data: Data, path: String, preferredCharset: String? = nil) -> String? {
        guard let entryData = unzipEntry(from: data, path: path) else { return nil }

        if let preferredCharset,
           let encoding = encoding(for: preferredCharset),
           let text = String(data: entryData, encoding: encoding) {
            return text
        }

        return decodeResponse(data: entryData, contentTypeHeader: nil)
            ?? String(data: entryData, encoding: .utf8)
            ?? String(data: entryData, encoding: .isoLatin1)
    }

    /// 解压 ZIP 数据中的首个非目录文件。
    private static func unzipFirstEntry(from data: Data) -> Data? {
        var cursor = 0

        while cursor + 30 <= data.count {
            let signature = readUInt32LE(from: data, offset: cursor)
            guard signature == 0x04034B50 else {
                return nil
            }

            let compressionMethod = readUInt16LE(from: data, offset: cursor + 8)
            let compressedSize = Int(readUInt32LE(from: data, offset: cursor + 18))
            let uncompressedSize = Int(readUInt32LE(from: data, offset: cursor + 22))
            let fileNameLength = Int(readUInt16LE(from: data, offset: cursor + 26))
            let extraLength = Int(readUInt16LE(from: data, offset: cursor + 28))

            let nameStart = cursor + 30
            let nameEnd = nameStart + fileNameLength
            let extraEnd = nameEnd + extraLength
            let dataEnd = extraEnd + compressedSize
            guard dataEnd <= data.count else { return nil }

            let fileNameData = data.subdata(in: nameStart..<nameEnd)
            let fileName = String(data: fileNameData, encoding: .utf8) ?? ""
            let isDirectory = fileName.hasSuffix("/")

            if !isDirectory {
                let fileData = data.subdata(in: extraEnd..<dataEnd)
                switch compressionMethod {
                case 0:
                    return fileData
                case 8:
                    return inflateRawDeflate(data: fileData, expectedSize: uncompressedSize)
                default:
                    return nil
                }
            }

            cursor = dataEnd
        }

        return nil
    }

    private static func normalizeZipPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func readUInt16LE(from data: Data, offset: Int) -> UInt16 {
        let range = offset..<(offset + 2)
        return data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    private static func readUInt32LE(from data: Data, offset: Int) -> UInt32 {
        let range = offset..<(offset + 4)
        return data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    private static func inflateRawDeflate(data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }

        let algorithm = COMPRESSION_ZLIB
        let destinationCapacity = max(expectedSize, data.count * 4, 1024)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                destinationBuffer,
                destinationCapacity,
                sourceBase,
                data.count,
                nil,
                algorithm
            )
        }

        guard decompressedSize > 0 else {
            return nil
        }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}

// MARK: - AnalyzeUrl
/// URL 规则解析器：处理 legado 的动态 URL 规则
///
/// URL 规则格式（参考 legado AnalyzeUrl.kt）：
/// - `https://example.com/search?q={key}&page={page}` — 普通 GET
/// - `POST:https://example.com/api/search,body=key%3D{key}` — 简单 POST
/// - `https://example.com/api,{"method":"POST","body":"q={key}","headers":{"token":"xxx"},"charset":"UTF-8"}` — JSON 选项
///
/// 关键字替换：`{key}` (URL 编码)、`{key!}` (原始未编码)、`{page}`、`{{page}}`
public nonisolated struct AnalyzeUrl {

    // MARK: - 属性

    public var urlString: String
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: String?
    public var charset: String
    public var responseType: String?
    public var retryCount: Int
    public var webView: Bool
    public var webJs: String?
    public var webViewDelayTime: Int
    public var sourceRegex: String?
    public var variableStore: ParserVariableStore?
    public var originalRule: String?

    // MARK: - 初始化

    /// 解析 URL 规则
    /// - Parameters:
    ///   - rule: URL 规则字符串（legado 格式）
    ///   - key: 搜索关键词（替换 `{key}` 和 `{key!}`）
    ///   - page: 分页页码（替换 `{page}`）
    ///   - baseUrl: 基础 URL（用于补全相对路径）
    ///   - headerString: 书源默认请求头（JSON 格式）
    public init(
        rule: String,
        key: String = "",
        page: Int = 1,
        baseUrl: String = "",
        headerString: String? = nil,
        source: BookSource? = nil,
        variableStore: ParserVariableStore? = nil
    ) {
        self.variableStore = variableStore
        self.originalRule = rule
        var processedRule = rule.trimmingCharacters(in: .whitespaces)

        // 替换 @get:{varName} 变量引用（URL 规则中常见）
        if processedRule.contains("@get:"), let store = variableStore {
            processedRule = RuleAnalyzer.substituteGetVariables(processedRule, variableStore: store)
        }
        var detectedMethod: HTTPMethod = .get

        // Android AnalyzeUrl 会先执行整条 URL 规则里所有内嵌的 @js:/<js> 块，
        // 即使 JS 只是 URL 规则中的一部分而非整条规则本身。
        processedRule = Self.executeEmbeddedJavaScript(
            in: processedRule,
            key: key,
            page: page,
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore
        )

        // 解析方法前缀（如 `GET:`, `POST:`）
        if processedRule.uppercased().hasPrefix("POST:") {
            detectedMethod = .post
            processedRule = String(processedRule.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if processedRule.uppercased().hasPrefix("GET:") {
            processedRule = String(processedRule.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }

        // 先只替换显式 raw key。普通 {{key}} / {key} 必须等 URL 与 body 分离后按上下文处理：
        // URL 片段需要百分号编码；JSON body 需要保留原始值；form body 交给统一表单编码器。
        processedRule = Self.replaceKeyPlaceholders(in: processedRule, key: key, encodeKey: false, rawOnly: true)

        // Android replaceKeyPageJs 先跑 {{...}}，再跑 <...> 分页片段与 {page} 变量。
        processedRule = Self.evaluateTemplateExpressions(in: processedRule, key: key, page: page, baseUrl: baseUrl, source: source, variableStore: variableStore)
        processedRule = Self.replacePagePattern(processedRule, page: page)

        processedRule = Self.consumePutOptions(in: processedRule, variableStore: variableStore)

        // 分离 URL 和选项部分（URL 部分是第一个 `,{` 或 `,` 之前的内容）
        // legado 格式：URL,{json options}  或  URL,body_string
        var urlPart = processedRule
        var optionPart: String? = nil

        // 找第一个顶层逗号（不在括号/引号内）
        if let commaIdx = Self.findOptionSeparator(in: processedRule) {
            urlPart = String(processedRule[processedRule.startIndex..<commaIdx])
                .trimmingCharacters(in: .whitespaces)
            optionPart = String(processedRule[processedRule.index(after: commaIdx)...])
                .trimmingCharacters(in: .whitespaces)
        }

        // 解析书源默认请求头
        var parsedHeaders: [String: String] = [:]
        if let headerStr = headerString {
            if let json = Self.parseHeaderJSON(headerStr) {
                parsedHeaders = json
            }
        }

        // 解析选项部分（尝试 JSON 格式，否则视为 body 字符串）
        var parsedBody: String? = nil
        var parsedCharset: String = "UTF-8"
        var parsedResponseType: String? = nil
        var parsedMethodFromOptions: HTTPMethod? = nil
        var parsedRetryCount = 0
        var parsedWebView = false
        var parsedWebJs: String? = nil
        var parsedWebViewDelayTime = 0
        var parsedSourceRegex: String? = nil

        if let option = optionPart {
            let trimmedOption = option.trimmingCharacters(in: .whitespacesAndNewlines)
            let decodedOption = trimmedOption.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedOption: String
            if trimmedOption.hasPrefix("{") {
                normalizedOption = trimmedOption
            } else if decodedOption?.hasPrefix("{") == true {
                normalizedOption = decodedOption!
            } else {
                normalizedOption = trimmedOption
            }

            let normalizedJSONLikeOption = Self.normalizeJSONLikeOptionText(normalizedOption)

            if normalizedOption.hasPrefix("{"),
               let optionJSON = (
                    LenientJSONParser.parse(normalizedJSONLikeOption) as? [String: Any]
                    ?? Self.parseTemplateOptionObject(from: normalizedOption)
               ) {
                // JSON 选项格式
                if let methodString = optionJSON["method"] as? String {
                    switch methodString.uppercased() {
                    case "POST":
                        parsedMethodFromOptions = .post
                    case "PUT":
                        parsedMethodFromOptions = .put
                    case "DELETE":
                        parsedMethodFromOptions = .delete
                    default:
                        break
                    }
                }
                if let headerMap = optionJSON["headers"] as? [String: Any] {
                    for (k, v) in headerMap {
                        parsedHeaders[k] = "\(v)"
                    }
                } else if let headerString = optionJSON["headers"] as? String,
                          let headerMap = Self.parseHeaderJSON(headerString) {
                    for (k, v) in headerMap {
                        parsedHeaders[k] = v
                    }
                }
                if let bodyValue = optionJSON["body"] {
                    parsedBody = Self.stringifyBodyValue(bodyValue, key: key, page: page)
                }
                if let cs = optionJSON["charset"] as? String {
                    parsedCharset = Self.normalizeCharsetName(cs)
                }
                if let responseType = optionJSON["type"] as? String,
                   !responseType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsedResponseType = responseType
                }
                if let retry = optionJSON["retry"] as? NSNumber {
                    parsedRetryCount = max(0, retry.intValue)
                } else if let retry = optionJSON["retry"] as? String,
                          let retryCount = Int(retry) {
                    parsedRetryCount = max(0, retryCount)
                }
                if let useWebView = Self.parseBooleanOption(optionJSON["webView"]) {
                    parsedWebView = useWebView
                }
                if let webJs = optionJSON["webJs"] as? String,
                   !webJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsedWebJs = webJs
                }
                if let sourceRegex = optionJSON["sourceRegex"] as? String,
                   !sourceRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsedSourceRegex = sourceRegex
                }
                if parsedBody == nil,
                   let fallbackBody = Self.extractBodyJSONString(from: normalizedOption, key: key, page: page) {
                    parsedBody = fallbackBody
                }
                if let delay = optionJSON["webViewDelayTime"] as? NSNumber {
                    parsedWebViewDelayTime = max(0, delay.intValue)
                } else if let delay = optionJSON["webViewDelayTime"] as? String,
                          let delayValue = Int(delay) {
                    parsedWebViewDelayTime = max(0, delayValue)
                }
            } else {
                // 纯文本 body
                parsedBody = normalizedOption
                    .replacingKeyPlaceholders(key: key, encodeKey: false)
                    .replacingOccurrences(of: "{{page}}", with: "\(page)")
                    .replacingOccurrences(of: "{page}", with: "\(page)")
                if !normalizedOption.isEmpty {
                    parsedMethodFromOptions = .post
                }
            }
        }

        let resolvedMethod = parsedMethodFromOptions ?? detectedMethod
        urlPart = Self.resolveURLPart(
            urlPart,
            key: key,
            baseUrl: baseUrl,
            method: resolvedMethod,
            charset: parsedCharset
        )

        self.urlString = urlPart
        self.method = resolvedMethod
        self.headers = parsedHeaders
        self.charset = Self.normalizeCharsetName(parsedCharset)
        self.body = Self.encodeRequestBodyIfNeeded(
            parsedBody,
            method: self.method,
            headers: parsedHeaders,
            charset: parsedCharset
        )
        self.responseType = parsedResponseType
        self.retryCount = parsedRetryCount
        self.webView = parsedWebView
        self.webJs = parsedWebJs
        self.webViewDelayTime = parsedWebViewDelayTime
        self.sourceRegex = parsedSourceRegex
        ParserLog.debug(
            "AnalyzeUrl",
            "rule=\(ParserLog.preview(rule)) resolvedUrl=\(self.urlString) method=\(self.method.rawValue) headers=\(self.headers.keys.sorted()) body=\(ParserLog.preview(self.body)) type=\(self.responseType ?? "") retry=\(self.retryCount) webView=\(self.webView) delay=\(self.webViewDelayTime) vars=\(variableStore?.values ?? [:]) source=\(source?.bookSourceName ?? "")"
        )
    }

    // MARK: - 辅助方法

    private static func replaceKeyPlaceholders(
        in text: String,
        key: String,
        encodeKey: Bool,
        rawOnly: Bool = false
    ) -> String {
        text.replacingKeyPlaceholders(key: key, encodeKey: encodeKey, rawOnly: rawOnly)
    }

    static func normalizeCharsetName(_ charset: String) -> String {
        let trimmed = charset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let leadingStripped = trimmed.replacingOccurrences(
            of: #"^(?:charset\s*=)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let sanitized = leadingStripped.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'\\;"))
        )
        guard !sanitized.isEmpty else { return "" }

        if let match = sanitized.range(
            of: #"^[A-Za-z0-9._-]+"#,
            options: .regularExpression
        ) {
            return String(sanitized[match])
        }
        return sanitized
    }

    /// 执行 URL 规则中内嵌的 `@js:` / `<js>...</js>` 片段。
    ///
    /// 兼容 Android `AnalyzeUrl.analyzeJs()`：
    /// - JS 片段前后的普通文本会按 `@result` 占位符回填
    /// - `result` 变量会携带上一次 JS 执行结果
    /// - 即使 JS 只是规则中的一部分，也会先执行再做后续 key/page 替换
    private static func executeEmbeddedJavaScript(
        in rule: String,
        key: String,
        page: Int,
        baseUrl: String,
        source: BookSource?,
        variableStore: ParserVariableStore?
    ) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@js:") || trimmed.contains("<js>") else { return rule }
        if isPureJavaScriptURLRule(trimmed),
           let resolvedPureRule = resolvePureJavaScriptURLRule(
                trimmed,
                key: key,
                page: page,
                baseUrl: baseUrl,
                source: source,
                variableStore: variableStore
           ) {
            return resolvedPureRule
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"<js>([\s\S]*?)</js>|@js:([\s\S]*)"#,
            options: [.caseInsensitive]
        ) else {
            return rule
        }

        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return rule }

        let jsParser = JavaScriptParser(
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore ?? ParserVariableStore()
        )
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let setupScript = """
            var key = '\(key.replacingOccurrences(of: "'", with: "\\'"))';
            var encodedKey = '\(encodedKey.replacingOccurrences(of: "'", with: "\\'"))';
            var page = \(page);
            var baseUrl = '\(baseUrl.replacingOccurrences(of: "'", with: "\\'"))';
        """

        var result = rule
        var currentLocation = 0

        for match in matches {
            let prefixLength = match.range.location - currentLocation
            if prefixLength > 0 {
                let prefix = nsRule.substring(with: NSRange(location: currentLocation, length: prefixLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    result = prefix.replacingOccurrences(of: "@result", with: result)
                }
            }

            let jsRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 1)
            let jsCode = nsRule.substring(with: jsRange)
            do {
                let evaluated = try jsParser.evaluate(script: setupScript + "\n" + jsCode, result: result)
                result = evaluated
            } catch {
                ParserLog.debug(
                    "AnalyzeUrl",
                    "embedded JS failed source=\(source?.bookSourceName ?? "") baseUrl=\(baseUrl) rule=\(ParserLog.preview(rule, limit: 240)) js=\(ParserLog.preview(jsCode, limit: 200)) error=\(error.localizedDescription)"
                )
            }
            currentLocation = match.range.location + match.range.length
        }

        if nsRule.length > currentLocation {
            let suffix = nsRule.substring(from: currentLocation).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                result = suffix.replacingOccurrences(of: "@result", with: result)
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPureJavaScriptURLRule(_ rule: String) -> Bool {
        if rule.hasPrefix("@js:") {
            return true
        }
        return rule.hasPrefix("<js>") && rule.hasSuffix("</js>")
    }

    private static func resolvePureJavaScriptURLRule(
        _ rule: String,
        key: String,
        page: Int,
        baseUrl: String,
        source: BookSource?,
        variableStore: ParserVariableStore?
    ) -> String? {
        let jsBody = extractPureJavaScriptBody(from: rule)
        let jsParser = JavaScriptParser(
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore ?? ParserVariableStore()
        )
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let setupScript = """
            var key = '\(key.replacingOccurrences(of: "'", with: "\\'"))';
            var encodedKey = '\(encodedKey.replacingOccurrences(of: "'", with: "\\'"))';
            var page = \(page);
            var baseUrl = '\(baseUrl.replacingOccurrences(of: "'", with: "\\'"))';
        """
        let normalizedScript = jsBody

        do {
            let evaluation = try jsParser.evaluateWithContext(script: setupScript + "\n" + normalizedScript, result: rule)
            let trimmedPrimary = normalizedPureJavaScriptURLRuleResult(evaluation.primary)
            let trimmedResult = normalizedPureJavaScriptURLRuleResult(evaluation.result)
            let inferredURLValue = normalizedPureJavaScriptURLRuleResult(evaluation.url)
            let trimmedEvaluated = [trimmedPrimary, trimmedResult, inferredURLValue]
                .compactMap { $0 }
                .first { !$0.isEmpty && $0 != rule }
                ?? ""
            ParserLog.debug(
                "AnalyzeUrl",
                "pure JS URL rule evaluated source=\(source?.bookSourceName ?? "") baseUrl=\(baseUrl) rule=\(ParserLog.preview(rule, limit: 240)) primary=\(ParserLog.preview(trimmedPrimary ?? "nil", limit: 240)) result=\(ParserLog.preview(trimmedResult ?? "nil", limit: 240)) url=\(ParserLog.preview(inferredURLValue ?? "nil", limit: 240)) resolved=\(ParserLog.preview(trimmedEvaluated, limit: 240))"
            )
            if !trimmedEvaluated.isEmpty {
                return trimmedEvaluated
            }
        } catch {
            ParserLog.debug(
                "AnalyzeUrl",
                "pure JS URL rule failed source=\(source?.bookSourceName ?? "") baseUrl=\(baseUrl) rule=\(ParserLog.preview(rule, limit: 240)) error=\(error.localizedDescription)"
            )
        }

        if let recovered = recoverLiteralURLRuleWrappedInJavaScript(jsBody) {
            ParserLog.debug(
                "AnalyzeUrl",
                "recovered legacy JS URL rule source=\(source?.bookSourceName ?? "") recovered=\(ParserLog.preview(recovered, limit: 240))"
            )
            return recovered
        }
        return nil
    }

    private static func extractPureJavaScriptBody(from rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("<js>"), trimmed.hasSuffix("</js>") {
            return String(trimmed.dropFirst(4).dropLast(5))
        }
        return trimmed
    }

    private static func recoverLiteralURLRuleWrappedInJavaScript(_ jsBody: String) -> String? {
        let trimmed = jsBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #";\s*result\s*=\s*(['"])\s*\1\s*;\s*result\s*;\s*$"#,
            #";\s*result\s*;\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsText = trimmed as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else {
                continue
            }

            let candidate = nsText.substring(with: NSRange(location: 0, length: match.range.location))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeLegacyLiteralURLRule(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func normalizedPureJavaScriptURLRuleResult(_ rawValue: Any?) -> String? {
        guard let rawValue else { return nil }

        if let string = rawValue as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = rawValue as? NSNumber {
            return number.stringValue
        }

        if let array = rawValue as? [Any], !array.isEmpty {
            return array
                .compactMap { normalizedPureJavaScriptURLRuleResult($0) }
                .joined(separator: "\n")
        }

        if JSONSerialization.isValidJSONObject(rawValue),
           let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let text = "\(rawValue)".trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func looksLikeLegacyLiteralURLRule(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if candidate.hasPrefix("/") || candidate.hasPrefix("?") {
            return true
        }
        if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
            return true
        }
        if candidate.contains(",{") || candidate.contains(",{'") || candidate.contains(",[") {
            return true
        }
        return false
    }

    /// 求值规则字符串中的 {{...}} 模板表达式（JS 表达式）
    /// 例如：{{cookie.removeCookie(source.key)}}、{{(page-1)*10}}、{{encodeURIComponent(key)}}
    private static func evaluateTemplateExpressions(
        in rule: String,
        key: String,
        page: Int,
        baseUrl: String,
        source: BookSource?,
        variableStore: ParserVariableStore?
    ) -> String {
        guard rule.contains("{{"), rule.contains("}}") else { return rule }

        #if canImport(JavaScriptCore)
        let jsParser = JavaScriptParser(baseUrl: baseUrl, source: source, variableStore: variableStore ?? ParserVariableStore())
        // 注入 key / page 变量供模板使用
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let setup = """
            var key = '\(key.replacingOccurrences(of: "'", with: "\\'"))';
            var encodedKey = '\(encodedKey.replacingOccurrences(of: "'", with: "\\'"))';
            var page = \(page);
            var baseUrl = '\(baseUrl.replacingOccurrences(of: "'", with: "\\'"))';
            function encodeURIComponent(s) { return java.urlEncode(s); }
            function getUrl() { return '\(baseUrl.replacingOccurrences(of: "'", with: "\\'"))'; }
            function bhost() {
                var u = '\(baseUrl.replacingOccurrences(of: "'", with: "\\'"))';
                var m = u.match(/https?:\\/\\/([^/]+)/);
                return m ? m[1] : u;
            }
        """

        // 逐个替换 {{expr}} 块
        var result = rule
        let pattern = #"\{\{([\s\S]*?)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return rule }

        var offset = 0
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))

        for match in matches {
            let fullRange = match.range(at: 0)
            let exprRange = match.range(at: 1)
            let expr = nsRule.substring(with: exprRange)

            // Skip pure {key} / {page} already replaced
            let trimExpr = expr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimExpr == "key" || trimExpr == "page" { continue }

            // Strip leading @@ (legado concatenation operator misused in templates)
            let evalExpr = trimExpr.hasPrefix("@@") ? String(trimExpr.dropFirst(2)) : trimExpr

            let jsResult = (try? jsParser.evaluate(script: setup + "\n" + evalExpr)) ?? ""
            let replacement = jsResult == "undefined" ? "" : jsResult

            // Apply offset-adjusted replacement
            let adjustedRange = NSRange(location: fullRange.location + offset, length: fullRange.length)
            if let swiftRange = Range(adjustedRange, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
                offset += replacement.count - fullRange.length
            }
        }
        return result
        #else
        return rule
        #endif
    }

    /// 替换 Android legado URL 规则里的分页语法：
    /// - `{page}` / `{{page}}`
    /// - `{{page-1}}`
    /// - `<,_{{page}}>` 这类按页码选取片段的 pagePattern
    private static func replacePagePattern(_ rule: String, page: Int) -> String {
        var result = rule

        if let pageChoiceRegex = try? NSRegularExpression(pattern: #"<(.*?)>"#, options: []) {
            let matches = pageChoiceRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 0), in: result),
                      let contentRange = Range(match.range(at: 1), in: result) else {
                    continue
                }
                let options = result[contentRange].split(separator: ",", omittingEmptySubsequences: false)
                guard !options.isEmpty else {
                    result.replaceSubrange(range, with: "")
                    continue
                }
                let chosenIndex = min(max(page - 1, 0), options.count - 1)
                let replacement = options[chosenIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                result.replaceSubrange(range, with: replacement)
            }
        }

        // 简单替换 {page} 和 {{page}}
        result = result
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{page}", with: "\(page)")
        // 替换 {{page-1}} 类型的算术表达式
        let pattern = #"\{\{page([+-]\d+)\}\}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result),
                   let offsetRange = Range(match.range(at: 1), in: result) {
                    let offset = Int(result[offsetRange]) ?? 0
                    result.replaceSubrange(range, with: "\(page + offset)")
                }
            }
        }
        return result
    }

    public static func postProcessExtractedURL(
        _ rawValue: String,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil
    ) -> String {
        postProcessExtractedURLs(rawValue, baseUrl: baseUrl, variableStore: variableStore).first ?? ""
    }

    public static func postProcessExtractedURLs(
        _ rawValue: String,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil
    ) -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("<js>") || trimmed.contains("@js:") {
            return [trimmed]
        }

        let withoutPut = consumePutOptions(in: trimmed, variableStore: variableStore)
        let commaIdx = findOptionSeparator(in: withoutPut)
        let urlPart: String
        let suffix: String
        if let commaIdx {
            urlPart = String(withoutPut[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            suffix = String(withoutPut[commaIdx...])
        } else {
            urlPart = withoutPut
            suffix = ""
        }
        let payloadCandidates = unwrapURLPayloadsIfNeeded(urlPart) ?? [urlPart]
        let rawCandidates = payloadCandidates.flatMap(splitExtractedURLCandidates)
        var seen: Set<String> = []
        var resolvedCandidates: [String] = []

        for candidate in rawCandidates {
            let resolvedURL = resolveURLPart(candidate, baseUrl: baseUrl)
            let resolvedValue = (resolvedURL + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedValue.isEmpty else { continue }
            if seen.insert(resolvedValue).inserted {
                resolvedCandidates.append(resolvedValue)
            }
        }
        return resolvedCandidates
    }

    static func extractedLiteralURLPart(from value: String, variableStore: ParserVariableStore? = nil) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let withoutPut = consumePutOptions(in: trimmed, variableStore: variableStore)
        if let commaIdx = findOptionSeparator(in: withoutPut) {
            return String(withoutPut[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return withoutPut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeLiteralURLRule(_ value: String, variableStore: ParserVariableStore? = nil) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("<js>") || trimmed.contains("@js:") {
            return false
        }

        let urlPart = extractedLiteralURLPart(from: value, variableStore: variableStore)
        guard !urlPart.isEmpty else { return false }

        if urlPart.contains("://") || urlPart.hasPrefix("/") || urlPart.hasPrefix("?") {
            return true
        }

        let lowered = urlPart.lowercased()
        if lowered.hasPrefix("www.") {
            return true
        }

        return false
    }

    /// 在字符串中找到第一个顶层逗号（不在 `{}[]"''` 内）的位置
    private static func findTopLevelComma(in string: String) -> String.Index? {
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var skipNext = false          // 用于跳过转义字符（如 `\"` 中的 `"`）
        for idx in string.indices {
            if skipNext {
                skipNext = false
                continue
            }
            let c = string[idx]
            if inDoubleQuote {
                if c == "\\" { skipNext = true; continue }
                if c == "\"" { inDoubleQuote = false }
                continue
            }
            if inSingleQuote {
                if c == "'" { inSingleQuote = false }
                continue
            }
            switch c {
            case "\"": inDoubleQuote = true
            case "'":  inSingleQuote = true
            case "{", "[", "(": depth += 1
            case "}", "]", ")": depth -= 1
            case "," where depth == 0: return idx
            default: break
            }
        }
        return nil
    }

    private static func resolveURLPart(
        _ urlPart: String,
        key: String,
        baseUrl: String,
        method: HTTPMethod,
        charset: String
    ) -> String {
        let replacedURL = replaceURLKeyPlaceholders(in: urlPart, key: key)
        var resolvedURL = makeAbsoluteURL(from: replacedURL, baseUrl: baseUrl)
        if method == .get {
            resolvedURL = encodeQueryIfNeeded(in: resolvedURL, charset: charset)
        }
        return resolvedURL
    }

    private static func replaceURLKeyPlaceholders(in urlPart: String, key: String) -> String {
        guard let querySeparator = urlPart.firstIndex(of: "?") else {
            return replaceKeyPlaceholders(in: urlPart, key: key, encodeKey: true)
        }

        let pathPart = String(urlPart[..<querySeparator])
        let queryPart = String(urlPart[urlPart.index(after: querySeparator)...])
        let encodedPath = replaceKeyPlaceholders(in: pathPart, key: key, encodeKey: true)
        let rawQuery = replaceKeyPlaceholders(in: queryPart, key: key, encodeKey: false)
        return rawQuery.isEmpty ? encodedPath : "\(encodedPath)?\(rawQuery)"
    }

    private static func makeAbsoluteURL(from urlPart: String, baseUrl: String) -> String {
        guard !urlPart.hasPrefix("http"), !baseUrl.isEmpty else {
            return urlPart
        }
        guard let base = URL(string: baseUrl),
              let resolved = URL(string: urlPart, relativeTo: base) else {
            return urlPart
        }
        return resolved.absoluteString
    }

    private static func encodeQueryIfNeeded(in url: String, charset: String) -> String {
        var workingURL = url
        var fragmentSuffix = ""
        if let fragmentSeparator = workingURL.firstIndex(of: "#") {
            fragmentSuffix = String(workingURL[fragmentSeparator...])
            workingURL = String(workingURL[..<fragmentSeparator])
        }

        guard let querySeparator = workingURL.firstIndex(of: "?") else {
            return url
        }

        let prefix = String(workingURL[..<querySeparator])
        let query = String(workingURL[workingURL.index(after: querySeparator)...])
        guard !query.isEmpty else {
            return prefix + fragmentSuffix
        }

        let encodedQuery = encodeQueryString(query, charset: charset)
        return "\(prefix)?\(encodedQuery)\(fragmentSuffix)"
    }

    private static func encodeRequestBodyIfNeeded(
        _ body: String?,
        method: HTTPMethod,
        headers: [String: String],
        charset: String
    ) -> String? {
        guard method == .post || method == .put || method == .delete else {
            return body
        }
        guard let body else { return nil }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        guard shouldEncodeFormBody(trimmed, headers: headers) else {
            return body
        }

        return encodeParameterString(trimmed, allowReservedCharacters: false, charset: charset)
    }

    private static func encodeQueryString(_ query: String, charset: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return query
        }
        return encodeParameterComponent(
            trimmed,
            allowReservedCharacters: true,
            charset: charset,
            spaceAsPlus: false
        )
    }

    private static func shouldEncodeFormBody(_ body: String, headers: [String: String]) -> Bool {
        let contentType = headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased() ?? ""

        if contentType.contains("json") || contentType.contains("xml") || contentType.contains("multipart/form-data") {
            return false
        }

        if body.hasPrefix("{") || body.hasPrefix("[") || body.hasPrefix("<") {
            return false
        }

        return true
    }

    private static func encodeParameterString(
        _ params: String,
        allowReservedCharacters: Bool,
        charset: String
    ) -> String {
        let segments = params.split(separator: "&", omittingEmptySubsequences: false)
        return segments.map { segment in
            guard let separatorIndex = segment.firstIndex(of: "=") else {
                return encodeParameterComponent(String(segment), allowReservedCharacters: allowReservedCharacters, charset: charset)
            }

            let key = String(segment[..<separatorIndex])
            let value = String(segment[segment.index(after: separatorIndex)...])
            let encodedKey = encodeParameterComponent(key, allowReservedCharacters: allowReservedCharacters, charset: charset)
            let encodedValue = encodeParameterComponent(value, allowReservedCharacters: allowReservedCharacters, charset: charset)
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private static func encodeParameterComponent(
        _ value: String,
        allowReservedCharacters: Bool,
        charset: String,
        spaceAsPlus: Bool = true
    ) -> String {
        guard !value.isEmpty else { return value }
        if looksPercentEncoded(value, allowReservedCharacters: allowReservedCharacters) {
            return value
        }

        if charset.caseInsensitiveCompare("escape") == .orderedSame {
            return value.unicodeScalars.map { scalar in
                if isAllowedParameterScalar(scalar, allowReservedCharacters: allowReservedCharacters) {
                    return String(scalar)
                }
                if scalar.value < 256 {
                    return String(format: "%%%02X", scalar.value)
                }
                return String(format: "%%u%04X", scalar.value)
            }.joined()
        }

        return value.unicodeScalars.map { scalar in
            if scalar == " " {
                return spaceAsPlus ? "+" : "%20"
            }
            if isAllowedParameterScalar(scalar, allowReservedCharacters: allowReservedCharacters) {
                return String(scalar)
            }

            let stringEncoding = formEncoding(for: charset) ?? .utf8
            guard let data = String(scalar).data(using: stringEncoding) else {
                return String(scalar)
            }
            return data.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    private static func formEncoding(for charset: String) -> String.Encoding? {
        switch normalizeCharsetName(charset).lowercased() {
        case "gbk", "gb2312", "gb18030", "gb_2312-80", "chinese", "csgb2312":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: value)
        case "big5":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: value)
        case "utf-8", "utf8", "":
            return .utf8
        default:
            let normalizedCharset = normalizeCharsetName(charset)
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringConvertIANACharSetNameToEncoding(normalizedCharset as CFString)
                )
            )
        }
    }

    private static func isAllowedParameterScalar(_ scalar: UnicodeScalar, allowReservedCharacters: Bool) -> Bool {
        if scalar.value < 128,
           (scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)) {
            return true
        }

        let formAllowed = "-._*"
        let queryReserved = "!*'();:@&=+$,/?#[]"
        if formAllowed.unicodeScalars.contains(scalar) {
            return true
        }
        return allowReservedCharacters && queryReserved.unicodeScalars.contains(scalar)
    }

    private static func looksPercentEncoded(_ value: String, allowReservedCharacters: Bool) -> Bool {
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "%" {
                let first = value.index(after: index)
                guard first < value.endIndex else { return false }
                let second = value.index(after: first)
                guard second < value.endIndex,
                      value[first].isHexDigit,
                      value[second].isHexDigit else {
                    return false
                }
                index = value.index(after: second)
                continue
            }
            if character == "+" {
                index = value.index(after: index)
                continue
            }
            guard let scalar = character.unicodeScalars.first,
                  isAllowedParameterScalar(scalar, allowReservedCharacters: allowReservedCharacters) else {
                return false
            }
            index = value.index(after: index)
        }
        return true
    }

    private static func findTopLevelOptionComma(in string: String) -> String.Index? {
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var skipNext = false

        for idx in string.indices {
            if skipNext {
                skipNext = false
                continue
            }

            let character = string[idx]
            if inDoubleQuote {
                if character == "\\" { skipNext = true; continue }
                if character == "\"" { inDoubleQuote = false }
                continue
            }
            if inSingleQuote {
                if character == "'" { inSingleQuote = false }
                continue
            }

            switch character {
            case "\"":
                inDoubleQuote = true
            case "'":
                inSingleQuote = true
            case "{", "[", "(":
                depth += 1
            case "}", "]", ")":
                depth -= 1
            case "," where depth == 0:
                let afterComma = string.index(after: idx)
                let remainder = string[afterComma...].trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.hasPrefix("{") || remainder.hasPrefix("[") {
                    return idx
                }
            default:
                break
            }
        }
        return nil
    }

    private static func findOptionSeparator(in string: String) -> String.Index? {
        let commaCandidates = [findTopLevelOptionComma(in: string), findTopLevelComma(in: string)]
            .compactMap { $0 }

        for commaIdx in commaCandidates.sorted(by: { string.distance(from: string.startIndex, to: $0) < string.distance(from: string.startIndex, to: $1) }) {
            let afterComma = string.index(after: commaIdx)
            let remainder = String(string[afterComma...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { continue }
            if looksLikeOptionPayload(remainder) {
                return commaIdx
            }
        }
        return nil
    }

    private static func looksLikeOptionPayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return true
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("body=") || lowered.hasPrefix("charset=") || lowered.hasPrefix("method=") {
            return true
        }

        return false
    }

    private static func splitExtractedURLCandidates(_ value: String) -> [String] {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "&&", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        if let htmlCandidates = extractHTMLURLAttributes(from: normalized), !htmlCandidates.isEmpty {
            return htmlCandidates
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            let matches = detector.matches(in: normalized, options: [], range: range)
            let urls = matches.compactMap { match -> String? in
                guard let url = match.url else { return nil }
                return normalizedURLCandidate(url.absoluteString)
            }
            if !urls.isEmpty {
                if urls.count > 1 || urls[0] != normalizedURLCandidate(normalized) {
                    return urls
                }
            }
        }

        if normalized.contains("\n") {
            return normalized
                .components(separatedBy: .newlines)
                .map(normalizedURLCandidate)
                .filter { !$0.isEmpty }
        }

        return [normalized]
    }

    private static func extractHTMLURLAttributes(from value: String) -> [String]? {
        let pattern = #"(?:href|src|value)\s*=\s*(['"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        return matches.compactMap { match in
            guard let candidateRange = Range(match.range(at: 2), in: value) else { return nil }
            return normalizedURLCandidate(String(value[candidateRange]))
        }
    }

    private static func normalizedURLCandidate(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "" }

        if candidate.hasPrefix("url("), candidate.hasSuffix(")") {
            candidate = String(candidate.dropFirst(4).dropLast())
        }

        candidate = candidate
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(
                of: #"\s+"#,
                with: "",
                options: .regularExpression
            )

        if candidate.hasPrefix("https:/"), !candidate.hasPrefix("https://") {
            candidate = "https://" + candidate.dropFirst("https:/".count)
        } else if candidate.hasPrefix("http:/"), !candidate.hasPrefix("http://") {
            candidate = "http://" + candidate.dropFirst("http:/".count)
        }

        return candidate
    }

    private static func resolveURLPart(_ urlPart: String, baseUrl: String) -> String {
        let normalized = normalizedURLCandidate(urlPart)
        guard !normalized.isEmpty else { return "" }

        if normalized.hasPrefix("//") {
            if shouldTreatProtocolRelativePathAsRootPath(normalized) {
                return resolveURLPart(String(normalized.dropFirst(2)), baseUrl: baseUrl)
            }
            let scheme = URL(string: baseUrl)?.scheme ?? "https"
            return "\(scheme):\(normalized)"
        }

        if normalized.hasPrefix("http://")
            || normalized.hasPrefix("https://") {
            if let repaired = repairPseudoAbsoluteRootPath(normalized, baseUrl: baseUrl) {
                return repaired
            }
            return normalized
        }

        if normalized.hasPrefix("data:")
            || normalized.hasPrefix("file:")
            || normalized.hasPrefix("about:")
            || normalized.hasPrefix("javascript:") {
            return normalized
        }

        if !normalized.hasPrefix("/")
            && !normalized.hasPrefix("?")
            && !normalized.hasPrefix("#")
            && !normalized.contains("://") {
            let hostCandidate = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
            if hostCandidate.contains("."),
               !shouldTreatProtocolRelativePathAsRootPath("//" + hostCandidate) {
                let scheme = URL(string: baseUrl)?.scheme ?? "https"
                return "\(scheme)://\(normalized)"
            }
        }

        guard !baseUrl.isEmpty,
              let base = URL(string: baseUrl),
              let resolved = URL(string: normalized, relativeTo: base) else {
            return normalized
        }
        return resolved.absoluteString
    }

    private static func repairPseudoAbsoluteRootPath(_ value: String, baseUrl: String) -> String? {
        guard let url = URL(string: value),
              let host = url.host,
              shouldTreatProtocolRelativePathAsRootPath("//" + host) else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty else { return nil }

        var rootPath = host
        if let query = url.query, !query.isEmpty {
            rootPath += "?\(query)"
        }
        if let fragment = url.fragment, !fragment.isEmpty {
            rootPath += "#\(fragment)"
        }
        return resolveURLPart(rootPath, baseUrl: baseUrl)
    }

    private static func shouldTreatProtocolRelativePathAsRootPath(_ value: String) -> Bool {
        let candidate = String(value.dropFirst(2))
        let firstSegment = candidate.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard !firstSegment.isEmpty else { return false }
        if !firstSegment.contains(".") {
            return true
        }
        return firstSegment.range(
            of: #"^[A-Za-z0-9_-]+\.(?:html?|s?html|php|asp|aspx|jsp)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func unwrapURLPayloadIfNeeded(_ value: String) -> String? {
        unwrapURLPayloadsIfNeeded(value)?.first
    }

    private static func unwrapURLPayloadsIfNeeded(_ value: String) -> [String]? {
        guard value.first == "{" || value.first == "[" || value.first == "\"" else {
            return nil
        }
        guard let object = LenientJSONParser.parse(value) else {
            return nil
        }
        let urls = extractURLStrings(from: object)
        return urls.isEmpty ? nil : urls
    }

    private static func extractURLString(from object: Any) -> String? {
        extractURLStrings(from: object).first
    }

    private static func extractURLStrings(from object: Any) -> [String] {
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        if let dictionary = object as? [String: Any] {
            var results: [String] = []
            for key in ["url", "path", "chapterUrl", "nextUrl", "href"] {
                if let value = dictionary[key] {
                    results.append(contentsOf: extractURLStrings(from: value))
                }
            }
            return results
        }

        if let array = object as? [Any] {
            return array.flatMap(extractURLStrings(from:))
        }

        return []
    }

    private static func stringifyBodyValue(_ bodyValue: Any, key: String, page: Int = 1) -> String? {
        if let string = bodyValue as? String {
            return string
                .replacingKeyPlaceholders(key: key, encodeKey: false)
                .replacingOccurrences(of: "{{page}}", with: "\(page)")
                .replacingOccurrences(of: "{page}", with: "\(page)")
        }

        let resolvedBody = resolveJSONTemplateValue(bodyValue, key: key, page: page)

        guard JSONSerialization.isValidJSONObject(resolvedBody),
              let data = try? JSONSerialization.data(withJSONObject: resolvedBody),
              let string = String(data: data, encoding: .utf8) else {
            return "\(resolvedBody)"
        }
        return string
    }

    private static func normalizeJSONLikeOptionText(_ input: String) -> String {
        let quotedTemplates = quoteStandaloneTemplateLiterals(in: input)
        return quoteBareScalarValues(in: quotedTemplates)
    }

    private static func quoteStandaloneTemplateLiterals(in input: String) -> String {
        let pattern = #"([:\[,]\s*)(\{\{[^{}]+\}\}|\{[A-Za-z0-9_!+\-]+\})(\s*[,}\]])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }

        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else {
            return input
        }

        var output = input
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let fullRange = Range(match.range(at: 0), in: output),
                  let prefixRange = Range(match.range(at: 1), in: output),
                  let tokenRange = Range(match.range(at: 2), in: output),
                  let suffixRange = Range(match.range(at: 3), in: output) else {
                continue
            }

            let prefix = output[prefixRange]
            let token = output[tokenRange]
            let suffix = output[suffixRange]
            output.replaceSubrange(fullRange, with: "\(prefix)\"\(token)\"\(suffix)")
        }

        return output
    }

    /// 将 JSON-like 文本中的裸字符串值补成合法 JSON。
    /// 例如：{"keyword":遮天,"page":1} -> {"keyword":"遮天","page":1}
    /// 只处理对象/数组里的 value 位置，避免影响 key 或已合法的 JSON 标量。
    private static func quoteBareScalarValues(in input: String) -> String {
        var output = ""
        var current = input.startIndex
        var expectingValue = false
        var inSingleQuote = false
        var inDoubleQuote = false
        var skipNext = false

        func shouldPreserveScalar(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }

            if trimmed == "true" || trimmed == "false" || trimmed == "null" {
                return true
            }

            if Double(trimmed) != nil {
                return true
            }

            return false
        }

        while current < input.endIndex {
            let character = input[current]

            if skipNext {
                output.append(character)
                skipNext = false
                current = input.index(after: current)
                continue
            }

            if inDoubleQuote {
                output.append(character)
                if character == "\\" {
                    skipNext = true
                } else if character == "\"" {
                    inDoubleQuote = false
                }
                current = input.index(after: current)
                continue
            }

            if inSingleQuote {
                output.append(character)
                if character == "\\" {
                    skipNext = true
                } else if character == "'" {
                    inSingleQuote = false
                }
                current = input.index(after: current)
                continue
            }

            switch character {
            case "\"":
                inDoubleQuote = true
                output.append(character)
                current = input.index(after: current)
            case "'":
                inSingleQuote = true
                output.append(character)
                current = input.index(after: current)
            case ":":
                expectingValue = true
                output.append(character)
                current = input.index(after: current)
            case ",", "{", "[":
                output.append(character)
                current = input.index(after: current)
                if character == "," {
                    expectingValue = false
                }
            case "}", "]":
                output.append(character)
                expectingValue = false
                current = input.index(after: current)
            default:
                if expectingValue {
                    if character.isWhitespace {
                        output.append(character)
                        current = input.index(after: current)
                        continue
                    }

                    if character == "\"" || character == "{" || character == "[" {
                        expectingValue = false
                        continue
                    }

                    let valueStart = current
                    var valueEnd = current
                    while valueEnd < input.endIndex {
                        let valueCharacter = input[valueEnd]
                        if valueCharacter == "," || valueCharacter == "}" || valueCharacter == "]" {
                            break
                        }
                        valueEnd = input.index(after: valueEnd)
                    }

                    let rawValue = String(input[valueStart..<valueEnd])
                    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let leadingWhitespace = rawValue.prefix { $0.isWhitespace }
                    let trailingWhitespace = String(rawValue.reversed().prefix { $0.isWhitespace }.reversed())

                    if shouldPreserveScalar(trimmed) {
                        output.append(contentsOf: rawValue)
                    } else {
                        let escaped = trimmed
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                        output.append(contentsOf: leadingWhitespace)
                        output.append("\"\(escaped)\"")
                        output.append(contentsOf: trailingWhitespace)
                    }

                    expectingValue = false
                    current = valueEnd
                } else {
                    output.append(character)
                    current = input.index(after: current)
                }
            }
        }

        return output
    }

    private static func parseTemplateOptionObject(from input: String) -> [String: Any]? {
        let quoted = normalizeJSONLikeOptionText(input)
        var parsed: [String: Any] = [:]

        if let methodKeyRange = quoted.range(of: "\"method\""),
           let methodValue = parseScalarOptionValue(in: quoted, after: methodKeyRange.upperBound) {
            parsed["method"] = methodValue
        }

        if let bodyKeyRange = quoted.range(of: "\"body\"") {
            if let bodyRange = parseObjectOptionValueRange(in: quoted, after: bodyKeyRange.upperBound),
               let bodyValue = LenientJSONParser.parse(String(quoted[bodyRange])) {
                parsed["body"] = bodyValue
            } else if let bodyValue = parseScalarOptionValue(in: quoted, after: bodyKeyRange.upperBound) {
                parsed["body"] = bodyValue
            }
        }

        if let headersKeyRange = quoted.range(of: "\"headers\"") {
            if let headersRange = parseObjectOptionValueRange(in: quoted, after: headersKeyRange.upperBound),
               let headersValue = LenientJSONParser.parse(String(quoted[headersRange])) {
                parsed["headers"] = headersValue
            } else if let headersValue = parseScalarOptionValue(in: quoted, after: headersKeyRange.upperBound),
                      let headers = parseHeaderJSON(headersValue) {
                parsed["headers"] = headers
            }
        }

        if let charsetKeyRange = quoted.range(of: "\"charset\""),
           let charsetValue = parseScalarOptionValue(in: quoted, after: charsetKeyRange.upperBound) {
            parsed["charset"] = charsetValue
        }

        return parsed.isEmpty ? nil : parsed
    }

    private static func parseObjectOptionValueRange(
        in input: String,
        after keyEnd: String.Index
    ) -> Range<String.Index>? {
        guard let colonIndex = input[keyEnd...].firstIndex(of: ":") else {
            return nil
        }
        return balancedValueRange(in: input, startingAt: input.index(after: colonIndex))
    }

    private static func parseScalarOptionValue(
        in input: String,
        after keyEnd: String.Index
    ) -> String? {
        guard let colonIndex = input[keyEnd...].firstIndex(of: ":") else {
            return nil
        }

        var cursor = input.index(after: colonIndex)
        while cursor < input.endIndex, input[cursor].isWhitespace {
            cursor = input.index(after: cursor)
        }
        guard cursor < input.endIndex else { return nil }

        if input[cursor] == "\"" {
            let start = input.index(after: cursor)
            guard let end = input[start...].firstIndex(of: "\"") else { return nil }
            return String(input[start..<end])
        }

        let end = input[cursor...].firstIndex { $0 == "," || $0 == "}" || $0 == "]" } ?? input.endIndex
        return String(input[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveJSONTemplateValue(_ value: Any, key: String, page: Int) -> Any {
        if let string = value as? String {
            switch string {
            case "{{page}}", "{page}":
                return page
            case "{{key}}", "{key}", "{{key!}}", "{key!}":
                return key
            default:
                return string
                    .replacingOccurrences(of: "{{key!}}", with: key)
                    .replacingOccurrences(of: "{{key}}", with: key)
                    .replacingOccurrences(of: "{key!}", with: key)
                    .replacingOccurrences(of: "{key}", with: key)
                    .replacingOccurrences(of: "{{page}}", with: "\(page)")
                    .replacingOccurrences(of: "{page}", with: "\(page)")
            }
        }

        if let array = value as? [Any] {
            return array.map { resolveJSONTemplateValue($0, key: key, page: page) }
        }

        if let dictionary = value as? [String: Any] {
            var resolved: [String: Any] = [:]
            for (nestedKey, nestedValue) in dictionary {
                resolved[nestedKey] = resolveJSONTemplateValue(nestedValue, key: key, page: page)
            }
            return resolved
        }

        return value
    }

    private static func extractBodyJSONString(from optionText: String, key: String, page: Int) -> String? {
        let quoted = normalizeJSONLikeOptionText(optionText)
        guard let bodyKeyRange = quoted.range(of: "\"body\""),
              let bodyRange = parseObjectOptionValueRange(in: quoted, after: bodyKeyRange.upperBound),
              let bodyValue = LenientJSONParser.parse(String(quoted[bodyRange])) else {
            return nil
        }
        return stringifyBodyValue(bodyValue, key: key, page: page)
    }

    private static func parseBooleanOption(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "", "false", "0", "null":
                return false
            case "true", "1":
                return true
            default:
                return true
            }
        default:
            return nil
        }
    }

    private static func consumePutOptions(
        in rule: String,
        variableStore: ParserVariableStore?
    ) -> String {
        var output = rule

        while let putRange = output.range(of: "@put:") {
            guard let objectRange = balancedValueRange(in: output, startingAt: putRange.upperBound) else {
                break
            }

            let objectText = String(output[objectRange])
            if let dictionary = LenientJSONParser.parse(objectText) as? [String: Any] {
                for (key, value) in dictionary {
                    _ = variableStore?.put(key, value: stringifyVariableValue(value))
                }
            }

            let prefix = String(output[..<putRange.lowerBound])
            var suffixStart = objectRange.upperBound
            var replacement = prefix
            if suffixStart < output.endIndex, output[suffixStart] == "," {
                replacement += ","
                suffixStart = output.index(after: suffixStart)
            }
            replacement += output[suffixStart...]
            output = replacement
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func balancedValueRange(
        in string: String,
        startingAt index: String.Index
    ) -> Range<String.Index>? {
        var current = index
        while current < string.endIndex, string[current].isWhitespace {
            current = string.index(after: current)
        }
        guard current < string.endIndex else { return nil }

        let opening = string[current]
        let closing: Character
        switch opening {
        case "{":
            closing = "}"
        case "[":
            closing = "]"
        default:
            return nil
        }

        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var skipNext = false
        var cursor = current

        while cursor < string.endIndex {
            let character = string[cursor]

            if skipNext {
                skipNext = false
                cursor = string.index(after: cursor)
                continue
            }

            if inDoubleQuote {
                if character == "\\" { skipNext = true }
                else if character == "\"" { inDoubleQuote = false }
                cursor = string.index(after: cursor)
                continue
            }

            if inSingleQuote {
                if character == "\\" { skipNext = true }
                else if character == "'" { inSingleQuote = false }
                cursor = string.index(after: cursor)
                continue
            }

            if character == "\"" {
                inDoubleQuote = true
            } else if character == "'" {
                inSingleQuote = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return current..<string.index(after: cursor)
                }
            }

            cursor = string.index(after: cursor)
        }

        return nil
    }

    private static func stringifyVariableValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return "\(value)"
        }
    }

    /// 将请求头 JSON 字符串解析为字典（public，供外部模块使用）
    public static func parseHeaderJSONPublic(_ str: String) -> [String: String]? {
        parseHeaderJSON(str)
    }

    /// 将请求头 JSON 字符串解析为字典
    private static func parseHeaderJSON(_ str: String) -> [String: String]? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = parseHeaderJSONObject(trimmed) {
            return parsed
        }

        let normalized = normalizeJSONLikeOptionText(trimmed)
        if normalized != trimmed, let parsed = parseHeaderJSONObject(normalized) {
            return parsed
        }

        if let parsed = parseHeaderPairs(trimmed) {
            return parsed
        }

        if normalized != trimmed, let parsed = parseHeaderPairs(normalized) {
            return parsed
        }

        return nil
    }

    private static func parseHeaderJSONObject(_ str: String) -> [String: String]? {
        guard let json = LenientJSONParser.parse(str) else { return nil }
        if let dict = json as? [String: String] { return dict }
        if let dict = json as? [String: Any] {
            return dict.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        }
        return nil
    }

    private static func parseHeaderPairs(_ str: String) -> [String: String]? {
        var body = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{"), body.hasSuffix("}") {
            body.removeFirst()
            body.removeLast()
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: ",\n")
        let rawPairs = body
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var headers: [String: String] = [:]
        for pair in rawPairs {
            guard let colonIndex = pair.firstIndex(of: ":") else { continue }
            let key = pair[..<colonIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = pair[pair.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }
            headers[key] = value
        }

        return headers.isEmpty ? nil : headers
    }

    /// 构建 URLRequest
    public func buildRequest(cookieManager: CookieManager = .shared) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw ParserError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(HTTPClient.shared.userAgent, forHTTPHeaderField: "User-Agent")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if request.value(forHTTPHeaderField: "Keep-Alive") == nil {
            request.setValue("300", forHTTPHeaderField: "Keep-Alive")
        }
        if request.value(forHTTPHeaderField: "Connection") == nil {
            request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        }
        if request.value(forHTTPHeaderField: "Cache-Control") == nil {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        let cookieString = cookieManager.getCookieString(for: url)
        if !cookieString.isEmpty {
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        return request
    }
}

private extension String {
    func replacingKeyPlaceholders(key: String, encodeKey: Bool, rawOnly: Bool = false) -> String {
        let replacement = encodeKey
            ? (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)
            : key
        var result = self
            .replacingOccurrences(of: "{{key!}}", with: key)
            .replacingOccurrences(of: "{key!}", with: key)

        guard !rawOnly else {
            return result
        }

        result = result
            .replacingOccurrences(of: "{{key}}", with: replacement)
            .replacingOccurrences(of: "{key}", with: replacement)
        return result
    }
}
