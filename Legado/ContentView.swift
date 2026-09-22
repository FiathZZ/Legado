import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    // 书架 ViewModel 在顶层持有，以便书架、搜索、详情页共享同一实例
    @StateObject private var bookshelfViewModel: BookshelfViewModel
    // 书源 ViewModel 同样在顶层持有，为搜索和书架页提供统一的书源数据
    @StateObject private var bookSourceViewModel: BookSourceManagerViewModel
    @State private var startupReaderRoute: StartupReaderRoute?
    @State private var hasResolvedStartupReader = false
    /// 启动时自动进入上次阅读的书籍，可在「设置 → 启动」里关闭
    @AppStorage(AppPreferenceKeys.restoreLastReaderOnLaunch) private var restoreLastReaderOnLaunch = true

    init(modelContext: ModelContext) {
        _bookshelfViewModel = StateObject(wrappedValue: BookshelfViewModel(modelContext: modelContext))
        _bookSourceViewModel = StateObject(wrappedValue: BookSourceManagerViewModel(modelContext: modelContext))
    }

    var body: some View {
        ZStack {
            themeManager.color(.appBackground)
                .ignoresSafeArea()

            TabView {
                BookshelfView(
                    viewModel: bookshelfViewModel,
                    allSources: bookSourceViewModel.bookSources
                )
                .tabItem {
                    Label("书架", systemImage: "books.vertical.fill")
                }

                SearchView(
                    allSources: bookSourceViewModel.bookSources,
                    bookshelfViewModel: bookshelfViewModel
                )
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }

                ExploreView(
                    allSources: bookSourceViewModel.bookSources,
                    bookshelfViewModel: bookshelfViewModel
                )
                .tabItem {
                    Label("发现", systemImage: "safari")
                }

                SettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gear")
                    }
            }
            .themedTabChrome()
        }
        .task {
            restoreLastReaderIfPossible()
        }
        .fullScreenCover(item: $startupReaderRoute) { route in
            Group {
                if let cachedSession = route.cachedSession {
                    ReaderView(
                        viewModel: cachedSession.viewModel,
                        bookID: cachedSession.bookID,
                        allSources: bookSourceViewModel.bookSources,
                        bookshelfViewModel: bookshelfViewModel
                    )
                } else {
                    BookshelfReaderRouteView(
                        book: route.book,
                        source: route.source,
                        allSources: bookSourceViewModel.bookSources,
                        bookshelfViewModel: bookshelfViewModel,
                        onFailure: { _ in
                            startupReaderRoute = nil
                        }
                    )
                }
            }
        }
    }

    @MainActor
    private func restoreLastReaderIfPossible() {
        guard !hasResolvedStartupReader else { return }
        hasResolvedStartupReader = true

        // 「设置 → 启动 → 启动时打开上次阅读」关掉后，启动就停在书架
        guard restoreLastReaderOnLaunch else { return }

        guard let book = bookshelfViewModel.books
            .filter({ $0.lastReadTime != nil })
            .max(by: { ($0.lastReadTime ?? .distantPast) < ($1.lastReadTime ?? .distantPast) }),
              let source = LocalBookSupport.resolveSource(
                  for: book.sourceUrl,
                  in: bookSourceViewModel.bookSources,
                  requireEnabled: true
              ) else {
            return
        }

        startupReaderRoute = StartupReaderRoute(
            book: book,
            source: source,
            cachedSession: ReaderSessionCache.shared.session(
                bookID: book.bookUrl,
                sourceURL: source.bookSourceUrl
            )
        )
    }
}

private struct StartupReaderRoute: Identifiable {
    let book: BookEntity
    let source: BookSource
    let cachedSession: ReaderSession?

    var id: String { "\(book.bookUrl)|\(source.bookSourceUrl)" }
}

#Preview {
    if let container = try? LegadoModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true) {
        let context = container.mainContext
        ContentView(modelContext: context)
            .modelContainer(container)
    } else {
        Text("预览不可用")
    }
}
