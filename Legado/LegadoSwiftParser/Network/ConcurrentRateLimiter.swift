import Foundation

// MARK: - ConcurrentRateLimiter
/// 书源级并发/速率限制器，语义与 Android legado 的 `ConcurrentRateLimiter` 对齐。
public actor ConcurrentRateLimiter {

    private struct ConcurrentRecord {
        var isConcurrentWindow: Bool
        var windowStart: UInt64
        var frequency: Int
    }

    // MARK: - Properties

    private let sourceKey: String
    private let concurrentRate: String?

    // MARK: - Init

    public init(sourceKey: String, concurrentRate: String?) {
        self.sourceKey = sourceKey
        self.concurrentRate = concurrentRate
    }

    // MARK: - Public

    /// 等待至允许发起当前请求后执行异步操作。
    public func withLimit<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let recordKey = try await acquireRecord()
        do {
            let result = try await operation()
            if let recordKey {
                await Self.release(sourceKey: recordKey)
            }
            return result
        } catch {
            if let recordKey {
                await Self.release(sourceKey: recordKey)
            }
            throw error
        }
    }

    // MARK: - Acquire / Release

    private func acquireRecord() async throws -> String? {
        guard let parsedRate = ParsedRate(concurrentRate) else {
            return nil
        }

        while true {
            try Task.checkCancellation()
            let attempt = await Self.claim(sourceKey: sourceKey, rate: parsedRate)
            switch attempt {
            case .acquired:
                return sourceKey
            case .wait(let waitMs):
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(waitMs))
                try Task.checkCancellation()
            }
        }
    }

    private enum ClaimResult {
        case acquired
        case wait(UInt64)
    }

    private actor SharedStore {
        private var records: [String: ConcurrentRecord] = [:]

        func claim(sourceKey: String, rate: ParsedRate) async -> ClaimResult {
            let now = Self.currentTimeMilliseconds()

            guard var record = records[sourceKey] else {
                records[sourceKey] = ConcurrentRecord(
                    isConcurrentWindow: rate.isConcurrentWindow,
                    windowStart: now,
                    frequency: 1
                )
                return .acquired
            }

            switch rate {
            case .interval(let intervalMs):
                let nextAllowedTime = record.windowStart + intervalMs
                if now >= nextAllowedTime {
                    record.windowStart = now
                    record.frequency = 1
                    records[sourceKey] = record
                    return .acquired
                }

                if record.frequency > 0 {
                    return .wait(nextAllowedTime - now)
                }

                record.frequency = 1
                records[sourceKey] = record
                return .acquired

            case .window(let count, let windowMs):
                let nextAllowedTime = record.windowStart + windowMs
                if now >= nextAllowedTime {
                    record.windowStart = now
                    record.frequency = 1
                    records[sourceKey] = record
                    return .acquired
                }

                if record.frequency > count {
                    return .wait(nextAllowedTime - now)
                }

                record.frequency += 1
                records[sourceKey] = record
                return .acquired
            }
        }

        func release(sourceKey: String) {
            guard var record = records[sourceKey], !record.isConcurrentWindow else {
                return
            }
            record.frequency = max(0, record.frequency - 1)
            records[sourceKey] = record
        }

        private static func currentTimeMilliseconds() -> UInt64 {
            UInt64(Date().timeIntervalSince1970 * 1000)
        }
    }

    private static let sharedStore = SharedStore()

    private static func claim(sourceKey: String, rate: ParsedRate) async -> ClaimResult {
        await sharedStore.claim(sourceKey: sourceKey, rate: rate)
    }

    private static func release(sourceKey: String) async {
        await sharedStore.release(sourceKey: sourceKey)
    }
}

// MARK: - ParsedRate
/// `concurrentRate` 解析结果。
private enum ParsedRate {
    case interval(UInt64)
    case window(count: Int, windowMs: UInt64)

    nonisolated var isConcurrentWindow: Bool {
        if case .window = self {
            return true
        }
        return false
    }

    nonisolated init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0" else { return nil }

        if let slashIndex = trimmed.firstIndex(of: "/") {
            let countPart = trimmed[..<slashIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let windowPart = trimmed[trimmed.index(after: slashIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let count = Int(countPart), count > 0,
                  let windowMs = UInt64(windowPart), windowMs > 0 else {
                return nil
            }
            self = .window(count: count, windowMs: windowMs)
            return
        }

        guard let intervalMs = UInt64(trimmed), intervalMs > 0 else {
            return nil
        }
        self = .interval(intervalMs)
    }
}
