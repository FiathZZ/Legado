import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var activeSheet: SettingsSheet?
    @State private var isProcessing = false
    @State private var progressMessage = ""
    @State private var alertState: SettingsAlertState?
    @State private var showClearAllCacheConfirmation = false
    /// 启动时自动进入上次阅读的书籍
    @AppStorage(AppPreferenceKeys.restoreLastReaderOnLaunch) private var restoreLastReaderOnLaunch = true

    var body: some View {
        NavigationStack {
            List {
                Section("启动") {
                    Toggle(isOn: $restoreLastReaderOnLaunch) {
                        SettingsOverviewRow(
                            icon: "book.pages",
                            title: "启动时打开上次阅读",
                            detail: "开启后，启动应用会自动进入上次阅读的书籍"
                        )
                    }
                    .tint(themeManager.color(.accent))
                    .themedSurfaceListRow()
                }

                Section("外观") {
                    NavigationLink(destination: ThemeManagementView().toolbar(.hidden, for: .tabBar)) {
                        SettingsOverviewRow(
                            icon: "paintpalette",
                            title: "主题与外观",
                            detail: "切换主题、导入导出主题包、打开主题调试"
                        )
                    }
                    .themedSurfaceListRow()

                    NavigationLink(destination: FontLibraryView().toolbar(.hidden, for: .tabBar)) {
                        SettingsOverviewRow(
                            icon: "textformat",
                            title: "字体库",
                            detail: "管理界面字体与导入字体文件"
                        )
                    }
                    .themedSurfaceListRow()
                }

                Section("内容管理") {
                    Button {
                        activeSheet = .importLocalBook
                    } label: {
                        SettingsOverviewRow(
                            icon: "square.and.arrow.down.on.square",
                            title: "导入本地书籍",
                            detail: "支持 TXT / EPUB，从“文件”或 Open In 导入"
                        )
                    }
                    .disabled(isProcessing)
                    .themedSurfaceListRow()

                    NavigationLink(destination: BookSourceManagerView(modelContext: modelContext).toolbar(.hidden, for: .tabBar)) {
                        SettingsOverviewRow(
                            icon: "doc.text.magnifyingglass",
                            title: "书源管理",
                            detail: "导入、新建、启停与调试书源"
                        )
                    }
                    .themedSurfaceListRow()

                    NavigationLink(destination: RssSourceManagerView(modelContext: modelContext).toolbar(.hidden, for: .tabBar)) {
                        SettingsOverviewRow(
                            icon: "dot.radiowaves.left.and.right",
                            title: "RSS 订阅源",
                            detail: "管理 RSS 源、文章列表与正文阅读"
                        )
                    }
                    .themedSurfaceListRow()

                    NavigationLink(destination: ReplaceRuleManagerView().toolbar(.hidden, for: .tabBar)) {
                        SettingsOverviewRow(
                            icon: "wand.and.stars",
                            title: "替换净化",
                            detail: "统一处理正文与标题的替换规则"
                        )
                    }
                    .themedSurfaceListRow()

                    Button {
                        showClearAllCacheConfirmation = true
                    } label: {
                        SettingsOverviewRow(
                            icon: "trash",
                            title: "清理全部阅读缓存",
                            detail: "删除所有章节、目录和离线清单，保留书架与阅读进度"
                        )
                    }
                    .disabled(isProcessing)
                    .tint(themeManager.color(.destructive))
                    .themedSurfaceListRow()
                }

                Section("关于") {
                    NavigationLink(destination: AboutView().toolbar(.hidden, for: .tabBar)) {
                        SettingsOverviewRow(
                            icon: "info.circle",
                            title: "关于",
                            detail: "版本、开发人员、开源许可与免责声明"
                        )
                    }
                    .themedSurfaceListRow()
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .importLocalBook:
                    LocalBookImportDocumentPicker(
                        onPick: { fileURL in
                            activeSheet = nil
                            Task {
                                await importLocalBook(from: fileURL)
                            }
                        },
                        onCancel: {
                            activeSheet = nil
                        }
                    )
                }
            }
            .alert(
                alertState?.title ?? "提示",
                isPresented: Binding(
                    get: { alertState != nil },
                    set: { newValue in
                        if !newValue {
                            alertState = nil
                        }
                    }
                )
            ) {
                Button("确定", role: .cancel) {
                    alertState = nil
                }
            } message: {
                Text(alertState?.message ?? "")
            }
            .alert("清理全部阅读缓存？", isPresented: $showClearAllCacheConfirmation) {
                Button("全部清理", role: .destructive) {
                    Task { await clearAllReadingCaches() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有书籍的章节正文、目录、离线清单和内存阅读会话，但不会删除书架、阅读进度或书源。")
            }
            .overlay {
                if isProcessing {
                    ZStack {
                        themeManager.color(.cardOverlayBackground)
                            .opacity(0.16)
                            .ignoresSafeArea()
                        ProgressView(progressMessage)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .background(themeManager.color(.surfaceBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(themeManager.color(.primaryText))
                    }
                }
            }
        }
        .themedNavigationChrome()
    }

    private func importLocalBook(from url: URL) async {
        isProcessing = true
        progressMessage = "正在导入本地书籍…"
        defer {
            isProcessing = false
            progressMessage = ""
        }

        do {
            let book = try await LocalBookLibraryService.importBook(from: url, modelContext: modelContext)
            alertState = SettingsAlertState(
                title: "导入完成",
                message: "《\(book.name)》已加入书架。"
            )
        } catch {
            alertState = SettingsAlertState(
                title: "导入失败",
                message: error.localizedDescription
            )
        }
    }

    private func clearAllReadingCaches() async {
        isProcessing = true
        progressMessage = "正在清理阅读缓存…"
        defer {
            isProcessing = false
            progressMessage = ""
        }

        let bookshelfViewModel = BookshelfViewModel(modelContext: modelContext)
        await bookshelfViewModel.clearAllReadingCaches()
        alertState = SettingsAlertState(
            title: "清理完成",
            message: "全部阅读缓存已清理，书架和阅读进度已保留。"
        )
    }

}

private struct SettingsOverviewRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(themeManager.softColor(.accent))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .foregroundStyle(themeManager.color(.accent))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeManager.font(.title, size: 15, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))

                Text(detail)
                    .font(themeManager.font(.primary, size: 13))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsAlertState {
    let title: String
    let message: String
}

private enum SettingsSheet: Identifiable {
    case importLocalBook

    var id: String {
        switch self {
        case .importLocalBook:
            return "import-local-book"
        }
    }
}

/// 应用级偏好开关的存储 key。
///
/// 统一用 `@AppStorage` 读写：key 从未写入过时会取 `@AppStorage` 声明的默认值。
/// 所以默认值只在声明处给一次，读取方不要改用 `UserDefaults.bool(forKey:)`，
/// 那条路径在 key 不存在时返回 `false`，会把默认行为改掉。
enum AppPreferenceKeys {
    /// 启动时自动打开上次阅读的书籍
    static let restoreLastReaderOnLaunch = "legado.preference.restoreLastReaderOnLaunch"
}
