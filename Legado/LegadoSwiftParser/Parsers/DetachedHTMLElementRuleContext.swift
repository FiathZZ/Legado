import Foundation
import SwiftSoup

/// 为单个 HTML 元素建立独立的解析上下文，避免字段提取阶段持续污染原始 DOM 的查询缓存。
nonisolated struct DetachedHTMLElementRuleContext {
    private let analyzer: AnalyzeRule
    private let html: String
    private let document: Document
    private let currentElement: Element
    private let baseUrl: String

    init(element: Element, analyzer: AnalyzeRule, baseUrl: String) throws {
        self.analyzer = analyzer
        self.baseUrl = baseUrl
        self.html = try element.outerHtml()
        self.document = try SwiftSoup.parse(self.html, baseUrl)
        self.currentElement = document.body()?.children().first() ?? document
    }

    func getString(rule: String, isUrl: Bool = false) throws -> String {
        let results = try getStringList(rule: rule, isUrl: isUrl)
        return results.first ?? ""
    }

    func getStringList(rule: String, isUrl: Bool = false) throws -> [String] {
        guard !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let results = try evaluate(rule: rule)
        return postProcess(results: results, isUrl: isUrl)
    }

    func cleanup() {
    }

    func infoHTML() -> String {
        html
    }

    private func evaluate(rule: String) throws -> [String] {
        let substitutedRule = RuleAnalyzer.substituteGetVariables(rule, variableStore: analyzer.variableStore)
        let splitResult = RuleAnalyzer.splitRulesWithOperator(substitutedRule)

        if splitResult.operator == "||" {
            for subRule in splitResult.parts {
                let results = try evaluate(rule: subRule)
                if !results.isEmpty {
                    return results
                }
            }
            return []
        }

        if splitResult.operator == "&&" {
            var combined: [String] = []
            for subRule in splitResult.parts {
                combined.append(contentsOf: try evaluate(rule: subRule))
            }
            return combined
        }

        if splitResult.operator == "@@" {
            var combined = ""
            for subRule in splitResult.parts {
                combined += try evaluate(rule: subRule).joined(separator: "")
            }
            return combined.isEmpty ? [] : [combined]
        }

        if splitResult.operator == "%%" {
            let groups = try splitResult.parts.map { try evaluate(rule: $0) }
            return interleave(groups)
        }

        return try evaluateLeaf(rule: substitutedRule)
    }

    private func evaluateLeaf(rule: String) throws -> [String] {
        guard !shouldFallbackToSourceElement(rule: rule) else {
            return try analyzer.getStringList(element: currentElement, rule: rule, isUrl: false)
        }

        let (ruleAfterPut, putMap) = RuleAnalyzer.extractPutOptions(rule)
        applyPutOptions(putMap)

        let (ruleWithoutHash, hashRegex, hashReplacement, hashReplaceFirst) = RuleAnalyzer.extractHashPattern(ruleAfterPut)
        let ruleType = RuleAnalyzer.ruleType(for: ruleWithoutHash)
        let cleanedRule = RuleAnalyzer.cleanRule(ruleWithoutHash)

        if shouldResolveAgainstCurrentElement(rule: cleanedRule, ruleType: ruleType) {
            var results = try CSSParser.getStringList(from: currentElement, rule: "@\(cleanedRule)", baseUrl: baseUrl)
            if let hashRegex {
                results = RuleAnalyzer.applyHashReplace(
                    results,
                    regex: hashRegex,
                    replacement: hashReplacement,
                    replaceFirst: hashReplaceFirst
                )
            }
            return results
        }

        let results: [String]
        switch ruleType {
        case .css:
            results = try CSSParser.getStringList(from: document, rule: cleanedRule, baseUrl: baseUrl)
        case .default:
            if let values = try? CSSParser.getStringListTraversing(from: document, rule: cleanedRule, baseUrl: baseUrl),
               !values.isEmpty {
                results = values
            } else {
                results = (try? RegexParser.getStringList(from: html, rule: cleanedRule)) ?? []
            }
        case .xpath:
            results = try XPathParser.getStringList(from: currentElement, rule: ruleWithoutHash, baseUrl: baseUrl)
        case .regex:
            results = try RegexParser.getStringList(from: try document.text(), rule: cleanedRule)
        case .jsonPath:
            results = try JSONPathParser.getStringList(from: try document.text(), rule: cleanedRule)
        case .javascript:
            results = try analyzer.getStringList(element: currentElement, rule: rule, isUrl: false)
        }

        guard let hashRegex else {
            return results
        }
        return RuleAnalyzer.applyHashReplace(
            results,
            regex: hashRegex,
            replacement: hashReplacement,
            replaceFirst: hashReplaceFirst
        )
    }

    private func shouldFallbackToSourceElement(rule: String) -> Bool {
        if RuleAnalyzer.containsTemplate(rule) || rule.contains("<js>") {
            return true
        }

        let (_, jsCode) = RuleAnalyzer.extractJS(rule)
        if jsCode != nil {
            return true
        }

        return false
    }

    private func shouldResolveAgainstCurrentElement(rule: String, ruleType: RuleType) -> Bool {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return false }
        guard ruleType == .default || ruleType == .css else { return false }

        let chainParts = trimmedRule
            .split(separator: "@", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard chainParts.count == 1, let candidate = chainParts.first, !candidate.isEmpty else {
            return false
        }

        let knownCurrentElementRules: Set<String> = [
            "text", "html", "innerhtml", "outerhtml", "all",
            "textnodes", "owntext", "href", "src", "alt", "title"
        ]
        if knownCurrentElementRules.contains(candidate.lowercased()) {
            return true
        }

        return candidate.range(of: #"^[a-z][a-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    private func postProcess(results: [String], isUrl: Bool) -> [String] {
        let filtered = results
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard isUrl else {
            return filtered
        }

        return filtered
            .flatMap { AnalyzeUrl.postProcessExtractedURLs($0, baseUrl: baseUrl, variableStore: analyzer.variableStore) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func interleave(_ groups: [[String]]) -> [String] {
        guard let maxCount = groups.map(\.count).max(), maxCount > 0 else {
            return []
        }

        var combined: [String] = []
        for index in 0..<maxCount {
            for group in groups where index < group.count {
                combined.append(group[index])
            }
        }
        return combined
    }

    private func applyPutOptions(_ putMap: [String: String]) {
        guard !putMap.isEmpty else { return }
        for (key, valueRule) in putMap {
            let value = (try? analyzer.getString(element: currentElement, rule: valueRule, isUrl: false)) ?? valueRule
            analyzer.variableStore.put(key, value: value)
        }
    }
}
