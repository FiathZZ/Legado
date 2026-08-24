import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct ThemeImportAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let themeID: String?
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published private(set) var currentTheme: AppTheme = BundledThemeCatalog.classic
    @Published private(set) var availableThemes: [ThemeCatalogItem] = []
    @Published private(set) var activeThemeID: String = BundledThemeCatalog.defaultThemeID
    @Published private(set) var chromeRefreshToken = UUID()
    @Published private(set) var availableFonts: [ThemeFontLibraryItem] = []
    @Published private(set) var interfaceFontOverridePostScriptName: String?
    @Published var importAlertState: ThemeImportAlertState?

    private let store: ThemeStore
    private let importExportManager: ThemeImportExportManager
    private let fontLibrary: ThemeFontLibrary
    private var persistedThemeIDBeforePreview: String?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        self.store = ThemeStore()
        self.importExportManager = ThemeImportExportManager(store: self.store)
        self.fontLibrary = .shared
        bindFontLibrary()
        reload()
    }

    init(store: ThemeStore) {
        self.store = store
        self.importExportManager = ThemeImportExportManager(store: store)
        self.fontLibrary = .shared
        bindFontLibrary()
        reload()
    }

    func reload() {
        availableFonts = fontLibrary.availableFonts
        interfaceFontOverridePostScriptName = fontLibrary.interfaceFontOverridePostScriptName
        do {
            availableThemes = try store.loadThemes()
            let resolvedActiveID = resolvedActiveThemeID()
            activeThemeID = resolvedActiveID
            currentTheme = availableThemes.first(where: { $0.id == resolvedActiveID })?.theme ?? BundledThemeCatalog.classic
            applyAppearance()
            refreshChrome()
        } catch {
            currentTheme = BundledThemeCatalog.classic
            activeThemeID = BundledThemeCatalog.defaultThemeID
            availableThemes = BundledThemeCatalog.themes.enumerated().map { index, theme in
                ThemeCatalogItem(
                    theme: theme,
                    source: .bundled,
                    fileURL: store.bundledThemesDirectory.appendingPathComponent("fallback-\(index).json", isDirectory: false)
                )
            }
            applyAppearance()
            refreshChrome()
        }
    }

    func applyTheme(id: String) {
        guard let item = availableThemes.first(where: { $0.id == id }) else { return }
        activeThemeID = id
        currentTheme = item.theme
        store.setActiveThemeID(id)
        persistedThemeIDBeforePreview = nil
        applyAppearance()
        refreshChrome()
    }

    func preview(theme: AppTheme) {
        if persistedThemeIDBeforePreview == nil {
            persistedThemeIDBeforePreview = activeThemeID
        }
        currentTheme = theme
        applyAppearance()
    }

    func resetPreview() {
        let targetID = persistedThemeIDBeforePreview ?? activeThemeID
        persistedThemeIDBeforePreview = nil
        applyTheme(id: targetID)
    }

    func restoreBundledThemes() throws {
        try store.restoreBundledThemes()
        reload()
    }

    func installTheme(from url: URL, applyImmediately: Bool = false, replaceExisting: Bool = false) throws -> ThemeCatalogItem {
        let result = try importExportManager.importTheme(from: url, replaceExisting: replaceExisting)
        reload()
        if applyImmediately {
            applyTheme(id: result.item.id)
        }
        return result.item
    }

    func handleIncomingThemeFile(_ url: URL) {
        do {
            let item = try installTheme(from: url, applyImmediately: false, replaceExisting: false)
            importAlertState = ThemeImportAlertState(
                title: "主题已导入",
                message: "“\(item.theme.metadata.name)” 已安装，现在可立即切换。",
                themeID: item.id
            )
        } catch {
            importAlertState = ThemeImportAlertState(
                title: "主题导入失败",
                message: error.localizedDescription,
                themeID: nil
            )
        }
    }

    func exportURL(for themeID: String) throws -> URL {
        let item = try store.theme(for: themeID)
        return try importExportManager.exportTheme(item.theme)
    }

    func saveEditedTheme(_ theme: AppTheme, overwrite: Bool) throws -> ThemeCatalogItem {
        let item = try overwrite ? store.replaceUserTheme(theme) : store.saveUserTheme(theme, overwrite: false)
        reload()
        applyTheme(id: item.id)
        return item
    }

    func saveThemeCopy(_ theme: AppTheme, basedOn original: ThemeCatalogItem?) throws -> ThemeCatalogItem {
        let copiedMetadata = AppTheme.Metadata(
            id: uniqueUserThemeID(from: original?.id ?? theme.id),
            name: "\(theme.metadata.name) 副本",
            author: theme.metadata.author,
            version: theme.metadata.version,
            description: theme.metadata.description
        )
        let copiedTheme = AppTheme(
            schemaVersion: theme.schemaVersion,
            metadata: copiedMetadata,
            palette: theme.palette,
            typography: theme.typography
        )
        let item = try store.saveUserTheme(copiedTheme, overwrite: false)
        reload()
        applyTheme(id: item.id)
        return item
    }

    func deleteThemes(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        let previousActiveID = activeThemeID
        try store.deleteUserThemes(ids: ids)
        reload()
        if ids.contains(previousActiveID), !availableThemes.contains(where: { $0.id == previousActiveID }) {
            applyTheme(id: fallbackThemeID(excluding: ids))
        }
    }

    func dismissImportAlert() {
        importAlertState = nil
    }

    func color(_ token: ThemePaletteToken) -> Color {
        currentTheme.palette[token].swiftUIColor
    }

    func softColor(_ token: ThemePaletteToken, opacity: Double = 0.15) -> Color {
        var themeColor = currentTheme.palette[token]
        themeColor.opacity = opacity
        return themeColor.swiftUIColor
    }

    func font(_ role: ThemeFontRole, size: CGFloat, weight: Font.Weight? = nil) -> Font {
        resolvedTypography.font(for: role, size: size, weight: weight)
    }

    func previewFont(postScriptName: String, size: CGFloat, weight: Font.Weight? = nil) -> Font {
        ThemeTypography(
            primary: ThemeFontReference(postScriptName: postScriptName),
            title: ThemeFontReference(postScriptName: postScriptName),
            monospace: currentTheme.typography.monospace
        )
        .font(for: .primary, size: size, weight: weight)
    }

    func item(for id: String) -> ThemeCatalogItem? {
        availableThemes.first(where: { $0.id == id })
    }

    func fontDisplayName(for postScriptName: String) -> String {
        fontLibrary.displayName(for: postScriptName)
    }

    func applyInterfaceFont(postScriptName: String?) {
        fontLibrary.applyInterfaceFontOverride(postScriptName: postScriptName)
        availableFonts = fontLibrary.availableFonts
        interfaceFontOverridePostScriptName = fontLibrary.interfaceFontOverridePostScriptName
        applyAppearance()
        refreshChrome()
    }

    func importFont(from url: URL, source: ThemeFontInstallSource = .imported) throws -> ThemeFontLibraryItem {
        let item = try fontLibrary.importFont(from: url, source: source)
        availableFonts = fontLibrary.availableFonts
        interfaceFontOverridePostScriptName = fontLibrary.interfaceFontOverridePostScriptName
        applyAppearance()
        refreshChrome()
        return item
    }

    func handleIncomingFontFile(_ url: URL) {
        do {
            let item = try importFont(from: url)
            importAlertState = ThemeImportAlertState(
                title: "字体已导入",
                message: "“\(item.displayName)” 已安装，可在字体库中立即应用。",
                themeID: nil
            )
        } catch {
            importAlertState = ThemeImportAlertState(
                title: "字体导入失败",
                message: error.localizedDescription,
                themeID: nil
            )
        }
    }

    var missingTypographyReferences: [ThemeFontReference] {
        fontLibrary.missingReferences(in: currentTheme.typography)
    }

    private var resolvedTypography: ThemeTypography {
        fontLibrary.resolveTypography(currentTheme.typography)
    }

    private func resolvedActiveThemeID() -> String {
        let requestedID = store.activeThemeID ?? BundledThemeCatalog.defaultThemeID
        if availableThemes.contains(where: { $0.id == requestedID }) {
            return requestedID
        }
        store.setActiveThemeID(BundledThemeCatalog.defaultThemeID)
        return BundledThemeCatalog.defaultThemeID
    }

    private func fallbackThemeID(excluding ids: Set<String>) -> String {
        availableThemes
            .first(where: { !ids.contains($0.id) })?
            .id ?? BundledThemeCatalog.defaultThemeID
    }

    private func uniqueUserThemeID(from base: String) -> String {
        let existingIDs = Set(availableThemes.map(\.id))
        let normalizedBase = "\(base).copy"
        var candidate = normalizedBase
        var index = 2
        while existingIDs.contains(candidate) {
            candidate = "\(normalizedBase).\(index)"
            index += 1
        }
        return candidate
    }

    private func applyAppearance() {
#if canImport(UIKit)
        let navigationAppearance = makeNavigationBarAppearance()
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        UINavigationBar.appearance().tintColor = currentTheme.palette.navigationIcon.platformColor

        let tabAppearance = makeTabBarAppearance()
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = currentTheme.palette.tabActive.platformColor
        UITabBar.appearance().unselectedItemTintColor = currentTheme.palette.tabInactive.platformColor
#endif
    }

    private func refreshChrome() {
        chromeRefreshToken = UUID()
    }

    private func bindFontLibrary() {
        fontLibrary.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                availableFonts = fontLibrary.availableFonts
                interfaceFontOverridePostScriptName = fontLibrary.interfaceFontOverridePostScriptName
                objectWillChange.send()
                refreshChrome()
            }
            .store(in: &cancellables)
    }

#if canImport(UIKit)
    func applyNavigationAppearance(to navigationBar: UINavigationBar) {
        let appearance = makeNavigationBarAppearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.tintColor = currentTheme.palette.navigationIcon.platformColor
    }

    func applyTabAppearance(to tabBar: UITabBar) {
        let appearance = makeTabBarAppearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = currentTheme.palette.tabActive.platformColor
        tabBar.unselectedItemTintColor = currentTheme.palette.tabInactive.platformColor
    }

    private func makeNavigationBarAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = currentTheme.palette.navigationBackground.platformColor
        appearance.titleTextAttributes = [.foregroundColor: currentTheme.palette.navigationTitle.platformColor]
        appearance.largeTitleTextAttributes = [.foregroundColor: currentTheme.palette.navigationTitle.platformColor]
        appearance.shadowColor = currentTheme.palette.divider.platformColor
        return appearance
    }

    private func makeTabBarAppearance() -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = currentTheme.palette.navigationBackground.platformColor

        let selected = appearance.stackedLayoutAppearance.selected
        selected.iconColor = currentTheme.palette.tabActive.platformColor
        selected.titleTextAttributes = [.foregroundColor: currentTheme.palette.tabActive.platformColor]

        let normal = appearance.stackedLayoutAppearance.normal
        normal.iconColor = currentTheme.palette.tabInactive.platformColor
        normal.titleTextAttributes = [.foregroundColor: currentTheme.palette.tabInactive.platformColor]
        return appearance
    }
#endif
}
