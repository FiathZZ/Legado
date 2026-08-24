import SwiftUI

enum ThemePaletteGroup: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case surfaces
    case text
    case accents
    case feedback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome:
            return "应用框架"
        case .surfaces:
            return "容器与背景"
        case .text:
            return "文字"
        case .accents:
            return "强调与选择"
        case .feedback:
            return "状态反馈"
        }
    }
}

enum ThemePaletteToken: String, CaseIterable, Identifiable, Sendable {
    case appBackground
    case groupedBackground
    case surfaceBackground
    case secondarySurfaceBackground
    case cardBackground
    case cardOverlayBackground
    case navigationBackground
    case navigationTitle
    case navigationIcon
    case tabActive
    case tabInactive
    case primaryText
    case secondaryText
    case tertiaryText
    case accent
    case selectionFill
    case selectionText
    case selectionIcon
    case divider
    case success
    case warning
    case destructive
    case badgeBackground
    case badgeText
    case emptyStateIcon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appBackground:
            return "应用背景"
        case .groupedBackground:
            return "分组背景"
        case .surfaceBackground:
            return "主表面"
        case .secondarySurfaceBackground:
            return "次级表面"
        case .cardBackground:
            return "卡片背景"
        case .cardOverlayBackground:
            return "覆盖层背景"
        case .navigationBackground:
            return "导航栏背景"
        case .navigationTitle:
            return "导航标题"
        case .navigationIcon:
            return "导航图标"
        case .tabActive:
            return "标签激活"
        case .tabInactive:
            return "标签未激活"
        case .primaryText:
            return "主文字"
        case .secondaryText:
            return "次文字"
        case .tertiaryText:
            return "弱文字"
        case .accent:
            return "主强调"
        case .selectionFill:
            return "选中填充"
        case .selectionText:
            return "选中文字"
        case .selectionIcon:
            return "选中图标"
        case .divider:
            return "分割线"
        case .success:
            return "成功"
        case .warning:
            return "警告"
        case .destructive:
            return "危险"
        case .badgeBackground:
            return "徽标背景"
        case .badgeText:
            return "徽标文字"
        case .emptyStateIcon:
            return "空状态图标"
        }
    }

    var group: ThemePaletteGroup {
        switch self {
        case .navigationBackground, .navigationTitle, .navigationIcon, .tabActive, .tabInactive:
            return .chrome
        case .appBackground, .groupedBackground, .surfaceBackground, .secondarySurfaceBackground, .cardBackground, .cardOverlayBackground, .divider:
            return .surfaces
        case .primaryText, .secondaryText, .tertiaryText, .badgeText:
            return .text
        case .accent, .selectionFill, .selectionText, .selectionIcon, .badgeBackground, .emptyStateIcon:
            return .accents
        case .success, .warning, .destructive:
            return .feedback
        }
    }
}

struct ThemePalette: Codable, Hashable, Sendable {
    var appBackground: ThemeColor
    var groupedBackground: ThemeColor
    var surfaceBackground: ThemeColor
    var secondarySurfaceBackground: ThemeColor
    var cardBackground: ThemeColor
    var cardOverlayBackground: ThemeColor
    var navigationBackground: ThemeColor
    var navigationTitle: ThemeColor
    var navigationIcon: ThemeColor
    var tabActive: ThemeColor
    var tabInactive: ThemeColor
    var primaryText: ThemeColor
    var secondaryText: ThemeColor
    var tertiaryText: ThemeColor
    var accent: ThemeColor
    var selectionFill: ThemeColor
    var selectionText: ThemeColor
    var selectionIcon: ThemeColor
    var divider: ThemeColor
    var success: ThemeColor
    var warning: ThemeColor
    var destructive: ThemeColor
    var badgeBackground: ThemeColor
    var badgeText: ThemeColor
    var emptyStateIcon: ThemeColor

    subscript(token: ThemePaletteToken) -> ThemeColor {
        get {
            switch token {
            case .appBackground: return appBackground
            case .groupedBackground: return groupedBackground
            case .surfaceBackground: return surfaceBackground
            case .secondarySurfaceBackground: return secondarySurfaceBackground
            case .cardBackground: return cardBackground
            case .cardOverlayBackground: return cardOverlayBackground
            case .navigationBackground: return navigationBackground
            case .navigationTitle: return navigationTitle
            case .navigationIcon: return navigationIcon
            case .tabActive: return tabActive
            case .tabInactive: return tabInactive
            case .primaryText: return primaryText
            case .secondaryText: return secondaryText
            case .tertiaryText: return tertiaryText
            case .accent: return accent
            case .selectionFill: return selectionFill
            case .selectionText: return selectionText
            case .selectionIcon: return selectionIcon
            case .divider: return divider
            case .success: return success
            case .warning: return warning
            case .destructive: return destructive
            case .badgeBackground: return badgeBackground
            case .badgeText: return badgeText
            case .emptyStateIcon: return emptyStateIcon
            }
        }
        set {
            switch token {
            case .appBackground: appBackground = newValue
            case .groupedBackground: groupedBackground = newValue
            case .surfaceBackground: surfaceBackground = newValue
            case .secondarySurfaceBackground: secondarySurfaceBackground = newValue
            case .cardBackground: cardBackground = newValue
            case .cardOverlayBackground: cardOverlayBackground = newValue
            case .navigationBackground: navigationBackground = newValue
            case .navigationTitle: navigationTitle = newValue
            case .navigationIcon: navigationIcon = newValue
            case .tabActive: tabActive = newValue
            case .tabInactive: tabInactive = newValue
            case .primaryText: primaryText = newValue
            case .secondaryText: secondaryText = newValue
            case .tertiaryText: tertiaryText = newValue
            case .accent: accent = newValue
            case .selectionFill: selectionFill = newValue
            case .selectionText: selectionText = newValue
            case .selectionIcon: selectionIcon = newValue
            case .divider: divider = newValue
            case .success: success = newValue
            case .warning: warning = newValue
            case .destructive: destructive = newValue
            case .badgeBackground: badgeBackground = newValue
            case .badgeText: badgeText = newValue
            case .emptyStateIcon: emptyStateIcon = newValue
            }
        }
    }
}
