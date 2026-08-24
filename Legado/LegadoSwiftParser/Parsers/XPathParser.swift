import Foundation
import SwiftSoup
import Kanna

// MARK: - XPathParser
/// XPath 解析器。
///
/// Phase 13D 起主执行入口改为基于 Kanna / libxml2 的成熟 XPath 实现，
/// 保持 `XPathParser` 对外 API 不变，调用方无需感知底层替换。
public nonisolated struct XPathParser {

    // MARK: - Public API

    /// 从 HTML 字符串中按 XPath 规则提取字符串列表。
    public static func getStringList(from html: String, rule: String, baseUrl: String = "") throws -> [String] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)
        return try evaluateStringList(html: html, rule: cleanedRule, baseUrl: baseUrl)
    }

    /// 从 Document 中按 XPath 规则提取字符串列表。
    public static func getStringList(from document: Document, rule: String, baseUrl: String = "") throws -> [String] {
        try getStringList(from: document.outerHtml(), rule: rule, baseUrl: baseUrl)
    }

    /// 从单个 SwiftSoup Element 中按 XPath 规则提取字符串列表。
    public static func getStringList(from element: Element, rule: String, baseUrl: String = "") throws -> [String] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)
        if isRelativeXPath(cleanedRule) {
            let query = try parseOutput(cleanedRule, allowRelative: true)
            let nodes = try evaluateNodeList(element: element, rule: query.path)
            return nodes.compactMap { node in
                let rawValue = stringValue(from: node, output: query.output)
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if case let .attribute(name) = query.output, name == "href" || name == "src" {
                    return resolveURL(trimmed, baseUrl: baseUrl)
                }
                return trimmed
            }
        }
        return try getStringList(from: element.outerHtml(), rule: rule, baseUrl: baseUrl)
    }

    /// 从 HTML 字符串中按 XPath 规则提取单个字符串。
    public static func getString(from html: String, rule: String, baseUrl: String = "") throws -> String {
        try getStringList(from: html, rule: rule, baseUrl: baseUrl).first ?? ""
    }

    /// 从 Document 中按 XPath 规则提取单个字符串。
    public static func getString(from document: Document, rule: String, baseUrl: String = "") throws -> String {
        try getStringList(from: document, rule: rule, baseUrl: baseUrl).first ?? ""
    }

    /// 从单个 SwiftSoup Element 中按 XPath 规则提取单个字符串。
    public static func getString(from element: Element, rule: String, baseUrl: String = "") throws -> String {
        try getStringList(from: element, rule: rule, baseUrl: baseUrl).first ?? ""
    }

    /// 从 HTML 字符串中按 XPath 规则提取元素列表。
    public static func getElements(from html: String, rule: String, baseUrl: String = "") throws -> [Element] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)
        let result = try evaluateNodeList(html: html, rule: cleanedRule)
        return try result.compactMap { try makeSwiftSoupElement(from: $0) }
    }

    /// 从 Document 中按 XPath 规则提取元素列表。
    public static func getElements(from document: Document, rule: String) throws -> [Element] {
        try getElements(from: document.outerHtml(), rule: rule)
    }

    // MARK: - Rule Execution

    private static func evaluateStringList(html: String, rule: String, baseUrl: String) throws -> [String] {
        let split = RuleAnalyzer.splitRulesWithOperator(rule)

        if split.parts.count > 1 {
            switch split.operator {
            case "||":
                for part in split.parts {
                    let values = try evaluateStringList(html: html, rule: part, baseUrl: baseUrl)
                    if !values.isEmpty {
                        return values
                    }
                }
                return []
            case "%%":
                let groups = try split.parts.map { try evaluateStringList(html: html, rule: $0, baseUrl: baseUrl) }
                return interleave(groups)
            default:
                return try split.parts.flatMap { try evaluateStringList(html: html, rule: $0, baseUrl: baseUrl) }
            }
        }

        let query = try parseOutput(rule, allowRelative: false)
        let nodes = try evaluateNodeList(html: html, rule: query.path)
        return nodes.compactMap { node in
            let rawValue = stringValue(from: node, output: query.output)
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if case let .attribute(name) = query.output, name == "href" || name == "src" {
                return resolveURL(trimmed, baseUrl: baseUrl)
            }
            return trimmed
        }
    }

    private static func evaluateNodeList(html: String, rule: String) throws -> [XPathNodeSnapshot] {
        let split = RuleAnalyzer.splitRulesWithOperator(rule)

        if split.parts.count > 1 {
            switch split.operator {
            case "||":
                for part in split.parts {
                    let nodes = try evaluateNodeList(html: html, rule: part)
                    if !nodes.isEmpty {
                        return deduplicated(nodes)
                    }
                }
                return []
            case "%%":
                let groups = try split.parts.map { try evaluateNodeList(html: html, rule: $0) }
                return deduplicated(interleave(groups))
            default:
                return deduplicated(try split.parts.flatMap { try evaluateNodeList(html: html, rule: $0) })
            }
        }

        // Android/jsoup 一些能“宽松吃下”的片段 HTML，在 libxml2/Kanna 下如果不先包裹 table/tr
        // 结构，XPath 命中会明显变少。这里先做一次最小归一化，尽量让目录页、列表页里的残片节点
        // 也能按 Android 预期进入 XPath 查询。
        let normalizedHTML = normalizeHTMLForXPath(html)
        let document = try makeDocument(from: normalizedHTML)
        return document.xpath(rule).compactMap(makeSnapshot(from:))
    }

    private static func evaluateNodeList(element: Element, rule: String) throws -> [XPathNodeSnapshot] {
        let split = RuleAnalyzer.splitRulesWithOperator(rule)

        if split.parts.count > 1 {
            switch split.operator {
            case "||":
                for part in split.parts {
                    let nodes = try evaluateNodeList(element: element, rule: part)
                    if !nodes.isEmpty {
                        return deduplicated(nodes)
                    }
                }
                return []
            case "%%":
                let groups = try split.parts.map { try evaluateNodeList(element: element, rule: $0) }
                return deduplicated(interleave(groups))
            default:
                return deduplicated(try split.parts.flatMap { try evaluateNodeList(element: element, rule: $0) })
            }
        }

        // 相对 XPath 规则依赖“当前节点就是上下文根”，但 Kanna 直接吃裸 fragment 时上下文不稳定。
        // 这里显式包一层 body，再把首节点作为根执行相对 XPath，行为更接近 Android 在元素上下文
        // 里继续跑 XPath 的语义。
        let fragment = try element.outerHtml()
        let wrappedHTML = "<body>\(fragment)</body>"
        let document = try makeDocument(from: wrappedHTML)
        guard let body = document.body,
              let first = body.xpath("./*").first else {
            throw ParserError.xpathError("XPath 元素上下文初始化失败")
        }
        return first.xpath(normalizedRelativeXPath(rule)).compactMap(makeSnapshot(from:))
    }

    // MARK: - Document

    private static func makeDocument(from html: String) throws -> Kanna.HTMLDocument {
        if html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<?xml") {
            if let xmlDocument = try? Kanna.XML(xml: html, encoding: .utf8),
               let htmlDocument = try? Kanna.HTML(html: xmlDocument.toXML ?? html, encoding: .utf8) {
                return htmlDocument
            }
        }

        if let document = try? Kanna.HTML(html: html, encoding: .utf8) {
            return document
        }

        throw ParserError.xpathError("XPath 文档初始化失败")
    }

    private static func normalizeHTMLForXPath(_ html: String) -> String {
        var normalized = html
        if normalized.hasSuffix("</td>") {
            normalized = "<tr>\(normalized)</tr>"
        }
        if normalized.hasSuffix("</tr>") || normalized.hasSuffix("</tbody>") {
            normalized = "<table>\(normalized)</table>"
        }
        return normalized
    }

    // MARK: - Output Conversion

    private static func parseOutput(_ rule: String, allowRelative: Bool) throws -> XPathOutputQuery {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || allowRelative else {
            throw ParserError.xpathError("XPath 必须以 / 或 // 开头: \(trimmed)")
        }

        if let range = trimmed.range(of: #"/@([\w\-:]+)$"#, options: .regularExpression) {
            let suffix = String(trimmed[range])
            return XPathOutputQuery(
                path: String(trimmed[..<range.lowerBound]),
                output: .attribute(String(suffix.dropFirst(2)))
            )
        }

        if trimmed.hasSuffix("/text()") {
            return XPathOutputQuery(
                path: String(trimmed.dropLast(7)),
                output: .text
            )
        }

        if let androidSuffix = parseAndroidOutputSuffix(from: trimmed) {
            return androidSuffix
        }

        return XPathOutputQuery(path: trimmed, output: .element)
    }

    private static func parseAndroidOutputSuffix(from rule: String) -> XPathOutputQuery? {
        let suffixes: [(suffix: String, output: XPathOutput)] = [
            ("@html", .html),
            ("@outerHtml", .html),
            ("@text", .text),
            ("@href", .attribute("href")),
            ("@src", .attribute("src")),
            ("@content", .attribute("content")),
            ("@value", .attribute("value")),
            ("@title", .attribute("title")),
            ("@alt", .attribute("alt"))
        ]

        for item in suffixes where rule.hasSuffix(item.suffix) {
            let path = String(rule.dropLast(item.suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { continue }
            return XPathOutputQuery(path: path, output: item.output)
        }

        return nil
    }

    private static func normalizedRelativeXPath(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRelativeXPath(trimmed) else { return trimmed }
        return trimmed.hasPrefix(".") ? trimmed : "./\(trimmed)"
    }

    private static func isRelativeXPath(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.hasPrefix("/")
    }

    private static func stringValue(from node: XPathNodeSnapshot, output: XPathOutput) -> String {
        switch output {
        case .text:
            return node.text.isEmpty ? node.content : node.text
        case .attribute(let name):
            if let value = attributeValue(name, from: node), !value.isEmpty {
                return value
            }
            if !node.text.isEmpty {
                return node.text
            }
            return node.content
        case .html:
            if !node.html.isEmpty {
                return node.html
            }
            return node.xml
        case .element:
            return node.text.isEmpty ? node.content : node.text
        }
    }

    private static func makeSwiftSoupElement(from node: XPathNodeSnapshot) throws -> Element? {
        let fragment = !node.html.isEmpty ? node.html : node.xml
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let document = try SwiftSoup.parseBodyFragment(fragment)
        let body = document.body()
        if let first = body?.children().first() {
            return first
        }
        return nil
    }

    private static func deduplicated(_ nodes: [XPathNodeSnapshot]) -> [XPathNodeSnapshot] {
        var seen: Set<String> = []
        return nodes.filter { node in
            let key = !node.xml.isEmpty ? node.xml : (!node.html.isEmpty ? node.html : node.text)
            return seen.insert(key).inserted
        }
    }

    private static func makeSnapshot(from node: Kanna.XMLElement) -> XPathNodeSnapshot {
        return XPathNodeSnapshot(
            text: node.text ?? "",
            content: node.content ?? "",
            html: node.toHTML ?? "",
            xml: node.toXML ?? ""
        )
    }

    private static func attributeValue(_ name: String, from node: XPathNodeSnapshot) -> String? {
        let fragment = !node.html.isEmpty ? node.html : node.xml
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let document = try? SwiftSoup.parseBodyFragment(fragment),
           let first = document.body()?.children().first(),
           let value = try? first.attr(name),
           !value.isEmpty {
            return value
        }

        return nil
    }

    private static func interleave<T>(_ groups: [[T]]) -> [T] {
        guard let maxCount = groups.map(\.count).max(), maxCount > 0 else {
            return []
        }

        var combined: [T] = []
        for index in 0..<maxCount {
            for group in groups where index < group.count {
                combined.append(group[index])
            }
        }
        return combined
    }

    private static func resolveURL(_ value: String, baseUrl: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.contains("://") || trimmed.hasPrefix("data:") {
            return trimmed
        }

        guard let base = URL(string: baseUrl), let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            return trimmed
        }

        return resolved.absoluteString
    }
}

private nonisolated struct XPathOutputQuery {
    let path: String
    let output: XPathOutput
}

private nonisolated enum XPathOutput {
    case text
    case attribute(String)
    case html
    case element
}

private nonisolated struct XPathNodeSnapshot {
    let text: String
    let content: String
    let html: String
    let xml: String
}
