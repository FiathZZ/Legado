import Foundation

// MARK: - ParserRuleRuntime

/// 统一收敛解析器中的“直接规则求值”逻辑，避免详情 / 目录 / 正文各自维护一套
/// 模板展开、变量替换、JSON 直取与字面量 URL 恢复链路。
nonisolated enum ParserRuleRuntime {

    struct Context {
        let baseUrl: String
        let source: BookSource
        let variableStore: ParserVariableStore
    }

    static func directExtractStringList(
        content: String,
        rule: String,
        context: Context,
        isUrl: Bool
    ) throws -> [String]? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return [] }

        if RuleAnalyzer.containsTemplate(trimmedRule) {
            guard let rendered = try directRenderTemplateRule(
                content: content,
                rule: trimmedRule,
                context: context
            ) else {
                return nil
            }
            if rendered == trimmedRule {
                return nil
            }

            let trimmedRendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            if isJavaScriptRule(trimmedRendered) {
                return nil
            }

            if let continued = try directExtractStringList(
                content: content,
                rule: rendered,
                context: context,
                isUrl: isUrl
            ), !continued.isEmpty {
                return continued
            }

            guard !rendered.isEmpty else { return [] }
            if isUrl {
                return AnalyzeUrl.postProcessExtractedURLs(
                    rendered,
                    baseUrl: context.baseUrl,
                    variableStore: context.variableStore
                )
            }
            return [rendered]
        }

        guard canUseDirectRuleExtraction(trimmedRule) else { return nil }

        let substitutedRule = RuleAnalyzer.substituteGetVariables(
            trimmedRule,
            variableStore: context.variableStore
        )
        let (ruleAfterPut, putMap) = RuleAnalyzer.extractPutOptions(substitutedRule)
        guard putMap.isEmpty else { return nil }

        let (ruleWithoutHash, hashRegex, hashReplacement, hashReplaceFirst) = RuleAnalyzer.extractHashPattern(ruleAfterPut)
        let cleanedRule = RuleAnalyzer.cleanRule(ruleWithoutHash)
        let ruleType = RuleAnalyzer.ruleType(for: ruleWithoutHash)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJsonContent = trimmedContent.hasPrefix("{") || trimmedContent.hasPrefix("[")

        if isUrl,
           ruleType == .default,
           AnalyzeUrl.looksLikeLiteralURLRule(cleanedRule, variableStore: context.variableStore) {
            return AnalyzeUrl.postProcessExtractedURLs(
                cleanedRule,
                baseUrl: context.baseUrl,
                variableStore: context.variableStore
            )
        }

        let results: [String]
        switch ruleType {
        case .css:
            results = try CSSParser.getStringList(from: content, rule: cleanedRule, baseUrl: context.baseUrl)
        case .xpath:
            results = try XPathParser.getStringList(from: content, rule: ruleWithoutHash, baseUrl: context.baseUrl)
        case .regex:
            results = try RegexParser.getStringList(from: content, rule: cleanedRule)
        case .jsonPath:
            results = try extractJSONPathStrings(from: content, rule: cleanedRule)
        case .javascript:
            return nil
        case .default:
            if isJsonContent {
                if let direct = try? extractJSONPathStrings(from: content, rule: cleanedRule), !direct.isEmpty {
                    results = direct
                } else {
                    let jsonRule: String
                    if cleanedRule.hasPrefix("$.")
                        || cleanedRule.hasPrefix("$[")
                        || cleanedRule.hasPrefix("@.")
                        || cleanedRule.hasPrefix(".")
                        || cleanedRule.hasPrefix("$") {
                        jsonRule = cleanedRule
                    } else {
                        jsonRule = "$.\(cleanedRule)"
                    }
                    results = (try? extractJSONPathStrings(from: content, rule: jsonRule)) ?? []
                }
            } else if let traversed = try? CSSParser.getStringListTraversing(
                from: content,
                rule: cleanedRule,
                baseUrl: context.baseUrl
            ), !traversed.isEmpty {
                results = traversed
            } else {
                results = (try? RegexParser.getStringList(from: content, rule: cleanedRule)) ?? []
            }
        }

        let finalResults: [String]
        if let hashRegex {
            finalResults = RuleAnalyzer.applyHashReplace(
                results,
                regex: hashRegex,
                replacement: hashReplacement,
                replaceFirst: hashReplaceFirst
            )
        } else {
            finalResults = results
        }

        if isUrl {
            return finalResults.flatMap {
                AnalyzeUrl.postProcessExtractedURLs(
                    $0,
                    baseUrl: context.baseUrl,
                    variableStore: context.variableStore
                )
            }
        }
        return finalResults
    }

    static func directRenderTemplateRule(
        content: String,
        rule: String,
        context: Context
    ) throws -> String? {
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
            guard let evaluated = try directEvaluateTemplateExpression(
                content: content,
                expression: expression,
                context: context
            ) else {
                return nil
            }
            rendered += evaluated
            cursor = fullRange.location + fullRange.length
        }

        if cursor < nsRule.length {
            rendered += nsRule.substring(from: cursor)
        }
        return rendered
    }

    static func directEvaluateTemplateExpression(
        content: String,
        expression: String,
        context: Context
    ) throws -> String? {
        guard !expression.isEmpty else { return "" }

        if expression == "baseUrl" {
            return context.baseUrl
        }
        if expression == "@@baseUrl" {
            return context.source.bookSourceUrl
        }

        if let bookKey = bookTemplateVariableKey(expression) {
            return context.variableStore.get(bookKey)
        }

        if let directResults = try? directExtractStringList(
            content: content,
            rule: expression,
            context: context,
            isUrl: false
        ) {
            return directResults.joined(separator: "")
        }

        if let fallbackKey = simpleTemplateVariableKey(expression) {
            let value = context.variableStore.get(fallbackKey)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    static func renderDirectLiteralURLIfNeeded(
        content: String,
        rule: String,
        context: Context
    ) -> String? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }
        guard !isJavaScriptRule(trimmedRule) else { return nil }
        guard !isStructuredSelectorRule(trimmedRule) else { return nil }

        if RuleAnalyzer.containsTemplate(trimmedRule) {
            let rendered = (
                (try? directRenderTemplateRule(content: content, rule: trimmedRule, context: context))
                ?? renderSimpleLiteralTemplateFallback(rule: trimmedRule, variableStore: context.variableStore)
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !rendered.isEmpty,
               AnalyzeUrl.looksLikeLiteralURLRule(rendered, variableStore: context.variableStore) {
                let resolvedBaseURL = preferredLiteralURLBaseURL(
                    renderedRule: rendered,
                    pageBaseURL: context.baseUrl,
                    sourceBaseURL: context.source.bookSourceUrl
                )
                return AnalyzeUrl.postProcessExtractedURL(
                    rendered,
                    baseUrl: resolvedBaseURL,
                    variableStore: context.variableStore
                )
            }
        }

        let substitutedRule = RuleAnalyzer.substituteGetVariables(trimmedRule, variableStore: context.variableStore)
        guard substitutedRule != trimmedRule,
              AnalyzeUrl.looksLikeLiteralURLRule(substitutedRule, variableStore: context.variableStore) else {
            return nil
        }

        let resolvedBaseURL = preferredLiteralURLBaseURL(
            renderedRule: substitutedRule,
            pageBaseURL: context.baseUrl,
            sourceBaseURL: context.source.bookSourceUrl
        )
        return AnalyzeUrl.postProcessExtractedURL(
            substitutedRule,
            baseUrl: resolvedBaseURL,
            variableStore: context.variableStore
        )
    }

    static func renderJSONLiteralRule(
        item: Any? = nil,
        itemJSON: String,
        rule: String,
        analyzer: AnalyzeRule
    ) -> String? {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return nil }
        guard !isJavaScriptRule(trimmedRule) else { return nil }

        let substitutedRule = RuleAnalyzer.substituteGetVariables(trimmedRule, variableStore: analyzer.variableStore)
        let hasTemplate = RuleAnalyzer.containsTemplate(substitutedRule)
        let containsLiteralVariable = substitutedRule != trimmedRule
        guard hasTemplate || containsLiteralVariable else { return nil }

        if hasTemplate,
           let rendered = renderJSONLiteralTemplateFragments(
                rule: substitutedRule,
                item: item,
                itemJSON: itemJSON,
                analyzer: analyzer
           ) {
            let trimmedRendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRendered.isEmpty {
                return trimmedRendered
            }
        }

        if hasTemplate,
           let rendered = try? analyzer.renderTemplateRule(content: itemJSON, rule: substitutedRule) {
            let trimmedRendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRendered.isEmpty {
                return trimmedRendered
            }
        }

        return substitutedRule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func finalizeJSONFieldValue(
        _ value: String,
        analyzer: AnalyzeRule,
        itemJSON: String,
        isUrl: Bool
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let renderedValue: String
        if RuleAnalyzer.containsTemplate(trimmed),
           let resolved = try? analyzer.renderTemplateRule(content: itemJSON, rule: trimmed),
           !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            renderedValue = resolved
        } else if trimmed.contains("${"),
                  let resolved = renderJavaScriptStyleTemplate(
                    trimmed,
                    analyzer: analyzer,
                    itemJSON: itemJSON
                  ),
                  !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            renderedValue = resolved
        } else {
            renderedValue = trimmed
        }

        guard isUrl else { return renderedValue }

        let normalized = AnalyzeUrl.postProcessExtractedURL(
            renderedValue,
            baseUrl: analyzer.baseUrl,
            variableStore: analyzer.variableStore
        )
        return normalized.isEmpty ? renderedValue : normalized
    }

    static func recoverLiteralURLIfNeeded(
        currentURL: String,
        rule: String,
        pageBaseURL: String,
        sourceBaseURL: String,
        variableStore: ParserVariableStore
    ) -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return currentURL }
        guard !isJavaScriptRule(trimmedRule) else { return currentURL }
        guard !isStructuredSelectorRule(trimmedRule) else { return currentURL }

        let currentIdentity = normalizedURLIdentity(currentURL)
        let pageIdentity = normalizedURLIdentity(pageBaseURL)
        let shouldRecover = currentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || currentIdentity == pageIdentity
            || !isValidResolvedURL(currentURL)
        guard shouldRecover || trimmedRule.hasPrefix("/") else {
            return currentURL
        }

        let renderedRule = (
            renderSimpleLiteralTemplateFallback(
                rule: RuleAnalyzer.substituteGetVariables(trimmedRule, variableStore: variableStore),
                variableStore: variableStore
            ) ?? RuleAnalyzer.substituteGetVariables(trimmedRule, variableStore: variableStore)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard AnalyzeUrl.looksLikeLiteralURLRule(renderedRule, variableStore: variableStore) else {
            return currentURL
        }

        let preferredBaseURL = preferredLiteralURLBaseURL(
            renderedRule: renderedRule,
            pageBaseURL: pageBaseURL,
            sourceBaseURL: sourceBaseURL
        )
        let preferredIdentity = normalizedURLIdentity(
            AnalyzeUrl.postProcessExtractedURL(
                renderedRule,
                baseUrl: preferredBaseURL,
                variableStore: variableStore
            )
        )
        if !preferredIdentity.isEmpty,
           preferredIdentity != currentIdentity,
           trimmedRule.hasPrefix("/") {
            let currentHost = URL(string: currentURL)?.host?.lowercased()
            let preferredHost = URL(string: preferredBaseURL)?.host?.lowercased()
            if let currentHost, let preferredHost, currentHost != preferredHost {
                let recovered = AnalyzeUrl.postProcessExtractedURL(
                    renderedRule,
                    baseUrl: preferredBaseURL,
                    variableStore: variableStore
                )
                return isValidResolvedURL(recovered) ? recovered : currentURL
            }
        }

        if let rebound = rebaseResolvedURLIfNeeded(
            currentURL: currentURL,
            pageBaseURL: pageBaseURL,
            preferredBaseURL: preferredBaseURL
        ) {
            return rebound
        }

        let recovered = AnalyzeUrl.postProcessExtractedURL(
            renderedRule,
            baseUrl: preferredBaseURL,
            variableStore: variableStore
        )
        return isValidResolvedURL(recovered) ? recovered : currentURL
    }

    static func extractJSONPathStrings(from content: String, rule: String) throws -> [String] {
        let candidates = jsonCandidateStrings(from: content)
        for candidate in candidates {
            if let results = try? JSONPathParser.getStringList(from: candidate, rule: rule), !results.isEmpty {
                return results
            }
        }
        return []
    }

    static func jsonCandidateStrings(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return [trimmed]
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*>([\s\S]*?)</script>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        var candidates: [String] = []
        candidates.reserveCapacity(matches.count)

        for match in matches where match.numberOfRanges > 1 {
            let body = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.hasPrefix("{") || body.hasPrefix("[") else { continue }
            candidates.append(body)
        }

        return candidates
    }

    static func renderSimpleLiteralTemplateFallback(
        rule: String,
        variableStore: ParserVariableStore
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) else {
            return nil
        }
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
            let replacement = simpleTemplateVariableKey(expression).flatMap { variableStore.get($0) } ?? ""
            rendered += replacement
            cursor = fullRange.location + fullRange.length
        }

        if cursor < nsRule.length {
            rendered += nsRule.substring(from: cursor)
        }
        return rendered
    }

    static func renderJavaScriptStyleTemplate(
        _ template: String,
        analyzer: AnalyzeRule,
        itemJSON: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\$\{([\s\S]*?)\}"#) else {
            return nil
        }
        let nsTemplate = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length))
        guard !matches.isEmpty else { return nil }

        var rendered = template
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: rendered),
                  let exprRange = Range(match.range(at: 1), in: rendered) else {
                continue
            }
            let expression = String(rendered[exprRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = resolveJavaScriptStyleTemplateExpression(
                expression,
                analyzer: analyzer,
                itemJSON: itemJSON
            )
            rendered.replaceSubrange(fullRange, with: replacement)
        }
        return rendered
    }

    static func preferredLiteralURLBaseURL(
        renderedRule: String,
        pageBaseURL: String,
        sourceBaseURL: String
    ) -> String {
        let trimmedRule = renderedRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedRule.hasPrefix("/"),
              let pageURL = URL(string: pageBaseURL),
              let sourceURL = URL(string: sourceBaseURL),
              let pageHost = pageURL.host?.lowercased(),
              let sourceHost = sourceURL.host?.lowercased(),
              pageHost != sourceHost else {
            return pageBaseURL
        }

        let pagePath = pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pagePath.isEmpty || pagePath == "index.html" {
            return sourceBaseURL
        }

        return pageBaseURL
    }

    static func simpleTemplateVariableKey(_ expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "$.", with: "")
            .replacingOccurrences(of: "@.", with: "")
        guard !normalized.contains("["),
              !normalized.contains("("),
              !normalized.contains(" "),
              let last = normalized.split(separator: ".").last else {
            return nil
        }
        return String(last)
    }

    static func bookTemplateVariableKey(_ expression: String) -> String? {
        switch expression {
        case "book.bookUrl":
            return "bookUrl"
        case "book.name":
            return "name"
        case "book.author":
            return "author"
        case "book.kind":
            return "kind"
        case "book.tocUrl":
            return "tocUrl"
        default:
            return nil
        }
    }

    static func lastVariableComponent(in expression: String) -> String? {
        let normalized = expression
            .replacingOccurrences(of: "$.", with: "")
            .replacingOccurrences(of: "@.", with: "")
        return normalized.split(separator: ".").last.map(String.init)
    }

    static func canUseDirectRuleExtraction(_ rule: String) -> Bool {
        guard !rule.isEmpty else { return false }
        guard !RuleAnalyzer.containsTemplate(rule) else { return false }
        guard !rule.contains("<js>") else { return false }
        guard RuleAnalyzer.extractJS(rule).1 == nil else { return false }
        guard !rule.localizedCaseInsensitiveContains("@put:") else { return false }
        let split = RuleAnalyzer.splitRulesWithOperator(rule)
        return split.operator.isEmpty
    }

    static func isJavaScriptRule(_ rule: String) -> Bool {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedRule.hasPrefix("<js>") || trimmedRule.contains("@js:")
    }

    private static func renderJSONLiteralTemplateFragments(
        rule: String,
        item: Any?,
        itemJSON: String,
        analyzer: AnalyzeRule
    ) -> String? {
        guard RuleAnalyzer.containsTemplate(rule),
              let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) else {
            return nil
        }

        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        guard !matches.isEmpty else { return rule }

        var rendered = rule
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: rendered),
                  let exprRange = Range(match.range(at: 1), in: rendered) else {
                continue
            }

            let expression = String(rendered[exprRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = resolveJSONLiteralTemplateExpression(
                expression,
                item: item,
                itemJSON: itemJSON,
                analyzer: analyzer
            )
            rendered.replaceSubrange(fullRange, with: replacement)
        }

        return rendered
    }

    private static func resolveJSONLiteralTemplateExpression(
        _ expression: String,
        item: Any?,
        itemJSON: String,
        analyzer: AnalyzeRule
    ) -> String {
        guard !expression.isEmpty else { return "" }

        if expression == "baseUrl" {
            return analyzer.baseUrl
        }

        if expression == "@@baseUrl", let sourceURL = analyzer.source?.bookSourceUrl {
            return sourceURL
        }

        if let variableKey = javaGetVariableKey(in: expression) ?? simpleTemplateVariableKey(expression) {
            let variableValue = analyzer.variableStore.get(variableKey)
            if !variableValue.isEmpty {
                return variableValue
            }
        }

        if let item,
           let directValue = resolveJSONTemplateValueFromObject(item: item, expression: expression),
           !directValue.isEmpty {
            return directValue
        }

        if let jsonValue = (try? JSONPathParser.getStringList(from: itemJSON, rule: expression))?.first,
           !jsonValue.isEmpty {
            return jsonValue
        }

        if expression.hasPrefix(".") || expression.hasPrefix("@.") {
            let normalizedExpression = expression.hasPrefix("@.")
                ? "$" + String(expression.dropFirst(1))
                : "$" + expression
            if let jsonValue = (try? JSONPathParser.getStringList(from: itemJSON, rule: normalizedExpression))?.first,
               !jsonValue.isEmpty {
                return jsonValue
            }
        }

        if let value = try? analyzer.getString(content: itemJSON, rule: expression, isUrl: false),
           !value.isEmpty {
            return value
        }

        // Android templates embedded in JSON directory fields can contain ordinary
        // JavaScript expressions, for example `{{baseUrl.replace('?paging=0','')}}`.
        // JSONPath resolution above intentionally handles `{{$.id}}` first; this
        // fallback covers method calls and other scalar JS expressions against the
        // same item content and page-level globals.
        analyzer.updateContextContent(itemJSON)
        let wrappedExpression = "(() => { return (\(expression)); })()"
        if let jsValue = try? analyzer.evaluateJS(script: wrappedExpression, resultObject: item ?? itemJSON, fallbackResult: itemJSON),
           !jsValue.isEmpty {
            return jsValue
        }

        return ""
    }

    private static func javaGetVariableKey(in expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^java\.get(?:String)?\(\s*['"]([^'"]+)['"]\s*\)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else {
                continue
            }
            return String(trimmed[range])
        }

        return nil
    }

    private static func resolveJSONTemplateValueFromObject(
        item: Any,
        expression: String
    ) -> String? {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpression.isEmpty else { return nil }

        let candidateRules: [String]
        if trimmedExpression.hasPrefix("$") || trimmedExpression.hasPrefix("@") || trimmedExpression.hasPrefix(".") {
            candidateRules = [trimmedExpression]
        } else {
            candidateRules = ["$.\(trimmedExpression)", trimmedExpression]
        }

        for rule in candidateRules {
            guard let value = (try? JSONPathParser.getStringList(fromObject: item, rule: rule))?.first,
                  !value.isEmpty else {
                continue
            }
            return value
        }

        if trimmedExpression.hasPrefix(".") || trimmedExpression.hasPrefix("@.") {
            let normalized = trimmedExpression.hasPrefix("@.")
                ? "$" + String(trimmedExpression.dropFirst(1))
                : "$" + trimmedExpression
            return (try? JSONPathParser.getStringList(fromObject: item, rule: normalized))?.first
        }

        return nil
    }

    private static func resolveJavaScriptStyleTemplateExpression(
        _ expression: String,
        analyzer: AnalyzeRule,
        itemJSON: String
    ) -> String {
        guard !expression.isEmpty else { return "" }

        let direct = analyzer.variableStore.get(expression)
        if !direct.isEmpty {
            return direct
        }

        let candidateRules: [String]
        if expression.hasPrefix("$") || expression.hasPrefix("@") || expression.hasPrefix(".") {
            candidateRules = [expression]
        } else {
            candidateRules = ["$.\(expression)", expression]
        }

        for rule in candidateRules {
            if let value = (try? JSONPathParser.getStringList(from: itemJSON, rule: rule))?.first,
               !value.isEmpty {
                return value
            }
            if let value = try? analyzer.getString(content: itemJSON, rule: rule, isUrl: false),
               !value.isEmpty {
                return value
            }
        }

        let dottedValue = analyzer.variableStore.get(lastVariableComponent(in: expression) ?? "")
        if !dottedValue.isEmpty {
            return dottedValue
        }

        return ""
    }

    private static func normalizedURLIdentity(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string?.lowercased() ?? trimmed.lowercased()
        }
        return trimmed.lowercased()
    }

    private static func isValidResolvedURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if isStructuredSelectorRule(trimmed) {
            return false
        }

        let urlPart = AnalyzeUrl.extractedLiteralURLPart(from: trimmed)
        let candidate = urlPart.isEmpty ? trimmed : urlPart
        let lowered = candidate.lowercased()
        let invalidValues: Set<String> = [
            "url", "href", "src", "#", "javascript:", "javascript:;", "javascript:void(0)", "javascript:void(0);",
            "about:blank", "[]", "%5b%5d", "null", "undefined"
        ]
        guard !invalidValues.contains(lowered) else { return false }
        guard !lowered.hasPrefix("javascript:") else { return false }
        guard !candidate.contains("{{"), !candidate.contains("}}") else { return false }
        guard !lowered.contains("undefined"), !lowered.contains("null") else { return false }
        guard !lowered.hasSuffix("/href"), !lowered.hasSuffix("/src"), !lowered.hasSuffix("/url") else { return false }

        if candidate.hasPrefix("//"), !candidate.hasPrefix("///") {
            return false
        }

        if candidate.hasPrefix("/") || candidate.hasPrefix("?") || candidate.hasPrefix("../") || candidate.hasPrefix("./") {
            return true
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func isStructuredSelectorRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("@css:") || lowercased.hasPrefix("@xpath:") || lowercased.hasPrefix("@json:") {
            return true
        }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/html") {
            return true
        }
        if trimmed.contains("@href") || trimmed.contains("@src") || trimmed.contains("@text") {
            return true
        }
        if trimmed.contains("text()") || trimmed.contains("::") {
            return true
        }
        return false
    }

    private static func rebaseResolvedURLIfNeeded(
        currentURL: String,
        pageBaseURL: String,
        preferredBaseURL: String
    ) -> String? {
        guard let currentComponents = URLComponents(string: currentURL),
              let pageURL = URL(string: pageBaseURL),
              let preferredURL = URL(string: preferredBaseURL),
              let currentHost = currentComponents.host?.lowercased(),
              let pageHost = pageURL.host?.lowercased(),
              let preferredHost = preferredURL.host?.lowercased(),
              currentHost == pageHost,
              currentHost != preferredHost else {
            return nil
        }

        let pagePath = pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard pagePath.isEmpty || pagePath == "index.html" else {
            return nil
        }

        var rebound = currentComponents
        rebound.scheme = preferredURL.scheme
        rebound.host = preferredURL.host
        rebound.port = preferredURL.port
        let reboundURL = rebound.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isValidResolvedURL(reboundURL) ? reboundURL : nil
    }
}
