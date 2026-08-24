import Foundation

// MARK: - ParserError
/// 解析器错误类型
public nonisolated enum ParserError: Error, LocalizedError {
    case invalidRule(String)
    case parsingFailed(String)
    case parseError(String)
    case networkError(String)
    case loginRequired(String)
    case invalidURL(String)
    case emptyResult
    case unsupportedRuleType(String)
    case javascriptError(String)
    case jsonPathError(String)
    case xpathError(String)
    case regexError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRule(let msg):
            return "无效规则: \(msg)"
        case .parsingFailed(let msg):
            return "解析失败: \(msg)"
        case .parseError(let msg):
            return "解析错误: \(msg)"
        case .networkError(let msg):
            return "网络错误: \(msg)"
        case .loginRequired(let msg):
            return "需要登录: \(msg)"
        case .invalidURL(let url):
            return "无效 URL: \(url)"
        case .emptyResult:
            return "解析结果为空"
        case .unsupportedRuleType(let type):
            return "不支持的规则类型: \(type)"
        case .javascriptError(let msg):
            return "JavaScript 错误: \(msg)"
        case .jsonPathError(let msg):
            return "JSON Path 错误: \(msg)"
        case .xpathError(let msg):
            return "XPath 错误: \(msg)"
        case .regexError(let msg):
            return "正则表达式错误: \(msg)"
        }
    }
}

// MARK: - ParserLog
nonisolated enum ParserLog {
    static func debug(_ stage: String, _ message: @autoclosure () -> String) {}

    static func preview(_ value: String?, limit: Int = 120) -> String {
        let normalized = (value ?? "")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > limit else {
            return normalized
        }
        return String(normalized.prefix(limit)) + "…"
    }
}
