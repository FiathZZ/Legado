import Foundation

enum ThemeStoreError: LocalizedError {
    case duplicateThemeID(String)
    case invalidThemeID
    case themeNotFound(String)
    case bundledThemeMutationNotAllowed

    var errorDescription: String? {
        switch self {
        case .duplicateThemeID(let id):
            return "主题 ID “\(id)” 已存在。"
        case .invalidThemeID:
            return "主题 ID 不能为空。"
        case .themeNotFound(let id):
            return "未找到主题 “\(id)”。"
        case .bundledThemeMutationNotAllowed:
            return "系统内置主题不能直接覆盖，请另存为新主题。"
        }
    }
}

struct ThemeStore {
    static let activeThemeIDKey = "theme.activeThemeID"

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let userDefaults: UserDefaults
    private let baseDirectory: URL?

    init(
        fileManager: FileManager = .default,
        encoder: JSONEncoder = ThemeStore.makeEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        userDefaults: UserDefaults = .standard,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
        self.userDefaults = userDefaults
        self.baseDirectory = baseDirectory
    }

    func bootstrapStore() throws {
        try fileManager.createDirectory(at: bundledThemesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)

        for theme in BundledThemeCatalog.themes {
            let url = bundledThemesDirectory.appendingPathComponent(filename(for: theme), isDirectory: false)
            let data = try encoder.encode(theme)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
        }

        if activeThemeID == nil {
            setActiveThemeID(BundledThemeCatalog.defaultThemeID)
        }
    }

    func loadThemes() throws -> [ThemeCatalogItem] {
        try bootstrapStore()
        let bundled = try loadThemes(in: bundledThemesDirectory, source: .bundled)
        let user = try loadThemes(in: userThemesDirectory, source: .user)
        return (bundled + user).sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source == .bundled
            }
            return lhs.theme.name.localizedStandardCompare(rhs.theme.name) == .orderedAscending
        }
    }

    func theme(for id: String) throws -> ThemeCatalogItem {
        try loadThemes().first(where: { $0.id == id }).unwrap(or: ThemeStoreError.themeNotFound(id))
    }

    func saveUserTheme(_ theme: AppTheme, overwrite: Bool = false) throws -> ThemeCatalogItem {
        let normalizedTheme = try validate(theme)
        try bootstrapStore()

        if let existing = try? self.theme(for: normalizedTheme.id) {
            if existing.isBundled {
                throw ThemeStoreError.bundledThemeMutationNotAllowed
            }
            if !overwrite {
                throw ThemeStoreError.duplicateThemeID(normalizedTheme.id)
            }
        }

        let url = userThemesDirectory.appendingPathComponent(filename(for: normalizedTheme), isDirectory: false)
        let data = try encoder.encode(normalizedTheme)
        try data.write(to: url, options: .atomic)
        return ThemeCatalogItem(theme: normalizedTheme, source: .user, fileURL: url)
    }

    func replaceUserTheme(_ theme: AppTheme) throws -> ThemeCatalogItem {
        try saveUserTheme(theme, overwrite: true)
    }

    func deleteUserThemes(ids: Set<String>) throws {
        let themes = try loadThemes()
        for item in themes where ids.contains(item.id) && item.source == .user {
            try? fileManager.removeItem(at: item.fileURL)
        }
    }

    func setActiveThemeID(_ id: String) {
        userDefaults.set(id, forKey: Self.activeThemeIDKey)
    }

    var activeThemeID: String? {
        userDefaults.string(forKey: Self.activeThemeIDKey)
    }

    func restoreBundledThemes() throws {
        try bootstrapStore()
    }

    var applicationSupportDirectory: URL {
        if let baseDirectory {
            return baseDirectory
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Legado", isDirectory: true)
    }

    var bundledThemesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Themes/Bundled", isDirectory: true)
    }

    var userThemesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Themes/User", isDirectory: true)
    }

    func filename(for theme: AppTheme) -> String {
        "\(theme.id).Legado-theme.json"
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func loadThemes(in directory: URL, source: ThemeInstallSource) throws -> [ThemeCatalogItem] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.lastPathComponent.hasSuffix(".Legado-theme.json") }
            .map { url in
                let data = try Data(contentsOf: url)
                let theme = try decoder.decode(AppTheme.self, from: data)
                return ThemeCatalogItem(theme: try validate(theme), source: source, fileURL: url)
            }
    }

    private func validate(_ theme: AppTheme) throws -> AppTheme {
        guard theme.schemaVersion == AppTheme.supportedSchemaVersion else {
            return theme
        }
        let trimmedID = theme.metadata.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw ThemeStoreError.invalidThemeID
        }
        var normalized = theme
        normalized.metadata.id = trimmedID
        normalized.metadata.name = theme.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}
