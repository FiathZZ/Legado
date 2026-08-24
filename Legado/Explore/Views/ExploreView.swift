import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let allSources: [BookSource]
    let bookshelfViewModel: BookshelfViewModel

    @StateObject private var viewModel: ExploreViewModel

    init(allSources: [BookSource], bookshelfViewModel: BookshelfViewModel) {
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        _viewModel = StateObject(wrappedValue: ExploreViewModel())
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.sections.isEmpty {
                    Section {
                        emptyState
                            .frame(height: 280)
                            .listRowBackground(themeManager.color(.appBackground))
                    }
                } else {
                    ForEach(viewModel.sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                NavigationLink {
                                    ExploreSourceView(
                                        item: item,
                                        allSources: allSources,
                                        bookshelfViewModel: bookshelfViewModel
                                    )
                                } label: {
                                    ExploreSourceRow(item: item)
                                }
                                .themedSurfaceListRow()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .background(themeManager.color(.appBackground).ignoresSafeArea())
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                scheduleSourceRefresh()
            }
            .onChange(of: sourceSignature) { _, _ in
                scheduleSourceRefresh()
            }
        }
        .themedNavigationChrome()
    }

    private func scheduleSourceRefresh() {
        let sources = allSources
        DispatchQueue.main.async {
            viewModel.updateSources(sources)
        }
    }

    private var sourceSignature: String {
        allSources.map {
            [
                $0.bookSourceUrl,
                $0.bookSourceGroup ?? "",
                $0.exploreUrl ?? "",
                "\($0.enabled)",
                "\($0.enabledExplore)"
            ].joined(separator: "#")
        }
        .joined(separator: "|")
    }

    private var emptyState: some View {
        ThemedEmptyState(
            icon: "square.grid.2x2",
            title: "暂无书源",
            message: "请在书源管理中导入书源"
        )
    }
}

private struct ExploreSourceRow: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let item: ExploreSourceItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.softColor(.warning))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "safari")
                        .foregroundStyle(themeManager.color(.warning))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.source.bookSourceName)
                    .font(.headline)
                    .foregroundStyle(themeManager.color(.primaryText))

                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(themeManager.color(.secondaryText))

                if let comment = item.source.bookSourceComment?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !comment.isEmpty {
                    Text(comment)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeManager.color(.tertiaryText))
        }
        .padding(.vertical, 6)
    }
}
