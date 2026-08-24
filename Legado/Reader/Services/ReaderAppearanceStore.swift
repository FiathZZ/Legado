import Combine
import Foundation
import SwiftUI
import UIKit

enum ReaderThemePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case paper
    case mist
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper:
            return "纸张"
        case .mist:
            return "雾青"
        case .night:
            return "夜读"
        }
    }

    var backgroundColor: Color {
        Color(uiColor: uiBackgroundColor)
    }

    var textColor: Color {
        Color(uiColor: uiTextColor)
    }

    var chromeColor: Color {
        Color(uiColor: uiChromeColor)
    }

    var secondaryTextColor: Color {
        Color(uiColor: uiSecondaryTextColor)
    }

    var uiBackgroundColor: UIColor {
        switch self {
        case .paper:
            return UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1)
        case .mist:
            return UIColor(red: 0.88, green: 0.92, blue: 0.88, alpha: 1)
        case .night:
            return UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        }
    }

    var uiTextColor: UIColor {
        switch self {
        case .paper, .mist:
            return UIColor(red: 0.18, green: 0.16, blue: 0.14, alpha: 1)
        case .night:
            return UIColor(red: 0.88, green: 0.90, blue: 0.84, alpha: 1)
        }
    }

    var uiChromeColor: UIColor {
        switch self {
        case .paper:
            return UIColor.black.withAlphaComponent(0.72)
        case .mist:
            return UIColor(red: 0.12, green: 0.19, blue: 0.15, alpha: 0.78)
        case .night:
            return UIColor.black.withAlphaComponent(0.78)
        }
    }

    var uiSecondaryTextColor: UIColor {
        switch self {
        case .paper, .mist:
            return UIColor.black.withAlphaComponent(0.62)
        case .night:
            return UIColor.white.withAlphaComponent(0.68)
        }
    }
}

enum ReaderFlipMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case slide
    case fade
    case instant
    case scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slide:
            return "滑动"
        case .fade:
            return "淡入"
        case .instant:
            return "瞬切"
        case .scroll:
            return "上下滚动"
        }
    }

    var animation: Animation? {
        switch self {
        case .slide:
            return .easeInOut(duration: 0.22)
        case .fade:
            return .easeInOut(duration: 0.18)
        case .instant:
            return nil
        case .scroll:
            return nil
        }
    }
}

struct ReaderFontOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let fontName: String?
    let previewText: String
    let sourceTitle: String

    static let system = ReaderFontOption(
        id: "system",
        displayName: "系统默认",
        fontName: nil,
        previewText: "系统默认字体预览",
        sourceTitle: "默认"
    )

    static func available(libraryItems: [ThemeFontLibraryItem]) -> [ReaderFontOption] {
        var options: [ReaderFontOption] = [system]
        var seenFontNames: Set<String> = []

        let preferredInstalledFonts: [ReaderFontOption] = [
            ReaderFontOption(
                id: "installed-PingFangSC-Regular",
                displayName: "苹方",
                fontName: "PingFangSC-Regular",
                previewText: "苹方预览 Legado",
                sourceTitle: "系统"
            ),
            ReaderFontOption(
                id: "installed-TimesNewRomanPSMT",
                displayName: "Times New Roman",
                fontName: "TimesNewRomanPSMT",
                previewText: "Times New Roman Preview",
                sourceTitle: "系统"
            ),
            ReaderFontOption(
                id: "installed-Georgia",
                displayName: "Georgia",
                fontName: "Georgia",
                previewText: "Georgia Preview",
                sourceTitle: "系统"
            ),
            ReaderFontOption(
                id: "installed-ArialRoundedMTBold",
                displayName: "Arial Rounded",
                fontName: "ArialRoundedMTBold",
                previewText: "Arial Rounded Preview",
                sourceTitle: "系统"
            ),
            ReaderFontOption(
                id: "installed-Menlo-Regular",
                displayName: "Menlo",
                fontName: "Menlo-Regular",
                previewText: "Menlo Preview",
                sourceTitle: "系统"
            )
        ]

        for option in preferredInstalledFonts where isInstalled(postScriptName: option.fontName) {
            seenFontNames.insert(option.fontName ?? "")
            options.append(option)
        }

        for item in libraryItems where !seenFontNames.contains(item.postScriptName) {
            seenFontNames.insert(item.postScriptName)
            options.append(
                ReaderFontOption(
                    id: "library-\(item.postScriptName)",
                    displayName: item.displayName,
                    fontName: item.postScriptName,
                    previewText: item.previewText,
                    sourceTitle: item.source.title
                )
            )
        }

        for option in installedSystemFonts() where !seenFontNames.contains(option.fontName ?? "") {
            seenFontNames.insert(option.fontName ?? "")
            options.append(option)
        }

        return options
    }

    static func isInstalled(postScriptName: String?) -> Bool {
        guard let postScriptName, !postScriptName.isEmpty else { return true }
        return UIFont(name: postScriptName, size: 16) != nil
    }

    static func installedSystemFonts() -> [ReaderFontOption] {
        UIFont.familyNames
            .sorted(using: .localizedStandard)
            .flatMap { familyName in
                UIFont.fontNames(forFamilyName: familyName)
                    .sorted(using: .localizedStandard)
                    .compactMap { postScriptName -> ReaderFontOption? in
                        guard !postScriptName.hasPrefix("."),
                              !postScriptName.hasPrefix("SFUI"),
                              UIFont(name: postScriptName, size: 16) != nil else {
                            return nil
                        }

                        return ReaderFontOption(
                            id: "installed-\(postScriptName)",
                            displayName: familyName,
                            fontName: postScriptName,
                            previewText: familyName + " 预览 Legado",
                            sourceTitle: "系统"
                        )
                    }
            }
    }
}

struct ReaderAppearanceSettings: Equatable, Codable, Sendable {
    var theme: ReaderThemePreset
    var flipMode: ReaderFlipMode
    var fontName: String?
    var fontSize: Double
    var lineSpacing: Double
    var paragraphSpacing: Double
    var paragraphIndentCount: Int
    var horizontalPadding: Double
    var verticalPadding: Double
    var letterSpacing: Double

    static let `default` = ReaderAppearanceSettings(
        theme: .paper,
        flipMode: .slide,
        fontName: nil,
        fontSize: 19,
        lineSpacing: 6,
        paragraphSpacing: 5,
        paragraphIndentCount: 2,
        horizontalPadding: 18,
        verticalPadding: 12,
        letterSpacing: 0
    )

    func resolvedFontOption(in options: [ReaderFontOption]) -> ReaderFontOption {
        options.first(where: { $0.fontName == fontName }) ?? options[0]
    }

    func makeLayoutConfiguration(viewportSize: CGSize, safeAreaInsets: EdgeInsets) -> ReaderLayoutConfiguration {
        ReaderLayoutConfiguration(
            viewportSize: viewportSize,
            contentInsets: UIEdgeInsets(
                top: safeAreaInsets.top + verticalPadding,
                left: safeAreaInsets.leading + horizontalPadding,
                bottom: safeAreaInsets.bottom + verticalPadding,
                right: safeAreaInsets.trailing + horizontalPadding
            ),
            fontName: fontName,
            fontSize: fontSize,
            titleFontIncrement: max(6, fontSize * 0.32),
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            paragraphIndentCount: paragraphIndentCount,
            letterSpacing: letterSpacing
        )
    }
}

@MainActor
final class ReaderAppearanceStore: ObservableObject {
    @Published private(set) var settings: ReaderAppearanceSettings

    private let defaults: UserDefaults
    private let key = "reader.appearance.settings"
    private let layoutVersionKey = "reader.appearance.layoutVersion"
    private let currentLayoutVersion = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let requiresLayoutMigration = defaults.integer(forKey: layoutVersionKey) < currentLayoutVersion
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ReaderAppearanceSettings.self, from: data) {
            self.settings = requiresLayoutMigration ? Self.migrateLayout(decoded) : decoded
        } else {
            self.settings = .default
        }
        if requiresLayoutMigration {
            persist()
            defaults.set(currentLayoutVersion, forKey: layoutVersionKey)
        }
    }

    func update(_ transform: (inout ReaderAppearanceSettings) -> Void) {
        var next = settings
        transform(&next)
        settings = next
        persist()
    }

    func replace(with newSettings: ReaderAppearanceSettings) {
        settings = newSettings
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    private static func migrateLayout(_ settings: ReaderAppearanceSettings) -> ReaderAppearanceSettings {
        var migrated = settings
        migrated.lineSpacing = min(migrated.lineSpacing, 6)
        migrated.paragraphSpacing = min(migrated.paragraphSpacing, 6)
        migrated.horizontalPadding = max(migrated.horizontalPadding, 16)
        migrated.verticalPadding = max(migrated.verticalPadding, 10)
        if abs(migrated.letterSpacing - 0.12) < 0.001 {
            migrated.letterSpacing = 0
        }
        return migrated
    }
}
