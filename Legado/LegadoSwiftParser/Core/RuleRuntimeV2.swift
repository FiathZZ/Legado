import Foundation
import SwiftSoup

// MARK: - RuleRuntimeV2

/// Android 对齐式内容规则运行时入口。
///
/// H1 的目标是先把“统一 rule runtime 的入口面”立起来，而不是立刻复制整份 `AnalyzeRule`
/// 内部实现。这里首轮显式承接：
/// - baseUrl / source / variableStore
/// - JS 上下文注入能力
/// - 统一的字符串、元素、结构化值提取入口
///
/// 内部当前优先委托旧 `AnalyzeRule` 与 `ParserRuleRuntime` 的成熟逻辑，后续 H2/H5 再继续下沉。
nonisolated final class RuleRuntimeV2 {
    let stage: ParserStageKindV2?
    let baseUrl: String
    let requestUrl: String?
    let responseUrl: String?
    let source: BookSource?
    let variableStore: ParserVariableStore
    let stageBookDetail: BookDetail?
    let transfer: ParserStageTransferV2
    private let analyzer: AnalyzeRule

    init(
        stage: ParserStageKindV2? = nil,
        baseUrl: String = "",
        requestUrl: String? = nil,
        responseUrl: String? = nil,
        source: BookSource? = nil,
        variableStore: ParserVariableStore = ParserVariableStore(),
        stageBookDetail: BookDetail? = nil,
        transfer: ParserStageTransferV2 = ParserStageTransferV2()
    ) {
        self.stage = stage
        self.baseUrl = baseUrl
        self.requestUrl = requestUrl
        self.responseUrl = responseUrl
        self.source = source
        self.variableStore = variableStore
        self.stageBookDetail = stageBookDetail
        self.transfer = transfer
        self.analyzer = AnalyzeRule(baseUrl: baseUrl, source: source, variableStore: variableStore)
        bootstrapStageContext()
    }

    // Search / detail parser 会在一次请求里频繁创建短生命周期 runtime。
    // 这里持有的都是同步解析对象，不需要 executor 参与析构；显式 nonisolated 可避免
    // 默认 MainActor 隔离工程把释放阶段送进并发运行时，放大底层 TaskLocal 清理缺陷。
    nonisolated deinit {}

    convenience init(stageContext: ParserStageContextV2) {
        self.init(
            stage: stageContext.stage,
            baseUrl: stageContext.baseUrl,
            requestUrl: stageContext.requestUrl,
            responseUrl: stageContext.responseUrl,
            source: stageContext.source,
            variableStore: stageContext.variableStore,
            stageBookDetail: stageContext.bookDetail,
            transfer: stageContext.transfer
        )
    }

    func injectBookVariable(
        bookUrl: String,
        name: String = "",
        author: String = "",
        kind: String = "",
        tocUrl: String = "",
        bookVariables: [String: String] = [:]
    ) {
        analyzer.injectBookVariable(
            bookUrl: bookUrl,
            name: name,
            author: author,
            kind: kind,
            tocUrl: tocUrl,
            bookVariables: bookVariables
        )
    }

    /// 目录与正文阶段都可能依赖 `chapter` / `nextChapterUrl` / `chapterUrl` 这类运行时变量。
    ///
    /// Android 会把这些值持续挂在同一份 `AnalyzeRule` / JS bridge 上，供 `nextContentUrl`
    /// 判定和分页 JS 规则直接读取。V2 在 runtime 初始化时统一灌入，避免 parser 自己临时拼装。
    func injectChapterVariable(
        chapter: BookChapter,
        nextChapterUrl: String? = nil
    ) {
        seedStageVariable("chapterTitle", chapter.title)
        seedStageVariable("chapterUrl", chapter.url)
        seedStageVariable("chapterBaseUrl", chapter.baseUrl)
        seedStageVariable("chapterBookUrl", chapter.bookUrl)
        seedStageVariable("nextChapterUrl", nextChapterUrl ?? "")

        variableStore.merge(chapter.sourceVariables, into: .source)
        variableStore.merge(chapter.bookVariables, into: .book)
        variableStore.merge(chapter.chapterVariables, into: .chapter)
        variableStore.merge(chapter.variables, into: .chapter)
    }

    func updateContextContent(_ content: String) {
        analyzer.updateContextContent(content)
    }

    func getString(content: String, rule: String, isUrl: Bool = false) throws -> String {
        try analyzer.getString(content: content, rule: rule, isUrl: isUrl)
    }

    func getString(element: Element, rule: String, isUrl: Bool = false) throws -> String {
        try analyzer.getString(element: element, rule: rule, isUrl: isUrl)
    }

    func getStringList(content: String, rule: String, isUrl: Bool = false) throws -> [String] {
        try analyzer.getStringList(content: content, rule: rule, isUrl: isUrl)
    }

    /// Android `AnalyzeRule` 在列表解析时会把当前 item 作为运行时 content 挂到同一条规则链上，
    /// 后续字段规则可以继续用：
    /// - JSON 对象本身做 `$.field` / `field` / `{{$.field}}`
    /// - HTML 节点继续做 CSS/XPath
    /// - 结构化值经过 `&& / @@ / template / <js>` 串接后再落成字符串
    ///
    /// V2 之前主要把 JSON item 先序列化成字符串再解析，遇到单对象列表、模板 URL、混合 rule chain
    /// 时会比 Android 更容易提前取空。这里补一层“item 直接求值”入口，让 `BookListParserV2`
    /// 可以把同一条字段规则直接作用在当前列表项上，而不是每次都退回整页 response。
    func getString(item: Any, content: String, rule: String, isUrl: Bool = false) throws -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return "" }

        if let element = item as? Element {
            return try analyzer.getString(element: element, rule: trimmedRule, isUrl: isUrl)
        }

        let directValues = try getStringList(item: item, content: content, rule: trimmedRule, isUrl: isUrl)
        return directValues.first ?? ""
    }

    func getStringList(element: Element, rule: String, isUrl: Bool = false) throws -> [String] {
        try analyzer.getStringList(element: element, rule: rule, isUrl: isUrl)
    }

    /// 针对 JSON / NSDictionary / 标量列表项的 Android 风格字段提取入口。
    ///
    /// 对 JSON item：
    /// 1. 先尝试把当前 item 作为结构化对象直接执行 JSONPath / 默认 JSON 规则
    /// 2. 再回退到字符串化内容，兼容旧链上的模板、正则与 HTML/JSON 混写规则
    /// 3. `isUrl=true` 时统一走 `AnalyzeUrlV2.postProcessExtractedURLs`
    ///
    /// 这样可以覆盖 H3 的“单对象 JSON 列表化 + 字段连续提取”，并减少 H1 里
    /// “详情 fallback 前其实已经拿到 JSON item，但字段规则在 item 级别取空”的误判。
    func getStringList(item: Any, content: String, rule: String, isUrl: Bool = false) throws -> [String] {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return [] }

        if let element = item as? Element {
            return try analyzer.getStringList(element: element, rule: trimmedRule, isUrl: isUrl)
        }

        if let structured = try resolveStructuredValues(item: item, rule: trimmedRule, isUrl: isUrl),
           !structured.isEmpty {
            return structured
        }

        return try analyzer.getStringList(content: content, rule: trimmedRule, isUrl: isUrl)
    }

    func getElements(content: String, rule: String) throws -> [Element] {
        try analyzer.getElements(content: content, rule: rule)
    }

    func resolveStructuredValue(content: String, rule: String) throws -> Any? {
        try analyzer.resolveStructuredValue(content: content, rule: rule)
    }

    func getValue(content: String, rule: String) throws -> Any? {
        try analyzer.getValue(content: content, rule: rule)
    }

    func evaluateJS(script: String, result: String = "") throws -> String {
        try analyzer.evaluateJS(script: script, result: result)
    }

    func evaluateJSValue(script: String, result: String = "", results: [String] = []) throws -> Any? {
        try analyzer.evaluateJSValue(script: script, result: result, results: results)
    }

    func directExtractStringList(
        content: String,
        rule: String,
        isUrl: Bool = false
    ) throws -> [String]? {
        guard let source else { return nil }
        return try ParserRuleRuntime.directExtractStringList(
            content: content,
            rule: rule,
            context: .init(baseUrl: baseUrl, source: source, variableStore: variableStore),
            isUrl: isUrl
        )
    }

    func renderDirectLiteralURLIfNeeded(
        content: String,
        rule: String
    ) -> String? {
        guard let source else { return nil }
        return ParserRuleRuntime.renderDirectLiteralURLIfNeeded(
            content: content,
            rule: rule,
            context: .init(baseUrl: baseUrl, source: source, variableStore: variableStore)
        )
    }

    /// Android `AnalyzeRule` 在 search/detail/toc/content 间会持续复用一份上下文：
    /// `result`、`baseUrl`、`redirectUrl`、`infoHtml`、`book` 等变量不会因为阶段切换而丢失。
    /// V2 runtime 在初始化时统一把这些值写回 variableStore 和 JS bridge，避免 parser 各自零散补环境。
    private func bootstrapStageContext() {
        seedStageVariable("baseUrl", baseUrl)
        seedStageVariable("result", transfer.responseBody ?? "")
        seedStageVariable("content", transfer.responseBody ?? "")
        seedStageVariable("requestUrl", requestUrl ?? "")
        seedStageVariable("redirectUrl", transfer.redirectUrl ?? responseUrl ?? "")
        seedStageVariable("responseUrl", responseUrl ?? "")
        seedStageVariable("infoHtml", transfer.infoHtml ?? "")
        seedStageVariable("tocHtml", transfer.tocHtml ?? "")
        seedStageVariable("bookUrl", transfer.bookUrl ?? stageBookDetail?.bookUrl ?? "")
        seedStageVariable("tocUrl", transfer.tocUrl ?? stageBookDetail?.tocUrl ?? "")
        seedStageVariable("nextChapterUrl", transfer.nextChapterUrl ?? "")

        if let responseBody = transfer.responseBody, !responseBody.isEmpty {
            analyzer.updateContextContent(responseBody)
        }

        if let detail = stageBookDetail {
            injectBookVariable(
                bookUrl: detail.bookUrl,
                name: detail.name,
                author: detail.author,
                kind: detail.kind ?? "",
                tocUrl: detail.tocUrl ?? "",
                bookVariables: variableStore.snapshot(for: .book, includeInherited: true)
            )
            return
        }

        let inferredBookURL = transfer.bookUrl ?? ""
        guard !inferredBookURL.isEmpty else { return }
        injectBookVariable(
            bookUrl: inferredBookURL,
            name: variableStore.get("name"),
            author: variableStore.get("author"),
            kind: variableStore.get("kind"),
            tocUrl: transfer.tocUrl ?? variableStore.get("tocUrl"),
            bookVariables: variableStore.snapshot(for: .book, includeInherited: true)
        )
    }

    private func seedStageVariable(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        variableStore.put(key, value: trimmed, scope: .book)
    }

    private func resolveStructuredValues(
        item: Any,
        rule: String,
        isUrl: Bool
    ) throws -> [String]? {
        let split = RuleAnalyzer.splitRulesWithOperator(rule)
        switch split.operator {
        case "||":
            for part in split.parts {
                if let value = try resolveStructuredValues(item: item, rule: part, isUrl: isUrl),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        case "&&":
            var results: [String] = []
            for part in split.parts {
                if let value = try resolveStructuredValues(item: item, rule: part, isUrl: isUrl) {
                    results.append(contentsOf: value)
                }
            }
            return results
        case "@@":
            var joined = ""
            for part in split.parts {
                if let value = try resolveStructuredValues(item: item, rule: part, isUrl: isUrl) {
                    joined += value.joined(separator: "")
                }
            }
            return joined.isEmpty ? [] : [joined]
        default:
            break
        }

        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let directResults = try resolveSingleStructuredValues(item: item, rule: trimmedRule)
        if directResults.isEmpty {
            return nil
        }

        if isUrl {
            return directResults.flatMap {
                AnalyzeUrlV2.postProcessExtractedURLs(
                    $0,
                    baseUrl: baseUrl,
                    variableStore: variableStore
                )
            }
        }
        return directResults
    }

    private func resolveSingleStructuredValues(item: Any, rule: String) throws -> [String] {
        let cleanedRule = RuleAnalyzer.cleanRule(rule)
        let ruleType = RuleAnalyzer.ruleType(for: rule)

        if RuleAnalyzer.containsTemplate(rule) || ruleType == .javascript {
            let itemContent = JSONPathParser.stringify(item) ?? "\(item)"
            return try analyzer.getStringList(content: itemContent, rule: rule)
        }

        switch ruleType {
        case .jsonPath:
            return try JSONPathParser.getStringList(fromObject: item, rule: cleanedRule)
        case .default:
            if let results = try? JSONPathParser.getStringList(fromObject: item, rule: cleanedRule),
               !results.isEmpty {
                return results
            }
            let normalizedRule: String
            if cleanedRule.hasPrefix("$.") || cleanedRule.hasPrefix("$[") || cleanedRule.hasPrefix("@.") || cleanedRule.hasPrefix(".") {
                normalizedRule = cleanedRule
            } else if cleanedRule.hasPrefix("$") {
                normalizedRule = cleanedRule
            } else {
                normalizedRule = "$.\(cleanedRule)"
            }
            return (try? JSONPathParser.getStringList(fromObject: item, rule: normalizedRule)) ?? []
        case .regex:
            let itemContent = JSONPathParser.stringify(item) ?? "\(item)"
            return try RegexParser.getStringList(from: itemContent, rule: cleanedRule)
        case .css, .xpath:
            let itemContent = JSONPathParser.stringify(item) ?? "\(item)"
            return try analyzer.getStringList(content: itemContent, rule: rule)
        case .javascript:
            return []
        }
    }
}
