import Foundation
import Combine

// MARK: - 换源结果
struct ChangeSourceSelection {
    let source: BookSource
    let searchBook: SearchBook
    let detail: BookDetail
    let chapters: [BookChapter]
    let targetIndex: Int
}

private actor ChangeSourceWorkQueue {
    private var sources: ArraySlice<BookSource>

    init(sources: [BookSource]) {
        self.sources = ArraySlice(sources)
    }

    func next() -> BookSource? {
        guard !sources.isEmpty else { return nil }
        return sources.removeFirst()
    }
}

private nonisolated enum ChapterTitleRegex {
    static let chineseNumber = try! NSRegularExpression(
        pattern: #"(第)\s*([零〇一二两三四五六七八九十百千万\d]+)\s*([章节卷回部篇集])"#
    )
    static let arabicNumber = try! NSRegularExpression(
        pattern: #"第\s*(\d+)\s*[章节卷回部篇集]"#
    )
}

// MARK: - 换源搜索 ViewModel
@MainActor
final class ChangeSourceViewModel: ObservableObject {
    nonisolated enum MatchLevel: Sendable {
        case exact
        case partial
        case unknown
        case mismatch

        var title: String {
            switch self {
            case .exact:
                return "精确匹配"
            case .partial:
                return "部分匹配"
            case .unknown:
                return "待校验"
            case .mismatch:
                return "不匹配"
            }
        }
    }

    nonisolated struct MatchRanking: Sendable {
        let score: Int
        let nameMatch: MatchLevel
        let authorMatch: MatchLevel
    }

    private nonisolated struct ValidatedCandidate: Sendable {
        let searchBook: SearchBook
        let ranking: MatchRanking
    }

    private nonisolated enum SourceProbeOutcome {
        case validated(ValidatedCandidate)
        case rejected
        case timedOut
    }

    struct ChangeSourceResult: Identifiable {
        let id = UUID()
        let source: BookSource
        let searchBook: SearchBook
        let ranking: MatchRanking
        var detail: BookDetail?
        var chapters: [BookChapter]?
        var matchedIndex: Int?
        var isApplying: Bool = false

        var latestChapter: String? {
            detail?.lastChapter ?? searchBook.lastChapter
        }
    }

    @Published var results: [ChangeSourceResult] = []
    @Published var isSearching: Bool = false
    @Published var errorMessage: String? = nil
    @Published var finishedSources: Int = 0
    @Published var totalSources: Int = 0

    private let bookName: String
    private let bookAuthor: String
    private let allSources: [BookSource]
    private let prefetchedBook: SearchBook?
    private let currentSourceURL: String?
    private let currentSourceName: String
    private let currentChapterTitle: String
    private let currentChapterIndex: Int
    private let currentChapterCount: Int
    private var searchTask: Task<Void, Never>?
    private var operationGeneration = UUID()
    private let inFlightWebBooks = InFlightWebBookRegistry()
    private static let perSourceSearchTimeoutSeconds = 3

    init(
        bookName: String,
        bookAuthor: String,
        allSources: [BookSource],
        prefetchedBook: SearchBook? = nil,
        currentSourceURL: String? = nil,
        currentSourceName: String = "",
        currentChapterTitle: String = "",
        currentChapterIndex: Int = 0,
        currentChapterCount: Int = 0
    ) {
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        self.allSources = allSources
        self.prefetchedBook = prefetchedBook
        self.currentSourceURL = currentSourceURL
        self.currentSourceName = currentSourceName
        self.currentChapterTitle = currentChapterTitle
        self.currentChapterIndex = currentChapterIndex
        self.currentChapterCount = currentChapterCount
        seedPrefetchedResults()
    }

    var searchProgressText: String {
        if isSearching {
            return "已搜索 \(finishedSources)/\(totalSources) 个书源"
        }
        return results.isEmpty ? "暂无可用书源" : "共 \(results.count) 个候选书源"
    }

    var currentSourceSummary: String {
        if currentSourceName.isEmpty {
            return "当前书源已自动排除"
        }
        return "当前书源：\(currentSourceName)（已自动排除）"
    }

    /// The source switcher follows Android and searches every enabled source, not only sources
    /// that happened to return the current book during the original search.
    var searchableSourceURLs: [String] {
        allSources
            .filter { source in
                source.enabled
                    && source.searchUrl != nil
                    && Self.normalizedSourceURL(source.bookSourceUrl) != Self.normalizedSourceURL(currentSourceURL ?? "")
                    && (currentSourceName.isEmpty || source.bookSourceName != currentSourceName)
            }
            .map(\.bookSourceUrl)
    }

    deinit {
        let registry = inFlightWebBooks
        searchTask?.cancel()
        Task {
            await registry.shutdownAll()
        }
    }

    func startSearch() {
        searchTask?.cancel()
        let generation = UUID()
        operationGeneration = generation
        searchTask = Task { [weak self, generation] in
            guard let self else { return }
            await self.inFlightWebBooks.shutdownAll()
            guard !Task.isCancelled, self.operationGeneration == generation else { return }
            await self.searchAll()
        }
    }

    private func searchAll() async {
        cleanupTransientResources()

        let trimmedBookName = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBookName.isEmpty else {
            errorMessage = "当前书籍名称为空，无法换源"
            return
        }

        isSearching = true
        results = []
        errorMessage = nil
        finishedSources = 0
        defer {
            isSearching = false
            searchTask = nil
        }

        let enabledSources = allSources.filter { source in
            source.enabled
                && source.searchUrl != nil
                && Self.normalizedSourceURL(source.bookSourceUrl) != Self.normalizedSourceURL(currentSourceURL ?? "")
                && (currentSourceName.isEmpty || source.bookSourceName != currentSourceName)
        }
        seedPrefetchedResults()
        let currentBookAuthor = bookAuthor
        totalSources = enabledSources.count

        guard !enabledSources.isEmpty else {
            if results.isEmpty {
                errorMessage = "没有可用的其他书源"
            }
            return
        }

        // Source JavaScript cannot be force-killed by Swift task cancellation. Keep fallback
        // discovery serial so one bad source cannot multiply CPU usage.
        let workQueue = ChangeSourceWorkQueue(sources: enabledSources)
        let workerCount = 1
        let webBookRegistry = inFlightWebBooks
        let sourceTimeoutSeconds = Self.perSourceSearchTimeoutSeconds

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self, trimmedBookName, currentBookAuthor] in
                    while !Task.isCancelled, let source = await workQueue.next() {
                        let outcome = await Task.detached(priority: .utility) {
                            await Self.probeSource(
                                source: source,
                                bookName: trimmedBookName,
                                bookAuthor: currentBookAuthor,
                                timeoutSeconds: sourceTimeoutSeconds,
                                registry: webBookRegistry
                            )
                        }.value

                        let shouldStopWorker = await MainActor.run { [weak self] in
                            guard let self else { return true }
                            self.finishedSources += 1
                            switch outcome {
                            case let .validated(candidate):
                                self.upsertResult(
                                    source: source,
                                    searchBook: candidate.searchBook,
                                    ranking: candidate.ranking
                                )
                                return false
                            case .rejected:
                                return false
                            case .timedOut:
                                return false
                            }
                        }
                        if shouldStopWorker { return }
                    }
                }
            }
        }

        guard !Task.isCancelled else {
            cleanupTransientResources()
            return
        }

        results.sort {
            if $0.ranking.score != $1.ranking.score {
                return $0.ranking.score > $1.ranking.score
            }
            return $0.source.bookSourceName.localizedCompare($1.source.bookSourceName) == .orderedAscending
        }

        guard !results.isEmpty else {
            errorMessage = "没有找到其他书源"
            cleanupTransientResources()
            return
        }
    }

    /// Android reuses the book rows produced by the original search immediately.
    /// Keep those candidates while the full enabled-source search fills in missing sources.
    private func seedPrefetchedResults() {
        guard let prefetchedBook else { return }
        let origins = prefetchedBook.sourceOrigins.isEmpty
            ? [SearchBookOrigin(
                url: prefetchedBook.origin,
                name: prefetchedBook.sourceName,
                bookUrl: prefetchedBook.bookUrl,
                infoHtml: prefetchedBook.infoHtml,
                sourceVariables: prefetchedBook.sourceVariables,
                bookVariables: prefetchedBook.bookVariables,
                variables: prefetchedBook.variables
            )]
            : prefetchedBook.sourceOrigins
        var seen: Set<String> = []
        for origin in origins {
            let normalized = Self.normalizedSourceURL(origin.url)
            guard !normalized.isEmpty,
                  seen.insert(normalized).inserted,
                  let source = allSources.first(where: {
                      $0.enabled && Self.normalizedSourceURL($0.bookSourceUrl) == normalized
                  }),
                  normalized != Self.normalizedSourceURL(currentSourceURL ?? ""),
                  currentSourceName.isEmpty || source.bookSourceName != currentSourceName else {
                continue
            }
            var book = prefetchedBook
            book.origin = source.bookSourceUrl
            book.sourceName = source.bookSourceName
            book.bookUrl = origin.bookUrl.isEmpty ? prefetchedBook.bookUrl : origin.bookUrl
            book.infoHtml = origin.infoHtml
            book.sourceVariables = origin.sourceVariables
            book.bookVariables = origin.bookVariables
            book.variables = origin.variables
            upsertResult(
                source: source,
                searchBook: book,
                ranking: Self.ranking(for: book, bookName: bookName, bookAuthor: bookAuthor)
            )
        }
    }

    private func upsertResult(
        source: BookSource,
        searchBook: SearchBook,
        ranking: MatchRanking
    ) {
        let sourceURL = Self.normalizedSourceURL(source.bookSourceUrl)
        if let index = results.firstIndex(where: {
            Self.normalizedSourceURL($0.source.bookSourceUrl) == sourceURL
        }) {
            return
        }
        results.append(
            ChangeSourceResult(
                source: source,
                searchBook: Self.makeLightweightSearchBook(searchBook),
                ranking: ranking
            )
        )
    }

    private nonisolated static func probeSource(
        source: BookSource,
        bookName: String,
        bookAuthor: String,
        timeoutSeconds: Int,
        registry: InFlightWebBookRegistry
    ) async -> SourceProbeOutcome {
        let webBook = WebBook(
            bookSource: source,
            maximumRequestTimeout: TimeInterval(timeoutSeconds),
            allowsWebViewRequests: false,
            allowsAutomaticWebViewRecovery: false
        )
        await registry.insert(webBook)

        do {
            let candidate = try await SourceOperationDeadline.run(seconds: timeoutSeconds, priority: .utility) {
                try Task.checkCancellation()
                let books = try await webBook.searchBook(keyword: bookName)
                guard let candidate = bestCandidate(
                    from: books,
                    bookName: bookName,
                    bookAuthor: bookAuthor
                ) else {
                    throw ParserError.emptyResult
                }

                return ValidatedCandidate(
                    searchBook: candidate.searchBook,
                    ranking: candidate.ranking
                )
            }
            await registry.shutdownAndRemove(webBook)
            return .validated(candidate)
        } catch is SourceOperationTimeoutError {
            await registry.shutdownAndRemove(webBook)
            return .timedOut
        } catch {
            await registry.shutdownAndRemove(webBook)
            return .rejected
        }
    }

    func prepareSelection(for result: ChangeSourceResult) async -> ChangeSourceSelection? {
        guard let index = results.firstIndex(where: { $0.id == result.id }) else {
            return nil
        }
        results[index].isApplying = true
        defer { results[index].isApplying = false }

        if results[index].detail == nil || results[index].chapters?.isEmpty != false {
            guard await loadToc(for: result) != nil else {
                return nil
            }
        }
        guard let detail = results[index].detail,
              let chapters = results[index].chapters,
              !chapters.isEmpty else {
            return nil
        }

        let targetIndex = results[index].matchedIndex ?? Self.matchChapterIndex(
            currentChapterTitle: currentChapterTitle,
            chapters: chapters,
            fallbackIndex: currentChapterIndex,
            currentChapterCount: currentChapterCount
        )

        return ChangeSourceSelection(
            source: result.source,
            searchBook: result.searchBook,
            detail: detail,
            chapters: chapters,
            targetIndex: targetIndex
        )
    }

    private func loadToc(for result: ChangeSourceResult) async -> (BookDetail, [BookChapter])? {
        guard let index = results.firstIndex(where: { $0.id == result.id }) else {
            return nil
        }

        if let detail = results[index].detail,
           let chapters = results[index].chapters,
           !chapters.isEmpty {
            return (detail, chapters)
        }

        let webBook = WebBook(
            bookSource: result.source,
            maximumRequestTimeout: TimeInterval(Self.perSourceSearchTimeoutSeconds),
            allowsWebViewRequests: false,
            allowsAutomaticWebViewRecovery: false
        )
        let webBookRegistry = inFlightWebBooks
        await webBookRegistry.insert(webBook)

        do {
            let detail = try await webBook.getBookInfo(
                bookUrl: result.searchBook.bookUrl,
                baseUrl: result.source.bookSourceUrl,
                cachedInfoHtml: result.searchBook.infoHtml,
                variables: result.searchBook.variables,
                sourceVariables: result.searchBook.sourceVariables,
                bookVariables: result.searchBook.bookVariables,
                name: result.searchBook.name,
                author: result.searchBook.author,
                kind: result.searchBook.kind ?? ""
            )

            guard let tocUrl = detail.tocUrl, !tocUrl.isEmpty else {
                await webBookRegistry.shutdownAndRemove(webBook)
                errorMessage = "切换书源失败：该书源未提供目录地址"
                return nil
            }

            let chapters = try await webBook.getTocList(
                tocUrl: tocUrl,
                bookUrl: detail.bookUrl,
                cachedTocHtml: detail.tocHtml,
                variables: detail.variables,
                sourceVariables: detail.sourceVariables,
                bookVariables: detail.bookVariables,
                name: detail.name,
                author: detail.author,
                kind: detail.kind ?? ""
            )

            guard !chapters.isEmpty else {
                await webBookRegistry.shutdownAndRemove(webBook)
                errorMessage = "切换书源失败：未能获取目录"
                return nil
            }

            await webBookRegistry.shutdownAndRemove(webBook)
            var trimmedDetail = detail
            trimmedDetail.infoHtml = nil
            trimmedDetail.tocHtml = nil
            results[index].detail = trimmedDetail
            results[index].chapters = chapters
            results[index].matchedIndex = Self.matchChapterIndex(
                currentChapterTitle: currentChapterTitle,
                chapters: chapters,
                fallbackIndex: currentChapterIndex,
                currentChapterCount: currentChapterCount
            )
            return (trimmedDetail, chapters)
        } catch {
            await webBookRegistry.shutdownAndRemove(webBook)
            errorMessage = "切换书源失败：\(error.localizedDescription)"
            return nil
        }
    }

    func cancel() {
        operationGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        results.removeAll(keepingCapacity: false)
        finishedSources = 0
        totalSources = 0
        errorMessage = nil
        isSearching = false
        Task {
            await inFlightWebBooks.shutdownAll()
        }
        cleanupTransientResources()
    }

    private nonisolated static func matchChapterIndex(
        currentChapterTitle: String,
        chapters: [BookChapter],
        fallbackIndex: Int,
        currentChapterCount: Int
    ) -> Int {
        guard !chapters.isEmpty else { return 0 }

        let normalizedCurrent = normalizeChapterTitle(currentChapterTitle)
        if !normalizedCurrent.isEmpty {
            let currentNumber = extractChapterNumber(from: currentChapterTitle)
            var fuzzyMatch: Int?
            var numberedMatch: Int?
            for (index, chapter) in chapters.enumerated() {
                let candidate = normalizeChapterTitle(chapter.title)
                if candidate == normalizedCurrent {
                    return index
                }
                if fuzzyMatch == nil,
                   candidate.contains(normalizedCurrent) || normalizedCurrent.contains(candidate) {
                    fuzzyMatch = index
                }
                if numberedMatch == nil,
                   let currentNumber,
                   extractChapterNumber(from: chapter.title) == currentNumber {
                    numberedMatch = index
                }
            }
            if let fuzzyMatch {
                return fuzzyMatch
            }
            if let numberedMatch {
                return numberedMatch
            }
        }

        let scaledIndex: Int
        if currentChapterCount > 1 {
            let progress = Double(max(fallbackIndex, 0)) / Double(max(currentChapterCount - 1, 1))
            scaledIndex = Int((progress * Double(max(chapters.count - 1, 0))).rounded())
        } else {
            scaledIndex = fallbackIndex
        }

        return min(max(scaledIndex, 0), chapters.count - 1)
    }

    private nonisolated static func normalizedSourceURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private nonisolated static func normalizeChapterTitle(_ title: String) -> String {
        Self.normalizeChineseChapterNumbers(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "【", with: "[")
            .replacingOccurrences(of: "】", with: "]")
            .lowercased()
    }

    private nonisolated static func extractChapterNumber(from title: String) -> Int? {
        let normalized = Self.normalizeChineseChapterNumbers(title)
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = ChapterTitleRegex.arabicNumber.firstMatch(in: normalized, range: range),
              let numberRange = Range(match.range(at: 1), in: normalized) else {
            return nil
        }
        return Int(normalized[numberRange])
    }

    private nonisolated static func makeLightweightSearchBook(_ book: SearchBook) -> SearchBook {
        var trimmed = book
        trimmed.infoHtml = nil
        return trimmed
    }

    private func cleanupTransientResources() {
        HeadlessWebView.shared.purge()
    }

    private nonisolated static func bestCandidate(from books: [SearchBook], bookName: String, bookAuthor: String) -> (searchBook: SearchBook, ranking: MatchRanking)? {
        books
            .map { ($0, ranking(for: $0, bookName: bookName, bookAuthor: bookAuthor)) }
            .filter { $0.1.nameMatch == .exact }
            .max { lhs, rhs in
                lhs.1.score < rhs.1.score
            }
            .map { (searchBook: $0.0, ranking: $0.1) }
    }

    private nonisolated static func ranking(for book: SearchBook, bookName: String, bookAuthor: String) -> MatchRanking {
        let normalizedBookName = normalizeText(bookName)
        let normalizedCandidateName = normalizeText(book.name)
        let normalizedBookAuthor = normalizeAuthor(bookAuthor)
        let normalizedCandidateAuthor = normalizeAuthor(book.author)

        let nameMatch: MatchLevel
        var score = 0
        if normalizedCandidateName == normalizedBookName {
            nameMatch = .exact
            score += 500
        } else if normalizedCandidateName.contains(normalizedBookName) || normalizedBookName.contains(normalizedCandidateName) {
            nameMatch = .partial
            score += 320
        } else {
            nameMatch = .mismatch
            score -= 400
        }

        let authorMatch: MatchLevel
        if normalizedBookAuthor.isEmpty {
            authorMatch = .unknown
        } else if normalizedCandidateAuthor.isEmpty {
            authorMatch = .unknown
            score -= 20
        } else if normalizedCandidateAuthor == normalizedBookAuthor {
            authorMatch = .exact
            score += 180
        } else if normalizedCandidateAuthor.contains(normalizedBookAuthor) || normalizedBookAuthor.contains(normalizedCandidateAuthor) {
            authorMatch = .partial
            score += 80
        } else {
            authorMatch = .mismatch
            score -= 120
        }

        if let lastChapter = book.lastChapter, !lastChapter.isEmpty {
            score += 20
        }
        if !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 10
        }

        return MatchRanking(score: score, nameMatch: nameMatch, authorMatch: authorMatch)
    }

    private nonisolated static func normalizeText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "：", with: ":")
            .lowercased()
    }

    private nonisolated static func normalizeAuthor(_ author: String) -> String {
        normalizeText(author)
            .replacingOccurrences(of: "作者:", with: "")
            .replacingOccurrences(of: "作者：", with: "")
    }

    private nonisolated static func normalizeChineseChapterNumbers(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        let matches = ChapterTitleRegex.chineseNumber.matches(in: title, range: range)
        guard !matches.isEmpty else { return title }

        var result = title
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let numeralRange = Range(match.range(at: 2), in: result),
                  let suffixRange = Range(match.range(at: 3), in: result) else {
                continue
            }

            let numeral = String(result[numeralRange])
            let replacement = "\(result[prefixRange])\(arabicNumber(from: numeral))\(result[suffixRange])"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private nonisolated static func arabicNumber(from value: String) -> Int {
        if let number = Int(value) {
            return number
        }

        let digits: [Character: Int] = [
            "零": 0, "〇": 0,
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

        var result = 0
        var current = 0

        for char in value {
            if let digit = digits[char] {
                current = digit
            } else if let unit = units[char] {
                let factor = current == 0 ? 1 : current
                result += factor * unit
                current = 0
            }
        }

        return result + current
    }
}
