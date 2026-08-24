import SwiftUI

struct FontLibraryView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var showImportPicker = false
    @State private var alertMessage: String?

    var body: some View {
        List {
            Section("说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("界面字体仅影响书架、搜索、发现、详情、设置与管理页，不影响阅读页字体。")
                        .font(themeManager.font(.primary, size: 14))
                        .foregroundStyle(themeManager.color(.secondaryText))

                    if !themeManager.missingTypographyReferences.isEmpty {
                        Text("当前主题引用了未安装字体，界面已回退到系统字体，可在此重新导入。")
                            .font(themeManager.font(.primary, size: 13, weight: .medium))
                            .foregroundStyle(themeManager.color(.warning))
                    }
                }
                .padding(.vertical, 4)
                .themedSurfaceListRow()
            }

            Section("当前界面字体") {
                Button {
                    themeManager.applyInterfaceFont(postScriptName: nil)
                    alertMessage = "已恢复为主题默认字体。"
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentFontTitle)
                                .font(themeManager.font(.title, size: 16, weight: .semibold))
                                .foregroundStyle(themeManager.color(.primaryText))
                            Text(currentFontSubtitle)
                                .font(themeManager.font(.primary, size: 13))
                                .foregroundStyle(themeManager.color(.secondaryText))
                        }
                        Spacer()
                        Text("恢复默认")
                            .font(themeManager.font(.primary, size: 13, weight: .medium))
                            .foregroundStyle(themeManager.color(.accent))
                    }
                    .padding(.vertical, 4)
                }
                .themedSurfaceListRow()

                Button {
                    showImportPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(themeManager.color(.accent))
                        Text("导入字体文件")
                            .font(themeManager.font(.primary, size: 15, weight: .medium))
                            .foregroundStyle(themeManager.color(.primaryText))
                    }
                }
                .themedSurfaceListRow()
            }

            Section {
                ForEach(themeManager.availableFonts) { item in
                    fontRow(item)
                }
            } header: {
                Text("可用字体")
            } footer: {
                Text("支持 .ttf 与 .otf。主题包后续可直接复用这里的字体注册结果。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle("字体库")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationChrome()
        .sheet(isPresented: $showImportPicker) {
            FontImportDocumentPicker(
                onPick: { url in
                    showImportPicker = false
                    importFont(from: url)
                },
                onCancel: {
                    showImportPicker = false
                }
            )
        }
        .alert(
            "字体提示",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var currentFontTitle: String {
        if let postScriptName = themeManager.interfaceFontOverridePostScriptName {
            return themeManager.fontDisplayName(for: postScriptName)
        }
        return "主题默认字体"
    }

    private var currentFontSubtitle: String {
        if let postScriptName = themeManager.interfaceFontOverridePostScriptName {
            return postScriptName
        }
        return "当前跟随主题 typography 配置"
    }

    @ViewBuilder
    private func fontRow(_ item: ThemeFontLibraryItem) -> some View {
        Button {
            themeManager.applyInterfaceFont(postScriptName: item.postScriptName)
            alertMessage = "已应用“\(item.displayName)”作为界面字体。"
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayName)
                        .font(themeManager.previewFont(postScriptName: item.postScriptName, size: 17, weight: .medium))
                        .foregroundStyle(themeManager.color(.primaryText))
                    Text(item.postScriptName)
                        .font(themeManager.font(.monospace, size: 11))
                        .foregroundStyle(themeManager.color(.tertiaryText))
                    Text(item.previewText)
                        .font(themeManager.previewFont(postScriptName: item.postScriptName, size: 14))
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    ThemedBadge(title: item.source.title, tint: item.isBundled ? .badgeText : .accent)

                    if themeManager.interfaceFontOverridePostScriptName == item.postScriptName {
                        ThemedBadge(title: "当前", tint: .selectionFill)
                    } else {
                        Text("应用")
                            .font(themeManager.font(.primary, size: 13, weight: .medium))
                            .foregroundStyle(themeManager.color(.accent))
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .themedSurfaceListRow()
    }

    private func importFont(from url: URL) {
        do {
            let item = try themeManager.importFont(from: url)
            alertMessage = "字体“\(item.displayName)”已导入，可立即应用。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
