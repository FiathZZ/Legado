import Foundation

/// 跟踪单个 `WebBook` 生命周期内实际可用的书源入口。
///
/// Android legado 的很多规则会围绕当前可访问的源域名继续派生请求；
/// iOS 侧这里显式学习跳域后的新入口，供后续 header / cookie / JS `source.getKey()`
/// 与相对链接补全复用，避免后续请求又回落到导入时的旧域名。
nonisolated final class SourceRuntimeContext: @unchecked Sendable {
    private let lock = NSLock()
    private let originalSourceURL: String
    private var activeSourceURL: String

    init(sourceURL: String) {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originalSourceURL = trimmed
        self.activeSourceURL = trimmed
    }

    // 工程启用了默认 MainActor 隔离后，普通 class 的析构可能被放进并发运行时清理路径。
    // `SourceRuntimeContext` 只持有锁和字符串，不需要任何 actor/executor 参与释放；
    // 若让它走 `swift_task_deinitOnExecutorImpl`，在当前运行时下会再次触发
    // `TaskLocal::StopLookupScope` bad-free。
    nonisolated deinit {}

    var currentSourceURL: String {
        lock.lock()
        defer { lock.unlock() }
        return activeSourceURL.isEmpty ? originalSourceURL : activeSourceURL
    }

    @discardableResult
    func learn(from responseURL: URL?) -> Bool {
        guard let responseURL,
              let learnedSourceURL = Self.promotedSourceURL(from: responseURL.absoluteString) else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        let currentIdentity = Self.networkIdentity(for: activeSourceURL)
        let learnedIdentity = Self.networkIdentity(for: learnedSourceURL)

        guard !learnedSourceURL.isEmpty,
              activeSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentIdentity != learnedIdentity else {
            return false
        }

        activeSourceURL = learnedSourceURL
        return true
    }

    private static func promotedSourceURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""
        return components.string
    }

    private static func networkIdentity(for rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !scheme.isEmpty,
              !host.isEmpty else {
            return nil
        }

        let portSuffix = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portSuffix)"
    }
}
