import Foundation
import SwiftData
import CommonCrypto

// MARK: - TocCacheEntity
/// 书籍目录缓存实体，使用 SwiftData 持久化章节列表 JSON。
@Model
final class TocCacheEntity {
    @Attribute(.unique) var cacheKey: String
    var bookUrl: String
    var chaptersJson: String
    var cachedAt: Date

    init(cacheKey: String, bookUrl: String, chaptersJson: String, cachedAt: Date = .now) {
        self.cacheKey = cacheKey
        self.bookUrl = bookUrl
        self.chaptersJson = chaptersJson
        self.cachedAt = cachedAt
    }

    func toChapters() -> [BookChapter]? {
        guard let data = chaptersJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([BookChapter].self, from: data)
    }

    static func cacheKey(for bookUrl: String) -> String {
        let data = Data(bookUrl.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
