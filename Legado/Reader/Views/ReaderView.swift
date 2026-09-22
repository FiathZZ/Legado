import SwiftData
import SwiftUI

struct ReaderSession {
    let id: UUID
    let viewModel: ReaderViewModel
    let bookID: String

    init(viewModel: ReaderViewModel, bookID: String, id: UUID = UUID()) {
        self.id = id
        self.viewModel = viewModel
        self.bookID = bookID
    }
}

/// Retains a few validated sessions so a book reopened from the bookshelf can restore its
/// existing content and native pagination immediately.
@MainActor
final class ReaderSessionCache {
    static let shared = ReaderSessionCache()

    private let maximumSessionCount = 3
    private var sessions: [String: ReaderSession] = [:]
    private var recency: [String] = []

    func session(bookID: String, sourceURL: String) -> ReaderSession? {
        let key = cacheKey(bookID: bookID, sourceURL: sourceURL)
        guard let session = sessions[key],
              session.viewModel.currentBookURL == bookID,
              session.viewModel.source.bookSourceUrl == sourceURL,
              let content = session.viewModel.currentContent,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            remove(key: key)
            return nil
        }
        touch(key)
        return session
    }

    func store(_ session: ReaderSession) {
        let sourceURL = session.viewModel.source.bookSourceUrl
        guard !session.bookID.isEmpty,
              !sourceURL.isEmpty,
              let content = session.viewModel.currentContent,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let key = cacheKey(bookID: session.bookID, sourceURL: sourceURL)
        sessions[key] = session
        touch(key)
        while recency.count > maximumSessionCount, let oldest = recency.first {
            remove(key: oldest)
        }
    }

    func remove(bookID: String, sourceURL: String) {
        remove(key: cacheKey(bookID: bookID, sourceURL: sourceURL))
    }

    func removeAll() {
        sessions.removeAll()
        recency.removeAll()
    }

    private func cacheKey(bookID: String, sourceURL: String) -> String {
        "\(sourceURL)|\(bookID)"
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func remove(key: String) {
        sessions[key] = nil
        recency.removeAll { $0 == key }
    }
}

// MARK: - 阅读器入口视图
struct ReaderView: View {
    @State private var session: ReaderSession
    let allSources: [BookSource]
    var bookshelfViewModel: BookshelfViewModel? = nil
    var onSourceSwitched: ((ChangeSourceSelection) -> Void)? = nil

    init(
        viewModel: ReaderViewModel,
        bookID: String,
        allSources: [BookSource],
        bookshelfViewModel: BookshelfViewModel? = nil,
        onSourceSwitched: ((ChangeSourceSelection) -> Void)? = nil
    ) {
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        self.onSourceSwitched = onSourceSwitched
        _session = State(initialValue: ReaderSession(viewModel: viewModel, bookID: bookID))
    }

    var body: some View {
        ReaderShellView(
            session: session,
            allSources: allSources,
            bookshelfViewModel: bookshelfViewModel,
            onSourceSwitched: onSourceSwitched,
            onChangeSourceSelection: handleSourceChange
        )
        .id(session.id)
    }

    private func handleSourceChange(_ selection: ChangeSourceSelection) {
        // First prepare using the prospective source. Do not mutate the shelf record until the
        // chapter has been proven usable; otherwise a failed source switch can leave the book
        // pointing at a source that never produced readable text.
        let preparationViewModel = ReaderViewModel(
            chapters: selection.chapters,
            source: selection.source,
            startIndex: selection.targetIndex,
            bookEntity: nil,
            modelContext: nil,
            bookName: selection.detail.name,
            bookAuthor: selection.detail.author,
            allSources: allSources
        )

        // Keep the currently displayed native controller alive until the replacement has a
        // usable first snapshot. Swapping the session first makes UIKit render an empty reader.
        Task { @MainActor in
            await preparationViewModel.loadCurrentChapter()
            guard let content = preparationViewModel.currentContent,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                session.viewModel.showUserMessage(preparationViewModel.errorMessage ?? "切换书源后加载章节失败")
                return
            }

            let updatedEntity = bookshelfViewModel?.changeBookSource(
                currentBookUrl: session.bookID,
                newDetail: selection.detail,
                newSource: selection.source,
                targetChapterIndex: selection.targetIndex,
                targetChapterName: selection.chapters[safe: selection.targetIndex]?.title,
                totalChapterCount: selection.chapters.count
            )
            let nextViewModel = ReaderViewModel(
                chapters: selection.chapters,
                source: selection.source,
                startIndex: selection.targetIndex,
                bookEntity: updatedEntity,
                modelContext: bookshelfViewModel?.modelContext,
                bookName: selection.detail.name,
                bookAuthor: selection.detail.author,
                allSources: allSources
            )

            // The successful preparation wrote the chapter to disk under the same source/book
            // key, so this is a cheap hydrate instead of another network request.
            await nextViewModel.loadCurrentChapter()

            session = ReaderSession(viewModel: nextViewModel, bookID: selection.detail.bookUrl)
            ReaderSessionCache.shared.store(session)
            onSourceSwitched?(selection)
        }
    }
}

private struct ReaderShellView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var paginator: ReaderPaginatorViewModel
    @StateObject private var ttsManager = TTSManager()
    @State private var readingTimeTracker = ReadingTimeTracker()
    @State private var route: ReaderRoute?
    @State private var context = ReaderRuntimeContext()
    @State private var progressSaveCoordinator = ReaderProgressSaveCoordinator()
    @State private var showAddToBookshelfPrompt = false

    let session: ReaderSession
    let allSources: [BookSource]
    let bookshelfViewModel: BookshelfViewModel?
    let onSourceSwitched: ((ChangeSourceSelection) -> Void)?
    let onChangeSourceSelection: (ChangeSourceSelection) -> Void

    private var viewModel: ReaderViewModel { session.viewModel }

    init(
        session: ReaderSession,
        allSources: [BookSource],
        bookshelfViewModel: BookshelfViewModel?,
        onSourceSwitched: ((ChangeSourceSelection) -> Void)?,
        onChangeSourceSelection: @escaping (ChangeSourceSelection) -> Void
    ) {
        self.session = session
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        self.onSourceSwitched = onSourceSwitched
        self.onChangeSourceSelection = onChangeSourceSelection
        _paginator = StateObject(wrappedValue: ReaderPaginatorViewModel(readerViewModel: session.viewModel))
    }

    var body: some View {
        Group {
            if viewModel.isAudioSource {
                AudioPlayerView(viewModel: viewModel, onBack: { leaveReader() })
            } else {
                ZStack {
                    DZMNativeReaderView(
                        readerViewModel: viewModel,
                        onBackRequested: { position in leaveReader(at: position) },
                        onChapterRequested: { index in
                            Task { @MainActor in
                                await viewModel.goTo(index: index)
                            }
                        },
                        onReadingPositionChanged: handleReadingPositionChanged,
                        onCacheEntireBook: {
                            guard viewModel.entireBookCacheState == .available else { return }
                            Task(priority: .utility) { @MainActor in
                                if await viewModel.downloadEntireBook() {
                                    viewModel.showUserMessage("全书缓存完成")
                                } else {
                                    viewModel.showUserMessage("部分章节缓存失败")
                                }
                            }
                        }
                    )

                    if let message = viewModel.errorMessage {
                        VStack(spacing: 12) {
                            Text(message)
                                .multilineTextAlignment(.center)
                            Button("重新加载") {
                                Task { @MainActor in
                                    await viewModel.loadCurrentChapter()
                                }
                            }
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(24)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .task(id: session.id) {
            await configureSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            readingTimeTracker.handleScenePhase(newPhase)
            guard newPhase == .background else { return }
            flushReadingPosition()
        }
        .onDisappear {
            ttsManager.stop()
            readingTimeTracker.finishTracking()
            flushReadingPosition()
            ReaderSessionCache.shared.store(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .LegadoDictionaryLookup)) { notification in
            handleDictionaryLookupNotification(notification)
        }
        .sheet(item: routeSheetBinding) { route in
            routeView(for: route)
        }
        .overlay(alignment: .top) {
            if let toastMessage = viewModel.toastMessage {
                ReaderToastView(message: toastMessage)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !viewModel.isAudioSource && paginator.isControlsVisible {
                ReaderQuickActionsView(
                    isReadAloudActive: ttsManager.isControlVisible,
                    isReadAloudPlaying: ttsManager.isPlaying,
                    onDictionary: { presentDictionaryLookup() },
                    onReadAloud: {
                        Task { @MainActor in
                            await handleReadAloudQuickAction()
                        }
                    }
                )
            }
        }
        .alert("加入书架", isPresented: $showAddToBookshelfPrompt) {
            Button("加入书架") {
                addCurrentBookToBookshelf()
                dismiss()
            }
            Button("暂不加入", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("是否将“\(viewModel.bookName)”加入书架？加入后会持续保存阅读进度。")
        }
        .overlay(alignment: .bottom) {
            if ttsManager.isControlVisible {
                TTSControlBarView(
                    manager: ttsManager,
                    onPlayPause: {
                        Task { @MainActor in
                            await toggleReadAloudPlayback()
                        }
                    },
                    onStop: {
                        ttsManager.stop()
                    },
                    onClose: {
                        ttsManager.stop()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.toastMessage)
        .animation(.easeInOut(duration: 0.2), value: paginator.isControlsVisible)
        .animation(.easeInOut(duration: 0.2), value: ttsManager.isControlVisible)
    }

    private func configureSession() async {
        viewModel.allSources = allSources
        viewModel.onChangeSource = onChangeSourceSelection
        ttsManager.onChapterFinished = { [weak viewModel, weak ttsManager] in
            guard let viewModel, let ttsManager else { return }
            Task { @MainActor in
                guard ttsManager.isControlVisible else { return }
                ttsManager.prepareForProgrammaticChapterChange()
                guard let nextPayload = await viewModel.advanceToNextChapterForReadAloud() else {
                    ttsManager.stop()
                    return
                }
                ttsManager.startReading(
                    text: nextPayload.text,
                    bookName: viewModel.bookName,
                    chapterTitle: nextPayload.chapterTitle
                )
            }
        }
        // Every navigation source prepares and validates the active chapter before creating
        // ReaderView. The service is still idempotent for restored sessions and retries.
        if viewModel.currentContent == nil {
            await viewModel.loadCurrentChapter()
        }

        // Warm a small bounded window before the user reaches the first chapter boundary. The
        // native scroll controller still owns section insertion and pagination; this only makes
        // its content provider hit the in-memory cache instead of starting disk/network work at
        // the boundary.
        let firstAdjacentIndex = viewModel.currentIndex + 1
        let lastAdjacentIndex = min(firstAdjacentIndex + 1, viewModel.chapters.count - 1)
        if firstAdjacentIndex <= lastAdjacentIndex {
            Task(priority: .userInitiated) { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                for index in firstAdjacentIndex...lastAdjacentIndex {
                    guard !Task.isCancelled else { return }
                    await viewModel.loadChapter(at: index)
                }
            }
        }

        ReaderSessionCache.shared.store(session)
        context = ReaderRuntimeContext(
            latestLookupText: context.latestLookupText,
            readingPosition: paginator.readingPosition
        )
        readingTimeTracker.startTracking(
            bookUrl: viewModel.currentBookURL,
            bookName: viewModel.bookName,
            chapterIndex: viewModel.currentIndex,
            modelContext: modelContext
        )
    }

    private func handleReadingPositionChanged(_ newPosition: ReaderPosition, saveImmediately: Bool) {
        defer { context.readingPosition = newPosition }

        if let oldPosition = context.readingPosition,
           ttsManager.isControlVisible,
           oldPosition != newPosition {
            if oldPosition.chapterIndex != newPosition.chapterIndex,
               ttsManager.consumeProgrammaticChapterChangeAllowance() {
                // TTS 自动续读触发的跳章不应被视为手动打断
            } else {
                ttsManager.stopForUserNavigation()
            }
        }

        if context.readingPosition?.chapterIndex != newPosition.chapterIndex {
            readingTimeTracker.updateVisibleChapter(newPosition.chapterIndex)
        }

        if saveImmediately {
            progressSaveCoordinator.flushLatest(position: newPosition) { position in
                viewModel.saveReadingProgress(position: position)
            }
        } else {
            progressSaveCoordinator.schedule(position: newPosition) { position in
                viewModel.saveReadingProgress(position: position)
            }
        }
    }

    private func flushReadingPosition() {
        if let position = context.readingPosition {
            progressSaveCoordinator.flushLatest(position: position) { position in
                viewModel.saveReadingProgress(position: position)
            }
        } else {
            progressSaveCoordinator.flush(fallbackPosition: nil) { position in
                viewModel.saveReadingProgress(position: position)
            }
        }
    }

    /// Explicit return actions must persist before dismissing because SwiftUI may tear down the
    /// embedded UIKit controller before its disappearance callbacks can report the last page.
    private func leaveReader(at position: ReaderPosition? = nil) {
        if let position {
            progressSaveCoordinator.flushLatest(position: position) { latestPosition in
                viewModel.saveReadingProgress(position: latestPosition)
            }
        } else {
            flushReadingPosition()
        }
        guard let bookshelfViewModel,
              !bookshelfViewModel.isInShelf(bookUrl: viewModel.currentBookURL) else {
            dismiss()
            return
        }
        showAddToBookshelfPrompt = true
    }

    private func addCurrentBookToBookshelf() {
        guard let bookshelfViewModel else { return }
        let detail = BookDetail(
            bookUrl: viewModel.currentBookURL,
            name: viewModel.bookName,
            author: viewModel.bookAuthor,
            lastChapter: viewModel.currentChapter?.title,
            origin: viewModel.source.bookSourceUrl
        )
        bookshelfViewModel.addBook(detail: detail, sourceUrl: viewModel.source.bookSourceUrl)
    }

    private func handleToolRouteRequested(_ toolRoute: ReaderToolRoute) {
        switch toolRoute {
        case .toc:
            route = .toc
        case .changeSource:
            route = .changeSource
        case .bookmarkList:
            route = .bookmarkList
        case .bookSearch:
            route = .bookSearch
        }
    }

    private func handleDictionaryLookupNotification(_ notification: Notification) {
        guard let term = notification.userInfo?[ReaderDictionaryLookupKey.selectedText] as? String else { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.latestLookupText = trimmed
        route = .dictionaryLookup(term: trimmed)
    }

    private func presentDictionaryLookup() {
        if let latestLookupText = context.latestLookupText, !latestLookupText.isEmpty {
            route = .dictionaryLookup(term: latestLookupText)
        } else {
            route = .dictionaryInput(initialTerm: "")
        }
    }

    private func toggleReadAloudPlayback() async {
        if ttsManager.isPlaying {
            ttsManager.pause()
            return
        }

        if ttsManager.isControlVisible {
            ttsManager.resume()
            return
        }

        let startOffset = currentReadAloudStartOffset()
        guard let payload = await viewModel.loadReadAloudPayload(startingAt: startOffset) else {
            viewModel.showUserMessage("当前章节暂无可朗读内容")
            return
        }

        ttsManager.startReading(
            text: payload.text,
            bookName: viewModel.bookName,
            chapterTitle: payload.chapterTitle
        )
    }

    private func handleReadAloudQuickAction() async {
        if ttsManager.isControlVisible {
            ttsManager.stop()
            return
        }

        await toggleReadAloudPlayback()
    }

    private func currentReadAloudStartOffset() -> Int {
        let renderOffset = paginator.currentPage?.contentRange.location ?? paginator.readingPosition.utf16Offset
        let titlePrefixLength = ((viewModel.currentChapter?.title ?? "") + "\n\n").utf16.count
        return max(renderOffset - titlePrefixLength, 0)
    }

    private var routeSheetBinding: Binding<ReaderRoute?> {
        Binding(
            get: { route },
            set: { route = $0 }
        )
    }

    @ViewBuilder
    private func routeView(for route: ReaderRoute) -> some View {
        switch route {
        case .toc:
            ReaderChapterListView(
                chapters: viewModel.chapters,
                currentIndex: paginator.chapterIndex,
                onSelectChapter: { index in
                    self.route = nil
                    Task { @MainActor in
                        await paginator.jumpToChapter(index: index)
                    }
                }
            )
        case .changeSource:
            ChangeSourceView(
                viewModel: ChangeSourceViewModel(
                    bookName: viewModel.bookName,
                    bookAuthor: viewModel.bookAuthor,
                    allSources: viewModel.allSources,
                    prefetchedBook: viewModel.prefetchedBook,
                    currentSourceURL: viewModel.source.bookSourceUrl,
                    currentSourceName: viewModel.source.bookSourceName,
                    currentChapterTitle: viewModel.currentChapter?.title ?? "",
                    currentChapterIndex: viewModel.currentIndex,
                    currentChapterCount: viewModel.chapters.count
                ),
                onConfirm: { selection in
                    // Android saves the active reader state before source migration. Flush the
                    // paginator's real page/offset, not only the current chapter index.
                    flushReadingPosition()
                    self.route = nil
                    viewModel.changeSource(selection)
                }
            )
        case .bookmarkList:
            BookmarkListView(
                readerViewModel: viewModel,
                onSelectBookmark: { bookmark in
                    self.route = nil
                    Task { @MainActor in
                        await paginator.jumpTo(position: bookmark.readerPosition)
                    }
                }
            )
        case .bookSearch:
            BookSearchView(
                readerViewModel: viewModel,
                onSelectResult: { result in
                    self.route = nil
                    Task { @MainActor in
                        await paginator.jumpToChapter(index: result.chapterIndex)
                    }
                }
            )
        case .dictionaryLookup(let term):
            DictionaryLookupView(term: term)
        case .dictionaryInput(let initialTerm):
            DictionaryLookupInputView(initialTerm: initialTerm) { term in
                context.latestLookupText = term
                self.route = .dictionaryLookup(term: term)
            }
        }
    }
}

private enum ReaderRoute: Identifiable, Equatable {
    case toc
    case changeSource
    case bookmarkList
    case bookSearch
    case dictionaryLookup(term: String)
    case dictionaryInput(initialTerm: String)

    var id: String {
        switch self {
        case .toc:
            return "toc"
        case .changeSource:
            return "change-source"
        case .bookmarkList:
            return "bookmark-list"
        case .bookSearch:
            return "book-search"
        case .dictionaryLookup(let term):
            return "dictionary-\(term)"
        case .dictionaryInput(let initialTerm):
            return "dictionary-input-\(initialTerm)"
        }
    }
}

private struct ReaderRuntimeContext {
    var latestLookupText: String?
    var readingPosition: ReaderPosition?
}

private struct ReaderQuickActionsView: View {
    let isReadAloudActive: Bool
    let isReadAloudPlaying: Bool
    let onDictionary: () -> Void
    let onReadAloud: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onDictionary) {
                ReaderQuickActionButton(
                    systemImage: "character.book.closed",
                    backgroundOpacity: 0.58
                )
            }

            Button(action: onReadAloud) {
                ReaderQuickActionButton(
                    systemImage: isReadAloudPlaying ? "speaker.wave.2.fill" : "speaker.wave.2",
                    backgroundOpacity: isReadAloudActive ? 0.78 : 0.58
                )
            }
        }
        // Place these below the reader's top menu, rather than over its actions.
        .padding(.top, 166)
        .padding(.trailing, 16)
    }
}

private struct ReaderQuickActionButton: View {
    let systemImage: String
    let backgroundOpacity: Double

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(backgroundOpacity), in: Circle())
    }
}

private struct ReaderToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .padding(.top, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 安全下标
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
