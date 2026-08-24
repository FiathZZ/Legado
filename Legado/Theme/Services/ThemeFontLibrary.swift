import Foundation
import Combine
import CoreText
#if canImport(UIKit)
import UIKit
#endif

enum ThemeFontInstallSource: String, Codable, Hashable, Sendable {
    case bundled
    case imported
    case themePack

    var title: String {
        switch self {
        case .bundled:
            return "内置"
        case .imported:
            return "已导入"
        case .themePack:
            return "主题包"
        }
    }
}

struct ThemeFontLibraryItem: Identifiable, Codable, Hashable, Sendable {
    var displayName: String
    var postScriptName: String
    var fileName: String
    var relativePath: String?
    var source: ThemeFontInstallSource
    var previewText: String

    var id: String { postScriptName }

    var isBundled: Bool {
        source == .bundled
    }
}

enum ThemeFontLibraryError: LocalizedError {
    case invalidFontFile
    case fontFileMissing(String)
    case duplicateFont(String)
    case registerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFontFile:
            return "无法识别字体文件，请选择 .ttf 或 .otf。"
        case .fontFileMissing(let name):
            return "字体文件缺失：\(name)"
        case .duplicateFont(let name):
            return "字体“\(name)”已存在。"
        case .registerFailed(let message):
            return "字体注册失败：\(message)"
        }
    }
}

@MainActor
final class ThemeFontLibrary: ObservableObject {
    static let shared = ThemeFontLibrary()

    @Published private(set) var availableFonts: [ThemeFontLibraryItem] = []
    @Published private(set) var interfaceFontOverridePostScriptName: String?

    private let store: ThemeFontStore

    private init(store: ThemeFontStore = ThemeFontStore()) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            availableFonts = try store.loadFonts()
            interfaceFontOverridePostScriptName = resolvedOverride(store.interfaceFontOverridePostScriptName)
        } catch {
            availableFonts = []
            interfaceFontOverridePostScriptName = nil
        }
    }

    func importFont(from url: URL, source: ThemeFontInstallSource = .imported) throws -> ThemeFontLibraryItem {
        let item = try store.importFont(from: url, source: source)
        reload()
        return item
    }

    func applyInterfaceFontOverride(postScriptName: String?) {
        let resolved = resolvedOverride(postScriptName)
        store.interfaceFontOverridePostScriptName = resolved
        interfaceFontOverridePostScriptName = resolved
    }

    func resolveTypography(_ typography: ThemeTypography) -> ThemeTypography {
        let override = interfaceFontOverridePostScriptName.map { ThemeFontReference(postScriptName: $0) }
        return ThemeTypography(
            primary: override ?? fallbackReference(for: typography.primary) ?? typography.primary,
            title: override ?? fallbackReference(for: typography.title),
            monospace: fallbackReference(for: typography.monospace)
        )
    }

    func missingReferences(in typography: ThemeTypography) -> [ThemeFontReference] {
        [typography.primary, typography.title, typography.monospace]
            .compactMap { $0 }
            .filter { !isFontInstalled(postScriptName: $0.postScriptName) }
    }

    func displayName(for postScriptName: String) -> String {
        availableFonts.first(where: { $0.postScriptName == postScriptName })?.displayName ?? postScriptName
    }

    func isFontInstalled(postScriptName: String) -> Bool {
#if canImport(UIKit)
        UIFont(name: postScriptName, size: 14) != nil
#else
        false
#endif
    }

    private func fallbackReference(for reference: ThemeFontReference?) -> ThemeFontReference? {
        guard let reference, isFontInstalled(postScriptName: reference.postScriptName) else {
            return nil
        }
        return reference
    }

    private func resolvedOverride(_ postScriptName: String?) -> String? {
        guard let trimmed = postScriptName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              availableFonts.contains(where: { $0.postScriptName == trimmed }) else {
            return nil
        }
        return trimmed
    }
}

private struct ThemeFontStore {
    private static let interfaceFontOverrideKey = "theme.interfaceFontOverridePostScriptName"

    private struct ImportedFontRecord: Codable, Hashable {
        var displayName: String
        var postScriptName: String
        var fileName: String
        var relativePath: String
        var source: ThemeFontInstallSource
        var previewText: String
    }

    private struct BundledFontSeed {
        let displayName: String
        let fileName: String
        let previewText: String
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let userDefaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        encoder: JSONEncoder = ThemeStore.makeEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
        self.userDefaults = userDefaults
    }

    var interfaceFontOverridePostScriptName: String? {
        get { userDefaults.string(forKey: Self.interfaceFontOverrideKey) }
        nonmutating set { userDefaults.set(newValue, forKey: Self.interfaceFontOverrideKey) }
    }

    func loadFonts() throws -> [ThemeFontLibraryItem] {
        try bootstrap()

        let bundled = try bundledFontSeeds.compactMap { seed -> ThemeFontLibraryItem? in
            guard let item = try bundledItem(for: seed) else { return nil }
            return item
        }

        let imported = try importedRecords().compactMap { record -> ThemeFontLibraryItem? in
            let fileURL = importedFontsDirectory.appendingPathComponent(record.relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
            _ = try registerFont(at: fileURL)
            return ThemeFontLibraryItem(
                displayName: record.displayName,
                postScriptName: record.postScriptName,
                fileName: record.fileName,
                relativePath: record.relativePath,
                source: record.source,
                previewText: record.previewText
            )
        }

        return (bundled + imported).sorted {
            if $0.source != $1.source {
                return $0.source == .bundled
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func importFont(from externalURL: URL, source: ThemeFontInstallSource) throws -> ThemeFontLibraryItem {
        try bootstrap()
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = externalURL.pathExtension.lowercased()
        guard fileExtension == "ttf" || fileExtension == "otf" else {
            throw ThemeFontLibraryError.invalidFontFile
        }

        let destinationURL = importedFontsDirectory.appendingPathComponent(UUID().uuidString + "." + fileExtension, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: externalURL, to: destinationURL)

        do {
            let postScriptName = try registerFont(at: destinationURL)
            if try importedRecords().contains(where: { $0.postScriptName == postScriptName }) {
                throw ThemeFontLibraryError.duplicateFont(postScriptName)
            }

            let record = ImportedFontRecord(
                displayName: externalURL.deletingPathExtension().lastPathComponent,
                postScriptName: postScriptName,
                fileName: externalURL.lastPathComponent,
                relativePath: destinationURL.lastPathComponent,
                source: source,
                previewText: "界面字体预览 Legado"
            )
            var records = try importedRecords()
            records.append(record)
            try saveImportedRecords(records)
            return ThemeFontLibraryItem(
                displayName: record.displayName,
                postScriptName: record.postScriptName,
                fileName: record.fileName,
                relativePath: record.relativePath,
                source: record.source,
                previewText: record.previewText
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func bootstrap() throws {
        try fileManager.createDirectory(at: importedFontsDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: importedMetadataURL.path) {
            try saveImportedRecords([])
        }
    }

    private func bundledItem(for seed: BundledFontSeed) throws -> ThemeFontLibraryItem? {
        guard let fileURL = bundledFontURL(fileName: seed.fileName) else { return nil }
        let postScriptName = try registerFont(at: fileURL)
        return ThemeFontLibraryItem(
            displayName: seed.displayName,
            postScriptName: postScriptName,
            fileName: seed.fileName,
            relativePath: nil,
            source: .bundled,
            previewText: seed.previewText
        )
    }

    private func bundledFontURL(fileName: String) -> URL? {
        if let url = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "Theme/BundledFonts") {
            return url
        }
        let fallback = Bundle.main.resourceURL?.appendingPathComponent("Theme/BundledFonts/\(fileName)", isDirectory: false)
        guard let fallback, fileManager.fileExists(atPath: fallback.path) else { return nil }
        return fallback
    }

    private func registerFont(at fileURL: URL) throws -> String {
        guard let provider = CGDataProvider(url: fileURL as CFURL),
              let fontRef = CGFont(provider) else {
            throw ThemeFontLibraryError.invalidFontFile
        }

        guard let postScriptName = fontRef.postScriptName as String? else {
            throw ThemeFontLibraryError.registerFailed("缺少 PostScript 名称")
        }

        var errorRef: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterGraphicsFont(fontRef, &errorRef)
        if !registered, let errorRef {
            let error = errorRef.takeRetainedValue() as Error as NSError
            if error.domain != kCTFontManagerErrorDomain as String || error.code != CTFontManagerError.alreadyRegistered.rawValue {
                throw ThemeFontLibraryError.registerFailed(error.localizedDescription)
            }
        }

        return postScriptName
    }

    private func importedRecords() throws -> [ImportedFontRecord] {
        guard fileManager.fileExists(atPath: importedMetadataURL.path) else { return [] }
        let data = try Data(contentsOf: importedMetadataURL)
        return try decoder.decode([ImportedFontRecord].self, from: data)
    }

    private func saveImportedRecords(_ records: [ImportedFontRecord]) throws {
        let data = try encoder.encode(records)
        try data.write(to: importedMetadataURL, options: .atomic)
    }

    private var applicationSupportDirectory: URL {
        ThemeStore().applicationSupportDirectory
    }

    private var importedFontsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Theme/Fonts/Imported", isDirectory: true)
    }

    private var importedMetadataURL: URL {
        applicationSupportDirectory.appendingPathComponent("Theme/Fonts/imported-fonts.json", isDirectory: false)
    }

    private var bundledFontSeeds: [BundledFontSeed] {
        [
            BundledFontSeed(displayName: "霞鹜文楷", fileName: "霞鹜文楷.ttf", previewText: "霞鹜文楷预览 Legado"),
            BundledFontSeed(displayName: "庞门正道真贵楷体", fileName: "庞门正道真贵楷体.ttf", previewText: "庞门正道真贵楷体预览")
        ]
    }
}
