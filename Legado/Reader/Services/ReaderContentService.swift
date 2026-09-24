import Combine
import Foundation
import SwiftData

enum ReaderContentRuleCacheVersion {
    private static let key = "Legado.ReaderContentRuleRevision"

    static var current: Int {
        UserDefaults.standard.integer(forKey: key)
    }

    static func notifyRulesChanged() {
        UserDefaults.standard.set(current + 1, forKey: key)
        NotificationCenter.default.post(name: .replaceRulesDidChange, object: nil)
    }
}

@MainActor
final class ReaderContentService: ObservableObject {
    private static let automaticPrefetchCount = 3
    @Published private(set) var cachedChapters: [Int: CachedChapter] = [:]
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var downloadProgress: Double? = nil
    @Published private(set) var isEntireBookCached: Bool

    private var chapters: [BookChapter]
    private let source: BookSource
    private let bookName: String
    private let chapterCacheKey: String
    private var currentIndex: Int
    private let modelContext: ModelContext?
    private var cachedContentReplaceRules: [ReplaceRule]?
    private var isOfflineBook: Bool
    private var chapterLoadWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var prefetchTask: Task<Void, Never>?
    private var prefetchingIndices = Set<Int>()
    private var prefetchAnchor: Int?

    init(
        chapters: [BookChapter],
        source: BookSource,
        bookName: String,
        chapterCacheKey: String,
        initialIndex: Int,
        modelContext: ModelContext?
    ) {
        self.chapters = chapters
        self.source = source
        self.bookName = bookName
        self.chapterCacheKey = chapterCacheKey
        self.currentIndex = min(max(initialIndex, 0), max(chapters.count - 1, 0))
        self.modelContext = modelContext
        // The manifest opts this book into offline-only reading. Completeness controls the UI
        // checkmark separately; a damaged package must not fall back to network.
        self.isOfflineBook = ChapterCacheStore.offlineBookManifest(bookKey: chapterCacheKey) != nil
        self.isEntireBookCached = Self.hasPersistedEntireBook(
            chapterCount: chapters.count,
            startingAt: self.currentIndex,
            chapterCacheKey: chapterCacheKey
        )
        if chapters.indices.contains(initialIndex),
           let persistedContent = ChapterCacheStore.content(bookKey: chapterCacheKey, index: initialIndex),
           !persistedContent.isEmpty {
            // The native reader needs its first snapshot during controller creation. Hydrating the
            // one active chapter here avoids presenting an empty controller before the async
            // loader has a chance to read the same persisted file.
            let processedContent = processPersistedContentIfNeeded(persistedContent, at: initialIndex)
            cachedChapters[initialIndex] = CachedChapter(
                chapter: chapters[initialIndex],
                content: processedContent
            )
        }
        observeReplaceRuleChanges()
    }

    func cachedChapter(at index: Int) -> CachedChapter? {
        cachedChapters[index]
    }

    /// Replaces a cache-only fallback directory once the complete TOC is available.
    /// Chapter loading uses this service snapshot, so updating only the view model is insufficient.
    func updateChapters(_ chapters: [BookChapter]) {
        guard !chapters.isEmpty else { return }
        self.chapters = chapters
        currentIndex = min(currentIndex, chapters.count - 1)
        cachedChapters = cachedChapters.reduce(into: [:]) { result, entry in
            guard chapters.indices.contains(entry.key) else { return }
            var cached = entry.value
            cached.chapter = chapters[entry.key]
            result[entry.key] = cached
        }
        refreshCacheStatus(from: currentIndex)
    }

    func loadCurrentChapter(at index: Int) async {
        guard chapters.indices.contains(index) else { return }
        currentIndex = index
        await loadChapter(at: index)
        refreshCacheStatus(from: index)
        if cachedChapters[index]?.content != nil {
            scheduleAutomaticPrefetch(after: index)
        }
    }

    func loadChapter(at index: Int) async {
        guard index >= 0, index < chapters.count else { return }
        if let cached = cachedChapters[index], cached.content != nil { return }
        if cachedChapters[index]?.isLoading == true {
            await withCheckedContinuation { continuation in
                chapterLoadWaiters[index, default: []].append(continuation)
            }
            return
        }

        let chapter = chapters[index]
        if let persistedContent = await persistedContent(at: index), !persistedContent.isEmpty {
            let processedContent = processPersistedContentIfNeeded(persistedContent, at: index)
            cachedChapters[index] = CachedChapter(chapter: chapter, content: processedContent)
            return
        }

        // A completed offline manifest is an explicit no-network contract. A damaged cache
        // must report its problem instead of silently consuming mobile data to repair itself.
        if isOfflineBook {
            cachedChapters[index] = CachedChapter(chapter: chapter, error: "离线缓存不完整，请重新缓存全书")
            return
        }

        cachedChapters[index] = CachedChapter(chapter: chapter, isLoading: true)
        defer {
            let waiters = chapterLoadWaiters.removeValue(forKey: index) ?? []
            waiters.forEach { $0.resume() }
        }

        do {
            let cachedChapter = try await fetchChapterContent(at: index)
            cachedChapters[index] = cachedChapter
            if let content = cachedChapter.content {
                try? await ChapterCacheStore.saveOnUtilityQueue(
                    bookKey: chapterCacheKey,
                    index: index,
                    content: content,
                    chapter: cachedChapter.chapter,
                    contentRuleRevision: contentRuleRevision
                )
            }
        } catch {
            cachedChapters[index] = CachedChapter(chapter: chapter, error: error.localizedDescription)
        }
    }

    /// Keeps a small forward window warm without requiring the user to press the download action.
    /// The task is cancelled and restarted as the reader advances.
    private func scheduleAutomaticPrefetch(after index: Int) {
        guard !isOfflineBook, !isDownloading else { return }
        guard prefetchAnchor != index else { return }
        let indexes = Self.automaticPrefetchIndices(
            after: index,
            chapterCount: chapters.count,
            count: Self.automaticPrefetchCount
        )
        guard !indexes.isEmpty else { return }
        prefetchAnchor = index
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for prefetchIndex in indexes {
                guard !Task.isCancelled else { return }
                guard !self.prefetchingIndices.contains(prefetchIndex) else { continue }
                self.prefetchingIndices.insert(prefetchIndex)
                await self.cacheChapterForDownload(at: prefetchIndex)
                self.prefetchingIndices.remove(prefetchIndex)
                await Task.yield()
            }
            self.refreshCacheStatus(from: self.currentIndex)
        }
    }

    func refreshCacheStatus(from index: Int) {
        guard chapters.indices.contains(index) else { return }
        currentIndex = index
        isEntireBookCached = Self.hasPersistedEntireBook(
            chapterCount: chapters.count,
            startingAt: index,
            chapterCacheKey: chapterCacheKey
        )
    }

    func downloadChapters(from currentIndex: Int, count: Int?) async {
        guard !isDownloading,
              !chapters.isEmpty,
              currentIndex >= 0,
              currentIndex < chapters.count else {
            return
        }

        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadProgress = nil
        }

        let start = currentIndex
        let end = count == nil ? chapters.count - 1 : min(start + count! - 1, chapters.count - 1)
        let indexes = (start...end).filter { !hasCachedChapter(at: $0) }
        let total = indexes.count
        guard total > 0 else {
            refreshCacheStatus(from: currentIndex)
            return
        }
        for (offset, index) in indexes.enumerated() {
            if Task.isCancelled { break }
            await cacheChapterForDownload(at: index)
            let completed = indexes[..<(offset + 1)].filter { hasCachedChapter(at: $0) }.count
            publishDownloadProgress(completed: completed, total: total)
            await Task.yield()
        }
        refreshCacheStatus(from: currentIndex)

    }

    /// Caches from the current reading chapter through the end of the book. Chapters before the
    /// current position are intentionally excluded from the offline package.
    func downloadEntireBook(from index: Int) async {
        guard !isDownloading, chapters.indices.contains(index) else { return }

        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAnchor = nil
        isDownloading = true
        downloadProgress = 0
        let start = index
        let indexes = Array(start..<chapters.count).filter { !hasCachedChapter(at: $0) }
        let total = indexes.count
        for (offset, index) in indexes.enumerated() {
            if Task.isCancelled { break }
            await cacheChapterForDownload(at: index)
            let completed = indexes[..<(offset + 1)].filter { hasCachedChapter(at: $0) }.count
            publishDownloadProgress(completed: completed, total: total)
            await Task.yield()
        }

        let chapterCount = chapters.count
        let cacheKey = chapterCacheKey
        let manifestChapters = Array(chapters[start...])
        let cacheStart = start
        let completed = await Task.detached(priority: .utility) {
            Self.hasPersistedEntireBook(
                chapterCount: chapterCount,
                startingAt: cacheStart,
                chapterCacheKey: cacheKey
            )
        }.value
        if completed {
            do {
                try ChapterCacheStore.saveOfflineBookManifest(bookKey: cacheKey, chapters: manifestChapters)
                isOfflineBook = ChapterCacheStore.isOfflineBookComplete(bookKey: cacheKey)
            } catch {
                isOfflineBook = false
            }
        }
        refreshCacheStatus(from: currentIndex)
        isDownloading = false
        downloadProgress = nil
    }

    func downloadOptions(for currentIndex: Int) -> [(label: String, count: Int?)] {
        Self.makeDownloadOptions(totalChapterCount: chapters.count, currentIndex: currentIndex)
    }

    func searchCachedChapters(keyword: String) -> [BookSearchResult] {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return [] }

        return ChapterCacheStore.cachedChapterContents(bookKey: chapterCacheKey).compactMap { entry in
            guard let matchRange = entry.content.range(
                of: trimmedKeyword,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else {
                return nil
            }

            let chapterName = chapters[safe: entry.index]?.title ?? "第\(entry.index + 1)章"
            let snippet = Self.makeContextSnippet(in: entry.content, around: matchRange)
            return BookSearchResult(
                chapterIndex: entry.index,
                chapterName: chapterName,
                snippet: snippet
            )
        }
    }

    func makeReadAloudPayload(for index: Int, startingAt startOffset: Int? = nil) async -> ReadAloudPayload? {
        await loadChapter(at: index)
        guard index >= 0, index < chapters.count,
              let content = cachedChapters[index]?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return nil
        }

        let chapterTitle = chapters[index].title
        let safeStartOffset = min(max(startOffset ?? 0, 0), content.utf16.count)
        let speechText: String
        if safeStartOffset == 0 {
            speechText = "\(chapterTitle)\n\(content)"
        } else {
            speechText = substring(fromUTF16Offset: safeStartOffset, in: content)
        }
        guard !speechText.isEmpty else { return nil }
        return ReadAloudPayload(chapterTitle: chapterTitle, text: speechText)
    }

    func clearChapterCache() {
        prefetchTask?.cancel()
        prefetchAnchor = nil
        ChapterCacheStore.clear(bookKey: chapterCacheKey)
        cachedChapters = [:]
        isOfflineBook = false
        isEntireBookCached = false
    }

    /// Fetches and persists a chapter for a download without publishing it to the reader's
    /// in-memory chapter map. Publishing hundreds of entries causes the native reader bridge to
    /// re-render while the user is scrolling.
    private func cacheChapterForDownload(at index: Int) async {
        guard chapters.indices.contains(index) else { return }

        if hasCachedChapter(at: index) {
            return
        }

        if let cachedContent = cachedChapters[index]?.content, !cachedContent.isEmpty {
            try? await ChapterCacheStore.saveOnUtilityQueue(
                bookKey: chapterCacheKey,
                index: index,
                content: cachedContent,
                chapter: chapters[index],
                contentRuleRevision: contentRuleRevision
            )
            return
        }

        guard let content = try? await fetchChapterContent(at: index).content,
              !content.isEmpty else {
            return
        }
        try? await ChapterCacheStore.saveOnUtilityQueue(
            bookKey: chapterCacheKey,
            index: index,
            content: content,
            chapter: chapters[index],
            contentRuleRevision: contentRuleRevision
        )
    }

    private func hasCachedChapter(at index: Int) -> Bool {
        return ChapterCacheStore.hasNonEmptyContent(bookKey: chapterCacheKey, index: index)
    }

    private func fetchChapterContent(at index: Int) async throws -> CachedChapter {
        let chapter = chapters[index]
        let nextChapterURL = chapters.dropFirst(index + 1).first?.url
        let source = source
        let replaceRules = replaceRules(for: .content)

        // Web rule execution, HTML cleanup and regex replacement are CPU-heavy for large
        // chapters. They previously resumed on this service's main actor, making both reader
        // startup and full-book caching contend with scrolling and touch handling.
        let payload = try await Task.detached(priority: .userInitiated) {
            let webBook = WebBook(bookSource: source)
            let result = try await webBook.getContent(
                chapter: chapter,
                nextChapterUrl: nextChapterURL,
                variables: chapter.variables
            )
            let content = Self.processContent(
                result.content,
                source: source,
                replaceRules: replaceRules
            )
            return ReaderChapterContentPayload(
                content: content,
                mediaURLs: result.mediaURLs,
                contentType: result.contentType
            )
        }.value

        return CachedChapter(
            chapter: chapter,
            content: payload.content,
            mediaURLs: payload.mediaURLs,
            contentType: payload.contentType
        )
    }

    private func persistedContent(at index: Int) async -> String? {
        let cacheKey = chapterCacheKey
        return await Task.detached(priority: .utility) {
            ChapterCacheStore.content(bookKey: cacheKey, index: index)
        }.value
    }

    private func publishDownloadProgress(completed: Int, total: Int) {
        guard total > 0 else { return }
        let interval = max(1, total / 100)
        guard completed == 1 || completed == total || completed.isMultiple(of: interval) else {
            return
        }
        downloadProgress = Double(completed) / Double(total)
    }

    nonisolated private static func processContent(
        _ content: String,
        source: BookSource,
        replaceRules: [ReplaceRule]
    ) -> String {
        let formattedContent = normalizeAndFormatContent(content)
        let withoutBrowserModeNotice = stripBrowserReadingModeNotice(formattedContent)
        let filteredContent = applyContentFilter(withoutBrowserModeNotice, source: source)
        return applyGlobalReplaceRules(filteredContent, source: source, rules: replaceRules)
    }

    nonisolated private static func normalizeAndFormatContent(_ content: String) -> String {
        let normalized = content
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return HtmlFormatter.format(normalized)
    }

    nonisolated private static func applyContentFilter(_ content: String, source: BookSource) -> String {
        var result = content
        if let sourceRegex = source.ruleContent?.sourceRegex, !sourceRegex.isEmpty,
           let regex = try? NSRegularExpression(pattern: sourceRegex) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        if let replaceRegex = source.ruleContent?.replaceRegex, !replaceRegex.isEmpty {
            for rule in replaceRegex.components(separatedBy: "\n") {
                let parts = rule.components(separatedBy: "##")
                let pattern = parts[0]
                let replacement = parts.count > 1 ? parts[1] : ""
                if !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
                }
            }
        }

        return result
    }

    nonisolated private static func applyGlobalReplaceRules(
        _ content: String,
        source: BookSource,
        rules: [ReplaceRule]
    ) -> String {
        var result = content
        for rule in rules {
            result = applyReplaceRule(result, rule: rule, source: source)
        }
        return result
    }

    /// Persisted chapter files predate the current replacement-rule configuration. Apply the
    /// current content rules again when reopening them so rule changes take effect without a
    /// network re-fetch or deleting an offline cache.
    nonisolated static func applyCachedContentReplacement(
        _ content: String,
        source: BookSource,
        rules: [ReplaceRule]
    ) -> String {
        applyGlobalReplaceRules(stripBrowserReadingModeNotice(content), source: source, rules: rules)
    }

    /// Several web-novel templates inject this browser-only warning into every chapter. It is
    /// neither story content nor a source-specific advertisement, so remove it before any user
    /// replacement rules run. Whitespace is deliberately flexible because sources often wrap the
    /// notice across HTML text nodes.
    nonisolated private static func stripBrowserReadingModeNotice(_ content: String) -> String {
        content.replacingOccurrences(
            of: #"\s*请\s*关闭\s*浏览器\s*阅读模式后查看本章节\s*[，,。！？]?\s*否则将出现无法翻页或章节内容丢失等现象\s*[。！]?"#,
            with: "",
            options: .regularExpression
        )
    }

    private func applyCurrentContentReplaceRules(to content: String) -> String {
        Self.applyCachedContentReplacement(
            content,
            source: source,
            rules: replaceRules(for: .content)
        )
    }

    private var contentRuleRevision: Int {
        ReaderContentRuleCacheVersion.current
    }

    private func processPersistedContentIfNeeded(_ content: String, at index: Int) -> String {
        guard ChapterCacheStore.contentRuleRevision(bookKey: chapterCacheKey, index: index) != contentRuleRevision else {
            return content
        }

        let processed = applyCurrentContentReplaceRules(to: content)
        let cacheKey = chapterCacheKey
        let revision = contentRuleRevision
        Task {
            try? await ChapterCacheStore.saveOnUtilityQueue(
                bookKey: cacheKey,
                index: index,
                content: processed,
                chapter: chapters[index],
                contentRuleRevision: revision
            )
        }
        return processed
    }

    private func observeReplaceRuleChanges() {
        NotificationCenter.default.publisher(for: .replaceRulesDidChange)
            .sink { [weak self] _ in
                self?.refreshCachedContentAfterRuleChange()
            }
            .store(in: &cancellables)
    }

    private func refreshCachedContentAfterRuleChange() {
        cachedContentReplaceRules = nil
        let rules = replaceRules(for: .content)

        var refreshed = cachedChapters
        var entriesToPersist: [(index: Int, content: String)] = []
        var hasVisibleContentChange = false
        for (index, cached) in cachedChapters {
            guard let content = cached.content else { continue }
            let processed = Self.applyCachedContentReplacement(content, source: source, rules: rules)
            if processed != content {
                var updated = cached
                updated.content = processed
                refreshed[index] = updated
                hasVisibleContentChange = true
            }
            entriesToPersist.append((index, processed))
        }
        if hasVisibleContentChange {
            cachedChapters = refreshed
        }
        let cacheKey = chapterCacheKey
        let revision = contentRuleRevision
        Task {
            for entry in entriesToPersist {
                try? await ChapterCacheStore.saveOnUtilityQueue(
                    bookKey: cacheKey,
                    index: entry.index,
                    content: entry.content,
                    chapter: chapters[entry.index],
                    contentRuleRevision: revision
                )
            }
        }
    }

    private func replaceRules(for scope: ReplaceRule.ReplaceScope) -> [ReplaceRule] {
        guard scope == .content else { return [] }
        if let cachedContentReplaceRules { return cachedContentReplaceRules }
        guard let modelContext else { return [] }

        let store = ReplaceRuleStore(modelContext: modelContext)
        let storedRules = store.fetchEnabled()
        let convertedRules = storedRules.map { $0.toReplaceRule() }
        let scopedRules = convertedRules.filter { rule in
            rule.scope == scope || rule.scope == .all
        }
        let matchingRules = scopedRules.filter { rule in
            rule.applies(
                toBookName: bookName,
                sourceName: source.bookSourceName,
                sourceURL: source.bookSourceUrl
            )
        }
        let sortedRules = matchingRules.sorted { $0.order < $1.order }
        cachedContentReplaceRules = sortedRules
        return sortedRules
    }

    /// Mirrors Android's replacement semantics, including `@js:` evaluated once per regex match.
    nonisolated static func applyReplaceRule(
        _ text: String,
        rule: ReplaceRule,
        source: BookSource
    ) -> String {
        guard !rule.pattern.isEmpty else { return text }
        guard rule.isRegex else {
            return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)
        }
        guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        guard rule.replacement.hasPrefix("@js:") else {
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.replacement)
        }

        let script = String(rule.replacement.dropFirst(4))
        let parser = JavaScriptParser(baseUrl: source.bookSourceUrl, source: source)
        var result = ""
        var cursor = text.startIndex
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let matchRange = Range(match.range, in: text) else { return }
            result += String(text[cursor..<matchRange.lowerBound])
            let matchedText = String(text[matchRange])
            result += (try? parser.evaluate(script: script, result: matchedText)) ?? matchedText
            cursor = matchRange.upperBound
        }
        result += String(text[cursor...])
        return result
    }

    private func substring(fromUTF16Offset offset: Int, in text: String) -> String {
        guard offset < text.utf16.count else {
            return ""
        }
        let index = String.Index(utf16Offset: offset, in: text)
        return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func makeDownloadOptions(
        totalChapterCount: Int,
        currentIndex: Int
    ) -> [(label: String, count: Int?)] {
        let remaining = totalChapterCount - currentIndex
        var options: [(String, Int?)] = []
        if remaining > 20 { options.append(("向下缓存20章", 20)) }
        if remaining > 100 { options.append(("向下缓存100章", 100)) }
        options.append(("全部缓存", nil))
        return options
    }

    nonisolated static func automaticPrefetchIndices(
        after index: Int,
        chapterCount: Int,
        count: Int
    ) -> [Int] {
        guard count > 0, index >= 0, index < chapterCount else { return [] }
        let start = index + 1
        guard start < chapterCount else { return [] }
        return Array(start..<min(start + count, chapterCount))
    }

    nonisolated static func missingChapterIndices(
        from start: Int,
        through end: Int,
        cachedIndices: Set<Int>
    ) -> [Int] {
        guard start >= 0, end >= start else { return [] }
        return (start...end).filter { !cachedIndices.contains($0) }
    }

    nonisolated static func hasPersistedEntireBook(
        chapterCount: Int,
        startingAt: Int = 0,
        chapterCacheKey: String
    ) -> Bool {
        guard chapterCount > 0, startingAt >= 0, startingAt < chapterCount else { return false }
        return (startingAt..<chapterCount).allSatisfy { index in
            ChapterCacheStore.hasNonEmptyContent(bookKey: chapterCacheKey, index: index)
        }
    }

    nonisolated static func makeContextSnippet(in text: String, around matchRange: Range<String.Index>) -> String {
        let start = text.index(matchRange.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(matchRange.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex

        var snippet = String(text[start..<end])
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if start > text.startIndex {
            snippet = "..." + snippet
        }
        if end < text.endIndex {
            snippet += "..."
        }
        return snippet
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct ReaderChapterContentPayload: Sendable {
    let content: String
    let mediaURLs: [String]
    let contentType: String
}
