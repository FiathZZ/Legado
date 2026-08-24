import SwiftUI
import SwiftData

struct RssArticlesView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel: RssArticlesViewModel
    let source: RssSourceEntity

    init(source: RssSourceEntity) {
        self.source = source
        _viewModel = StateObject(wrappedValue: RssArticlesViewModel(source: source))
    }

    var body: some View {
        List {
            if !viewModel.sorts.isEmpty {
                Section("分类") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(viewModel.sorts) { sort in
                                Button(sort.name) {
                                    Task {
                                        await viewModel.selectSort(sort, modelContext: modelContext)
                                    }
                                }
                                .font(themeManager.font(.primary, size: 13, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background((viewModel.selectedSort == sort ? themeManager.color(.selectionFill) : themeManager.color(.secondarySurfaceBackground)), in: Capsule())
                                .foregroundStyle(viewModel.selectedSort == sort ? themeManager.color(.selectionText) : themeManager.color(.primaryText))
                            }
                        }
                    }
                    .listRowBackground(themeManager.color(.appBackground))
                }
            }

            Section(viewModel.selectedSort?.name ?? "文章") {
                if viewModel.articles.isEmpty && !viewModel.isLoading {
                    Text("当前分类暂无文章")
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .themedSurfaceListRow()
                } else {
                    ForEach(viewModel.articles) { article in
                        NavigationLink(destination: RssReaderView(source: source, article: article)) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(article.title)
                                    .font(themeManager.font(.primary, size: 17, weight: .semibold))
                                    .foregroundStyle(themeManager.color(.primaryText))
                                if let description = article.articleDescription, !description.isEmpty {
                                    Text(HtmlFormatter.format(description))
                                        .font(themeManager.font(.primary, size: 13, weight: .regular))
                                        .foregroundStyle(themeManager.color(.secondaryText))
                                        .lineLimit(3)
                                }
                                if let pubDate = article.pubDate, !pubDate.isEmpty {
                                    Text(pubDate)
                                        .font(themeManager.font(.primary, size: 12, weight: .regular))
                                        .foregroundStyle(themeManager.color(.tertiaryText))
                                }
                            }
                        }
                        .themedSurfaceListRow()
                    }

                    if viewModel.nextPageURL != nil {
                        Button {
                            Task {
                                await viewModel.loadMore()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("加载下一页")
                                Spacer()
                            }
                        }
                        .themedSurfaceListRow()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle(source.sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中…")
            }
        }
        .task {
            await viewModel.loadInitial(modelContext: modelContext)
        }
        .refreshable {
            await viewModel.refresh(modelContext: modelContext)
        }
        .alert("RSS 提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}
