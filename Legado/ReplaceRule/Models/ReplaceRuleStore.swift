import Foundation
import SwiftData

/// 替换净化规则 Repository
struct ReplaceRuleStore {
    let modelContext: ModelContext

    func fetchAll() -> [ReplaceRuleEntity] {
        let descriptor = FetchDescriptor<ReplaceRuleEntity>(
            sortBy: [
                SortDescriptor(\.order, order: .forward),
                SortDescriptor(\.addedTime, order: .forward)
            ]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchEnabled() -> [ReplaceRuleEntity] {
        let predicate = #Predicate<ReplaceRuleEntity> { $0.isEnabled }
        let descriptor = FetchDescriptor<ReplaceRuleEntity>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.order, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func upsert(_ rule: ReplaceRule) {
        let predicate = #Predicate<ReplaceRuleEntity> { $0.id == rule.id }
        let descriptor = FetchDescriptor<ReplaceRuleEntity>(predicate: predicate)
        if let entity = try? modelContext.fetch(descriptor).first {
            entity.update(from: rule)
        } else {
            modelContext.insert(ReplaceRuleEntity(rule: rule))
        }
        try? modelContext.save()
    }

    func upsertAll(_ rules: [ReplaceRule]) {
        for rule in rules {
            upsert(rule)
        }
    }

    func delete(_ entity: ReplaceRuleEntity) {
        modelContext.delete(entity)
        try? modelContext.save()
    }

    func toggleEnabled(_ entity: ReplaceRuleEntity) {
        entity.isEnabled.toggle()
        try? modelContext.save()
    }

    func updateOrder(_ entities: [ReplaceRuleEntity]) {
        for (index, entity) in entities.enumerated() {
            entity.order = index
        }
        try? modelContext.save()
    }
}
