import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

private enum LenientJSONParserV2 {
    static func parse(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        let normalized = normalizeSingleQuotedJSON(trimmed)
        if normalized != trimmed,
           let data = normalized.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

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

    private static func normalizeSingleQuotedJSON(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        var inDoubleQuote = false
        var inSingleQuote = false

        while i < input.endIndex {
            let character = input[i]
            let next = input.index(after: i)

            if inDoubleQuote {
                if character == "\\" && next < input.endIndex {
                    result.append(character)
                    result.append(input[next])
                    i = input.index(after: next)
                    continue
                }
                if character == "\"" { inDoubleQuote = false }
                result.append(character)
            } else if inSingleQuote {
                if character == "\\" && next < input.endIndex {
                    result.append(character)
                    result.append(input[next])
                    i = input.index(after: next)
                    continue
                }
                if character == "'" {
                    inSingleQuote = false
                    result.append("\"")
                } else if character == "\"" {
                    result.append("\\\"")
                } else {
                    result.append(character)
                }
            } else {
                if character == "\"" {
                    inDoubleQuote = true
                    result.append(character)
                } else if character == "'" {
                    inSingleQuote = true
                    result.append("\"")
                } else {
                    result.append(character)
                }
            }
            i = next
        }
        return result
    }
}

// MARK: - AnalyzeUrlV2

/// Android `AnalyzeUrl` 对齐的 V2 URL runtime。
///
/// 这一层的职责不是“顺手包一下旧 AnalyzeUrl”，而是把 URL 规则的解释流程收口为统一入口：
/// 1. 处理整条规则中的 `@js:` / `<js>...</js>`
/// 2. 处理 `{{...}}` 模板表达式
/// 3. 处理 `<...>` 分页片段与 `{page}` / `{{page}}`
/// 4. 分离 URL 主体与 option payload
/// 5. 解析 option JSON，产出标准化 request / descriptor 所需中间态
///
/// 这样 `WebBookV2` 的四类请求都只需要“提供阶段输入”，而不再自己理解 URL 规则语法。
nonisolated struct AnalyzeUrlV2 {

    // MARK: - Nested Types

    /// 单次 URL runtime 的原始输入。
    ///
    /// 之所以单独建模，是为了把 Android `AnalyzeUrl(...)` 的构造参数显式保留下来，
    /// 便于 trace、fixture 测试，以及后续把 request runtime 拆得更细。
    struct Input: Sendable {
        var rule: String
        var key: String
        var page: Int
        var baseUrl: String
        var headerString: String?
        var source: BookSource?
        var variableStore: ParserVariableStore?

        init(
            rule: String,
            key: String = "",
            page: Int = 1,
            baseUrl: String = "",
            headerString: String? = nil,
            source: BookSource? = nil,
            variableStore: ParserVariableStore? = nil
        ) {
            self.rule = rule
            self.key = key
            self.page = page
            self.baseUrl = baseUrl
            self.headerString = headerString
            self.source = source
            self.variableStore = variableStore
        }
    }

    /// URL runtime 解释后的中间态。
    ///
    /// 这里明确暴露 Android 风格的几个关键阶段，方便我们在 compare / trace 中直接看到：
    /// - 原始规则
    /// - JS 全条规则替换后的文本
    /// - 模板 / 分页替换后的文本
    /// - URL 主体与 option payload 的分离结果
    struct TraceState: Codable, Sendable {
        var originalRule: String
        var afterEmbeddedJavaScript: String
        var afterTemplateExpansion: String
        var urlPart: String
        var optionPart: String?
        var resolvedURL: String
        var method: String
        var appliedOptions: [String]
    }

    /// option payload 解析后的规范结果。
    private struct ParsedOptions {
        var method: HTTPMethod?
        var headers: [String: String] = [:]
        var body: String?
        var charset: String = "UTF-8"
        var responseType: String?
        var retryCount: Int = 0
        var webView: Bool = false
        var webJs: String?
        var javaScriptURLOverride: String?
        var sourceRegex: String?
        var webViewDelayTime: Int = 0
        var appliedOptions: [String] = []
    }

    // MARK: - Stored Properties

    let input: Input
    let traceState: TraceState
    private let parsedOptions: ParsedOptions

    var urlString: String { traceState.resolvedURL }
    var method: HTTPMethod {
        HTTPMethod(rawValue: traceState.method) ?? .get
    }
    var headers: [String: String] { parsedOptions.headers }
    var body: String? { parsedOptions.body }
    var charset: String { parsedOptions.charset }
    var responseType: String? { parsedOptions.responseType }
    var retryCount: Int { parsedOptions.retryCount }
    var webView: Bool { parsedOptions.webView }
    var webJs: String? { parsedOptions.webJs }
    var webViewDelayTime: Int { parsedOptions.webViewDelayTime }
    var sourceRegex: String? { parsedOptions.sourceRegex }
    var variableStore: ParserVariableStore? { input.variableStore }
    var originalRule: String? { input.rule }

    func withWebViewOverrides(webJs: String?, sourceRegex: String?) -> AnalyzeUrlV2 {
        var overriddenOptions = parsedOptions
        if let webJs, !webJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overriddenOptions.webJs = webJs
        }
        if let sourceRegex, !sourceRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overriddenOptions.sourceRegex = sourceRegex
        }
        return AnalyzeUrlV2(input: input, traceState: traceState, parsedOptions: overriddenOptions)
    }

    // MARK: - Init

    init(
        rule: String,
        key: String = "",
        page: Int = 1,
        baseUrl: String = "",
        headerString: String? = nil,
        source: BookSource? = nil,
        variableStore: ParserVariableStore? = nil
    ) {
        self.init(
            input: Input(
                rule: rule,
                key: key,
                page: page,
                baseUrl: baseUrl,
                headerString: headerString,
                source: source,
                variableStore: variableStore
            )
        )
    }

    init(input: Input) {
        self.input = input

        let originalRule = input.rule.trimmingCharacters(in: .whitespaces)
        let replacedGetVariables = Self.replaceGetVariablesIfNeeded(originalRule, variableStore: input.variableStore)
        let jsExpandedRule = Self.executeEmbeddedJavaScript(
            in: replacedGetVariables,
            key: input.key,
            page: input.page,
            baseUrl: input.baseUrl,
            source: input.source,
            variableStore: input.variableStore
        )
        let (ruleBody, prefixedMethod) = Self.consumeMethodPrefix(jsExpandedRule)

        // Android `replaceKeyPageJs` 是先处理 `{{...}}`，再处理 page pattern。
        // 同时 `raw key` 需要先替换，避免模板 / body 上下文被错误编码。
        let rawKeyReplaced = Self.replaceKeyPlaceholders(in: ruleBody, key: input.key, encodeKey: false, rawOnly: true)
        let templateExpanded = Self.evaluateTemplateExpressions(
            in: rawKeyReplaced,
            key: input.key,
            page: input.page,
            baseUrl: input.baseUrl,
            source: input.source,
            variableStore: input.variableStore
        )
        let pageExpanded = Self.replacePagePattern(templateExpanded, page: input.page)
        let putConsumed = Self.consumePutOptions(in: pageExpanded, variableStore: input.variableStore)

        let (urlPart, optionPart) = Self.splitRuleAndOption(from: putConsumed)
        var parsedOptions = Self.parseOptions(
            optionPart,
            key: input.key,
            page: input.page,
            headerString: input.headerString
        )
        let resolvedMethod = parsedOptions.method ?? prefixedMethod

        var resolvedURL = Self.resolveURLPart(
            urlPart,
            key: input.key,
            baseUrl: input.baseUrl,
            method: resolvedMethod,
            charset: parsedOptions.charset
        )

        if let optionJavaScript = parsedOptions.javaScriptURLOverride,
           !optionJavaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedURL = Self.evaluateOptionJavaScriptURLOverride(
                optionJavaScript,
                currentURL: resolvedURL,
                key: input.key,
                page: input.page,
                baseUrl: input.baseUrl,
                source: input.source,
                variableStore: input.variableStore
            ) ?? resolvedURL
        }

        parsedOptions.body = Self.encodeRequestBodyIfNeeded(
            parsedOptions.body,
            method: resolvedMethod,
            headers: parsedOptions.headers,
            charset: parsedOptions.charset
        )

        self.parsedOptions = parsedOptions
        self.traceState = TraceState(
            originalRule: input.rule,
            afterEmbeddedJavaScript: jsExpandedRule,
            afterTemplateExpansion: putConsumed,
            urlPart: urlPart,
            optionPart: optionPart,
            resolvedURL: resolvedURL,
            method: resolvedMethod.rawValue,
            appliedOptions: parsedOptions.appliedOptions
        )

        ParserLog.debug(
            "AnalyzeUrlV2",
            "source=\(input.source?.bookSourceName ?? "") rule=\(ParserLog.preview(input.rule)) urlPart=\(ParserLog.preview(urlPart)) option=\(ParserLog.preview(optionPart)) resolved=\(resolvedURL) method=\(resolvedMethod.rawValue) headers=\(parsedOptions.headers.keys.sorted()) body=\(ParserLog.preview(parsedOptions.body)) applied=\(parsedOptions.appliedOptions)"
        )
    }

    private init(
        input: Input,
        traceState: TraceState,
        parsedOptions: ParsedOptions
    ) {
        self.input = input
        self.traceState = traceState
        self.parsedOptions = parsedOptions
    }

    // MARK: - Public Runtime Output

    /// 基于统一 URL runtime 产出标准化 HTTPRequest。
    ///
    /// 这样 `RequestExecutorV2` 不再需要重新理解任何 URL 规则语法，
    /// 只负责把 runtime 产物发出去。
    func makeRequest(
        timeout: TimeInterval,
        transportPreference: HTTPRequest.TransportPreference = .automatic,
        enableCookieJar: Bool = true,
        followRedirects: Bool = true
    ) -> HTTPRequest {
        HTTPRequest(
            url: urlString,
            method: method,
            headers: requestHeaders,
            body: requestBodyData,
            timeout: timeout,
            charset: charset,
            followRedirects: followRedirects,
            transportPreference: transportPreference,
            enableCookieJar: enableCookieJar
        )
    }

    /// 基于统一 URL runtime 产出 descriptor。
    ///
    /// descriptor 除了保留 request 层摘要，还额外记录 URL runtime 的关键中间态，
    /// 方便和 Android 的 AnalyzeUrl 逐字段核对。
    func makeDescriptor(
        request: HTTPRequest,
        transportPreference: HTTPRequest.TransportPreference,
        cookieJarEnabled: Bool,
        followRedirects: Bool
    ) -> LegadoRequestDescriptorV2 {
        LegadoRequestDescriptorV2(
            resolvedURL: request.url,
            method: request.method.rawValue,
            headerKeys: request.headers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            originalRulePreview: ParserLog.preview(input.rule, limit: 220),
            bodyLength: request.body?.count ?? 0,
            bodyPreview: Self.bodyPreview(request.body, charset: request.charset),
            bodyHash: Self.bodyHash(request.body),
            charset: request.charset,
            webView: webView,
            webJs: webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            sourceRegex: sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            retryCount: retryCount,
            responseType: responseType,
            cookieJarEnabled: cookieJarEnabled,
            timeoutSeconds: request.timeout,
            followRedirects: followRedirects,
            transportPreference: Self.transportPreferenceName(transportPreference),
            runtimeTrace: traceState
        )
    }

    var requestHeaders: [String: String] {
        var requestHeaders = headers
        if method == .post || method == .put || method == .delete,
           let body,
           requestHeaders["Content-Type"] == nil {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCharset = charset.isEmpty ? "UTF-8" : charset
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                requestHeaders["Content-Type"] = "application/json; charset=\(normalizedCharset)"
            } else {
                requestHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=\(normalizedCharset)"
            }
        }
        return requestHeaders
    }

    var requestBodyData: Data? {
        guard let body else { return nil }
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

    // MARK: - Public Shared Helpers

    static func postProcessExtractedURL(
        _ rawValue: String,
        baseUrl: String,
        variableStore: ParserVariableStore? = nil
    ) -> String {
        postProcessExtractedURLs(rawValue, baseUrl: baseUrl, variableStore: variableStore).first ?? ""
    }

    static func postProcessExtractedURLs(
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

    static func parseHeaderJSONPublic(_ text: String) -> [String: String]? {
        parseHeaderJSON(text)
    }

    static func normalizeCharsetName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if let match = sanitized.range(of: #"^[A-Za-z0-9._-]+"#, options: .regularExpression) {
            return String(sanitized[match])
        }
        return sanitized
    }

    // MARK: - Analyze Flow

    private static func replaceGetVariablesIfNeeded(_ rule: String, variableStore: ParserVariableStore?) -> String {
        guard rule.contains("@get:"), let variableStore else { return rule }
        return RuleAnalyzer.substituteGetVariables(rule, variableStore: variableStore)
    }

    private static func consumeMethodPrefix(_ rule: String) -> (String, HTTPMethod) {
        var processedRule = rule
        var method: HTTPMethod = .get

        if processedRule.uppercased().hasPrefix("POST:") {
            method = .post
            processedRule = String(processedRule.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if processedRule.uppercased().hasPrefix("GET:") {
            processedRule = String(processedRule.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else if processedRule.uppercased().hasPrefix("PUT:") {
            method = .put
            processedRule = String(processedRule.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else if processedRule.uppercased().hasPrefix("DELETE:") {
            method = .delete
            processedRule = String(processedRule.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        return (processedRule, method)
    }

    private static func splitRuleAndOption(from rule: String) -> (urlPart: String, optionPart: String?) {
        if let commaIdx = findOptionSeparator(in: rule) {
            return (
                String(rule[..<commaIdx]).trimmingCharacters(in: .whitespaces),
                String(rule[rule.index(after: commaIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (rule.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    private static func parseOptions(
        _ optionPart: String?,
        key: String,
        page: Int,
        headerString: String?
    ) -> ParsedOptions {
        var parsed = ParsedOptions()

        if let headerString, let headerJSON = parseHeaderJSON(headerString) {
            parsed.headers = headerJSON
        }

        guard let optionPart else {
            parsed.charset = normalizeCharsetName(parsed.charset)
            return parsed
        }

        let trimmedOption = optionPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedOption = trimmedOption.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOption: String
        if trimmedOption.hasPrefix("{") {
            normalizedOption = trimmedOption
        } else if decodedOption?.hasPrefix("{") == true {
            normalizedOption = decodedOption!
        } else {
            normalizedOption = trimmedOption
        }

        let normalizedJSONLikeOption = normalizeJSONLikeOptionText(normalizedOption)
        if normalizedOption.hasPrefix("{"),
           let optionJSON = (
                LenientJSONParserV2.parse(normalizedJSONLikeOption) as? [String: Any]
                ?? parseTemplateOptionObject(from: normalizedOption)
           ) {
            if let methodString = optionJSON["method"] as? String {
                switch methodString.uppercased() {
                case "POST":
                    parsed.method = .post
                    parsed.appliedOptions.append("method")
                case "PUT":
                    parsed.method = .put
                    parsed.appliedOptions.append("method")
                case "DELETE":
                    parsed.method = .delete
                    parsed.appliedOptions.append("method")
                case "HEAD":
                    parsed.method = .head
                    parsed.appliedOptions.append("method")
                default:
                    break
                }
            }

            if let headerMap = optionJSON["headers"] as? [String: Any] {
                for (key, value) in headerMap {
                    parsed.headers[key] = "\(value)"
                }
                parsed.appliedOptions.append("headers")
            } else if let headerString = optionJSON["headers"] as? String,
                      let headerMap = parseHeaderJSON(headerString) {
                for (key, value) in headerMap {
                    parsed.headers[key] = value
                }
                parsed.appliedOptions.append("headers")
            }

            // 兼容部分书源把字段写成 header。
            if let headerMap = optionJSON["header"] as? [String: Any] {
                for (key, value) in headerMap {
                    parsed.headers[key] = "\(value)"
                }
                parsed.appliedOptions.append("header")
            } else if let headerString = optionJSON["header"] as? String,
                      let headerMap = parseHeaderJSON(headerString) {
                for (key, value) in headerMap {
                    parsed.headers[key] = value
                }
                parsed.appliedOptions.append("header")
            }

            if let bodyValue = optionJSON["body"] {
                parsed.body = stringifyBodyValue(bodyValue, key: key, page: page)
                parsed.appliedOptions.append("body")
            }
            if let charset = optionJSON["charset"] as? String {
                parsed.charset = normalizeCharsetName(charset)
                parsed.appliedOptions.append("charset")
            }
            if let responseType = optionJSON["type"] as? String,
               !responseType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed.responseType = responseType
                parsed.appliedOptions.append("type")
            }
            if let retry = optionJSON["retry"] as? NSNumber {
                parsed.retryCount = max(0, retry.intValue)
                parsed.appliedOptions.append("retry")
            } else if let retry = optionJSON["retry"] as? String,
                      let retryCount = Int(retry) {
                parsed.retryCount = max(0, retryCount)
                parsed.appliedOptions.append("retry")
            }
            if let useWebView = parseBooleanOption(optionJSON["webView"]) {
                parsed.webView = useWebView
                parsed.appliedOptions.append("webView")
            }
            if let webJs = optionJSON["webJs"] as? String,
               !webJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed.webJs = webJs
                parsed.appliedOptions.append("webJs")
            }
            if let sourceRegex = optionJSON["sourceRegex"] as? String,
               !sourceRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed.sourceRegex = sourceRegex
                parsed.appliedOptions.append("sourceRegex")
            }
            if let javaScriptURL = optionJSON["js"] as? String,
               !javaScriptURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed.javaScriptURLOverride = javaScriptURL
                parsed.appliedOptions.append("js")
            }
            if let delay = optionJSON["webViewDelayTime"] as? NSNumber {
                parsed.webViewDelayTime = max(0, delay.intValue)
                parsed.appliedOptions.append("webViewDelayTime")
            } else if let delay = optionJSON["webViewDelayTime"] as? String,
                      let delayValue = Int(delay) {
                parsed.webViewDelayTime = max(0, delayValue)
                parsed.appliedOptions.append("webViewDelayTime")
            }
            if parsed.body == nil,
               let fallbackBody = extractBodyJSONString(from: normalizedOption, key: key, page: page) {
                parsed.body = fallbackBody
                parsed.appliedOptions.append("body")
            }
        } else {
            parsed.body = normalizedOption
                .replacingKeyPlaceholders(key: key, encodeKey: false)
                .replacingOccurrences(of: "{{page}}", with: "\(page)")
                .replacingOccurrences(of: "{page}", with: "\(page)")
            if !normalizedOption.isEmpty {
                parsed.method = .post
                parsed.appliedOptions.append("body")
            }
        }

        parsed.charset = normalizeCharsetName(parsed.charset)
        return parsed
    }

    private static func evaluateOptionJavaScriptURLOverride(
        _ script: String,
        currentURL: String,
        key: String,
        page: Int,
        baseUrl: String,
        source: BookSource?,
        variableStore: ParserVariableStore?
    ) -> String? {
        let parser = JavaScriptParser(
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
            var url = '\(currentURL.replacingOccurrences(of: "'", with: "\\'"))';
        """
        return try? parser.evaluate(script: setupScript + "\n" + script, result: currentURL)
    }

    // MARK: - Shared Helpers Ported From Legacy AnalyzeUrl

    private static func replaceKeyPlaceholders(
        in text: String,
        key: String,
        encodeKey: Bool,
        rawOnly: Bool = false
    ) -> String {
        text.replacingKeyPlaceholders(key: key, encodeKey: encodeKey, rawOnly: rawOnly)
    }

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
        if isPureJavaScriptURLRule(trimmed) {
            if let resolvedPureRule = resolvePureJavaScriptURLRule(
                trimmed,
                key: key,
                page: page,
                baseUrl: baseUrl,
                source: source,
                variableStore: variableStore
            ) {
                return resolvedPureRule
            }
            return unresolvedPureJavaScriptURLRulePlaceholder(for: trimmed)
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
                    "AnalyzeUrlV2",
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

        do {
            let evaluation = try jsParser.evaluateWithContext(script: setupScript + "\n" + jsBody, result: rule)
            let trimmedPrimary = normalizedPureJavaScriptURLRuleResult(evaluation.primary)
            let trimmedResult = normalizedPureJavaScriptURLRuleResult(evaluation.result)
            let inferredURLValue = normalizedPureJavaScriptURLRuleResult(evaluation.url)
            let trimmedEvaluated = [trimmedPrimary, trimmedResult, inferredURLValue]
                .compactMap { $0 }
                .first {
                    isMeaningfulPureJavaScriptURLRuleResult(
                        $0,
                        originalRule: rule,
                        baseUrl: baseUrl,
                        source: source
                    )
                }
                ?? ""
            if !trimmedEvaluated.isEmpty {
                return trimmedEvaluated
            }
        } catch {
            ParserLog.debug(
                "AnalyzeUrlV2",
                "pure JS URL rule failed source=\(source?.bookSourceName ?? "") baseUrl=\(baseUrl) rule=\(ParserLog.preview(rule, limit: 240)) error=\(error.localizedDescription)"
            )
        }

        if let recovered = recoverLiteralURLRuleWrappedInJavaScript(jsBody) {
            return recovered
        }
        return nil
    }

    /// Android `AnalyzeUrl.evalJS` 在纯 `@js:` URL 规则失败时，不会把初始化上下文 `url`
    /// 再次喂回普通嵌入式 JS 替换链；否则 iOS 会把 `source.key` / `baseUrl` 误当成成功 URL。
    ///
    /// 这里显式返回一个不可误判为主页请求成功的占位 URL 规则，
    /// 让后续 runtime trace 仍能看出这是“纯 JS 未产出有效 URL”的失败场景，
    /// 同时避免搜索 silently degrade 成首页 GET。
    private static func unresolvedPureJavaScriptURLRulePlaceholder(for rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return "@js:"
        }
        if trimmed.hasPrefix("<js>"), trimmed.hasSuffix("</js>") {
            return "<js></js>"
        }
        return trimmed
    }

    /// Android `AnalyzeUrl.evalJS` 对齐：
    /// 纯 `@js:` URL 规则只有在脚本真正产出了“与上下文不同的目标 URL / URL 规则”时，
    /// 才能把该结果当作成功解析。
    ///
    /// 这一步专门拦截 iOS JSContext 常见的“脚本求值失败，但 `url` 变量仍保留初始化值”的场景。
    /// 若这里把默认上下文 `url` / `baseUrl` / `source.key` 误当成功结果，就会把
    /// 纯 JS 搜索规则静默退化成主页 GET，请求虽然发出，却永远无法进入真正的搜索链。
    private static func isMeaningfulPureJavaScriptURLRuleResult(
        _ candidate: String,
        originalRule: String,
        baseUrl: String,
        source: BookSource?
    ) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != originalRule else { return false }

        let normalizedCandidate = normalizedPureJavaScriptRuntimeURL(trimmed)
        let contextDefaults = [
            baseUrl,
            source?.bookSourceUrl ?? ""
        ]
            .map { normalizedPureJavaScriptRuntimeURL($0) }
            .filter { !$0.isEmpty }

        if contextDefaults.contains(normalizedCandidate) {
            return false
        }

        return true
    }

    private static func normalizedPureJavaScriptRuntimeURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           let host = components.host?.lowercased() {
            let port = components.port.map { ":\($0)" } ?? ""
            let path = components.path.isEmpty ? "/" : components.path
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)\(path)\(query)\(fragment)"
        }

        return trimmed
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
            return array.compactMap { normalizedPureJavaScriptURLRuleResult($0) }.joined(separator: "\n")
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

            let trimExpr = expr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimExpr == "key" {
                let adjustedRange = NSRange(location: fullRange.location + offset, length: fullRange.length)
                if let swiftRange = Range(adjustedRange, in: result) {
                    result.replaceSubrange(swiftRange, with: key)
                    offset += key.count - fullRange.length
                }
                continue
            }
            if trimExpr == "page" {
                let replacement = "\(page)"
                let adjustedRange = NSRange(location: fullRange.location + offset, length: fullRange.length)
                if let swiftRange = Range(adjustedRange, in: result) {
                    result.replaceSubrange(swiftRange, with: replacement)
                    offset += replacement.count - fullRange.length
                }
                continue
            }

            let evalExpr = trimExpr.hasPrefix("@@") ? String(trimExpr.dropFirst(2)) : trimExpr
            let jsResult = (try? jsParser.evaluate(script: setup + "\n" + evalExpr)) ?? ""
            let replacement = jsResult == "undefined" ? "" : jsResult

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

        result = result
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{page}", with: "\(page)")
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

    private static func resolveURLPart(
        _ urlPart: String,
        key: String,
        baseUrl: String,
        method: HTTPMethod,
        charset: String
    ) -> String {
        let replacedURL = replaceURLKeyPlaceholders(in: urlPart, key: key)
        var resolvedURL = makeAbsoluteURL(from: replacedURL, baseUrl: baseUrl)
        // Android `AnalyzeUrl` 不会因为请求方法是 POST / PUT 就跳过 URL 自身的 query 编码。
        // 许多书源会同时依赖“URL 上带 query + body 里再带 form 参数”，这里始终对 URL query 做收口，
        // 才能保证 JS 拼出的已编码参数保留、未编码参数补齐。
        _ = method
        resolvedURL = encodeQueryIfNeeded(in: resolvedURL, charset: charset)
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
        guard let base = URL(string: baseUrl) else {
            return urlPart
        }
        let split = splitURLIntoPathQueryAndFragment(urlPart)
        guard let resolvedPathURL = URL(string: split.path, relativeTo: base) else {
            return urlPart
        }

        var resolved = resolvedPathURL.absoluteString
        if let query = split.query, !query.isEmpty {
            resolved += "?\(query)"
        }
        if let fragment = split.fragment, !fragment.isEmpty {
            resolved += "#\(fragment)"
        }
        return resolved
    }

    /// `Foundation.URL(relativeTo:)` 会重新解释 query，导致已经编码好的 `%xx`
    /// 在 Android 风格 URL runtime 收口时再次变成 `%25xx`。
    ///
    /// 这里先单独解析路径，再把 query / fragment 原样拼回，
    /// 让 JS 已产出的 percent-encoded 参数能够完整保留。
    private static func splitURLIntoPathQueryAndFragment(_ value: String) -> (path: String, query: String?, fragment: String?) {
        var working = value
        var fragment: String?
        if let fragmentSeparator = working.firstIndex(of: "#") {
            fragment = String(working[working.index(after: fragmentSeparator)...])
            working = String(working[..<fragmentSeparator])
        }

        var query: String?
        if let querySeparator = working.firstIndex(of: "?") {
            query = String(working[working.index(after: querySeparator)...])
            working = String(working[..<querySeparator])
        }

        return (working, query, fragment)
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
        let segments = trimmed.split(separator: "&", omittingEmptySubsequences: false)
        return segments.map { segment in
            guard let separatorIndex = segment.firstIndex(of: "=") else {
                return encodeParameterComponent(
                    String(segment),
                    allowReservedCharacters: false,
                    charset: charset,
                    spaceAsPlus: false
                )
            }

            let key = String(segment[..<separatorIndex])
            let value = String(segment[segment.index(after: separatorIndex)...])
            let encodedKey = encodeParameterComponent(
                key,
                allowReservedCharacters: false,
                charset: charset,
                spaceAsPlus: false
            )
            let encodedValue = encodeParameterComponent(
                value,
                allowReservedCharacters: false,
                charset: charset,
                spaceAsPlus: false
            )
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
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

        let stringEncoding = formEncoding(for: charset) ?? .utf8
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]

            if character == "%" {
                let first = value.index(after: index)
                if first < value.endIndex {
                    let second = value.index(after: first)
                    if second < value.endIndex,
                       value[first].isHexDigit,
                       value[second].isHexDigit {
                        result.append(character)
                        result.append(value[first])
                        result.append(value[second])
                        index = value.index(after: second)
                        continue
                    }
                }
            }

            for scalar in String(character).unicodeScalars {
                if scalar == " " {
                    result.append(spaceAsPlus ? "+" : "%20")
                    continue
                }
                if isAllowedParameterScalar(scalar, allowReservedCharacters: allowReservedCharacters) {
                    result.append(String(scalar))
                    continue
                }

                guard let data = String(scalar).data(using: stringEncoding) else {
                    result.append(String(scalar))
                    continue
                }
                result.append(data.map { String(format: "%%%02X", $0) }.joined())
            }

            index = value.index(after: index)
        }

        return result
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

    private static func findTopLevelComma(in string: String) -> String.Index? {
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
                if character == "\\" { skipNext = true }
                else if character == "\"" { inDoubleQuote = false }
                continue
            }
            if inSingleQuote {
                if character == "\\" { skipNext = true }
                else if character == "'" { inSingleQuote = false }
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
                return idx
            default:
                break
            }
        }
        return nil
    }

    private static func findOptionSeparator(in string: String) -> String.Index? {
        let commaCandidates = [findTopLevelOptionComma(in: string), findTopLevelComma(in: string)].compactMap { $0 }

        for commaIdx in commaCandidates.sorted(by: {
            string.distance(from: string.startIndex, to: $0) < string.distance(from: string.startIndex, to: $1)
        }) {
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
            if !urls.isEmpty, urls.count > 1 || urls[0] != normalizedURLCandidate(normalized) {
                return urls
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
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

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

        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") {
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

    private static func unwrapURLPayloadsIfNeeded(_ value: String) -> [String]? {
        guard value.first == "{" || value.first == "[" || value.first == "\"" else {
            return nil
        }
        guard let object = LenientJSONParserV2.parse(value) else {
            return nil
        }
        let urls = extractURLStrings(from: object)
        return urls.isEmpty ? nil : urls
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
        guard !matches.isEmpty else { return input }

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
               let bodyValue = LenientJSONParserV2.parse(String(quoted[bodyRange])) {
                parsed["body"] = bodyValue
            } else if let bodyValue = parseScalarOptionValue(in: quoted, after: bodyKeyRange.upperBound) {
                parsed["body"] = bodyValue
            }
        }

        if let headersKeyRange = quoted.range(of: "\"headers\"") {
            if let headersRange = parseObjectOptionValueRange(in: quoted, after: headersKeyRange.upperBound),
               let headersValue = LenientJSONParserV2.parse(String(quoted[headersRange])) {
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
              let bodyValue = LenientJSONParserV2.parse(String(quoted[bodyRange])) else {
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
            if let dictionary = LenientJSONParserV2.parse(objectText) as? [String: Any] {
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

    private static func parseHeaderJSON(_ string: String) -> [String: String]? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parseHeaderJSONObject(_ string: String) -> [String: String]? {
        guard let json = LenientJSONParserV2.parse(string) else { return nil }
        if let dict = json as? [String: String] { return dict }
        if let dict = json as? [String: Any] {
            var result: [String: String] = [:]
            for (key, value) in dict {
                result[key] = value as? String ?? "\(value)"
            }
            return result
        }
        return nil
    }

    private static func parseHeaderPairs(_ string: String) -> [String: String]? {
        // Android book sources often use a lenient header literal like
        // `{ auth-code:xxx,app:com.foo,platform:android }` instead of strict JSON.
        // Treat commas as pair separators only after strict/lenient JSON parsing has
        // failed, so quoted JSON header values keep their normal JSON semantics above.
        let body = trimHeaderPairContainer(string)
        let separators = CharacterSet(charactersIn: "\n&,")
        let segments = body.components(separatedBy: separators).map {
            trimHeaderPairToken($0)
        }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        var headers: [String: String] = [:]
        for segment in segments {
            let pair: [String]
            if segment.contains(":") {
                pair = segment.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            } else if segment.contains("=") {
                pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            } else {
                continue
            }
            guard pair.count == 2 else { continue }
            let key = trimHeaderPairToken(pair[0])
            let value = trimHeaderPairToken(pair[1])
            guard !key.isEmpty else { continue }
            headers[key] = value
        }
        return headers.isEmpty ? nil : headers
    }

    private static func trimHeaderPairContainer(_ string: String) -> String {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimHeaderPairToken(_ string: String) -> String {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        } else if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bodyPreview(_ body: Data?, charset: String, limit: Int = 160) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let decoded = HTTPClient.decodeTextData(body, preferredCharset: charset) ?? body.base64EncodedString()
        let compact = decoded
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }

    private static func bodyHash(_ body: Data?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in body {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func transportPreferenceName(_ preference: HTTPRequest.TransportPreference) -> String {
        switch preference {
        case .automatic:
            return "automatic"
        case .preferThirdParty:
            return "preferThirdParty"
        }
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

        guard !rawOnly else { return result }

        result = result
            .replacingOccurrences(of: "{{key}}", with: replacement)
            .replacingOccurrences(of: "{key}", with: replacement)
        return result
    }
}
