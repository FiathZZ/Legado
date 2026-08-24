import SwiftData
import Foundation

// MARK: - BookGroup
/// 书架分组模型。使用位掩码 `groupId` 与 `BookEntity.group` 建立多对多关系。
@Model
final class BookGroup {
    @Attribute(.unique) var groupId: Int64
    var groupName: String
    var order: Int
    var show: Bool
    var bookSort: Int?

    init(
        groupId: Int64,
        groupName: String,
        order: Int = 0,
        show: Bool = true,
        bookSort: Int? = nil
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.order = order
        self.show = show
        self.bookSort = bookSort
    }

    static func nextGroupID(existingIDs: [Int64]) -> Int64 {
        let positiveIDs = Set(existingIDs.filter { $0 > 0 })
        var candidate: Int64 = 1

        while positiveIDs.contains(candidate) && candidate <= Int64.max / 2 {
            candidate <<= 1
        }

        return positiveIDs.contains(candidate) ? 0 : candidate
    }
}
