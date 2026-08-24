import Foundation
import SwiftData

@MainActor
final class RestoreManager {
    func restoreFromBackup(url: URL, modelContext: ModelContext) async throws {
        let decoder = BackupCoding.makeDecoder()
        let extractedDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legado-restore-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: extractedDirectoryURL.path) {
            try FileManager.default.removeItem(at: extractedDirectoryURL)
        }
        try FileManager.default.createDirectory(at: extractedDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractedDirectoryURL) }

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try BackupZipArchive.extractArchive(at: url, to: extractedDirectoryURL)

        if let records: [BookSourceBackupRecord] = try decodeRecords(
            named: BackupJSONFile.bookSource,
            in: extractedDirectoryURL,
            decoder: decoder
        ) {
            try mergeBookSources(records, in: modelContext)
        }

        if let records: [BookBackupRecord] = try decodeRecords(
            named: BackupJSONFile.bookshelf,
            in: extractedDirectoryURL,
            decoder: decoder
        ) {
            try mergeBooks(records, in: modelContext)
        }

        if let records: [BookGroupBackupRecord] = try decodeRecords(
            named: BackupJSONFile.bookGroup,
            in: extractedDirectoryURL,
            decoder: decoder
        ) {
            try mergeBookGroups(records, in: modelContext)
        }

        if let records: [BookmarkBackupRecord] = try decodeRecords(
            named: BackupJSONFile.bookmark,
            in: extractedDirectoryURL,
            decoder: decoder
        ) {
            try mergeBookmarks(records, in: modelContext)
        }

        if let records: [ReplaceRuleBackupRecord] = try decodeRecords(
            named: BackupJSONFile.replaceRule,
            in: extractedDirectoryURL,
            decoder: decoder
        ) {
            try mergeReplaceRules(records, in: modelContext)
        }

        try modelContext.save()
    }

    private func decodeRecords<T: Decodable>(
        named fileName: String,
        in directoryURL: URL,
        decoder: JSONDecoder
    ) throws -> T? {
        let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(T.self, from: data)
    }

    private func mergeBookSources(_ records: [BookSourceBackupRecord], in modelContext: ModelContext) throws {
        let entities = try modelContext.fetch(FetchDescriptor<BookSourceEntity>())
        var entitiesByURL = Dictionary(uniqueKeysWithValues: entities.map { ($0.bookSourceUrl, $0) })

        for record in records {
            if let existing = entitiesByURL[record.bookSourceUrl] {
                record.apply(to: existing)
            } else {
                let entity = record.makeEntity()
                modelContext.insert(entity)
                entitiesByURL[record.bookSourceUrl] = entity
            }
        }
    }

    private func mergeBooks(_ records: [BookBackupRecord], in modelContext: ModelContext) throws {
        let entities = try modelContext.fetch(FetchDescriptor<BookEntity>())
        var entitiesByURL = Dictionary(uniqueKeysWithValues: entities.map { ($0.bookUrl, $0) })

        for record in records {
            if let existing = entitiesByURL[record.bookUrl] {
                record.apply(to: existing)
            } else {
                let entity = record.makeEntity()
                modelContext.insert(entity)
                entitiesByURL[record.bookUrl] = entity
            }
        }
    }

    private func mergeBookGroups(_ records: [BookGroupBackupRecord], in modelContext: ModelContext) throws {
        let entities = try modelContext.fetch(FetchDescriptor<BookGroup>())
        var entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.groupId, $0) })

        for record in records {
            if let existing = entitiesByID[record.groupId] {
                record.apply(to: existing)
            } else {
                let entity = record.makeEntity()
                modelContext.insert(entity)
                entitiesByID[record.groupId] = entity
            }
        }
    }

    private func mergeBookmarks(_ records: [BookmarkBackupRecord], in modelContext: ModelContext) throws {
        let entities = try modelContext.fetch(FetchDescriptor<BookmarkEntity>())
        var entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        for record in records {
            if let existing = entitiesByID[record.id] {
                record.apply(to: existing)
            } else {
                let entity = record.makeEntity()
                modelContext.insert(entity)
                entitiesByID[record.id] = entity
            }
        }
    }

    private func mergeReplaceRules(_ records: [ReplaceRuleBackupRecord], in modelContext: ModelContext) throws {
        let entities = try modelContext.fetch(FetchDescriptor<ReplaceRuleEntity>())
        var entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        for record in records {
            if let existing = entitiesByID[record.id] {
                record.apply(to: existing)
            } else {
                let entity = record.makeEntity()
                modelContext.insert(entity)
                entitiesByID[record.id] = entity
            }
        }
    }
}
