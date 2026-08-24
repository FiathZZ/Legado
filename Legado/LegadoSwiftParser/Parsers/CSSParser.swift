import Foundation
import SwiftSoup

// MARK: - CSSParser
/// CSS 选择器解析器（基于 SwiftSoup）。
///
/// 支持 legado JSoup 风格扩展：
/// - `selector@attr` 属性提取
/// - 默认模式下的 `selector@selector@attr` 链式下钻
/// - `textNodes` / `ownText` / `all` 属性关键字
/// - `selector[index]`、`selector[start:end:step]`、`selector!start:end` 索引切片
public nonisolated struct CSSParser {

    // MARK: - 私有类型

    private enum SelectorFilterMode {
        case include
        case exclude
    }

    private enum SelectorIndexSpec {
        case single(Int)
        case range(start: Int?, end: Int?, step: Int)
    }

    private struct SelectorFilter {
        let mode: SelectorFilterMode
        let specs: [SelectorIndexSpec]
    }

    // MARK: - 从 HTML 字符串解析

    /// 从 HTML 字符串中按 CSS 规则提取字符串列表。
    public static func getStringList(
        from html: String,
        rule: String,
        baseUrl: String = ""
    ) throws -> [String] {
        let document = try SwiftSoup.parse(html, baseUrl)
        defer { _ = document.empty() }
        return try getStringList(from: document, rule: rule, baseUrl: baseUrl)
    }

    /// 从 Document 中按 CSS 规则提取字符串列表。
    public static func getStringList(
        from document: Document,
        rule: String,
        baseUrl: String = ""
    ) throws -> [String] {
        let (selector, attribute) = parseSelectorAndAttribute(rule)
        let elements = try getElements(from: document, rule: selector.isEmpty ? "*" : selector)
        return try elements.compactMap { element in
            try extractValue(from: element, attribute: attribute, baseUrl: baseUrl)
        }.filter { !$0.isEmpty }
    }

    /// 从 Element 中按 CSS 规则提取字符串列表。
    public static func getStringList(
        from element: Element,
        rule: String,
        baseUrl: String = ""
    ) throws -> [String] {
        let (selector, attribute) = parseSelectorAndAttribute(rule)

        if selector.isEmpty {
            if let value = try extractValue(from: element, attribute: attribute, baseUrl: baseUrl), !value.isEmpty {
                return [value]
            }
            return []
        }

        let elements = try getElements(from: element, rule: selector)
        return try elements.compactMap { selectedElement in
            try extractValue(from: selectedElement, attribute: attribute, baseUrl: baseUrl)
        }.filter { !$0.isEmpty }
    }

    /// 从 HTML 字符串中按规则多级遍历提取字符串列表（默认模式）。
    public static func getStringListTraversing(
        from html: String,
        rule: String,
        baseUrl: String = ""
    ) throws -> [String] {
        let document = try SwiftSoup.parse(html, baseUrl)
        defer { _ = document.empty() }
        return try getStringListTraversing(from: document, rule: rule, baseUrl: baseUrl)
    }

    /// 从 Document 中按规则多级遍历提取字符串列表（默认模式）。
    public static func getStringListTraversing(
        from document: Document,
        rule: String,
        baseUrl: String = ""
    ) throws -> [String] {
        let rootElement: Element = document
        return try getStringListTraversing(from: rootElement, rule: rule, baseUrl: baseUrl)
    }

    /// 从 Element 中按规则多级遍历提取字符串列表（默认模式）。
    public static func getStringListTraversing(
        from element: Element,
        rule: String,
        baseUrl: String = ""
    ) throws -> [String] {
        let chainParts = splitChainRule(rule)
        guard !chainParts.isEmpty else { return [] }

        let attribute: String
        let selectorParts: [String]
        if shouldTreatLastPartAsAttribute(chainParts) {
            attribute = chainParts.last ?? "text"
            selectorParts = Array(chainParts.dropLast())
        } else {
            attribute = "text"
            selectorParts = chainParts
        }

        var currentElements: [Element] = [element]
        if !selectorParts.isEmpty {
            for selector in selectorParts where !selector.isEmpty {
                var nextElements: [Element] = []
                for current in currentElements {
                    nextElements.append(contentsOf: try selectElements(from: current, selectorRule: selector))
                }
                currentElements = nextElements
                if currentElements.isEmpty { return [] }
            }
        }

        return try currentElements.compactMap { current in
            try extractValue(from: current, attribute: attribute, baseUrl: baseUrl)
        }.filter { !$0.isEmpty }
    }

    /// 从 HTML 字符串中按规则多级遍历提取元素列表（默认模式）。
    public static func getElementsTraversing(
        from html: String,
        rule: String,
        baseUrl: String = ""
    ) throws -> [Element] {
        let document = try SwiftSoup.parse(html, baseUrl)
        return try getElementsTraversing(from: document, rule: rule)
    }

    /// 从 Document 中按规则多级遍历提取元素列表（默认模式）。
    public static func getElementsTraversing(
        from document: Document,
        rule: String
    ) throws -> [Element] {
        let rootElement: Element = document
        return try getElementsTraversing(from: rootElement, rule: rule)
    }

    /// 从 Element 中按规则多级遍历提取元素列表（默认模式）。
    public static func getElementsTraversing(
        from element: Element,
        rule: String
    ) throws -> [Element] {
        let chainParts = splitChainRule(rule)
        guard !chainParts.isEmpty else { return [] }

        var currentElements: [Element] = [element]
        for selector in chainParts where !selector.isEmpty {
            var nextElements: [Element] = []
            for current in currentElements {
                nextElements.append(contentsOf: try selectElements(from: current, selectorRule: selector))
            }
            currentElements = nextElements
            if currentElements.isEmpty { break }
        }
        return currentElements
    }

    /// 从 HTML 字符串中按 CSS 规则提取单个字符串（取第一个匹配结果）。
    public static func getString(
        from html: String,
        rule: String,
        baseUrl: String = ""
    ) throws -> String {
        try getStringList(from: html, rule: rule, baseUrl: baseUrl).first ?? ""
    }

    /// 从 Document 中按 CSS 规则提取单个字符串。
    public static func getString(
        from document: Document,
        rule: String,
        baseUrl: String = ""
    ) throws -> String {
        try getStringList(from: document, rule: rule, baseUrl: baseUrl).first ?? ""
    }

    /// 从 Element 中按 CSS 规则提取单个字符串。
    public static func getString(
        from element: Element,
        rule: String,
        baseUrl: String = ""
    ) throws -> String {
        try getStringList(from: element, rule: rule, baseUrl: baseUrl).first ?? ""
    }

    // MARK: - 元素列表提取

    /// 从 HTML 字符串中按 CSS 规则提取元素列表。
    public static func getElements(
        from html: String,
        rule: String,
        baseUrl: String = ""
    ) throws -> [Element] {
        let document = try SwiftSoup.parse(html, baseUrl)
        return try getElements(from: document, rule: rule)
    }

    /// 从 Document 中按 CSS 规则提取元素列表。
    public static func getElements(
        from document: Document,
        rule: String
    ) throws -> [Element] {
        try selectElements(from: document, selectorRule: rule)
    }

    /// 从 Element 中按 CSS 规则提取子元素列表。
    public static func getElements(
        from element: Element,
        rule: String
    ) throws -> [Element] {
        try selectElements(from: element, selectorRule: rule)
    }

    // MARK: - 规则拆分

    /// 在默认模式下按顶层 `@` 拆分链式规则，忽略 `[]`、`()`、`{{}}` 与引号内的 `@`。
    public static func splitChainRule(_ rule: String) -> [String] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var parts: [String] = []
        var current = ""
        var index = trimmed.startIndex
        var bracketDepth = 0
        var parenthesisDepth = 0
        var templateDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        while index < trimmed.endIndex {
            let remaining = trimmed[index...]
            let character = trimmed[index]

            if remaining.hasPrefix("{{") {
                templateDepth += 1
                current.append("{{")
                index = trimmed.index(index, offsetBy: 2)
                continue
            }

            if templateDepth > 0, remaining.hasPrefix("}}") {
                templateDepth -= 1
                current.append("}}")
                index = trimmed.index(index, offsetBy: 2)
                continue
            }

            if templateDepth == 0 {
                if character == "\"" && !inSingleQuote {
                    inDoubleQuote.toggle()
                } else if character == "'" && !inDoubleQuote {
                    inSingleQuote.toggle()
                } else if !inSingleQuote && !inDoubleQuote {
                    switch character {
                    case "[":
                        bracketDepth += 1
                    case "]":
                        bracketDepth = max(0, bracketDepth - 1)
                    case "(":
                        parenthesisDepth += 1
                    case ")":
                        parenthesisDepth = max(0, parenthesisDepth - 1)
                    case "@" where bracketDepth == 0 && parenthesisDepth == 0:
                        let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !part.isEmpty {
                            parts.append(part)
                        }
                        current = ""
                        index = trimmed.index(after: index)
                        continue
                    default:
                        break
                    }
                }
            }

            current.append(character)
            index = trimmed.index(after: index)
        }

        let finalPart = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalPart.isEmpty {
            parts.append(finalPart)
        }
        ParserLog.debug("CSSParser", "split chain parts=\(parts.count) rule=\(ParserLog.preview(rule))")
        return parts
    }

    // MARK: - 辅助方法

    /// 解析 CSS 模式下的 `selector@attribute` 规则。
    private static func parseSelectorAndAttribute(_ rule: String) -> (selector: String, attribute: String) {
        let parts = splitChainRule(rule)
        guard !parts.isEmpty else { return ("", "text") }
        guard shouldTreatLastPartAsAttribute(parts) else {
            return (rule.trimmingCharacters(in: .whitespacesAndNewlines), "text")
        }

        let attribute = parts.last ?? "text"
        let selector = parts.dropLast().joined(separator: "@")
        return (selector, attribute)
    }

    /// 判断链式规则最后一段是否应被视为属性提取器。
    private static func shouldTreatLastPartAsAttribute(_ parts: [String]) -> Bool {
        guard let candidate = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else {
            return false
        }

        let lowered = candidate.lowercased()
        let knownAttributes: Set<String> = [
            "text", "html", "innerhtml", "outerhtml", "href", "src", "alt", "title", "textnodes", "owntext", "all"
        ]
        if knownAttributes.contains(lowered) {
            return true
        }

        if parts.count == 2,
           lowered.range(of: #"^[a-z][a-z0-9_-]*$"#, options: .regularExpression) != nil,
           !candidate.contains("."),
           !candidate.contains("#"),
           !candidate.contains("["),
           !candidate.contains(":") {
            return true
        }

        return false
    }

    /// 从元素中提取指定属性的值。
    private static func extractValue(
        from element: Element,
        attribute: String,
        baseUrl: String
    ) throws -> String? {
        switch attribute.lowercased() {
        case "text", "":
            return try element.text()
        case "textnodes":
            let joined = element.textNodes()
                .map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        case "owntext":
            let value = element.ownText()
            return value.isEmpty ? nil : value
        case "html", "innerhtml":
            return try element.html()
        case "all", "outerhtml":
            return try element.outerHtml()
        case "href":
            return try element.attr("href")
        case "src":
            return try element.attr("src")
        default:
            return try element.attr(attribute)
        }
    }

    /// 选择器兼容扩展：支持旧格式索引、`[]` 切片与排除模式。
    private static func selectElements(
        from element: Element,
        selectorRule: String
    ) throws -> [Element] {
        let trimmed = selectorRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return element.children().array() }

        let (baseRule, filter) = parseSelectorFilter(trimmed)

        let selected: [Element]
        if baseRule == "children" {
            selected = element.children().array()
        } else if baseRule.hasPrefix("class."), baseRule.count > 6 {
            let rawClassRule = String(baseRule.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            let classNames = rawClassRule
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }

            if classNames.count <= 1 {
                selected = try includeSelfIfMatched(
                    element: element,
                    matches: element.getElementsByClass(rawClassRule).array(),
                    selectorRule: ".\(rawClassRule)"
                )
            } else {
                let selector = classNames.map { ".\($0)" }.joined()
                selected = try includeSelfIfMatched(
                    element: element,
                    matches: element.select(selector).array(),
                    selectorRule: selector
                )
            }
        } else if baseRule.hasPrefix("tag."), baseRule.count > 4 {
            let selector = String(baseRule.dropFirst(4))
            selected = try includeSelfIfMatched(
                element: element,
                matches: element.getElementsByTag(selector).array(),
                selectorRule: selector
            )
        } else if baseRule.hasPrefix("id."), baseRule.count > 3 {
            let elementID = String(baseRule.dropFirst(3))
            if let matched = firstElementByID(elementID, from: element) {
                selected = [matched]
            } else {
                selected = []
            }
        } else if baseRule.hasPrefix("text."), baseRule.count > 5 {
            let needle = String(baseRule.dropFirst(5))
            let ownMatches = try element.getElementsContainingOwnText(needle).array()
            let broadMatches = try element.getElementsContainingText(needle).array()
            let mergedMatches = deduplicateTextMatches(ownMatches + broadMatches)
            selected = preferLeafTextMatches(mergedMatches)
        } else {
            do {
                selected = try includeSelfIfMatched(
                    element: element,
                    matches: element.select(baseRule).array(),
                    selectorRule: baseRule
                )
            } catch {
                if let compatible = try selectElementsWithAttributeRegexCompatibility(
                    from: element,
                    selectorRule: baseRule
                ) {
                    selected = try includeSelfIfMatched(
                        element: element,
                        matches: compatible,
                        selectorRule: baseRule
                    )
                } else {
                    throw error
                }
            }
        }

        guard let filter else { return selected }
        let filtered = applySelectorFilter(selected, filter: filter)
        ParserLog.debug(
            "CSSParser",
            "selector filter rule=\(ParserLog.preview(selectorRule)) selected=\(selected.count) filtered=\(filtered.count)"
        )
        return filtered
    }

    /// SwiftSoup 的 `getElementById` 通过父节点和 siblingIndex 遍历；异常或并发读取的 DOM
    /// 可能在该路径直接触发越界崩溃。对子节点数组取快照后只读遍历，且保持文档深度优先顺序。
    private static func firstElementByID(_ elementID: String, from root: Element) -> Element? {
        var stack: [Node] = [root]

        while let node = stack.popLast() {
            if let candidate = node as? Element, candidate.id() == elementID {
                return candidate
            }

            let children = node.getChildNodes()
            stack.append(contentsOf: children.reversed())
        }

        return nil
    }

    /// legado 的 item 级默认链规则允许当前节点自身命中首段选择器。
    /// 例如搜索列表 item 自身就是 `<a>`，而字段规则仍写成 `tag.a@href`。
    /// SwiftSoup 的常规查找只返回后代节点，这里在 self 确实匹配时把它补回到结果头部。
    private static func includeSelfIfMatched(
        element: Element,
        matches: [Element],
        selectorRule: String
    ) throws -> [Element] {
        if element is Document {
            return matches
        }
        let trimmedSelector = selectorRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelector.isEmpty else { return matches }
        guard elementMatchesSelector(element, selectorRule: trimmedSelector) else { return matches }
        guard !matches.contains(where: { $0 === element }) else { return matches }
        return [element] + matches
    }

    private static func elementMatchesSelector(_ element: Element, selectorRule: String) -> Bool {
        if let tagName = try? element.tagName(), selectorRule.caseInsensitiveCompare(tagName) == .orderedSame {
            return true
        }
        let wrapperHTML = "<div id=\"__swift_legado_self_wrapper__\">\((try? element.outerHtml()) ?? "")</div>"
        guard let document = try? SwiftSoup.parse(wrapperHTML),
              let wrapper = document.body()?.children().first(),
              let firstChild = wrapper.children().first() else {
            return false
        }
        return ((try? wrapper.select(selectorRule).array().contains(where: { $0 == firstChild })) == true)
    }

    /// 解析选择器尾部的索引切片表达式。
    private static func parseSelectorFilter(_ selector: String) -> (baseRule: String, filter: SelectorFilter?) {
        if let bracketRange = trailingBracketRange(in: selector) {
            let baseRule = String(selector[..<bracketRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let expressionStart = selector.index(after: bracketRange.lowerBound)
            let expressionEnd = selector.index(before: bracketRange.upperBound)
            let expression = String(selector[expressionStart..<expressionEnd])
            if let filter = parseBracketFilterExpression(expression) {
                return (baseRule.isEmpty ? selector : baseRule, filter)
            }
        }

        if let legacyFilter = parseLegacyFilterExpression(selector) {
            return legacyFilter
        }

        return (selector, nil)
    }

    private static func selectElementsWithAttributeRegexCompatibility(
        from element: Element,
        selectorRule: String
    ) throws -> [Element]? {
        let predicates = parseAttributeRegexPredicates(in: selectorRule)
        guard !predicates.isEmpty else { return nil }

        let fallbackSelector = predicates.reduce(selectorRule) { partial, predicate in
            partial.replacingOccurrences(of: predicate.original, with: "[\(predicate.attribute)]")
        }

        let broadMatches = try element.select(fallbackSelector).array()
        return broadMatches.filter { candidate in
            predicates.allSatisfy { predicate in
                guard let attrValue = try? candidate.attr(predicate.attribute) else {
                    return false
                }
                return predicate.matches(attrValue)
            }
        }
    }

    private static func deduplicateTextMatches(_ elements: [Element]) -> [Element] {
        var seen: Set<ObjectIdentifier> = []
        var deduplicated: [Element] = []
        deduplicated.reserveCapacity(elements.count)

        for element in elements {
            let identifier = ObjectIdentifier(element)
            if seen.insert(identifier).inserted {
                deduplicated.append(element)
            }
        }

        return deduplicated
    }

    private static func preferLeafTextMatches(_ elements: [Element]) -> [Element] {
        guard elements.count > 1 else { return elements }

        let filtered = elements.filter { candidate in
            !elements.contains { other in
                guard candidate !== other else { return false }
                return isDescendant(other, of: candidate)
            }
        }

        guard !filtered.isEmpty else { return elements }
        return filtered.sorted { lhs, rhs in
            textMatchDepth(lhs) > textMatchDepth(rhs)
        }
    }

    private static func isDescendant(_ element: Element, of ancestor: Element) -> Bool {
        var current = element.parent()
        while let parent = current {
            if parent === ancestor {
                return true
            }
            current = parent.parent()
        }
        return false
    }

    private static func textMatchDepth(_ element: Element) -> Int {
        var depth = 0
        var current = element.parent()
        while let parent = current {
            depth += 1
            current = parent.parent()
        }
        return depth
    }

    private struct AttributeRegexPredicate {
        let original: String
        let attribute: String
        let pattern: String

        func matches(_ value: String) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return value.range(of: pattern) != nil
            }
            let range = NSRange(value.startIndex..., in: value)
            return regex.firstMatch(in: value, range: range) != nil
        }
    }

    private static func parseAttributeRegexPredicates(in selector: String) -> [AttributeRegexPredicate] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\s*([^\s~\]=]+)\s*~=\s*([^\]]+?)\s*\]"#) else {
            return []
        }

        let nsSelector = selector as NSString
        let matches = regex.matches(in: selector, range: NSRange(location: 0, length: nsSelector.length))
        return matches.compactMap { match in
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: selector),
                  let attributeRange = Range(match.range(at: 1), in: selector),
                  let patternRange = Range(match.range(at: 2), in: selector) else {
                return nil
            }

            let rawPattern = String(selector[patternRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let unquotedPattern = rawPattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !unquotedPattern.isEmpty else { return nil }

            return AttributeRegexPredicate(
                original: String(selector[fullRange]),
                attribute: String(selector[attributeRange]),
                pattern: unquotedPattern
            )
        }
    }

    /// 解析 Android legado `selector[expr]` 索引表达式。
    private static func parseBracketFilterExpression(_ expression: String) -> SelectorFilter? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let mode: SelectorFilterMode
        let body: String
        if trimmed.hasPrefix("!") {
            mode = .exclude
            body = String(trimmed.dropFirst())
        } else {
            mode = .include
            body = trimmed
        }

        let specs = body
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { parseBracketIndexSpec(String($0)) }
        guard !specs.isEmpty else { return nil }
        return SelectorFilter(mode: mode, specs: specs)
    }

    /// 解析 Android legado 旧式 `selector!0:2:-1` 索引表达式。
    private static func parseLegacyFilterExpression(_ selector: String) -> (baseRule: String, filter: SelectorFilter?)? {
        let pattern = #"^(.*?)([.!])(-?\d+(?::-?\d+)*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: selector, range: NSRange(selector.startIndex..., in: selector)),
              let baseRange = Range(match.range(at: 1), in: selector),
              let modeRange = Range(match.range(at: 2), in: selector),
              let indexesRange = Range(match.range(at: 3), in: selector) else {
            return nil
        }

        let rawIndexes = String(selector[indexesRange])
        let specs = rawIndexes
            .split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map(SelectorIndexSpec.single)
        guard !specs.isEmpty else { return nil }

        let mode: SelectorFilterMode = selector[modeRange] == "!" ? .exclude : .include
        let baseRule = String(selector[baseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (baseRule, SelectorFilter(mode: mode, specs: specs))
    }

    private static func parseBracketIndexSpec(_ token: String) -> SelectorIndexSpec? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains(":"), let index = Int(trimmed) {
            return .single(index)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let start = parts[0].isEmpty ? nil : Int(parts[0])
        let end = parts[1].isEmpty ? nil : Int(parts[1])
        let step = parts.count == 3 ? (Int(parts[2]) ?? 1) : 1
        return .range(start: start, end: end, step: step)
    }

    /// 应用选择器索引过滤。
    private static func applySelectorFilter(_ elements: [Element], filter: SelectorFilter) -> [Element] {
        guard !elements.isEmpty else { return [] }

        let orderedIndexes = resolveSelectorIndexes(filter.specs, count: elements.count)
        switch filter.mode {
        case .exclude:
            let excluded = Set(orderedIndexes)
            return elements.enumerated().compactMap { idx, element in
                excluded.contains(idx) ? nil : element
            }
        case .include:
            return orderedIndexes.compactMap { index in
                elements.indices.contains(index) ? elements[index] : nil
            }
        }
    }

    /// 计算与 Android `AnalyzeByJSoup.ElementsSingle` 对齐的有序索引列表。
    private static func resolveSelectorIndexes(_ specs: [SelectorIndexSpec], count: Int) -> [Int] {
        guard count > 0 else { return [] }

        var orderedIndexes: [Int] = []
        var seen: Set<Int> = []

        for spec in specs {
            switch spec {
            case .single(let index):
                guard let resolvedIndex = resolveIndex(index, count: count) else { continue }
                if seen.insert(resolvedIndex).inserted {
                    orderedIndexes.append(resolvedIndex)
                }

            case .range(let startValue, let endValue, let stepValue):
                guard let rangeIndexes = resolveRangeIndexes(
                    count: count,
                    startValue: startValue,
                    endValue: endValue,
                    stepValue: stepValue
                ) else { continue }

                for index in rangeIndexes where seen.insert(index).inserted {
                    orderedIndexes.append(index)
                }
            }
        }

        return orderedIndexes
    }

    /// 归一化单个索引。
    private static func resolveIndex(_ index: Int, count: Int) -> Int? {
        let resolved = index >= 0 ? index : count + index
        guard resolved >= 0 && resolved < count else { return nil }
        return resolved
    }

    /// 找到尾部索引方括号范围。
    private static func trailingBracketRange(in selector: String) -> Range<String.Index>? {
        guard selector.last == "]", let openIndex = selector.lastIndex(of: "[") else { return nil }
        return openIndex..<selector.endIndex
    }

    private static func resolveRangeIndexes(
        count: Int,
        startValue: Int?,
        endValue: Int?,
        stepValue: Int
    ) -> [Int]? {
        var start = startValue ?? 0
        if start < 0 { start += count }

        var end = endValue ?? (count - 1)
        if end < 0 { end += count }

        if (start < 0 && end < 0) || (start >= count && end >= count) {
            return nil
        }

        if start >= count {
            start = count - 1
        } else if start < 0 {
            start = 0
        }

        if end >= count {
            end = count - 1
        } else if end < 0 {
            end = 0
        }

        if start == end || stepValue >= count {
            return [start]
        }

        let normalizedStep: Int
        if stepValue > 0 {
            normalizedStep = stepValue
        } else if -stepValue < count {
            normalizedStep = stepValue + count
        } else {
            normalizedStep = 1
        }

        var indexes: [Int] = []
        if end > start {
            var current = start
            while current <= end {
                indexes.append(current)
                current += max(normalizedStep, 1)
            }
        } else {
            var current = start
            while current >= end {
                indexes.append(current)
                current -= max(normalizedStep, 1)
            }
        }
        return indexes
    }
}
