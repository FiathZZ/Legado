import SwiftUI

struct BookmarkListView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var readerViewModel: ReaderViewModel
    var onSelectBookmark: ((BookmarkEntity) -> Void)? = nil
    @State private var bookmarks: [BookmarkEntity] = []

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView("暂无书签", systemImage: "bookmark")
                } else {
                    List {
                        ForEach(bookmarks, id: \.id) { bookmark in
                            Button {
                                dismiss()
                                if let onSelectBookmark {
                                    onSelectBookmark(bookmark)
                                } else {
                                    Task { @MainActor in
                                        await readerViewModel.jumpToChapter(index: bookmark.chapterIndex)
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(bookmark.chapterName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(bookmark.time.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(bookmark.bookText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)

                                    if !bookmark.content.isEmpty {
                                        Text(bookmark.content)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteBookmarks)
                    }
                }
            }
            .navigationTitle("书签")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: reloadBookmarks)
    }

    private func reloadBookmarks() {
        bookmarks = readerViewModel.bookmarks()
    }

    private func deleteBookmarks(at offsets: IndexSet) {
        readerViewModel.deleteBookmarks(at: offsets, in: bookmarks)
        reloadBookmarks()
    }
}
