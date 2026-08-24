import Foundation
import Combine

@MainActor
final class ExploreResultViewModel: ObservableObject {
    @Published private(set) var results: [SearchBook] = []
    @Published private(set) var currentPage: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasReachedEnd: Bool = false
    @Published var errorMessage: String?

    let source: BookSource
    let category: ExploreCategory

    private let webBook: WebBook

    init(source: BookSource, category: ExploreCategory) {
        self.source = source
        self.category = category
        self.webBook = WebBook(bookSource: source)
    }

    deinit {
        webBook.shutdown()
    }

    func refresh() async {
        currentPage = 0
        hasReachedEnd = false
        results = []
        errorMessage = nil
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !hasReachedEnd else { return }

        let nextPage = currentPage + 1
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await webBook.getExploreList(url: category.url, page: nextPage)
            merge(fetched, reset: nextPage == 1)
            currentPage = nextPage
            hasReachedEnd = fetched.isEmpty
            errorMessage = nil
        } catch {
            if nextPage == 1 {
                results = []
            }
            errorMessage = "加载发现页失败：\(error.localizedDescription)"
        }
    }

    func shouldLoadMore(currentItem item: SearchBook) -> Bool {
        guard !isLoading, !hasReachedEnd else { return false }
        guard let index = results.firstIndex(where: { $0.id == item.id }) else { return false }
        return index >= max(results.count - 3, 0)
    }

    private func merge(_ newResults: [SearchBook], reset: Bool) {
        let existing = reset ? [:] : Dictionary(uniqueKeysWithValues: results.map { (bookKey(for: $0), $0) })

        if reset {
            results = newResults
        } else {
            let appended = newResults.filter { existing[bookKey(for: $0)] == nil }
            results.append(contentsOf: appended)
        }
    }

    private func bookKey(for book: SearchBook) -> String {
        let bookURL = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bookURL.isEmpty {
            return "\(book.origin)::\(bookURL)"
        }
        return "\(book.origin)::\(book.name)::\(book.author)"
    }
}
