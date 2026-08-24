import SwiftUI

struct BookSourceDebugView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel: BookSourceDebugViewModel

    init(source: BookSource) {
        _viewModel = StateObject(wrappedValue: BookSourceDebugViewModel(source: source))
    }

    var body: some View {
        List {
            sourceSection
            searchSection
            if !viewModel.searchResults.isEmpty {
                searchResultSection
            }
            detailSection
            chapterSection
            contentSection
            logSection
        }
        .navigationTitle("书源调试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
    }

    private var sourceSection: some View {
        Section("书源信息") {
            LabeledContent("名称", value: viewModel.source.bookSourceName)
            LabeledContent("地址", value: viewModel.source.bookSourceUrl)
            LabeledContent("启用", value: viewModel.source.enabled ? "是" : "否")
            if let searchUrl = viewModel.source.searchUrl, !searchUrl.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("searchUrl")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                    Text(searchUrl)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            if let bookUrlRule = viewModel.source.ruleSearch?.bookUrl, !bookUrlRule.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ruleSearch.bookUrl")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                    Text(bookUrlRule)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            if let tocUrlRule = viewModel.source.ruleBookInfo?.tocUrl, !tocUrlRule.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ruleBookInfo.tocUrl")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                    Text(tocUrlRule)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            if let chapterUrlRule = viewModel.source.ruleToc?.chapterUrl, !chapterUrlRule.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ruleToc.chapterUrl")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                    Text(chapterUrlRule)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var searchSection: some View {
        Section("搜索调试") {
            TextField("输入关键字，例如：凡人修仙传", text: $viewModel.keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await viewModel.search() }
            } label: {
                if viewModel.isWorking && viewModel.currentAction == "搜索" {
                    Label("搜索中...", systemImage: "hourglass")
                } else {
                    Label("开始搜索", systemImage: "magnifyingglass")
                }
            }
            .disabled(viewModel.isWorking)
        }
    }

    private var searchResultSection: some View {
        Section("搜索结果") {
            ForEach(viewModel.searchResults) { book in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        CoverImageView(
                            url: book.coverUrl,
                            displaySize: CGSize(width: 48, height: 64),
                            source: viewModel.source,
                            bookUrl: book.bookUrl,
                            bookName: book.name,
                            bookAuthor: book.author
                        )
                            .frame(width: 48, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.name.isEmpty ? "未解析书名" : book.name)
                                .font(.headline)
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.subheadline)
                                    .foregroundStyle(themeManager.color(.secondaryText))
                            }
                            Text(book.bookUrl.isEmpty ? "bookUrl 为空" : book.bookUrl)
                                .font(.caption2)
                                .foregroundStyle(book.bookUrl.isEmpty ? themeManager.color(.destructive) : themeManager.color(.secondaryText))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }

                        Spacer()
                    }

                    HStack {
                        Button(viewModel.selectedBook?.bookUrl == book.bookUrl ? "已选中" : "选中") {
                            viewModel.select(book: book)
                        }
                        .buttonStyle(.bordered)

                        Button("解析详情") {
                            viewModel.select(book: book)
                            Task { await viewModel.loadDetail() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isWorking)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var detailSection: some View {
        Section("详情调试") {
            if let book = viewModel.selectedBook {
                LabeledContent("当前书籍", value: book.name.isEmpty ? "未命名结果" : book.name)
                LabeledContent("bookUrl", value: book.bookUrl.isEmpty ? "空" : book.bookUrl)
                    .textSelection(.enabled)
            } else {
                Text("请先搜索并选择一本书")
                    .foregroundStyle(themeManager.color(.secondaryText))
            }

            Button {
                Task { await viewModel.loadDetail() }
            } label: {
                if viewModel.isWorking && viewModel.currentAction == "详情" {
                    Label("解析详情中...", systemImage: "hourglass")
                } else {
                    Label("解析详情", systemImage: "doc.text.magnifyingglass")
                }
            }
            .disabled(viewModel.selectedBook == nil || viewModel.isWorking)

            if let detail = viewModel.detail {
                if let cover = detail.coverUrl, !cover.isEmpty {
                    HStack {
                        Spacer()
                        CoverImageView(
                            url: cover,
                            displaySize: CGSize(width: 90, height: 120),
                            source: viewModel.source,
                            bookUrl: detail.bookUrl,
                            bookName: detail.name,
                            bookAuthor: detail.author
                        )
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                }
                LabeledContent("书名", value: detail.name.isEmpty ? "空" : detail.name)
                LabeledContent("作者", value: detail.author.isEmpty ? "空" : detail.author)
                LabeledContent("分类", value: detail.kind ?? "空")
                LabeledContent("最新章节", value: detail.lastChapter ?? "空")
                LabeledContent("tocUrl", value: detail.tocUrl ?? "空")
                    .textSelection(.enabled)

                if let intro = detail.intro, !intro.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介")
                            .font(.caption)
                            .foregroundStyle(themeManager.color(.secondaryText))
                        Text(intro)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }

                Button {
                    Task { await viewModel.loadToc() }
                } label: {
                    if viewModel.isWorking && viewModel.currentAction == "目录" {
                        Label("解析目录中...", systemImage: "hourglass")
                    } else {
                        Label("解析目录", systemImage: "list.bullet.rectangle")
                    }
                }
                .disabled(viewModel.isWorking)
            }
        }
    }

    private var chapterSection: some View {
        Section("目录调试") {
            if viewModel.chapters.isEmpty {
                Text("请先解析目录")
                    .foregroundStyle(themeManager.color(.secondaryText))
            } else {
                Text("共 \(viewModel.chapters.count) 章，以下展示前 20 章")
                    .font(.footnote)
                    .foregroundStyle(themeManager.color(.secondaryText))

                ForEach(Array(viewModel.chapters.prefix(20)), id: \.index) { chapter in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chapter.title.isEmpty ? "未解析章节名" : chapter.title)
                            .font(.body)
                        Text(chapter.url.isEmpty ? "url 为空" : chapter.url)
                            .font(.caption2)
                            .foregroundStyle(chapter.url.isEmpty ? themeManager.color(.destructive) : themeManager.color(.secondaryText))
                            .textSelection(.enabled)
                            .lineLimit(2)

                        HStack {
                            Button(viewModel.selectedChapter?.url == chapter.url ? "已选中" : "选中") {
                                viewModel.select(chapter: chapter)
                            }
                            .buttonStyle(.bordered)

                            Button("解析正文") {
                                viewModel.select(chapter: chapter)
                                Task { await viewModel.loadContent() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isWorking)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var contentSection: some View {
        Section("正文调试") {
            if let content = viewModel.chapterContent {
                LabeledContent("标题", value: content.title.isEmpty ? "空" : content.title)
                Text(content.content.isEmpty ? "正文为空" : content.content)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .lineLimit(12)
            } else {
                Text("请先选择章节并解析正文")
                    .foregroundStyle(themeManager.color(.secondaryText))
            }
        }
    }

    private var logSection: some View {
        Section("调试记录") {
            Text("更完整的解析细节请查看 Xcode 控制台，筛选关键字 `[LegadoParser]`。")
                .font(.footnote)
                .foregroundStyle(themeManager.color(.secondaryText))

            if viewModel.messages.isEmpty {
                Text("还没有操作记录")
                    .foregroundStyle(themeManager.color(.secondaryText))
            } else {
                ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

#Preview {
    let source = BookSource(
        bookSourceName: "示例书源",
        bookSourceUrl: "https://example.com",
        searchUrl: "/search?q={{key}}",
        ruleSearch: SearchRule(bookList: "$.data", name: "$.name", bookUrl: "/detail/{{$.id}}"),
        ruleBookInfo: BookInfoRule(name: "$.name", tocUrl: "/toc/{{$.id}}"),
        ruleToc: TocRule(chapterList: "$.chapters", chapterName: "$.title", chapterUrl: "/chapter/{{$.id}}")
    )

    NavigationStack {
        BookSourceDebugView(source: source)
    }
}
