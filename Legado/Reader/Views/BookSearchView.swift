import SwiftUI

struct BookSearchView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var readerViewModel: ReaderViewModel
    var onSelectResult: ((BookSearchResult) -> Void)? = nil

    @State private var keyword = ""
    @State private var results: [BookSearchResult] = []
    @State private var hasSearched = false
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Text("仅搜索已缓存章节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                content
            }
            .navigationTitle("书内搜索")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField("输入关键词", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(performSearch)

            Button("搜索") {
                performSearch()
            }
            .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            Spacer()
            ProgressView("搜索中…")
            Spacer()
        } else if results.isEmpty {
            Spacer()
            if hasSearched {
                ContentUnavailableView("未找到", systemImage: "magnifyingglass")
            } else {
                ContentUnavailableView("输入关键词后开始搜索", systemImage: "text.magnifyingglass")
            }
            Spacer()
        } else {
            List(results, id: \.id) { result in
                Button {
                    dismiss()
                    if let onSelectResult {
                        onSelectResult(result)
                    } else {
                        Task { @MainActor in
                            await readerViewModel.jumpToChapter(index: result.chapterIndex)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.chapterName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(result.snippet)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func performSearch() {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return }

        isSearching = true
        Task { @MainActor in
            results = readerViewModel.searchCachedChapters(keyword: trimmedKeyword)
            hasSearched = true
            isSearching = false
        }
    }
}
