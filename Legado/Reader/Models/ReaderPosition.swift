import Foundation

struct ReaderPosition: Equatable, Sendable, Codable {
    var chapterIndex: Int
    var pageIndex: Int
    var utf16Offset: Int

    init(chapterIndex: Int, pageIndex: Int = 0, utf16Offset: Int = 0) {
        self.chapterIndex = chapterIndex
        self.pageIndex = pageIndex
        self.utf16Offset = utf16Offset
    }

    init(enginePosition: ReadingPosition) {
        self.chapterIndex = enginePosition.chapterIndex
        self.pageIndex = enginePosition.pageIndex
        self.utf16Offset = enginePosition.utf16Offset
    }

    var enginePosition: ReadingPosition {
        ReadingPosition(
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            utf16Offset: utf16Offset
        )
    }
}

enum ReaderToolRoute: Equatable {
    case toc
    case changeSource
    case bookmarkList
    case bookSearch
}
