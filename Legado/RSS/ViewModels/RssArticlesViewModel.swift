import Combine
import Foundation
import SwiftData

@MainActor
final class RssArticlesViewModel: ObservableObject {
    @Published var sorts: [RssSortItem] = []
    @Published var selectedSort: RssSortItem?
    @Published var articles: [RssArticleSummary] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var nextPageURL: String?

    private let source: RssSourceEntity
    private let rssService = RssService()
    private let sortResolver = RssSortResolver()
    private var currentPage = 1

    init(source: RssSourceEntity) {
        self.source = source
    }

    func loadInitial(modelContext: ModelContext) async {
        isLoading = true
        defer { isLoading = false }

        do {
            sorts = try await sortResolver.resolveSorts(for: source)
            if selectedSort == nil {
                selectedSort = sorts.first
            }
            try await reloadArticles(modelContext: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadArticles(modelContext: ModelContext) async throws {
        guard let selectedSort else { return }
        currentPage = 1
        let page = try await rssService.fetchArticles(from: source, sort: selectedSort, page: currentPage)
        articles = page.articles
        nextPageURL = page.nextPageURL
        _ = try? rssService.upsertArticles(page.articles, source: source, sortName: selectedSort.name, into: modelContext)
    }

    func refresh(modelContext: ModelContext) async {
        do {
            try await reloadArticles(modelContext: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let selectedSort, nextPageURL != nil else { return }
        do {
            currentPage += 1
            let page = try await rssService.fetchArticles(from: source, sort: selectedSort, page: currentPage)
            articles.append(contentsOf: page.articles)
            nextPageURL = page.nextPageURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSort(_ sort: RssSortItem, modelContext: ModelContext) async {
        selectedSort = sort
        await refresh(modelContext: modelContext)
    }
}
