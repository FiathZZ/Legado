import Foundation
import Combine

struct ExploreCategory: Identifiable, Hashable {
    let name: String
    let url: String

    var id: String { "\(name)::\(url)" }
}

struct ExploreSourceItem: Identifiable {
    let source: BookSource

    var id: String { source.bookSourceUrl }
    var hasExploreRule: Bool {
        source.enabledExplore && !(source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var statusText: String {
        if !source.enabled { return "书源已停用" }
        return hasExploreRule ? "发现规则已配置" : "未配置发现规则"
    }

    var groupName: String {
        let trimmed = source.bookSourceGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未分组" : trimmed
    }
}

struct ExploreSourceSection: Identifiable {
    let title: String
    let items: [ExploreSourceItem]

    var id: String { title }
}

@MainActor
final class ExploreViewModel: ObservableObject {
    @Published private(set) var sections: [ExploreSourceSection] = []

    init() {}

    nonisolated deinit {}

    func updateSources(_ allSources: [BookSource]) {
        // A library can contain hundreds of sources. Parsing every explore rule here
        // delayed publishing any rows until all JavaScript work had completed.
        // ExploreSourceView resolves one source's categories only after it is selected.
        let items: [ExploreSourceItem] = allSources.map(ExploreSourceItem.init)
        .sorted { lhs, rhs in
            lhs.source.bookSourceName.localizedStandardCompare(rhs.source.bookSourceName) == .orderedAscending
        }

        let grouped: [String: [ExploreSourceItem]] = Dictionary(
            grouping: items,
            by: { item in item.groupName }
        )

        sections = grouped.keys
            .sorted { lhs, rhs in
                if lhs == "未分组" { return false }
                if rhs == "未分组" { return true }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { key in
                ExploreSourceSection(
                    title: key,
                    items: grouped[key] ?? []
                )
            }
    }

}
