import SwiftUI
import UIKit

/// SwiftUI entry point for the imported DZMeBookRead reader.
///
/// This intentionally embeds `DZMReadController` itself rather than recreating its page or
/// scrolling views. In particular, the scroll table remains below `DZMReadMenu.singleTap`,
/// which is the gesture ownership used by the upstream reader.
struct DZMNativeReaderView: UIViewControllerRepresentable {
    @ObservedObject var readerViewModel: ReaderViewModel
    let onBackRequested: (ReaderPosition?) -> Void
    let onChapterRequested: (Int) -> Void
    let onReadingPositionChanged: (ReaderPosition, Bool) -> Void
    let onCacheEntireBook: () -> Void

    func makeUIViewController(context: Context) -> DZMNativeReaderHostController {
        let controller = DZMNativeReaderHostController()
        controller.apply(
            snapshot: snapshot,
            chapterContentProvider: chapterContentProvider,
            onBackRequested: onBackRequested,
            onChapterRequested: onChapterRequested,
            onReadingPositionChanged: onReadingPositionChanged,
            onCacheEntireBook: onCacheEntireBook,
            cacheState: readerViewModel.entireBookCacheState
        )
        return controller
    }

    func updateUIViewController(_ controller: DZMNativeReaderHostController, context: Context) {
        controller.apply(
            snapshot: snapshot,
            chapterContentProvider: chapterContentProvider,
            onBackRequested: onBackRequested,
            onChapterRequested: onChapterRequested,
            onReadingPositionChanged: onReadingPositionChanged,
            onCacheEntireBook: onCacheEntireBook,
            cacheState: readerViewModel.entireBookCacheState
        )
    }

    private var snapshot: DZMNativeReaderSnapshot? {
        guard let chapter = readerViewModel.currentChapter,
              let content = readerViewModel.currentContent,
              !content.isEmpty else {
            return nil
        }

        return DZMNativeReaderSnapshot(
            bookID: readerViewModel.currentBookURL,
            bookName: readerViewModel.bookName,
            chapters: readerViewModel.chapters.map(\.title),
            chapterIndex: readerViewModel.currentIndex,
            chapterTitle: chapter.title,
            content: content,
            restoredPosition: readerViewModel.restoredReadingPosition()
        )
    }

    private var chapterContentProvider: (Int, @escaping (String?) -> Void) -> Void {
        { index, completion in
            if let content = readerViewModel.cachedChapters[index]?.content, !content.isEmpty {
                completion(content)
                return
            }

            Task { @MainActor in
                await readerViewModel.loadChapter(at: index)
                completion(readerViewModel.cachedChapters[index]?.content)
            }
        }
    }
}

struct DZMNativeReaderSnapshot: Equatable {
    let bookID: String
    let bookName: String
    let chapters: [String]
    let chapterIndex: Int
    let chapterTitle: String
    let content: String
    let restoredPosition: ReaderPosition

    var identity: String {
        "\(bookID)|\(chapterIndex)|\(chapters.count)|\(content.hashValue)"
    }
}

enum DZMReaderChapterTitleResolver {
    static func resolve(snapshotTitle: String, recordChapterTitle: String?) -> String {
        let snapshot = snapshotTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // The native engine can restore an old record whose name is empty or the generic
        // placeholder. The current directory snapshot is authoritative for the visible title.
        if !snapshot.isEmpty {
            return snapshot
        }
        let currentTitle = recordChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return currentTitle.isEmpty || currentTitle == "(无章节名)" ? "阅读中" : currentTitle
    }
}

/// Hosts a replaceable upstream controller. DZMeBookRead predates SwiftUI and assumes it owns
/// a controller for the lifetime of a chapter, so changing chapters creates a fresh native
/// controller after Legado's async loader has supplied the new text.
final class DZMNativeReaderHostController: UIViewController {
    private var displayedIdentity: String?
    private var displayedSnapshot: DZMNativeReaderSnapshot?
    private var readerController: DZMEmbeddedReadController?

    private var onBackRequested: (ReaderPosition?) -> Void = { _ in }
    private var onChapterRequested: (Int) -> Void = { _ in }
    private var onReadingPositionChanged: (ReaderPosition, Bool) -> Void = { _, _ in }
    private var backgroundObserver: NSObjectProtocol?
    private weak var gestureNavigationController: UINavigationController?
    private var previousInteractivePopGestureState: Bool?
    private var onCacheEntireBook: () -> Void = {}
    private var cacheState: ReaderBookCacheState = .available
    private var chapterContentProvider: (Int, @escaping (String?) -> Void) -> Void = { _, completion in
        completion(nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DZMReadConfigure.shared().bgColor
        _ = updateLayoutMetrics()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.readerController?.scrollController?.updateReadRecordForLifecycle()
            self?.readerController?.reportReadingPosition(immediately: true)
        }
    }

    deinit {
        restoreInteractivePopGesture()
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        disableInteractivePopGesture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        restoreInteractivePopGesture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let layoutChanged = updateLayoutMetrics()
        readerController?.view.frame = view.bounds
        readerController?.updateChromeLayout()

        guard let snapshot = displayedSnapshot,
              view.bounds.width > 0,
              view.bounds.height > 0 else { return }

        // `makeUIViewController` happens before the host has its final size. Building the
        // CoreText reader there paginates a large chapter once at zero/temporary dimensions and
        // immediately builds it again here, which can spike memory badly. Create it only now.
        guard readerController != nil else {
            replaceReader(with: snapshot, chapterContentProvider: chapterContentProvider)
            return
        }

        guard layoutChanged else { return }

        // CoreText pagination is derived from the available reading rectangle. Recreate the
        // upstream controller after a size/safe-area change so its current chapter is paginated
        // inside the new safe area rather than merely stretching the old pages.
        let position = readerController?.currentReadingPosition() ?? snapshot.restoredPosition
        replaceReader(
            with: snapshot.withRestoredPosition(position),
            chapterContentProvider: chapterContentProvider
        )
    }

    func apply(
        snapshot: DZMNativeReaderSnapshot?,
        chapterContentProvider: @escaping (Int, @escaping (String?) -> Void) -> Void,
        onBackRequested: @escaping (ReaderPosition?) -> Void,
        onChapterRequested: @escaping (Int) -> Void,
        onReadingPositionChanged: @escaping (ReaderPosition, Bool) -> Void,
        onCacheEntireBook: @escaping () -> Void,
        cacheState: ReaderBookCacheState
    ) {
        self.onBackRequested = onBackRequested
        self.onChapterRequested = onChapterRequested
        self.onReadingPositionChanged = onReadingPositionChanged
        self.onCacheEntireBook = onCacheEntireBook
        self.cacheState = cacheState
        self.chapterContentProvider = chapterContentProvider

        guard let snapshot else { return }
        guard displayedIdentity != snapshot.identity else {
            readerController?.updateCallbacks(
                onBackRequested: onBackRequested,
                onChapterRequested: onChapterRequested,
                onReadingPositionChanged: onReadingPositionChanged,
                onCacheEntireBook: onCacheEntireBook,
                chapterTitle: snapshot.chapterTitle,
                cacheState: cacheState
            )
            return
        }

        displayedIdentity = snapshot.identity
        displayedSnapshot = snapshot

        // Wait until `viewDidLayoutSubviews` has a real reading rectangle. This avoids an
        // expensive temporary pagination pass during navigation.
        guard isViewLoaded, view.bounds.width > 0, view.bounds.height > 0 else { return }
        replaceReader(with: snapshot, chapterContentProvider: chapterContentProvider)
    }

    private func updateLayoutMetrics() -> Bool {
        DZMReadLayoutMetrics.update(bounds: view.bounds, safeAreaInsets: view.safeAreaInsets)
    }

    private func disableInteractivePopGesture() {
        guard let navigationController = containingNavigationController(),
              let gesture = navigationController.interactivePopGestureRecognizer else {
            return
        }
        gestureNavigationController = navigationController
        if previousInteractivePopGestureState == nil {
            previousInteractivePopGestureState = gesture.isEnabled
        }
        gesture.isEnabled = false
    }

    private func restoreInteractivePopGesture() {
        guard let previousInteractivePopGestureState,
              let gesture = gestureNavigationController?.interactivePopGestureRecognizer else {
            return
        }
        gesture.isEnabled = previousInteractivePopGestureState
        self.previousInteractivePopGestureState = nil
        gestureNavigationController = nil
    }

    private func containingNavigationController() -> UINavigationController? {
        var controller: UIViewController? = self
        while let current = controller {
            if let navigationController = current as? UINavigationController {
                return navigationController
            }
            if let navigationController = current.navigationController {
                return navigationController
            }
            controller = current.parent
        }
        return nil
    }

    private func replaceReader(
        with snapshot: DZMNativeReaderSnapshot,
        chapterContentProvider: @escaping (Int, @escaping (String?) -> Void) -> Void
    ) {
        readerController?.willMove(toParent: nil)
        readerController?.view.removeFromSuperview()
        readerController?.removeFromParent()

        // The imported engine stores this setting globally. Set it before creating the native
        // controller so its own `DZMReadViewScrollController` and `DZMReadMenu` are used.
        DZMReadConfigure.shared().effectIndex = NSNumber(value: DZMEffectType.scroll.rawValue)
        DZMReadConfigure.shared().openLongPress = false

        let controller = DZMEmbeddedReadController()
        controller.readModel = DZMNativeReadModelFactory.makeModel(
            from: snapshot,
            chapterContentProvider: chapterContentProvider
        )
        controller.updateCallbacks(
            onBackRequested: onBackRequested,
            onChapterRequested: onChapterRequested,
            onReadingPositionChanged: onReadingPositionChanged,
            onCacheEntireBook: onCacheEntireBook,
            chapterTitle: snapshot.chapterTitle,
            cacheState: cacheState
        )

        addChild(controller)
        view.addSubview(controller.view)
        controller.view.frame = view.bounds
        controller.didMove(toParent: self)
        readerController = controller
    }
}

/// Small adapter around the upstream controller for SwiftUI navigation and Legado's async
/// chapter loader. Rendering, scroll handling, menu presentation, and menu tap handling stay
/// in `DZMReadController` / `DZMReadMenu`.
private final class DZMEmbeddedReadController: DZMReadController {
    private var onBackRequested: (ReaderPosition?) -> Void = { _ in }
    private var onChapterRequested: (Int) -> Void = { _ in }
    private var onReadingPositionChanged: (ReaderPosition, Bool) -> Void = { _, _ in }
    private var onCacheEntireBook: () -> Void = {}
    private var chapterTitle: String = ""
    private var cacheState: ReaderBookCacheState = .available

    func updateCallbacks(
        onBackRequested: @escaping (ReaderPosition?) -> Void,
        onChapterRequested: @escaping (Int) -> Void,
        onReadingPositionChanged: @escaping (ReaderPosition, Bool) -> Void,
        onCacheEntireBook: @escaping () -> Void,
        chapterTitle: String,
        cacheState: ReaderBookCacheState
    ) {
        self.onBackRequested = onBackRequested
        self.onChapterRequested = onChapterRequested
        self.onReadingPositionChanged = onReadingPositionChanged
        self.onCacheEntireBook = onCacheEntireBook
        self.chapterTitle = chapterTitle
        self.cacheState = cacheState
        updateMenuChrome()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateMenuChrome()
    }

    private func updateMenuChrome() {
        guard isViewLoaded else { return }
        updateMenuChapterTitle()
        readMenu?.topView.updateCacheEntireBook(state: cacheState)
    }

    private func updateMenuChapterTitle() {
        let currentTitle = DZMReaderChapterTitleResolver.resolve(
            snapshotTitle: chapterTitle,
            recordChapterTitle: readModel?.recordModel?.chapterModel?.name
        )
        readMenu?.topView.updateChapterTitle(currentTitle)
    }

    func readMenuClickCacheEntireBook(readMenu: DZMReadMenu!) {
        guard cacheState == .available else { return }
        onCacheEntireBook()
    }

    override func readMenuClickBack(readMenu: DZMReadMenu!) {
        // Scroll mode coalesces visible-row updates for performance. A return tap can happen
        // inside that interval, so commit the row currently on screen before reading the record.
        scrollController?.updateReadRecordForLifecycle()
        let position = currentReadingPosition()
        onBackRequested(position)
    }

    override func readMenuClickPreviousChapter(readMenu: DZMReadMenu!) {
        requestChapter(relativeOffset: -1)
    }

    override func readMenuClickNextChapter(readMenu: DZMReadMenu!) {
        requestChapter(relativeOffset: 1)
    }

    override func catalogViewClickChapter(
        catalogView: DZMReadCatalogView,
        chapterListModel: DZMReadChapterListModel
    ) {
        onChapterRequested(chapterListModel.id.intValue - 1)
    }

    override func readMenuDraggingProgress(
        readMenu: DZMReadMenu!,
        toChapterID: NSNumber,
        toPage: Int
    ) {
        onChapterRequested(toChapterID.intValue - 1)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scrollController?.updateReadRecordForLifecycle()
        reportReadingPosition(immediately: true)
    }

    override func readMenuWillDisplay(readMenu: DZMReadMenu!) {
        updateMenuChapterTitle()
        super.readMenuWillDisplay(readMenu: readMenu)
    }

    override func scrollReadingPositionDidChange() {
        updateMenuChapterTitle()
        reportReadingPosition()
    }

    private func requestChapter(relativeOffset: Int) {
        let currentIndex = readModel.recordModel.chapterModel.priority.intValue
        let nextIndex = currentIndex + relativeOffset
        guard nextIndex >= 0, nextIndex < readModel.chapterListModels.count else { return }
        reportReadingPosition(immediately: true)
        onChapterRequested(nextIndex)
    }

    func reportReadingPosition(immediately: Bool = false) {
        guard let position = currentReadingPosition() else { return }
        let callback = onReadingPositionChanged
        if immediately {
            callback(position, true)
            return
        }

        // This can be invoked while the representable is replacing a child controller from
        // `updateUIViewController`. Publishing SwiftUI state synchronously at that point emits
        // “Publishing changes from within view updates” and can recursively rebuild the reader.
        DispatchQueue.main.async {
            callback(position, false)
        }
    }

    func currentReadingPosition() -> ReaderPosition? {
        guard let record = readModel?.recordModel,
              let chapter = record.chapterModel else { return nil }
        return ReaderPosition(
            chapterIndex: chapter.priority.intValue,
            pageIndex: record.page.intValue,
            utf16Offset: record.locationFirst.intValue
        )
    }

    func updateChromeLayout() {
        readMenu?.updateLayout()
    }
}

private extension DZMNativeReaderSnapshot {
    func withRestoredPosition(_ position: ReaderPosition) -> DZMNativeReaderSnapshot {
        DZMNativeReaderSnapshot(
            bookID: bookID,
            bookName: bookName,
            chapters: chapters,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            content: content,
            restoredPosition: position
        )
    }
}

/// Converts Legado's asynchronously fetched chapter into the exact archived model expected by
/// DZMeBookRead's native scroll controller. The current chapter is persisted before the native
/// table asks for it; adjacent chapters continue through Legado's loader when requested.
enum DZMNativeReadModelFactory {
    static func makeModel(
        from snapshot: DZMNativeReaderSnapshot,
        chapterContentProvider: @escaping (Int, @escaping (String?) -> Void) -> Void = { _, completion in completion(nil) }
    ) -> DZMReadModel {
        let bookID = stableBookID(for: snapshot.bookID)
        let chapterID = NSNumber(value: snapshot.chapterIndex + 1)

        let readModel = DZMReadModel()
        readModel.bookID = bookID
        readModel.bookName = snapshot.bookName
        readModel.bookSourceType = .network
        readModel.chapterListModels = snapshot.chapters.enumerated().map { index, title in
            let chapter = DZMReadChapterListModel()
            chapter.bookID = bookID
            chapter.id = NSNumber(value: index + 1)
            chapter.name = title
            return chapter
        }

        let chapter = makeChapter(
            bookID: bookID,
            chapterID: chapterID,
            chapterIndex: snapshot.chapterIndex,
            title: snapshot.chapterTitle,
            content: snapshot.content,
            chapterCount: snapshot.chapters.count
        )

        readModel.loadChapterModel = { requestedChapterID, completion in
            let chapterIndex = requestedChapterID.intValue - 1
            guard snapshot.chapters.indices.contains(chapterIndex) else {
                completion(nil)
                return
            }

            chapterContentProvider(chapterIndex) { content in
                guard let content, !content.isEmpty else {
                    completion(nil)
                    return
                }

                // Pagination is CPU-heavy for long chapters. Build the adjacent chapter before
                // the user reaches it, without blocking scrolling or menu interactions.
                DispatchQueue.global(qos: .userInitiated).async {
                    let chapter = makeChapter(
                        bookID: bookID,
                        chapterID: requestedChapterID,
                        chapterIndex: chapterIndex,
                        title: snapshot.chapters[chapterIndex],
                        content: content,
                        chapterCount: snapshot.chapters.count
                    )
                    DispatchQueue.main.async {
                        completion(chapter)
                    }
                }
            }
        }

        let record = DZMReadRecordModel()
        record.bookID = bookID
        record.chapterModel = chapter
        record.page = NSNumber(value: max(snapshot.restoredPosition.pageIndex, 0))
        if record.page.intValue >= chapter.pageCount.intValue {
            record.page = NSNumber(value: max(chapter.pageCount.intValue - 1, 0))
        }
        readModel.recordModel = record
        // Archiving the complete read model serializes the chapter text and every CoreText page.
        // It is legacy persistence only; doing it synchronously here keeps the reader on the
        // loading screen for large chapters even when pagination was already cached.
        DispatchQueue.global(qos: .utility).async {
            readModel.save()
        }
        return readModel
    }

    private static func makeChapter(
        bookID: String,
        chapterID: NSNumber,
        chapterIndex: Int,
        title: String,
        content: String,
        chapterCount: Int
    ) -> DZMReadChapterModel {
        let paginationSignature = DZMNativeReadModelFactory.paginationSignature()
        let sourceContentSignature = DZMNativeReadModelFactory.contentSignature(content)

        if DZMReadChapterModel.isExist(bookID: bookID, chapterID: chapterID),
           let cachedChapter = DZMKeyedArchiver.unarchiver(
               folderName: bookID,
               fileName: chapterID.stringValue
           ) as? DZMReadChapterModel,
           DZMNativeReadModelFactory.canReuseCachedPagination(
               cachedChapter,
               title: title,
               chapterIndex: chapterIndex,
               chapterCount: chapterCount,
               sourceContentSignature: sourceContentSignature,
               paginationSignature: paginationSignature
           ) {
            return cachedChapter
        }

        let formattedContent = DZM_READ_PH_SPACE + DZMReadParser.contentTypesetting(content: content)
        let chapter = DZMReadChapterModel()
        chapter.bookID = bookID
        chapter.id = chapterID
        chapter.name = title
        chapter.priority = NSNumber(value: chapterIndex)
        chapter.previousChapterID = chapterIndex > 0
            ? NSNumber(value: chapterIndex)
            : DZM_READ_NO_MORE_CHAPTER
        chapter.nextChapterID = chapterIndex + 1 < chapterCount
            ? NSNumber(value: chapterIndex + 2)
            : DZM_READ_NO_MORE_CHAPTER
        chapter.content = formattedContent
        chapter.paginationSignature = paginationSignature
        chapter.sourceContentSignature = sourceContentSignature
        chapter.updateFont()
        return chapter
    }

    /// Fast path for a current-format archive. The signature is calculated from the raw cached
    /// text, so an existing pagination archive can be used without recreating its formatted
    /// `NSAttributedString` just to compare it.
    static func canReuseCachedPagination(
        _ chapter: DZMReadChapterModel,
        title: String,
        chapterIndex: Int,
        chapterCount: Int,
        sourceContentSignature: String,
        paginationSignature: String
    ) -> Bool {
        guard chapter.sourceContentSignature == sourceContentSignature else {
            return false
        }
        return canReuseCachedPaginationMetadata(
            chapter,
            title: title,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            paginationSignature: paginationSignature
        )
    }

    static func canReuseCachedPagination(
        _ chapter: DZMReadChapterModel,
        title: String,
        chapterIndex: Int,
        chapterCount: Int,
        content: String,
        paginationSignature: String
    ) -> Bool {
        guard canReuseCachedPaginationMetadata(
            chapter,
            title: title,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            paginationSignature: paginationSignature
        ) else {
            return false
        }

        return chapter.content == content
    }

    private static func canReuseCachedPaginationMetadata(
        _ chapter: DZMReadChapterModel,
        title: String,
        chapterIndex: Int,
        chapterCount: Int,
        paginationSignature: String
    ) -> Bool {
        // Older DZMe archives can omit fields that the current in-memory model always has.
        // An incomplete archive is not reusable; it must fall through to fresh pagination.
        guard let cachedBookID = chapter.bookID,
              let cachedID = chapter.id,
              let cachedName = chapter.name,
              let cachedPriority = chapter.priority,
              let cachedFullContent = chapter.fullContent,
              let cachedPageCount = chapter.pageCount,
              let cachedPageModels = chapter.pageModels,
              !cachedBookID.isEmpty,
              cachedID.intValue == chapterIndex + 1,
              cachedFullContent.length > 0,
              cachedPageCount.intValue == cachedPageModels.count,
              !cachedPageModels.isEmpty else {
            return false
        }

        let expectedPreviousID = chapterIndex > 0 ? chapterIndex : nil
        let expectedNextID = chapterIndex + 1 < chapterCount ? chapterIndex + 2 : nil

        // These links are deliberately nil at the beginning/end of a book. Keep their
        // optional type here so a legacy archive cannot be implicitly force-unwrapped.
        let cachedPreviousID: NSNumber? = chapter.previousChapterID
        let cachedNextID: NSNumber? = chapter.nextChapterID

        guard cachedName == title,
              Int(cachedPriority.intValue) == chapterIndex,
              matchesChapterID(cachedPreviousID, expected: expectedPreviousID),
              matchesChapterID(cachedNextID, expected: expectedNextID),
              chapter.paginationSignature == paginationSignature else {
            return false
        }

        return true
    }

    private static func matchesChapterID(_ actual: NSNumber?, expected: Int?) -> Bool {
        guard let expected else { return actual == nil }
        return actual.map { Int($0.intValue) == expected } ?? false
    }

    private static func paginationSignature() -> String {
        let bounds = DZM_READ_VIEW_RECT ?? .zero
        let configuration = DZMReadConfigure.shared()
        return [
            String(format: "%.2f", bounds.width),
            String(format: "%.2f", bounds.height),
            String(configuration.fontIndex.intValue),
            String(configuration.fontSize.intValue),
            String(configuration.spacingIndex.intValue)
        ].joined(separator: "|")
    }

    private static func contentSignature(_ content: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Uses a deterministic filename-safe ID because DZMeBookRead archives chapters by book ID.
    static func stableBookID(for sourceBookID: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in sourceBookID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "swift-legado-\(String(hash, radix: 16))"
    }
}
