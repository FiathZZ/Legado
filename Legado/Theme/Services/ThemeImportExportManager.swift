import Foundation

enum ThemeImportExportError: LocalizedError {
    case malformedJSON
    case unsupportedSchemaVersion(Int)
    case duplicateThemeID(String)
    case reservedContainerFormat
    case invalidFilename

    var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "主题文件不是有效的 JSON。"
        case .unsupportedSchemaVersion(let version):
            return "不支持的主题 schemaVersion：\(version)。"
        case .duplicateThemeID(let id):
            return "主题 ID “\(id)” 已存在，请先删除旧主题或改用新 ID。"
        case .reservedContainerFormat:
            return "`.Legado-themepack` 预留给后续字体/资源包，本阶段暂不支持导入。"
        case .invalidFilename:
            return "主题文件名无效。"
        }
    }
}

struct ThemeImportResult: Sendable {
    let item: ThemeCatalogItem
    let replacedExistingTheme: Bool
}

struct ThemeImportExportManager {
    static let standaloneFileSuffix = ".Legado-theme.json"
    static let containerFileSuffix = ".Legado-themepack"

    private let store: ThemeStore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let fileManager: FileManager

    init(
        store: ThemeStore = ThemeStore(),
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = ThemeStore.makeEncoder(),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.decoder = decoder
        self.encoder = encoder
        self.fileManager = fileManager
    }

    func importTheme(from url: URL, replaceExisting: Bool = false) throws -> ThemeImportResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = url.lastPathComponent
        if fileName.hasSuffix(Self.containerFileSuffix) {
            throw ThemeImportExportError.reservedContainerFormat
        }
        guard fileName.hasSuffix(Self.standaloneFileSuffix) || url.pathExtension.lowercased() == "json" else {
            throw ThemeImportExportError.invalidFilename
        }

        let data = try Data(contentsOf: url)
        let theme: AppTheme
        do {
            theme = try decoder.decode(AppTheme.self, from: data)
        } catch {
            throw ThemeImportExportError.malformedJSON
        }

        guard theme.schemaVersion == AppTheme.supportedSchemaVersion else {
            throw ThemeImportExportError.unsupportedSchemaVersion(theme.schemaVersion)
        }

        do {
            let item = try replaceExisting
                ? store.replaceUserTheme(theme)
                : store.saveUserTheme(theme, overwrite: false)
            return ThemeImportResult(item: item, replacedExistingTheme: replaceExisting)
        } catch ThemeStoreError.duplicateThemeID(let id) {
            throw ThemeImportExportError.duplicateThemeID(id)
        }
    }

    func exportTheme(_ theme: AppTheme) throws -> URL {
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent(exportFilename(for: theme), isDirectory: false)
        let data = try encoder.encode(theme)
        if fileManager.fileExists(atPath: tempURL.path) {
            try? fileManager.removeItem(at: tempURL)
        }
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    func exportFilename(for theme: AppTheme) -> String {
        let base = sanitizeFilenameComponent(theme.metadata.name)
        return "\(base)\(Self.standaloneFileSuffix)"
    }

    private func sanitizeFilenameComponent(_ rawName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = rawName.components(separatedBy: invalid)
        let joined = parts.joined(separator: "-")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "theme" : trimmed
    }
}
