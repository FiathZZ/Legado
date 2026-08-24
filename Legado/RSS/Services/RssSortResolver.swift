import Foundation

// MARK: - RssSortResolver
/// 解析 RSS 源分类配置，对齐 Android legado 的 `sortUrl` 语义。
struct RssSortResolver {
    func resolveSorts(for source: RssSourceEntity) async throws -> [RssSortItem] {
        let trimmedSortRule = source.sortUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedSortRule.isEmpty else {
            return [RssSortItem(name: "默认", url: source.sourceUrl)]
        }

        let renderedRule = try renderSortRule(trimmedSortRule, source: source)
        let components = renderedRule
            .replacingOccurrences(of: "&&", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let resolved = components.compactMap { component in
            parseSortComponent(component, source: source)
        }

        return resolved.isEmpty ? [RssSortItem(name: "默认", url: source.sourceUrl)] : resolved
    }

    private func renderSortRule(_ rule: String, source: RssSourceEntity) throws -> String {
        guard rule.hasPrefix("@js:") || (rule.hasPrefix("<js>") && rule.hasSuffix("</js>")) else {
            return rule
        }

        let store = ParserVariableStore(writeScope: .ruleData)
        let analyzeRule = AnalyzeRule(
            baseUrl: source.sourceUrl,
            source: source.asBookSourceAdapter(),
            variableStore: store
        )
        return try analyzeRule.getString(content: source.sourceUrl, rule: rule)
    }

    private func parseSortComponent(_ component: String, source: RssSourceEntity) -> RssSortItem? {
        let parts = component.components(separatedBy: "::")
        let name: String
        let rawURL: String

        switch parts.count {
        case 0:
            return nil
        case 1:
            name = parts[0].isEmpty ? "默认" : parts[0]
            rawURL = source.sourceUrl
        default:
            name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认" : parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            rawURL = parts[1...].joined(separator: "::")
        }

        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = trimmedURL.isEmpty ? source.sourceUrl : RssURLHelper.absoluteURL(trimmedURL, baseURL: source.sourceUrl)
        guard !resolvedURL.isEmpty else { return nil }
        return RssSortItem(name: name, url: resolvedURL)
    }
}
