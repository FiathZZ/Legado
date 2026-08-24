import SwiftUI

struct ReaderChapterListView: View {
    @Environment(\.dismiss) private var dismiss

    let chapters: [BookChapter]
    let currentIndex: Int
    let onSelectChapter: (Int) -> Void

    var body: some View {
        NavigationStack {
            List(chapters.indices, id: \.self) { index in
                Button {
                    dismiss()
                    onSelectChapter(index)
                } label: {
                    HStack(spacing: 12) {
                        Text(chapters[index].title)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index == currentIndex {
                            Image(systemName: "book.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("目录")
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
