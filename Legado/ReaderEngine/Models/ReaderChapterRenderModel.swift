import Foundation

/// Full render output for a chapter after pagination.
struct ReaderChapterRenderModel: Equatable, Sendable {
    var source: ReaderChapterSource
    var layout: ReaderLayoutConfiguration
    var attributedText: NSAttributedString
    var pages: [ReaderPage]

    var pageCount: Int {
        pages.count
    }

    func clampedPosition(_ position: ReadingPosition) -> ReadingPosition {
        let clampedPage = min(max(position.pageIndex, 0), max(pageCount - 1, 0))
        let pageRange = pages[safe: clampedPage]?.contentRange ?? NSRange(location: 0, length: 0)
        let upperBound = pageRange.location + pageRange.length
        let clampedOffset = min(max(position.utf16Offset, pageRange.location), upperBound)
        return ReadingPosition(chapterIndex: source.chapterIndex, pageIndex: clampedPage, utf16Offset: clampedOffset)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
