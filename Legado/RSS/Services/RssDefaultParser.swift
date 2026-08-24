import Foundation

// MARK: - RssDefaultParser
/// 默认 RSS/Atom 解析器。
struct RssDefaultParser {
    func parse(data: Data, source: RssSourceEntity, sortName: String) throws -> [RssArticleSummary] {
        switch parseOnce(data: data, source: source, sortName: sortName) {
        case .success(let articles):
            return articles
        case .failure(let initialError):
            guard let sanitizedData = RssXMLSanitizer.sanitizedData(from: data),
                  sanitizedData != data else {
                throw parsingError(initialError)
            }

            switch parseOnce(data: sanitizedData, source: source, sortName: sortName) {
            case .success(let articles):
                return articles
            case .failure(let sanitizedError):
                throw parsingError(sanitizedError)
            }
        }
    }

    private func parseOnce(
        data: Data,
        source: RssSourceEntity,
        sortName: String
    ) -> Result<[RssArticleSummary], Error> {
        let collector = FeedCollector(source: source, sortName: sortName)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            return .failure(parser.parserError ?? ParserError.parsingFailed("未知 XML 解析错误"))
        }

        return .success(collector.articles)
    }

    private func parsingError(_ error: Error) -> ParserError {
        ParserError.parsingFailed("RSS/XML 解析失败: \(error.localizedDescription)")
    }
}

/// `XMLParser` correctly rejects HTML-only entities and raw ampersands, while Android's
/// XmlPullParser accepts many feeds containing them. Preserve CDATA verbatim and normalize only
/// XML text outside it before one retry.
private enum RssXMLSanitizer {
    private static let invalidEntityPattern = #"&(?!amp;|lt;|gt;|quot;|apos;|#(?:[0-9]+|[xX][0-9A-Fa-f]+);)"#
    private static let invalidControlPattern = #"[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}]"#

    static func sanitizedData(from data: Data) -> Data? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let sanitized = sanitizeOutsideCDATA(xml)
        return sanitized == xml ? nil : Data(sanitized.utf8)
    }

    private static func sanitizeOutsideCDATA(_ xml: String) -> String {
        var result = ""
        var remainder = xml[...]

        while let cdataStart = remainder.range(of: "<![CDATA[") {
            result += sanitizeXMLText(String(remainder[..<cdataStart.lowerBound]))
            let cdata = remainder[cdataStart.lowerBound...]
            guard let cdataEnd = cdata.range(of: "]]>") else {
                return result + sanitizeXMLText(String(cdata))
            }
            result += String(cdata[..<cdataEnd.upperBound])
            remainder = cdata[cdataEnd.upperBound...]
        }

        return result + sanitizeXMLText(String(remainder))
    }

    private static func sanitizeXMLText(_ value: String) -> String {
        let withoutInvalidControls = value.replacingOccurrences(
            of: invalidControlPattern,
            with: "",
            options: .regularExpression
        )
        return withoutInvalidControls.replacingOccurrences(
            of: invalidEntityPattern,
            with: "&amp;",
            options: .regularExpression
        )
    }
}

// MARK: - FeedCollector
private final class FeedCollector: NSObject, XMLParserDelegate {
    private struct WorkingArticle {
        var title: String?
        var link: String?
        var description: String?
        var content: String?
        var pubDate: String?
        var image: String?
    }

    let source: RssSourceEntity
    let sortName: String
    private(set) var articles: [RssArticleSummary] = []

    private var currentItem: WorkingArticle?
    private var currentText = ""
    private var currentElement = ""
    private var feedKind: FeedKind = .unknown

    init(source: RssSourceEntity, sortName: String) {
        self.source = source
        self.sortName = sortName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        let name = normalized(elementName, qName: qName)
        currentElement = name
        currentText = ""

        switch name {
        case "rss":
            feedKind = .rss
        case "feed":
            feedKind = .atom
        case "item", "entry":
            currentItem = WorkingArticle()
        case "media:thumbnail":
            if currentItem?.image == nil {
                currentItem?.image = attributeDict["url"]
            }
        case "enclosure":
            if currentItem?.image == nil,
               let type = attributeDict["type"]?.lowercased(),
               type.hasPrefix("image/") {
                currentItem?.image = attributeDict["url"]
            }
        case "link":
            guard feedKind == .atom,
                  let href = attributeDict["href"],
                  !href.isEmpty else {
                return
            }
            let rel = attributeDict["rel"]?.lowercased()
            if rel == nil || rel == "alternate" || currentItem?.link == nil {
                currentItem?.link = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalized(elementName, qName: qName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard currentItem != nil else {
            currentElement = ""
            currentText = ""
            return
        }

        switch name {
        case "title":
            assign(text) { $0.title = text }
        case "link":
            if feedKind == .rss {
                assign(text) { $0.link = text }
            }
        case "description", "summary":
            assign(text) { $0.description = text }
            if currentItem?.image == nil {
                currentItem?.image = extractImageURL(fromHTML: text)
            }
        case "content:encoded", "content":
            assign(text) { $0.content = text }
            if currentItem?.image == nil {
                currentItem?.image = extractImageURL(fromHTML: text)
            }
        case "pubdate", "published", "updated", "time":
            assign(text) { $0.pubDate = text }
        case "item", "entry":
            finalizeCurrentItem()
        default:
            break
        }

        currentElement = ""
        currentText = ""
    }

    private func finalizeCurrentItem() {
        defer { currentItem = nil }
        guard let item = currentItem,
              let rawTitle = item.title,
              !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let link = RssURLHelper.absoluteURL(item.link ?? "", baseURL: source.sourceUrl)
        articles.append(
            RssArticleSummary(
                origin: source.sourceUrl,
                sortName: sortName,
                title: HtmlFormatter.format(rawTitle),
                link: link.isEmpty ? source.sourceUrl : link,
                pubDate: normalizedOptional(item.pubDate),
                articleDescription: normalizedOptional(item.description),
                content: normalizedOptional(item.content),
                image: normalizedOptional(item.image).map { RssURLHelper.absoluteURL($0, baseURL: link.isEmpty ? source.sourceUrl : link) },
                variableValues: [:]
            )
        )
    }

    private func assign(_ text: String, update: (inout WorkingArticle) -> Void) {
        guard !text.isEmpty, var item = currentItem else { return }
        update(&item)
        currentItem = item
    }

    private func normalized(_ elementName: String, qName: String?) -> String {
        (qName ?? elementName).lowercased()
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractImageURL(fromHTML html: String) -> String? {
        let pattern = #"<img[^>]+src\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let imageRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[imageRange])
    }

    private enum FeedKind {
        case unknown
        case rss
        case atom
    }
}
