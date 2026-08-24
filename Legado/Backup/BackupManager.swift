import Foundation
import SwiftData

@MainActor
final class BackupManager {
    func createBackup(modelContext: ModelContext) async throws -> URL {
        let encoder = BackupCoding.makeEncoder()
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legado-backup-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(makeBackupFileName(), isDirectory: false)

        if FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
            try FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let bookSources = try modelContext.fetch(FetchDescriptor<BookSourceEntity>(sortBy: [SortDescriptor(\.bookSourceName)]))
        let books = try modelContext.fetch(FetchDescriptor<BookEntity>(sortBy: [SortDescriptor(\.addedTime, order: .forward)]))
        let bookGroups = try modelContext.fetch(FetchDescriptor<BookGroup>(sortBy: [SortDescriptor(\.order, order: .forward)]))
        let bookmarks = try modelContext.fetch(
            FetchDescriptor<BookmarkEntity>(
                sortBy: [
                    SortDescriptor(\.chapterIndex, order: .forward),
                    SortDescriptor(\.time, order: .forward)
                ]
            )
        )
        let replaceRules = try modelContext.fetch(
            FetchDescriptor<ReplaceRuleEntity>(
                sortBy: [
                    SortDescriptor(\.order, order: .forward),
                    SortDescriptor(\.addedTime, order: .forward)
                ]
            )
        )

        let files = [
            (BackupJSONFile.bookSource, try encoder.encode(bookSources.map(BookSourceBackupRecord.init(entity:)))),
            (BackupJSONFile.bookshelf, try encoder.encode(books.map(BookBackupRecord.init(entity:)))),
            (BackupJSONFile.bookGroup, try encoder.encode(bookGroups.map(BookGroupBackupRecord.init(entity:)))),
            (BackupJSONFile.bookmark, try encoder.encode(bookmarks.map(BookmarkBackupRecord.init(entity:)))),
            (BackupJSONFile.replaceRule, try encoder.encode(replaceRules.map(ReplaceRuleBackupRecord.init(entity:))))
        ]

        var entries: [BackupArchiveEntry] = []
        for (fileName, data) in files {
            let fileURL = tempDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
            entries.append(BackupArchiveEntry(path: fileName, data: data))
        }

        try BackupZipArchive.createArchive(entries: entries, to: archiveURL)
        return archiveURL
    }

    private func makeBackupFileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Legado_backup_\(formatter.string(from: date)).zip"
    }
}
