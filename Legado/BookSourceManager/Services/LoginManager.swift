import Foundation

// MARK: - LoginManager
/// 书源登录管理器。
nonisolated final class LoginManager {
    static let shared = LoginManager()

    private let cookieManager: CookieManager
    private let sessionDefaults = UserDefaults.standard
    private let sessionKey = "Legado.LoginSessions"
    private let captchaResolver: CaptchaResolver

    init(cookieManager: CookieManager = .shared, captchaResolver: CaptchaResolver = UnsupportedCaptchaResolver()) {
        self.cookieManager = cookieManager
        self.captchaResolver = captchaResolver
    }

    /// 获取书源登录表单定义。
    func loginForm(for source: BookSource) throws -> LoginFormDefinition? {
        guard let loginUi = source.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !loginUi.isEmpty else {
            return nil
        }

        guard let data = loginUi.data(using: .utf8),
              let rawItems = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParserError.parseError("loginUi 不是有效 JSON 数组")
        }

        let fields = rawItems.enumerated().map { index, item in
            let name = (item["name"] as? String) ?? "field_\(index)"
            let type = LoginFieldDefinition.FieldType(rawValue: ((item["type"] as? String) ?? "text").lowercased()) ?? .text
            let action = item["action"] as? String
            let value = item["value"] as? String
            let extras = item.reduce(into: [String: String]()) { partial, entry in
                guard !["name", "type", "action", "value"].contains(entry.key) else { return }
                partial[entry.key] = "\(entry.value)"
            }

            return LoginFieldDefinition(
                id: "\(source.bookSourceUrl)#\(index)",
                name: name,
                type: type,
                action: action,
                value: value,
                extras: extras
            )
        }

        return LoginFormDefinition(fields: fields, extras: [:])
    }

    /// 执行书源登录请求。
    func login(source: BookSource, values: [String: String], captcha: CaptchaPayload?) async throws {
        guard let loginURLRule = source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !loginURLRule.isEmpty else {
            throw ParserError.loginRequired("书源未配置 loginUrl")
        }

        var mergedValues = values
        if let captcha {
            mergedValues["captcha"] = captcha.value
            captcha.extras.forEach { mergedValues[$0.key] = $0.value }
        }

        let variableStore = ParserVariableStore(values: mergedValues, writeScope: .source)
        let analyzeUrl = AnalyzeUrl(
            rule: loginURLRule,
            baseUrl: source.bookSourceUrl,
            headerString: source.header,
            source: source,
            variableStore: variableStore
        )

        let request = HTTPClient.makeRequest(from: analyzeUrl)

        let client = HTTPClient()
        _ = try await client.send(request: request)
        guard let domain = URL(string: source.bookSourceUrl)?.host else {
            throw ParserError.loginRequired("登录完成后无法确认 Cookie 域名")
        }

        let cookies = cookieManager.getCookieString(domain: domain)
        guard !cookies.isEmpty else {
            throw ParserError.loginRequired("登录后未获取到 Cookie，会话未建立")
        }

        var session = allSessions()[source.bookSourceUrl] ?? LoginSession(
            sourceURL: source.bookSourceUrl,
            loggedInAt: Date(),
            lastValidatedAt: nil,
            values: mergedValues
        )
        session.values = mergedValues
        persist(session: session)
    }

    /// 校验当前书源是否仍处于有效登录态。
    func validateSession(for source: BookSource) async -> Bool {
        guard let js = source.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines), !js.isEmpty else {
            return true
        }

        guard let sourceURL = URL(string: source.bookSourceUrl), !cookieManager.getCookieString(for: sourceURL).isEmpty else {
            return false
        }

        let session = allSessions()[source.bookSourceUrl]
        guard session != nil else {
            return false
        }

        if requiresResponseObjectPreflightBypass(js) {
            touch(session: session, for: source)
            ParserLog.debug(
                "LoginManager",
                "loginCheckJs preflight bypassed for response-style script source=\(source.bookSourceName)"
            )
            return true
        }

        let variableStore = ParserVariableStore(values: session?.values ?? [:], writeScope: .source)
        let analyzeUrl = AnalyzeUrl(
            rule: source.bookSourceUrl,
            baseUrl: source.bookSourceUrl,
            headerString: source.header,
            source: source,
            variableStore: variableStore
        )
        let requestHeaders = HTTPClient.requestHeaders(for: analyzeUrl)
        let parser = JavaScriptParser(
            baseUrl: source.bookSourceUrl,
            source: source,
            variableStore: variableStore,
            requestURL: analyzeUrl.urlString,
            requestHeaders: requestHeaders
        )
        do {
            let cookieString = cookieManager.getCookieString(for: sourceURL)
            parser.updateContextContent(cookieString)
            let result = try parser.evaluate(
                script: JavaScriptParser.wrapImmediateInvocation(js),
                result: cookieString
            )
            let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isValid = !["", "false", "0", "null", "undefined"].contains(normalized)
            if isValid {
                touch(session: session, for: source)
            }
            return isValid
        } catch {
            // 一部分 loginCheckJs 会在响应返回后按 Android StrResponse 访问 result.body()/result.code()。
            // 预检阶段只有本地 Cookie 快照，无法提供完整响应对象；这类脚本抛错时，退化为
            // “本地已有已登录会话且 Cookie 未丢失” 的快速判断，真实失效仍由响应后 loginCheckJs 捕获。
            if session != nil {
                touch(session: session, for: source)
                ParserLog.debug(
                    "LoginManager",
                    "loginCheckJs preflight fallback to persisted session source=\(source.bookSourceName) error=\(error.localizedDescription)"
                )
                return true
            }
            return false
        }
    }

    /// 清除当前书源会话。
    func clearSession(for source: BookSource) {
        if let host = URL(string: source.bookSourceUrl)?.host {
            cookieManager.clearCookies(domain: host)
        }
        var sessions = allSessions()
        sessions.removeValue(forKey: source.bookSourceUrl)
        persist(sessions: sessions)
    }

    /// 解析或创建验证码载荷。
    func resolveCaptchaIfNeeded(_ challenge: CaptchaChallenge?) async throws -> CaptchaPayload? {
        guard let challenge else { return nil }
        return try await captchaResolver.resolve(challenge)
    }

    private func allSessions() -> [String: LoginSession] {
        guard let data = sessionDefaults.data(forKey: sessionKey),
              let sessions = try? JSONDecoder().decode([String: LoginSession].self, from: data) else {
            return [:]
        }
        return sessions
    }

    private func persist(session: LoginSession) {
        var sessions = allSessions()
        sessions[session.sourceURL] = session
        persist(sessions: sessions)
    }

    private func persist(sessions: [String: LoginSession]) {
        if let data = try? JSONEncoder().encode(sessions) {
            sessionDefaults.set(data, forKey: sessionKey)
        }
    }

    private func touch(session: LoginSession?, for source: BookSource) {
        guard var session else { return }
        session.lastValidatedAt = Date()
        persist(session: session)
    }

    private func requiresResponseObjectPreflightBypass(_ js: String) -> Bool {
        let normalized = js.replacingOccurrences(of: " ", with: "")
        let patterns = [
            "result.body(",
            "result.body.",
            "result.body[",
            "result.body)",
            "result.code(",
            "result.statusCode(",
            "result.headers(",
            "result.header(",
            "result.url.",
            "result.url[",
            "result.finalURL",
            "result.finalUrl",
            "result.requestUrl",
            "result.requestURL"
        ]
        return patterns.contains { normalized.contains($0) }
    }
}
