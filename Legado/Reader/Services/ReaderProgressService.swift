import Foundation
import SwiftData
import CommonCrypto

/// 阅读进度落盘目录（`Application Support/ReaderProgress`）。读写两条路径共用，保证指向同一处。
private let readerProgressDirectoryName = "ReaderProgress"

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
        guard let data = try? JSONEncoder().encode(persistedPosition) else { return }
        
        // UserDefaults 留在主线程同步写：它本身很轻，而 `restoreReadingProgress` 会优先读它，
        // 所以退出时的 flush 立刻就能生效 —— 进度不会因为后台落盘还没跑完而丢。
        defaults.set(data, forKey: positionKey(for: bookURL))
        
        // 目录创建 + SHA256 + 原子文件写入是真正的磁盘 IO，挪到主线程之外串行执行，
        // 不再让每次翻页/滚动落盘都卡一下主线程。
        Task.detached(priority: .utility) {
            await ReaderProgressFileWriter.shared.write(data, bookURL: bookURL)
        }
    }

    func restoreReadingProgress(bookURL: String, fallbackChapterIndex: Int) -> ReaderPosition {
        guard !bookURL.isEmpty else {
            return ReaderPosition(chapterIndex: fallbackChapterIndex)
        }
        // UserDefaults 优先：它是同步写入的，而文件落盘已经挪到后台串行执行，
        // 退出瞬间可能还没写完。写入顺序保证 UserDefaults 不会比文件旧，
        // 文件只作为 UserDefaults 被系统清理时的兜底。
        let persistedData = defaults.data(forKey: positionKey(for: bookURL))
            ?? (try? Data(contentsOf: progressFileURL(for: bookURL)))
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
        
        let directory = ReaderProgressFileWriter.progressDirectory()
        
        // 读取路径上目录通常已经存在，这里只是兜底
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        return directory.appendingPathComponent("\(ReaderProgressFileWriter.stableKey(for: bookURL)).json")
    }
}

/// 阅读进度文件的串行写入器。
///
/// 落盘放在 `@MainActor` 之外，避免每次翻页/滚动都阻塞主线程；
/// 用 actor 串行化，保证连续两次保存不会因为并发完成顺序错乱而让旧数据覆盖新数据。
private actor ReaderProgressFileWriter {
    
    static let shared = ReaderProgressFileWriter()
    
    func write(_ data: Data, bookURL: String) {
        
        let directory = Self.progressDirectory()
        
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        let url = directory.appendingPathComponent("\(Self.stableKey(for: bookURL)).json")
        
        try? data.write(to: url, options: [.atomic])
    }
    
    /// 进度文件所在目录。读取路径（主线程）也用它，保证读写指向同一个位置。
    nonisolated static func progressDirectory() -> URL {
        
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        
        return base.appendingPathComponent(readerProgressDirectoryName, isDirectory: true)
    }
    
    /// 用 SHA256 把 bookURL 折成稳定的文件名。
    nonisolated static func stableKey(for bookURL: String) -> String {
        
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
