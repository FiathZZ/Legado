import Foundation
import SwiftData

// MARK: - RuleSubEntity
/// 书源订阅持久化模型。
@Model
final class RuleSubEntity {
    @Attribute(.unique) var id: String
    var name: String
    var url: String
    var lastUpdateTime: Date?
    var autoUpdate: Bool
    var order: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        lastUpdateTime: Date? = nil,
        autoUpdate: Bool = true,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdateTime = lastUpdateTime
        self.autoUpdate = autoUpdate
        self.order = order
    }
}
