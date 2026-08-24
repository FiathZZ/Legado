import SwiftUI
import SwiftData

@main
struct LegadoApp: App {
    @StateObject private var themeManager = ThemeManager()

    private let modelContainer: ModelContainer = {
        do {
            let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            return try LegadoModelContainerFactory.makeModelContainer(
                isStoredInMemoryOnly: isRunningTests
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(modelContainer)
                .environmentObject(themeManager)
        }
    }
}

// MARK: - RootView
/// 从环境中取出 modelContext 并传给 ContentView，
/// 使 ContentView 可以在 init 中创建依赖 modelContext 的 ViewModel。
private struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var localImportAlert: RootImportAlertState?
    @State private var ruleSubNotice: String?
    @State private var hasTriggeredRuleSubAutoUpdate = false

    var body: some View {
        ContentView(modelContext: modelContext)
            .tint(themeManager.color(.accent))
            .background(themeManager.color(.appBackground).ignoresSafeArea())
            .onOpenURL { url in
                if ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                    themeManager.handleIncomingFontFile(url)
                } else if LocalBookLibraryService.supportsImport(url: url) {
                    Task {
                        await importLocalBook(url)
                    }
                } else {
                    themeManager.handleIncomingThemeFile(url)
                }
            }
            .alert(
                themeManager.importAlertState?.title ?? "主题导入",
                isPresented: Binding(
                    get: { themeManager.importAlertState != nil },
                    set: { isPresented in
                        if !isPresented {
                            themeManager.dismissImportAlert()
                        }
                    }
                )
            ) {
                if let themeID = themeManager.importAlertState?.themeID {
                    Button("立即应用") {
                        themeManager.applyTheme(id: themeID)
                        themeManager.dismissImportAlert()
                    }
                }
                Button("确定", role: .cancel) {
                    themeManager.dismissImportAlert()
                }
            } message: {
                Text(themeManager.importAlertState?.message ?? "")
            }
            .alert(
                localImportAlert?.title ?? "本地书导入",
                isPresented: Binding(
                    get: { localImportAlert != nil },
                    set: { isPresented in
                        if !isPresented {
                            localImportAlert = nil
                        }
                    }
                )
            ) {
                Button("确定", role: .cancel) {
                    localImportAlert = nil
                }
            } message: {
                Text(localImportAlert?.message ?? "")
            }
            .overlay(alignment: .top) {
                if let ruleSubNotice {
                    Text(ruleSubNotice)
                        .font(themeManager.font(.primary, size: 13, weight: .medium))
                        .foregroundStyle(themeManager.color(.selectionText))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(themeManager.color(.selectionFill), in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task {
                #if DEBUG
                if await Phase13SelfTestRunner.runIfNeeded() {
                    return
                }
                #endif
                await performRuleSubAutoUpdateIfNeeded()
            }
    }

    private func importLocalBook(_ url: URL) async {
        do {
            let book = try await LocalBookLibraryService.importBook(from: url, modelContext: modelContext)
            localImportAlert = RootImportAlertState(
                title: "导入完成",
                message: "《\(book.name)》已加入书架。"
            )
        } catch {
            localImportAlert = RootImportAlertState(
                title: "导入失败",
                message: error.localizedDescription
            )
        }
    }

    private func performRuleSubAutoUpdateIfNeeded() async {
        guard !hasTriggeredRuleSubAutoUpdate else { return }
        hasTriggeredRuleSubAutoUpdate = true

        let subscriptions = RuleSubService.fetchAll(in: modelContext)
        guard !subscriptions.isEmpty else { return }

        let summary = await RuleSubService.updateAllSubscriptions(
            subs: subscriptions,
            in: modelContext,
            onlyAutoUpdate: true,
            onlyDue: true
        )

        guard summary.addedCount > 0 else { return }
        withAnimation(.spring(duration: 0.3)) {
            ruleSubNotice = "书源订阅已更新，新增 \(summary.addedCount) 个书源"
        }

        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    ruleSubNotice = nil
                }
            }
        }
    }
}

private struct RootImportAlertState {
    let title: String
    let message: String
}
