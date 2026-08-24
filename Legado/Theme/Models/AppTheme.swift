import Foundation

struct AppTheme: Codable, Hashable, Identifiable, Sendable {
    static let supportedSchemaVersion = 1

    struct Metadata: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var author: String
        var version: String
        var description: String?
    }

    var schemaVersion: Int
    var metadata: Metadata
    var palette: ThemePalette
    var typography: ThemeTypography

    var id: String { metadata.id }
    var name: String { metadata.name }
}

enum ThemeInstallSource: String, Codable, Hashable, Sendable {
    case bundled
    case user
}

struct ThemeCatalogItem: Identifiable, Hashable, Sendable {
    let theme: AppTheme
    let source: ThemeInstallSource
    let fileURL: URL

    var id: String { theme.id }
    var isBundled: Bool { source == .bundled }
}
