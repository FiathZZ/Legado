import Foundation
import CommonCrypto

// MARK: - ChapterCacheStore
/// 章节正文文件缓存，保存到 Application Support/ChapterCache。
struct ChapterCacheStore {
    nonisolated private static let rootDirectoryName = "ChapterCache"

    /// The durable boundary of a completed offline book. A body file alone is an incremental
    /// cache; only this manifest means the TOC and every chapter are available offline.
    nonisolated struct OfflineBookManifest: Codable, Sendable {
        let chapters: [BookChapter]
    }

    nonisolated static func content(bookKey: String, index: Int) -> String? {
        let fileURL = chapterFileURL(bookKey: bookKey, index: index)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// The rule revision that was applied before this chapter was written. Keeping it next to
    /// the chapter avoids replaying every global replacement rule for unchanged cached text
    /// each time the reader is opened.
    nonisolated static func contentRuleRevision(bookKey: String, index: Int) -> Int? {
        let fileURL = chapterRuleRevisionFileURL(bookKey: bookKey, index: index)
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func chapterMetadata(bookKey: String, index: Int) -> BookChapter? {
        guard let data = try? Data(contentsOf: chapterMetadataFileURL(bookKey: bookKey, index: index)) else { return nil }
        return try? JSONDecoder().decode(BookChapter.self, from: data)
    }

    nonisolated static func offlineBookManifest(bookKey: String) -> OfflineBookManifest? {
        guard let data = try? Data(contentsOf: offlineManifestFileURL(bookKey: bookKey)) else { return nil }
        return try? JSONDecoder().decode(OfflineBookManifest.self, from: data)
    }

    nonisolated static func saveOfflineBookManifest(bookKey: String, chapters: [BookChapter]) throws {
        guard !chapters.isEmpty else { return }
        let manifest = OfflineBookManifest(chapters: chapters)
        try persist(data: JSONEncoder().encode(manifest), to: offlineManifestFileURL(bookKey: bookKey))
    }

    nonisolated static func isOfflineBookComplete(bookKey: String) -> Bool {
        guard let manifest = offlineBookManifest(bookKey: bookKey), !manifest.chapters.isEmpty else {
            return false
        }
        return manifest.chapters.allSatisfy {
            hasNonEmptyContent(bookKey: bookKey, index: $0.index)
        }
    }

    /// Cache-completeness checks must not decode every chapter into a `String`. A large offline
    /// book can otherwise briefly hold its full text in memory while a reader is being opened.
    nonisolated static func hasNonEmptyContent(bookKey: String, index: Int) -> Bool {
        let fileURL = chapterFileURL(bookKey: bookKey, index: index)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    nonisolated static func save(bookKey: String, index: Int, content: String) {
        let fileURL = chapterFileURL(bookKey: bookKey, index: index)
        Task.detached(priority: .utility) {
            do {
                try persist(content: content, to: fileURL)
            } catch {
            }
        }
    }

    nonisolated static func saveSynchronously(
        bookKey: String,
        index: Int,
        content: String,
        chapter: BookChapter? = nil,
        contentRuleRevision: Int? = nil
    ) throws {
        let fileURL = chapterFileURL(bookKey: bookKey, index: index)
        try persist(content: content, to: fileURL)
        if let chapter, let data = try? JSONEncoder().encode(chapter) {
            try persist(data: data, to: chapterMetadataFileURL(bookKey: bookKey, index: index))
        }

        let revisionURL = chapterRuleRevisionFileURL(bookKey: bookKey, index: index)
        if let contentRuleRevision {
            try persist(content: String(contentRuleRevision), to: revisionURL)
        } else {
            try? FileManager.default.removeItem(at: revisionURL)
        }
    }

    /// Full-book caching awaits this write so completion means all chapter files are on disk,
    /// without blocking the reader's main actor during filesystem work.
    nonisolated static func saveOnUtilityQueue(
        bookKey: String,
        index: Int,
        content: String,
        chapter: BookChapter? = nil,
        contentRuleRevision: Int? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            try saveSynchronously(
                bookKey: bookKey,
                index: index,
                content: content,
                chapter: chapter,
                contentRuleRevision: contentRuleRevision
            )
        }.value
    }

    nonisolated static func clear(bookKey: String) {
        Task.detached(priority: .utility) {
            await clearAsync(bookKey: bookKey)
        }
    }

    nonisolated static func clearAsync(bookKey: String) async {
        let directoryURL = bookDirectoryURL(bookKey: bookKey)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
        }
    }

    nonisolated static func clearAll() async {
        let directoryURL = rootDirectoryURL()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func makeKey(sourceUrl: String, bookUrl: String) -> String {
        let data = Data((sourceUrl + bookUrl).utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        let hex = digest.map { String(format: "%02hhx", $0) }.joined()
        return String(hex.prefix(16))
    }

    nonisolated static func cachedChapterContents(bookKey: String) -> [(index: Int, content: String)] {
        let directoryURL = bookDirectoryURL(bookKey: bookKey)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension == "txt" || fileURL.pathExtension.isEmpty,
                  let index = Int(fileURL.deletingPathExtension().lastPathComponent),
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return nil
            }
            return (index, content)
        }
        .sorted { $0.index < $1.index }
    }

    /// Returns indexes with non-empty persisted chapter bodies without loading their text.
    nonisolated static func cachedChapterIndices(bookKey: String) -> [Int] {
        let directoryURL = bookDirectoryURL(bookKey: bookKey)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension == "txt" || fileURL.pathExtension.isEmpty,
                  let index = Int(fileURL.deletingPathExtension().lastPathComponent),
                  let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) > 0 else {
                return nil
            }
            return index
        }.sorted()
    }

    nonisolated private static func chapterFileURL(bookKey: String, index: Int) -> URL {
        bookDirectoryURL(bookKey: bookKey).appendingPathComponent("\(index).txt")
    }

    nonisolated private static func chapterRuleRevisionFileURL(bookKey: String, index: Int) -> URL {
        bookDirectoryURL(bookKey: bookKey).appendingPathComponent("\(index).rules")
    }

    nonisolated private static func chapterMetadataFileURL(bookKey: String, index: Int) -> URL {
        bookDirectoryURL(bookKey: bookKey).appendingPathComponent("\(index).meta")
    }

    nonisolated private static func offlineManifestFileURL(bookKey: String) -> URL {
        bookDirectoryURL(bookKey: bookKey).appendingPathComponent("offline-manifest.json")
    }

    nonisolated private static func persist(content: String, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    nonisolated private static func persist(data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    nonisolated private static func bookDirectoryURL(bookKey: String) -> URL {
        rootDirectoryURL().appendingPathComponent(bookKey, isDirectory: true)
    }

    nonisolated private static func rootDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }
}
