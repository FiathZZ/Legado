import Foundation
import SwiftData

// MARK: - 书源 SwiftData 仓库
/// 封装所有对 BookSourceEntity 的 SwiftData CRUD 操作。
/// ViewModel 持有 ModelContext，调用本类的静态方法完成数据操作。
enum BookSourceRepository {

    // MARK: 查询
    /// 返回所有书源实体，按名称升序
    static func fetchAll(in context: ModelContext) -> [BookSourceEntity] {
        let descriptor = FetchDescriptor<BookSourceEntity>(
            sortBy: [SortDescriptor(\.bookSourceName)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 根据 bookSourceUrl 查找实体
    static func fetch(url: String, in context: ModelContext) -> BookSourceEntity? {
        var descriptor = FetchDescriptor<BookSourceEntity>(
            predicate: #Predicate { $0.bookSourceUrl == url }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func fetchURLSet(in context: ModelContext) -> Set<String> {
        Set(fetchAll(in: context).map(\.bookSourceUrl))
    }

    // MARK: 导入（去重合并）
    /// 将 BookSource 数组合并写入数据库：
    /// - 已存在（url 相同）的书源原地更新
    /// - 不存在的书源新建插入
    static func merge(sources: [BookSource], in context: ModelContext) {
        for source in sources {
            if let existing = fetch(url: source.bookSourceUrl, in: context) {
                existing.update(from: source)
            } else {
                context.insert(BookSourceEntity(source: source))
            }
        }
        save(context)
    }

    // MARK: 删除
    /// 删除指定 URL 集合对应的书源
    static func delete(urls: Set<String>, in context: ModelContext) {
        let descriptor = FetchDescriptor<BookSourceEntity>(
            predicate: #Predicate { urls.contains($0.bookSourceUrl) }
        )
        if let entities = try? context.fetch(descriptor) {
            entities.forEach { context.delete($0) }
        }
        save(context)
    }

    // MARK: 更新单个书源
    /// 更新单个书源的字段并保存
    static func update(source: BookSource, in context: ModelContext) {
        guard let entity = fetch(url: source.bookSourceUrl, in: context) else { return }
        entity.update(from: source)
        save(context)
    }

    static func upsert(source: BookSource, replacing originalURL: String? = nil, in context: ModelContext) {
        let normalizedOriginalURL = originalURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedOriginalURL,
           !normalizedOriginalURL.isEmpty,
           let existing = fetch(url: normalizedOriginalURL, in: context) {
            if normalizedOriginalURL != source.bookSourceUrl,
               let duplicate = fetch(url: source.bookSourceUrl, in: context),
               duplicate !== existing {
                duplicate.update(from: source)
                context.delete(existing)
                save(context)
                return
            }
            existing.bookSourceUrl = source.bookSourceUrl
            existing.update(from: source)
            save(context)
            return
        }

        if let existing = fetch(url: source.bookSourceUrl, in: context) {
            existing.update(from: source)
        } else {
            context.insert(BookSourceEntity(source: source))
        }
        save(context)
    }

    // MARK: 批量切换启用状态
    /// 将指定 URL 集合的书源批量设为启用/禁用
    static func setEnabled(_ enabled: Bool, urls: Set<String>, in context: ModelContext) {
        let descriptor = FetchDescriptor<BookSourceEntity>(
            predicate: #Predicate { urls.contains($0.bookSourceUrl) }
        )
        if let entities = try? context.fetch(descriptor) {
            entities.forEach { $0.enabled = enabled }
        }
        save(context)
    }

    private static func save(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: .bookSourcesDidChange, object: nil)
    }
}
