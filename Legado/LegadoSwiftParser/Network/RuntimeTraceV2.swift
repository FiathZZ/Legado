import Foundation

// MARK: - RuntimeTraceV2

/// V2 请求 trace 收集器。
///
/// H1 先把 trace 从旧 `HTTPClient.swift` 里的内嵌实现显式包装出来，
/// 后续 V2 executor / WebBookV2 都通过这层记录请求链，而不是继续直接依赖旧 TaskLocal 名称。
nonisolated final class RuntimeTraceCollectorV2: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [LegadoRequestDescriptorV2] = []
    private var responseSummaries: [LegadoResponseContextV2.TraceSummary] = []

    init() {}

    // 这些 V2 trace collector 只持有锁和纯值数组，不需要回到任何 actor / executor 才能析构。
    // 在默认 MainActor 隔离工程里，若让它走并发运行时的 deinit 路径，测试阶段短生命周期创建/销毁
    // 仍可能重新撞到 `TaskLocal::StopLookupScope` 的坏释放。这里显式保持析构为 nonisolated。
    nonisolated deinit {}

    func append(_ descriptor: LegadoRequestDescriptorV2) {
        lock.lock()
        descriptors.append(descriptor)
        lock.unlock()
    }

    func drain() -> [LegadoRequestDescriptorV2] {
        lock.lock()
        let current = descriptors
        descriptors.removeAll(keepingCapacity: true)
        lock.unlock()
        return current
    }

    func appendResponse(_ summary: LegadoResponseContextV2.TraceSummary) {
        lock.lock()
        responseSummaries.append(summary)
        lock.unlock()
    }

    func drainResponses() -> [LegadoResponseContextV2.TraceSummary] {
        lock.lock()
        let current = responseSummaries
        responseSummaries.removeAll(keepingCapacity: true)
        lock.unlock()
        return current
    }
}

/// V2 runtime trace 句柄。
nonisolated struct RuntimeTraceV2: Sendable {
    let collector: RuntimeTraceCollectorV2

    init(collector: RuntimeTraceCollectorV2 = RuntimeTraceCollectorV2()) {
        self.collector = collector
    }

    func record(_ descriptor: LegadoRequestDescriptorV2) {
        collector.append(descriptor)
    }

    func recordResponse(_ summary: LegadoResponseContextV2.TraceSummary, for descriptor: LegadoRequestDescriptorV2) {
        ParserLog.debug(
            "RuntimeTraceV2",
            "request=\(descriptor.method) \(descriptor.resolvedURL) transport=\(summary.transportKind) status=\(summary.statusCode) redirected=\(summary.wasRedirected) attempts=\(summary.attemptCount)"
        )
        collector.appendResponse(summary)
    }

    func drain() -> [LegadoRequestDescriptorV2] {
        collector.drain()
    }

    func drainResponses() -> [LegadoResponseContextV2.TraceSummary] {
        collector.drainResponses()
    }
}
