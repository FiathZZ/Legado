import UIKit

/// App-owned reader layout configuration used by the new engine.
struct ReaderLayoutConfiguration: Equatable, Sendable {
    var viewportSize: CGSize
    var contentInsets: UIEdgeInsets
    var fontName: String?
    var fontSize: CGFloat
    var titleFontIncrement: CGFloat
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var paragraphIndentCount: Int
    var letterSpacing: CGFloat

    init(
        viewportSize: CGSize,
        contentInsets: UIEdgeInsets = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16),
        fontName: String? = nil,
        fontSize: CGFloat = 18,
        titleFontIncrement: CGFloat = 8,
        lineSpacing: CGFloat = 7,
        paragraphSpacing: CGFloat = 15,
        paragraphIndentCount: Int = 2,
        letterSpacing: CGFloat = 0.1
    ) {
        self.viewportSize = viewportSize
        self.contentInsets = contentInsets
        self.fontName = fontName
        self.fontSize = fontSize
        self.titleFontIncrement = titleFontIncrement
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.paragraphIndentCount = paragraphIndentCount
        self.letterSpacing = letterSpacing
    }

    var textBounds: CGSize {
        CGSize(
            width: max(1, viewportSize.width - contentInsets.left - contentInsets.right),
            height: max(1, viewportSize.height - contentInsets.top - contentInsets.bottom)
        )
    }

    func normalizedBody(_ content: String) -> String {
        let paragraphs = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n")
    }

    func font(isTitle: Bool) -> UIFont {
        let resolvedSize = fontSize + (isTitle ? titleFontIncrement : 0)
        if let fontName, let font = UIFont(name: fontName, size: resolvedSize) {
            return font
        }
        if isTitle {
            return UIFont.systemFont(ofSize: resolvedSize, weight: .semibold)
        }
        return UIFont.systemFont(ofSize: resolvedSize)
    }

    func attributes(isTitle: Bool) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.0
        paragraphStyle.alignment = isTitle ? .center : .justified
        paragraphStyle.lineBreakMode = .byCharWrapping
        paragraphStyle.lineSpacing = isTitle ? 0 : lineSpacing
        paragraphStyle.paragraphSpacing = isTitle ? fontSize * 0.8 : paragraphSpacing
        if !isTitle {
            paragraphStyle.firstLineHeadIndent = font(isTitle: false).pointSize * CGFloat(paragraphIndentCount)
        }

        return [
            .font: font(isTitle: isTitle),
            .paragraphStyle: paragraphStyle,
            .kern: letterSpacing
        ]
    }
}
