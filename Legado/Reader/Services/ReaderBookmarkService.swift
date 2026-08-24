import Foundation
import SwiftData

@MainActor
final class ReaderBookmarkService {
    private let modelContext: ModelContext?

    init(modelContext: ModelContext?) {
        self.modelContext = modelContext
    }

    @discardableResult
    func addBookmark(
        bookUrl: String,
        chapterIndex: Int,
        pageIndex: Int?,
        utf16Offset: Int?,
        chapterName: String,
        pageText: String?,
        currentContent: String?
    ) -> BookmarkEntity? {
        guard let modelContext, !bookUrl.isEmpty else { return nil }

        let bookmark = BookmarkEntity(
            bookUrl: bookUrl,
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            utf16Offset: utf16Offset,
            chapterName: chapterName,
            bookText: Self.makeSnippet(from: pageText ?? currentContent, limit: 50)
        )
        modelContext.insert(bookmark)
        try? modelContext.save()
        return bookmark
    }

    func bookmarks(for bookUrl: String) -> [BookmarkEntity] {
        guard let modelContext, !bookUrl.isEmpty else { return [] }
        let descriptor = FetchDescriptor<BookmarkEntity>(
            predicate: #Predicate { $0.bookUrl == bookUrl },
            sortBy: [
                SortDescriptor(\.chapterIndex, order: .forward),
                SortDescriptor(\.time, order: .forward)
            ]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func deleteBookmarks(at offsets: IndexSet, in bookmarks: [BookmarkEntity]) {
        guard let modelContext else { return }
        offsets.map { bookmarks[$0] }.forEach(modelContext.delete)
        try? modelContext.save()
    }

    nonisolated static func makeSnippet(from text: String?, limit: Int) -> String {
        let normalized = (text ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalized.isEmpty else { return "暂无摘要" }
        return String(normalized.prefix(limit))
    }
}
