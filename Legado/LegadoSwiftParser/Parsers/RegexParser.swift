import Foundation

// MARK: - RegexParser
/// 正则表达式解析器
///
/// legado 正则规则格式：
/// - `##pattern##replacement` - 匹配并替换
/// - `##pattern` - 只匹配，返回第 1 个捕获组
/// - `pattern##replacement` - 匹配替换
///
/// 规则链：多条正则用 `\n` 分隔依次处理
public nonisolated struct RegexParser {

    // MARK: - 字符串提取

    /// 从文本中按正则规则提取字符串列表
    /// - Parameters:
    ///   - text: 输入文本
    ///   - rule: 正则规则（支持 `##` 分隔的模式和替换）
    /// - Returns: 匹配的字符串列表
    public static func getStringList(from text: String, rule: String) throws -> [String] {
        let (pattern, replacement) = parseRule(rule)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            throw ParserError.regexError("无法编译正则表达式: \(pattern)")
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)

        return matches.compactMap { match -> String? in
            if let replacement = replacement {
                // 有替换模式：对匹配到的字符串执行替换
                let matchRange = match.range
                let matchedString = nsText.substring(with: matchRange)
                let matchRange2 = NSRange(location: 0, length: (matchedString as NSString).length)
                return regex.stringByReplacingMatches(in: matchedString, range: matchRange2, withTemplate: replacement)
            } else {
                // 无替换：返回第一个捕获组，没有捕获组则返回整个匹配
                if match.numberOfRanges > 1 {
                    let captureRange = match.range(at: 1)
                    if captureRange.location != NSNotFound {
                        return nsText.substring(with: captureRange)
                    }
                }
                return nsText.substring(with: match.range)
            }
        }
    }

    /// 从文本中按正则规则提取单个字符串
    public static func getString(from text: String, rule: String) throws -> String {
        let results = try getStringList(from: text, rule: rule)
        return results.first ?? ""
    }

    // MARK: - 文本替换

    /// 按正则规则替换文本中的内容
    /// - Parameters:
    ///   - text: 输入文本
    ///   - pattern: 正则模式
    ///   - replacement: 替换字符串（支持 `$0`, `$1` 等捕获组引用）
    /// - Returns: 替换后的文本
    public static func replace(
        _ text: String,
        pattern: String,
        replacement: String
    ) throws -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            throw ParserError.regexError("无法编译正则表达式: \(pattern)")
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// 按 legado 格式的替换规则处理文本
    /// 规则格式：`##pattern##replacement`
    public static func applyReplaceRule(_ text: String, rule: String) throws -> String {
        let parts = rule.components(separatedBy: "##")
        guard parts.count >= 2 else { return text }
        let pattern = parts[1]
        let replacement = parts.count > 2 ? parts[2] : ""
        return try replace(text, pattern: pattern, replacement: replacement)
    }

    // MARK: - 多规则链式处理

    /// 对文本依次应用多条正则替换规则
    /// - Parameters:
    ///   - text: 输入文本
    ///   - rules: 规则列表，每条规则格式为 `##pattern##replacement`
    /// - Returns: 经所有规则处理后的文本
    public static func applyReplaceRules(_ text: String, rules: [String]) throws -> String {
        var result = text
        for rule in rules {
            result = try applyReplaceRule(result, rule: rule)
        }
        return result
    }

    // MARK: - 辅助方法

    /// 解析正则规则，返回 (pattern, replacement)
    /// 格式：`##pattern##replacement` 或 `pattern`
    static func parseRule(_ rule: String) -> (String, String?) {
        if rule.hasPrefix("##") {
            let withoutPrefix = String(rule.dropFirst(2))
            let parts = withoutPrefix.components(separatedBy: "##")
            if parts.count > 1 {
                return (parts[0], parts[1])
            }
            return (withoutPrefix, nil)
        }
        let parts = rule.components(separatedBy: "##")
        if parts.count > 1 {
            return (parts[0], parts[1])
        }
        return (rule, nil)
    }

    /// 测试文本是否匹配正则
    public static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
