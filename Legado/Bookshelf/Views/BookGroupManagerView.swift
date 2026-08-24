import SwiftUI

struct BookGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @ObservedObject var viewModel: BookshelfViewModel

    @State private var newGroupName = ""
    @State private var pendingDeletion: BookGroup?

    var body: some View {
        NavigationStack {
            List {
                Section("新增分组") {
                    HStack(spacing: 12) {
                        TextField("输入分组名称", text: $newGroupName)
                            .textInputAutocapitalization(.never)

                        Button("添加") {
                            if viewModel.createGroup(named: newGroupName) {
                                newGroupName = ""
                            }
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("现有分组") {
                    if viewModel.groups.isEmpty {
                        Text("还没有自定义分组")
                            .foregroundStyle(themeManager.color(.secondaryText))
                    } else {
                        ForEach(viewModel.groups, id: \.groupId) { group in
                            BookGroupManagerRow(
                                group: group,
                                onRename: { viewModel.renameGroup(group, to: $0) },
                                onToggleVisibility: { viewModel.setGroupVisibility(group, isVisible: $0) },
                                onUpdateSortMode: { viewModel.setGroupSortMode($0, for: group) }
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDeletion = group
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .onMove(perform: viewModel.moveGroups)
                    }
                }
            }
            .navigationTitle("分组管理")
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                        .disabled(viewModel.groups.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("删除分组", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletion = nil
                    }
                }
            )) {
                Button("取消", role: .cancel) {
                    pendingDeletion = nil
                }
                Button("删除", role: .destructive) {
                    if let pendingDeletion {
                        viewModel.deleteGroup(pendingDeletion)
                    }
                    self.pendingDeletion = nil
                }
            } message: {
                Text("删除分组不会删除书籍，只会移除这些书籍上的分组归属。")
            }
        }
    }
}

private struct BookGroupManagerRow: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let group: BookGroup
    let onRename: (String) -> Void
    let onToggleVisibility: (Bool) -> Void
    let onUpdateSortMode: (BookshelfSortMode?) -> Void

    @State private var draftName: String

    init(
        group: BookGroup,
        onRename: @escaping (String) -> Void,
        onToggleVisibility: @escaping (Bool) -> Void,
        onUpdateSortMode: @escaping (BookshelfSortMode?) -> Void
    ) {
        self.group = group
        self.onRename = onRename
        self.onToggleVisibility = onToggleVisibility
        self.onUpdateSortMode = onUpdateSortMode
        _draftName = State(initialValue: group.groupName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(themeManager.color(.tertiaryText))

                TextField("分组名称", text: $draftName)
                    .onSubmit(commitRename)

                Spacer()

                Text("#\(group.order + 1)")
                    .font(.caption)
                    .foregroundStyle(themeManager.color(.secondaryText))
            }

            Toggle("显示在书架顶部", isOn: Binding(
                get: { group.show },
                set: { onToggleVisibility($0) }
            ))
            .font(.caption)
            .tint(themeManager.color(.accent))

            Picker(
                "分组排序",
                selection: Binding(
                    get: { group.bookSort ?? -1 },
                    set: { newValue in
                        onUpdateSortMode(BookshelfSortMode(rawValue: newValue))
                    }
                )
            ) {
                Text("跟随全局").tag(-1)
                ForEach(BookshelfSortMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
        }
        .padding(.vertical, 4)
        .onDisappear(perform: commitRename)
    }

    private func commitRename() {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            draftName = group.groupName
            return
        }
        draftName = trimmedName
        onRename(trimmedName)
    }
}
