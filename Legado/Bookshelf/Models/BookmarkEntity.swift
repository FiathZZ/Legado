import Foundation
import SwiftData

// MARK: - BookmarkEntity
/// 阅读书签持久化实体。
@Model
final class BookmarkEntity {
    @Attribute(.unique) var id: String
    var bookUrl: String
    var chapterIndex: Int
    var pageIndex: Int?
    var utf16Offset: Int?
    var chapterName: String
    var bookText: String
    var content: String
    var time: Date

    init(
        id: String = UUID().uuidString,
        bookUrl: String,
        chapterIndex: Int,
        pageIndex: Int? = nil,
        utf16Offset: Int? = nil,
        chapterName: String,
        bookText: String,
        content: String = "",
        time: Date = .now
    ) {
        self.id = id
        self.bookUrl = bookUrl
        self.chapterIndex = chapterIndex
        self.pageIndex = pageIndex
        self.utf16Offset = utf16Offset
        self.chapterName = chapterName
        self.bookText = bookText
        self.content = content
        self.time = time
    }
}

extension BookmarkEntity {
    var readerPosition: ReaderPosition {
        ReaderPosition(
            chapterIndex: chapterIndex,
            pageIndex: pageIndex ?? 0,
            utf16Offset: utf16Offset ?? 0
        )
    }
}
