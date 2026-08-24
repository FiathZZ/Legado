import Combine
import Foundation
import SwiftData

@MainActor
final class RssSourceManagerViewModel: ObservableObject {
    @Published var sources: [RssSourceEntity] = []
    @Published var searchText: String = ""
    @Published var alertMessage: String = ""
    @Published var showAlert: Bool = false
    @Published var isBusy: Bool = false

    private let modelContext: ModelContext
    private var cancellables: Set<AnyCancellable> = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        load()
    }

    var filteredSources: [RssSourceEntity] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sources
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sources.filter { source in
            source.sourceName.localizedCaseInsensitiveContains(keyword) ||
            source.sourceUrl.localizedCaseInsensitiveContains(keyword) ||
            (source.sourceGroup ?? "").localizedCaseInsensitiveContains(keyword)
        }
    }

    func load() {
        let descriptor = FetchDescriptor<RssSourceEntity>(
            sortBy: [
                SortDescriptor(\.customOrder, order: .forward),
                SortDescriptor(\.sourceName, order: .forward)
            ]
        )
        sources = (try? modelContext.fetch(descriptor)) ?? []
    }

    func importFromURL(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            show(message: "请输入 RSS 订阅地址或 JSON 地址")
            return
        }

        await perform {
            _ = try await RssSourceImportService().importSources(from: trimmed, into: self.modelContext)
            self.load()
            self.show(message: "RSS 源导入成功")
        }
    }

    func importFromFile(_ fileURL: URL) async {
        await perform {
            _ = try await RssSourceImportService().importSources(fromFile: fileURL, into: self.modelContext)
            self.load()
            self.show(message: "已从本地文件导入 RSS 源")
        }
    }

    func toggleEnabled(_ source: RssSourceEntity) {
        source.enabled.toggle()
        try? modelContext.save()
        load()
    }

    func delete(_ source: RssSourceEntity) {
        modelContext.delete(source)
        try? modelContext.save()
        load()
    }

    func saveDraft(_ draft: RssSourceDraft, editing source: RssSourceEntity?) {
        let entity = source ?? RssSourceEntity(
            sourceUrl: draft.sourceURL,
            sourceName: draft.sourceName
        )

        entity.sourceUrl = draft.sourceURL
        entity.sourceName = draft.sourceName
        entity.sourceGroup = draft.sourceGroup.nilIfBlank
        entity.sourceComment = draft.sourceComment.nilIfBlank
        entity.enabled = draft.enabled
        entity.sortUrl = draft.sortURL.nilIfBlank
        entity.singleUrl = draft.singleURL
        entity.ruleArticles = draft.ruleArticles.nilIfBlank
        entity.ruleNextPage = draft.ruleNextPage.nilIfBlank
        entity.ruleTitle = draft.ruleTitle.nilIfBlank
        entity.rulePubDate = draft.rulePubDate.nilIfBlank
        entity.ruleDescription = draft.ruleDescription.nilIfBlank
        entity.ruleImage = draft.ruleImage.nilIfBlank
        entity.ruleLink = draft.ruleLink.nilIfBlank
        entity.ruleContent = draft.ruleContent.nilIfBlank
        entity.style = draft.style.nilIfBlank
        entity.enableJs = draft.enableJs
        entity.loadWithBaseUrl = draft.loadWithBaseUrl
        entity.injectJs = draft.injectJs.nilIfBlank
        entity.header = draft.header.nilIfBlank
        entity.concurrentRate = draft.concurrentRate.nilIfBlank

        if source == nil {
            modelContext.insert(entity)
        }

        do {
            try modelContext.save()
            load()
        } catch {
            show(message: error.localizedDescription)
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await action()
        } catch {
            show(message: error.localizedDescription)
        }
    }

    private func show(message: String) {
        alertMessage = message
        showAlert = true
    }
}

struct RssSourceDraft {
    var sourceURL: String = ""
    var sourceName: String = ""
    var sourceGroup: String = ""
    var sourceComment: String = ""
    var enabled: Bool = true
    var sortURL: String = ""
    var singleURL: Bool = false
    var ruleArticles: String = ""
    var ruleNextPage: String = ""
    var ruleTitle: String = ""
    var rulePubDate: String = ""
    var ruleDescription: String = ""
    var ruleImage: String = ""
    var ruleLink: String = ""
    var ruleContent: String = ""
    var style: String = ""
    var enableJs: Bool = true
    var loadWithBaseUrl: Bool = true
    var injectJs: String = ""
    var header: String = ""
    var concurrentRate: String = ""

    init(source: RssSourceEntity? = nil) {
        guard let source else { return }
        sourceURL = source.sourceUrl
        sourceName = source.sourceName
        sourceGroup = source.sourceGroup ?? ""
        sourceComment = source.sourceComment ?? ""
        enabled = source.enabled
        sortURL = source.sortUrl ?? ""
        singleURL = source.singleUrl
        ruleArticles = source.ruleArticles ?? ""
        ruleNextPage = source.ruleNextPage ?? ""
        ruleTitle = source.ruleTitle ?? ""
        rulePubDate = source.rulePubDate ?? ""
        ruleDescription = source.ruleDescription ?? ""
        ruleImage = source.ruleImage ?? ""
        ruleLink = source.ruleLink ?? ""
        ruleContent = source.ruleContent ?? ""
        style = source.style ?? ""
        enableJs = source.enableJs
        loadWithBaseUrl = source.loadWithBaseUrl
        injectJs = source.injectJs ?? ""
        header = source.header ?? ""
        concurrentRate = source.concurrentRate ?? ""
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
