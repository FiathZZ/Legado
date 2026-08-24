import SwiftUI
import SwiftData

struct BookSourceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager

    private let originalURL: String?

    @State private var selectedSection: BookSourceEditorSection = .basic
    @State private var draft: BookSourceEditDraft
    @State private var jsonText: String
    @State private var jsonError: String?
    @State private var alertMessage: String?

    init(sourceEntity: BookSourceEntity? = nil) {
        let initialSource = sourceEntity?.toBookSource() ?? BookSourceEditDraft.blankSource()
        let initialDraft = BookSourceEditDraft(source: initialSource)
        _draft = State(initialValue: initialDraft)
        _jsonText = State(initialValue: BookSourceEditDraft.prettyPrintedJSON(for: initialSource))
        self.originalURL = sourceEntity?.bookSourceUrl
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionPicker
                editorBody
            }
            .padding()
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .navigationTitle(originalURL == nil ? "新建书源" : "编辑书源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("保存") {
                    save()
                }
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: selectedSection) { _, newValue in
            if newValue == .json {
                syncJSONFromDraft()
            }
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BookSourceEditorSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Text(section.title)
                            .font(themeManager.font(.primary, size: 14, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                selectedSection == section
                                    ? themeManager.color(.selectionFill)
                                    : themeManager.color(.secondarySurfaceBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(
                                selectedSection == section
                                    ? themeManager.color(.selectionText)
                                    : themeManager.color(.primaryText)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        switch selectedSection {
        case .basic:
            basicEditor
        case .search:
            searchEditor
        case .explore:
            exploreEditor
        case .info:
            infoEditor
        case .toc:
            tocEditor
        case .content:
            contentEditor
        case .json:
            jsonEditor
        }
    }

    private var basicEditor: some View {
        VStack(spacing: 14) {
            editorCard(title: "基础信息") {
                EditorTextField(title: "书源名称", text: $draft.bookSourceName)
                EditorTextField(title: "书源地址", text: $draft.bookSourceUrl, autocapitalization: .never)
                EditorTextField(title: "分组", text: $draft.bookSourceGroup)
                Picker("书源类型", selection: $draft.bookSourceType) {
                    ForEach(BookSourceTypeOption.allCases, id: \.rawValue) { type in
                        Text(type.title).tag(type.rawValue)
                    }
                }
                Toggle("启用书源", isOn: $draft.enabled)
                Toggle("启用发现", isOn: $draft.enabledExplore)
                EditorTextArea(title: "备注", text: $draft.bookSourceComment)
            }

            editorCard(title: "请求与认证") {
                EditorTextArea(title: "Header", text: $draft.header)
                EditorTextArea(title: "Cookie", text: $draft.cookieJar)
                EditorTextField(title: "并发/限速", text: $draft.concurrentRate)
                EditorTextField(title: "详情页 URL 正则", text: $draft.bookUrlPattern)
                EditorTextField(title: "登录 URL", text: $draft.loginUrl)
                EditorTextArea(title: "loginUi", text: $draft.loginUi)
                EditorTextArea(title: "loginCheckJs", text: $draft.loginCheckJs)
                EditorTextArea(title: "jsLib", text: $draft.jsLib)
                EditorTextArea(title: "coverDecodeJs", text: $draft.coverDecodeJs)
            }
        }
    }

    private var searchEditor: some View {
        editorCard(title: "搜索规则") {
            EditorTextField(title: "searchUrl", text: $draft.searchUrl)
            EditorTextField(title: "bookList", text: $draft.searchBookList)
            EditorTextField(title: "name", text: $draft.searchName)
            EditorTextField(title: "author", text: $draft.searchAuthor)
            EditorTextArea(title: "intro", text: $draft.searchIntro)
            EditorTextField(title: "kind", text: $draft.searchKind)
            EditorTextField(title: "lastChapter", text: $draft.searchLastChapter)
            EditorTextField(title: "updateTime", text: $draft.searchUpdateTime)
            EditorTextField(title: "bookUrl", text: $draft.searchBookUrl)
            EditorTextField(title: "coverUrl", text: $draft.searchCoverUrl)
            EditorTextField(title: "wordCount", text: $draft.searchWordCount)
            EditorTextField(title: "checkKeyWord", text: $draft.searchCheckKeyWord)
        }
    }

    private var exploreEditor: some View {
        editorCard(title: "发现规则") {
            EditorTextField(title: "exploreUrl", text: $draft.exploreUrl)
            EditorTextField(title: "bookList", text: $draft.exploreBookList)
            EditorTextField(title: "name", text: $draft.exploreName)
            EditorTextField(title: "author", text: $draft.exploreAuthor)
            EditorTextArea(title: "intro", text: $draft.exploreIntro)
            EditorTextField(title: "kind", text: $draft.exploreKind)
            EditorTextField(title: "lastChapter", text: $draft.exploreLastChapter)
            EditorTextField(title: "updateTime", text: $draft.exploreUpdateTime)
            EditorTextField(title: "bookUrl", text: $draft.exploreBookUrl)
            EditorTextField(title: "coverUrl", text: $draft.exploreCoverUrl)
            EditorTextField(title: "wordCount", text: $draft.exploreWordCount)
        }
    }

    private var infoEditor: some View {
        editorCard(title: "详情规则") {
            EditorTextArea(title: "init", text: $draft.infoInit)
            EditorTextField(title: "name", text: $draft.infoName)
            EditorTextField(title: "author", text: $draft.infoAuthor)
            EditorTextArea(title: "intro", text: $draft.infoIntro)
            EditorTextField(title: "kind", text: $draft.infoKind)
            EditorTextField(title: "lastChapter", text: $draft.infoLastChapter)
            EditorTextField(title: "updateTime", text: $draft.infoUpdateTime)
            EditorTextField(title: "coverUrl", text: $draft.infoCoverUrl)
            EditorTextField(title: "tocUrl", text: $draft.infoTocUrl)
            EditorTextField(title: "wordCount", text: $draft.infoWordCount)
            EditorTextField(title: "canReName", text: $draft.infoCanReName)
            EditorTextField(title: "downloadUrls", text: $draft.infoDownloadUrls)
        }
    }

    private var tocEditor: some View {
        editorCard(title: "目录规则") {
            EditorTextField(title: "chapterList", text: $draft.tocChapterList)
            EditorTextField(title: "chapterName", text: $draft.tocChapterName)
            EditorTextField(title: "chapterUrl", text: $draft.tocChapterUrl)
            EditorTextField(title: "isVolume", text: $draft.tocIsVolume)
            EditorTextField(title: "isVip", text: $draft.tocIsVip)
            EditorTextField(title: "isPay", text: $draft.tocIsPay)
            EditorTextField(title: "updateTime", text: $draft.tocUpdateTime)
            EditorTextField(title: "nextTocUrl", text: $draft.tocNextTocUrl)
            EditorTextArea(title: "preUpdateJs", text: $draft.tocPreUpdateJs)
            EditorTextArea(title: "formatJs", text: $draft.tocFormatJs)
        }
    }

    private var contentEditor: some View {
        editorCard(title: "内容规则") {
            EditorTextArea(title: "content", text: $draft.contentValue)
            EditorTextField(title: "title", text: $draft.contentTitle)
            EditorTextField(title: "nextContentUrl", text: $draft.contentNextContentUrl)
            EditorTextArea(title: "webJs", text: $draft.contentWebJs)
            EditorTextField(title: "sourceRegex", text: $draft.contentSourceRegex)
            EditorTextArea(title: "replaceRegex", text: $draft.contentReplaceRegex)
            EditorTextField(title: "imageStyle", text: $draft.contentImageStyle)
            EditorTextField(title: "imageDecode", text: $draft.contentImageDecode)
            EditorTextField(title: "payAction", text: $draft.contentPayAction)
        }
    }

    private var jsonEditor: some View {
        editorCard(title: "原始 JSON") {
            TextEditor(text: $jsonText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 420)
                .padding(10)
                .background(themeManager.color(.secondarySurfaceBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let jsonError, !jsonError.isEmpty {
                Text(jsonError)
                    .font(themeManager.font(.primary, size: 13))
                    .foregroundStyle(themeManager.color(.destructive))
            }

            Button("从当前表单重新生成 JSON") {
                syncJSONFromDraft()
            }
            .buttonStyle(.bordered)
        }
    }

    private func editorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(themeManager.font(.primary, size: 16, weight: .semibold))
                .foregroundStyle(themeManager.color(.primaryText))

            content()
        }
        .padding()
        .background(themeManager.color(.surfaceBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeManager.color(.divider).opacity(0.55), lineWidth: 1)
        )
    }

    private var canDebugCurrentState: Bool {
        if selectedSection == .json {
            return !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return draft.buildSource() != nil
    }

    private func syncJSONFromDraft() {
        if let source = draft.buildSource() {
            jsonText = BookSourceEditDraft.prettyPrintedJSON(for: source)
        }
        jsonError = nil
    }

    private func parseJSONDraft() -> BookSource? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            jsonError = "JSON 内容不能为空。"
            return nil
        }

        do {
            let data = Data(trimmed.utf8)
            let source = try JSONDecoder().decode(BookSource.self, from: data)
            jsonError = nil
            return source
        } catch {
            jsonError = "JSON 解析失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func save() {
        let source: BookSource?
        if selectedSection == .json {
            source = parseJSONDraft()
        } else {
            source = draft.buildSource()
        }

        guard var source else { return }

        let trimmedURL = source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            alertMessage = "书源地址不能为空。"
            return
        }

        source.bookSourceUrl = trimmedURL
        BookSourceRepository.upsert(source: source, replacing: originalURL, in: modelContext)
        dismiss()
    }

    private func debugSourceFromCurrentState() -> BookSource? {
        if selectedSection == .json {
            return parseJSONDraft()
        }
        return draft.buildSource()
    }
}

private enum BookSourceEditorSection: String, CaseIterable, Identifiable {
    case basic
    case search
    case explore
    case info
    case toc
    case content
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return "基本"
        case .search: return "搜索"
        case .explore: return "发现"
        case .info: return "详情"
        case .toc: return "目录"
        case .content: return "内容"
        case .json: return "JSON"
        }
    }
}

private enum BookSourceTypeOption: Int, CaseIterable {
    case text = 0
    case audio = 1
    case image = 2

    var title: String {
        switch self {
        case .text: return "文本"
        case .audio: return "音频"
        case .image: return "图片"
        }
    }
}

private struct DebugSourceRoute: Identifiable, Hashable {
    let source: BookSource
    var id: String { source.bookSourceUrl + "#" + source.bookSourceName }

    static func == (lhs: DebugSourceRoute, rhs: DebugSourceRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct EditorTextField: View {
    let title: String
    @Binding var text: String
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, axis: .vertical)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct EditorTextArea: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .frame(minHeight: 110)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .autocorrectionDisabled()
        }
    }
}

private struct BookSourceEditDraft {
    var bookSourceName = ""
    var bookSourceUrl = ""
    var bookSourceGroup = ""
    var bookSourceType = 0
    var enabled = true
    var enabledExplore = true
    var bookSourceComment = ""
    var header = ""
    var cookieJar = ""
    var loginUrl = ""
    var loginUi = ""
    var loginCheckJs = ""
    var concurrentRate = ""
    var jsLib = ""
    var bookUrlPattern = ""
    var coverDecodeJs = ""
    var lastUpdateTime: Int64 = 0

    var searchUrl = ""
    var searchBookList = ""
    var searchName = ""
    var searchAuthor = ""
    var searchIntro = ""
    var searchKind = ""
    var searchLastChapter = ""
    var searchUpdateTime = ""
    var searchBookUrl = ""
    var searchCoverUrl = ""
    var searchWordCount = ""
    var searchCheckKeyWord = ""

    var exploreUrl = ""
    var exploreBookList = ""
    var exploreName = ""
    var exploreAuthor = ""
    var exploreIntro = ""
    var exploreKind = ""
    var exploreLastChapter = ""
    var exploreUpdateTime = ""
    var exploreBookUrl = ""
    var exploreCoverUrl = ""
    var exploreWordCount = ""

    var infoInit = ""
    var infoName = ""
    var infoAuthor = ""
    var infoIntro = ""
    var infoKind = ""
    var infoLastChapter = ""
    var infoUpdateTime = ""
    var infoCoverUrl = ""
    var infoTocUrl = ""
    var infoWordCount = ""
    var infoCanReName = ""
    var infoDownloadUrls = ""

    var tocChapterList = ""
    var tocChapterName = ""
    var tocChapterUrl = ""
    var tocIsVolume = ""
    var tocIsVip = ""
    var tocIsPay = ""
    var tocUpdateTime = ""
    var tocNextTocUrl = ""
    var tocPreUpdateJs = ""
    var tocFormatJs = ""

    var contentValue = ""
    var contentTitle = ""
    var contentNextContentUrl = ""
    var contentWebJs = ""
    var contentSourceRegex = ""
    var contentReplaceRegex = ""
    var contentImageStyle = ""
    var contentImageDecode = ""
    var contentPayAction = ""

    init(source: BookSource) {
        bookSourceName = source.bookSourceName
        bookSourceUrl = source.bookSourceUrl
        bookSourceGroup = source.bookSourceGroup ?? ""
        bookSourceType = source.bookSourceType
        enabled = source.enabled
        enabledExplore = source.enabledExplore
        bookSourceComment = source.bookSourceComment ?? ""
        header = source.header ?? ""
        cookieJar = source.cookieJar ?? ""
        loginUrl = source.loginUrl ?? ""
        loginUi = source.loginUi ?? ""
        loginCheckJs = source.loginCheckJs ?? ""
        concurrentRate = source.concurrentRate ?? ""
        jsLib = source.jsLib ?? ""
        bookUrlPattern = source.bookUrlPattern ?? ""
        coverDecodeJs = source.coverDecodeJs ?? ""
        lastUpdateTime = source.lastUpdateTime

        searchUrl = source.searchUrl ?? ""
        searchBookList = source.ruleSearch?.bookList ?? ""
        searchName = source.ruleSearch?.name ?? ""
        searchAuthor = source.ruleSearch?.author ?? ""
        searchIntro = source.ruleSearch?.intro ?? ""
        searchKind = source.ruleSearch?.kind ?? ""
        searchLastChapter = source.ruleSearch?.lastChapter ?? ""
        searchUpdateTime = source.ruleSearch?.updateTime ?? ""
        searchBookUrl = source.ruleSearch?.bookUrl ?? ""
        searchCoverUrl = source.ruleSearch?.coverUrl ?? ""
        searchWordCount = source.ruleSearch?.wordCount ?? ""
        searchCheckKeyWord = source.ruleSearch?.checkKeyWord ?? ""

        exploreUrl = source.exploreUrl ?? ""
        exploreBookList = source.ruleExplore?.bookList ?? ""
        exploreName = source.ruleExplore?.name ?? ""
        exploreAuthor = source.ruleExplore?.author ?? ""
        exploreIntro = source.ruleExplore?.intro ?? ""
        exploreKind = source.ruleExplore?.kind ?? ""
        exploreLastChapter = source.ruleExplore?.lastChapter ?? ""
        exploreUpdateTime = source.ruleExplore?.updateTime ?? ""
        exploreBookUrl = source.ruleExplore?.bookUrl ?? ""
        exploreCoverUrl = source.ruleExplore?.coverUrl ?? ""
        exploreWordCount = source.ruleExplore?.wordCount ?? ""

        infoInit = source.ruleBookInfo?.`init` ?? ""
        infoName = source.ruleBookInfo?.name ?? ""
        infoAuthor = source.ruleBookInfo?.author ?? ""
        infoIntro = source.ruleBookInfo?.intro ?? ""
        infoKind = source.ruleBookInfo?.kind ?? ""
        infoLastChapter = source.ruleBookInfo?.lastChapter ?? ""
        infoUpdateTime = source.ruleBookInfo?.updateTime ?? ""
        infoCoverUrl = source.ruleBookInfo?.coverUrl ?? ""
        infoTocUrl = source.ruleBookInfo?.tocUrl ?? ""
        infoWordCount = source.ruleBookInfo?.wordCount ?? ""
        infoCanReName = source.ruleBookInfo?.canReName ?? ""
        infoDownloadUrls = source.ruleBookInfo?.downloadUrls ?? ""

        tocChapterList = source.ruleToc?.chapterList ?? ""
        tocChapterName = source.ruleToc?.chapterName ?? ""
        tocChapterUrl = source.ruleToc?.chapterUrl ?? ""
        tocIsVolume = source.ruleToc?.isVolume ?? ""
        tocIsVip = source.ruleToc?.isVip ?? ""
        tocIsPay = source.ruleToc?.isPay ?? ""
        tocUpdateTime = source.ruleToc?.updateTime ?? ""
        tocNextTocUrl = source.ruleToc?.nextTocUrl ?? ""
        tocPreUpdateJs = source.ruleToc?.preUpdateJs ?? ""
        tocFormatJs = source.ruleToc?.formatJs ?? ""

        contentValue = source.ruleContent?.content ?? ""
        contentTitle = source.ruleContent?.title ?? ""
        contentNextContentUrl = source.ruleContent?.nextContentUrl ?? ""
        contentWebJs = source.ruleContent?.webJs ?? ""
        contentSourceRegex = source.ruleContent?.sourceRegex ?? ""
        contentReplaceRegex = source.ruleContent?.replaceRegex ?? ""
        contentImageStyle = source.ruleContent?.imageStyle ?? ""
        contentImageDecode = source.ruleContent?.imageDecode ?? ""
        contentPayAction = source.ruleContent?.payAction ?? ""
    }

    static func blankSource() -> BookSource {
        BookSource(bookSourceName: "", bookSourceUrl: "")
    }

    func buildSource() -> BookSource? {
        let trimmedURL = bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        return BookSource(
            bookSourceName: normalize(bookSourceName) ?? "未命名书源",
            bookSourceUrl: trimmedURL,
            bookSourceGroup: normalize(bookSourceGroup),
            bookSourceType: bookSourceType,
            bookUrlPattern: normalize(bookUrlPattern),
            enabled: enabled,
            enabledExplore: enabledExplore,
            bookSourceComment: normalize(bookSourceComment),
            loginUrl: normalize(loginUrl),
            loginUi: normalize(loginUi),
            loginCheckJs: normalize(loginCheckJs),
            coverDecodeJs: normalize(coverDecodeJs),
            header: normalize(header),
            cookieJar: normalize(cookieJar),
            concurrentRate: normalize(concurrentRate),
            jsLib: normalize(jsLib),
            lastUpdateTime: lastUpdateTime,
            searchUrl: normalize(searchUrl),
            ruleSearch: buildSearchRule(),
            exploreUrl: normalize(exploreUrl),
            ruleExplore: buildExploreRule(),
            ruleBookInfo: buildInfoRule(),
            ruleToc: buildTocRule(),
            ruleContent: buildContentRule()
        )
    }

    static func prettyPrintedJSON(for source: BookSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(source)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildSearchRule() -> SearchRule? {
        let rule = SearchRule(
            bookList: normalize(searchBookList),
            name: normalize(searchName),
            author: normalize(searchAuthor),
            intro: normalize(searchIntro),
            kind: normalize(searchKind),
            lastChapter: normalize(searchLastChapter),
            updateTime: normalize(searchUpdateTime),
            bookUrl: normalize(searchBookUrl),
            coverUrl: normalize(searchCoverUrl),
            wordCount: normalize(searchWordCount),
            checkKeyWord: normalize(searchCheckKeyWord)
        )
        return hasAnyValue([
            searchBookList, searchName, searchAuthor, searchIntro, searchKind, searchLastChapter,
            searchUpdateTime, searchBookUrl, searchCoverUrl, searchWordCount, searchCheckKeyWord
        ]) ? rule : nil
    }

    private func buildExploreRule() -> ExploreRule? {
        let rule = ExploreRule(
            bookList: normalize(exploreBookList),
            name: normalize(exploreName),
            author: normalize(exploreAuthor),
            intro: normalize(exploreIntro),
            kind: normalize(exploreKind),
            lastChapter: normalize(exploreLastChapter),
            updateTime: normalize(exploreUpdateTime),
            bookUrl: normalize(exploreBookUrl),
            coverUrl: normalize(exploreCoverUrl),
            wordCount: normalize(exploreWordCount)
        )
        return hasAnyValue([
            exploreBookList, exploreName, exploreAuthor, exploreIntro, exploreKind,
            exploreLastChapter, exploreUpdateTime, exploreBookUrl, exploreCoverUrl, exploreWordCount
        ]) ? rule : nil
    }

    private func buildInfoRule() -> BookInfoRule? {
        let rule = BookInfoRule(
            init: normalize(infoInit),
            name: normalize(infoName),
            author: normalize(infoAuthor),
            intro: normalize(infoIntro),
            kind: normalize(infoKind),
            lastChapter: normalize(infoLastChapter),
            updateTime: normalize(infoUpdateTime),
            coverUrl: normalize(infoCoverUrl),
            tocUrl: normalize(infoTocUrl),
            wordCount: normalize(infoWordCount),
            canReName: normalize(infoCanReName),
            downloadUrls: normalize(infoDownloadUrls)
        )
        return hasAnyValue([
            infoInit, infoName, infoAuthor, infoIntro, infoKind, infoLastChapter,
            infoUpdateTime, infoCoverUrl, infoTocUrl, infoWordCount, infoCanReName, infoDownloadUrls
        ]) ? rule : nil
    }

    private func buildTocRule() -> TocRule? {
        let rule = TocRule(
            chapterList: normalize(tocChapterList),
            chapterName: normalize(tocChapterName),
            chapterUrl: normalize(tocChapterUrl),
            isVolume: normalize(tocIsVolume),
            isVip: normalize(tocIsVip),
            isPay: normalize(tocIsPay),
            updateTime: normalize(tocUpdateTime),
            nextTocUrl: normalize(tocNextTocUrl),
            preUpdateJs: normalize(tocPreUpdateJs),
            formatJs: normalize(tocFormatJs)
        )
        return hasAnyValue([
            tocChapterList, tocChapterName, tocChapterUrl, tocIsVolume, tocIsVip,
            tocIsPay, tocUpdateTime, tocNextTocUrl, tocPreUpdateJs, tocFormatJs
        ]) ? rule : nil
    }

    private func buildContentRule() -> ContentRule? {
        let rule = ContentRule(
            content: normalize(contentValue),
            title: normalize(contentTitle),
            nextContentUrl: normalize(contentNextContentUrl),
            webJs: normalize(contentWebJs),
            sourceRegex: normalize(contentSourceRegex),
            replaceRegex: normalize(contentReplaceRegex),
            imageStyle: normalize(contentImageStyle),
            imageDecode: normalize(contentImageDecode),
            payAction: normalize(contentPayAction)
        )
        return hasAnyValue([
            contentValue, contentTitle, contentNextContentUrl, contentWebJs,
            contentSourceRegex, contentReplaceRegex, contentImageStyle,
            contentImageDecode, contentPayAction
        ]) ? rule : nil
    }

    private func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func hasAnyValue(_ values: [String]) -> Bool {
        values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
