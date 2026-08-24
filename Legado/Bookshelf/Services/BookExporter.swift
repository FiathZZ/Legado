import Foundation
import SwiftData

final class BookExporter {
    private let modelContext: ModelContext?

    init(modelContext: ModelContext?) {
        self.modelContext = modelContext
    }

    func exportAsTXT(book: BookEntity, cacheStore: ChapterCacheStore = ChapterCacheStore()) async throws -> URL {
        let cachedEntries = ChapterCacheStore.cachedChapterContents(bookKey: chapterCacheKey(for: book))
        guard !cachedEntries.isEmpty else {
            throw LocalBookImportError.missingCachedChapters
        }

        let titles = chapterTitles(for: book)
        var chunks: [String] = []
        for entry in cachedEntries {
            let title = titles[safe: entry.index] ?? "第\(entry.index + 1)章"
            chunks.append(title)
            chunks.append(entry.content)
            chunks.append("")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitizedFileName(book.name)).txt", isDirectory: false)
        try chunks.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func exportAsEPUB(book: BookEntity, cacheStore: ChapterCacheStore = ChapterCacheStore()) async throws -> URL {
        let cachedEntries = ChapterCacheStore.cachedChapterContents(bookKey: chapterCacheKey(for: book))
        guard !cachedEntries.isEmpty else {
            throw LocalBookImportError.missingCachedChapters
        }

        let titles = chapterTitles(for: book)
        var entries: [BackupArchiveEntry] = [
            BackupArchiveEntry(path: "mimetype", data: Data("application/epub+zip".utf8)),
            BackupArchiveEntry(
                path: "META-INF/container.xml",
                data: Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """.utf8
                )
            )
        ]

        var manifestItems: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        ]
        var spineItems: [String] = []
        var navLinks: [String] = []

        for entry in cachedEntries {
            let title = titles[safe: entry.index] ?? "第\(entry.index + 1)章"
            let fileName = "Text/chapter-\(entry.index + 1).xhtml"
            let itemID = "chapter\(entry.index + 1)"
            manifestItems.append(#"<item id="\#(itemID)" href="\#(fileName)" media-type="application/xhtml+xml"/>"#)
            spineItems.append(#"<itemref idref="\#(itemID)"/>"#)
            navLinks.append(#"<li><a href="\#(fileName)">\#(escapeXML(title))</a></li>"#)
            entries.append(
                BackupArchiveEntry(
                    path: "EPUB/\(fileName)",
                    data: Data(chapterDocument(title: title, content: entry.content).utf8)
                )
            )
        }

        let navDocument = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>目录</title></head>
        <body>
        <nav epub:type="toc" id="toc">
          <h1>目录</h1>
          <ol>\(navLinks.joined())</ol>
        </nav>
        </body>
        </html>
        """
        entries.append(BackupArchiveEntry(path: "EPUB/nav.xhtml", data: Data(navDocument.utf8)))

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(escapeXML(book.bookUrl))</dc:identifier>
            <dc:title>\(escapeXML(book.name))</dc:title>
            <dc:creator>\(escapeXML(book.author))</dc:creator>
            <dc:language>zh-CN</dc:language>
          </metadata>
          <manifest>\(manifestItems.joined())</manifest>
          <spine>\(spineItems.joined())</spine>
        </package>
        """
        entries.append(BackupArchiveEntry(path: "EPUB/content.opf", data: Data(opf.utf8)))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitizedFileName(book.name)).epub", isDirectory: false)
        try BackupZipArchive.createArchive(entries: entries, to: outputURL)
        return outputURL
    }

    private func chapterTitles(for book: BookEntity) -> [String] {
        guard let modelContext else { return [] }
        let key = TocCacheEntity.cacheKey(for: book.bookUrl)
        let descriptor = FetchDescriptor<TocCacheEntity>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        return (try? modelContext.fetch(descriptor).first?.toChapters()?.map(\.title)) ?? []
    }

    private func chapterCacheKey(for book: BookEntity) -> String {
        ChapterCacheStore.makeKey(sourceUrl: book.sourceUrl, bookUrl: book.bookUrl)
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = name.components(separatedBy: invalidCharacters).filter { !$0.isEmpty }
        return components.isEmpty ? "LegadoBook" : components.joined(separator: "_")
    }

    private func chapterDocument(title: String, content: String) -> String {
        let paragraphs = content
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "<p>\(escapeXML($0))</p>" }
            .joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(escapeXML(title))</title></head>
        <body><h1>\(escapeXML(title))</h1>\(paragraphs)</body>
        </html>
        """
    }

    private func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
