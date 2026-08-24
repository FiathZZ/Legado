import Foundation
import SwiftData

// MARK: - ReadRecordEntity
/// 按“日期 + 书籍”聚合的本地阅读统计实体。
@Model
final class ReadRecordEntity {
    @Attribute(.unique) var id: String
    var bookUrl: String
    var bookName: String
    var dateKey: String
    var durationSeconds: Int
    var chapterCount: Int
    var updatedAt: Date

    init(
        id: String,
        bookUrl: String,
        bookName: String,
        dateKey: String,
        durationSeconds: Int = 0,
        chapterCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.bookUrl = bookUrl
        self.bookName = bookName
        self.dateKey = dateKey
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
        self.updatedAt = updatedAt
    }
}
