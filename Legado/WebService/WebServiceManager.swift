import Foundation
import Combine
import SwiftData
import GCDWebServer
import Darwin
#if canImport(UIKit)
import UIKit
#endif

enum WebServiceError: LocalizedError {
    case missingDependencies
    case invalidPort
    case serverStartFailed(String)
    case missingUploadFile
    case invalidUploadPayload(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingDependencies:
            return "Web 服务尚未绑定主题管理器或数据库上下文。"
        case .invalidPort:
            return "端口范围必须在 1024 - 65530。"
        case .serverStartFailed(let message):
            return "Web 服务启动失败：\(message)"
        case .missingUploadFile:
            return "未收到上传文件。"
        case .invalidUploadPayload(let message):
            return message
        case .encodingFailed:
            return "响应编码失败。"
        }
    }
}

@MainActor
final class WebServiceManager: ObservableObject {
    static let shared = WebServiceManager()

    private enum Constants {
        static let portKey = "Legado.WebService.Port"
        static let defaultPort = 1122
        static let minPort = 1024
        static let maxPort = 65530
    }

    @Published private(set) var isRunning = false
    @Published private(set) var serverURL: URL?
    @Published private(set) var port: Int

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let userDefaults: UserDefaults
    private var server: GCDWebServer?
    private weak var themeManager: ThemeManager?
    private var modelContext: ModelContext?
    private var backgroundObserver: NSObjectProtocol?
    private lazy var isoFormatter = ISO8601DateFormatter()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedPort = userDefaults.integer(forKey: Constants.portKey)
        self.port = Self.normalizedPort(storedPort == 0 ? Constants.defaultPort : storedPort)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    func configure(modelContext: ModelContext, themeManager: ThemeManager) {
        self.modelContext = modelContext
        self.themeManager = themeManager
    }

    func updatePort(_ newValue: Int) throws {
        guard Self.isValidPort(newValue) else {
            throw WebServiceError.invalidPort
        }
        port = newValue
        userDefaults.set(newValue, forKey: Constants.portKey)
    }

    func start(port requestedPort: Int? = nil) throws {
        guard let modelContext, let themeManager else {
            throw WebServiceError.missingDependencies
        }

        let targetPort = requestedPort ?? port
        guard Self.isValidPort(targetPort) else {
            throw WebServiceError.invalidPort
        }

        try updatePort(targetPort)
        stop()

        let webServer = GCDWebServer()
        registerHandlers(on: webServer, modelContext: modelContext, themeManager: themeManager)

        let started = webServer.start(withPort: UInt(targetPort), bonjourName: nil)

        guard started else {
            throw WebServiceError.serverStartFailed("端口 \(targetPort) 可能已被占用。")
        }

        server = webServer
        isRunning = true
        let address = Self.detectLANIPAddress() ?? webServer.serverURL?.host ?? "127.0.0.1"
        serverURL = URL(string: "http://\(address):\(targetPort)")
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        serverURL = nil
    }

    private func registerHandlers(on server: GCDWebServer, modelContext: ModelContext, themeManager: ThemeManager) {
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            self?.htmlResponse() ?? Self.fallbackServerErrorResponse(message: "Web 服务未准备完成")
        }

        server.addHandler(
            forMethod: "GET",
            path: "/index.html",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            self?.htmlResponse() ?? Self.fallbackServerErrorResponse(message: "Web 服务未准备完成")
        }

        server.addHandler(
            forMethod: "GET",
            path: "/api/bookSources",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            return self.handleBookSourceList(modelContext: modelContext)
        }

        server.addHandler(
            forMethod: "DELETE",
            path: "/api/bookSources",
            request: GCDWebServerDataRequest.self
        ) { [weak self] request in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            guard let dataRequest = request as? GCDWebServerDataRequest else {
                return self.errorResponse(statusCode: 400, message: "删除请求无效。")
            }
            return self.handleBookSourceDeletion(request: dataRequest, modelContext: modelContext)
        }

        server.addHandler(
            forMethod: "GET",
            path: "/api/bookshelf",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            return self.handleBookshelfList(modelContext: modelContext)
        }

        server.addHandler(
            forMethod: "GET",
            path: "/api/replaceRules",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            return self.handleReplaceRuleList(modelContext: modelContext)
        }

        server.addHandler(
            forMethod: "GET",
            path: "/api/theme/current",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            return self.handleCurrentTheme(themeManager: themeManager)
        }

        server.addHandler(
            forMethod: "GET",
            path: "/api/theme/export",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            return self.handleThemeExport(themeManager: themeManager)
        }

        server.addHandler(
            forMethod: "GET",
            path: "/api/fonts",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self else { return Self.fallbackServerErrorResponse(message: "Web 服务未准备完成") }
            return self.handleFontList(themeManager: themeManager)
        }

        server.addHandler(
            forMethod: "POST",
            path: "/api/bookSources",
            request: GCDWebServerMultiPartFormRequest.self,
            asyncProcessBlock: { [weak self] request, completion in
                guard let self, let multipartRequest = request as? GCDWebServerMultiPartFormRequest else {
                    completion(Self.fallbackServerErrorResponse(message: "上传请求无效"))
                    return
                }
                Task { @MainActor in
                    completion(self.handleBookSourceImport(request: multipartRequest, modelContext: modelContext))
                }
            }
        )

        server.addHandler(
            forMethod: "POST",
            path: "/api/localBooks/import",
            request: GCDWebServerMultiPartFormRequest.self,
            asyncProcessBlock: { [weak self] request, completion in
                guard let self, let multipartRequest = request as? GCDWebServerMultiPartFormRequest else {
                    completion(Self.fallbackServerErrorResponse(message: "上传请求无效"))
                    return
                }
                Task { @MainActor in
                    completion(await self.handleLocalBookImport(request: multipartRequest, modelContext: modelContext))
                }
            }
        )

        server.addHandler(
            forMethod: "POST",
            path: "/api/replaceRules",
            request: GCDWebServerMultiPartFormRequest.self,
            asyncProcessBlock: { [weak self] request, completion in
                guard let self, let multipartRequest = request as? GCDWebServerMultiPartFormRequest else {
                    completion(Self.fallbackServerErrorResponse(message: "上传请求无效"))
                    return
                }
                Task { @MainActor in
                    completion(self.handleReplaceRuleImport(request: multipartRequest, modelContext: modelContext))
                }
            }
        )

        server.addHandler(
            forMethod: "POST",
            path: "/api/theme/import",
            request: GCDWebServerMultiPartFormRequest.self,
            asyncProcessBlock: { [weak self] request, completion in
                guard let self, let multipartRequest = request as? GCDWebServerMultiPartFormRequest else {
                    completion(Self.fallbackServerErrorResponse(message: "上传请求无效"))
                    return
                }
                Task { @MainActor in
                    completion(self.handleThemeImport(request: multipartRequest, themeManager: themeManager))
                }
            }
        )

        server.addHandler(
            forMethod: "POST",
            path: "/api/fonts/import",
            request: GCDWebServerMultiPartFormRequest.self,
            asyncProcessBlock: { [weak self] request, completion in
                guard let self, let multipartRequest = request as? GCDWebServerMultiPartFormRequest else {
                    completion(Self.fallbackServerErrorResponse(message: "上传请求无效"))
                    return
                }
                Task { @MainActor in
                    completion(self.handleFontImport(request: multipartRequest, themeManager: themeManager))
                }
            }
        )
    }

    private func htmlResponse() -> GCDWebServerResponse {
        let data = Data(WebServiceAdminPage.html.utf8)
        let response = GCDWebServerDataResponse(data: data, contentType: "text/html; charset=utf-8")
        response.statusCode = 200
        decorate(response)
        return response
    }

    private func handleBookSourceList(modelContext: ModelContext) -> GCDWebServerResponse {
        let items = BookSourceRepository.fetchAll(in: modelContext).map { entity in
            WebServiceBookSourceDTO(
                bookSourceUrl: entity.bookSourceUrl,
                bookSourceName: entity.bookSourceName,
                bookSourceGroup: entity.bookSourceGroup,
                enabled: entity.enabled,
                enabledExplore: entity.enabledExplore
            )
        }
        return jsonResponse(data: items)
    }

    private func handleBookSourceDeletion(request: GCDWebServerDataRequest, modelContext: ModelContext) -> GCDWebServerResponse {
        guard let payload = request.jsonObject as? [String: Any],
              let urls = payload["urls"] as? [String],
              !urls.isEmpty else {
            return errorResponse(statusCode: 400, message: "请提供待删除的书源地址数组。")
        }

        BookSourceRepository.delete(urls: Set(urls), in: modelContext)
        NotificationCenter.default.post(name: .bookSourcesDidChange, object: nil)
        return jsonResponse(
            statusCode: 200,
            message: "已删除 \(urls.count) 个书源。",
            data: WebServiceMutationResult(count: urls.count)
        )
    }

    private func handleBookshelfList(modelContext: ModelContext) -> GCDWebServerResponse {
        let descriptor = FetchDescriptor<BookEntity>(
            sortBy: [
                SortDescriptor(\.lastReadTime, order: .reverse),
                SortDescriptor(\.addedTime, order: .reverse)
            ]
        )
        let books = (try? modelContext.fetch(descriptor)) ?? []
        let sourceNameMap = Dictionary(
            uniqueKeysWithValues: BookSourceRepository.fetchAll(in: modelContext).map { ($0.bookSourceUrl, $0.bookSourceName) }
        )
        let items = books.map { book in
            WebServiceBookDTO(
                bookUrl: book.bookUrl,
                name: book.name,
                author: book.author,
                kind: book.kind,
                totalChapterCount: book.totalChapterCount,
                sourceName: LocalBookSupport.isLocalSource(book.sourceUrl)
                    ? LocalBookSupport.sourceName
                    : (sourceNameMap[book.sourceUrl] ?? book.sourceUrl),
                lastReadTime: book.lastReadTime.map { isoFormatter.string(from: $0) }
            )
        }
        return jsonResponse(data: items)
    }

    private func handleReplaceRuleList(modelContext: ModelContext) -> GCDWebServerResponse {
        let store = ReplaceRuleStore(modelContext: modelContext)
        let items = store.fetchAll().map { entity in
            WebServiceReplaceRuleDTO(
                name: entity.name,
                pattern: entity.pattern,
                scope: entity.scope,
                isEnabled: entity.isEnabled
            )
        }
        return jsonResponse(data: items)
    }

    private func handleCurrentTheme(themeManager: ThemeManager) -> GCDWebServerResponse {
        let activeItem = themeManager.item(for: themeManager.activeThemeID)
        let payload = WebServiceThemeDTO(
            id: activeItem?.id ?? themeManager.activeThemeID,
            name: activeItem?.theme.metadata.name ?? themeManager.currentTheme.metadata.name,
            author: activeItem?.theme.metadata.author,
            missingFonts: themeManager.missingTypographyReferences.map(\.postScriptName)
        )
        return jsonResponse(data: payload)
    }

    private func handleThemeExport(themeManager: ThemeManager) -> GCDWebServerResponse {
        do {
            let url = try themeManager.exportURL(for: themeManager.activeThemeID)
            let data = try Data(contentsOf: url)
            let response = GCDWebServerDataResponse(data: data, contentType: "application/json")
            response.statusCode = 200
            response.setValue("attachment; filename=\"\(url.lastPathComponent)\"", forAdditionalHeader: "Content-Disposition")
            decorate(response)
            return response
        } catch {
            return errorResponse(statusCode: 500, message: error.localizedDescription)
        }
    }

    private func handleFontList(themeManager: ThemeManager) -> GCDWebServerResponse {
        let items = themeManager.availableFonts.map { item in
            WebServiceFontDTO(
                displayName: item.displayName,
                postScriptName: item.postScriptName,
                source: item.source.title,
                isCurrent: themeManager.interfaceFontOverridePostScriptName == item.postScriptName
            )
        }
        let payload = WebServiceFontListDTO(
            currentDisplayName: themeManager.interfaceFontOverridePostScriptName.map { themeManager.fontDisplayName(for: $0) },
            items: items
        )
        return jsonResponse(data: payload)
    }

    private func handleBookSourceImport(request: GCDWebServerMultiPartFormRequest, modelContext: ModelContext) -> GCDWebServerResponse {
        do {
            let data = try uploadedData(from: request, allowedExtensions: ["json"])
            let sources = try decodeBookSources(from: data)
            guard !sources.isEmpty else {
                return errorResponse(statusCode: 400, message: "文件中没有可导入的书源。")
            }
            BookSourceRepository.merge(sources: sources, in: modelContext)
            NotificationCenter.default.post(name: .bookSourcesDidChange, object: nil)
            return jsonResponse(
                statusCode: 201,
                message: "已导入 \(sources.count) 个书源。",
                data: WebServiceMutationResult(count: sources.count)
            )
        } catch {
            return errorResponse(statusCode: 400, message: error.localizedDescription)
        }
    }

    private func handleLocalBookImport(request: GCDWebServerMultiPartFormRequest, modelContext: ModelContext) async -> GCDWebServerResponse {
        do {
            let upload = try uploadedFile(from: request, allowedExtensions: ["txt", "epub"])
            let book = try await LocalBookLibraryService.importTemporaryBook(
                from: upload.url,
                originalFileName: upload.originalFileName,
                modelContext: modelContext
            )
            return jsonResponse(
                statusCode: 201,
                message: "《\(book.name)》已加入书架。",
                data: WebServiceBookDTO(
                    bookUrl: book.bookUrl,
                    name: book.name,
                    author: book.author,
                    kind: book.kind,
                    totalChapterCount: book.totalChapterCount,
                    sourceName: LocalBookSupport.sourceName,
                    lastReadTime: book.lastReadTime.map { isoFormatter.string(from: $0) }
                )
            )
        } catch {
            return errorResponse(statusCode: 400, message: error.localizedDescription)
        }
    }

    private func handleReplaceRuleImport(request: GCDWebServerMultiPartFormRequest, modelContext: ModelContext) -> GCDWebServerResponse {
        do {
            let data = try uploadedData(from: request, allowedExtensions: ["json"])
            let rules = try decodeReplaceRules(from: data)
            guard !rules.isEmpty else {
                return errorResponse(statusCode: 400, message: "文件中没有可导入的替换规则。")
            }
            let store = ReplaceRuleStore(modelContext: modelContext)
            store.upsertAll(rules.enumerated().map { index, rule in
                ReplaceRule(
                    name: rule.name,
                    isEnabled: rule.isEnabled,
                    isRegex: rule.isRegex,
                    pattern: rule.pattern,
                    replacement: rule.replacement,
                    scope: rule.scope,
                    matchScope: rule.matchScope,
                    excludeScope: rule.excludeScope,
                    order: rule.order == 0 ? index : rule.order,
                    sourceID: rule.sourceID
                )
            })
            ReaderContentRuleCacheVersion.notifyRulesChanged()
            return jsonResponse(
                statusCode: 201,
                message: "已导入 \(rules.count) 条替换规则。",
                data: WebServiceMutationResult(count: rules.count)
            )
        } catch {
            return errorResponse(statusCode: 400, message: error.localizedDescription)
        }
    }

    private func handleThemeImport(request: GCDWebServerMultiPartFormRequest, themeManager: ThemeManager) -> GCDWebServerResponse {
        do {
            let url = try uploadedFileURL(from: request, allowedExtensions: ["json"])
            let item = try themeManager.installTheme(from: url, applyImmediately: false, replaceExisting: false)
            return jsonResponse(
                statusCode: 201,
                message: "主题“\(item.theme.metadata.name)”已安装。",
                data: WebServiceThemeDTO(
                    id: item.id,
                    name: item.theme.metadata.name,
                    author: item.theme.metadata.author,
                    missingFonts: []
                )
            )
        } catch {
            return errorResponse(statusCode: 400, message: error.localizedDescription)
        }
    }

    private func handleFontImport(request: GCDWebServerMultiPartFormRequest, themeManager: ThemeManager) -> GCDWebServerResponse {
        do {
            let url = try uploadedFileURL(from: request, allowedExtensions: ["ttf", "otf"])
            let item = try themeManager.importFont(from: url)
            return jsonResponse(
                statusCode: 201,
                message: "字体“\(item.displayName)”已导入。",
                data: WebServiceFontDTO(
                    displayName: item.displayName,
                    postScriptName: item.postScriptName,
                    source: item.source.title,
                    isCurrent: themeManager.interfaceFontOverridePostScriptName == item.postScriptName
                )
            )
        } catch {
            return errorResponse(statusCode: 400, message: error.localizedDescription)
        }
    }

    private func uploadedFile(
        from request: GCDWebServerMultiPartFormRequest,
        allowedExtensions: Set<String>
    ) throws -> (url: URL, originalFileName: String) {
        guard let file = request.files.first else {
            throw WebServiceError.missingUploadFile
        }
        let fileExtension = (file.fileName as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(fileExtension) else {
            throw WebServiceError.invalidUploadPayload("文件类型不支持：\(file.fileName)")
        }
        return (URL(fileURLWithPath: file.temporaryPath), file.fileName)
    }

    private func uploadedFileURL(from request: GCDWebServerMultiPartFormRequest, allowedExtensions: Set<String>) throws -> URL {
        try uploadedFile(from: request, allowedExtensions: allowedExtensions).url
    }

    private func uploadedData(from request: GCDWebServerMultiPartFormRequest, allowedExtensions: Set<String>) throws -> Data {
        let url = try uploadedFileURL(from: request, allowedExtensions: allowedExtensions)
        return try Data(contentsOf: url)
    }

    private func decodeBookSources(from data: Data) throws -> [BookSource] {
        if let sources = try? decoder.decode([BookSource].self, from: data) {
            return sources.filter { !$0.isMangaSource }
        }
        if let source = try? decoder.decode(BookSource.self, from: data) {
            return source.isMangaSource ? [] : [source]
        }
        throw WebServiceError.invalidUploadPayload("书源 JSON 解析失败。")
    }

    private func decodeReplaceRules(from data: Data) throws -> [ReplaceRule] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebServiceError.invalidUploadPayload("替换规则 JSON 不是 UTF-8 文本。")
        }
        do {
            return try ReplaceRule.importRules(from: text)
        } catch {
            throw WebServiceError.invalidUploadPayload("替换规则 JSON 解析失败。")
        }
    }

    private func jsonResponse<T: Encodable>(
        statusCode: Int = 200,
        message: String? = nil,
        data: T?
    ) -> GCDWebServerResponse {
        do {
            let payload = WebServiceEnvelope(success: true, message: message, data: data)
            let data = try encoder.encode(payload)
            let response = GCDWebServerDataResponse(data: data, contentType: "application/json; charset=utf-8")
            response.statusCode = statusCode
            decorate(response)
            return response
        } catch {
            return Self.fallbackServerErrorResponse(message: WebServiceError.encodingFailed.localizedDescription)
        }
    }

    private func errorResponse(statusCode: Int, message: String) -> GCDWebServerResponse {
        do {
            let payload = WebServiceEnvelope<WebServiceEmptyDTO>(success: false, message: message, data: nil)
            let data = try encoder.encode(payload)
            let response = GCDWebServerDataResponse(data: data, contentType: "application/json; charset=utf-8")
            response.statusCode = statusCode
            decorate(response)
            return response
        } catch {
            return Self.fallbackServerErrorResponse(message: message)
        }
    }

    private func decorate(_ response: GCDWebServerResponse) {
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        response.setValue("GET, POST, DELETE, OPTIONS", forAdditionalHeader: "Access-Control-Allow-Methods")
        response.setValue("Content-Type", forAdditionalHeader: "Access-Control-Allow-Headers")
        response.setValue("no-store", forAdditionalHeader: "Cache-Control")
    }

    private static func fallbackServerErrorResponse(message: String) -> GCDWebServerResponse {
        let data = Data(#"{"success":false,"message":"internal server error","data":null}"#.utf8)
        let response = GCDWebServerDataResponse(data: data, contentType: "application/json; charset=utf-8")
        response.statusCode = 500
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        response.setValue(message, forAdditionalHeader: "X-Legado-Error")
        return response
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (Constants.minPort...Constants.maxPort).contains(port)
    }

    private static func normalizedPort(_ port: Int) -> Int {
        isValidPort(port) ? port : Constants.defaultPort
    }

    private static func detectLANIPAddress() -> String? {
        var candidates: [(name: String, address: String, priority: Int)] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstAddress = interfaces else {
            return nil
        }

        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { continue }
            let candidate = String(cString: hostname)
            guard let priority = lanPriority(for: candidate, interfaceName: name) else {
                continue
            }
            candidates.append((name: name, address: candidate, priority: priority))
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first?
            .address
    }

    private static func lanPriority(for address: String, interfaceName: String) -> Int? {
        if address.hasPrefix("169.254.") || address == "127.0.0.1" {
            return nil
        }

        let interfacePriority: Int
        switch interfaceName {
        case "en0", "en1":
            interfacePriority = 40
        case let name where name.hasPrefix("en"):
            interfacePriority = 30
        default:
            interfacePriority = 0
        }

        if address.hasPrefix("192.168.") {
            return 300 + interfacePriority
        }

        if let secondOctet = Int(address.split(separator: ".").dropFirst().first ?? ""),
           address.hasPrefix("172."),
           (16...31).contains(secondOctet) {
            return 200 + interfacePriority
        }

        if address.hasPrefix("10.") {
            return 100 + interfacePriority
        }

        return nil
    }
}

private struct WebServiceEnvelope<T: Encodable>: Encodable {
    let success: Bool
    let message: String?
    let data: T?
}

private struct WebServiceEmptyDTO: Encodable {
}

private struct WebServiceMutationResult: Encodable {
    let count: Int
}

private struct WebServiceBookSourceDTO: Encodable {
    let bookSourceUrl: String
    let bookSourceName: String
    let bookSourceGroup: String?
    let enabled: Bool
    let enabledExplore: Bool
}

private struct WebServiceBookDTO: Encodable {
    let bookUrl: String
    let name: String
    let author: String
    let kind: String?
    let totalChapterCount: Int
    let sourceName: String
    let lastReadTime: String?
}

private struct WebServiceReplaceRuleDTO: Encodable {
    let name: String
    let pattern: String
    let scope: String
    let isEnabled: Bool
}

private struct WebServiceThemeDTO: Encodable {
    let id: String
    let name: String
    let author: String?
    let missingFonts: [String]
}

private struct WebServiceFontDTO: Encodable {
    let displayName: String
    let postScriptName: String
    let source: String
    let isCurrent: Bool
}

private struct WebServiceFontListDTO: Encodable {
    let currentDisplayName: String?
    let items: [WebServiceFontDTO]
}
