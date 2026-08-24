import Foundation
import SwiftSoup

struct EPUBParser {
    private struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: String
    }

    func parse(fileURL: URL, bookNameHint: String? = nil) throws -> LocalBookImportPayload {
        let extractionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legado-epub-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: extractionURL)
        try FileManager.default.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractionURL) }

        try BackupZipArchive.extractArchive(at: fileURL, to: extractionURL)

        let containerURL = extractionURL.appendingPathComponent("META-INF/container.xml", isDirectory: false)
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw LocalBookImportError.missingEPUBContainer
        }

        let containerText = try String(contentsOf: containerURL, encoding: .utf8)
        let containerDoc = try SwiftSoup.parse(containerText, "", Parser.xmlParser())
        guard let rootfilePath = try containerDoc.select("rootfile").first()?.attr("full-path"),
              !rootfilePath.isEmpty else {
            throw LocalBookImportError.missingEPUBPackage
        }

        let packageURL = extractionURL.appendingPathComponent(rootfilePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw LocalBookImportError.missingEPUBPackage
        }

        let packageText = try String(contentsOf: packageURL, encoding: .utf8)
        let packageDoc = try SwiftSoup.parse(packageText, "", Parser.xmlParser())
        let packageDirectory = packageURL.deletingLastPathComponent()

        let fallbackBookName = sanitizedBookName(bookNameHint) ?? fileURL.deletingPathExtension().lastPathComponent
        let title = try firstText(in: packageDoc, names: ["dc:title", "title"]) ?? fallbackBookName
        let author = try firstText(in: packageDoc, names: ["dc:creator", "creator"]) ?? "未知"

        let manifestItems = try packageDoc.select("manifest > item").map { element in
            ManifestItem(
                id: try element.attr("id"),
                href: try element.attr("href"),
                mediaType: try element.attr("media-type"),
                properties: try element.attr("properties")
            )
        }
        let manifest = Dictionary(uniqueKeysWithValues: manifestItems.map { ($0.id, $0) })
        let spineIDs = try packageDoc.select("spine > itemref").map { try $0.attr("idref") }

        var coverURLString: String?
        if let coverItem = try resolveCoverItem(in: packageDoc, manifest: manifest),
           let savedCoverURL = try saveCover(from: coverItem, packageDirectory: packageDirectory) {
            coverURLString = savedCoverURL.absoluteString
        }

        var chapters: [BookChapter] = []
        var contents: [String] = []
        for spineID in spineIDs {
            guard let manifestItem = manifest[spineID] else { continue }
            guard manifestItem.mediaType.contains("html") || manifestItem.href.lowercased().hasSuffix(".xhtml") else {
                continue
            }

            let chapterURL = packageDirectory.appendingPathComponent(manifestItem.href, isDirectory: false)
            guard let chapterText = try loadText(at: chapterURL) else { continue }
            let chapterDoc = try SwiftSoup.parse(chapterText, chapterURL.deletingLastPathComponent().absoluteString)
            let chapterTitle = try chapterDoc.select("title").first()?.text()
                ?? chapterDoc.select("h1, h2, h3").first()?.text()
                ?? chapterURL.deletingPathExtension().lastPathComponent
            let chapterHTML = try chapterDoc.body()?.html() ?? chapterText
            let content = HtmlFormatter.format(chapterHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let index = chapters.count
            chapters.append(BookChapter(index: index, title: chapterTitle, url: "", baseUrl: "", bookUrl: ""))
            contents.append(content)
        }

        guard !contents.isEmpty else {
            throw LocalBookImportError.emptyBookContent
        }

        let detail = BookDetail(
            bookUrl: "",
            name: title,
            author: author,
            coverUrl: coverURLString,
            intro: "本地 EPUB 导入",
            kind: "EPUB",
            lastChapter: chapters.last?.title,
            wordCount: "\(contents.reduce(0) { $0 + $1.count })",
            origin: LocalBookSupport.sourceURL
        )
        return LocalBookImportPayload(detail: detail, chapters: chapters, contents: contents)
    }

    private func sanitizedBookName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstText(in document: Document, names: [String]) throws -> String? {
        for name in names {
            if let text = try document.select(name).first()?.text(), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func resolveCoverItem(in document: Document, manifest: [String: ManifestItem]) throws -> ManifestItem? {
        if let coverID = try document.select("meta[name=cover]").first()?.attr("content"),
           let item = manifest[coverID] {
            return item
        }
        return manifest.values.first(where: { $0.properties.contains("cover-image") })
    }

    private func saveCover(from item: ManifestItem, packageDirectory: URL) throws -> URL? {
        let coverURL = packageDirectory.appendingPathComponent(item.href, isDirectory: false)
        guard FileManager.default.fileExists(atPath: coverURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: coverURL)
        let ext = coverURL.pathExtension.isEmpty ? "jpg" : coverURL.pathExtension
        return try LocalBookFileStore.saveCover(data: data, preferredExtension: ext)
    }

    private func loadText(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return LocalBookTextDecoder.decode(data)
    }
}
