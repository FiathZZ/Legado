import Foundation

/// Minimal chapter input consumed by the app-owned reader engine.
struct ReaderChapterSource: Equatable, Sendable {
    var bookID: String
    var chapterID: String
    var chapterIndex: Int
    var title: String
    var content: String

    init(
        bookID: String,
        chapterID: String,
        chapterIndex: Int,
        title: String,
        content: String
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.title = title
        self.content = content
    }
}
