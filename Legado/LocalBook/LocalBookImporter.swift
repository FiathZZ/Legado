import Foundation

final class LocalBookImporter {
    func importFile(url: URL) async throws -> (detail: BookDetail, chapters: [BookChapter], contents: [String]) {
        let payload = try await importPayload(
            url: url,
            bookNameHint: url.deletingPathExtension().lastPathComponent
        )
        return (payload.detail, payload.chapters, payload.contents)
    }

    func importTemporaryFile(url: URL, bookNameHint: String? = nil) async throws -> LocalBookImportPayload {
        try await importPayload(url: url, bookNameHint: bookNameHint)
    }

    private func importPayload(url: URL, bookNameHint: String?) async throws -> LocalBookImportPayload {
        switch url.pathExtension.lowercased() {
        case "txt":
            return try TXTParser().parse(fileURL: url, bookNameHint: bookNameHint)
        case "epub":
            return try EPUBParser().parse(fileURL: url, bookNameHint: bookNameHint)
        default:
            throw LocalBookImportError.unsupportedFileType
        }
    }
}
