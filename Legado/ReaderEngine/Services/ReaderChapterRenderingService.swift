import Foundation

/// Facade service that keeps pagination reusable from the current Reader business layer.
final class ReaderChapterRenderingService {
    private let paginator: ReaderTextPaginationService

    init(paginator: ReaderTextPaginationService = ReaderTextPaginationService()) {
        self.paginator = paginator
    }

    func renderChapter(
        bookID: String,
        chapterID: String,
        chapterIndex: Int,
        chapterTitle: String,
        content: String,
        configuration: ReaderLayoutConfiguration
    ) -> ReaderChapterRenderModel {
        paginator.paginate(
            source: ReaderChapterSource(
                bookID: bookID,
                chapterID: chapterID,
                chapterIndex: chapterIndex,
                title: chapterTitle,
                content: content
            ),
            configuration: configuration
        )
    }
}
