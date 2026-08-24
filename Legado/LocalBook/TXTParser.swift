import Foundation

struct TXTParser {
    private let chapterPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^第[零一二三四五六七八九十百千万\d]+[章节回卷集部篇]"#, options: [.anchorsMatchLines]),
        try! NSRegularExpression(pattern: #"^Chapter\s+\d+"#, options: [.anchorsMatchLines, .caseInsensitive]),
        try! NSRegularExpression(pattern: #"^卷[零一二三四五六七八九十百千万\d]+"#, options: [.anchorsMatchLines])
    ]

    func parse(fileURL: URL, bookNameHint: String? = nil) throws -> LocalBookImportPayload {
        let data = try Data(contentsOf: fileURL)
        guard let decoded = LocalBookTextDecoder.decode(data) else {
            throw LocalBookImportError.decodeFailed
        }

        let normalized = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalBookImportError.emptyBookContent
        }

        let fileBaseName = sanitizedBookName(bookNameHint) ?? fileURL.deletingPathExtension().lastPathComponent
        let split = splitChapters(in: normalized)
        let detail = BookDetail(
            bookUrl: "",
            name: fileBaseName,
            author: "未知",
            intro: "本地 TXT 导入",
            kind: "TXT",
            lastChapter: split.chapters.last?.title,
            wordCount: "\(normalized.count)",
            origin: LocalBookSupport.sourceURL
        )
        return LocalBookImportPayload(detail: detail, chapters: split.chapters, contents: split.contents)
    }

    private func sanitizedBookName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func splitChapters(in text: String) -> (chapters: [BookChapter], contents: [String]) {
        let lines = text.components(separatedBy: "\n")
        var chapters: [BookChapter] = []
        var contents: [String] = []
        var currentTitle = "开始"
        var buffer: [String] = []
        var matchedHeading = false

        func flush() {
            let content = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            let index = chapters.count
            chapters.append(BookChapter(index: index, title: currentTitle, url: "", baseUrl: "", bookUrl: ""))
            contents.append(content)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isChapterHeading(trimmed) {
                matchedHeading = true
                flush()
                currentTitle = trimmed
                buffer = []
            } else {
                buffer.append(line)
            }
        }
        flush()

        if matchedHeading, !chapters.isEmpty {
            return (chapters, contents)
        }

        chapters.removeAll()
        contents.removeAll()
        let chunkSize = 5000
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text.index(cursor, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let content = String(text[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                let index = chapters.count
                chapters.append(BookChapter(index: index, title: "第\(index + 1)章", url: "", baseUrl: "", bookUrl: ""))
                contents.append(content)
            }
            cursor = end
        }
        return (chapters, contents)
    }

    private func isChapterHeading(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let range = NSRange(location: 0, length: line.utf16.count)
        return chapterPatterns.contains { regex in
            regex.firstMatch(in: line, options: [], range: range) != nil
        }
    }
}
