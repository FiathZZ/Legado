import SwiftUI

private enum ThemeSheet: Identifiable {
    case export(URL)
    case importTheme

    var id: String {
        switch self {
        case .export(let url):
            return "export-\(url.path)"
        case .importTheme:
            return "import"
        }
    }
}

private struct ThemeDebugRoute: Identifiable, Hashable {
    let id: String
}

struct ThemeManagementView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var activeSheet: ThemeSheet?
    @State private var editMode = false
    @State private var selectedThemeIDs: Set<String> = []
    @State private var pendingDelete = false
    @State private var pendingConflictImportURL: URL?
    @State private var showConflictAlert = false
    @State private var messageAlert: String?
    @State private var importedThemeToApply: String?
    @State private var debugRoute: ThemeDebugRoute?

    var body: some View {
        List {
            Section("当前主题") {
                if let active = themeManager.item(for: themeManager.activeThemeID) {
                    ThemeHeroCard(theme: active.theme, isActive: true, isBundled: active.isBundled)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(themeManager.color(.appBackground))
                }
            }

            themeToolsSection

            Section {
                ForEach(themeManager.availableThemes) { item in
                    themeRow(for: item)
                }
            } header: {
                Text("已安装主题")
            } footer: {
                Text("当前主题会立即作用于书架、搜索、发现、详情、设置与管理页。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle("主题与外观")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationChrome()
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if hasUserThemes {
                    Button {
                        editMode.toggle()
                        if !editMode {
                            selectedThemeIDs.removeAll()
                        }
                    } label: {
                        Image(systemName: editMode ? "checkmark.circle.fill" : "checklist")
                    }
                    .accessibilityLabel(editMode ? "完成批量选择" : "批量选择")
                }

                if editMode && !selectedThemeIDs.isEmpty {
                    Button {
                        pendingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除所选主题")
                }
            }
        }
        .navigationDestination(item: $debugRoute) { route in
            ThemeDebugView(initialThemeID: route.id)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .export(let url):
                ThemeExportDocumentPicker(
                    sourceURL: url,
                    onComplete: { _ in
                        cleanupTempFile(url)
                        activeSheet = nil
                        messageAlert = "主题文件已导出。"
                    },
                    onCancel: {
                        cleanupTempFile(url)
                        activeSheet = nil
                    }
                )
            case .importTheme:
                ThemeImportDocumentPicker(
                    onPick: { url in
                        activeSheet = nil
                        handleImport(url)
                    },
                    onCancel: {
                        activeSheet = nil
                    }
                )
            }
        }
        .alert("删除主题", isPresented: $pendingDelete) {
            Button("取消", role: .cancel) {
                selectedThemeIDs.removeAll()
            }
            Button("删除", role: .destructive) {
                deleteSelectedThemes()
            }
        } message: {
            Text(deletePrompt)
        }
        .alert("导入冲突", isPresented: $showConflictAlert) {
            Button("取消", role: .cancel) {
                pendingConflictImportURL = nil
                showConflictAlert = false
            }
            Button("覆盖旧主题") {
                if let url = pendingConflictImportURL {
                    handleImport(url, replaceExisting: true)
                }
                pendingConflictImportURL = nil
                showConflictAlert = false
            }
        } message: {
            Text("导入文件的主题 ID 已存在，是否用新文件覆盖原有用户主题？")
        }
        .alert("主题提示", isPresented: Binding(
            get: { messageAlert != nil || importedThemeToApply != nil },
            set: { isPresented in
                if !isPresented {
                    messageAlert = nil
                    importedThemeToApply = nil
                }
            }
        )) {
            if let importedThemeToApply {
                Button("立即应用") {
                    themeManager.applyTheme(id: importedThemeToApply)
                    self.importedThemeToApply = nil
                }
            }
            Button("确定", role: .cancel) {
                messageAlert = nil
                importedThemeToApply = nil
            }
        } message: {
            if let messageAlert {
                Text(messageAlert)
            } else if let importedThemeToApply,
                      let item = themeManager.item(for: importedThemeToApply) {
                Text("“\(item.theme.metadata.name)” 已导入，是否立即应用？")
            } else {
                Text("")
            }
        }
    }

    private var deletePrompt: String {
        if selectedThemeIDs.contains(themeManager.activeThemeID) {
            return "选中集合包含当前启用主题。删除后会自动切换到可用主题。"
        }
        return "仅删除自定义安装主题，内置主题会保留。"
    }

    private var hasUserThemes: Bool {
        themeManager.availableThemes.contains(where: { !$0.isBundled })
    }

    private func toggleSelection(_ item: ThemeCatalogItem) {
        guard !item.isBundled else { return }
        if selectedThemeIDs.contains(item.id) {
            selectedThemeIDs.remove(item.id)
        } else {
            selectedThemeIDs.insert(item.id)
        }
    }

    private func handleImport(_ url: URL, replaceExisting: Bool = false) {
        do {
            let item = try themeManager.installTheme(from: url, applyImmediately: false, replaceExisting: replaceExisting)
            importedThemeToApply = item.id
        } catch ThemeImportExportError.duplicateThemeID {
            pendingConflictImportURL = url
            showConflictAlert = true
        } catch {
            messageAlert = error.localizedDescription
        }
    }

    private func export(_ item: ThemeCatalogItem) {
        do {
            let url = try themeManager.exportURL(for: item.id)
            activeSheet = .export(url)
        } catch {
            messageAlert = error.localizedDescription
        }
    }

    private func deleteSelectedThemes() {
        do {
            try themeManager.deleteThemes(ids: selectedThemeIDs)
            selectedThemeIDs.removeAll()
            editMode = false
        } catch {
            messageAlert = error.localizedDescription
        }
    }

    private func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private var themeToolsSection: some View {
        Section("主题工具") {
            Button {
                activeSheet = .importTheme
            } label: {
                ThemeToolRow(
                    icon: "square.and.arrow.down",
                    title: "导入主题文件",
                    detail: "从“文件”导入自定义主题包"
                )
            }
            .themedSurfaceListRow()

            Button {
                debugRoute = ThemeDebugRoute(id: themeManager.activeThemeID)
            } label: {
                ThemeToolRow(
                    icon: "paintpalette",
                    title: "打开主题调试",
                    detail: "查看当前主题预览与颜色 token"
                )
            }
            .themedSurfaceListRow()

            Button {
                do {
                    try themeManager.restoreBundledThemes()
                    messageAlert = "内置主题已恢复，可继续切换或导出。"
                } catch {
                    messageAlert = error.localizedDescription
                }
            } label: {
                ThemeToolRow(
                    icon: "arrow.counterclockwise",
                    title: "恢复内置主题",
                    detail: "重新写回系统内置的默认主题"
                )
            }
            .themedSurfaceListRow()
        }
    }

    @ViewBuilder
    private func themeRow(for item: ThemeCatalogItem) -> some View {
        let isActive = item.id == themeManager.activeThemeID
        let isSelected = selectedThemeIDs.contains(item.id)

        ThemeManagementRow(
            item: item,
            isActive: isActive,
            isEditing: editMode,
            isSelected: isSelected,
            onToggleSelection: {
                toggleSelection(item)
            },
            onApply: {
                themeManager.applyTheme(id: item.id)
            },
            onExport: {
                export(item)
            },
            onDebug: {
                debugRoute = ThemeDebugRoute(id: item.id)
            }
        )
        .themedSurfaceListRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !item.isBundled {
                Button(role: .destructive) {
                    selectedThemeIDs = [item.id]
                    pendingDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }

            Button {
                export(item)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .tint(themeManager.color(.accent))
        }
    }
}

private struct ThemeToolRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(themeManager.softColor(.accent))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(themeManager.color(.accent))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeManager.font(.title, size: 16, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))

                Text(detail)
                    .font(themeManager.font(.primary, size: 13))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeManager.color(.tertiaryText))
        }
        .padding(.vertical, 6)
    }
}

private struct ThemeHeroCard: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let theme: AppTheme
    let isActive: Bool
    let isBundled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.metadata.name)
                        .font(themeManager.font(.title, size: 18, weight: .semibold))
                        .foregroundStyle(themeManager.color(.primaryText))
                    Text(theme.metadata.description ?? "无描述")
                        .font(themeManager.font(.primary, size: 13))
                        .foregroundStyle(themeManager.color(.secondaryText))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if isActive {
                        ThemedBadge(title: "当前", tint: .selectionFill)
                    }
                    if isBundled {
                        ThemedBadge(title: "内置", tint: .badgeText)
                    }
                }
            }

            VStack(spacing: 8) {
                ThemeSwatchRow(token: .accent, color: theme.palette.accent)
                ThemeSwatchRow(token: .cardBackground, color: theme.palette.cardBackground)
                ThemeSwatchRow(token: .navigationBackground, color: theme.palette.navigationBackground)
                ThemeSwatchRow(token: .warning, color: theme.palette.warning)
                ThemeSwatchRow(token: .success, color: theme.palette.success)
            }

            Text("作者：\(theme.metadata.author) · 版本：\(theme.metadata.version)")
                .font(themeManager.font(.primary, size: 12))
                .foregroundStyle(themeManager.color(.tertiaryText))
        }
        .themedCard()
    }
}

private struct ThemeManagementRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let item: ThemeCatalogItem
    let isActive: Bool
    let isEditing: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onApply: () -> Void
    let onExport: () -> Void
    let onDebug: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isEditing && !item.isBundled {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? themeManager.color(.selectionFill) : themeManager.color(.secondaryText))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.theme.metadata.name)
                        .font(themeManager.font(.title, size: 16, weight: .semibold))
                        .foregroundStyle(themeManager.color(.primaryText))
                    if isActive {
                        ThemedBadge(title: "当前", tint: .selectionFill)
                    }
                    if item.isBundled {
                        ThemedBadge(title: "内置", tint: .badgeText)
                    }
                }

                Text(item.theme.metadata.description ?? "无描述")
                    .font(themeManager.font(.primary, size: 13))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(2)

                Text(item.theme.metadata.author + " · " + item.theme.metadata.version)
                    .font(themeManager.font(.primary, size: 12))
                    .foregroundStyle(themeManager.color(.tertiaryText))
            }

            Spacer()

            if !isEditing {
                VStack(spacing: 8) {
                    if isActive {
                        Button("已启用") {
                            onApply()
                        }
                        .buttonStyle(ThemedSecondaryButtonStyle())
                        .frame(width: 88)
                    } else {
                        Button("应用") {
                            onApply()
                        }
                        .buttonStyle(ThemedPrimaryButtonStyle())
                        .frame(width: 88)
                    }

                    HStack(spacing: 10) {
                        Button(action: onDebug) {
                            Image(systemName: "paintpalette")
                        }
                        .foregroundStyle(themeManager.color(.accent))

                        Button(action: onExport) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .foregroundStyle(themeManager.color(.secondaryText))
                    }
                    .font(.headline)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                onToggleSelection()
            }
        }
    }
}

private struct ThemeSwatchRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let token: ThemePaletteToken
    let color: ThemeColor

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.swiftUIColor)
                .frame(width: 30, height: 30)

            Text(token.title)
                .font(themeManager.font(.primary, size: 13, weight: .medium))
                .foregroundStyle(themeManager.color(.primaryText))

            Spacer()

            Text(color.cssHex)
                .font(themeManager.font(.monospace, size: 12))
                .foregroundStyle(themeManager.color(.secondaryText))
        }
    }
}
