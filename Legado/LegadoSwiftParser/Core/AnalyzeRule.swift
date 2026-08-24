import Foundation
import SwiftSoup

// MARK: - AnalyzeRule
/// 规则解析主控制器
///
/// 根据规则前缀自动选择合适的解析引擎（CSS/XPath/正则/JSON Path/JS），
/// 支持规则链式组合（`@@` 连接、`||` 取并集、`&&` 取交集）。
public nonisolated class AnalyzeRule {

    // MARK: - 属性

    /// 当前页面基础 URL
    public var baseUrl: String
    /// 当前书源
    public var source: BookSource?
    /// 规则运行时变量（用于 legado 的 `@put` / `java.get`）
    public let variableStore: ParserVariableStore
    /// JavaScript 执行器（懒加载）
    private let jsParser: JavaScriptParser

    // MARK: - 初始化

    public init(
        baseUrl: String = "",
        source: BookSource? = nil,
        variableStore: ParserVariableStore = ParserVariableStore()
    ) {
        self.baseUrl = baseUrl
        self.source = source
        self.variableStore = variableStore
        self.jsParser = JavaScriptParser(baseUrl: baseUrl, source: source, variableStore: variableStore)
    }

    // 工程开启了默认 MainActor 隔离后，普通 deinit 会被推断到 actor 上下文。
    // AnalyzeRule 又持有 JavaScriptParser，而 compare 批量跑里这些对象经常在后台线程短生命周期创建/销毁。
    // 这里显式标记 nonisolated，避免对象释放阶段被错误拉回主线程，进而触发
    // JavaScriptCore/bridge 清理时的线程与生命周期错配。
    nonisolated deinit {}

    /// Inject a `book` JS variable so init / toc / content rules can read detail semantics.
    ///
    /// Android legado 会让详情阶段解析出来的书籍语义继续参与目录、正文和后续 JS 规则。
    /// iOS 之前经常只把当前页面内容传给 JS，导致 `book.bookUrl`、`book.tocUrl`、
    /// `book.name` 或 `book.getVariable(...)` 这类依赖详情上下文的规则在后续阶段失效。
    /// 这里统一把 book payload 提前灌进 `JavaScriptParser`，保证同一条阅读链路里的 JS
    /// 可以读取稳定的书籍上下文，而不是依赖某次页面解析时临时拼出来的变量。
    public func injectBookVariable(
        bookUrl: String,
        name: String = "",
        author: String = "",
        kind: String = "",
        tocUrl: String = "",
        bookVariables: [String: String] = [:]
    ) {
        jsParser.injectBook(
            bookUrl: bookUrl,
            name: name,
            author: author,
            kind: kind,
            tocUrl: tocUrl,
            bookVariables: bookVariables
        )
    }

    /// 更新当前 JS 规则上下文内容，供 `src` / `content` / `java.getString(...)` 等桥接读取。
    ///
    /// 这一步不仅是把字符串塞给 JS 变量，更重要的是同步刷新 bridge 侧缓存，
    /// 让 `java.ajax`、`java.connect`、`jsoup.parse` 等后续调用拿到的是当前规则链真实输入，
    /// 避免沿用上一条规则或上一页内容造成“规则看起来执行了，实际吃的是旧上下文”。
    internal func updateContextContent(_ content: String) {
        jsParser.updateContextContent(content)
    }

    /// 执行原始 JS，并注入 `result` 变量。
    internal func evaluateJS(script: String, result: String = "") throws -> String {
        try jsParser.evaluate(script: script, result: result)
    }

    /// 执行原始 JS，并将 `result` 注入为对象/数组等原始 JS 值。
    internal func evaluateJS(script: String, resultObject: Any, fallbackResult: String = "") throws -> String {
        try jsParser.evaluate(script: script, resultObject: resultObject, fallbackResult: fallbackResult)
    }

    /// 执行原始 JS，并尽量保留数组 / 对象等原始值。
    internal func evaluateJSValue(script: String, result: String = "", results: [String] = []) throws -> Any? {
        try jsParser.evaluateValue(script: script, result: result, results: results)
    }

    /// 执行原始 JS，并将 `result` 注入为对象/数组等原始值，尽量保留数组 / 对象结构。
    internal func evaluateJSValue(script: String, resultObject: Any, fallbackResult: String = "") throws -> Any? {
        try jsParser.evaluateValue(script: script, resultObject: resultObject, fallbackResult: fallbackResult)
    }

    // MARK: - 字符串提取

    /// 从 HTML/JSON/文本 内容中按规则提取字符串
    /// - Parameters:
    ///   - content: 待解析的原始内容（HTML、JSON 字符串等）
    ///   - rule: legado 格式的规则字符串
    /// - Returns: 提取的字符串，若无结果返回空字符串
    public func getString(content: String, rule: String, isUrl: Bool = false) throws -> String {
        guard !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        do {
            let results = try getStringList(content: content, rule: rule, isUrl: isUrl)
            let result = results.first ?? ""
            ParserLog.debug(
                "AnalyzeRule",
                "content rule=\(ParserLog.preview(rule)) isUrl=\(isUrl) count=\(results.count) result=\(ParserLog.preview(result))"
            )
            return result
        } catch {
            ParserLog.debug(
                "AnalyzeRule",
                "content rule=\(ParserLog.preview(rule)) failed error=\(error.localizedDescription)"
            )
            throw error
        }
    }

    /// 从内容中按规则提取结构化值。
    ///
    /// 用于 Android legado 会把 JS 返回对象继续传给后续规则的场景。
    public func getValue(content: String, rule: String) throws -> Any? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }

        jsParser.updateContextContent(content)

        if trimmedRule.contains("<js>") {
            return try evaluateMixedJSRuleValue(content: content, rule: trimmedRule)
        }

        let (mainRule, jsCode) = RuleAnalyzer.extractJS(trimmedRule)
        if let jsCode {
            let resolvedJSCode = RuleAnalyzer.containsTemplate(jsCode)
                ? try renderTemplate(content: content, rule: jsCode)
                : jsCode
            if let mainRule, !mainRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let resolvedValue = try resolveRuleValue(content: content, rule: mainRule) ?? content
                let fallbackResult = stringifyRuleValue(resolvedValue) ?? content
                return try jsParser.evaluateValue(
                    script: resolvedJSCode,
                    resultObject: resolvedValue,
                    fallbackResult: fallbackResult
                )
            }
            return try jsParser.evaluateValue(script: resolvedJSCode, result: content)
        }

        return try resolveRuleValue(content: content, rule: trimmedRule)
    }

    /// 从 HTML Element 中按规则提取字符串
    public func getString(element: Element, rule: String, isUrl: Bool = false) throws -> String {
        guard !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        do {
            let results = try getStringList(element: element, rule: rule, isUrl: isUrl)
            let result = results.first ?? ""
            ParserLog.debug(
                "AnalyzeRule",
                "element rule=\(ParserLog.preview(rule)) isUrl=\(isUrl) count=\(results.count) result=\(ParserLog.preview(result))"
            )
            return result
        } catch {
            ParserLog.debug(
                "AnalyzeRule",
                "element rule=\(ParserLog.preview(rule)) failed error=\(error.localizedDescription)"
            )
            throw error
        }
    }

    // MARK: - 字符串列表提取

    /// 从内容中按规则提取字符串列表
    public func getStringList(content: String, rule: String, isUrl: Bool = false) throws -> [String] {
        guard !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        if shouldPrimeJavaScriptContext(for: rule) {
            jsParser.updateContextContent(content)
        }

        if rule.contains("<js>") {
            if let structuredResults = structuredStringList(
                from: try evaluateMixedJSRuleValue(content: content, rule: rule)
            ) {
                return postProcess(results: structuredResults, isUrl: isUrl)
            }
            let results = try evaluateMixedJSRule(content: content, rule: rule)
            return postProcess(results: results, isUrl: isUrl)
        }

        let (mainRule, jsCode) = RuleAnalyzer.extractJS(rule)
        var results: [String] = []

        if let mainRule = mainRule, !mainRule.trimmingCharacters(in: .whitespaces).isEmpty {
            results = try applyRule(content: content, rule: mainRule)
        } else {
            results = [content]
        }

        if let jsCode = jsCode {
            let resolvedJSCode = RuleAnalyzer.containsTemplate(jsCode)
                ? try renderTemplate(content: content, rule: jsCode)
                : jsCode
            let jsResult: String
            if let mainRule = mainRule, !mainRule.trimmingCharacters(in: .whitespaces).isEmpty {
                jsResult = try jsParser.evaluate(script: resolvedJSCode, results: results)
            } else {
                jsResult = try jsParser.evaluate(script: resolvedJSCode, result: content)
            }
            results = [jsResult]
        }

        return postProcess(results: results, isUrl: isUrl)
    }

    /// 从 Element 中按规则提取字符串列表
    public func getStringList(element: Element, rule: String, isUrl: Bool = false) throws -> [String] {
        guard !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let contentContext = try element.outerHtml()
        if shouldPrimeJavaScriptContext(for: rule) {
            jsParser.updateContextContent(contentContext)
        }

        if rule.contains("<js>") {
            if let structuredResults = structuredStringList(
                from: try evaluateMixedJSRuleValue(content: contentContext, rule: rule)
            ) {
                return postProcess(results: structuredResults, isUrl: isUrl)
            }
            let results = try evaluateMixedJSRule(element: element, content: contentContext, rule: rule)
            return postProcess(results: results, isUrl: isUrl)
        }

        let (mainRule, jsCode) = RuleAnalyzer.extractJS(rule)
        var results: [String] = []

        if let mainRule = mainRule, !mainRule.trimmingCharacters(in: .whitespaces).isEmpty {
            results = try applyRuleToElement(element: element, rule: mainRule)
        } else {
            results = [contentContext]
        }

        if let jsCode = jsCode {
            let resolvedJSCode = RuleAnalyzer.containsTemplate(jsCode)
                ? try renderTemplate(content: contentContext, rule: jsCode)
                : jsCode
            let jsResult: String
            if let mainRule = mainRule, !mainRule.trimmingCharacters(in: .whitespaces).isEmpty {
                jsResult = try jsParser.evaluate(script: resolvedJSCode, results: results)
            } else {
                jsResult = try jsParser.evaluate(script: resolvedJSCode, result: contentContext)
            }
            results = [jsResult]
        }

        return postProcess(results: results, isUrl: isUrl)
    }

    // MARK: - 元素列表提取

    /// 从 HTML 内容中按规则提取元素列表（用于解析列表型规则）
    public func getElements(content: String, rule: String) throws -> [Element] {
        let normalizedRule = normalizeElementListPrefix(rule)
        guard !normalizedRule.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let (_, jsCode) = RuleAnalyzer.extractJS(normalizedRule)
        if jsCode == nil, !normalizedRule.contains("<js>") {
            let splitResult = RuleAnalyzer.splitRulesWithOperator(normalizedRule)
            if splitResult.operator == "||" {
                for subRule in splitResult.parts {
                    let elements = (try? getElements(content: content, rule: subRule)) ?? []
                    if !elements.isEmpty { return elements }
                }
                return []
            }

            if splitResult.operator == "&&" || splitResult.operator == "@@" {
                var combined: [Element] = []
                for subRule in splitResult.parts {
                    combined.append(contentsOf: try getElements(content: content, rule: subRule))
                }
                return combined
            }

            if splitResult.operator == "%%" {
                let groups = try splitResult.parts.map { try getElements(content: content, rule: $0) }
                return interleaveElements(groups)
            }
        }

        jsParser.updateContextContent(content)
        let evaluatedRule = RuleAnalyzer.containsTemplate(normalizedRule)
            ? try renderTemplate(content: content, rule: normalizedRule)
            : normalizedRule
        let ruleType = RuleAnalyzer.ruleType(for: evaluatedRule)
        let cleanedRule = RuleAnalyzer.cleanRule(evaluatedRule)

        let elements: [Element]
        switch ruleType {
        case .css:
            elements = try CSSParser.getElements(from: content, rule: cleanedRule, baseUrl: baseUrl)
        case .default:
            elements = try CSSParser.getElementsTraversing(from: content, rule: cleanedRule, baseUrl: baseUrl)
        case .xpath:
            elements = try XPathParser.getElements(from: content, rule: evaluatedRule, baseUrl: baseUrl)
        case .jsonPath:
            elements = []
        case .javascript:
            let jsResult = try jsParser.evaluate(script: cleanedRule)
            elements = try CSSParser.getElements(from: jsResult, rule: "*")
        case .regex:
            elements = []
        }

        ParserLog.debug(
            "AnalyzeRule",
            "elements rule=\(ParserLog.preview(rule)) evaluated=\(ParserLog.preview(evaluatedRule)) count=\(elements.count)"
        )
        return elements
    }

    public func resolveStructuredValue(content: String, rule: String) throws -> Any? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }

        let (_, jsCode) = RuleAnalyzer.extractJS(trimmedRule)
        if jsCode == nil, !trimmedRule.contains("<js>") {
            let splitResult = RuleAnalyzer.splitRulesWithOperator(trimmedRule)
            if splitResult.operator == "||" {
                for subRule in splitResult.parts {
                    if let value = try resolveStructuredValue(content: content, rule: subRule),
                       structuredValueIsUsable(value) {
                        return value
                    }
                }
                return nil
            }

            if splitResult.operator == "&&" || splitResult.operator == "@@" {
                var combined: [Any] = []
                for subRule in splitResult.parts {
                    if let value = try resolveStructuredValue(content: content, rule: subRule) {
                        combined.append(contentsOf: flattenStructuredValues(value))
                    }
                }
                return combined
            }
        }

        return try resolveRuleValue(content: content, rule: trimmedRule)
    }

    // MARK: - 私有辅助

    /// legado list rules may prefix CSS/XPath selectors with `+` or `-` to control order.
    private func normalizeElementListPrefix(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "+" || first == "-" else { return rule }
        let rest = trimmed.dropFirst()
        guard rest.hasPrefix("@css:")
            || rest.hasPrefix("@xpath:")
            || rest.hasPrefix("//")
            || rest.hasPrefix(".")
            || rest.hasPrefix("#")
            || rest.hasPrefix("[")
            || rest.hasPrefix("*")
            || rest.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(?:[.#\[:@ >]|$)"#, options: .regularExpression) != nil else {
            return rule
        }
        return String(rest)
    }

    /// 对内容应用单条规则（自动判断类型）
    private func applyRule(content: String, rule: String) throws -> [String] {
        let splitResult = RuleAnalyzer.splitRulesWithOperator(rule)

        if splitResult.operator == "||" {
            for subRule in splitResult.parts {
                let results: [String]
                do {
                    results = try applyRule(content: content, rule: subRule)
                } catch {
                    ParserLog.debug(
                        "AnalyzeRule",
                        "fallback branch skipped rule=\(ParserLog.preview(subRule)) error=\(error.localizedDescription)"
                    )
                    continue
                }
                if !results.isEmpty { return results }
            }
            return []
        }

        if splitResult.operator == "&&" {
            var combined: [String] = []
            for subRule in splitResult.parts {
                let results = try applyRule(content: content, rule: subRule)
                combined.append(contentsOf: results)
            }
            return combined
        }

        if splitResult.operator == "@@" {
            var combined = ""
            for subRule in splitResult.parts {
                let results = try applyRule(content: content, rule: subRule)
                combined += results.joined(separator: "")
            }
            return combined.isEmpty ? [] : [combined]
        }

        if splitResult.operator == "%%" {
            var resultGroups: [[String]] = []
            for subRule in splitResult.parts {
                resultGroups.append(try applyRule(content: content, rule: subRule))
            }
            return interleave(resultGroups)
        }

        return try applySingleRule(content: content, rule: rule)
    }

    /// 应用单条规则到 Element（支持 ||、&&、@@、%% 组合操作符，与 applyRule 对齐）
    private func applyRuleToElement(element: Element, rule: String) throws -> [String] {
        let splitResult = RuleAnalyzer.splitRulesWithOperator(rule)

        if splitResult.operator == "||" {
            for subRule in splitResult.parts {
                let results: [String]
                do {
                    results = try applyRuleToElement(element: element, rule: subRule)
                } catch {
                    ParserLog.debug(
                        "AnalyzeRule",
                        "element fallback branch skipped rule=\(ParserLog.preview(subRule)) error=\(error.localizedDescription)"
                    )
                    continue
                }
                if !results.isEmpty { return results }
            }
            return []
        }

        if splitResult.operator == "&&" {
            var combined: [String] = []
            for subRule in splitResult.parts {
                let results = try applyRuleToElement(element: element, rule: subRule)
                combined.append(contentsOf: results)
            }
            return combined
        }

        if splitResult.operator == "@@" {
            var combined = ""
            for subRule in splitResult.parts {
                let results = try applyRuleToElement(element: element, rule: subRule)
                combined += results.joined(separator: "")
            }
            return combined.isEmpty ? [] : [combined]
        }

        if splitResult.operator == "%%" {
            var resultGroups: [[String]] = []
            for subRule in splitResult.parts {
                resultGroups.append(try applyRuleToElement(element: element, rule: subRule))
            }
            return interleave(resultGroups)
        }

        let ruleAfterGet = RuleAnalyzer.substituteGetVariables(rule, variableStore: variableStore)
        let (ruleAfterPut, putMap) = RuleAnalyzer.extractPutOptions(ruleAfterGet)
        applyPutOptions(putMap, element: element)

        let originalRuleAfterPut = RuleAnalyzer.extractPutOptions(rule).cleanRule
        let (originalRuleWithoutHash, _, _, _) = RuleAnalyzer.extractHashPattern(originalRuleAfterPut)
        let (ruleWithoutHash, hashRegex, hashReplacement, hashReplaceFirst) = RuleAnalyzer.extractHashPattern(ruleAfterPut)

        if isStandaloneGetRule(originalRuleWithoutHash) {
            var results = ruleWithoutHash.isEmpty ? [] : [ruleWithoutHash]
            if let regex = hashRegex {
                results = RuleAnalyzer.applyHashReplace(
                    results,
                    regex: regex,
                    replacement: hashReplacement,
                    replaceFirst: hashReplaceFirst
                )
            }
            return results
        }

        if RuleAnalyzer.containsTemplate(ruleWithoutHash) {
            let rendered = try renderTemplate(element: element, rule: ruleWithoutHash)
            let results: [String]
            if shouldContinueEvaluatingRenderedRule(rendered, originalRule: ruleWithoutHash) {
                results = try applyRuleToElement(element: element, rule: rendered)
            } else {
                results = rendered.isEmpty ? [] : [rendered]
            }
            if let regex = hashRegex {
                return RuleAnalyzer.applyHashReplace(
                    results,
                    regex: regex,
                    replacement: hashReplacement,
                    replaceFirst: hashReplaceFirst
                )
            }
            return results
        }

        let ruleType = RuleAnalyzer.ruleType(for: ruleWithoutHash)
        let cleanedRule = RuleAnalyzer.cleanRule(ruleWithoutHash)

        var results: [String]
        switch ruleType {
        case .css:
            // CSS 模式：最后一个 @ 分隔选择器与属性，由 CSSParser 负责处理
            results = try CSSParser.getStringList(from: element, rule: cleanedRule, baseUrl: baseUrl)
        case .default:
            // 默认模式：@ 作为多级 DOM 遍历分隔符；非法选择器按空结果处理，再回退文本正则。
            if let r = try? CSSParser.getStringListTraversing(from: element, rule: cleanedRule, baseUrl: baseUrl),
               !r.isEmpty {
                results = r
            } else if let text = try? element.text() {
                results = (try? RegexParser.getStringList(from: text, rule: cleanedRule)) ?? []
            } else {
                results = []
            }
        case .xpath:
            results = try XPathParser.getStringList(from: element, rule: ruleWithoutHash, baseUrl: baseUrl)
        case .regex:
            let text = try element.text()
            results = try RegexParser.getStringList(from: text, rule: cleanedRule)
        case .jsonPath:
            let text = try element.text()
            results = try JSONPathParser.getStringList(from: text, rule: cleanedRule)
        case .javascript:
            let html = try element.outerHtml()
            let result = try jsParser.evaluate(script: cleanedRule, result: html)
            results = result.isEmpty ? [] : [result]
        }

        if let regex = hashRegex {
            results = RuleAnalyzer.applyHashReplace(
                results,
                regex: regex,
                replacement: hashReplacement,
                replaceFirst: hashReplaceFirst
            )
        }
        return results
    }

    /// 以 legado `%%` 语义交错合并多个结果列表。
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
        ParserLog.debug("AnalyzeRule", "interleave groups=\(groups.count) count=\(combined.count)")
        return combined
    }

    private func interleaveElements(_ groups: [[Element]]) -> [Element] {
        guard let maxCount = groups.map(\.count).max(), maxCount > 0 else {
            return []
        }

        var combined: [Element] = []
        for index in 0..<maxCount {
            for group in groups where index < group.count {
                combined.append(group[index])
            }
        }
        ParserLog.debug("AnalyzeRule", "interleave element groups=\(groups.count) count=\(combined.count)")
        return combined
    }

    private func isStandaloneGetRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^@get:\{[^}]+\}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 应用单条规则（不包含组合操作符）
    private func applySingleRule(content: String, rule: String) throws -> [String] {
        // 替换 @get:{varName} 变量引用
        let ruleAfterGet = RuleAnalyzer.substituteGetVariables(rule, variableStore: variableStore)
        let (ruleAfterPut, putMap) = RuleAnalyzer.extractPutOptions(ruleAfterGet)
        applyPutOptions(putMap, content: content)

        let ruleAfterPutBeforeGet = RuleAnalyzer.extractPutOptions(rule).cleanRule
        let (originalRuleWithoutHash, _, _, _) = RuleAnalyzer.extractHashPattern(ruleAfterPutBeforeGet)
        let (ruleWithoutHash, hashRegex, hashReplacement, hashReplaceFirst) = RuleAnalyzer.extractHashPattern(ruleAfterPut)

        if isStandaloneGetRule(originalRuleWithoutHash) {
            var results = ruleWithoutHash.isEmpty ? [] : [ruleWithoutHash]
            if let regex = hashRegex {
                results = RuleAnalyzer.applyHashReplace(
                    results,
                    regex: regex,
                    replacement: hashReplacement,
                    replaceFirst: hashReplaceFirst
                )
            }
            return results
        }

        if RuleAnalyzer.containsTemplate(ruleWithoutHash) {
            let rendered = try renderTemplate(content: content, rule: ruleWithoutHash)
            let shouldContinueEvaluating = shouldContinueEvaluatingRenderedRule(rendered, originalRule: ruleWithoutHash)

            if shouldContinueEvaluating {
                let continuedResults = try applySingleRule(content: content, rule: rendered)
                if let regex = hashRegex {
                    return RuleAnalyzer.applyHashReplace(
                        continuedResults,
                        regex: regex,
                        replacement: hashReplacement,
                        replaceFirst: hashReplaceFirst
                    )
                }
                return continuedResults
            }

            var results = rendered.isEmpty ? [] : [rendered]
            if let regex = hashRegex {
                results = RuleAnalyzer.applyHashReplace(
                    results,
                    regex: regex,
                    replacement: hashReplacement,
                    replaceFirst: hashReplaceFirst
                )
            }
            return results
        }

        let ruleType = RuleAnalyzer.ruleType(for: ruleWithoutHash)
        let cleanedRule = RuleAnalyzer.cleanRule(ruleWithoutHash)

        var results: [String]

        switch ruleType {
        case .css:
            // CSS 模式：最后一个 @ 分隔选择器与属性
            results = try CSSParser.getStringList(from: content, rule: cleanedRule, baseUrl: baseUrl)

        case .xpath:
            results = try XPathParser.getStringList(from: content, rule: ruleWithoutHash, baseUrl: baseUrl)

        case .regex:
            results = try RegexParser.getStringList(from: content, rule: cleanedRule)

        case .jsonPath:
            results = try JSONPathParser.getStringList(from: content, rule: cleanedRule)

        case .javascript:
            let result = try jsParser.evaluate(script: cleanedRule, result: content)
            results = result.isEmpty ? [] : [result]

        case .default:
            // 默认先检测内容类型
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJsonContent = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            if isJsonContent {
                // Android 会把 JSON 内容下的默认规则继续按 Json 语义处理，
                // 因此要先尝试原始规则本身，确保 `{$.path}` / `prefix{$.a}` 这类混合写法不会被误补成 `$.prefix...`
                if let r = try? JSONPathParser.getStringList(from: content, rule: cleanedRule), !r.isEmpty {
                    results = r
                } else {
                    let jsonRule: String
                    if cleanedRule.hasPrefix("$.") || cleanedRule.hasPrefix("$[") || cleanedRule.hasPrefix("@.") || cleanedRule.hasPrefix(".") {
                        jsonRule = cleanedRule
                    } else if cleanedRule.hasPrefix("$") {
                        jsonRule = cleanedRule
                    } else {
                        jsonRule = "$.\(cleanedRule)"
                    }
                    if let r = try? JSONPathParser.getStringList(from: content, rule: jsonRule), !r.isEmpty {
                        results = r
                    } else {
                        results = []
                    }
                }
            } else {
                // HTML 内容：使用 @ 多级遍历（对应 legado 的 getResultList 逻辑）
                // CSSParser.getStringListTraversing 正确处理 `selector@selector@attr` 多级 @ 分隔
                if let r = try? CSSParser.getStringListTraversing(from: content, rule: cleanedRule, baseUrl: baseUrl),
                   !r.isEmpty {
                    results = r
                } else {
                    // 回退到正则
                    results = (try? RegexParser.getStringList(from: content, rule: cleanedRule)) ?? []
                }
            }
        }

        if let regex = hashRegex {
            results = RuleAnalyzer.applyHashReplace(
                results,
                regex: regex,
                replacement: hashReplacement,
                replaceFirst: hashReplaceFirst
            )
        }
        return results
    }

    private func renderTemplate(content: String, rule: String) throws -> String {
        let pattern = #"\{\{([\s\S]*?)\}\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return rule }

        var rendered = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range(at: 0)
            let exprRange = match.range(at: 1)
            if fullRange.location > cursor {
                rendered += nsRule.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let expression = nsRule.substring(with: exprRange).trimmingCharacters(in: .whitespacesAndNewlines)
            rendered += try evaluateTemplateExpression(content: content, expression: expression)
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsRule.length {
            rendered += nsRule.substring(from: cursor)
        }
        return rendered
    }

    internal func renderTemplateRule(content: String, rule: String) throws -> String {
        try renderTemplate(content: content, rule: rule)
    }

    private func renderTemplate(element: Element, rule: String) throws -> String {
        let content = try element.outerHtml()
        let pattern = #"\{\{([\s\S]*?)\}\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return rule }

        var rendered = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range(at: 0)
            let exprRange = match.range(at: 1)
            if fullRange.location > cursor {
                rendered += nsRule.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let expression = nsRule.substring(with: exprRange).trimmingCharacters(in: .whitespacesAndNewlines)
            rendered += try evaluateTemplateExpression(element: element, content: content, expression: expression)
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsRule.length {
            rendered += nsRule.substring(from: cursor)
        }
        return rendered
    }

    private func evaluateTemplateExpression(content: String, expression: String) throws -> String {
        guard !expression.isEmpty else { return "" }

        // Strip leading @@ (legado concatenation operator misused in templates, e.g. {{@@baseUrl}})
        // @@baseUrl means "the book source base URL", resolve to source.bookSourceUrl if available
        let expr: String
        if expression.hasPrefix("@@") {
            let stripped = String(expression.dropFirst(2))
            // If stripped is "baseUrl" and source has a bookSourceUrl, use that directly
            if stripped == "baseUrl", let sourceUrl = source?.bookSourceUrl, !sourceUrl.isEmpty {
                return sourceUrl
            }
            expr = stripped
        } else {
            expr = expression
        }

        if let literal = resolveTemplateStringLiteral(expr) {
            return literal
        }

        if let results = try? applyRule(content: content, rule: expr), !results.isEmpty {
            return results.joined(separator: "")
        }

        jsParser.updateContextContent(content)
        let wrapped = "(() => { return (\(expr)); })()"
        if let jsValue = try? jsParser.evaluate(script: wrapped, result: content), !jsValue.isEmpty {
            return jsValue
        }
        return try jsParser.evaluate(script: expr, result: content)
    }

    private func evaluateTemplateExpression(element: Element, content: String, expression: String) throws -> String {
        guard !expression.isEmpty else { return "" }

        // Strip leading @@ (legado concatenation operator misused in templates)
        let expr = expression.hasPrefix("@@") ? String(expression.dropFirst(2)) : expression

        if let literal = resolveTemplateStringLiteral(expr) {
            return literal
        }

        if let results = try? applyRuleToElement(element: element, rule: expr), !results.isEmpty {
            return results.joined(separator: "")
        }

        jsParser.updateContextContent(content)
        let wrapped = "(() => { return (\(expr)); })()"
        if let jsValue = try? jsParser.evaluate(script: wrapped, result: content), !jsValue.isEmpty {
            return jsValue
        }
        return try jsParser.evaluate(script: expr, result: content)
    }

    private func evaluateMixedJSRule(content: String, rule: String) throws -> [String] {
        let pattern = #"<js>([\s\S]*?)</js>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return try applyRule(content: content, rule: rule) }

        var cursor = 0
        var currentResult = ""
        var hasResult = false

        for match in matches {
            let fullRange = match.range(at: 0)
            let scriptRange = match.range(at: 1)

            if fullRange.location > cursor {
                let segment = nsRule.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
                let value = try evaluateNonJSSegment(content: content, segment: segment, currentResult: currentResult, hasResult: hasResult)
                if !value.isEmpty {
                    currentResult = value
                    hasResult = true
                }
            }

            let script = nsRule.substring(with: scriptRange)
            jsParser.updateContextContent(content)
            let jsInput = hasResult ? currentResult : content
            currentResult = try jsParser.evaluate(script: script, result: jsInput)
            ParserLog.debug(
                "AnalyzeRule",
                "mixedJS segment script=\(ParserLog.preview(script, limit: 160)) currentResult=\(ParserLog.preview(currentResult, limit: 200))"
            )
            hasResult = true
            cursor = fullRange.location + fullRange.length
        }

        if cursor < nsRule.length {
            let segment = nsRule.substring(from: cursor)
            let value = try evaluateNonJSSegment(content: content, segment: segment, currentResult: currentResult, hasResult: hasResult)
            if !value.isEmpty {
                currentResult = value
            }
        }

        return currentResult.isEmpty ? [] : [currentResult]
    }

    private func evaluateMixedJSRuleValue(content: String, rule: String) throws -> Any? {
        let pattern = #"<js>([\s\S]*?)</js>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return try resolveRuleValue(content: content, rule: rule) }

        var cursor = 0
        var currentValue: Any?
        var hasResult = false

        for match in matches {
            let fullRange = match.range(at: 0)
            let scriptRange = match.range(at: 1)

            if fullRange.location > cursor {
                let segment = nsRule.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
                if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let value = try evaluateNonJSSegment(
                        content: content,
                        segment: segment,
                        currentResult: stringifyRuleValue(currentValue) ?? "",
                        hasResult: hasResult
                    )
                    if !value.isEmpty {
                        currentValue = value
                        hasResult = true
                    }
                }
            }

            let script = nsRule.substring(with: scriptRange)
            jsParser.updateContextContent(content)
            if let currentResolvedValue = currentValue {
                currentValue = try jsParser.evaluateValue(
                    script: script,
                    resultObject: currentResolvedValue,
                    fallbackResult: stringifyRuleValue(currentResolvedValue) ?? ""
                )
            } else {
                currentValue = try jsParser.evaluateValue(
                    script: script,
                    resultObject: content,
                    fallbackResult: content
                )
            }
            hasResult = true
            cursor = fullRange.location + fullRange.length
        }

        if cursor < nsRule.length {
            let segment = nsRule.substring(from: cursor)
            if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let value = try evaluateNonJSSegment(
                    content: content,
                    segment: segment,
                    currentResult: stringifyRuleValue(currentValue) ?? "",
                    hasResult: hasResult
                )
                if !value.isEmpty {
                    currentValue = value
                }
            }
        }

        return currentValue
    }

    private func evaluateMixedJSRule(element: Element, content: String, rule: String) throws -> [String] {
        let pattern = #"<js>([\s\S]*?)</js>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return try applyRuleToElement(element: element, rule: rule) }

        var cursor = 0
        var currentResult = ""
        var hasResult = false

        for match in matches {
            let fullRange = match.range(at: 0)
            let scriptRange = match.range(at: 1)

            if fullRange.location > cursor {
                let segment = nsRule.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
                let value = try evaluateNonJSSegment(element: element, segment: segment, currentResult: currentResult, hasResult: hasResult)
                if !value.isEmpty {
                    currentResult = value
                    hasResult = true
                }
            }

            let script = nsRule.substring(with: scriptRange)
            jsParser.updateContextContent(content)
            let jsInput = hasResult ? currentResult : content
            currentResult = try jsParser.evaluate(script: script, result: jsInput)
            hasResult = true
            cursor = fullRange.location + fullRange.length
        }

        if cursor < nsRule.length {
            let segment = nsRule.substring(from: cursor)
            let value = try evaluateNonJSSegment(element: element, segment: segment, currentResult: currentResult, hasResult: hasResult)
            if !value.isEmpty {
                currentResult = value
            }
        }

        return currentResult.isEmpty ? [] : [currentResult]
    }

    private func evaluateNonJSSegment(
        content: String,
        segment: String,
        currentResult: String,
        hasResult: Bool
    ) throws -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentResult }

        let replaced = replaceResultPlaceholders(in: trimmed, with: currentResult)
        if replaced != trimmed {
            return replaced
        }
        if hasResult {
            if let values = try? applyRule(content: currentResult, rule: trimmed), !values.isEmpty {
                return values.joined(separator: "")
            }
            if shouldAppendMixedJSLiteralSuffix(trimmed) {
                return currentResult + trimmed
            }
            return ""
        }
        let values = try applyRule(content: content, rule: trimmed)
        return values.joined(separator: "")
    }

    private func evaluateNonJSSegment(
        element: Element,
        segment: String,
        currentResult: String,
        hasResult: Bool
    ) throws -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentResult }

        let replaced = replaceResultPlaceholders(in: trimmed, with: currentResult)
        if replaced != trimmed {
            return replaced
        }
        if hasResult {
            if let values = try? applyRule(content: currentResult, rule: trimmed), !values.isEmpty {
                return values.joined(separator: "")
            }
            if shouldAppendMixedJSLiteralSuffix(trimmed) {
                return currentResult + trimmed
            }
            return ""
        }
        let values = try applyRuleToElement(element: element, rule: trimmed)
        return values.joined(separator: "")
    }

    /// Android legado 的 `<js>...</js>selector` 会把尾段继续作用在 JS 返回内容上；
    /// 只有像 `,{'webView': true}` 这种 descriptor 后缀才应该直接拼回结果。
    /// iOS 旧实现把尾段原样当字符串返回，会让 `p.sone` 这类尾选择器退化成字面量。
    private func shouldAppendMixedJSLiteralSuffix(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(",") || trimmed.hasPrefix("&") || trimmed.hasPrefix("?") {
            return true
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return true
        }
        return false
    }

    private func replaceResultPlaceholders(in input: String, with value: String) -> String {
        input
            .replacingOccurrences(of: "@result", with: value)
            .replacingOccurrences(of: "{{result}}", with: value)
            .replacingOccurrences(of: "{result}", with: value)
    }

    private func shouldPrimeJavaScriptContext(for rule: String) -> Bool {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return false }
        if trimmedRule.contains("<js>") {
            return true
        }
        let (_, jsCode) = RuleAnalyzer.extractJS(trimmedRule)
        if jsCode != nil {
            return true
        }
        if RuleAnalyzer.containsTemplate(trimmedRule) {
            return true
        }
        return false
    }

    private func resolveRuleValue(content: String, rule: String) throws -> Any? {
        let renderedRule = RuleAnalyzer.containsTemplate(rule)
            ? try renderTemplate(content: content, rule: rule)
            : rule
        let ruleType = RuleAnalyzer.ruleType(for: renderedRule)
        let cleanedRule = RuleAnalyzer.cleanRule(renderedRule)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJsonContent = trimmedContent.hasPrefix("{") || trimmedContent.hasPrefix("[")

        switch ruleType {
        case .jsonPath:
            if let objects = try? JSONPathParser.getObjects(from: content, rule: cleanedRule),
               !objects.isEmpty {
                return objects.count == 1 ? objects[0] : objects
            }
            let results = try JSONPathParser.getStringList(from: content, rule: cleanedRule)
            if results.count > 1 {
                return results
            }
            return results.first
        case .css:
            return try CSSParser.getStringList(from: content, rule: cleanedRule, baseUrl: baseUrl)
        case .default:
            if isJsonContent {
                if let objects = try? JSONPathParser.getObjects(from: content, rule: cleanedRule),
                   !objects.isEmpty {
                    return objects.count == 1 ? objects[0] : objects
                }
                let normalizedRule: String
                if cleanedRule.hasPrefix("$.") || cleanedRule.hasPrefix("$[") || cleanedRule.hasPrefix("@.") || cleanedRule.hasPrefix(".") {
                    normalizedRule = cleanedRule
                } else if cleanedRule.hasPrefix("$") {
                    normalizedRule = cleanedRule
                } else {
                    normalizedRule = "$.\(cleanedRule)"
                }
                if let objects = try? JSONPathParser.getObjects(from: content, rule: normalizedRule),
                   !objects.isEmpty {
                    return objects.count == 1 ? objects[0] : objects
                }
            }
            return try CSSParser.getStringListTraversing(from: content, rule: cleanedRule, baseUrl: baseUrl)
        case .xpath:
            return try XPathParser.getStringList(from: content, rule: renderedRule, baseUrl: baseUrl)
        case .javascript:
            return try jsParser.evaluateValue(script: cleanedRule, result: content)
        case .regex:
            return try RegexParser.getStringList(from: content, rule: cleanedRule)
        }
    }

    private func stringifyRuleValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        if let array = value as? [String] {
            return array.joined(separator: "\n")
        }
        return "\(value)"
    }

    private func structuredStringList(from value: Any?) -> [String]? {
        guard let value else {
            return nil
        }

        if let array = value as? [Any] {
            return array.flatMap { element -> [String] in
                if let nested = structuredStringList(from: element) {
                    return nested
                }
                return []
            }
        }

        if let string = value as? String {
            return [string]
        }

        if let serialized = stringifyRuleValue(value) {
            return [serialized]
        }

        return nil
    }

    private func flattenStructuredValues(_ value: Any) -> [Any] {
        if let array = value as? [Any] {
            return array.flatMap { element -> [Any] in
                if let nested = element as? [Any] {
                    return flattenStructuredValues(nested)
                }
                return [element]
            }
        }
        return [value]
    }

    private func structuredValueIsUsable(_ value: Any) -> Bool {
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return !flattenStructuredValues(array).isEmpty
        }
        return true
    }

    private func postProcess(results: [String], isUrl: Bool) -> [String] {
        let filtered = results
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard isUrl else {
            return filtered
        }

        return filtered
            .flatMap { AnalyzeUrl.postProcessExtractedURLs($0, baseUrl: baseUrl, variableStore: variableStore) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func applyPutOptions(_ putMap: [String: String], content: String) {
        guard !putMap.isEmpty else { return }
        for (key, valueRule) in putMap {
            let value = (try? getString(content: content, rule: valueRule, isUrl: false)) ?? valueRule
            variableStore.put(key, value: value)
        }
    }

    private func applyPutOptions(_ putMap: [String: String], element: Element) {
        guard !putMap.isEmpty else { return }
        for (key, valueRule) in putMap {
            let value = (try? getString(element: element, rule: valueRule, isUrl: false)) ?? valueRule
            variableStore.put(key, value: value)
        }
    }

    private func shouldContinueEvaluatingRenderedRule(_ rendered: String, originalRule: String) -> Bool {
        let trimmedRendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRendered.isEmpty else { return false }
        if trimmedRendered == originalRule.trimmingCharacters(in: .whitespacesAndNewlines) {
            return false
        }

        if trimmedRendered.contains("<js>") || trimmedRendered.contains("@js:") || trimmedRendered.contains("{$") {
            return true
        }

        let renderedRuleType = RuleAnalyzer.ruleType(for: trimmedRendered)
        switch renderedRuleType {
        case .javascript, .jsonPath, .xpath, .css:
            return true
        case .default:
            return looksLikeEvaluatableDefaultRule(trimmedRendered)
        case .regex:
            return false
        }
    }

    private func looksLikeEvaluatableDefaultRule(_ rendered: String) -> Bool {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if looksLikeAbsoluteURL(trimmed) {
            return false
        }
        if trimmed.hasPrefix("//") {
            return true
        }
        if trimmed.hasPrefix("@") || trimmed.hasPrefix(".") || trimmed.hasPrefix("#") {
            return true
        }
        if trimmed.contains("@") || trimmed.contains("##") || trimmed.contains("&&") || trimmed.contains("||") || trimmed.contains("@@") || trimmed.contains("%%") {
            return true
        }
        if trimmed.contains("[") || trimmed.contains(":") {
            return true
        }
        return false
    }

    private func looksLikeAbsoluteURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return false
        }
        return true
    }

    private func resolveTemplateStringLiteral(_ expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              first == last,
              first == "'" || first == "\"" || first == "`" else {
            return nil
        }

        let inner = String(trimmed.dropFirst().dropLast())
        return decodeTemplateStringEscapes(inner, quote: first)
    }

    private func decodeTemplateStringEscapes(_ value: String, quote: Character) -> String {
        var result = ""
        var iterator = value.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }

            guard let escaped = iterator.next() else {
                result.append("\\")
                break
            }

            switch escaped {
            case "n":
                result.append("\n")
            case "r":
                result.append("\r")
            case "t":
                result.append("\t")
            case "\\":
                result.append("\\")
            case "'":
                result.append("'")
            case "\"":
                result.append("\"")
            case "`":
                result.append("`")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }

        return result
    }
}
