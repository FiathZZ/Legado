import Foundation
import SwiftData

enum LocalBookSupport {
    static let sourceURL = "local"
    static let sourceName = "本地书籍"

    static func source() -> BookSource {
        BookSource(
            bookSourceName: sourceName,
            bookSourceUrl: sourceURL,
            enabled: true,
            enabledExplore: false
        )
    }

    static func isLocalSource(_ sourceURL: String) -> Bool {
        sourceURL == self.sourceURL
    }

    static func makeBookURL(relativePath: String) -> String {
        "local://\(relativePath)"
    }
}

enum LocalBookImportError: LocalizedError {
    case unsupportedFileType
    case decodeFailed
    case emptyBookContent
    case missingEPUBContainer
    case missingEPUBPackage
    case missingCachedChapters

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "仅支持导入 TXT 与 EPUB 文件。"
        case .decodeFailed:
            return "未能识别文件编码。"
        case .emptyBookContent:
            return "书籍内容为空，无法导入。"
        case .missingEPUBContainer:
            return "EPUB 缺少 META-INF/container.xml。"
        case .missingEPUBPackage:
            return "EPUB 缺少 OPF 包文件。"
        case .missingCachedChapters:
            return "当前没有可导出的已缓存章节。"
        }
    }
}

extension Notification.Name {
    static let bookshelfDataDidChange = Notification.Name("Legado.bookshelfDataDidChange")
    static let bookSourcesDidChange = Notification.Name("Legado.bookSourcesDidChange")
    static let replaceRulesDidChange = Notification.Name("Legado.replaceRulesDidChange")
}

enum LocalBookTextDecoder {
    static let candidateEncodings: [String.Encoding] = [
        .utf8,
        .unicode,
        .utf16LittleEndian,
        .utf16BigEndian,
        .gb18030,
        .gbk,
        .gb2312
    ]

    static func decode(_ data: Data) -> String? {
        for encoding in candidateEncodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

extension String.Encoding {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)))
    static let gb2312 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_CN.rawValue)))
}

enum LocalBookFileStore {
    static func persistImportedFile(from externalURL: URL) throws -> (fileURL: URL, relativePath: String) {
        try persistImportedFile(from: externalURL, securityScoped: true)
    }

    static func persistUploadedFile(from temporaryURL: URL) throws -> (fileURL: URL, relativePath: String) {
        try persistImportedFile(from: temporaryURL, securityScoped: false)
    }

    private static func persistImportedFile(from sourceURL: URL, securityScoped: Bool) throws -> (fileURL: URL, relativePath: String) {
        let didAccess = securityScoped ? sourceURL.startAccessingSecurityScopedResource() : false
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = sourceURL.pathExtension
        let fileName = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        let relativePath = "Files/\(fileName)"
        let destinationURL = baseDirectory.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return (destinationURL, relativePath)
    }

    static func saveCover(data: Data, preferredExtension: String) throws -> URL {
        let fileName = UUID().uuidString + "." + preferredExtension
        let url = baseDirectory.appendingPathComponent("Covers/\(fileName)", isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static var baseDirectory: URL {
        ThemeStore().applicationSupportDirectory.appendingPathComponent("LocalBooks", isDirectory: true)
    }
}

struct LocalBookImportPayload {
    let detail: BookDetail
    let chapters: [BookChapter]
    let contents: [String]
}

@MainActor
enum LocalBookLibraryService {
    static func supportsImport(url: URL) -> Bool {
        ["txt", "epub"].contains(url.pathExtension.lowercased())
    }

    static func importBook(from externalURL: URL, modelContext: ModelContext) async throws -> BookEntity {
        let persistedFile = try LocalBookFileStore.persistImportedFile(from: externalURL)
        let importer = LocalBookImporter()
        let payload = try await importer.importTemporaryFile(
            url: persistedFile.fileURL,
            bookNameHint: externalURL.deletingPathExtension().lastPathComponent
        )
        return try persistImportedBook(payload, relativePath: persistedFile.relativePath, modelContext: modelContext)
    }

    static func importTemporaryBook(
        from temporaryURL: URL,
        originalFileName: String? = nil,
        modelContext: ModelContext
    ) async throws -> BookEntity {
        let persistedFile = try LocalBookFileStore.persistUploadedFile(from: temporaryURL)
        let importer = LocalBookImporter()
        let payload = try await importer.importTemporaryFile(
            url: persistedFile.fileURL,
            bookNameHint: originalFileName.map { ($0 as NSString).deletingPathExtension }
        )
        return try persistImportedBook(payload, relativePath: persistedFile.relativePath, modelContext: modelContext)
    }

    private static func persistImportedBook(
        _ payload: LocalBookImportPayload,
        relativePath: String,
        modelContext: ModelContext
    ) throws -> BookEntity {
        let localBookURL = LocalBookSupport.makeBookURL(relativePath: relativePath)
        let detail = BookDetail(
            bookUrl: localBookURL,
            name: payload.detail.name,
            author: payload.detail.author,
            coverUrl: payload.detail.coverUrl,
            intro: payload.detail.intro,
            kind: payload.detail.kind,
            lastChapter: payload.chapters.last?.title,
            updateTime: payload.detail.updateTime,
            tocUrl: localBookURL,
            wordCount: payload.detail.wordCount,
            origin: LocalBookSupport.sourceURL
        )

        let cachedChapters = payload.chapters.enumerated().map { index, chapter in
            BookChapter(
                index: index,
                title: chapter.title,
                url: "local://chapter/\(index)",
                baseUrl: localBookURL,
                bookUrl: localBookURL
            )
        }

        let entity = BookEntity(detail: detail, sourceUrl: LocalBookSupport.sourceURL)
        entity.totalChapterCount = cachedChapters.count
        modelContext.insert(entity)

        if let data = try? JSONEncoder().encode(cachedChapters),
           let json = String(data: data, encoding: .utf8) {
            let key = TocCacheEntity.cacheKey(for: localBookURL)
            modelContext.insert(TocCacheEntity(cacheKey: key, bookUrl: localBookURL, chaptersJson: json))
        }

        let cacheKey = ChapterCacheStore.makeKey(sourceUrl: LocalBookSupport.sourceURL, bookUrl: localBookURL)
        for (index, content) in payload.contents.enumerated() {
            try ChapterCacheStore.saveSynchronously(bookKey: cacheKey, index: index, content: content)
        }

        try modelContext.save()
        NotificationCenter.default.post(name: .bookshelfDataDidChange, object: nil)
        return entity
    }
}
