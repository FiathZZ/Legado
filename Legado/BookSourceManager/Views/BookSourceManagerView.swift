import SwiftUI
import SwiftData

// MARK: - 书源管理主视图
struct BookSourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel: BookSourceManagerViewModel

    init(modelContext: ModelContext) {
        _viewModel = StateObject(wrappedValue: BookSourceManagerViewModel(modelContext: modelContext))
    }

    @State private var showImportSheet = false
    @State private var isEditMode: EditMode = .inactive
    @State private var showDeleteConfirm = false
    @State private var showBatchTest = false
    @State private var editRoute: BookSourceEditRoute?

    private var isEditing: Bool { isEditMode == .active }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.bookSources.isEmpty {
                    emptyStateView
                } else {
                    bookSourceList
                }
            }
            .background(themeManager.color(.appBackground).ignoresSafeArea())
            .navigationTitle("书源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .searchable(text: $viewModel.searchText, prompt: "搜索书源名称、地址或分组")
            .toolbar { toolbarContent }
            .environment(\.editMode, $isEditMode)
            .sheet(isPresented: $showImportSheet) {
                ImportBookSourceView(viewModel: viewModel)
            }
            .sheet(isPresented: $showBatchTest) {
                BookSourceBatchTestView()
            }
            .sheet(item: $editRoute) { route in
                NavigationStack {
                    BookSourceEditView(
                        sourceEntity: route.sourceURL.flatMap { BookSourceRepository.fetch(url: $0, in: modelContext) }
                    )
                }
            }
            .alert("提示", isPresented: $viewModel.showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.alertMessage)
            }
            .confirmationDialog(
                "确定删除选中的 \(viewModel.selectedURLs.count) 个书源？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    viewModel.deleteSelected()
                    isEditMode = .inactive
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: 空状态
    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 20) {
                ThemedEmptyState(
                    icon: "books.vertical.circle",
                    title: "暂无书源",
                    message: "先导入现有书源，或新建自己的规则。",
                    actionTitle: "导入书源"
                ) {
                    showImportSheet = true
                }
                .frame(height: 280)
            }
            .padding()
        }
    }

    // MARK: 书源列表
    private var bookSourceList: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.allGroups, id: \.self) { group in
                            Button(group) {
                                viewModel.selectedGroup = (group == "全部") ? nil : group
                            }
                            .font(themeManager.font(.primary, size: 13, weight: .medium))
                            .foregroundStyle(
                                (viewModel.selectedGroup ?? "全部") == group
                                    ? themeManager.color(.selectionText)
                                    : themeManager.color(.primaryText)
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                ((viewModel.selectedGroup ?? "全部") == group
                                    ? themeManager.color(.selectionFill)
                                    : themeManager.color(.secondarySurfaceBackground)),
                                in: Capsule()
                            )
                        }
                    }
                }
                .listRowBackground(themeManager.color(.appBackground))
            }

            Section {
                ForEach(viewModel.filteredSources, id: \.bookSourceUrl) { source in
                    BookSourceRowView(
                        source: source,
                        isEditing: isEditing,
                        isSelected: viewModel.selectedURLs.contains(source.bookSourceUrl),
                        onToggleEnabled: { viewModel.toggleEnabled(source) },
                        onToggleSelected: { toggleSelection(source) }
                    )
                    .contextMenu {
                        Button {
                            editRoute = BookSourceEditRoute(sourceURL: source.bookSourceUrl)
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            if let idx = viewModel.filteredSources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                                viewModel.delete(at: IndexSet([idx]))
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            viewModel.toggleEnabled(source)
                        } label: {
                            Label(source.enabled ? "禁用" : "启用",
                                  systemImage: source.enabled ? "xmark.circle" : "checkmark.circle")
                        }
                        .tint(source.enabled ? themeManager.color(.warning) : themeManager.color(.success))
                    }
                }
            } header: {
                if !viewModel.filteredSources.isEmpty {
                    HStack {
                        Text("共 \(viewModel.filteredSources.count) 个书源")
                        Spacer()
                        if isEditing {
                            Button(viewModel.selectedURLs.count == viewModel.filteredSources.count ? "取消全选" : "全选") {
                                viewModel.toggleSelectAll()
                            }
                            .font(.footnote)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
    }

    // MARK: 工具栏
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isEditing {
                Button("完成") { isEditMode = .inactive; viewModel.selectedURLs.removeAll() }
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isEditing && !viewModel.selectedURLs.isEmpty {
                // 批量操作菜单
                Menu {
                    Button {
                        viewModel.setEnabled(true, for: viewModel.selectedURLs)
                    } label: {
                        Label("启用选中", systemImage: "checkmark.circle")
                    }

                    Button {
                        viewModel.setEnabled(false, for: viewModel.selectedURLs)
                    } label: {
                        Label("禁用选中", systemImage: "xmark.circle")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除选中", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            if isEditing {
                Button("全选") {
                    viewModel.selectAll()
                }
            }

            if !isEditing {
                Menu {
                    Button {
                        showImportSheet = true
                    } label: {
                        Label("导入书源", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        editRoute = BookSourceEditRoute(sourceURL: nil)
                    } label: {
                        Label("新建书源", systemImage: "square.and.pencil")
                    }

                    Button {
                        showBatchTest = true
                    } label: {
                        Label("批量测速", systemImage: "checkmark.circle.badge.questionmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                Button("编辑") { isEditMode = .active }
            }
        }
    }

    private func toggleSelection(_ source: BookSource) {
        let key = source.bookSourceUrl
        if viewModel.selectedURLs.contains(key) {
            viewModel.selectedURLs.remove(key)
        } else {
            viewModel.selectedURLs.insert(key)
        }
    }

}

private struct BookSourceEditRoute: Identifiable {
    let sourceURL: String?
    var id: String { sourceURL ?? "new" }
}

// MARK: - Preview
#Preview {
    if let container = try? LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true) {
        BookSourceManagerView(modelContext: container.mainContext)
            .modelContainer(container)
    } else {
        Text("预览不可用")
    }
}
