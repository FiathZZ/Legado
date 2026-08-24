import SwiftUI

struct ExploreResultView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let source: BookSource
    let category: ExploreCategory
    let allSources: [BookSource]
    let bookshelfViewModel: BookshelfViewModel

    @StateObject private var viewModel: ExploreResultViewModel

    init(source: BookSource, category: ExploreCategory, allSources: [BookSource], bookshelfViewModel: BookshelfViewModel) {
        self.source = source
        self.category = category
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        _viewModel = StateObject(wrappedValue: ExploreResultViewModel(source: source, category: category))
    }

    var body: some View {
        Group {
            if viewModel.results.isEmpty && viewModel.isLoading {
                ProgressView("加载中…")
                    .foregroundStyle(themeManager.color(.primaryText))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.results.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard viewModel.currentPage == 0, viewModel.results.isEmpty else { return }
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var resultList: some View {
        List {
            ForEach(viewModel.results) { book in
                NavigationLink {
                    ExploreBookDetailWrapper(
                        searchBook: book,
                        allSources: allSources,
                        bookshelfViewModel: bookshelfViewModel
                    )
                } label: {
                    ExploreResultRow(book: book, source: source)
                }
                .onAppear {
                    if viewModel.shouldLoadMore(currentItem: book) {
                        Task {
                            await viewModel.loadMore()
                        }
                    }
                }
            }

            if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 12)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if viewModel.hasReachedEnd {
                HStack {
                    Spacer()
                    Text("没有更多了")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .padding(.vertical, 12)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
    }

    private var emptyState: some View {
        ThemedEmptyState(
            icon: viewModel.errorMessage == nil ? "books.vertical" : "exclamationmark.triangle",
            title: viewModel.errorMessage ?? "暂无内容",
            message: viewModel.errorMessage == nil ? "下拉可重新加载该分类内容" : "可以下拉重试，或切换其他分类"
        )
    }
}

private struct ExploreBookDetailWrapper: View {
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
    }
}

private struct ExploreResultRow: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let book: SearchBook
    let source: BookSource

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(
                url: book.coverUrl,
                displaySize: CGSize(width: 60, height: 80),
                source: source,
                bookUrl: book.bookUrl,
                bookName: book.name,
                bookAuthor: book.author
            )
            .frame(width: 60, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(book.name.isEmpty ? "未知书名" : book.name)
                    .font(.headline)
                    .foregroundStyle(themeManager.color(.primaryText))
                    .lineLimit(1)

                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.subheadline)
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(1)

                if let lastChapter = book.lastChapter, !lastChapter.isEmpty {
                    Text("最新：\(lastChapter)")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .lineLimit(1)
                }

                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.tertiaryText))
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
