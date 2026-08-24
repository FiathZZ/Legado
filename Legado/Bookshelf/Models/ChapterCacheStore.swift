import Foundation
import CommonCrypto

// MARK: - ChapterCacheStore
/// 章节正文文件缓存，保存到 Application Support/ChapterCache。
struct ChapterCacheStore {
    nonisolated private static let rootDirectoryName = "ChapterCache"

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
        contentRuleRevision: Int? = nil
    ) throws {
        let fileURL = chapterFileURL(bookKey: bookKey, index: index)
        try persist(content: content, to: fileURL)

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
        contentRuleRevision: Int? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            try saveSynchronously(
                bookKey: bookKey,
                index: index,
                content: content,
                contentRuleRevision: contentRuleRevision
            )
        }.value
    }

    nonisolated static func clear(bookKey: String) {
        let directoryURL = bookDirectoryURL(bookKey: bookKey)
        Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: directoryURL)
            } catch {
            }
        }
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

    nonisolated private static func chapterFileURL(bookKey: String, index: Int) -> URL {
        bookDirectoryURL(bookKey: bookKey).appendingPathComponent("\(index).txt")
    }

    nonisolated private static func chapterRuleRevisionFileURL(bookKey: String, index: Int) -> URL {
        bookDirectoryURL(bookKey: bookKey).appendingPathComponent("\(index).rules")
    }

    nonisolated private static func persist(content: String, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    nonisolated private static func bookDirectoryURL(bookKey: String) -> URL {
        rootDirectoryURL().appendingPathComponent(bookKey, isDirectory: true)
    }

    nonisolated private static func rootDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }
}
