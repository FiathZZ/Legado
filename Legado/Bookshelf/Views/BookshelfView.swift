import SwiftUI
import SwiftData
import ImageIO
import Combine
#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#endif

// MARK: - 书架视图
struct BookshelfView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var viewModel: BookshelfViewModel
    var allSources: [BookSource]
    @State private var showGroupManager = false
    @State private var showBatchGroupSheet = false
    @State private var showManualSortSheet = false
    @State private var showDeleteConfirmation = false
    @State private var navigationTarget: BookshelfNavigationTarget?
    @State private var readerRoute: BookshelfReaderRoute?
    @State private var readerLaunchError: ReaderLaunchError?
    @State private var exportItem: ExportShareItem?
    @State private var exportErrorMessage: String?

    private struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.hasShelfBooks || !viewModel.visibleGroups.isEmpty {
                    groupTabBar
                }

                Group {
                    if !viewModel.hasShelfBooks {
                        emptyState
                    } else if viewModel.displayBooks.isEmpty {
                        filteredEmptyState
                    } else {
                        bookGrid
                    }
                }
            }
            .background(themeManager.color(.appBackground).ignoresSafeArea())
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if viewModel.isEditing {
                        Button("完成") {
                            viewModel.exitEditMode()
                        }
                    } else {
                        Menu {
                            Button {
                                showGroupManager = true
                            } label: {
                                Label("管理分组", systemImage: "folder.badge.gearshape")
                            }

                            Menu("排序方式") {
                                ForEach(BookshelfSortMode.allCases) { mode in
                                    Button {
                                        viewModel.sortMode = mode
                                    } label: {
                                        if viewModel.sortMode == mode {
                                            Label(mode.title, systemImage: "checkmark")
                                        } else {
                                            Text(mode.title)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }

                        if viewModel.hasShelfBooks {
                            Button("编辑") {
                                viewModel.enterEditMode()
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showGroupManager) {
                BookGroupManagerView(viewModel: viewModel)
            }
            .sheet(isPresented: $showBatchGroupSheet) {
                BookshelfBatchGroupSheet(
                    viewModel: viewModel,
                    onSelect: { group in
                        viewModel.toggleGroupForSelectedBooks(group.groupId)
                        showBatchGroupSheet = false
                    }
                )
            }
            .sheet(isPresented: $showManualSortSheet) {
                BookshelfManualSortSheet(viewModel: viewModel)
            }
            .sheet(item: $exportItem) { item in
                ActivityShareSheet(items: [item.url])
            }
            .alert(
                "确定删除选中的 \(viewModel.selectedBooks.count) 本书？",
                isPresented: $showDeleteConfirmation
            ) {
                Button("删除", role: .destructive) {
                    viewModel.deleteSelectedBooks()
                }
                Button("取消", role: .cancel) {}
            }
            .alert(
                "导出失败",
                isPresented: Binding(
                    get: { exportErrorMessage != nil },
                    set: { newValue in
                        if !newValue { exportErrorMessage = nil }
                    }
                )
            ) {
                Button("确定", role: .cancel) {
                    exportErrorMessage = nil
                }
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .navigationDestination(item: $navigationTarget) { target in
                Group {
                    if let book = viewModel.bookEntity(for: target.bookUrl) {
                        switch target.destination {
                        case .detail:
                            BookDetailView(
                                viewModel: BookDetailViewModel(
                                    searchBook: SearchBook(
                                        bookUrl: book.bookUrl,
                                        name: book.name,
                                        author: book.author,
                                        coverUrl: book.effectiveCoverUrl,
                                        intro: book.effectiveIntro,
                                        kind: book.kind,
                                        lastChapter: book.lastChapter,
                                        updateTime: book.updateTime,
                                        wordCount: book.wordCount,
                                        origin: book.sourceUrl
                                    ),
                                    allSources: allSources
                                ),
                                bookshelfViewModel: viewModel
                            )
                        }
                    }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(item: $readerRoute) { route in
                Group {
                    if let cachedSession = route.cachedSession {
                        ReaderView(
                            viewModel: cachedSession.viewModel,
                            bookID: cachedSession.bookID,
                            allSources: allSources,
                            bookshelfViewModel: viewModel
                        )
                    } else {
                        BookshelfReaderRouteView(
                            book: route.book,
                            source: route.source,
                            allSources: allSources,
                            bookshelfViewModel: viewModel,
                            onFailure: { message in
                                readerRoute = nil
                                readerLaunchError = ReaderLaunchError(
                                    bookURL: route.book.bookUrl,
                                    message: message
                                )
                            }
                        )
                    }
                }
                .toolbar(.hidden, for: .tabBar)
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
                    guard let bookURL = readerLaunchError?.bookURL,
                          let book = viewModel.bookEntity(for: bookURL) else {
                        return
                    }
                    readerLaunchError = nil
                    openReader(for: book)
                }
                Button("取消", role: .cancel) {
                    readerLaunchError = nil
                }
            } message: {
                Text(readerLaunchError?.message ?? "加载章节失败")
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isEditing {
                    batchToolbar
                }
            }
            .task {
                await viewModel.checkUpdates(allSources: allSources)
            }
        }
        .themedNavigationChrome()
    }

    private var groupTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                groupTabButton(title: "全部", isSelected: viewModel.selectedGroupID == nil) {
                    viewModel.selectGroup(nil)
                }

                ForEach(viewModel.visibleGroups, id: \.groupId) { group in
                    groupTabButton(
                        title: group.groupName,
                        isSelected: viewModel.selectedGroupID == group.groupId
                    ) {
                        viewModel.selectGroup(group.groupId)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(themeManager.color(.secondarySurfaceBackground))
    }

    private func groupTabButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? themeManager.color(.selectionFill) : themeManager.color(.secondarySurfaceBackground), in: Capsule())
                .foregroundStyle(isSelected ? themeManager.color(.selectionText) : themeManager.color(.primaryText))
        }
        .buttonStyle(.plain)
    }

    // MARK: 书籍网格
    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.displayBooks, id: \.bookUrl) { book in
                    BookCoverCell(
                        book: book,
                        source: LocalBookSupport.resolveSource(for: book.sourceUrl, in: allSources),
                        isEditing: viewModel.isEditing,
                        isSelected: viewModel.selectedBookURLs.contains(book.bookUrl),
                        onDetail: {
                            guard !viewModel.isEditing else { return }
                            navigationTarget = BookshelfNavigationTarget(
                                bookUrl: book.bookUrl,
                                destination: .detail
                            )
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if viewModel.isEditing {
                            viewModel.toggleSelection(for: book)
                        } else {
                            openReader(for: book)
                        }
                    }
                    .contextMenu {
                        if !viewModel.isEditing {
                            Button {
                                navigationTarget = BookshelfNavigationTarget(
                                    bookUrl: book.bookUrl,
                                    destination: .detail
                                )
                            } label: {
                                Label("书籍详情", systemImage: "info.circle")
                            }

                            if !viewModel.groups.isEmpty {
                                Menu("移入分组") {
                                    ForEach(viewModel.groups, id: \.groupId) { group in
                                        Button {
                                            viewModel.toggleGroup(group.groupId, for: book)
                                        } label: {
                                            Label(
                                                group.groupName,
                                                systemImage: book.hasGroup(group.groupId)
                                                    ? "checkmark.circle.fill"
                                                    : "circle"
                                            )
                                        }
                                    }
                                }
                            }

                            Menu("导出") {
                                Button("导出 TXT") {
                                    Task { await export(book, format: .txt) }
                                }
                                Button("导出 EPUB") {
                                    Task { await export(book, format: .epub) }
                                }
                            }

                            Button(role: .destructive) {
                                viewModel.removeBook(book)
                            } label: {
                                Label("移出书架", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func export(_ book: BookEntity, format: ExportFormat) async {
        do {
            let exporter = BookExporter(modelContext: viewModel.modelContext)
            let exportedURL: URL
            switch format {
            case .txt:
                exportedURL = try await exporter.exportAsTXT(book: book)
            case .epub:
                exportedURL = try await exporter.exportAsEPUB(book: book)
            }
            exportItem = ExportShareItem(url: exportedURL)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func openReader(for book: BookEntity) {
        // 本地书没有对应的书源记录，走 `resolveSource` 拿内置的本地书源
        guard let source = LocalBookSupport.resolveSource(for: book.sourceUrl, in: allSources) else {
            readerLaunchError = ReaderLaunchError(
                bookURL: book.bookUrl,
                message: "该书籍对应的书源已被删除或禁用"
            )
            return
        }
        readerRoute = BookshelfReaderRoute(
            book: book,
            source: source,
            cachedSession: ReaderSessionCache.shared.session(
                bookID: book.bookUrl,
                sourceURL: source.bookSourceUrl
            )
        )
    }

    private var batchToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(viewModel.isAllDisplayBooksSelected ? "取消全选" : "全选") {
                    viewModel.toggleSelectAllDisplayBooks()
                }

                Spacer()

                Text("已选 \(viewModel.selectedBooks.count) 本")
                    .font(.subheadline)
                    .foregroundStyle(themeManager.color(.secondaryText))

                Spacer()

                Button("分组") {
                    showBatchGroupSheet = true
                }
                .disabled(!viewModel.hasSelection)

                Button("排序") {
                    showManualSortSheet = true
                }
                .disabled(viewModel.activeSortMode != .manual || viewModel.displayBooks.count < 2)

                Button("删除", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(!viewModel.hasSelection)
            }
            .padding(.horizontal)
            .padding(.vertical, 14)
            .background(themeManager.color(.surfaceBackground))
        }
    }

    private var filteredEmptyState: some View {
        ThemedEmptyState(
            icon: "tray",
            title: "“\(viewModel.selectedGroupName)”暂无书籍",
            actionTitle: "查看全部",
            action: {
                viewModel.selectGroup(nil)
            }
        )
    }

    // MARK: 空书架
    private var emptyState: some View {
        ThemedEmptyState(
            icon: "books.vertical",
            title: "书架空空如也",
            message: "搜索喜欢的书籍，加入书架开始阅读"
        )
    }
}

private enum ExportFormat {
    case txt
    case epub
}

// MARK: - 书籍封面格子
private struct BookCoverCell: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let book: BookEntity
    let source: BookSource?
    var isEditing: Bool = false
    var isSelected: Bool = false
    var onDetail: (() -> Void)?

    private var shouldShowCurrentChapter: Bool {
        guard let currentChapterName = book.currentChapterName,
              !currentChapterName.isEmpty else {
            return false
        }
        return currentChapterName != book.lastChapter
    }

    private var isFinished: Bool {
        book.totalChapterCount > 0 && book.currentChapterIndex >= book.totalChapterCount - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverImageView(
                url: book.effectiveCoverUrl,
                displaySize: CGSize(width: 110, height: 150),
                source: source,
                bookUrl: book.bookUrl,
                bookName: book.name,
                bookAuthor: book.author
            )
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 3)
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if isEditing {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? themeManager.color(.selectionFill) : themeManager.color(.selectionText))
                                .shadow(radius: 2)
                        }

                        if book.hasNewChapter {
                            ThemedStatusDot(tint: .warning)
                        }

                        if isFinished {
                            Text("完")
                                .font(.system(size: 9))
                                .padding(3)
                                .background(themeManager.color(.success))
                                .foregroundStyle(themeManager.color(.selectionText))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if !isEditing {
                        Button {
                            onDetail?()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(themeManager.color(.selectionText))
                                .shadow(radius: 2)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("书籍详情")
                    }
                }
                .overlay {
                    if isEditing {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? themeManager.color(.selectionFill) : themeManager.color(.divider), lineWidth: 2)
                    }
                }

            Text(book.name)
                .font(themeManager.font(.title, size: 13, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(themeManager.color(.primaryText))

            if let lastChapter = book.lastChapter, !lastChapter.isEmpty {
                Text("最新：" + lastChapter)
                    .font(themeManager.font(.primary, size: 11))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(1)
            }

            if shouldShowCurrentChapter, let currentChapterName = book.currentChapterName {
                Text("读到：\(currentChapterName)")
                    .font(themeManager.font(.primary, size: 11, weight: .medium))
                    .foregroundStyle(themeManager.color(.accent))
                    .lineLimit(1)
            }

            if let updateTime = book.updateTime, !updateTime.isEmpty {
                Text("更新：\(updateTime)")
                    .font(themeManager.font(.monospace, size: 10))
                    .foregroundStyle(themeManager.color(.tertiaryText))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct BookshelfNavigationTarget: Identifiable, Hashable {
    enum Destination: Hashable {
        case detail
    }

    let bookUrl: String
    let destination: Destination
    var id: String { "\(bookUrl)-\(destination)" }
}

private struct BookshelfReaderRoute: Identifiable, Hashable {
    let book: BookEntity
    let source: BookSource
    let cachedSession: ReaderSession?
    let id = UUID()

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Mirrors Android's reader handoff: push the reader route first, then resolve its data.
/// DZMReadController is only created after a usable chapter has been loaded.
struct BookshelfReaderRouteView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let book: BookEntity
    let source: BookSource
    let allSources: [BookSource]
    @ObservedObject var bookshelfViewModel: BookshelfViewModel
    let onFailure: (String) -> Void

    @StateObject private var tocViewModel: BookTocViewModel
    @State private var readerDestination: BookshelfReaderDestination?
    @State private var hasStarted = false

    init(
        book: BookEntity,
        source: BookSource,
        allSources: [BookSource],
        bookshelfViewModel: BookshelfViewModel,
        onFailure: @escaping (String) -> Void
    ) {
        self.book = book
        self.source = source
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        self.onFailure = onFailure
        let viewModel = BookTocViewModel(
            detail: book.toBookDetail(),
            source: source,
            bookshelfViewModel: bookshelfViewModel
        )
        viewModel.allSources = allSources
        _tocViewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            if let readerDestination {
                ReaderView(
                    viewModel: readerDestination.viewModel,
                    bookID: readerDestination.bookID,
                    allSources: allSources,
                    bookshelfViewModel: bookshelfViewModel
                )
            } else {
                VStack(spacing: 16) {
                    ProgressView().scaleEffect(1.2)
                    Text("正在打开阅读器…")
                        .foregroundStyle(themeManager.color(.secondaryText))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeManager.color(.appBackground).ignoresSafeArea())
            }
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await prepareReader()
        }
    }

    @MainActor
    private func prepareReader() async {
        let restoredFromCache = await tocViewModel.restoreCachedChaptersIfAvailable()
        if !restoredFromCache {
            await tocViewModel.loadToc()
        } else {
            Task { @MainActor in await tocViewModel.loadToc() }
        }
        guard let result = tocViewModel.makeReaderViewModel(startIndex: book.currentChapterIndex) else {
            onFailure(tocViewModel.errorMessage ?? "未能获取到目录")
            return
        }

        await result.vm.loadCurrentChapter()
        guard let content = result.vm.currentContent,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onFailure(result.vm.errorMessage ?? "加载章节失败")
            return
        }

        readerDestination = BookshelfReaderDestination(
            viewModel: result.vm,
            bookID: result.bookID
        )

        Task { @MainActor in
            await tocViewModel.waitForBackgroundTocRefresh()
            result.vm.updateChapters(
                tocViewModel.chapters,
                hasCompleteTableOfContents: tocViewModel.hasCompleteTableOfContents
            )
        }
    }
}

private struct BookshelfReaderDestination: Identifiable, Hashable {
    let viewModel: ReaderViewModel
    let bookID: String
    let id = UUID()

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct ReaderLaunchError: Identifiable {
    let bookURL: String
    let message: String
    var id: String { bookURL }
}

private struct BookshelfManualSortSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var viewModel: BookshelfViewModel

    var body: some View {
        NavigationStack {
            List {
                if viewModel.displayBooks.isEmpty {
                    Text("当前分组没有可排序的书籍")
                        .foregroundStyle(themeManager.color(.secondaryText))
                } else {
                    ForEach(viewModel.displayBooks, id: \.bookUrl) { book in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(themeManager.color(.tertiaryText))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.name)
                                    .foregroundStyle(themeManager.color(.primaryText))
                                Text(book.author)
                                    .font(.caption)
                                    .foregroundStyle(themeManager.color(.secondaryText))
                            }

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove(perform: viewModel.moveDisplayBooks)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("手动排序")
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BookshelfBatchGroupSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: BookshelfViewModel
    let onSelect: (BookGroup) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.groups.isEmpty {
                    ThemedEmptyState(icon: "folder", title: "暂无分组")
                } else {
                    List(viewModel.groups, id: \.groupId) { group in
                        Button {
                            onSelect(group)
                        } label: {
                            HStack {
                                Text(group.groupName)
                                    .foregroundStyle(themeManager.color(.primaryText))
                                Spacer()
                                Image(systemName: viewModel.isGroupAppliedToAllSelectedBooks(group.groupId) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        viewModel.isGroupAppliedToAllSelectedBooks(group.groupId)
                                            ? themeManager.color(.selectionFill)
                                            : themeManager.color(.secondaryText)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("批量分组")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 封面图片加载
@MainActor
private final class CoverImageLoader: ObservableObject {
    @Published var image: PlatformImage?
    @Published var isLoading = false

    private var task: Task<Void, Never>?

    func load(
        urlString: String?,
        displaySize: CGSize,
        source: BookSource? = nil,
        bookURL: String? = nil,
        bookName: String = "",
        bookAuthor: String = ""
    ) {
        cancel()

        guard let normalizedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedURL.isEmpty,
              let url = URL(string: normalizedURL) else {
            image = nil
            isLoading = false
            return
        }

        let decodeToken = Self.decodeToken(source: source, bookURL: bookURL)
        let cacheKey = CoverImageCache.cacheKey(for: normalizedURL, size: displaySize, decodeToken: decodeToken)
        if let cached = CoverImageCache.shared.image(forKey: cacheKey) {
            image = cached
            isLoading = false
            return
        }

        image = nil
        isLoading = true
        let request = CoverImageSession.makeRequest(for: url, source: source)
        let session = CoverImageSession.shared
        let scale = CoverImageSession.displayScale
        let pixelSize = CGSize(
            width: max(displaySize.width, 1) * scale,
            height: max(displaySize.height, 1) * scale
        )
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let processed = try await Task.detached(priority: .utility) { () -> (image: PlatformImage, cost: Int)? in
                    let (data, _) = try await session.data(for: request)
                    try Task.checkCancellation()
                    let decodedData = Self.applyCoverDecodeIfNeeded(
                        data,
                        src: normalizedURL,
                        source: source,
                        bookURL: bookURL,
                        bookName: bookName,
                        bookAuthor: bookAuthor
                    )
                    guard let image = Self.downsampledImage(from: decodedData, pixelSize: pixelSize) else {
                        return nil
                    }
                    return (image: image, cost: Self.memoryCost(of: image))
                }.value
                guard !Task.isCancelled else { return }
                guard let processed else {
                    self.isLoading = false
                    return
                }

                CoverImageCache.shared.insert(processed.image, forKey: cacheKey, cost: processed.cost)
                self.image = processed.image
                self.isLoading = false
            } catch {
                self.image = nil
                self.isLoading = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
    }

    deinit {
        task?.cancel()
    }

    private static func decodeToken(source: BookSource?, bookURL: String?) -> String {
        let sourceKey = source?.bookSourceUrl ?? ""
        let rule = source?.coverDecodeJs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bookKey = bookURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(sourceKey)#\(rule)#\(bookKey)"
    }

    nonisolated private static func applyCoverDecodeIfNeeded(
        _ data: Data,
        src: String,
        source: BookSource?,
        bookURL: String?,
        bookName: String,
        bookAuthor: String
    ) -> Data {
        guard let source,
              let coverDecodeJs = source.coverDecodeJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !coverDecodeJs.isEmpty else {
            return data
        }

        let parser = JavaScriptParser(
            baseUrl: source.bookSourceUrl.isEmpty ? src : source.bookSourceUrl,
            source: source,
            variableStore: ParserVariableStore(writeScope: .book),
            requestURL: src
        )
        parser.injectBook(bookUrl: bookURL ?? src, name: bookName, author: bookAuthor)

        do {
            if let decoded = try parser.evaluateBinary(script: coverDecodeJs, resultData: data, src: src),
               !decoded.isEmpty {
                return decoded
            }
        } catch {
            ParserLog.debug("CoverImageLoader", "coverDecodeJs failed src=\(src) error=\(error.localizedDescription)")
        }

        return data
    }

    nonisolated private static func downsampledImage(from data: Data, pixelSize: CGSize) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let maxDimension = max(pixelSize.width, pixelSize.height)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension.rounded(.up)))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

#if canImport(UIKit)
        return UIImage(cgImage: cgImage)
#elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
#endif
    }

    nonisolated private static func memoryCost(of image: PlatformImage) -> Int {
#if canImport(UIKit)
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
#elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
#endif
    }
}

private final class CoverImageCache {
    static let shared = CoverImageCache()

    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    func image(forKey key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: PlatformImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    static func cacheKey(for url: String, size: CGSize, decodeToken: String) -> String {
        "\(url)#\(decodeToken)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int(CoverImageSession.displayScale.rounded()))"
    }
}

private enum CoverImageSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    static var displayScale: CGFloat {
#if canImport(UIKit)
        UIScreen.main.scale
#elseif canImport(AppKit)
        NSScreen.main?.backingScaleFactor ?? 2
#else
        2
#endif
    }

    static func makeRequest(for url: URL, source: BookSource?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)

        if let source,
           let rawHeader = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHeader.isEmpty,
           !rawHeader.hasPrefix("@js:"),
           let headers = AnalyzeUrl.parseHeaderJSONPublic(rawHeader) {
            for (key, value) in headers where !key.isEmpty {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let cookie = source?.cookieJar?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        if request.value(forHTTPHeaderField: "Referer") == nil,
           let host = url.host {
            let scheme = url.scheme ?? "https"
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        return request
    }
}

// MARK: - 封面图片视图（复用）
struct CoverImageView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let url: String?
    var displaySize: CGSize = CGSize(width: 60, height: 80)
    var source: BookSource? = nil
    var bookUrl: String? = nil
    var bookName: String = ""
    var bookAuthor: String = ""

    @StateObject private var loader = CoverImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
#if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
#elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
#endif
            } else if loader.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(themeManager.color(.secondarySurfaceBackground))
            } else {
                placeholderCover
            }
        }
        .task(id: cacheToken) {
            loader.load(
                urlString: url,
                displaySize: displaySize,
                source: source,
                bookURL: bookUrl,
                bookName: bookName,
                bookAuthor: bookAuthor
            )
        }
        .onDisappear {
            loader.cancel()
        }
        .clipped()
    }

    private var cacheToken: String {
        let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceKey = source?.bookSourceUrl ?? ""
        let decodeRule = source?.coverDecodeJs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bookKey = bookUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalizedURL)#\(sourceKey)#\(decodeRule)#\(bookKey)#\(Int(displaySize.width.rounded()))x\(Int(displaySize.height.rounded()))"
    }

    private var placeholderCover: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        themeManager.color(.accent).opacity(0.72),
                        themeManager.color(.badgeBackground).opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(themeManager.color(.selectionText).opacity(0.85))
            }
    }
}
