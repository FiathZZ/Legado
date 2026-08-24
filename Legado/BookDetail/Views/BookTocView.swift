import SwiftUI

// MARK: - 目录页
struct BookTocView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject var viewModel: BookTocViewModel
    let allSources: [BookSource]
    let bookshelfViewModel: BookshelfViewModel
    var onSourceSwitched: ((ChangeSourceSelection) -> Void)? = nil
    @State private var readerDestination: ReaderDestination? = nil
    @State private var readerLaunchError: String? = nil
    @State private var openingChapterIndex: Int? = nil
    @State private var retryChapterIndex: Int? = nil

    private struct ReaderDestination: Identifiable, Hashable {
        let viewModel: ReaderViewModel
        let bookID: String
        let id = UUID()

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingState
            } else if let err = viewModel.errorMessage {
                errorState(err)
            } else if viewModel.chapters.isEmpty {
                emptyState
            } else {
                chapterList
            }
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .navigationTitle("目录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if viewModel.chapters.isEmpty {
                await viewModel.loadToc()
            }
        }
        .navigationDestination(item: $readerDestination) { destination in
            ReaderView(
                viewModel: destination.viewModel,
                bookID: destination.bookID,
                allSources: allSources,
                bookshelfViewModel: bookshelfViewModel,
                onSourceSwitched: handleSourceSwitch
            )
        }
        .alert(
            "无法打开阅读器",
            isPresented: Binding(
                get: { readerLaunchError != nil },
                set: { isPresented in
                    if !isPresented {
                        readerLaunchError = nil
                    }
                }
            )
        ) {
            Button("重试") {
                guard let index = retryChapterIndex,
                      let chapter = viewModel.chapters.first(where: { $0.index == index }) else {
                    return
                }
                readerLaunchError = nil
                Task { await openReader(for: chapter) }
            }
            Button("取消", role: .cancel) {
                readerLaunchError = nil
            }
        } message: {
            Text(readerLaunchError ?? "加载章节失败")
        }
    }

    // MARK: 章节列表
    private var chapterList: some View {
        List(viewModel.chapters, id: \.index) { chapter in
            HStack {
                if chapter.isVolume {
                    Text(viewModel.displayChapterTitle(chapter.title))
                        .font(.headline)
                        .foregroundStyle(themeManager.color(.primaryText))
                } else {
                    Text(viewModel.displayChapterTitle(chapter.title))
                        .font(.subheadline)
                        .foregroundStyle(themeManager.color(.primaryText))
                        .padding(.leading, 8)
                }
                Spacer()
                if chapter.isVip {
                    Text("VIP")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(themeManager.softColor(.warning), in: Capsule())
                        .foregroundStyle(themeManager.color(.warning))
                }
            }
            .padding(.vertical, 2)
            .listRowBackground(chapter.isVolume ? themeManager.softColor(.secondaryText, opacity: 0.08) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if !chapter.isVolume {
                    Task { await openReader(for: chapter) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
    }

    // MARK: 加载中
    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text("加载目录中…").foregroundStyle(themeManager.color(.secondaryText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ThemedEmptyState(
            icon: "exclamationmark.triangle",
            title: message,
            message: "请稍后重试或切换书源"
        )
    }

    private var emptyState: some View {
        ThemedEmptyState(icon: "list.bullet", title: "暂无章节")
    }

    /// Constructing DZMReadController with an empty snapshot leaves a permanent white reader.
    /// Load and validate the target chapter before mutating the navigation state.
    private func openReader(for chapter: BookChapter) async {
        guard openingChapterIndex == nil else { return }
        openingChapterIndex = chapter.index
        retryChapterIndex = chapter.index
        defer { openingChapterIndex = nil }

        guard let result = viewModel.makeReaderViewModel(startIndex: chapter.index) else {
            readerLaunchError = viewModel.errorMessage ?? "未能创建阅读器"
            return
        }

        await result.vm.loadCurrentChapter()
        guard let content = result.vm.currentContent,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            readerLaunchError = result.vm.errorMessage ?? "加载章节失败"
            return
        }

        readerDestination = ReaderDestination(viewModel: result.vm, bookID: result.bookID)
        retryChapterIndex = nil
    }

    private func handleSourceSwitch(_ selection: ChangeSourceSelection) {
        viewModel.applySourceSwitch(selection)
        onSourceSwitched?(selection)
    }
}
