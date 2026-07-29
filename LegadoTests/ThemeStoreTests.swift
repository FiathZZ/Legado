import Foundation
import XCTest
@testable import Legado

final class ThemeStoreTests: XCTestCase {
    func testThemeStoreBootstrapsBundledThemesAndPersistsActiveSelection() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        let store = fixture.store
        try store.bootstrapStore()

        let themes = try store.loadThemes()
        XCTAssertGreaterThanOrEqual(themes.count, 2)
        XCTAssertEqual(store.activeThemeID, BundledThemeCatalog.defaultThemeID)

        let customTheme = makeCustomTheme(
            id: "test.custom-theme",
            name: "测试主题"
        )
        _ = try store.saveUserTheme(customTheme)
        store.setActiveThemeID(customTheme.id)

        let reloadedStore = fixture.makeStore()
        let reloadedThemes = try reloadedStore.loadThemes()
        XCTAssertTrue(reloadedThemes.contains(where: { $0.id == customTheme.id }))
        XCTAssertEqual(reloadedStore.activeThemeID, customTheme.id)
    }

    func testThemeImportExportRoundTripAndDuplicateConflict() throws {
        let sourceFixture = makeFixture()
        defer { sourceFixture.cleanup() }
        let targetFixture = makeFixture()
        defer { targetFixture.cleanup() }

        let sourceStore = sourceFixture.store
        try sourceStore.bootstrapStore()
        let sourceTheme = makeCustomTheme(
            id: "test.import-export",
            name: "导入导出主题"
        )
        _ = try sourceStore.saveUserTheme(sourceTheme)

        let sourceManager = ThemeImportExportManager(store: sourceStore)
        let exportedURL = try sourceManager.exportTheme(sourceTheme)
        defer { try? FileManager.default.removeItem(at: exportedURL) }

        let targetStore = targetFixture.store
        try targetStore.bootstrapStore()
        let targetManager = ThemeImportExportManager(store: targetStore)

        let imported = try targetManager.importTheme(from: exportedURL)
        XCTAssertEqual(imported.item.theme.metadata.name, sourceTheme.metadata.name)
        XCTAssertEqual(imported.item.id, sourceTheme.id)

        XCTAssertThrowsError(try targetManager.importTheme(from: exportedURL)) { error in
            guard case ThemeImportExportError.duplicateThemeID(let id) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(id, sourceTheme.id)
        }
    }

    private func makeCustomTheme(id: String, name: String) -> AppTheme {
        AppTheme(
            schemaVersion: AppTheme.supportedSchemaVersion,
            metadata: .init(
                id: id,
                name: name,
                author: "Tests",
                version: "1.0.0",
                description: "测试主题"
            ),
            palette: BundledThemeCatalog.moss.palette,
            typography: BundledThemeCatalog.moss.typography
        )
    }

    private func makeFixture() -> ThemeStoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-store-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "ThemeStoreTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return ThemeStoreFixture(baseDirectory: directory, userDefaults: userDefaults, suiteName: suiteName)
    }
}

private struct ThemeStoreFixture {
    let baseDirectory: URL
    let userDefaults: UserDefaults
    let suiteName: String

    var store: ThemeStore {
        makeStore()
    }

    func makeStore() -> ThemeStore {
        ThemeStore(
            fileManager: .default,
            decoder: JSONDecoder(),
            userDefaults: userDefaults,
            baseDirectory: baseDirectory
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDirectory)
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}
