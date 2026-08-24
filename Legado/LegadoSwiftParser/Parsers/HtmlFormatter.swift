import Foundation

// MARK: - HTML 清理工具（对应 Android legado HtmlFormatter.kt）
nonisolated struct HtmlFormatter {
    private static let nbspPattern = try! NSRegularExpression(
        pattern: "(&nbsp;)+",
        options: .caseInsensitive
    )
    private static let spaceEntities = try! NSRegularExpression(
        pattern: "(&ensp;|&emsp;)",
        options: .caseInsensitive
    )
    private static let invisibleEntities = try! NSRegularExpression(
        pattern: "(&thinsp;|&zwnj;|&zwj;|\\u2009|\\u200C|\\u200D)",
        options: .caseInsensitive
    )

    // Block-level tags → newline
    private static let blockTags = try! NSRegularExpression(
        pattern: "</?(?:div|p|br|hr|h[1-6]|article|dd|dl|dt|li|tr|blockquote|section|header|footer)[^>]*?>",
        options: .caseInsensitive
    )
    // HTML comments
    private static let comments = try! NSRegularExpression(
        pattern: "<!--.*?-->",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    // All remaining tags
    private static let allTags = try! NSRegularExpression(
        pattern: "<[^>]+>",
        options: .caseInsensitive
    )
    private static let nonImageTags = try! NSRegularExpression(
        pattern: "</?(?!img\\b)[a-zA-Z]+(?=[ >])[^<>]*>",
        options: .caseInsensitive
    )
    private static let imageTag = try! NSRegularExpression(
        pattern: #"<img[^>]*\s(?:data-src|src)\s*=\s*['"]([^'"]+)['"][^>]*>"#,
        options: .caseInsensitive
    )
    // Numeric decimal entities &#NNN;
    private static let decimalEntities = try! NSRegularExpression(pattern: "&#(\\d+);")
    // Numeric hex entities &#xHHH;
    private static let hexEntities = try! NSRegularExpression(
        pattern: "&#x([0-9a-fA-F]+);", options: .caseInsensitive
    )

    /// Strip HTML tags and unescape entities. Use for plain-text fields (intro, title, etc.)
    static func format(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var s = normalizeHTMLSpaceEntities(html)
        s = comments.stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: "")
        s = blockTags.stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: "\n")
        s = allTags.stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: "")
        return normalizeContentText(unescapeEntities(s))
    }

    /// Keep `<img>` tags while formatting chapter HTML so image URLs remain recoverable.
    static func formatKeepImages(_ html: String, baseUrl: String = "") -> String {
        guard html.contains("<") || html.contains("&") else {
            return normalizeContentText(html, preserveImages: true)
        }

        var formatted = normalizeHTMLSpaceEntities(html)
        formatted = comments.stringByReplacingMatches(in: formatted, range: nsRange(formatted), withTemplate: "")
        formatted = blockTags.stringByReplacingMatches(in: formatted, range: nsRange(formatted), withTemplate: "\n")
        formatted = normalizeImageTags(in: formatted, baseUrl: baseUrl)
        formatted = nonImageTags.stringByReplacingMatches(in: formatted, range: nsRange(formatted), withTemplate: "")
        formatted = unescapeEntities(formatted)
        return normalizeContentText(formatted, preserveImages: true)
    }

    static func normalizeContentText(_ text: String, preserveImages: Bool = false) -> String {
        guard !text.isEmpty else { return "" }

        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        let rawLines = normalized.components(separatedBy: "\n")
        var cleanedLines: [String] = []
        var previousWasEmpty = true

        for rawLine in rawLines {
            let trimmedLine = trimContentLine(rawLine, preserveImages: preserveImages)
            if trimmedLine.isEmpty {
                if !previousWasEmpty {
                    cleanedLines.append("")
                }
                previousWasEmpty = true
                continue
            }

            if looksLikeNavigationLine(trimmedLine) {
                continue
            }

            cleanedLines.append(trimmedLine)
            previousWasEmpty = false
        }

        normalized = cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return normalized
    }

    // MARK: - Private

    private static func nsRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }

    private static func normalizeHTMLSpaceEntities(_ html: String) -> String {
        var result = html
        result = nbspPattern.stringByReplacingMatches(in: result, range: nsRange(result), withTemplate: " ")
        result = spaceEntities.stringByReplacingMatches(in: result, range: nsRange(result), withTemplate: " ")
        result = invisibleEntities.stringByReplacingMatches(in: result, range: nsRange(result), withTemplate: "")
        return result
    }

    private static func normalizeImageTags(in html: String, baseUrl: String) -> String {
        let matches = imageTag.matches(in: html, range: nsRange(html))
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let srcRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let rawSource = String(result[srcRange])
            let resolvedSource = AnalyzeUrl.postProcessExtractedURL(rawSource, baseUrl: baseUrl)
            let replacement = resolvedSource.isEmpty ? "" : "<img src=\"\(resolvedSource)\">"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private static func trimContentLine(_ line: String, preserveImages: Bool) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preserveImages else { return trimmed }

        if trimmed.hasPrefix("<img"), trimmed.hasSuffix(">") {
            return trimmed
        }

        return trimmed
    }

    private static func looksLikeNavigationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.count <= 18 {
            let exactMatches = [
                "上一章", "下一章", "上一页", "下一页", "返回目录", "目录", "加入书签",
                "章节报错", "手机阅读", "章节目录", "投推荐票", "书签", "返回书页"
            ]
            if exactMatches.contains(trimmed) {
                return true
            }
        }

        let patterns = [
            #"^本章未完.*"#,
            #"^点击.*继续阅读.*"#,
            #"^最新网址[:：]?.*"#,
            #"^请收藏.*"#,
            #"^喜欢.*请.*收藏.*"#,
            #"^(?:上一章|下一章|上一页|下一页).*(?:返回|目录|阅读).*$"#
        ]

        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func unescapeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var s = string

        // Named entities (most common in Chinese novel sources)
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&ensp;", " "), ("&emsp;", " "),
            ("&thinsp;", ""), ("&zwnj;", ""), ("&zwj;", ""),
            ("&lrm;", ""), ("&rlm;", ""),
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            // &amp; last so it doesn't double-unescape other entities
            ("&amp;", "&"),
        ]
        for (entity, replacement) in named {
            s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // &#NNN;
        var matches = decimalEntities.matches(in: s, range: nsRange(s))
        for match in matches.reversed() {
            guard let r = Range(match.range, in: s),
                  let nr = Range(match.range(at: 1), in: s),
                  let cp = UInt32(s[nr]),
                  let scalar = Unicode.Scalar(cp) else { continue }
            s.replaceSubrange(r, with: String(scalar))
        }

        // &#xHHH;
        matches = hexEntities.matches(in: s, range: nsRange(s))
        for match in matches.reversed() {
            guard let r = Range(match.range, in: s),
                  let nr = Range(match.range(at: 1), in: s),
                  let cp = UInt32(s[nr], radix: 16),
                  let scalar = Unicode.Scalar(cp) else { continue }
            s.replaceSubrange(r, with: String(scalar))
        }

        return s
    }
}
