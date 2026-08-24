import Combine
import Foundation
import SwiftUI

@MainActor
final class ReaderPaginatorViewModel: ObservableObject {
    @Published private(set) var renderModel: ReaderChapterRenderModel?
    @Published private(set) var readingPosition: ReaderPosition
    @Published private(set) var viewportSize: CGSize = .zero
    @Published private(set) var safeAreaInsets: EdgeInsets = EdgeInsets()
    @Published var isControlsVisible: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var lastNavigationDirection: ReaderPageNavigationDirection = .stationary

    private let readerViewModel: ReaderViewModel
    private let appearanceStore: ReaderAppearanceStore
    private let renderingService = ReaderChapterRenderingService()
    private var hasPrepared = false
    private var internallyDrivenChapterIndex: Int?

    var appearance: ReaderAppearanceSettings {
        appearanceStore.settings
    }

    var currentPage: ReaderPage? {
        renderModel?.pages[safe: readingPosition.pageIndex]
    }

    var pageIdentity: String {
        "\(readingPosition.chapterIndex)-\(readingPosition.pageIndex)"
    }

    var currentChapterTitle: String {
        renderModel?.source.title ?? readerViewModel.currentChapter?.title ?? ""
    }

    var chapterIndex: Int {
        readingPosition.chapterIndex
    }

    var chapterCount: Int {
        readerViewModel.chapters.count
    }

    var pageCount: Int {
        max(renderModel?.pageCount ?? 0, 1)
    }

    var pageProgressText: String {
        "\(readingPosition.pageIndex + 1)/\(pageCount)"
    }

    var chapterProgressText: String {
        "\(chapterIndex + 1)/\(max(chapterCount, 1))"
    }

    var totalProgress: Double {
        guard chapterCount > 0 else { return 0 }
        let chapterProgress = Double(chapterIndex) / Double(chapterCount)
        let pageProgress = Double(readingPosition.pageIndex + 1) / Double(max(pageCount, 1))
        return min(max((chapterProgress + pageProgress / Double(max(chapterCount, 1))), 0), 1)
    }

    var totalProgressText: String {
        let percentage = max(0, min(totalProgress * 100, 100))
        let rounded = percentage.rounded()
        if abs(percentage - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", percentage)
    }

    init(readerViewModel: ReaderViewModel, appearanceStore: ReaderAppearanceStore? = nil) {
        self.readerViewModel = readerViewModel
        self.appearanceStore = appearanceStore ?? ReaderAppearanceStore()
        self.readingPosition = readerViewModel.restoredReadingPosition()
    }

    func prepareIfNeeded() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        await open(at: readingPosition, persist: false)
    }

    func updateViewport(size: CGSize, safeAreaInsets: EdgeInsets) async {
        guard size.width > 1, size.height > 1 else { return }
        let hasMeaningfulChange = abs(size.width - viewportSize.width) > 0.5
            || abs(size.height - viewportSize.height) > 0.5
            || safeAreaInsets != self.safeAreaInsets
        guard hasMeaningfulChange else { return }
        viewportSize = size
        self.safeAreaInsets = safeAreaInsets
        guard hasPrepared else { return }
        await repaginateCurrentChapter()
    }

    func toggleControls() {
        isControlsVisible.toggle()
    }

    func openRoute(_ route: ReaderToolRoute, handler: (ReaderToolRoute) -> Void) {
        isControlsVisible = false
        handler(route)
    }

    func nextPage() async {
        if readingPosition.pageIndex + 1 < pageCount {
            moveToPage(readingPosition.pageIndex + 1)
            return
        }
        guard chapterIndex + 1 < chapterCount else { return }
        await open(at: ReaderPosition(chapterIndex: chapterIndex + 1), persist: true)
    }

    func previousPage() async {
        if readingPosition.pageIndex > 0 {
            moveToPage(readingPosition.pageIndex - 1)
            return
        }
        guard chapterIndex > 0 else { return }
        await open(at: ReaderPosition(chapterIndex: chapterIndex - 1, pageIndex: .max, utf16Offset: .max), persist: true)
    }

    func jumpToPage(_ pageIndex: Int) {
        moveToPage(pageIndex)
    }

    /// Records the first visible character in continuous scrolling mode.
    func syncScrollPosition(utf16Offset: Int) {
        guard let renderModel, !renderModel.pages.isEmpty else { return }

        let clampedOffset = min(max(utf16Offset, 0), renderModel.attributedText.length)
        let pageIndex = renderModel.pages.lastIndex(where: {
            $0.contentRange.location <= clampedOffset
        }) ?? 0
        let position = ReaderPosition(
            enginePosition: renderModel.clampedPosition(
                ReadingPosition(
                    chapterIndex: readingPosition.chapterIndex,
                    pageIndex: pageIndex,
                    utf16Offset: clampedOffset
                )
            )
        )

        guard position != readingPosition else { return }
        updateNavigationDirection(for: position)
        applyPosition(position, persist: true)
    }

    func jumpToChapter(index: Int) async {
        await open(at: ReaderPosition(chapterIndex: index), persist: true)
    }

    func jumpTo(position: ReaderPosition) async {
        await open(at: position, persist: true)
    }

    func syncToExternalChapterIfNeeded(_ chapterIndex: Int) async {
        guard chapterIndex != readingPosition.chapterIndex else { return }
        guard internallyDrivenChapterIndex != chapterIndex else { return }
        await open(at: ReaderPosition(chapterIndex: chapterIndex), persist: false)
    }

    func refreshCurrentChapter() async {
        await open(at: readingPosition, persist: false)
    }

    func updateAppearance(_ transform: (inout ReaderAppearanceSettings) -> Void) async {
        let oldOffset = preservedUTF16Offset()
        appearanceStore.update(transform)
        await repaginateCurrentChapter(targetOffset: oldOffset)
    }

    func replaceAppearance(with settings: ReaderAppearanceSettings) async {
        let oldOffset = preservedUTF16Offset()
        appearanceStore.replace(with: settings)
        await repaginateCurrentChapter(targetOffset: oldOffset)
    }

    func currentPageSnippet(limit: Int = 80) -> String? {
        let text = currentPage?.attributedText.string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    private func moveToPage(_ pageIndex: Int) {
        guard let renderModel else { return }
        let nextPosition = ReaderPosition(
            enginePosition: renderModel.clampedPosition(
                ReadingPosition(
                    chapterIndex: readingPosition.chapterIndex,
                    pageIndex: pageIndex,
                    utf16Offset: currentPage?.contentRange.location ?? readingPosition.utf16Offset
                )
            )
        )
        updateNavigationDirection(for: nextPosition)
        applyPosition(nextPosition, persist: true)
    }

    private func open(at position: ReaderPosition, persist: Bool) async {
        let clampedChapterIndex = min(max(position.chapterIndex, 0), max(chapterCount - 1, 0))
        updateNavigationDirection(
            for: ReaderPosition(
                chapterIndex: clampedChapterIndex,
                pageIndex: position.pageIndex,
                utf16Offset: position.utf16Offset
            )
        )
        isLoading = true
        errorMessage = nil

        if readerViewModel.currentIndex != clampedChapterIndex {
            internallyDrivenChapterIndex = clampedChapterIndex
            await readerViewModel.goTo(index: clampedChapterIndex, persistProgress: persist)
            internallyDrivenChapterIndex = nil
        } else {
            await readerViewModel.loadCurrentChapter()
        }

        defer { isLoading = false }

        guard viewportSize.width > 1, viewportSize.height > 1 else {
            readingPosition = ReaderPosition(
                chapterIndex: clampedChapterIndex,
                pageIndex: max(position.pageIndex, 0),
                utf16Offset: max(position.utf16Offset, 0)
            )
            return
        }

        guard let chapter = readerViewModel.chapters[safe: clampedChapterIndex] else { return }
        guard let content = readerViewModel.cachedChapters[clampedChapterIndex]?.content,
              !content.isEmpty else {
            renderModel = nil
            errorMessage = readerViewModel.errorMessage ?? "章节内容为空"
            return
        }

        let renderModel = renderingService.renderChapter(
            bookID: readerViewModel.currentBookURL,
            chapterID: chapter.url.isEmpty ? String(clampedChapterIndex) : chapter.url,
            chapterIndex: clampedChapterIndex,
            chapterTitle: chapter.title,
            content: content,
            configuration: appearance.makeLayoutConfiguration(
                viewportSize: viewportSize,
                safeAreaInsets: safeAreaInsets
            )
        )

        self.renderModel = renderModel
        let resolvedPosition = ReaderPosition(enginePosition: renderModel.clampedPosition(position.enginePosition))
        applyPosition(resolvedPosition, persist: persist)
    }

    private func repaginateCurrentChapter(targetOffset: Int? = nil) async {
        let targetPosition = ReaderPosition(
            chapterIndex: readingPosition.chapterIndex,
            pageIndex: readingPosition.pageIndex,
            utf16Offset: targetOffset ?? resolvedUTF16Offset()
        )
        await open(at: targetPosition, persist: false)
    }

    private func resolvedUTF16Offset() -> Int {
        currentPage?.contentRange.location ?? readingPosition.utf16Offset
    }

    private func preservedUTF16Offset() -> Int {
        appearance.flipMode == .scroll ? readingPosition.utf16Offset : resolvedUTF16Offset()
    }

    private func applyPosition(_ position: ReaderPosition, persist: Bool) {
        readingPosition = position
        if persist {
            readerViewModel.saveReadingProgress(position: position)
        }
    }

    private func updateNavigationDirection(for target: ReaderPosition) {
        if target.chapterIndex > readingPosition.chapterIndex {
            lastNavigationDirection = .forward
            return
        }
        if target.chapterIndex < readingPosition.chapterIndex {
            lastNavigationDirection = .backward
            return
        }
        if target.pageIndex > readingPosition.pageIndex {
            lastNavigationDirection = .forward
            return
        }
        if target.pageIndex < readingPosition.pageIndex {
            lastNavigationDirection = .backward
            return
        }
        lastNavigationDirection = .stationary
    }
}

enum ReaderPageNavigationDirection {
    case forward
    case backward
    case stationary
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
