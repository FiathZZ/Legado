import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ThemeFontReference: Codable, Hashable, Sendable {
    var postScriptName: String
    var bundledFileName: String?
    var packageIdentifier: String?

    static let pingFangRegular = ThemeFontReference(postScriptName: "PingFangSC-Regular")
    static let pingFangSemibold = ThemeFontReference(postScriptName: "PingFangSC-Semibold")
    static let menloRegular = ThemeFontReference(postScriptName: "Menlo-Regular")
}

struct ThemeTypography: Codable, Hashable, Sendable {
    var primary: ThemeFontReference
    var title: ThemeFontReference?
    var monospace: ThemeFontReference?
}

enum ThemeFontRole: Sendable {
    case primary
    case title
    case monospace
}

extension ThemeTypography {
    func font(for role: ThemeFontRole, size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let reference: ThemeFontReference?
        switch role {
        case .primary:
            reference = primary
        case .title:
            reference = title ?? primary
        case .monospace:
            reference = monospace ?? primary
        }

        guard let reference else {
            return fallbackFont(for: role, size: size, weight: weight)
        }

#if canImport(UIKit)
        if let uiFont = UIFont(name: reference.postScriptName, size: size) {
            return Font(uiFont)
        }
#elseif canImport(AppKit)
        if let nsFont = NSFont(name: reference.postScriptName, size: size) {
            return Font(nsFont)
        }
#endif

        return fallbackFont(for: role, size: size, weight: weight)
    }

    private func fallbackFont(for role: ThemeFontRole, size: CGFloat, weight: Font.Weight?) -> Font {
        switch role {
        case .monospace:
            return .system(size: size, weight: weight ?? .regular, design: .monospaced)
        case .title:
            return .system(size: size, weight: weight ?? .semibold, design: .default)
        case .primary:
            return .system(size: size, weight: weight ?? .regular, design: .default)
        }
    }
}
