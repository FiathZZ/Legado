import Foundation
import SwiftData

@Model
final class ReplaceRuleEntity {
    @Attribute(.unique) var id: String
    var name: String
    var isEnabled: Bool
    var isRegex: Bool
    var pattern: String
    var replacement: String
    var scope: String
    var order: Int
    var addedTime: Date

    init(
        id: String,
        name: String,
        isEnabled: Bool,
        isRegex: Bool,
        pattern: String,
        replacement: String,
        scope: String,
        order: Int,
        addedTime: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.isRegex = isRegex
        self.pattern = pattern
        self.replacement = replacement
        self.scope = scope
        self.order = order
        self.addedTime = addedTime
    }

    convenience init(rule: ReplaceRule) {
        self.init(
            id: rule.id,
            name: rule.name,
            isEnabled: rule.isEnabled,
            isRegex: rule.isRegex,
            pattern: rule.pattern,
            replacement: rule.replacement,
            scope: rule.storedScope,
            order: rule.order
        )
    }

    func toReplaceRule() -> ReplaceRule {
        let storedScope = ReplaceRule.fromStoredScope(scope)
        return ReplaceRule(
            name: name,
            isEnabled: isEnabled,
            isRegex: isRegex,
            pattern: pattern,
            replacement: replacement,
            scope: storedScope.scope,
            matchScope: storedScope.match,
            excludeScope: storedScope.exclude,
            order: order,
            sourceID: id
        )
    }

    func update(from rule: ReplaceRule) {
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        isRegex = rule.isRegex
        pattern = rule.pattern
        replacement = rule.replacement
        scope = rule.storedScope
        order = rule.order
    }
}
