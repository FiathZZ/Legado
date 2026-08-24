import Foundation
import SwiftData

// MARK: - RSS 导入错误
enum RssSourceImportError: LocalizedError {
    case invalidInput
    case invalidSubscriptionURL
    case missingSourceParameter
    case invalidRemoteURL
    case unsupportedSubscriptionType(String)
    case fileReadError(Error)
    case networkError(Error)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "请输入有效的 RSS 源地址或内容"
        case .invalidSubscriptionURL:
            return "无效的 RSS 订阅地址格式"
        case .missingSourceParameter:
            return "RSS 订阅地址缺少 src 参数"
        case .invalidRemoteURL:
            return "RSS 远程地址无效"
        case .unsupportedSubscriptionType(let type):
            return "当前链接是\(type)订阅，不是可导入的 RSS 订阅"
        case .fileReadError(let error):
            return "读取 RSS 文件失败: \(error.localizedDescription)"
        case .networkError(let error):
            return "RSS 网络请求失败: \(error.localizedDescription)"
        case .parseError(let message):
            return "RSS 解析失败: \(message)"
        }
    }
}

struct RssSourcePayload: Decodable, Sendable {
    let sourceUrl: String
    let sourceName: String
    let sourceIcon: String
    let sourceGroup: String?
    let sourceComment: String?
    let enabled: Bool
    let variableComment: String?
    let jsLib: String?
    let enabledCookieJar: Bool
    let concurrentRate: String?
    let header: String?
    let loginUrl: String?
    let loginUi: String?
    let loginCheckJs: String?
    let coverDecodeJs: String?
    let sortUrl: String?
    let singleUrl: Bool
    let articleStyle: Int
    let ruleArticles: String?
    let ruleNextPage: String?
    let ruleTitle: String?
    let rulePubDate: String?
    let ruleDescription: String?
    let ruleImage: String?
    let ruleLink: String?
    let ruleContent: String?
    let contentWhitelist: String?
    let contentBlacklist: String?
    let shouldOverrideUrlLoading: String?
    let style: String?
    let enableJs: Bool
    let loadWithBaseUrl: Bool
    let injectJs: String?
    let lastUpdateTime: Int64
    let customOrder: Int

    enum CodingKeys: String, CodingKey {
        case sourceUrl
        case sourceName
        case sourceIcon
        case sourceGroup
        case sourceComment
        case enabled
        case variableComment
        case jsLib
        case enabledCookieJar
        case concurrentRate
        case header
        case loginUrl
        case loginUi
        case loginCheckJs
        case coverDecodeJs
        case sortUrl
        case singleUrl
        case articleStyle
        case ruleArticles
        case ruleNextPage
        case ruleTitle
        case rulePubDate
        case ruleDescription
        case ruleImage
        case ruleLink
        case ruleContent
        case contentWhitelist
        case contentBlacklist
        case shouldOverrideUrlLoading
        case style
        case enableJs
        case loadWithBaseUrl
        case injectJs
        case lastUpdateTime
        case customOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceUrl = try container.decodeIfPresent(String.self, forKey: .sourceUrl)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        self.sourceIcon = try container.decodeIfPresent(String.self, forKey: .sourceIcon) ?? ""
        self.sourceGroup = try container.decodeIfPresent(String.self, forKey: .sourceGroup)
        self.sourceComment = try container.decodeIfPresent(String.self, forKey: .sourceComment)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.variableComment = try container.decodeIfPresent(String.self, forKey: .variableComment)
        self.jsLib = try container.decodeIfPresent(String.self, forKey: .jsLib)
        self.enabledCookieJar = try container.decodeIfPresent(Bool.self, forKey: .enabledCookieJar) ?? true
        self.concurrentRate = try container.decodeIfPresent(String.self, forKey: .concurrentRate)
        self.header = try container.decodeIfPresent(String.self, forKey: .header)
        self.loginUrl = try container.decodeIfPresent(String.self, forKey: .loginUrl)
        self.loginUi = try container.decodeIfPresent(String.self, forKey: .loginUi)
        self.loginCheckJs = try container.decodeIfPresent(String.self, forKey: .loginCheckJs)
        self.coverDecodeJs = try container.decodeIfPresent(String.self, forKey: .coverDecodeJs)
        self.sortUrl = try container.decodeIfPresent(String.self, forKey: .sortUrl)
        self.singleUrl = try container.decodeIfPresent(Bool.self, forKey: .singleUrl) ?? false
        self.articleStyle = try container.decodeIfPresent(Int.self, forKey: .articleStyle) ?? 0
        self.ruleArticles = try container.decodeIfPresent(String.self, forKey: .ruleArticles)
        self.ruleNextPage = try container.decodeIfPresent(String.self, forKey: .ruleNextPage)
        self.ruleTitle = try container.decodeIfPresent(String.self, forKey: .ruleTitle)
        self.rulePubDate = try container.decodeIfPresent(String.self, forKey: .rulePubDate)
        self.ruleDescription = try container.decodeIfPresent(String.self, forKey: .ruleDescription)
        self.ruleImage = try container.decodeIfPresent(String.self, forKey: .ruleImage)
        self.ruleLink = try container.decodeIfPresent(String.self, forKey: .ruleLink)
        self.ruleContent = try container.decodeIfPresent(String.self, forKey: .ruleContent)
        self.contentWhitelist = try container.decodeIfPresent(String.self, forKey: .contentWhitelist)
        self.contentBlacklist = try container.decodeIfPresent(String.self, forKey: .contentBlacklist)
        self.shouldOverrideUrlLoading = try container.decodeIfPresent(String.self, forKey: .shouldOverrideUrlLoading)
        self.style = try container.decodeIfPresent(String.self, forKey: .style)
        self.enableJs = try container.decodeIfPresent(Bool.self, forKey: .enableJs) ?? true
        self.loadWithBaseUrl = try container.decodeIfPresent(Bool.self, forKey: .loadWithBaseUrl) ?? true
        self.injectJs = try container.decodeIfPresent(String.self, forKey: .injectJs)
        self.lastUpdateTime = try container.decodeIfPresent(Int64.self, forKey: .lastUpdateTime) ?? 0
        self.customOrder = try container.decodeIfPresent(Int.self, forKey: .customOrder) ?? 0
    }
}

// MARK: - RSS 源导入服务
struct RssSourceImportService {
    typealias RemoteDataLoader = @Sendable (URL) async throws -> Data
    typealias LocalFileLoader = @Sendable (URL) throws -> Data

    private struct SourceURLCollection: Decodable {
        let sourceUrls: [String]?
    }

    private let remoteDataLoader: RemoteDataLoader?
    private let localFileLoader: LocalFileLoader?

    init() {
        self.remoteDataLoader = nil
        self.localFileLoader = nil
    }

    init(
        remoteDataLoader: @escaping RemoteDataLoader,
        localFileLoader: @escaping LocalFileLoader = { url in
            try Data(contentsOf: url)
        }
    ) {
        self.remoteDataLoader = remoteDataLoader
        self.localFileLoader = localFileLoader
    }

    func parseSubscriptionURL(_ urlString: String) throws -> URL {
        let parsed: (kind: BookSourceService.SubscriptionKind, remoteURL: URL)
        do {
            parsed = try BookSourceService.parseSubscription(urlString)
        } catch let error as BookSourceServiceError {
            switch error {
            case .invalidSubscriptionURL:
                throw RssSourceImportError.invalidSubscriptionURL
            case .missingSourceParameter:
                throw RssSourceImportError.missingSourceParameter
            case .invalidRemoteURL:
                throw RssSourceImportError.invalidRemoteURL
            case .unsupportedSubscriptionType(let type):
                throw RssSourceImportError.unsupportedSubscriptionType(type)
            case .networkError(let innerError):
                throw RssSourceImportError.networkError(innerError)
            case .parseError(let message):
                throw RssSourceImportError.parseError(message)
            }
        }
        guard parsed.kind == .rssSource else {
            throw RssSourceImportError.unsupportedSubscriptionType("书源")
        }
        return parsed.remoteURL
    }

    @MainActor
    func importSources(from input: String, into context: ModelContext) async throws -> [RssSourceEntity] {
        let payloads = try await loadImportableSources(from: input)
        return try upsert(payloads: payloads, into: context)
    }

    @MainActor
    func importSources(fromFile fileURL: URL, into context: ModelContext) async throws -> [RssSourceEntity] {
        let payloads = try await loadImportableSources(fromFile: fileURL)
        return try upsert(payloads: payloads, into: context)
    }

    @MainActor
    func importSources(fromRemoteURL remoteURL: URL, into context: ModelContext) async throws -> [RssSourceEntity] {
        let payloads = try await loadImportableSources(fromRemoteURL: remoteURL)
        return try upsert(payloads: payloads, into: context)
    }

    func loadImportableSources(from input: String) async throws -> [RssSourcePayload] {
        let trimmed = input
            .normalizedImportURLString()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RssSourceImportError.invalidInput
        }

        if let data = trimmed.data(using: .utf8),
           let jsonType = jsonType(for: data) {
            return try await decodeSources(from: data, jsonType: jsonType)
        }

        if trimmed.hasPrefix("yuedu://") {
            let remoteURL = try parseSubscriptionURL(trimmed)
            return try await loadImportableSources(fromParsedSubscriptionURL: remoteURL)
        }

        if let url = URL(string: trimmed) {
            if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                return try await loadImportableSources(fromRemoteURL: url)
            }
            if url.isFileURL {
                return try await loadImportableSources(fromFile: url)
            }
        }

        if FileManager.default.fileExists(atPath: trimmed) {
            return try await loadImportableSources(fromFile: URL(fileURLWithPath: trimmed))
        }

        throw RssSourceImportError.invalidInput
    }

    func loadImportableSources(fromFile fileURL: URL) async throws -> [RssSourcePayload] {
        do {
            let data: Data
            if let localFileLoader {
                data = try localFileLoader(fileURL)
            } else {
                data = try Data(contentsOf: fileURL)
            }
            return try await loadImportableSources(from: String(decoding: data, as: UTF8.self))
        } catch let error as RssSourceImportError {
            throw error
        } catch {
            throw RssSourceImportError.fileReadError(error)
        }
    }

    func loadImportableSources(fromRemoteURL remoteURL: URL) async throws -> [RssSourcePayload] {
        let url = sanitizedRemoteURL(remoteURL)
        do {
            let data: Data
            if let remoteDataLoader {
                data = try await remoteDataLoader(url)
            } else {
                data = try await fetchRemoteData(from: url)
            }
            guard let jsonType = jsonType(for: data) else {
                throw RssSourceImportError.parseError("响应内容不是有效的 RSS 源 JSON")
            }
            return try await decodeSources(from: data, jsonType: jsonType)
        } catch let error as RssSourceImportError {
            throw error
        } catch {
            throw RssSourceImportError.networkError(error)
        }
    }

    private func loadImportableSources(fromParsedSubscriptionURL remoteURL: URL) async throws -> [RssSourcePayload] {
        if remoteURL.isFileURL {
            return try await loadImportableSources(fromFile: remoteURL)
        }
        guard let scheme = remoteURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw RssSourceImportError.invalidRemoteURL
        }
        return try await loadImportableSources(fromRemoteURL: remoteURL)
    }

    @MainActor
    func upsert(payloads: [RssSourcePayload], into context: ModelContext) throws -> [RssSourceEntity] {
        let existing = (try? context.fetch(FetchDescriptor<RssSourceEntity>())) ?? []
        var existingByURL = Dictionary(uniqueKeysWithValues: existing.map { ($0.sourceUrl, $0) })
        var importedEntities: [RssSourceEntity] = []

        for payload in payloads {
            if let entity = existingByURL[payload.sourceUrl] {
                entity.update(from: payload)
                importedEntities.append(entity)
            } else {
                let entity = RssSourceEntity(payload: payload)
                context.insert(entity)
                existingByURL[payload.sourceUrl] = entity
                importedEntities.append(entity)
            }
        }

        try context.save()
        return importedEntities
    }

    private func decodeSources(from data: Data, jsonType: JSONType) async throws -> [RssSourcePayload] {
        switch jsonType {
        case .object:
            let object = try jsonObject(from: data)
            if let sourceURLs = extractSourceURLs(from: object),
               !sourceURLs.isEmpty {
                var merged: [RssSourcePayload] = []
                for sourceURL in sourceURLs {
                    let payloads = try await loadImportableSources(from: sourceURL)
                    merged.append(contentsOf: payloads)
                }
                return try validated(payloads: merged)
            }

            if let payload = decodeSinglePayload(from: data) {
                return try validated(payloads: [payload])
            }

            throw RssSourceImportError.parseError("不是有效的 RSS 源或 RSS 源数组")

        case .array:
            let object = try jsonObject(from: data)
            guard let items = object as? [Any] else {
                throw RssSourceImportError.parseError("不是有效的 RSS 源数组")
            }
            let payloads = try decodePayloadArray(from: items)
            return try validated(payloads: payloads)
        }
    }

    private func validated(payloads: [RssSourcePayload]) throws -> [RssSourcePayload] {
        guard let first = payloads.first,
              !first.sourceUrl.isEmpty else {
            throw RssSourceImportError.parseError("不是有效的 RSS 源")
        }
        return payloads
    }

    private func sanitizedRemoteURL(_ url: URL) -> URL {
        let suffix = "#requestWithoutUA"
        let absoluteString = url.absoluteString
        guard absoluteString.hasSuffix(suffix) else { return url }
        return URL(string: String(absoluteString.dropLast(suffix.count))) ?? url
    }

    private func fetchRemoteData(from url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, _) = try await session.data(for: request)
        session.invalidateAndCancel()
        return data
    }

    private func jsonType(for data: Data) -> JSONType? {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            if object is [Any] {
                return .array
            }
            if object is [String: Any] {
                return .object
            }
            return nil
        } catch {
            return nil
        }
    }

    private func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RssSourceImportError.parseError("JSON 格式错误")
        }
    }

    private func extractSourceURLs(from object: Any) -> [String]? {
        guard let dictionary = object as? [String: Any] else { return nil }
        guard let rawURLs = dictionary["sourceUrls"] as? [Any] else { return nil }

        let urls = rawURLs.compactMap { value -> String? in
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        return urls.isEmpty ? nil : urls
    }

    private func decodePayloadArray(from items: [Any]) throws -> [RssSourcePayload] {
        var payloads: [RssSourcePayload] = []

        for item in items {
            guard let dictionary = item as? [String: Any],
                  dictionary["sourceUrl"] != nil else {
                throw RssSourceImportError.parseError("不是订阅源")
            }

            guard let itemData = try? JSONSerialization.data(withJSONObject: dictionary),
                  let payload = decodeSinglePayload(from: itemData) else {
                throw RssSourceImportError.parseError("RSS 源字段格式无效")
            }
            payloads.append(payload)
        }

        return payloads
    }

    private func decodeSinglePayload(from data: Data) -> RssSourcePayload? {
        try? JSONDecoder().decode(RssSourcePayload.self, from: data)
    }

    private enum JSONType {
        case object
        case array
    }
}
