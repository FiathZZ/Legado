import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ThemeColor: Codable, Hashable, Sendable {
    var hex: String
    var opacity: Double

    init(hex: String, opacity: Double = 1.0) {
        self.hex = ThemeColor.normalize(hex)
        self.opacity = opacity.clamped(to: 0...1)
    }

    var cssHex: String {
        "#\(hex)"
    }

    var swiftUIColor: Color {
#if canImport(UIKit)
        Color(uiColor: platformColor)
#elseif canImport(AppKit)
        Color(nsColor: platformColor)
#else
        Color.clear
#endif
    }

#if canImport(UIKit)
    var platformColor: UIColor {
        let components = Self.rgbComponents(for: hex)
        return UIColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: opacity
        )
    }

    init(color: Color) {
        self.init(platformColor: UIColor(color))
    }

    init(platformColor: UIColor) {
        let resolved = platformColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.hex = ThemeColor.hexString(red: red, green: green, blue: blue)
        self.opacity = Double(alpha)
    }
#elseif canImport(AppKit)
    var platformColor: NSColor {
        let components = Self.rgbComponents(for: hex)
        return NSColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: opacity
        )
    }

    init(color: Color) {
        self.init(platformColor: NSColor(color))
    }

    init(platformColor: NSColor) {
        let resolved = platformColor.usingColorSpace(.deviceRGB) ?? .black
        self.hex = ThemeColor.hexString(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
        self.opacity = Double(resolved.alphaComponent)
    }
#endif

    private static func normalize(_ rawHex: String) -> String {
        let cleaned = rawHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        if cleaned.count == 3 {
            return cleaned.map { "\($0)\($0)" }.joined()
        }
        if cleaned.count == 8 {
            return String(cleaned.prefix(6))
        }
        return cleaned.count == 6 ? cleaned : "000000"
    }

    private static func rgbComponents(for hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let normalized = normalize(hex)
        let scanner = Scanner(string: normalized)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else {
            return (0, 0, 0)
        }

        return (
            CGFloat((value & 0xFF0000) >> 16) / 255,
            CGFloat((value & 0x00FF00) >> 8) / 255,
            CGFloat(value & 0x0000FF) / 255
        )
    }

    private static func hexString(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        String(
            format: "%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
