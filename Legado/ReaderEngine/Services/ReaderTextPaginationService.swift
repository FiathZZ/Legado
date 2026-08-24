import Foundation
import UIKit

/// Pure text pagination for the new reader engine.
final class ReaderTextPaginationService {
    func paginate(
        source: ReaderChapterSource,
        configuration: ReaderLayoutConfiguration
    ) -> ReaderChapterRenderModel {
        let attributedText = makeAttributedText(for: source, configuration: configuration)
        let pages = makePages(
            chapterID: source.chapterID,
            attributedText: attributedText,
            configuration: configuration
        )

        return ReaderChapterRenderModel(
            source: source,
            layout: configuration,
            attributedText: attributedText,
            pages: pages
        )
    }

    private func makeAttributedText(
        for source: ReaderChapterSource,
        configuration: ReaderLayoutConfiguration
    ) -> NSAttributedString {
        let titleText = NSMutableAttributedString(
            string: "\(source.title)\n",
            attributes: configuration.attributes(isTitle: true)
        )
        let bodyText = NSMutableAttributedString(
            string: configuration.normalizedBody(source.content),
            attributes: configuration.attributes(isTitle: false)
        )
        titleText.append(bodyText)
        return titleText
    }

    private func makePages(
        chapterID: String,
        attributedText: NSAttributedString,
        configuration: ReaderLayoutConfiguration
    ) -> [ReaderPage] {
        guard attributedText.length > 0 else {
            return [
                ReaderPage(
                    chapterID: chapterID,
                    pageIndex: 0,
                    contentRange: NSRange(location: 0, length: 0),
                    attributedText: NSAttributedString(string: ""),
                    contentSize: configuration.textBounds,
                    extraHeaderHeight: 0
                )
            ]
        }

        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        var pages: [ReaderPage] = []
        var previousUpperBound = 0
        var pageIndex = 0

        while previousUpperBound < layoutManager.numberOfGlyphs || pageIndex == 0 {
            let textContainer = NSTextContainer(size: configuration.textBounds)
            textContainer.lineFragmentPadding = 0
            textContainer.maximumNumberOfLines = 0
            layoutManager.addTextContainer(textContainer)

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            guard characterRange.length > 0 || pageIndex == 0 else { break }

            let usedRect = layoutManager.usedRect(for: textContainer)
            let pageText = attributedText.attributedSubstring(from: characterRange)

            pages.append(
                ReaderPage(
                    chapterID: chapterID,
                    pageIndex: pageIndex,
                    contentRange: characterRange,
                    attributedText: pageText,
                    contentSize: usedRect.size,
                    extraHeaderHeight: max(0, configuration.contentInsets.top)
                )
            )

            let upperBound = characterRange.location + characterRange.length
            if upperBound <= previousUpperBound { break }

            previousUpperBound = upperBound
            pageIndex += 1
        }

        return pages
    }
}
