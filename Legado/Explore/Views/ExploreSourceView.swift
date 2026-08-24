import Foundation
import SwiftUI

struct ExploreSourceView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let item: ExploreSourceItem
    let allSources: [BookSource]
    let bookshelfViewModel: BookshelfViewModel
    private let webBook: WebBook
    @State private var menuItems: [ExploreMenuItem]
    @State private var selectionValues: [String: String] = [:]
    @State private var isLoadingMenu = true

    private let columns = [
        GridItem(.adaptive(minimum: 110), spacing: 12)
    ]

    init(item: ExploreSourceItem, allSources: [BookSource], bookshelfViewModel: BookshelfViewModel) {
        self.item = item
        self.allSources = allSources
        self.bookshelfViewModel = bookshelfViewModel
        let book = WebBook(bookSource: item.source)
        self.webBook = book
        _menuItems = State(initialValue: [])
    }

    var body: some View {
        ScrollView {
            if isLoadingMenu {
                ProgressView()
                    .frame(minHeight: 320)
            } else if categories.isEmpty && filters.isEmpty {
                VStack(spacing: 18) {
                    ThemedEmptyState(
                        icon: "tag.slash",
                        title: "暂无分类",
                        message: "该书源暂时无法加载分类"
                    )

                    if let browserVerification {
                        Button {
                            openBrowserVerification(browserVerification)
                        } label: {
                            Label("打开网页验证", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(minHeight: 320)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !filters.isEmpty {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(filters) { filter in
                                Menu {
                                    ForEach(filter.choices, id: \.self) { choice in
                                        Button(choice) {
                                            select(choice, for: filter)
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(filter.title)
                                            .font(.caption)
                                            .foregroundStyle(themeManager.color(.secondaryText))
                                        Text(selectionValues[filter.id] ?? filter.defaultValue ?? filter.choices.first ?? "")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(themeManager.color(.primaryText))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(themeManager.color(.cardBackground))
                                    )
                                }
                            }
                        }
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(categories) { category in
                        NavigationLink {
                            ExploreResultView(
                                source: item.source,
                                category: category,
                                allSources: allSources,
                                bookshelfViewModel: bookshelfViewModel
                            )
                        } label: {
                            Text(category.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(themeManager.color(.primaryText))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .padding(.horizontal, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(themeManager.color(.cardBackground))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    }
                }
                .padding()
            }
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .navigationTitle(item.source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: item.id) {
            await loadMenu()
        }
    }

    private var categories: [ExploreCategory] {
        menuItems.compactMap { item in
            guard let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }
            return ExploreCategory(name: item.title, url: url)
        }
    }

    private var filters: [ExploreMenuItem] {
        menuItems.filter(\.isSelection)
    }

    /// Android exposes a manual browser entry when a dynamic discovery rule falls into its
    /// compatibility branch. The supplied source carries that entry inside `catch`; keep it
    /// reachable on iOS instead of leaving the user at an empty category screen.
    private var browserVerification: (url: String, title: String)? {
        let rule = item.source.exploreUrl ?? ""
        let pattern = #"java\.startBrowser\(\s*[\"']([^\"']+)[\"']\s*,\s*[\"']([^\"']*)[\"']\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: rule,
                range: NSRange(rule.startIndex..., in: rule)
              ),
              let urlRange = Range(match.range(at: 1), in: rule),
              let titleRange = Range(match.range(at: 2), in: rule) else {
            return nil
        }
        return (String(rule[urlRange]), String(rule[titleRange]))
    }

    private func loadMenu() async {
        let menu = await Task.detached(priority: .userInitiated) { [webBook] in
            webBook.getExploreMenu()
        }.value
        guard !Task.isCancelled else { return }
        menuItems = menu
        isLoadingMenu = false
    }

    private func openBrowserVerification(_ verification: (url: String, title: String)) {
        Task { @MainActor in
#if canImport(UIKit) && canImport(WebKit)
            do {
                try await SourceVerificationHelper.shared.startBrowser(
                    source: item.source,
                    url: verification.url,
                    title: verification.title,
                    headers: HTTPClient.resolvedSourceHeaders(
                        baseUrl: verification.url,
                        source: item.source
                    )
                )
                await loadMenu()
            } catch {
                // Closing the verification sheet is an expected user action. There is no
                // parser diagnostic to show on the discover surface.
                ParserLog.debug("ExploreSourceView", "browser verification ended: \(error.localizedDescription)")
            }
#endif
        }
    }

    private func select(_ value: String, for filter: ExploreMenuItem) {
        guard let action = filter.action else { return }
        isLoadingMenu = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { [webBook] in
                Result { () -> [ExploreMenuItem] in
                    try webBook.applyExploreMenuAction(action, infoMap: [filter.title: value])
                    return webBook.getExploreMenu()
                }
            }.value

            guard !Task.isCancelled else { return }
            switch result {
            case .success(let menu):
                menuItems = menu
                selectionValues[filter.id] = value
            case .failure(let error):
                ParserLog.debug("ExploreSourceView", "apply explore selection failed: \(error.localizedDescription)")
            }
            isLoadingMenu = false
        }
    }
}
