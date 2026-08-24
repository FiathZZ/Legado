import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var activeSheet: SettingsSheet?
    @State private var isProcessing = false
    @State private var progressMessage = ""
    @State private var alertState: SettingsAlertState?

    var body: some View {
        NavigationStack {
            List {
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
                }

                Section("关于") {
                    HStack {
                        SettingsOverviewRow(
                            icon: "info.circle",
                            title: "版本",
                            detail: "当前已安装版本"
                        )
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundStyle(themeManager.color(.secondaryText))
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
