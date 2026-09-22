import Foundation
import SwiftData
import CommonCrypto

/// Coalesces high-frequency reader position changes into at most one persistent write per
/// interval. The newest position is retained, and lifecycle transitions can flush it at once.
@MainActor
final class ReaderProgressSaveCoordinator {
    private let interval: Duration
    private var pendingPosition: ReaderPosition?
    private var scheduledSave: Task<Void, Never>?

    init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    func schedule(
        position: ReaderPosition,
        persist: @escaping (ReaderPosition) -> Void
    ) {
        pendingPosition = position
        guard scheduledSave == nil else { return }

        scheduledSave = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled,
                  let position = pendingPosition else {
                return
            }
            pendingPosition = nil
            scheduledSave = nil
            persist(position)
        }
    }

    func flush(
        fallbackPosition: ReaderPosition?,
        persist: (ReaderPosition?) -> Void
    ) {
        scheduledSave?.cancel()
        scheduledSave = nil
        let position = pendingPosition ?? fallbackPosition
        pendingPosition = nil
        persist(position)
    }

    /// Flushes a lifecycle/explicit-navigation position. The caller's position was sampled
    /// after the latest visible-row commit, so it must win over any older queued callback.
    func flushLatest(
        position: ReaderPosition,
        persist: (ReaderPosition) -> Void
    ) {
        scheduledSave?.cancel()
        scheduledSave = nil
        pendingPosition = nil
        persist(position)
    }

    deinit {
        scheduledSave?.cancel()
    }
}

@MainActor
struct ReaderProgressService {
    private let defaults = UserDefaults.standard
    private let positionKeyPrefix = "reader.progress.position."
    private let progressDirectoryName = "ReaderProgress"

    func saveReadingProgress(
        bookEntity: BookEntity?,
        chapters: [BookChapter],
        currentIndex: Int,
        currentPosition: ReaderPosition? = nil,
        bookURL: String,
        modelContext: ModelContext?
    ) {
        let chapterIndex = currentPosition?.chapterIndex ?? currentIndex
        if let bookEntity {
            bookEntity.currentChapterIndex = chapterIndex
            bookEntity.currentChapterName = chapters[safe: chapterIndex]?.title
            bookEntity.lastReadTime = Date()
            bookEntity.hasNewChapter = false
            try? modelContext?.save()
        }

        let persistedPosition = currentPosition ?? ReaderPosition(chapterIndex: chapterIndex)
        if let data = try? JSONEncoder().encode(persistedPosition) {
            defaults.set(data, forKey: positionKey(for: bookURL))
            try? data.write(to: progressFileURL(for: bookURL), options: [.atomic])
        }
    }

    func restoreReadingProgress(bookURL: String, fallbackChapterIndex: Int) -> ReaderPosition {
        guard !bookURL.isEmpty else {
            return ReaderPosition(chapterIndex: fallbackChapterIndex)
        }
        let persistedData = (try? Data(contentsOf: progressFileURL(for: bookURL)))
            ?? defaults.data(forKey: positionKey(for: bookURL))
        guard let persistedData,
              let position = try? JSONDecoder().decode(ReaderPosition.self, from: persistedData) else {
            return ReaderPosition(chapterIndex: fallbackChapterIndex)
        }
        return position
    }

    private func positionKey(for bookURL: String) -> String {
        positionKeyPrefix + bookURL
    }

    private func progressFileURL(for bookURL: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(progressDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(stableKey(for: bookURL)).json")
    }

    private func stableKey(for bookURL: String) -> String {
        let data = Data(bookURL.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
