import Foundation

// MARK: - JSONPathParser
/// JSON Path 解析器
///
/// 支持的 JSON Path 格式（legado 规范）：
/// - `$.key` - 根对象的字段
/// - `$.array[*].key` - 数组遍历
/// - `$.array[0]` - 数组索引
/// - `$..key` - 递归搜索
/// - `@.key` - 相对路径（相对于当前节点）
///
/// 使用 Foundation 原生 JSON 解析实现，无需第三方库
public nonisolated struct JSONPathParser {

    // MARK: - 公开接口

    /// 从 JSON 字符串中按 JSON Path 规则提取字符串列表
    public static func getStringList(from json: String, rule: String) throws -> [String] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)
        guard let data = json.data(using: .utf8) else {
            throw ParserError.jsonPathError("无法将字符串转换为 Data")
        }
        let jsonObject = try JSONSerialization.jsonObject(with: data)

        if let inlineResults = try resolveInlineTemplate(rule: cleanedRule, object: jsonObject) {
            return inlineResults.compactMap { stringify($0) }
        }

        let results = try query(jsonObject, path: cleanedRule)
        return results.compactMap { stringify($0) }
    }

    /// 从 JSON 字符串中按 JSON Path 规则提取单个字符串
    public static func getString(from json: String, rule: String) throws -> String {
        let results = try getStringList(from: json, rule: rule)
        return results.first ?? ""
    }

    /// 从 JSON 字符串中按 JSON Path 规则提取原始对象列表
    public static func getObjects(from json: String, rule: String) throws -> [Any] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)
        guard let data = json.data(using: .utf8) else {
            throw ParserError.jsonPathError("无法将字符串转换为 Data")
        }
        let jsonObject = try JSONSerialization.jsonObject(with: data)

        if let inlineResults = try resolveInlineTemplate(rule: cleanedRule, object: jsonObject) {
            return inlineResults
        }

        return try query(jsonObject, path: cleanedRule)
    }

    /// 从已解析的 JSON 对象中按 JSON Path 规则提取对象列表
    public static func getObjects(fromObject object: Any, rule: String) throws -> [Any] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)

        if let inlineResults = try resolveInlineTemplate(rule: cleanedRule, object: object) {
            return inlineResults
        }

        return try query(object, path: cleanedRule)
    }

    /// 从已解析的 JSON 对象中提取字符串列表
    public static func getStringList(fromObject object: Any, rule: String) throws -> [String] {
        let results = try getObjects(fromObject: object, rule: rule)
        return results.compactMap { stringify($0) }
    }

    // MARK: - 内部查询引擎

    /// 处理 legado JSONPath 内嵌引用模板：`{$.path}` / `prefix-{$.a}`。
    private static func resolveInlineTemplate(rule: String, object: Any) throws -> [Any]? {
        guard rule.contains("{$") else { return nil }

        let pattern = #"\{(\$[^}]+)\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(rule.startIndex..., in: rule)
        let matches = regex.matches(in: rule, range: range)
        guard !matches.isEmpty else { return nil }

        if matches.count == 1,
           let fullRange = Range(matches[0].range(at: 0), in: rule),
           fullRange.lowerBound == rule.startIndex,
           fullRange.upperBound == rule.endIndex,
           let pathRange = Range(matches[0].range(at: 1), in: rule) {
            return try query(object, path: String(rule[pathRange]))
        }

        var rendered = rule
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: rendered),
                  let pathRange = Range(match.range(at: 1), in: rendered) else {
                continue
            }

            let path = String(rendered[pathRange])
            let value = try query(object, path: path).compactMap { stringify($0) }.first ?? ""
            rendered.replaceSubrange(fullRange, with: value)
        }

        return [rendered]
    }

    /// 核心查询方法：按 JSON Path 表达式查询 JSON 对象
    static func query(_ object: Any, path: String) throws -> [Any] {
        var currentPath = path.trimmingCharacters(in: .whitespaces)

        // 处理递归下降 `$..key`
        if currentPath.hasPrefix("$..") {
            let key = String(currentPath.dropFirst(3))
            // key may itself contain path components like `list[*]`
            if key.contains(".") || key.contains("[") {
                // evaluate remaining path on all recursive matches of first segment
                let dotIdx = key.firstIndex(of: ".") ?? key.endIndex
                let bracketIdx = key.firstIndex(of: "[") ?? key.endIndex
                let splitIdx = dotIdx < bracketIdx ? dotIdx : bracketIdx
                let firstKey = String(key[..<splitIdx])
                let rest = String(key[splitIdx...])
                let found = recursiveSearch(object, key: firstKey)
                guard !found.isEmpty else { return [] }

                // 对 `$..key[*]` / `$..key.child` 这类路径，Android legado 会把递归命中的每个节点
                // 分别继续向下求值再扁平化；不能先把所有命中聚成一个数组，否则 `[*]` 只会展开外层一层。
                if found.count == 1 {
                    return try query(found[0], path: "$" + rest)
                }

                if rest.hasPrefix(".") || rest.hasPrefix("[") {
                    return try found.flatMap { try query($0, path: "$" + rest) }
                } else {
                    return try found.flatMap { try query($0, path: "$" + rest) }
                }
            }
            return recursiveSearch(object, key: key)
        }

        // 处理 `$` 或 `@` 起始符
        if currentPath.hasPrefix("$.") {
            currentPath = String(currentPath.dropFirst(2))
        } else if currentPath.hasPrefix("$[") {
            currentPath = String(currentPath.dropFirst(1))
        } else if currentPath == "$" {
            return [object]
        } else if currentPath.hasPrefix("@.") {
            currentPath = String(currentPath.dropFirst(2))
        } else if currentPath == "@" {
            return [object]
        } else if currentPath.hasPrefix(".") {
            currentPath = String(currentPath.dropFirst(1))
        }
        // bare path like `data.books` or `items` — treat as relative path from root

        return try evaluate([object], pathComponents: parsePathComponents(currentPath))
    }

    /// 将 JSON Path 字符串拆分为路径组件列表
    private static func parsePathComponents(_ path: String) -> [String] {
        var components: [String] = []
        var current = ""
        var inBracket = false
        var index = path.startIndex

        while index < path.endIndex {
            let char = path[index]

            switch char {
            case "[":
                if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
                inBracket = true
                current.append(char)
            case "]":
                current.append(char)
                components.append(current)
                current = ""
                inBracket = false
            case "." where !inBracket:
                let nextIndex = path.index(after: index)
                if nextIndex < path.endIndex, path[nextIndex] == "." {
                    if !current.isEmpty {
                        components.append(current)
                        current = ""
                    }
                    current = ".."
                    index = nextIndex
                } else if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }

            index = path.index(after: index)
        }

        if !current.isEmpty {
            components.append(current)
        }
        return components
    }

    /// 递归遍历 JSON 对象列表，按路径组件逐步提取
    private static func evaluate(_ objects: [Any], pathComponents: [String]) throws -> [Any] {
        guard !pathComponents.isEmpty else { return objects }

        var remaining = pathComponents
        let component = remaining.removeFirst()

        var nextObjects: [Any] = []

        for object in objects {
            let extracted = try extract(from: object, component: component)
            nextObjects.append(contentsOf: extracted)
        }

        if remaining.isEmpty {
            return nextObjects
        }
        return try evaluate(nextObjects, pathComponents: remaining)
    }

    /// 从单个 JSON 对象中按一个路径组件提取值
    private static func extract(from object: Any, component: String) throws -> [Any] {
        // 处理递归下降 `..key`
        if component.hasPrefix("..") {
            let key = String(component.dropFirst(2))
            return recursiveSearch(object, key: key)
        }

        if component == "*" {
            if let dictionary = object as? [String: Any] {
                return Array(dictionary.values)
            }
            if let array = object as? [Any] {
                return array
            }
            return [object]
        }

        // 处理数组索引或通配符 `[*]`, `[0]`, `[0,1]`, `[-1]`
        if component.hasPrefix("[") && component.hasSuffix("]") {
            let inner = String(component.dropFirst().dropLast())
            return try extractArrayComponent(from: object, inner: inner)
        }

        // 处理普通键名
        if let dict = object as? [String: Any] {
            if let value = dict[component] {
                return [value]
            }
            return []
        }

        // 对象是数组时，对每个元素应用键提取
        if let array = object as? [Any] {
            return array.flatMap { element -> [Any] in
                if let dict = element as? [String: Any],
                   let value = dict[component] {
                    return [value]
                }
                return []
            }
        }

        return []
    }

    /// 处理数组组件（`[*]`, `[0]`, `[0,1]` 等）
    private static func extractArrayComponent(from object: Any, inner: String) throws -> [Any] {
        if inner == "*" {
            if let array = object as? [Any] { return array }
            if let dictionary = object as? [String: Any] {
                return Array(dictionary.values)
            }
            return [object]
        }

        guard let array = object as? [Any] else { return [] }

        if inner.hasPrefix("?("), inner.hasSuffix(")"),
           let filter = parseFilterExpression(String(inner.dropFirst(2).dropLast())) {
            return array.filter { candidate in
                guard let dictionary = candidate as? [String: Any],
                      let fieldValue = value(at: filter.keyPath, in: dictionary) else {
                    return false
                }

                let value = stringify(fieldValue) ?? "\(fieldValue)"
                switch filter.comparison {
                case .equals:
                    return value == filter.expectedValue
                case .notEquals:
                    return value != filter.expectedValue
                }
            }
        }

        if inner.contains(",") {
            // 多索引：`[0,1,2]`
            let indices = inner.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return indices.compactMap { idx -> Any? in
                let actualIdx = idx < 0 ? array.count + idx : idx
                guard actualIdx >= 0 && actualIdx < array.count else { return nil }
                return array[actualIdx]
            }
        }

        if inner.contains(":") {
            // 切片：`[0:3]`
            let parts = inner.components(separatedBy: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            let start = parts[0] ?? 0
            let end = parts.count > 1 ? (parts[1] ?? array.count) : array.count
            let actualStart = max(0, start < 0 ? array.count + start : start)
            let actualEnd = min(array.count, end < 0 ? array.count + end : end)
            if actualStart < actualEnd {
                return Array(array[actualStart..<actualEnd])
            }
            return []
        }

        // 单索引
        if let idx = Int(inner) {
            let actualIdx = idx < 0 ? array.count + idx : idx
            if actualIdx >= 0 && actualIdx < array.count {
                return [array[actualIdx]]
            }
        }

        return []
    }

    /// 递归搜索：在整个 JSON 树中查找指定键
    private static func recursiveSearch(_ object: Any, key: String) -> [Any] {
        var results: [Any] = []
        if let dict = object as? [String: Any] {
            if let value = dict[key] {
                results.append(value)
            }
            for (_, v) in dict {
                results.append(contentsOf: recursiveSearch(v, key: key))
            }
        } else if let array = object as? [Any] {
            for item in array {
                results.append(contentsOf: recursiveSearch(item, key: key))
            }
        }
        return results
    }

    private enum FilterComparison {
        case equals
        case notEquals
    }

    private struct FilterExpression {
        let keyPath: [String]
        let comparison: FilterComparison
        let expectedValue: String
    }

    private static func parseFilterExpression(_ expression: String) -> FilterExpression? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^@\.(.+?)\s*(==|!=)\s*(['"])(.*?)\3$"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let keyRange = Range(match.range(at: 1), in: trimmed),
              let operatorRange = Range(match.range(at: 2), in: trimmed),
              let valueRange = Range(match.range(at: 4), in: trimmed) else {
            return nil
        }

        let comparison: FilterComparison = String(trimmed[operatorRange]) == "!=" ? .notEquals : .equals
        return FilterExpression(
            keyPath: String(trimmed[keyRange])
                .split(separator: ".")
                .map { String($0) }
                .filter { !$0.isEmpty },
            comparison: comparison,
            expectedValue: String(trimmed[valueRange])
        )
    }

    private static func value(at keyPath: [String], in object: [String: Any]) -> Any? {
        guard let first = keyPath.first else { return nil }
        var current: Any? = object[first]
        guard keyPath.count > 1 else { return current }

        for key in keyPath.dropFirst() {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    // MARK: - 辅助方法

    /// 将任意 JSON 值转换为字符串
    static func stringify(_ value: Any) -> String? {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            // 布尔值检测：objCType 为 "c" 表示 Bool
            if String(cString: num.objCType) == "c" {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case is NSNull:
            return nil
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return nil
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return nil
        default:
            return "\(value)"
        }
    }
}
