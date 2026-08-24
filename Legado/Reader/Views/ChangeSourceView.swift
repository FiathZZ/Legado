import SwiftUI

// MARK: - 换源面板
struct ChangeSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: ChangeSourceViewModel

    let onConfirm: (ChangeSourceSelection) -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("选择书源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            viewModel.startSearch()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel.isSearching)
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    bottomSummary
                }
        }
        .task {
            viewModel.startSearch()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            ProgressView("搜索中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage, viewModel.results.isEmpty {
            ContentUnavailableView {
                Label("没有找到其他书源", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重新搜索") {
                    viewModel.startSearch()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    summaryCard
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)

                Section("可用书源") {
                    ForEach(viewModel.results) { result in
                        ChangeSourceRowView(
                            result: result,
                            onSelect: {
                                if let selection = await viewModel.prepareSelection(for: result) {
                                    onConfirm(selection)
                                }
                            }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.currentSourceSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(viewModel.searchProgressText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isSearching {
                ProgressView(value: Double(viewModel.finishedSources), total: Double(max(viewModel.totalSources, 1)))
                    .tint(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomSummary: some View {
        HStack {
            Text("优先按书名、作者和章节定位排序")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("共 \(viewModel.results.count) 个可用书源")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

private struct ChangeSourceRowView: View {
    let result: ChangeSourceViewModel.ChangeSourceResult
    let onSelect: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.searchBook.name.isEmpty ? "未知书名" : result.searchBook.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(result.searchBook.author.isEmpty ? "作者未知" : result.searchBook.author) · \(result.source.bookSourceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                badge(result.ranking.nameMatch.title, tint: .blue)
                Button(buttonTitle) {
                    Task { await onSelect() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.mini)
                .disabled(result.isApplying)
            }

            if let latestChapter = result.latestChapter, !latestChapter.isEmpty {
                Text(latestChapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
        .padding(.vertical, 2)
    }

    private var buttonTitle: String {
        if result.isApplying {
            return "切换中…"
        }
        return "切换"
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

}
