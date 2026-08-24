import Foundation

// MARK: - RuleType
/// 规则类型枚举
public nonisolated enum RuleType {
    case css        // CSS 选择器（JSoup 风格）
    case xpath      // XPath 表达式
    case regex      // 正则表达式
    case jsonPath   // JSON Path
    case javascript // JavaScript 代码
    case `default`  // 根据内容自动判断
}

// MARK: - RuleMode
/// 规则获取模式
public nonisolated enum RuleMode {
    case string     // 返回字符串
    case stringList // 返回字符串列表
    case element    // 返回 HTML 元素
    case elementList// 返回 HTML 元素列表
}

// MARK: - ParsedRule
/// 解析后的单条规则
public nonisolated struct ParsedRule {
    public let ruleType: RuleType
    public let rule: String
    public let mode: RuleMode
}

// MARK: - RuleAnalyzer
/// 规则分析器：解析 legado 的规则语法
///
/// 支持的规则前缀：
/// - `@css:` - CSS 选择器
/// - `@xpath:` 或 `//` - XPath 表达式
/// - `@json:` 或 `$.` - JSON Path
/// - `@js:` 或 `<js>` - JavaScript
/// - `@@` - 结果拼接
/// - `&&` - 取交集（全部匹配时结果有效）
/// - `||` - 取并集（优先返回非空结果）
public nonisolated struct RuleAnalyzer {

    /// 组合规则拆分结果。
    public typealias SplitRuleResult = (operator: String, parts: [String])

    // MARK: - 规则分割

    /// 将组合规则按 `@@` 或 `&&` 或 `||` 分割为多个子规则
    /// - Parameter rule: 原始规则字符串
    /// - Returns: 子规则数组
    public static func splitRules(_ rule: String) -> [String] {
        splitRulesWithOperator(rule).parts
    }

    /// 将组合规则按顶层操作符拆分，并返回命中的操作符。
    ///
    /// 支持 `%%`、`@@`、`||`、`&&`，其中 `%%` 的优先探测顺序高于 `@@`，
    /// 以便调用方区分 legado 的交错合并语义。
    ///
    /// - Parameter rule: 原始规则字符串
    /// - Returns: `(operator, parts)` 元组；未命中时 `operator` 为空字符串
    public static func splitRulesWithOperator(_ rule: String) -> SplitRuleResult {
        let separators = ["%%", "@@", "||", "&&"]
        for separator in separators {
            if let parts = splitTopLevel(rule, separator: separator), parts.count > 1 {
                ParserLog.debug("RuleAnalyzer", "split operator=\(separator) parts=\(parts.count) rule=\(ParserLog.preview(rule))")
                return (separator, parts)
            }
        }
        return ("", [rule])
    }

    /// 按顶层分隔符拆分规则，忽略 `{{...}}` 模板内部的连接符
    public static func splitTopLevel(_ rule: String, separator: String) -> [String]? {
        guard !separator.isEmpty else { return nil }

        var parts: [String] = []
        var current = ""
        var index = rule.startIndex
        var templateDepth = 0

        while index < rule.endIndex {
            let nextIndex = rule.index(after: index)
            let remaining = rule[index...]

            if remaining.hasPrefix("{{") {
                templateDepth += 1
                current.append("{{")
                index = rule.index(index, offsetBy: 2)
                continue
            }

            if templateDepth > 0, remaining.hasPrefix("}}") {
                templateDepth = max(0, templateDepth - 1)
                current.append("}}")
                index = rule.index(index, offsetBy: 2)
                continue
            }

            if templateDepth == 0, remaining.hasPrefix(separator) {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                index = rule.index(index, offsetBy: separator.count)
                continue
            }

            current.append(rule[index])
            index = nextIndex
        }

        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    public static func containsTemplate(_ rule: String) -> Bool {
        rule.contains("{{") && rule.contains("}}")
    }

    /// 判断规则类型
    /// - Parameter rule: 规则字符串
    /// - Returns: 规则类型
    public static func ruleType(for rule: String) -> RuleType {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("@css:") {
            return .css
        } else if lower.hasPrefix("@xpath:") || trimmed.hasPrefix("//") {
            return .xpath
        } else if lower.hasPrefix("@json:") || trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[") {
            return .jsonPath
        } else if lower.hasPrefix("@js:") || trimmed.hasPrefix("<js>") {
            return .javascript
        } else if trimmed.hasPrefix(":") {
            // 以 `:` 开头为 CSS 伪类，当作 CSS 规则
            return .css
        } else {
            return .default
        }
    }

    /// 去除规则前缀，返回干净的规则表达式
    /// - Parameter rule: 原始规则字符串
    /// - Returns: 去除前缀后的规则
    public static func cleanRule(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("@css:") {
            return String(trimmed.dropFirst(5))
        } else if lower.hasPrefix("@xpath:") {
            return String(trimmed.dropFirst(7))
        } else if lower.hasPrefix("@json:") {
            return String(trimmed.dropFirst(6))
        } else if lower.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("<js>") && trimmed.hasSuffix("</js>") {
            // 去除 <js>...</js> 标签
            let inner = trimmed.dropFirst(4).dropLast(5)
            return String(inner)
        }
        return trimmed
    }

    /// 从规则中提取 JS 部分（@js: 或 <js>...</js> 块）
    /// - Parameter rule: 包含 JS 的规则字符串
    /// - Returns: (前置规则, JS代码) 元组，前置规则为 nil 表示整条都是 JS
    public static func extractJS(_ rule: String) -> (String?, String?) {
        if let jsRange = rule.range(of: "<js>"),
           let jsEndRange = rule.range(of: "</js>") {
            let prefix = String(rule[rule.startIndex..<jsRange.lowerBound])
            let jsCode = String(rule[jsRange.upperBound..<jsEndRange.lowerBound])
            let prefixTrimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            return (prefixTrimmed.isEmpty ? nil : prefixTrimmed, jsCode)
        }
        if rule.hasPrefix("@js:") {
            return (nil, String(rule.dropFirst(4)))
        }
        if let jsRange = rule.range(of: "@js:") {
            let prefix = String(rule[..<jsRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let jsCode = String(rule[jsRange.upperBound...])
            return (prefix.isEmpty ? nil : prefix, jsCode)
        }
        return (rule, nil)
    }

    /// 解析 CSS 属性提取规则，例如 `a@href`、`img@src`、`@text`、`@html`
    /// - Parameter rule: 含 `@` 属性的规则
    /// - Returns: (选择器, 属性名) 元组
    public static func parseCSSAttribute(_ rule: String) -> (selector: String, attribute: String) {
        // 找最后一个 @ 且前面不是数字（避免误解析邮箱等）
        let parts = rule.components(separatedBy: "@")
        if parts.count >= 2 {
            let attr = parts.last ?? ""
            let selector = parts.dropLast().joined(separator: "@")
            return (selector, attr)
        }
        return (rule, "text")
    }

    // MARK: - ## 正则替换提取

    /// 从规则中提取 `##` 替换模式（对应 legado 的 `makeUpRule` 逻辑）
    ///
    /// 格式：`rule##replaceRegex##replacement`
    /// - `rule##` - 提取后将结果整体替换为空（等同于删除匹配项）
    /// - `rule##regex##replacement` - 使用 `replacement` 替换匹配到的 `regex`
    ///
    /// 示例：
    /// - `a@href##/detail/(\d+)\.html##/book/$1` → 提取 href，并将匹配的路径转换
    /// - `a@href##https://##` → 提取 href，删除 `https://` 前缀
    /// - `img@src##//##https://` → 提取 src，把 `//` 替换为 `https://`
    ///
    /// - Returns: `(cleanRule, regex, replacement, replaceFirst)` 四元组；
    ///   若无 `##`，`regex` 为 `nil`
    public static func extractHashPattern(
        _ rule: String
    ) -> (cleanRule: String, regex: String?, replacement: String, replaceFirst: Bool) {
        var markers: [String.Index] = []
        var index = rule.startIndex
        var templateDepth = 0

        while index < rule.endIndex {
            let remaining = rule[index...]

            if remaining.hasPrefix("{{") {
                templateDepth += 1
                index = rule.index(index, offsetBy: 2)
                continue
            }

            if templateDepth > 0, remaining.hasPrefix("}}") {
                templateDepth = max(0, templateDepth - 1)
                index = rule.index(index, offsetBy: 2)
                continue
            }

            if templateDepth == 0, remaining.hasPrefix("##") {
                markers.append(index)
                index = rule.index(index, offsetBy: 2)
                if markers.count == 3 { break }
                continue
            }

            index = rule.index(after: index)
        }

        guard let firstMarker = markers.first else { return (rule, nil, "", false) }

        let cleanRule = String(rule[..<firstMarker])
        let regexStart = rule.index(firstMarker, offsetBy: 2)
        let regex: String
        let replacement: String
        let replaceFirst: Bool

        if markers.count >= 2 {
            let secondMarker = markers[1]
            regex = String(rule[regexStart..<secondMarker])
            if markers.count >= 3 {
                let thirdMarker = markers[2]
                let replacementStart = rule.index(secondMarker, offsetBy: 2)
                replacement = String(rule[replacementStart..<thirdMarker])
                replaceFirst = true
            } else {
                let replacementStart = rule.index(secondMarker, offsetBy: 2)
                replacement = String(rule[replacementStart...])
                replaceFirst = false
            }
        } else {
            regex = String(rule[regexStart...])
            replacement = ""
            replaceFirst = false
        }

        return (cleanRule, regex.isEmpty ? nil : regex, replacement, replaceFirst)
    }

    /// 对字符串列表应用 `##` 提取到的正则替换
    ///
    /// - Parameters:
    ///   - results: 待替换的字符串列表
    ///   - regex: 正则表达式字符串
    ///   - replacement: 替换字符串（支持 `$1`、`$2` 等捕获组引用）
    /// - Returns: 替换后的字符串列表（空结果过滤掉）
    public static func applyHashReplace(
        _ results: [String],
        regex: String,
        replacement: String,
        replaceFirst: Bool = false
    ) -> [String] {
        guard !regex.isEmpty else { return results }

        guard let nsRegex = try? NSRegularExpression(pattern: regex) else {
            if replaceFirst {
                return replacement.isEmpty ? [] : Array(repeating: replacement, count: results.count)
            }
            return results.map { $0.replacingOccurrences(of: regex, with: replacement) }
        }

        return results.compactMap { str -> String? in
            let replaced: String
            if replaceFirst {
                let fullRange = NSRange(str.startIndex..., in: str)
                guard let match = nsRegex.firstMatch(in: str, range: fullRange) else {
                    return nil
                }
                let matchString = (str as NSString).substring(with: match.range)
                let matchRange = NSRange(location: 0, length: (matchString as NSString).length)
                replaced = nsRegex.stringByReplacingMatches(
                    in: matchString,
                    range: matchRange,
                    withTemplate: replacement
                )
            } else {
                let range = NSRange(str.startIndex..., in: str)
                // $0 全匹配、$1 第一捕获组 等
                replaced = nsRegex.stringByReplacingMatches(in: str, range: range, withTemplate: replacement)
            }
            return replaced.isEmpty ? nil : replaced
        }
    }

    // MARK: - @get: 变量替换

    /// 将规则中的 `@get:{varName}` 替换为变量存储中对应的值
    ///
    /// 格式：`@get:{key}` — 从 variableStore 中读取 key 对应的值并内联替换
    /// 例如：`$.data.list@get:{tid}` → `$.data.list123`（若 tid=123）
    public static func substituteGetVariables(_ rule: String, variableStore: ParserVariableStore) -> String {
        guard rule.contains("@get:") else { return rule }
        // Pattern: @get:{varName}
        guard let regex = try? NSRegularExpression(pattern: #"@get:\{([^}]+)\}"#, options: .caseInsensitive) else {
            return rule
        }
        let nsRule = rule as NSString
        var result = rule
        var offset = 0
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        for match in matches {
            let fullRange = match.range(at: 0)
            let keyRange = match.range(at: 1)
            let key = nsRule.substring(with: keyRange)
            let value = variableStore.get(key)
            let adjustedRange = NSRange(location: fullRange.location + offset, length: fullRange.length)
            if let swiftRange = Range(adjustedRange, in: result) {
                result.replaceSubrange(swiftRange, with: value)
                offset += value.count - fullRange.length
            }
        }
        return result
    }

    // MARK: - @put: 选项处理

    /// 从规则中剥离 `@put:{...}` 选项，将键值对存入 variableStore，返回干净的规则
    ///
    /// 格式：`rule@put:{"key":"jsonpath"}` 或 `rule@put:{key:jsonpath}`
    /// 书源用此机制在解析字段时顺带存储变量供后续规则使用。
    public static func stripPutOptions(
        _ rule: String,
        content: String,
        variableStore: ParserVariableStore
    ) -> String {
        let (cleanRule, putMap) = extractPutOptions(rule)
        for (key, valueRule) in putMap {
            let extracted = (try? JSONPathParser.getStringList(from: content, rule: valueRule))?.first ?? valueRule
            variableStore.put(key, value: extracted)
        }
        return cleanRule
    }

    /// 从规则中抽离 `@put:{...}` 配置，但不立即求值。
    ///
    /// 这更贴近 Android legado 的行为：先记录变量映射，再在当前解析上下文里按规则求值并写入。
    public static func extractPutOptions(_ rule: String) -> (cleanRule: String, putMap: [String: String]) {
        guard let regex = try? NSRegularExpression(pattern: #"@put:(\{[^}]+?\})"#, options: .caseInsensitive) else {
            return (rule, [:])
        }

        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else {
            return (rule, [:])
        }

        var cleanRule = rule
        var putMap: [String: String] = [:]

        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            let jsonRange = match.range(at: 1)
            let optionStr = nsRule.substring(with: jsonRange)
            putMap.merge(parsePutMap(optionStr)) { _, new in new }
            if let range = Range(fullRange, in: cleanRule) {
                cleanRule.removeSubrange(range)
            }
        }

        return (cleanRule.trimmingCharacters(in: .whitespacesAndNewlines), putMap)
    }

    private static func parsePutMap(_ optionStr: String) -> [String: String] {
        if let data = optionStr.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var normalized: [String: String] = [:]
            for (key, value) in dict {
                normalized[key] = "\(value)"
            }
            return normalized
        }

        var result: [String: String] = [:]
        var inner = optionStr
        if inner.hasPrefix("{") { inner = String(inner.dropFirst()) }
        if inner.hasSuffix("}") { inner = String(inner.dropLast()) }
        for pair in inner.components(separatedBy: ",") {
            let kv = pair.components(separatedBy: ":")
            if kv.count >= 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let valueRule = kv[1...].joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                result[key] = valueRule
            }
        }
        return result
    }

    /// 将规则中的 `$0` / `$1` / `$2` 等替换为对应捕获组内容。
    public static func substituteRegexCaptures(_ rule: String, captures: [String]) -> String {
        guard rule.contains("$") else { return rule }

        var rendered = rule
        for index in stride(from: captures.count - 1, through: 0, by: -1) {
            rendered = rendered.replacingOccurrences(of: "$\(index)", with: captures[index])
        }
        return rendered
    }
}
