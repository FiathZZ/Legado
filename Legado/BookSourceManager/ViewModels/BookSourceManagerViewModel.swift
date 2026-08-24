import Foundation
import SwiftData
import Combine

// MARK: - 书源管理 ViewModel
@MainActor
final class BookSourceManagerViewModel: ObservableObject {

    // MARK: 状态
    @Published var bookSources: [BookSource] = []
    @Published var isLoading: Bool = false
    @Published var alertMessage: String = ""
    @Published var showAlert: Bool = false
    @Published var selectedURLs: Set<String> = []
    @Published var searchText: String = ""
    @Published var selectedGroup: String? = nil

    // MARK: SwiftData 上下文
    private var modelContext: ModelContext
    private var cancellables: Set<AnyCancellable> = []

    // MARK: 计算属性
    var allGroups: [String] {
        let groups = Set(bookSources.compactMap { $0.bookSourceGroup })
        return ["全部"] + groups.sorted()
    }

    var filteredSources: [BookSource] {
        var result = bookSources

        if let group = selectedGroup, group != "全部" {
            result = result.filter { $0.bookSourceGroup == group }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.bookSourceName.localizedCaseInsensitiveContains(searchText) ||
                $0.bookSourceUrl.localizedCaseInsensitiveContains(searchText) ||
                ($0.bookSourceGroup ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var enabledCount: Int { bookSources.filter { $0.enabled }.count }

    // MARK: 初始化
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        NotificationCenter.default.publisher(for: .bookSourcesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadFromDatabase()
            }
            .store(in: &cancellables)
        loadFromDatabase()
    }

    // MARK: 从数据库加载
    /// 从 SwiftData 加载所有书源并转换为值类型。
    /// 书源数量通常在几百量级内，全量加载后在内存中过滤性能可接受；
    /// 若未来数量显著增大，可改用 @Query + 分页 FetchDescriptor 优化。
    func loadFromDatabase() {
        let entities = BookSourceRepository.fetchAll(in: modelContext)
        bookSources = entities.map { $0.toBookSource() }
    }

    // MARK: 导入（订阅地址 / 直接 URL）
    /// 支持书源订阅地址、RSS 订阅地址或普通 http/https URL。
    func importFromURL(_ urlString: String) async {
        let trimmed = urlString
            .normalizedImportURLString()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showMessage("请输入有效的书源地址")
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            if trimmed.hasPrefix("yuedu://") {
                let parsed = try BookSourceService.parseSubscription(trimmed)
                if parsed.kind == .rssSource {
                    let imported = try await RssSourceImportService().importSources(from: trimmed, into: modelContext)
                    let linkedBookSources = await RssLinkedBookSourceImporter().importLinkedBookSources(
                        from: imported,
                        into: modelContext
                    )
                    loadFromDatabase()
                    if linkedBookSources.isEmpty {
                        showMessage("成功导入 \(imported.count) 个 RSS 源")
                    } else {
                        showMessage("成功导入 \(imported.count) 个 RSS 源，并自动导入 \(linkedBookSources.count) 个书源")
                    }
                    return
                }
            }

            let newSources: [BookSource]
            if trimmed.first == "[" || trimmed.first == "{" {
                newSources = try BookSourceService.importFromJSONText(trimmed)
            } else if trimmed.hasPrefix("yuedu://") {
                newSources = try await BookSourceService.importFromSubscription(trimmed)
            } else {
                newSources = try await BookSourceService.importFromHTTPURL(trimmed)
            }
            BookSourceRepository.merge(sources: newSources, in: modelContext)
            loadFromDatabase()
            showMessage("成功导入 \(newSources.count) 个书源")
        } catch let error as RssSourceImportError {
            showMessage(error.localizedDescription)
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    // MARK: 删除选中书源
    func deleteSelected() {
        guard !selectedURLs.isEmpty else { return }
        BookSourceRepository.delete(urls: selectedURLs, in: modelContext)
        selectedURLs.removeAll()
        loadFromDatabase()
    }

    // MARK: 全选当前筛选
    func selectAll() {
        selectedURLs = Set(filteredSources.map { $0.bookSourceUrl })
    }

    // MARK: 删除单个书源（滑动删除，基于 filteredSources 的 offsets）
    func delete(at offsets: IndexSet) {
        let toDelete = Set(offsets.map { filteredSources[$0].bookSourceUrl })
        BookSourceRepository.delete(urls: toDelete, in: modelContext)
        loadFromDatabase()
    }

    // MARK: 切换启用状态
    func toggleEnabled(_ source: BookSource) {
        var updated = source
        updated.enabled = !source.enabled
        BookSourceRepository.update(source: updated, in: modelContext)
        loadFromDatabase()
    }

    // MARK: 批量启用 / 禁用选中书源
    func setEnabled(_ enabled: Bool, for urls: Set<String>) {
        BookSourceRepository.setEnabled(enabled, urls: urls, in: modelContext)
        loadFromDatabase()
    }

    // MARK: 全选 / 取消全选
    func toggleSelectAll() {
        if selectedURLs.count == filteredSources.count {
            selectedURLs.removeAll()
        } else {
            selectedURLs = Set(filteredSources.map { $0.bookSourceUrl })
        }
    }

    // MARK: 私有辅助
    private func showMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
