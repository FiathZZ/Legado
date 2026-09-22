import SwiftUI

// MARK: - 书籍详情页
struct BookDetailView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var viewModel: BookDetailViewModel
    @ObservedObject var bookshelfViewModel: BookshelfViewModel

    @State private var readerDestination: ReaderDestination? = nil
    @State private var notice: DetailNotice?
    @State private var isOpeningReader = false
    @State private var showEditBookInfo = false
    @State private var showSourceSwitcher = false
    @State private var exportItem: ExportShareItem?
    @State private var showClearCacheConfirmation = false

    private enum DetailNotice: Identifiable {
        case readerUnavailable
        case addedToBookshelf
        case exportFailed

        var id: String {
            switch self {
            case .readerUnavailable: "readerUnavailable"
            case .addedToBookshelf: "addedToBookshelf"
            case .exportFailed: "exportFailed"
            }
        }
    }

    private struct ReaderDestination: Hashable {
        let vm: ReaderViewModel
        let bookID: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.vm === rhs.vm }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(vm)) }
    }

    private struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                    .padding(.horizontal)
                    .padding(.top, 16)

                infoSection
                    .padding(.horizontal)

                if !displayIntro.isEmpty {
                    introSection(displayIntro)
                        .padding(.horizontal)
                }

                Spacer(minLength: 100)
            }
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSourceSwitcher = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel("切换书源")
            }
            if currentBookEntity != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("编辑") {
                            showEditBookInfo = true
                        }
                        Button("导出 TXT") {
                            Task { await exportCurrentBook(as: .txt) }
                        }
                        Button("导出 EPUB") {
                            Task { await exportCurrentBook(as: .epub) }
                        }
                        Button("清理本书缓存", role: .destructive) {
                            showClearCacheConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            bottomBar
        }
        .task {
            bookshelfViewModel.markAsRead(bookUrl: viewModel.searchBook.bookUrl)
            // A completed offline package already owns the book's TOC and chapter metadata.
            // Do not fetch the detail page merely because the user opened this screen.
            if !isOfflineBook {
                await viewModel.loadDetail()
            }
        }
        .onDisappear {
            viewModel.clearTocCache()
        }
        .navigationDestination(item: $readerDestination) { dest in
            ReaderView(
                viewModel: dest.vm,
                bookID: dest.bookID,
                allSources: viewModel.availableSources,
                bookshelfViewModel: bookshelfViewModel,
                onSourceSwitched: handleSourceSwitch
            )
            .toolbar(.hidden, for: .tabBar)
        }
        .sheet(isPresented: $showEditBookInfo) {
            if let currentBookEntity {
                BookInfoEditView(
                    book: currentBookEntity,
                    onSave: { customCoverUrl, customIntro, customTag in
                        bookshelfViewModel.updateCustomInfo(
                            for: currentBookEntity,
                            customCoverUrl: customCoverUrl,
                            customIntro: customIntro,
                            customTag: customTag
                        )
                    },
                    onReset: {
                        bookshelfViewModel.resetCustomInfo(for: currentBookEntity)
                    }
                )
            }
        }
        .sheet(isPresented: $showSourceSwitcher) {
            ChangeSourceView(
                viewModel: ChangeSourceViewModel(
                    bookName: viewModel.searchBook.name,
                    bookAuthor: viewModel.searchBook.author,
                    allSources: viewModel.availableSources,
                    prefetchedBook: viewModel.searchBook,
                    currentSourceURL: viewModel.bookSource?.bookSourceUrl,
                    currentSourceName: viewModel.bookSource?.bookSourceName ?? "",
                ),
                onConfirm: { selection in
                    handleSourceSwitch(selection)
                    showSourceSwitcher = false
                }
            )
        }
        .sheet(item: $exportItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        .alert(item: $notice) { notice in
            switch notice {
            case .readerUnavailable:
                return Alert(
                    title: Text("暂时无法打开阅读器"),
                    message: Text("请重试或切换书源"),
                    primaryButton: .default(Text("重试")) {
                        if let tocVM = viewModel.tocViewModel(bookshelfViewModel: bookshelfViewModel) {
                            Task { await openReader(tocVM: tocVM) }
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .addedToBookshelf:
                return Alert(title: Text("已加入书架"), dismissButton: .default(Text("好的")))
            case .exportFailed:
                return Alert(title: Text("导出失败"), message: Text("请稍后重试"), dismissButton: .default(Text("确定")))
            }
        }
        .alert("清理本书缓存？", isPresented: $showClearCacheConfirmation) {
            Button("清理", role: .destructive) {
                if let currentBookEntity {
                    bookshelfViewModel.clearBookCache(for: currentBookEntity)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本书的章节正文、目录和离线清单，但不会移出书架或删除阅读进度。")
        }
    }

    // MARK: 顶部封面 + 基本信息
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImageView(
                url: displayCoverUrl,
                displaySize: CGSize(width: 78, height: 108),
                source: viewModel.bookSource,
                bookUrl: viewModel.detail?.bookUrl ?? viewModel.searchBook.bookUrl,
                bookName: viewModel.detail?.name ?? viewModel.searchBook.name,
                bookAuthor: viewModel.detail?.author ?? viewModel.searchBook.author
            )
            .frame(width: 78, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(viewModel.detail?.name ?? viewModel.searchBook.name)
                    .font(themeManager.font(.title, size: 19, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))
                    .lineLimit(3)

                Text(viewModel.detail?.author ?? viewModel.searchBook.author)
                    .font(themeManager.font(.primary, size: 14))
                    .foregroundStyle(themeManager.color(.secondaryText))

                if let kind = viewModel.detail?.kind, !kind.isEmpty {
                    ThemedBadge(title: kind, tint: .accent)
                }

                if let sourceName = viewModel.bookSource?.bookSourceName, !sourceName.isEmpty {
                    Label(sourceName, systemImage: "network")
                        .font(themeManager.font(.primary, size: 12))
                        .foregroundStyle(themeManager.color(.tertiaryText))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: 详细信息栏
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sourceName = viewModel.bookSource?.bookSourceName, !sourceName.isEmpty {
                infoRow(icon: "network", label: "来源", value: sourceName)
            }
            if let lastChapter = viewModel.detail?.lastChapter, !lastChapter.isEmpty {
                infoRow(icon: "text.book.closed", label: "最新章节", value: lastChapter)
            }
            if let updateTime = viewModel.detail?.updateTime, !updateTime.isEmpty {
                infoRow(icon: "clock", label: "更新时间", value: updateTime)
            }
            if let wordCount = viewModel.detail?.wordCount, !wordCount.isEmpty {
                infoRow(icon: "character.cursor.ibeam", label: "字数", value: wordCount)
            }
            if let displayTag, !displayTag.isEmpty {
                infoRow(icon: "tag", label: "标签", value: displayTag)
            }
            if viewModel.isLoading {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("加载详情中…").font(.caption).foregroundStyle(themeManager.color(.secondaryText))
                }
            }
            if let err = viewModel.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(themeManager.color(.destructive))
                Button {
                    showSourceSwitcher = true
                } label: {
                    Label("切换书源", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(themeManager.color(.secondaryText)).frame(width: 20)
            Text(label).foregroundStyle(themeManager.color(.secondaryText)).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).lineLimit(1).foregroundStyle(themeManager.color(.primaryText))
        }
    }

    // MARK: 简介
    private func introSection(_ intro: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介")
                .font(themeManager.font(.primary, size: 15, weight: .semibold))
                .foregroundStyle(themeManager.color(.primaryText))
            Text(intro)
                .font(themeManager.font(.primary, size: 14))
                .foregroundStyle(themeManager.color(.secondaryText))
                .lineSpacing(4)
        }
    }

    // MARK: 底部操作栏
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // 目录按钮
                if let tocVM = viewModel.tocViewModel(bookshelfViewModel: bookshelfViewModel) {
                    NavigationLink {
                        BookTocView(
                            viewModel: tocVM,
                            allSources: viewModel.availableSources,
                            bookshelfViewModel: bookshelfViewModel,
                            onSourceSwitched: handleSourceSwitch
                        )
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet")
                            Text("目录").font(.caption2)
                        }
                        .frame(width: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themeManager.color(.primaryText))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "list.bullet")
                        Text("目录").font(.caption2)
                    }
                    .frame(width: 50)
                    .foregroundStyle(themeManager.color(.tertiaryText))
                }

                // 加入书架 / 已在书架
                let inShelf = bookshelfViewModel.isInShelf(bookUrl: viewModel.searchBook.bookUrl)
                Button {
                    if !inShelf, let detail = viewModel.detail {
                        bookshelfViewModel.addBook(detail: detail, sourceUrl: viewModel.searchBook.origin)
                        notice = .addedToBookshelf
                    }
                } label: {
                    Text(inShelf ? "已在书架" : "加入书架")
                        .font(.subheadline).fontWeight(.medium)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(inShelf ? themeManager.color(.secondarySurfaceBackground) : themeManager.color(.warning))
                        .foregroundStyle(inShelf ? themeManager.color(.secondaryText) : themeManager.color(.selectionText))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(inShelf)

                // 立即阅读
                Button {
                    guard let tocVM = viewModel.tocViewModel(bookshelfViewModel: bookshelfViewModel) else { return }
                    Task { await openReader(tocVM: tocVM) }
                } label: {
                    Text("立即阅读")
                        .font(.subheadline).fontWeight(.medium)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(themeManager.color(.selectionFill))
                        .foregroundStyle(themeManager.color(.selectionText))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isOpeningReader)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(themeManager.color(.surfaceBackground))
        }
    }

    private func openReader(tocVM: BookTocViewModel) async {
        guard !isOpeningReader else { return }
        isOpeningReader = true
        defer { isOpeningReader = false }

        let restoredFromCache = await tocVM.restoreCachedChaptersIfAvailable()
        if !restoredFromCache {
            await tocVM.loadToc()
        } else {
            Task { @MainActor in await tocVM.loadToc() }
        }
        guard !tocVM.chapters.isEmpty else {
            notice = .readerUnavailable
            return
        }

        let savedIndex = bookshelfViewModel.bookEntity(for: viewModel.searchBook.bookUrl)?.currentChapterIndex ?? 0
        guard let result = tocVM.makeReaderViewModel(startIndex: savedIndex) else {
            notice = .readerUnavailable
            return
        }

        await result.vm.loadCurrentChapter()
        guard let content = result.vm.currentContent,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = .readerUnavailable
            return
        }

        readerDestination = ReaderDestination(vm: result.vm, bookID: result.bookID)
        Task { @MainActor in
            await tocVM.waitForBackgroundTocRefresh()
            result.vm.updateChapters(
                tocVM.chapters,
                hasCompleteTableOfContents: tocVM.hasCompleteTableOfContents
            )
        }
    }

    private func handleSourceSwitch(_ selection: ChangeSourceSelection) {
        viewModel.applySourceSwitch(selection)
    }

    private var currentBookEntity: BookEntity? {
        bookshelfViewModel.bookEntity(for: viewModel.searchBook.bookUrl)
    }

    private var isOfflineBook: Bool {
        guard let book = currentBookEntity else { return false }
        let key = ChapterCacheStore.makeKey(sourceUrl: book.sourceUrl, bookUrl: book.bookUrl)
        return ChapterCacheStore.offlineBookManifest(bookKey: key) != nil
    }

    private var displayCoverUrl: String? {
        currentBookEntity?.effectiveCoverUrl ?? viewModel.detail?.coverUrl
    }

    private var displayIntro: String {
        currentBookEntity?.effectiveIntro ?? viewModel.detail?.intro ?? ""
    }

    private var displayTag: String? {
        currentBookEntity?.effectiveTag
    }

    private func exportCurrentBook(as format: BookDetailExportFormat) async {
        guard let currentBookEntity else { return }
        do {
            let exporter = BookExporter(modelContext: bookshelfViewModel.modelContext)
            let url: URL
            switch format {
            case .txt:
                url = try await exporter.exportAsTXT(book: currentBookEntity)
            case .epub:
                url = try await exporter.exportAsEPUB(book: currentBookEntity)
            }
            exportItem = ExportShareItem(url: url)
        } catch {
            notice = .exportFailed
        }
    }

}

private enum BookDetailExportFormat {
    case txt
    case epub
}
