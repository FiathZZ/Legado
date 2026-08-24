import Foundation

enum BundledThemeCatalog {
    static let defaultThemeID = "Legado.classic"

    static let themes: [AppTheme] = [
        classic,
        moss
    ]

    static let classic = AppTheme(
        schemaVersion: AppTheme.supportedSchemaVersion,
        metadata: .init(
            id: "Legado.classic",
            name: "经典白昼",
            author: "Legado",
            version: "1.0.0",
            description: "贴近当前默认观感的浅色主题。"
        ),
        palette: ThemePalette(
            appBackground: ThemeColor(hex: "F5F6F8"),
            groupedBackground: ThemeColor(hex: "EEF1F6"),
            surfaceBackground: ThemeColor(hex: "FFFFFF"),
            secondarySurfaceBackground: ThemeColor(hex: "E7ECF3"),
            cardBackground: ThemeColor(hex: "FFFFFF"),
            cardOverlayBackground: ThemeColor(hex: "101725", opacity: 0.72),
            navigationBackground: ThemeColor(hex: "FFFFFF"),
            navigationTitle: ThemeColor(hex: "18202A"),
            navigationIcon: ThemeColor(hex: "425063"),
            tabActive: ThemeColor(hex: "2F6BFF"),
            tabInactive: ThemeColor(hex: "7B8796"),
            primaryText: ThemeColor(hex: "18202A"),
            secondaryText: ThemeColor(hex: "667180"),
            tertiaryText: ThemeColor(hex: "94A0AF"),
            accent: ThemeColor(hex: "2F6BFF"),
            selectionFill: ThemeColor(hex: "2F6BFF"),
            selectionText: ThemeColor(hex: "FFFFFF"),
            selectionIcon: ThemeColor(hex: "FFFFFF"),
            divider: ThemeColor(hex: "D9E0EA"),
            success: ThemeColor(hex: "2B9363"),
            warning: ThemeColor(hex: "D88916"),
            destructive: ThemeColor(hex: "D64545"),
            badgeBackground: ThemeColor(hex: "EAF1FF"),
            badgeText: ThemeColor(hex: "2F6BFF"),
            emptyStateIcon: ThemeColor(hex: "A8B3C2")
        ),
        typography: ThemeTypography(
            primary: .pingFangRegular,
            title: .pingFangSemibold,
            monospace: .menloRegular
        )
    )

    static let moss = AppTheme(
        schemaVersion: AppTheme.supportedSchemaVersion,
        metadata: .init(
            id: "Legado.moss",
            name: "苔原绿洲",
            author: "Legado",
            version: "1.0.0",
            description: "更偏纸感与植物色调的验证主题。"
        ),
        palette: ThemePalette(
            appBackground: ThemeColor(hex: "F4F1E6"),
            groupedBackground: ThemeColor(hex: "E8E2D2"),
            surfaceBackground: ThemeColor(hex: "FFF9ED"),
            secondarySurfaceBackground: ThemeColor(hex: "E2D8BF"),
            cardBackground: ThemeColor(hex: "FFFDF5"),
            cardOverlayBackground: ThemeColor(hex: "263123", opacity: 0.78),
            navigationBackground: ThemeColor(hex: "F6F0DE"),
            navigationTitle: ThemeColor(hex: "2D3826"),
            navigationIcon: ThemeColor(hex: "59674E"),
            tabActive: ThemeColor(hex: "4F7A4B"),
            tabInactive: ThemeColor(hex: "8E937A"),
            primaryText: ThemeColor(hex: "2D3826"),
            secondaryText: ThemeColor(hex: "6A735C"),
            tertiaryText: ThemeColor(hex: "9B9F88"),
            accent: ThemeColor(hex: "4F7A4B"),
            selectionFill: ThemeColor(hex: "4F7A4B"),
            selectionText: ThemeColor(hex: "F9F7F0"),
            selectionIcon: ThemeColor(hex: "F9F7F0"),
            divider: ThemeColor(hex: "D7CEB6"),
            success: ThemeColor(hex: "5B8F58"),
            warning: ThemeColor(hex: "B97A22"),
            destructive: ThemeColor(hex: "B24A40"),
            badgeBackground: ThemeColor(hex: "E2E9D8"),
            badgeText: ThemeColor(hex: "4F7A4B"),
            emptyStateIcon: ThemeColor(hex: "97A184")
        ),
        typography: ThemeTypography(
            primary: .pingFangRegular,
            title: .pingFangSemibold,
            monospace: .menloRegular
        )
    )
}
