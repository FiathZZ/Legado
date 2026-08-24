import SwiftUI

struct ThemeDebugView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let initialThemeID: String?

    @State private var draftTheme: AppTheme?
    @State private var sourceItem: ThemeCatalogItem?
    @State private var statusMessage: String?

    init(initialThemeID: String? = nil) {
        self.initialThemeID = initialThemeID
    }

    var body: some View {
        List {
            if let draftTheme {
                Section("预览") {
                    ThemeDebugPreview(theme: draftTheme)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(themeManager.color(.appBackground))
                }

                Section {
                    Button("应用草稿") {
                        themeManager.preview(theme: draftTheme)
                    }

                    Button("重置到已安装主题") {
                        resetDraft()
                    }

                    Button("恢复内置默认值") {
                        restoreBundledDraft()
                    }

                    Button("保存覆盖当前主题") {
                        saveCurrentTheme()
                    }
                    .disabled(sourceItem?.isBundled == true)

                    Button("另存为新主题") {
                        saveAsCopy()
                    }
                } header: {
                    Text("操作")
                } footer: {
                    if sourceItem?.isBundled == true {
                        Text("内置主题不可直接覆盖；如需调整，请使用“另存为新主题”。")
                    } else {
                        Text("保存后会立即切换到新主题。")
                    }
                }

                ForEach(ThemePaletteGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(ThemePaletteToken.allCases.filter { $0.group == group }) { token in
                            ThemeTokenEditorRow(
                                token: token,
                                color: binding(for: token)
                            )
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle("主题调试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .onAppear(perform: loadDraftIfNeeded)
        .onDisappear {
            themeManager.resetPreview()
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { statusMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        statusMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                statusMessage = nil
            }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private func loadDraftIfNeeded() {
        guard draftTheme == nil else { return }
        let resolvedID = initialThemeID ?? themeManager.activeThemeID
        let item = themeManager.item(for: resolvedID) ?? themeManager.availableThemes.first
        sourceItem = item
        draftTheme = item?.theme ?? themeManager.currentTheme
    }

    private func binding(for token: ThemePaletteToken) -> Binding<ThemeColor> {
        Binding(
            get: {
                draftTheme?.palette[token] ?? ThemeColor(hex: "000000")
            },
            set: { newColor in
                guard var draftTheme else { return }
                draftTheme.palette[token] = newColor
                self.draftTheme = draftTheme
            }
        )
    }

    private func resetDraft() {
        themeManager.resetPreview()
        if let sourceItem {
            draftTheme = sourceItem.theme
        } else {
            draftTheme = themeManager.currentTheme
        }
    }

    private func restoreBundledDraft() {
        if let currentID = sourceItem?.id,
           let bundled = BundledThemeCatalog.themes.first(where: { $0.id == currentID }) {
            draftTheme = bundled
        } else {
            draftTheme = BundledThemeCatalog.classic
        }
    }

    private func saveCurrentTheme() {
        guard let draftTheme else { return }
        do {
            let item = try themeManager.saveEditedTheme(draftTheme, overwrite: true)
            sourceItem = item
            self.draftTheme = item.theme
            statusMessage = "主题已保存并立即应用。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func saveAsCopy() {
        guard let draftTheme else { return }
        do {
            let item = try themeManager.saveThemeCopy(draftTheme, basedOn: sourceItem)
            sourceItem = item
            self.draftTheme = item.theme
            statusMessage = "已创建新主题 “\(item.theme.metadata.name)”。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct ThemeTokenEditorRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let token: ThemePaletteToken
    @Binding var color: ThemeColor

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(token.title)
                    .font(themeManager.font(.primary, size: 15, weight: .medium))
                    .foregroundStyle(themeManager.color(.primaryText))
                Text(token.rawValue)
                    .font(themeManager.font(.monospace, size: 11))
                    .foregroundStyle(themeManager.color(.tertiaryText))
            }

            Spacer()

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.swiftUIColor)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(themeManager.color(.divider), lineWidth: 1)
                )

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()

            TextField("#RRGGBB", text: hexBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(themeManager.font(.monospace, size: 12))
                .multilineTextAlignment(.trailing)
                .frame(width: 92)
        }
        .padding(.vertical, 4)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { color.swiftUIColor },
            set: { color = ThemeColor(color: $0) }
        )
    }

    private var hexBinding: Binding<String> {
        Binding(
            get: { color.cssHex },
            set: { color = ThemeColor(hex: $0) }
        )
    }
}

private struct ThemeDebugPreview: View {
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Legado")
                    .font(theme.typography.font(for: .title, size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.navigationTitle.swiftUIColor)
                Spacer()
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(theme.palette.navigationIcon.swiftUIColor)
            }

            HStack(spacing: 10) {
                previewTab("书架", isActive: true)
                previewTab("搜索", isActive: false)
                previewTab("发现", isActive: false)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("分组标题")
                        .font(theme.typography.font(for: .title, size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.primaryText.swiftUIColor)
                    Spacer()
                    Text("NEW")
                        .font(theme.typography.font(for: .primary, size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.palette.badgeBackground.swiftUIColor, in: Capsule())
                        .foregroundStyle(theme.palette.badgeText.swiftUIColor)
                }

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.palette.cardBackground.swiftUIColor)
                    .frame(height: 96)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("主题卡片")
                                .font(theme.typography.font(for: .title, size: 17, weight: .semibold))
                                .foregroundStyle(theme.palette.primaryText.swiftUIColor)
                            Text("用于验证导航、卡片、按钮、徽标与空状态的映射是否统一。")
                                .font(theme.typography.font(for: .primary, size: 13))
                                .foregroundStyle(theme.palette.secondaryText.swiftUIColor)
                                .lineLimit(2)
                        }
                        .padding(14)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(theme.palette.divider.swiftUIColor.opacity(0.7), lineWidth: 1)
                    )
            }
            .padding()
            .background(theme.palette.groupedBackground.swiftUIColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 10) {
                Text("选中")
                    .font(theme.typography.font(for: .primary, size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.palette.selectionFill.swiftUIColor, in: Capsule())
                    .foregroundStyle(theme.palette.selectionText.swiftUIColor)

                Text("状态")
                    .font(theme.typography.font(for: .primary, size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.palette.warning.swiftUIColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(theme.palette.warning.swiftUIColor)

                Spacer()

                button("主要按钮", fill: theme.palette.selectionFill.swiftUIColor, text: theme.palette.selectionText.swiftUIColor)
            }

            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .foregroundStyle(theme.palette.emptyStateIcon.swiftUIColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("空状态")
                        .font(theme.typography.font(for: .primary, size: 14, weight: .medium))
                        .foregroundStyle(theme.palette.secondaryText.swiftUIColor)
                    Text("暂无可用数据")
                        .font(theme.typography.font(for: .primary, size: 12))
                        .foregroundStyle(theme.palette.tertiaryText.swiftUIColor)
                }
                Spacer()
            }
            .padding()
            .background(theme.palette.surfaceBackground.swiftUIColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.palette.divider.swiftUIColor.opacity(0.7), lineWidth: 1)
            )
        }
        .padding()
        .background(theme.palette.appBackground.swiftUIColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.palette.divider.swiftUIColor.opacity(0.65), lineWidth: 1)
        )
    }

    private func previewTab(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(theme.typography.font(for: .primary, size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? theme.palette.selectionFill.swiftUIColor : theme.palette.secondarySurfaceBackground.swiftUIColor, in: Capsule())
            .foregroundStyle(isActive ? theme.palette.selectionText.swiftUIColor : theme.palette.secondaryText.swiftUIColor)
    }

    private func button(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(theme.typography.font(for: .primary, size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(text)
    }
}
