import Foundation

// MARK: - 导入链接归一化
extension String {
    /// 将移动端中文输入法常见的全角 URL 符号归一化为 ASCII，避免导入链接被误判为非法 URL。
    func normalizedImportURLString() -> String {
        let replacements: [String: String] = [
            "：": ":",
            "／": "/",
            "？": "?",
            "＝": "=",
            "＆": "&",
            "。": ".",
            "＃": "#",
            "％": "%",
            "　": " "
        ]

        var normalized = self
        for (source, target) in replacements {
            normalized = normalized.replacingOccurrences(of: source, with: target)
        }
        return normalized.replacingOccurrences(of: "\u{2006}", with: "")
    }
}

// MARK: - 书源服务错误
enum BookSourceServiceError: LocalizedError {
    case invalidSubscriptionURL
    case missingSourceParameter
    case invalidRemoteURL
    case unsupportedSubscriptionType(String)
    case networkError(Error)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidSubscriptionURL:
            return "无效的订阅地址格式"
        case .missingSourceParameter:
            return "订阅地址缺少 src 参数"
        case .invalidRemoteURL:
            return "远程书源地址无效"
        case .unsupportedSubscriptionType(let type):
            return "当前链接是\(type)订阅，不是可导入的书源订阅"
        case .networkError(let error):
            return "网络请求失败: \(error.localizedDescription)"
        case .parseError(let message):
            return "书源解析失败: \(message)"
        }
    }
}

// MARK: - 书源服务
/// 负责订阅地址解析、远程书源获取与 JSON 解码
struct BookSourceService {
    enum SubscriptionKind: String {
        case bookSource = "booksource"
        case rssSource = "rsssource"
    }

    private static let supportedSubscriptionHosts: Set<String> = [
        "booksource",
        "rsssource"
    ]

    // MARK: 订阅地址解析
    /// 解析 `yuedu://booksource/importonline?src=<url>` 或
    /// `yuedu://rsssource/importonline?src=<url>` 格式的订阅地址，返回远程 JSON 的 URL。
    ///
    /// 社区里存在一批历史分享链接会复用 `rsssource` host 来承载书源 JSON，
    /// Android legado 在在线导入时会继续读取 `src` 并尝试解析具体类型。
    /// 这里对 host 做兼容放宽，避免合法分享链接在 Swift 端被提前拒绝。
    static func parseSubscriptionURL(_ urlString: String) throws -> URL {
        let parsed = try parseSubscription(urlString)
        return parsed.remoteURL
    }

    static func parseSubscription(_ urlString: String) throws -> (kind: SubscriptionKind, remoteURL: URL) {
        let normalized = urlString.normalizedImportURLString()
        guard let components = URLComponents(string: normalized),
              components.scheme == "yuedu",
              let host = components.host?.lowercased(),
              supportedSubscriptionHosts.contains(host) else {
            throw BookSourceServiceError.invalidSubscriptionURL
        }
        guard let kind = SubscriptionKind(rawValue: host) else {
            throw BookSourceServiceError.invalidSubscriptionURL
        }
        guard let srcValue = components.queryItems?.first(where: { $0.name == "src" })?.value,
              !srcValue.isEmpty else {
            throw BookSourceServiceError.missingSourceParameter
        }
        guard let remoteURL = URL(string: srcValue) else {
            throw BookSourceServiceError.invalidRemoteURL
        }
        return (kind, remoteURL)
    }

    static func importFromAnyURLString(_ urlString: String) async throws -> [BookSource] {
        let normalized = urlString
            .normalizedImportURLString()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw BookSourceServiceError.invalidRemoteURL
        }

        if normalized.hasPrefix("yuedu://") {
            return try await importFromSubscription(normalized)
        }
        return try await fetchBookSources(from: try validatedRemoteURL(from: normalized))
    }

    /// 解析用户直接粘贴的单个书源或书源数组 JSON。
    static func importFromJSONText(_ text: String) throws -> [BookSource] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw BookSourceServiceError.parseError("JSON 内容为空")
        }
        return try decodeBookSources(from: Data(normalized.utf8))
    }

    // MARK: 远程获取并解析书源
    /// 从远程 URL 下载书源 JSON，支持单个书源对象或书源数组
    static func fetchBookSources(from url: URL) async throws -> [BookSource] {
        let data: Data
        do {
            data = try await loadData(from: url)
        } catch {
            throw BookSourceServiceError.networkError(error)
        }

        return try decodeBookSources(from: data)
    }

    // MARK: 通过订阅地址导入书源
    /// 解析订阅地址后拉取并返回书源列表
    static func importFromSubscription(_ subscriptionURL: String) async throws -> [BookSource] {
        let parsed = try parseSubscription(subscriptionURL)
        guard parsed.kind == .bookSource else {
            throw BookSourceServiceError.unsupportedSubscriptionType("RSS")
        }
        let remoteURL = parsed.remoteURL
        return try await fetchBookSources(from: remoteURL)
    }

    // MARK: 直接从 HTTP/HTTPS URL 导入书源
    /// 直接从普通 http/https URL 拉取书源
    static func importFromHTTPURL(_ urlString: String) async throws -> [BookSource] {
        let url = try validatedRemoteURL(from: urlString)
        return try await fetchBookSources(from: url)
    }

    private static func validatedRemoteURL(from urlString: String) throws -> URL {
        let normalized = urlString
            .normalizedImportURLString()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized) else {
            throw BookSourceServiceError.invalidRemoteURL
        }
        return url
    }

    private static func decodeBookSources(from data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder()
        if let sources = try? decoder.decode([BookSource].self, from: data), !sources.isEmpty {
            return sources.filter { !$0.isMangaSource }
        }
        if let source = try? decoder.decode(BookSource.self, from: data) {
            return source.isMangaSource ? [] : [source]
        }

        let detail: String
        do {
            _ = try decoder.decode([BookSource].self, from: data)
            detail = "书源数组为空"
        } catch {
            detail = error.localizedDescription
        }
        throw BookSourceServiceError.parseError("JSON 格式不是有效的书源或书源数组：\(detail)")
    }

    private static func loadData(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        let (responseData, _) = try await URLSession.shared.data(from: url)
        return responseData
    }
}
