import Foundation

// MARK: - RequestExecutorV2

/// V2 请求执行层。
///
/// H3 的核心目标，是把 Android `AnalyzeUrl -> WebBook` 请求执行语义真正收口到这一层：
/// - descriptor / request 只作为输入
/// - HTTP transport、WebView transport、retry、cookie 环境、redirect 结果、response normalize 统一在这里处理
/// - 上层 `WebBookV2` 只做“阶段编排”，不再散点拼装底层请求逻辑
///
/// 当前实现仍复用旧 `HTTPClient` 与 `HeadlessWebView` 的成熟 transport，
/// 但它们现在被包在清晰的 executor 边界之内，后续再继续替换也不会把复杂度弹回上层。
nonisolated final class RequestExecutorV2 {
    typealias HTTPSendClosure = @Sendable (HTTPRequest, HTTPClient) async throws -> HTTPResponse
    typealias WebViewSendClosure = @Sendable (AnalyzeUrlV2, HTTPRequest, HTTPClient) async throws -> HTTPResponse

    private let httpClient: HTTPClient
    private let cookieJarEnabled: Bool
    private let httpSender: HTTPSendClosure?
    private let webViewSender: WebViewSendClosure?

    init(
        httpClient: HTTPClient = .shared,
        cookieJarEnabled: Bool = true,
        httpSender: HTTPSendClosure? = nil,
        webViewSender: WebViewSendClosure? = nil
    ) {
        self.httpClient = httpClient
        self.cookieJarEnabled = cookieJarEnabled
        self.httpSender = httpSender
        self.webViewSender = webViewSender
    }

    // executor 只封装 transport 闭包与配置，不需要特定 actor 参与释放。
    // 显式 nonisolated，避免测试里批量构造/销毁 executor 时回落到并发运行时析构路径。
    nonisolated deinit {}

    func shutdown() {
        httpClient.shutdown()
    }

    func makeRequest(
        from analyzeUrlRuntime: AnalyzeUrlV2,
        timeout: TimeInterval,
        transportPreference: HTTPRequest.TransportPreference = .automatic,
        followRedirects: Bool = true
    ) -> HTTPRequest {
        analyzeUrlRuntime.makeRequest(
            timeout: timeout,
            transportPreference: transportPreference,
            enableCookieJar: cookieJarEnabled,
            followRedirects: followRedirects
        )
    }

    func makeDescriptor(
        from analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        transportPreference: HTTPRequest.TransportPreference,
        sourceHeaderKeys: [String],
        followRedirects: Bool = true
    ) -> LegadoRequestDescriptorV2 {
        var descriptor = analyzeUrlRuntime.makeDescriptor(
            request: request,
            transportPreference: transportPreference,
            cookieJarEnabled: cookieJarEnabled,
            followRedirects: followRedirects
        )
        descriptor.sourceHeaderKeys = sourceHeaderKeys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return descriptor
    }

    /// 执行一次解析请求，并返回响应与更新后的运行时上下文。
    ///
    /// Swift 并发下不能把 actor-isolated 状态以 `inout` 形式跨 `await` 传递，
    /// 因此 V2 executor 显式产出新的 `LegadoRequestContextV2`，由上层编排器决定是否接纳。
    func execute(
        analyzeUrlRuntime: AnalyzeUrlV2,
        context: LegadoRequestContextV2,
        transportPreference: HTTPRequest.TransportPreference = .automatic,
        webJs: String? = nil,
        sourceRegex: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> (responseContext: LegadoResponseContextV2, updatedContext: LegadoRequestContextV2) {
        var updatedContext = context
        let effectiveTimeout = min(timeout ?? updatedContext.maximumRequestTimeout, updatedContext.maximumRequestTimeout)
        let sourceHeaders = updatedContext.resolvedSourceHeaders()
        let request = makePreparedRequest(
            from: analyzeUrlRuntime,
            sourceHeaders: sourceHeaders,
            timeout: effectiveTimeout,
            transportPreference: transportPreference
        )
        let descriptor = makeDescriptor(
            from: analyzeUrlRuntime,
            request: request,
            transportPreference: transportPreference,
            sourceHeaderKeys: Array(sourceHeaders.keys)
        )
        updatedContext.runtimeTrace?.record(descriptor)

        let effectiveAnalyzeUrlRuntime = mergedWebViewOptions(
            base: analyzeUrlRuntime,
            webJsFallback: webJs,
            sourceRegexFallback: sourceRegex
        )
        let client = makeConfiguredHTTPClient(using: updatedContext, sourceHeaders: sourceHeaders)
        let transportResult = try await executeTransport(
            analyzeUrlRuntime: effectiveAnalyzeUrlRuntime,
            request: request,
            descriptor: descriptor,
            context: updatedContext,
            client: client
        )
        updatedContext.learnRuntimeSource(from: transportResult.response.url)
        let responseURL = transportResult.response.url?.absoluteString ?? request.url

        let responseContext = LegadoResponseContextV2(
            response: transportResult.response,
            descriptor: descriptor,
            requestUrl: request.url,
            responseUrl: responseURL,
            baseUrl: responseURL,
            transportKind: transportResult.transportKind,
            attemptCount: transportResult.attemptCount
        )
        updatedContext.runtimeTrace?.recordResponse(responseContext.traceSummary, for: descriptor)
        return (responseContext: responseContext, updatedContext: updatedContext)
    }

    /// 业务 fallback 仍然保留在 executor 边界，而不是散回 `WebBookV2`。
    ///
    /// H2 的目标是把“URL 规则解释”统一收口到 `AnalyzeUrlV2`，不是提前删掉
    /// 旧主链路已经存在的 `ruleContent.webJs / sourceRegex` 兜底能力。
    private func mergedWebViewOptions(
        base: AnalyzeUrlV2,
        webJsFallback: String?,
        sourceRegexFallback: String?
    ) -> AnalyzeUrlV2 {
        let effectiveWebJs = base.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? base.webJs
            : webJsFallback
        let effectiveSourceRegex = base.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? base.sourceRegex
            : sourceRegexFallback
        return base.withWebViewOverrides(webJs: effectiveWebJs, sourceRegex: effectiveSourceRegex)
    }

    private func makePreparedRequest(
        from analyzeUrlRuntime: AnalyzeUrlV2,
        sourceHeaders: [String: String],
        timeout: TimeInterval,
        transportPreference: HTTPRequest.TransportPreference
    ) -> HTTPRequest {
        var request = makeRequest(
            from: analyzeUrlRuntime,
            timeout: timeout,
            transportPreference: transportPreference
        )
        if !sourceHeaders.isEmpty {
            request.headers = sourceHeaders.merging(request.headers) { _, requestValue in requestValue }
        }
        return request
    }

    private func makeConfiguredHTTPClient(
        using context: LegadoRequestContextV2,
        sourceHeaders: [String: String]
    ) -> HTTPClient {
        let client = httpClient
        client.defaultHeaders = sourceHeaders
        context.restoreCookieJarIfNeeded(into: client)
        return client
    }

    private func executeTransport(
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        descriptor: LegadoRequestDescriptorV2,
        context: LegadoRequestContextV2,
        client: HTTPClient
    ) async throws -> (response: HTTPResponse, transportKind: LegadoResponseContextV2.TransportKind, attemptCount: Int) {
        if analyzeUrlRuntime.webView && !context.allowsWebViewRequests {
            throw ParserError.networkError("WebView request skipped in batch compare: \(analyzeUrlRuntime.urlString)")
        }

        let requestStartedAt = Date()
        var attemptedTransportWebViewRecovery = false
        let maxAttempt = max(0, analyzeUrlRuntime.retryCount)

        for attempt in 0...maxAttempt {
            do {
                let result = try await performPrimaryTransport(
                    analyzeUrlRuntime: analyzeUrlRuntime,
                    request: request,
                    descriptor: descriptor,
                    context: context,
                    client: client,
                    requestStartedAt: requestStartedAt
                )
                return (result.response, result.transportKind, attempt + 1)
            } catch {
                if !attemptedTransportWebViewRecovery,
                   shouldAttemptTransportWebViewRecovery(
                    error: error,
                    analyzeUrlRuntime: analyzeUrlRuntime,
                    request: request,
                    context: context
                   ) {
                    attemptedTransportWebViewRecovery = true
                    do {
                        ParserLog.debug(
                            "RequestExecutorV2",
                            "transport webview recovery url=\(analyzeUrlRuntime.urlString) error=\(error.localizedDescription)"
                        )
                        let recovered = try await recoverResponseWithWebViewAfterTransportFailure(
                            analyzeUrlRuntime: analyzeUrlRuntime,
                            request: request,
                            startedAt: requestStartedAt
                        )
                        return (normalizedResponseIfNeeded(recovered, descriptor: descriptor), .webViewRecoveredURL, attempt + 1)
                    } catch {
                        ParserLog.debug(
                            "RequestExecutorV2",
                            "transport webview recovery failed url=\(analyzeUrlRuntime.urlString) error=\(error.localizedDescription)"
                        )
                    }
                }

                if attempt == maxAttempt {
                    throw error
                }
                ParserLog.debug(
                    "RequestExecutorV2",
                    "retry request attempt=\(attempt + 1) url=\(analyzeUrlRuntime.urlString)"
                )
            }
        }

        throw ParserError.networkError("请求失败: \(analyzeUrlRuntime.urlString)")
    }

    private func performPrimaryTransport(
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        descriptor: LegadoRequestDescriptorV2,
        context: LegadoRequestContextV2,
        client: HTTPClient,
        requestStartedAt: Date
    ) async throws -> (response: HTTPResponse, transportKind: LegadoResponseContextV2.TransportKind) {
        if analyzeUrlRuntime.webView {
            let response = try await sendWebViewRequest(
                analyzeUrlRuntime: analyzeUrlRuntime,
                request: request,
                client: client
            )
            return (normalizedResponseIfNeeded(response, descriptor: descriptor), .webView)
        }

        let response = try await sendHTTPRequest(request, client: client)
        if let recoveryMode = automaticWebViewRecoveryMode(
            response: response,
            analyzeUrlRuntime: analyzeUrlRuntime,
            context: context
        ) {
            ParserLog.debug(
                "RequestExecutorV2",
                "auto webview recovery status=\(response.statusCode) url=\(response.url?.absoluteString ?? analyzeUrlRuntime.urlString)"
            )
            switch recoveryMode {
            case .renderHTML:
                let recovered = try await recoverResponseWithWebView(
                    response,
                    analyzeUrlRuntime: analyzeUrlRuntime,
                    request: request,
                    startedAt: requestStartedAt
                )
                return (normalizedResponseIfNeeded(recovered, descriptor: descriptor), .webViewRecoveredHTML)
            case .reloadURL:
                let recovered = try await recoverResponseWithWebViewAfterTransportFailure(
                    analyzeUrlRuntime: analyzeUrlRuntime,
                    request: request,
                    startedAt: requestStartedAt
                )
                return (normalizedResponseIfNeeded(recovered, descriptor: descriptor), .webViewRecoveredURL)
            }
        }
        return (normalizedResponseIfNeeded(response, descriptor: descriptor), .http)
    }

    /// Executes HTTP transport through either a test-injected sender or the concrete client.
    ///
    /// Keeping the production path as a normal method call avoids storing a default async
    /// closure that captures `HTTPClient`; that closure is crossed by Swift concurrency often
    /// in parser tests and has proven fragile on simulator runtimes.
    private func sendHTTPRequest(_ request: HTTPRequest, client: HTTPClient) async throws -> HTTPResponse {
        if let httpSender {
            return try await httpSender(request, client)
        }
        return try await client.send(request: request)
    }

    /// Executes WebView transport through either a test-injected sender or the default renderer.
    private func sendWebViewRequest(
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        client: HTTPClient
    ) async throws -> HTTPResponse {
        if let webViewSender {
            return try await webViewSender(analyzeUrlRuntime, request, client)
        }
        return try await Self.defaultSendWebViewRequest(
            analyzeUrlRuntime: analyzeUrlRuntime,
            request: request,
            httpClient: client
        )
    }

    private func automaticWebViewRecoveryMode(
        response: HTTPResponse,
        analyzeUrlRuntime: AnalyzeUrlV2,
        context: LegadoRequestContextV2
    ) -> BrowserRecoveryHeuristics.RecoveryMode? {
        guard context.allowsAutomaticWebViewRecovery,
              context.allowsWebViewRequests,
              !analyzeUrlRuntime.webView,
              let body = response.text?.lowercased(),
              !body.isEmpty else {
            return nil
        }

        return BrowserRecoveryHeuristics.recoveryMode(
            statusCode: response.statusCode,
            server: response.headerValue(for: "Server") ?? "",
            mitigationHeader: response.headerValue(for: "cf-mitigated") ?? "",
            body: body
        )
    }

    private func shouldAttemptTransportWebViewRecovery(
        error: Error,
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        context: LegadoRequestContextV2
    ) -> Bool {
        guard context.allowsWebViewRequests, !analyzeUrlRuntime.webView else {
            return false
        }
        guard analyzeUrlRuntime.method == .get else {
            return false
        }
        guard request.body == nil || request.body?.isEmpty == true else {
            return false
        }
        return Self.isRecoverableBrowserTransportError(error)
    }

    private func recoverResponseWithWebView(
        _ response: HTTPResponse,
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        startedAt: Date
    ) async throws -> HTTPResponse {
        let elapsed = Date().timeIntervalSince(startedAt)
        let remainingMilliseconds = Int(max(500, (request.timeout - elapsed) * 1000))
        let renderer = await MainActor.run { HeadlessWebView.shared }
        let html = response.text ?? ""
        let baseURL = response.url?.absoluteString ?? analyzeUrlRuntime.urlString
        let rendered = try await Self.renderWithWebView(
            renderer: renderer,
            html: html,
            url: baseURL,
            headers: request.headers,
            webJs: analyzeUrlRuntime.webJs,
            sourceRegex: analyzeUrlRuntime.sourceRegex,
            delayMs: analyzeUrlRuntime.webViewDelayTime,
            timeoutMs: remainingMilliseconds
        )
        let finalURL = await renderer.lastLoadedURL ?? response.url ?? URL(string: baseURL)
        return HTTPResponse(
            data: Data(rendered.utf8),
            statusCode: 200,
            headers: response.headers,
            url: finalURL,
            requestURL: response.requestURL,
            message: response.message,
            headerValues: response.headerValues
        )
    }

    private func recoverResponseWithWebViewAfterTransportFailure(
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        startedAt: Date
    ) async throws -> HTTPResponse {
        let remainingMilliseconds = Int(max(1_000, (request.timeout - Date().timeIntervalSince(startedAt)) * 1000))
        let renderer = await MainActor.run { HeadlessWebView.shared }
        let rendered = try await Self.renderWithWebView(
            renderer: renderer,
            html: nil,
            url: analyzeUrlRuntime.urlString,
            headers: request.headers,
            webJs: analyzeUrlRuntime.webJs,
            sourceRegex: analyzeUrlRuntime.sourceRegex,
            delayMs: analyzeUrlRuntime.webViewDelayTime,
            timeoutMs: remainingMilliseconds
        )
        let finalURL = await renderer.lastLoadedURL ?? URL(string: analyzeUrlRuntime.urlString)
        return HTTPResponse(
            data: Data(rendered.utf8),
            statusCode: 200,
            headers: [:],
            url: finalURL,
            requestURL: URL(string: analyzeUrlRuntime.urlString),
            message: "OK"
        )
    }

    private func normalizedResponseIfNeeded(
        _ response: HTTPResponse,
        descriptor: LegadoRequestDescriptorV2
    ) -> HTTPResponse {
        guard descriptor.responseType?.caseInsensitiveCompare("hex") == .orderedSame else {
            return response
        }
        return Self.hexEncodedResponse(from: response)
    }

    private nonisolated static func hexEncodedResponse(from response: HTTPResponse) -> HTTPResponse {
        let hexBody = response.data.map { String(format: "%02x", $0) }.joined()
        return HTTPResponse(
            data: response.data,
            statusCode: response.statusCode,
            headers: response.headers,
            url: response.url,
            requestURL: response.requestURL,
            message: response.message,
            headerValues: response.headerValues,
            textOverride: hexBody
        )
    }

    private nonisolated static func isRecoverableBrowserTransportError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        let markers = [
            "[nsurlerrordomain:-1200]",
            "[nsurlerrordomain:-1005]",
            "[nsurlerrordomain:-1007]",
            "[nsurlerrordomain:-1001]",
            "tls error",
            "secure connection",
            "ssl",
            "handshake",
            "connection reset by peer",
            "network connection was lost",
            "too many redirects",
            "redirect loop",
            "protocol error",
            "empty reply"
        ]
        return markers.contains { description.contains($0) }
    }

    private static func defaultSendWebViewRequest(
        analyzeUrlRuntime: AnalyzeUrlV2,
        request: HTTPRequest,
        httpClient: HTTPClient
    ) async throws -> HTTPResponse {
        let renderer = await MainActor.run { HeadlessWebView.shared }

        if analyzeUrlRuntime.method == .post || analyzeUrlRuntime.method == .put || analyzeUrlRuntime.method == .delete {
            let preloadResponse = try await httpClient.send(request: request)
            guard let html = preloadResponse.text else {
                throw ParserError.parsingFailed("无法解析 WebView 预加载响应")
            }

            let baseURL = preloadResponse.url?.absoluteString ?? analyzeUrlRuntime.urlString
            let rendered = try await Self.renderWithWebView(
                renderer: renderer,
                html: html,
                url: baseURL,
                headers: request.headers,
                webJs: analyzeUrlRuntime.webJs,
                sourceRegex: analyzeUrlRuntime.sourceRegex,
                delayMs: analyzeUrlRuntime.webViewDelayTime,
                timeoutMs: 30_000
            )
            let finalURL = await renderer.lastLoadedURL ?? preloadResponse.url ?? URL(string: analyzeUrlRuntime.urlString)
            return HTTPResponse(
                data: Data(rendered.utf8),
                statusCode: preloadResponse.statusCode,
                headers: preloadResponse.headers,
                url: finalURL
            )
        }

        let rendered = try await Self.renderWithWebView(
            renderer: renderer,
            html: nil,
            url: analyzeUrlRuntime.urlString,
            headers: request.headers,
            webJs: analyzeUrlRuntime.webJs,
            sourceRegex: analyzeUrlRuntime.sourceRegex,
            delayMs: analyzeUrlRuntime.webViewDelayTime,
            timeoutMs: 30_000
        )
        let finalURL = await renderer.lastLoadedURL ?? URL(string: analyzeUrlRuntime.urlString)
        return HTTPResponse(
            data: Data(rendered.utf8),
            statusCode: 200,
            headers: [:],
            url: finalURL
        )
    }

    private static func renderWithWebView(
        renderer: HeadlessWebView,
        html: String?,
        url: String,
        headers: [String: String],
        webJs: String?,
        sourceRegex: String?,
        delayMs: Int,
        timeoutMs: Int
    ) async throws -> String {
        if let sourceRegex, !sourceRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await renderer.sniffSourceURL(
                html: html,
                url: url,
                headers: headers,
                sourceRegex: sourceRegex,
                webJs: webJs,
                delayMs: delayMs,
                timeoutMs: max(timeoutMs, 1_000)
            )
        }

        return try await renderer.fetchHTML(
            html: html,
            url: url,
            headers: headers,
            webJs: webJs,
            delayMs: delayMs,
            timeoutMs: max(timeoutMs, 1_000)
        )
    }
}
