import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RssSourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel: RssSourceManagerViewModel
    @State private var showImportSheet = false
    @State private var showFileImporter = false
    @State private var showManualEditor = false
    @State private var editingSource: RssSourceEntity?
    @State private var editingDraft = RssSourceDraft()

    init(modelContext: ModelContext) {
        _viewModel = StateObject(wrappedValue: RssSourceManagerViewModel(modelContext: modelContext))
    }

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("RSS 订阅源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .searchable(text: $viewModel.searchText, prompt: "搜索 RSS 源")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button("在线导入") {
                            showImportSheet = true
                        }
                        Button("本地导入") {
                            showFileImporter = true
                        }
                        Button("手动新增") {
                            editingSource = nil
                            editingDraft = RssSourceDraft()
                            showManualEditor = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .background(themeManager.color(.appBackground).ignoresSafeArea())
            .sheet(isPresented: $showImportSheet) {
                RssImportURLSheet { urlString in
                    Task {
                        await viewModel.importFromURL(urlString)
                    }
                }
            }
            .sheet(item: $editingSource) { source in
                NavigationStack {
                    RssSourceEditView(
                        draft: $editingDraft,
                        title: "编辑 RSS 源",
                        onSave: {
                            viewModel.saveDraft(editingDraft, editing: source)
                            editingSource = nil
                        }
                    )
                }
            }
            .sheet(isPresented: $showManualEditor) {
                NavigationStack {
                    RssSourceEditView(
                        draft: $editingDraft,
                        title: "手动新增 RSS 源",
                        onSave: {
                            viewModel.saveDraft(editingDraft, editing: nil)
                            editingDraft = RssSourceDraft()
                            showManualEditor = false
                        }
                    )
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText, .text]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    await viewModel.importFromFile(url)
                }
            }
            .alert("提示", isPresented: $viewModel.showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.alertMessage)
            }
        }
        .themedNavigationChrome()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.filteredSources.isEmpty {
            ThemedEmptyState(
                icon: "dot.radiowaves.left.and.right",
                title: "暂无 RSS 订阅源",
                message: "先导入订阅 JSON，或手动录入一个 RSS 源。"
            ) {
                showImportSheet = true
            }
        } else {
            List {
                ForEach(viewModel.filteredSources) { source in
                    row(for: source)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
        }
    }

    private func row(for source: RssSourceEntity) -> some View {
        NavigationLink(destination: RssArticlesView(source: source)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(source.sourceName)
                        .font(themeManager.font(.primary, size: 17, weight: .semibold))
                        .foregroundStyle(themeManager.color(.primaryText))
                    Spacer()
                    Image(systemName: source.enabled ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(source.enabled ? themeManager.color(.success) : themeManager.color(.secondaryText))
                }
                Text(source.sourceUrl)
                    .font(themeManager.font(.primary, size: 12, weight: .regular))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(2)
            }
        }
        .contextMenu {
            Button("编辑") {
                editingSource = source
                editingDraft = RssSourceDraft(source: source)
            }
            Button(source.enabled ? "停用" : "启用") {
                viewModel.toggleEnabled(source)
            }
            Button("删除", role: .destructive) {
                viewModel.delete(source)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(source.enabled ? "停用" : "启用") {
                viewModel.toggleEnabled(source)
            }
            .tint(source.enabled ? themeManager.color(.warning) : themeManager.color(.success))

            Button("编辑") {
                editingSource = source
                editingDraft = RssSourceDraft(source: source)
            }
            .tint(themeManager.color(.accent))

            Button("删除", role: .destructive) {
                viewModel.delete(source)
            }
        }
        .themedSurfaceListRow()
    }
}

private struct RssImportURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var value = ""
    let onConfirm: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅地址") {
                    TextField("粘贴 RSS 订阅地址或 JSON 地址", text: $value, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
            .navigationTitle("在线导入")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("导入") {
                        onConfirm(value)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RssSourceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @Binding var draft: RssSourceDraft
    let title: String
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("基础") {
                TextField("源名称", text: $draft.sourceName)
                TextField("源地址", text: $draft.sourceURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("分组", text: $draft.sourceGroup)
                Toggle("启用", isOn: $draft.enabled)
            }

            Section("分类与列表") {
                TextField("sortUrl", text: $draft.sortURL, axis: .vertical)
                Toggle("singleUrl", isOn: $draft.singleURL)
                TextField("ruleArticles", text: $draft.ruleArticles, axis: .vertical)
                TextField("ruleNextPage", text: $draft.ruleNextPage)
                TextField("ruleTitle", text: $draft.ruleTitle)
                TextField("ruleLink", text: $draft.ruleLink)
                TextField("rulePubDate", text: $draft.rulePubDate)
                TextField("ruleDescription", text: $draft.ruleDescription, axis: .vertical)
                TextField("ruleImage", text: $draft.ruleImage)
            }

            Section("正文") {
                TextField("ruleContent", text: $draft.ruleContent, axis: .vertical)
                Toggle("enableJs", isOn: $draft.enableJs)
                Toggle("loadWithBaseUrl", isOn: $draft.loadWithBaseUrl)
                TextField("injectJs", text: $draft.injectJs, axis: .vertical)
                TextField("style", text: $draft.style, axis: .vertical)
            }

            Section("高级") {
                TextField("header(JSON)", text: $draft.header, axis: .vertical)
                TextField("concurrentRate", text: $draft.concurrentRate)
                TextField("备注", text: $draft.sourceComment, axis: .vertical)
            }
        }
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    onSave()
                    dismiss()
                }
                .disabled(draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
