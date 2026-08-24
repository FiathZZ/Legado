import SwiftUI
import Combine

// MARK: - 搜索结果页
struct SearchResultView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let keyword: String
    let matchMode: SearchMatchMode
    var allSources: [BookSource]
    var bookshelfViewModel: BookshelfViewModel

    @StateObject private var viewModel = SearchResultViewModel()
    /// 防止从详情页返回时重复触发搜索
    @State private var hasSearched = false

    var body: some View {
        Group {
            if viewModel.results.isEmpty && !viewModel.isSearching {
                emptyState
            } else {
                resultList
            }
        }
        .navigationTitle("\(keyword)的搜索结果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                progressLabel
            }
        }
        .onAppear {
            guard !hasSearched else { return }
            hasSearched = true
            viewModel.search(keyword: keyword, sources: allSources, matchMode: matchMode)
        }
        .onDisappear {
            // A pushed detail/reader view keeps this result view alive in the navigation stack.
            // Stop source work here so its parsing and result publishing cannot compete with reading.
            viewModel.stopSearchForNavigation()
        }
    }

    // MARK: 结果列表
    private var resultList: some View {
        List {
            Section("搜索结果") {
                ForEach(viewModel.results) { book in
                    NavigationLink {
                        BookDetailViewWrapper(
                            searchBook: book,
                            allSources: allSources,
                            bookshelfViewModel: bookshelfViewModel
                        )
                    } label: {
                        SearchResultRow(
                            book: book,
                            source: allSources.first(where: { $0.bookSourceUrl == book.origin })
                        )
                    }
                    .themedSurfaceListRow()
                }
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
    }

    // MARK: 进度标签
    @ViewBuilder
    private var progressLabel: some View {
        if viewModel.isSearching {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("\(viewModel.finishedSources)/\(viewModel.totalSources)")
                    .font(.caption)
                    .foregroundStyle(themeManager.color(.secondaryText))
                Button {
                    viewModel.stopSearch()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.semibold))
                }
                .accessibilityLabel("停止搜索")
            }
        }
    }

    // MARK: 空状态
    private var emptyState: some View {
        ThemedEmptyState(
            icon: viewModel.isSearching ? "ellipsis.circle" : "magnifyingglass",
            title: viewModel.errorMessage ?? (viewModel.isSearching ? "正在搜索中…" : "没有找到相关书籍"),
            message: viewModel.errorMessage == nil ? nil : "请检查书源配置或稍后重试"
        )
    }

}

// MARK: - BookDetailViewWrapper
/// Wraps BookDetailView with @StateObject so the ViewModel is stable across parent re-renders
private struct BookDetailViewWrapper: View {
    let searchBook: SearchBook
    let allSources: [BookSource]
    let bookshelfViewModel: BookshelfViewModel

    @StateObject private var detailViewModel: BookDetailViewModel

    init(searchBook: SearchBook, allSources: [BookSource], bookshelfViewModel: BookshelfViewModel) {
        self.searchBook = searchBook
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        _detailViewModel = StateObject(wrappedValue: BookDetailViewModel(searchBook: searchBook, allSources: allSources))
    }

    var body: some View {
        BookDetailView(viewModel: detailViewModel, bookshelfViewModel: bookshelfViewModel)
            .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - 搜索结果行
private struct SearchResultRow: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let book: SearchBook
    let source: BookSource?

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(
                url: book.coverUrl,
                displaySize: CGSize(width: 42, height: 56),
                source: source,
                bookUrl: book.bookUrl,
                bookName: book.name,
                bookAuthor: book.author
            )
                .frame(width: 42, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(book.name.isEmpty ? "未知书名" : book.name)
                    .font(themeManager.font(.title, size: 16, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(book.author.isEmpty ? "未知作者" : book.author)
                    if !sourceSummary(for: book).isEmpty {
                        Text(sourceSummary(for: book))
                    }
                }
                .font(themeManager.font(.primary, size: 13))
                .foregroundStyle(themeManager.color(.secondaryText))
                .lineLimit(1)

                if let lastChapter = book.lastChapter, !lastChapter.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "text.book.closed")
                            .font(.caption2)
                        .foregroundStyle(themeManager.color(.secondaryText))
                        Text(lastChapter)
                            .font(themeManager.font(.primary, size: 12))
                            .foregroundStyle(themeManager.color(.secondaryText))
                    }
                    .lineLimit(1)
                }

                if let kind = book.kind, !kind.isEmpty || !(book.wordCount ?? "").isEmpty {
                    HStack(spacing: 8) {
                        if !kind.isEmpty {
                            ThemedBadge(title: kind, tint: .accent)
                        }
                        if let wordCount = book.wordCount, !wordCount.isEmpty {
                            Text(wordCount)
                                .font(themeManager.font(.primary, size: 11, weight: .medium))
                                .foregroundStyle(themeManager.color(.tertiaryText))
                        }
                    }
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeManager.color(.tertiaryText))
        }
        .padding(.vertical, 2)
    }

    private func sourceSummary(for book: SearchBook) -> String {
        if book.sourceOrigins.count > 1 {
            return "\(book.sourceOrigins.count) 个书源"
        }
        return book.sourceName
    }
}
