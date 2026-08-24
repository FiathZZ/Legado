import Combine
import Foundation

@MainActor
final class RssReaderViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var result: RssContentResult?

    private let source: RssSourceEntity
    private let article: RssArticleSummary
    private let service = RssService()

    init(source: RssSourceEntity, article: RssArticleSummary) {
        self.source = source
        self.article = article
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            result = try await service.fetchContent(for: article, source: source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var renderedHTML: String? {
        guard let result else { return nil }
        if let html = result.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrapHTML(html, title: result.title)
        }
        if let text = result.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br/>")
            return wrapHTML("<article>\(escaped)</article>", title: result.title)
        }
        return nil
    }

    var fallbackURL: URL? {
        guard let result, result.shouldFallbackToWebView else { return nil }
        return URL(string: result.articleURL)
    }

    private func wrapHTML(_ body: String, title: String) -> String {
        let customStyle = source.style ?? ""
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(title)</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif; padding: 18px; line-height: 1.7; color: #1f2937; background: #ffffff; }
            img { max-width: 100%; height: auto; border-radius: 12px; }
            article { word-break: break-word; }
            \(customStyle)
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
