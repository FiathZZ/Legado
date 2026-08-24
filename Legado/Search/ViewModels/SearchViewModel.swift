import Foundation
import Combine

// MARK: - 搜索 ViewModel（搜索页：关键词输入 + 历史记录）
@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: 状态
    @Published var keyword: String = ""
    @Published var history: [String] = []

    // MARK: 配置
    private let historyKey = "SearchHistoryKey"
    private let maxHistory = 20

    // MARK: 初始化
    init() {
        loadHistory()
    }

    // MARK: 执行搜索（将关键词写入历史，由调用方导航到结果页）
    func commitSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addToHistory(trimmed)
    }

    // MARK: 使用历史词
    func useHistory(_ word: String) {
        keyword = word
        addToHistory(word)
    }

    // MARK: 删除单条历史
    func deleteHistory(_ word: String) {
        history.removeAll { $0 == word }
        saveHistory()
    }

    // MARK: 清空历史
    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // MARK: 私有
    private func addToHistory(_ word: String) {
        history.removeAll { $0 == word }
        history.insert(word, at: 0)
        if history.count > maxHistory {
            history = Array(history.prefix(maxHistory))
        }
        saveHistory()
    }

    private func loadHistory() {
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private func saveHistory() {
        UserDefaults.standard.set(history, forKey: historyKey)
    }
}
