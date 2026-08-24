import SwiftUI

// MARK: - 搜索页
struct SearchView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel = SearchViewModel()
    var allSources: [BookSource]
    var bookshelfViewModel: BookshelfViewModel

    @State private var isShowingResult = false
    @State private var committedKeyword: String = ""
    @State private var matchMode: SearchMatchMode = SearchMatchMode.defaultValue
    @FocusState private var isKeywordFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchBar

                    if viewModel.history.isEmpty {
                        emptyHistory
                            .frame(height: 260)
                    } else {
                        historySection
                    }
                }
            }
            .padding()
            .background(themeManager.color(.appBackground).ignoresSafeArea())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isShowingResult) {
                SearchResultView(
                    keyword: committedKeyword,
                    matchMode: matchMode,
                    allSources: allSources,
                    bookshelfViewModel: bookshelfViewModel
                )
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .themedNavigationChrome()
    }

    // MARK: 搜索栏
    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ThemedSectionHeader(
                title: "输入关键词",
                detail: "书名优先，其次作者名。搜索会并发查询当前已启用书源。"
            )

            Picker("搜索模式", selection: $matchMode) {
                ForEach(SearchMatchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(themeManager.color(.secondaryText))
                    TextField("搜索书籍、作者", text: $viewModel.keyword)
                        .focused($isKeywordFocused)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                    if !viewModel.keyword.isEmpty {
                        Button {
                            viewModel.keyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(themeManager.color(.secondaryText))
                        }
                    }
                }
                .padding(12)
                .background(themeManager.color(.secondarySurfaceBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button("搜索") {
                    performSearch()
                }
                .buttonStyle(ThemedPrimaryButtonStyle())
                .disabled(viewModel.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .themedCard()
    }

    // MARK: 历史记录
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemedSectionHeader(
                title: "搜索历史",
                detail: "轻点可直接重搜，低频清理动作收纳在分区右侧。",
                actionTitle: "清空"
            ) {
                viewModel.clearHistory()
            }

            VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.history, id: \.self) { word in
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(themeManager.color(.secondaryText))
                                .font(.subheadline)
                            Text(word)
                                .foregroundStyle(themeManager.color(.primaryText))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                viewModel.deleteHistory(word)
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(themeManager.color(.secondaryText))
                                    .font(.caption)
                            }
                        }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.useHistory(word)
                                performSearch()
                            }

                        if word != viewModel.history.last {
                            Divider()
                                .padding(.leading)
                                .overlay(themeManager.color(.divider))
                        }
                    }
                }
            }
            .themedCard()
        }
    }

    // MARK: 空历史
    private var emptyHistory: some View {
        ThemedEmptyState(
            icon: "magnifyingglass",
            title: "输入书名或作者开始搜索"
        )
    }

    // MARK: 触发搜索
    private func performSearch() {
        let trimmed = viewModel.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isKeywordFocused = false
        viewModel.commitSearch()
        committedKeyword = trimmed
        isShowingResult = true
    }
}
