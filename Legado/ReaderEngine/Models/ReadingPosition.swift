import Foundation

/// Engine-owned reading position used for pagination and relocation.
struct ReadingPosition: Equatable, Sendable, Codable {
    var chapterIndex: Int
    var pageIndex: Int
    var utf16Offset: Int

    init(chapterIndex: Int, pageIndex: Int = 0, utf16Offset: Int = 0) {
        self.chapterIndex = chapterIndex
        self.pageIndex = pageIndex
        self.utf16Offset = utf16Offset
    }
}
