import Foundation

/// 替换净化规则（与安卓 legado ReplaceRule 字段对齐）
public nonisolated struct ReplaceRule: Codable, Identifiable, Hashable, Sendable {
    /// Keeps Android's numeric/string primary key stable when a rule is imported.
    /// Older iOS rules did not store one, so they retain the existing name/pattern key.
    public var sourceID: String?
    public var id: String { sourceID ?? name + pattern }

    public var name: String
    public var isEnabled: Bool
    public var isRegex: Bool
    public var pattern: String
    public var replacement: String
    public var scope: ReplaceScope
    /// Android `scope`: limits a rule to book names or source origins.
    public var matchScope: String?
    /// Android `excludeScope`: book names or source origins where the rule must not run.
    public var excludeScope: String?
    public var order: Int

    public nonisolated enum ReplaceScope: String, Codable, CaseIterable, Sendable {
        case content = "content"
        case title = "title"
        case all = "all"
        case none = "none"
    }

    public init(
        name: String = "",
        isEnabled: Bool = true,
        isRegex: Bool = true,
        pattern: String = "",
        replacement: String = "",
        scope: ReplaceScope = .content,
        matchScope: String? = nil,
        excludeScope: String? = nil,
        order: Int = 0,
        sourceID: String? = nil
    ) {
        self.sourceID = sourceID
        self.name = name
        self.isEnabled = isEnabled
        self.isRegex = isRegex
        self.pattern = pattern
        self.replacement = replacement
        self.scope = scope
        self.matchScope = matchScope
        self.excludeScope = excludeScope
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case isRegex
        case pattern
        case replacement
        case scope
        case order
        case regex
        case replaceSummary
        case useTo
        case enable
        case serialNumber
        case scopeTitle
        case scopeContent
        case excludeScope
    }

    /// Decodes both the current iOS export and Android Legado's replacement-rule formats.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            sourceID = stringID
        } else if let numberID = try? container.decode(Int.self, forKey: .id) {
            sourceID = String(numberID)
        } else {
            sourceID = nil
        }

        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .replaceSummary)
            ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .enable)
            ?? true
        isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? true
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
            ?? container.decodeIfPresent(String.self, forKey: .regex)
            ?? ""
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        order = try container.decodeIfPresent(Int.self, forKey: .order)
            ?? container.decodeIfPresent(Int.self, forKey: .serialNumber)
            ?? 0

        let rawScope = try container.decodeIfPresent(String.self, forKey: .scope)
        let legacyScope = try container.decodeIfPresent(String.self, forKey: .useTo)
        if let rawScope, let decodedScope = Self.scope(for: rawScope) {
            scope = decodedScope
        } else {
            let title = try container.decodeIfPresent(Bool.self, forKey: .scopeTitle) ?? false
            let content = try container.decodeIfPresent(Bool.self, forKey: .scopeContent) ?? true
            scope = Self.scope(title: title, content: content)
        }
        matchScope = rawScope.flatMap { Self.scope(for: $0) == nil ? $0 : nil } ?? legacyScope
        excludeScope = try container.decodeIfPresent(String.self, forKey: .excludeScope)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sourceID, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isRegex, forKey: .isRegex)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(matchScope, forKey: .useTo)
        try container.encodeIfPresent(excludeScope, forKey: .excludeScope)
        try container.encode(order, forKey: .order)
    }

    /// Imports one rule or an array from iOS exports and Android online subscriptions.
    public static func importRules(from text: String) throws -> [ReplaceRule] {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let rules = try? decoder.decode([ReplaceRule].self, from: data) {
            return rules.filter { !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let rule = try? decoder.decode(ReplaceRule.self, from: data),
           !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [rule]
        }
        throw ReplaceRuleImportError.unsupportedFormat
    }

    private static func scope(for rawValue: String) -> ReplaceScope? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case ReplaceScope.title.rawValue, "标题", "titleonly":
            return .title
        case ReplaceScope.content.rawValue, "正文", "contentonly":
            return .content
        case ReplaceScope.all.rawValue, "全部", "标题正文", "正文标题":
            return .all
        default:
            return nil
        }
    }

    private static func scope(title: Bool, content: Bool) -> ReplaceScope {
        if title && content { return .all }
        if title { return .title }
        if !content { return .none }
        return .content
    }

    /// Encodes fields that the existing SwiftData entity stores in one string, avoiding a schema migration.
    var storedScope: String {
        guard matchScope != nil || excludeScope != nil else { return scope.rawValue }
        return [scope.rawValue, matchScope ?? "", excludeScope ?? ""].joined(separator: "\u{001F}")
    }

    static func fromStoredScope(_ value: String) -> (scope: ReplaceScope, match: String?, exclude: String?) {
        let parts = value.components(separatedBy: "\u{001F}")
        guard parts.count == 3 else {
            return (ReplaceScope(rawValue: value) ?? .content, nil, nil)
        }
        return (
            ReplaceScope(rawValue: parts[0]) ?? .content,
            parts[1].isEmpty ? nil : parts[1],
            parts[2].isEmpty ? nil : parts[2]
        )
    }

    func applies(toBookName bookName: String, sourceName: String, sourceURL: String) -> Bool {
        guard scope != .none else { return false }
        let candidates = [bookName, sourceName, sourceURL].filter { !$0.isEmpty }
        if let excludeScope, candidates.contains(where: { excludeScope.contains($0) }) { return false }
        guard let matchScope, !matchScope.isEmpty else { return true }
        return candidates.contains(where: { matchScope.contains($0) })
    }
}

public enum ReplaceRuleImportError: LocalizedError {
    case unsupportedFormat

    public var errorDescription: String? {
        "替换规则 JSON 格式不受支持。"
    }
}
