import XCTest
@testable import Legado

final class BookSourceBatchComparisonExportTests: XCTestCase {
    private struct RunConfig: Codable {
        let keyword: String
        let startIndex: Int
        let endIndexExclusive: Int
        let timeoutSeconds: Double
        let outputPath: String
        let searchOnly: Bool?
        let allowsWebViewRequests: Bool?
        let allowsAutomaticWebViewRecovery: Bool?
        let sourceNames: [String]?
        let sourceIndices: [Int]?
        let snapshotPath: String?
        let snapshotIntervalSeconds: Double?
        let progressSummaryPath: String?
        let tracePath: String?
    }

    private struct SourceRunResult: Codable {
        let index: Int
        let sourceName: String
        let sourceUrl: String
        let searchOk: Bool
        let detailOk: Bool
        let tocOk: Bool
        let contentOk: Bool
        let firstResultName: String?
        let firstResultAuthor: String?
        let firstResultURL: String?
        let detailBookURL: String?
        let detailTocURL: String?
        let tocCount: Int?
        let firstChapterTitle: String?
        let firstChapterURL: String?
        let contentLength: Int?
        let errorStep: String?
        let errorMessage: String?
    }

    private struct SourceRunTrace: Codable {
        let index: Int
        let sourceName: String
        let sourceUrl: String
        let keyword: String
        let startedAt: String
        let durationSeconds: Double
        let stages: [StageTrace]
        let finalResult: SourceRunResult
    }

    private struct StageTrace: Codable {
        let stage: String
        let status: String
        let startedAt: String
        let durationSeconds: Double
        let input: [String: String]
        let output: [String: String]
        let requests: [LegadoRequestDescriptor]
        let errorMessage: String?
    }

    private struct SourceRunOutcome {
        let result: SourceRunResult
        let trace: SourceRunTrace
    }

    private struct ProgressSummary: Codable {
        let startedAt: String
        let lastUpdatedAt: String
        let startIndex: Int
        let endIndexExclusive: Int
        let completedCount: Int
        let totalCount: Int
        let lastCompletedIndex: Int?
        let lastCompletedSourceName: String?
        let searchOkCount: Int
        let detailOkCount: Int
        let tocOkCount: Int
        let contentOkCount: Int
        let outputPath: String
        let progressPath: String
        let snapshotPath: String?
    }

    private struct TimeoutError: Error, LocalizedError {
        var errorDescription: String? { "Timed out" }
    }

    private static let defaultConfigPath = "/tmp/ios_book_source_compare_config.json"
    private static let defaultSourcesPath = "/tmp/ios_book_source_compare_sources.json"
    private static let phase13SampleNames = [
        "UU小說",
        "83中文S",
        "八一.mu",
        "过期杂志",
        "企鹅浏览",
        "📗阅友小说",
        "非凡看书",
        "54看书-笔趣阁（天天书源）"
    ]

    func testExportComparisonBaseline() async throws {
        let previousLogging = ParserLog.isEnabled
        ParserLog.isEnabled = false
        defer { ParserLog.isEnabled = previousLogging }

        let config = try Self.makeConfig()
        let allSources = try Self.loadSources()
        let filteredSources = Self.filterSources(allSources, using: config.sourceNames, sourceIndices: config.sourceIndices)
        let effectiveStart = min(max(config.startIndex, 0), filteredSources.count)
        let effectiveEnd = min(max(config.endIndexExclusive, effectiveStart), filteredSources.count)
        let sources = Array(filteredSources[effectiveStart..<effectiveEnd])

        let outputURL = URL(fileURLWithPath: config.outputPath)
        let progressURL = outputURL.appendingPathExtension("jsonl")
        let snapshotURL = config.snapshotPath.map { URL(fileURLWithPath: $0) }
        let progressSummaryURL = config.progressSummaryPath.map { URL(fileURLWithPath: $0) }
        let traceURL = config.tracePath.map { URL(fileURLWithPath: $0) }
        let snapshotIntervalSeconds = max(config.snapshotIntervalSeconds ?? 30, 1)
        let startedAt = Date()
        var lastSnapshotAt = startedAt
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: progressURL)
        if let snapshotURL {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        if let progressSummaryURL {
            try? FileManager.default.removeItem(at: progressSummaryURL)
        }
        if let traceURL {
            try? FileManager.default.removeItem(at: traceURL)
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let snapshotURL {
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let progressSummaryURL {
            try FileManager.default.createDirectory(at: progressSummaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let traceURL {
            try FileManager.default.createDirectory(at: traceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var results: [SourceRunResult] = []
        for (index, source) in sources {
            let outcome = await Self.runSingleSource(
                index: index,
                source: source,
                keyword: config.keyword,
                timeoutSeconds: config.timeoutSeconds,
                searchOnly: config.searchOnly == true,
                allowsWebViewRequests: config.allowsWebViewRequests ?? false,
                allowsAutomaticWebViewRecovery: config.allowsAutomaticWebViewRecovery ?? true
            )
            let result = outcome.result
            results.append(result)
            try Self.appendLine(result, to: progressURL)
            if let traceURL {
                try Self.appendLine(outcome.trace, to: traceURL)
            }

            let now = Date()
            if now.timeIntervalSince(lastSnapshotAt) >= snapshotIntervalSeconds {
                try Self.writeProgressArtifacts(
                    results: results,
                    startedAt: startedAt,
                    updatedAt: now,
                    startIndex: effectiveStart,
                    endIndexExclusive: effectiveEnd,
                    outputURL: outputURL,
                    progressURL: progressURL,
                    snapshotURL: snapshotURL,
                    progressSummaryURL: progressSummaryURL
                )
                lastSnapshotAt = now
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: outputURL)
        try Self.writeProgressArtifacts(
            results: results,
            startedAt: startedAt,
            updatedAt: Date(),
            startIndex: effectiveStart,
            endIndexExclusive: effectiveEnd,
            outputURL: outputURL,
            progressURL: progressURL,
            snapshotURL: snapshotURL,
            progressSummaryURL: progressSummaryURL
        )
    }

    func testExportPhase13SampleComparison() async throws {
        let previousLogging = ParserLog.isEnabled
        ParserLog.isEnabled = false
        defer { ParserLog.isEnabled = previousLogging }

        let config = try Self.makeConfig(
            defaultOutputPath: "/tmp/ios_phase13_sample_compare.json",
            defaultSourceNames: Self.phase13SampleNames
        )
        let allSources = try Self.loadSources()
        let filteredSources = Self.filterSources(allSources, using: config.sourceNames, sourceIndices: config.sourceIndices)
        XCTAssertFalse(filteredSources.isEmpty, "Phase 13 sample set should not be empty")

        let outputURL = URL(fileURLWithPath: config.outputPath)
        let progressURL = outputURL.appendingPathExtension("jsonl")
        let traceURL = config.tracePath.map { URL(fileURLWithPath: $0) }
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: progressURL)
        if let traceURL {
            try? FileManager.default.removeItem(at: traceURL)
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let traceURL {
            try FileManager.default.createDirectory(at: traceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var results: [SourceRunResult] = []
        for (index, source) in filteredSources {
            let outcome = await Self.runSingleSource(
                index: index,
                source: source,
                keyword: config.keyword,
                timeoutSeconds: config.timeoutSeconds,
                searchOnly: config.searchOnly == true,
                allowsWebViewRequests: config.allowsWebViewRequests ?? false,
                allowsAutomaticWebViewRecovery: config.allowsAutomaticWebViewRecovery ?? true
            )
            let result = outcome.result
            results.append(result)
            try Self.appendLine(result, to: progressURL)
            if let traceURL {
                try Self.appendLine(outcome.trace, to: traceURL)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: outputURL)
    }

    private static func makeConfig(
        defaultOutputPath: String? = nil,
        defaultSourceNames: [String]? = nil
    ) throws -> RunConfig {
        let env = ProcessInfo.processInfo.environment
        let configPath = env["BOOK_SOURCE_COMPARE_CONFIG_PATH"] ?? defaultConfigPath
        let configURL = URL(fileURLWithPath: configPath)
        if let data = try? Data(contentsOf: configURL) {
            let decoded = try JSONDecoder().decode(RunConfig.self, from: data)
            let searchOnlyFlag = env["BOOK_SOURCE_COMPARE_SEARCH_ONLY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let envSearchOnly = searchOnlyFlag == nil ? nil : (searchOnlyFlag == "1" || searchOnlyFlag == "true")
            let envAllowsWebViewRequests = parseOptionalBoolEnv("BOOK_SOURCE_COMPARE_ALLOWS_WEBVIEW", env: env)
            let envAllowsAutomaticWebViewRecovery = parseOptionalBoolEnv("BOOK_SOURCE_COMPARE_ALLOWS_WEBVIEW_RECOVERY", env: env)
            let envSourceNames = env["BOOK_SOURCE_COMPARE_SOURCE_NAMES"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let envSourceIndices = loadSourceIndices(from: env)
            return RunConfig(
                keyword: env["BOOK_SOURCE_COMPARE_KEYWORD"] ?? decoded.keyword,
                startIndex: Int(env["BOOK_SOURCE_COMPARE_START_INDEX"] ?? "") ?? decoded.startIndex,
                endIndexExclusive: Int(env["BOOK_SOURCE_COMPARE_END_INDEX_EXCLUSIVE"] ?? "") ?? decoded.endIndexExclusive,
                timeoutSeconds: Double(env["BOOK_SOURCE_COMPARE_TIMEOUT_SECONDS"] ?? "") ?? decoded.timeoutSeconds,
                outputPath: env["BOOK_SOURCE_COMPARE_OUTPUT_PATH"] ?? decoded.outputPath,
                searchOnly: envSearchOnly ?? decoded.searchOnly,
                allowsWebViewRequests: envAllowsWebViewRequests ?? decoded.allowsWebViewRequests,
                allowsAutomaticWebViewRecovery: envAllowsAutomaticWebViewRecovery ?? decoded.allowsAutomaticWebViewRecovery,
                sourceNames: (envSourceNames?.isEmpty == false ? envSourceNames : decoded.sourceNames),
                sourceIndices: envSourceIndices ?? decoded.sourceIndices,
                snapshotPath: env["BOOK_SOURCE_COMPARE_SNAPSHOT_PATH"] ?? decoded.snapshotPath,
                snapshotIntervalSeconds: Double(env["BOOK_SOURCE_COMPARE_SNAPSHOT_INTERVAL_SECONDS"] ?? "") ?? decoded.snapshotIntervalSeconds,
                progressSummaryPath: env["BOOK_SOURCE_COMPARE_PROGRESS_SUMMARY_PATH"] ?? decoded.progressSummaryPath,
                tracePath: env["BOOK_SOURCE_COMPARE_TRACE_PATH"] ?? decoded.tracePath
            )
        }

        let keyword = env["BOOK_SOURCE_COMPARE_KEYWORD"] ?? "遮天"
        let startIndex = Int(env["BOOK_SOURCE_COMPARE_START_INDEX"] ?? "0") ?? 0
        let endIndexExclusive = Int(env["BOOK_SOURCE_COMPARE_END_INDEX_EXCLUSIVE"] ?? "463") ?? 463
        let timeoutSeconds = Double(env["BOOK_SOURCE_COMPARE_TIMEOUT_SECONDS"] ?? "12") ?? 12
        let outputPath = env["BOOK_SOURCE_COMPARE_OUTPUT_PATH"] ?? defaultOutputPath ?? "/tmp/ios_book_source_compare.json"
        let searchOnlyFlag = env["BOOK_SOURCE_COMPARE_SEARCH_ONLY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchOnly = searchOnlyFlag == "1" || searchOnlyFlag == "true"
        let allowsWebViewRequests = parseOptionalBoolEnv("BOOK_SOURCE_COMPARE_ALLOWS_WEBVIEW", env: env)
        let allowsAutomaticWebViewRecovery = parseOptionalBoolEnv("BOOK_SOURCE_COMPARE_ALLOWS_WEBVIEW_RECOVERY", env: env)
        let sourceNames = env["BOOK_SOURCE_COMPARE_SOURCE_NAMES"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sourceIndices = loadSourceIndices(from: env)
        let snapshotPath = env["BOOK_SOURCE_COMPARE_SNAPSHOT_PATH"]
        let snapshotIntervalSeconds = Double(env["BOOK_SOURCE_COMPARE_SNAPSHOT_INTERVAL_SECONDS"] ?? "30")
        let progressSummaryPath = env["BOOK_SOURCE_COMPARE_PROGRESS_SUMMARY_PATH"]
        let tracePath = env["BOOK_SOURCE_COMPARE_TRACE_PATH"]
        return RunConfig(
            keyword: keyword,
            startIndex: startIndex,
            endIndexExclusive: endIndexExclusive,
            timeoutSeconds: timeoutSeconds,
            outputPath: outputPath,
            searchOnly: searchOnly,
            allowsWebViewRequests: allowsWebViewRequests,
            allowsAutomaticWebViewRecovery: allowsAutomaticWebViewRecovery,
            sourceNames: (sourceNames?.isEmpty == false ? sourceNames : defaultSourceNames),
            sourceIndices: sourceIndices,
            snapshotPath: snapshotPath,
            snapshotIntervalSeconds: snapshotIntervalSeconds,
            progressSummaryPath: progressSummaryPath,
            tracePath: tracePath
        )
    }

    private static func parseOptionalBoolEnv(_ key: String, env: [String: String]) -> Bool? {
        guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        return raw == "1" || raw == "true"
    }

    private static func loadSources() throws -> [BookSource] {
        let env = ProcessInfo.processInfo.environment
        let fileURL: URL
        if let customPath = env["BOOK_SOURCE_COMPARE_SOURCES_PATH"],
           !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fileURL = URL(fileURLWithPath: customPath)
        } else if FileManager.default.fileExists(atPath: defaultSourcesPath) {
            fileURL = URL(fileURLWithPath: defaultSourcesPath)
        } else {
            fileURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("书源.json")
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([BookSource].self, from: data)
    }

    private static func filterSources(
        _ sources: [BookSource],
        using sourceNames: [String]?,
        sourceIndices: [Int]?
    ) -> [(Int, BookSource)] {
        let indexedSources = Array(sources.enumerated())

        if let sourceIndices, !sourceIndices.isEmpty {
            return sourceIndices.compactMap { index in
                guard sources.indices.contains(index) else { return nil }
                return (index, sources[index])
            }
        }

        guard let sourceNames, !sourceNames.isEmpty else { return indexedSources }

        let nameSet = Set(sourceNames)
        return indexedSources.filter { _, source in
            nameSet.contains(source.bookSourceName)
        }
    }

    private static func loadSourceIndices(from env: [String: String]) -> [Int]? {
        guard let path = env["BOOK_SOURCE_COMPARE_SOURCE_INDICES_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let payload = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !payload.isEmpty else { return nil }

        if let rawIndices = try? JSONDecoder().decode([Int].self, from: Data(payload.utf8)) {
            return rawIndices
        }

        if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
           let rawIndices = object["indices"] as? [Int] {
            return rawIndices
        }

        return nil
    }

    private static func runSingleSource(
        index: Int,
        source: BookSource,
        keyword: String,
        timeoutSeconds: Double,
        searchOnly: Bool,
        allowsWebViewRequests: Bool,
        allowsAutomaticWebViewRecovery: Bool
    ) async -> SourceRunOutcome {
        let runStartedAt = Date()
        let requestCollector = LegadoRequestTraceCollector()
        var stages: [StageTrace] = []
        var searchOk = false
        var detailOk = false
        var tocOk = false
        var firstResultName: String?
        var firstResultAuthor: String?
        var firstResultURL: String?
        var detailBookURL: String?
        var detailTocURL: String?
        var tocCount: Int?
        var firstChapterTitle: String?
        var firstChapterURL: String?

        func makeOutcome(_ result: SourceRunResult) -> SourceRunOutcome {
            let completedAt = Date()
            return SourceRunOutcome(
                result: result,
                trace: SourceRunTrace(
                    index: index,
                    sourceName: source.bookSourceName,
                    sourceUrl: source.bookSourceUrl,
                    keyword: keyword,
                    startedAt: iso8601String(runStartedAt),
                    durationSeconds: roundedDuration(from: runStartedAt, to: completedAt),
                    stages: stages,
                    finalResult: result
                )
            )
        }

        func appendStage(
            _ stage: String,
            status: String,
            startedAt: Date,
            output: [String: String] = [:],
            errorMessage: String? = nil
        ) {
            let input: [String: String]
            switch stage {
            case "search":
                input = [
                    "sourceUrl": source.bookSourceUrl,
                    "searchUrlRule": source.searchUrl ?? "",
                    "keyword": keyword
                ]
            case "detail":
                input = [
                    "bookInfoRule": compactRule(source.ruleBookInfo?.name),
                    "tocUrlRule": compactRule(source.ruleBookInfo?.tocUrl)
                ]
            case "toc":
                input = [
                    "chapterListRule": compactRule(source.ruleToc?.chapterList),
                    "nextTocUrlRule": compactRule(source.ruleToc?.nextTocUrl)
                ]
            case "content":
                input = [
                    "contentRule": compactRule(source.ruleContent?.content),
                    "nextContentUrlRule": compactRule(source.ruleContent?.nextContentUrl)
                ]
            default:
                input = [:]
            }

            stages.append(
                StageTrace(
                    stage: stage,
                    status: status,
                    startedAt: iso8601String(startedAt),
                    durationSeconds: roundedDuration(from: startedAt, to: Date()),
                    input: input,
                    output: output,
                    requests: requestCollector.drain(),
                    errorMessage: errorMessage
                )
            )
        }

        do {
            return try await withTimeout(seconds: timeoutSeconds) {
                let webBook = WebBook(
                    bookSource: source,
                    maximumRequestTimeout: timeoutSeconds,
                    allowsWebViewRequests: allowsWebViewRequests,
                    allowsAutomaticWebViewRecovery: allowsAutomaticWebViewRecovery,
                    requestTraceCollector: requestCollector
                )
                    let searchStartedAt = Date()
                    let searchResults = try await webBook.searchBook(
                        keyword: keyword,
                        maximumResults: 1
                    )
                    guard let firstResult = searchResults.first else {
                        appendStage("search", status: "failed", startedAt: searchStartedAt, errorMessage: "empty_result")
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: false,
                            detailOk: false,
                            tocOk: false,
                            contentOk: false,
                            firstResultName: nil,
                            firstResultAuthor: nil,
                            firstResultURL: nil,
                            detailBookURL: nil,
                            detailTocURL: nil,
                            tocCount: nil,
                            firstChapterTitle: nil,
                            firstChapterURL: nil,
                            contentLength: nil,
                            errorStep: "search",
                            errorMessage: "empty_result"
                        ))
                    }
                    appendStage(
                        "search",
                        status: "passed",
                        startedAt: searchStartedAt,
                        output: [
                            "resultCount": "\(searchResults.count)",
                            "firstResultName": firstResult.name,
                            "firstResultAuthor": firstResult.author,
                            "firstResultURL": firstResult.bookUrl
                        ]
                    )
                    searchOk = true
                    firstResultName = firstResult.name
                    firstResultAuthor = firstResult.author
                    firstResultURL = firstResult.bookUrl

                    if searchOnly {
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: searchOk,
                            detailOk: false,
                            tocOk: false,
                            contentOk: false,
                            firstResultName: firstResultName,
                            firstResultAuthor: firstResultAuthor,
                            firstResultURL: firstResultURL,
                            detailBookURL: nil,
                            detailTocURL: nil,
                            tocCount: nil,
                            firstChapterTitle: nil,
                            firstChapterURL: nil,
                            contentLength: nil,
                            errorStep: nil,
                            errorMessage: nil
                        ))
                    }

                    let detail: BookDetail
                    let detailStartedAt = Date()
                    do {
                        detail = try await webBook.getBookInfo(
                            bookUrl: firstResult.bookUrl,
                            variables: firstResult.variables,
                            sourceVariables: firstResult.sourceVariables,
                            bookVariables: firstResult.bookVariables,
                            name: firstResult.name,
                            author: firstResult.author,
                            kind: firstResult.kind ?? ""
                        )
                        appendStage(
                            "detail",
                            status: "passed",
                            startedAt: detailStartedAt,
                            output: [
                                "detailBookURL": detail.bookUrl,
                                "detailTocURL": detail.tocUrl ?? "",
                                "name": detail.name,
                                "author": detail.author,
                                "bookVariableKeys": detail.bookVariables.keys.sorted().joined(separator: ","),
                                "variableKeys": detail.variables.keys.sorted().joined(separator: ","),
                                "bid": detail.bookVariables["bid"] ?? detail.variables["bid"] ?? ""
                            ]
                        )
                        detailOk = true
                        detailBookURL = detail.bookUrl
                        detailTocURL = detail.tocUrl ?? ""
                    } catch {
                        appendStage("detail", status: "failed", startedAt: detailStartedAt, errorMessage: error.localizedDescription)
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: searchOk,
                            detailOk: false,
                            tocOk: false,
                            contentOk: false,
                            firstResultName: firstResultName,
                            firstResultAuthor: firstResultAuthor,
                            firstResultURL: firstResultURL,
                            detailBookURL: nil,
                            detailTocURL: nil,
                            tocCount: nil,
                            firstChapterTitle: nil,
                            firstChapterURL: nil,
                            contentLength: nil,
                            errorStep: "detail",
                            errorMessage: error.localizedDescription
                        ))
                    }

                    let tocURL = detail.tocUrl ?? firstResult.bookUrl
                    let chapters: [BookChapter]
                    let tocStartedAt = Date()
                    do {
                        chapters = try await webBook.getTocList(
                            tocUrl: tocURL,
                            bookUrl: firstResult.bookUrl,
                            cachedTocHtml: detail.tocHtml,
                            variables: detail.variables,
                            sourceVariables: detail.sourceVariables,
                            bookVariables: detail.bookVariables,
                            fetchMode: .validation()
                        )
                        appendStage(
                            "toc",
                            status: "passed",
                            startedAt: tocStartedAt,
                            output: [
                                "tocURL": tocURL,
                                "tocCount": "\(chapters.count)",
                                "firstChapterTitle": (chapters.first(where: { !$0.isVolume }) ?? chapters.first)?.title ?? "",
                                "firstChapterURL": (chapters.first(where: { !$0.isVolume }) ?? chapters.first)?.url ?? "",
                                "bookVariableKeys": detail.bookVariables.keys.sorted().joined(separator: ","),
                                "variableKeys": detail.variables.keys.sorted().joined(separator: ","),
                                "bid": detail.bookVariables["bid"] ?? detail.variables["bid"] ?? ""
                            ]
                        )
                        tocOk = true
                        tocCount = chapters.count
                        firstChapterTitle = (chapters.first(where: { !$0.isVolume }) ?? chapters.first)?.title
                        firstChapterURL = (chapters.first(where: { !$0.isVolume }) ?? chapters.first)?.url
                    } catch {
                        appendStage("toc", status: "failed", startedAt: tocStartedAt, output: ["tocURL": tocURL], errorMessage: error.localizedDescription)
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: searchOk,
                            detailOk: detailOk,
                            tocOk: false,
                            contentOk: false,
                            firstResultName: firstResultName,
                            firstResultAuthor: firstResultAuthor,
                            firstResultURL: firstResultURL,
                            detailBookURL: detailBookURL,
                            detailTocURL: tocURL,
                            tocCount: nil,
                            firstChapterTitle: nil,
                            firstChapterURL: nil,
                            contentLength: nil,
                            errorStep: "toc",
                            errorMessage: error.localizedDescription
                        ))
                    }

                    guard let firstChapter = chapters.first(where: { !$0.isVolume }) ?? chapters.first else {
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: searchOk,
                            detailOk: detailOk,
                            tocOk: false,
                            contentOk: false,
                            firstResultName: firstResultName,
                            firstResultAuthor: firstResultAuthor,
                            firstResultURL: firstResultURL,
                            detailBookURL: detailBookURL,
                            detailTocURL: tocURL,
                            tocCount: chapters.count,
                            firstChapterTitle: nil,
                            firstChapterURL: nil,
                            contentLength: nil,
                            errorStep: "toc",
                            errorMessage: "empty_chapter_list"
                        ))
                    }

                    let contentStartedAt = Date()
                    let nextChapterURL = nextNonVolumeChapterURL(after: firstChapter, in: chapters)
                    do {
                        let content = try await webBook.getContent(
                            chapter: firstChapter,
                            nextChapterUrl: nextChapterURL,
                            variables: detail.variables,
                            fetchMode: .validation()
                        )
                        appendStage(
                            "content",
                            status: "passed",
                            startedAt: contentStartedAt,
                            output: [
                                "chapterTitle": firstChapter.title,
                                "chapterURL": firstChapter.url,
                                "contentLength": "\(content.wordCount)"
                            ]
                        )
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: searchOk,
                            detailOk: detailOk,
                            tocOk: tocOk,
                            contentOk: true,
                            firstResultName: firstResultName,
                            firstResultAuthor: firstResultAuthor,
                            firstResultURL: firstResultURL,
                            detailBookURL: detailBookURL,
                            detailTocURL: detailTocURL ?? tocURL,
                            tocCount: chapters.count,
                            firstChapterTitle: firstChapter.title,
                            firstChapterURL: firstChapter.url,
                            contentLength: content.wordCount,
                            errorStep: nil,
                            errorMessage: nil
                        ))
                    } catch {
                        appendStage("content", status: "failed", startedAt: contentStartedAt, output: ["chapterURL": firstChapter.url], errorMessage: error.localizedDescription)
                        return makeOutcome(SourceRunResult(
                            index: index,
                            sourceName: source.bookSourceName,
                            sourceUrl: source.bookSourceUrl,
                            searchOk: searchOk,
                            detailOk: detailOk,
                            tocOk: tocOk,
                            contentOk: false,
                            firstResultName: firstResultName,
                            firstResultAuthor: firstResultAuthor,
                            firstResultURL: firstResultURL,
                            detailBookURL: detailBookURL,
                            detailTocURL: detailTocURL ?? tocURL,
                            tocCount: chapters.count,
                            firstChapterTitle: firstChapter.title,
                            firstChapterURL: firstChapter.url,
                            contentLength: nil,
                            errorStep: "content",
                            errorMessage: error.localizedDescription
                        ))
                    }
            }
        } catch {
            if stages.isEmpty {
                appendStage(
                    "search",
                    status: "failed",
                    startedAt: runStartedAt,
                    errorMessage: error.localizedDescription
                )
            }
            return makeOutcome(SourceRunResult(
                index: index,
                sourceName: source.bookSourceName,
                sourceUrl: source.bookSourceUrl,
                searchOk: searchOk,
                detailOk: detailOk,
                tocOk: tocOk,
                contentOk: false,
                firstResultName: firstResultName,
                firstResultAuthor: firstResultAuthor,
                firstResultURL: firstResultURL,
                detailBookURL: detailBookURL,
                detailTocURL: detailTocURL,
                tocCount: tocCount,
                firstChapterTitle: firstChapterTitle,
                firstChapterURL: firstChapterURL,
                contentLength: nil,
                errorStep: partialErrorStep(
                    searchOk: searchOk,
                    detailOk: detailOk,
                    tocOk: tocOk
                ),
                errorMessage: error.localizedDescription
            ))
        }
    }

    private static func appendLine<T: Encodable>(_ result: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = try encoder.encode(result) + Data([0x0A])
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    private static func writeProgressArtifacts(
        results: [SourceRunResult],
        startedAt: Date,
        updatedAt: Date,
        startIndex: Int,
        endIndexExclusive: Int,
        outputURL: URL,
        progressURL: URL,
        snapshotURL: URL?,
        progressSummaryURL: URL?
    ) throws {
        if let snapshotURL {
            try writeSnapshot(results, to: snapshotURL)
        }
        if let progressSummaryURL {
            try writeProgressSummary(
                results: results,
                startedAt: startedAt,
                updatedAt: updatedAt,
                startIndex: startIndex,
                endIndexExclusive: endIndexExclusive,
                outputURL: outputURL,
                progressURL: progressURL,
                snapshotURL: snapshotURL,
                to: progressSummaryURL
            )
        }
    }

    private static func writeSnapshot(_ results: [SourceRunResult], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: url)
    }

    private static func writeProgressSummary(
        results: [SourceRunResult],
        startedAt: Date,
        updatedAt: Date,
        startIndex: Int,
        endIndexExclusive: Int,
        outputURL: URL,
        progressURL: URL,
        snapshotURL: URL?,
        to url: URL
    ) throws {
        let summary = ProgressSummary(
            startedAt: iso8601String(startedAt),
            lastUpdatedAt: iso8601String(updatedAt),
            startIndex: startIndex,
            endIndexExclusive: endIndexExclusive,
            completedCount: results.count,
            totalCount: max(endIndexExclusive - startIndex, 0),
            lastCompletedIndex: results.last?.index,
            lastCompletedSourceName: results.last?.sourceName,
            searchOkCount: results.filter(\.searchOk).count,
            detailOkCount: results.filter(\.detailOk).count,
            tocOkCount: results.filter(\.tocOk).count,
            contentOkCount: results.filter(\.contentOk).count,
            outputPath: outputURL.path,
            progressPath: progressURL.path,
            snapshotPath: snapshotURL?.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: url)
    }

    private static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func roundedDuration(from start: Date, to end: Date) -> Double {
        (end.timeIntervalSince(start) * 1000).rounded() / 1000
    }

    private static func compactRule(_ value: String?, limit: Int = 160) -> String {
        guard let value else { return "" }
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit - 1)) + "…"
    }

    private static func nextNonVolumeChapterURL(after chapter: BookChapter, in chapters: [BookChapter]) -> String? {
        guard let currentIndex = chapters.firstIndex(where: {
            $0.url == chapter.url && $0.title == chapter.title && $0.index == chapter.index
        }) else {
            return chapters.first(where: { !$0.isVolume && $0.url != chapter.url })?.url
        }

        guard currentIndex < chapters.endIndex else { return nil }
        return chapters[chapters.index(after: currentIndex)...]
            .first(where: { !$0.isVolume })?
            .url
    }

    private static func partialErrorStep(searchOk: Bool, detailOk: Bool, tocOk: Bool) -> String {
        if tocOk {
            return "content"
        }
        if detailOk {
            return "toc"
        }
        if searchOk {
            return "detail"
        }
        return "search"
    }

    private static func withTimeout<T>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
