import XCTest
@testable import Legado

final class RequestExecutorV2RuntimeTests: XCTestCase {
    private final class AttemptProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var attemptCount = 0

        func incrementAttempt() -> Int {
            lock.lock()
            attemptCount += 1
            let current = attemptCount
            lock.unlock()
            return current
        }

        func snapshotAttemptCount() -> Int {
            lock.lock()
            let snapshot = attemptCount
            lock.unlock()
            return snapshot
        }
    }

    func testExecutorBuildsUnifiedResponseContextAndTrace() async throws {
        let trace = RuntimeTraceV2()
        let source = BookSource(
            bookSourceName: "test",
            bookSourceUrl: "https://origin.example.com",
            header: "{\"X-Source\":\"source-header\"}",
            cookieJar: "token=abc123"
        )
        let runtime = AnalyzeUrlV2(
            rule: "/search,{\"method\":\"POST\",\"body\":\"keyword={{key}}\",\"charset\":\"gbk\",\"retry\":1}",
            key: "斗罗大陆",
            baseUrl: source.bookSourceUrl,
            source: source
        )
        let requestContext = LegadoRequestContextV2(
            source: source,
            maximumRequestTimeout: 30,
            runtimeTrace: trace
        )
        let mirroredSearchURL = URL(string: "https://mirror.example.com/search")!
        let originalSearchURL = URL(string: "https://origin.example.com/search")!
        let mirroredResponse = HTTPResponse(
            data: Data("ok".utf8),
            statusCode: 200,
            headers: ["Content-Type": "text/plain"],
            url: mirroredSearchURL,
            requestURL: originalSearchURL,
            message: "OK"
        )
        let executor = RequestExecutorV2(
            httpClient: HTTPClient(),
            cookieJarEnabled: true,
            httpSender: { _, _ in
                return mirroredResponse
            }
        )

        let execution = try await executor.execute(
            analyzeUrlRuntime: runtime,
            context: requestContext,
            transportPreference: .preferThirdParty,
            timeout: 12
        )

        let responseContext = execution.responseContext
        XCTAssertEqual(responseContext.transportKind, .http)
        XCTAssertEqual(responseContext.attemptCount, 1)
        XCTAssertEqual(responseContext.requestUrl, "https://origin.example.com/search")
        XCTAssertEqual(responseContext.responseUrl, "https://mirror.example.com/search")
        XCTAssertTrue(responseContext.wasRedirected)
        XCTAssertEqual(responseContext.charset.uppercased(), "GBK")
        XCTAssertEqual(responseContext.responseType, nil)
        XCTAssertEqual(responseContext.statusCode, 200)
        XCTAssertEqual(responseContext.text, "ok")
        XCTAssertEqual(responseContext.descriptor.method, "POST")
        XCTAssertEqual(responseContext.descriptor.charset.uppercased(), "GBK")
        XCTAssertEqual(responseContext.descriptor.headerKeys, ["Content-Type", "X-Source"])
        XCTAssertEqual(responseContext.descriptor.sourceHeaderKeys, ["X-Source"])
        XCTAssertEqual(responseContext.descriptor.bodyPreview, "keyword=%B6%B7%C2%DE%B4%F3%C2%BD")
        XCTAssertGreaterThan(responseContext.descriptor.bodyLength, 0)

        let descriptors = trace.drain()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.retryCount, 1)
        XCTAssertEqual(descriptors.first?.headerKeys, ["Content-Type", "X-Source"])
        XCTAssertEqual(descriptors.first?.sourceHeaderKeys, ["X-Source"])

        let responses = trace.drainResponses()
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.transportKind, "http")
        XCTAssertEqual(responses.first?.attemptCount, 1)
        XCTAssertEqual(responses.first?.responseUrl, "https://mirror.example.com/search")
    }

    func testExecutorRetriesAndNormalizesHexResponse() async throws {
        let source = BookSource(bookSourceName: "test", bookSourceUrl: "https://origin.example.com")
        let runtime = AnalyzeUrlV2(
            rule: "/bytes,{\"retry\":2,\"type\":\"hex\"}",
            baseUrl: source.bookSourceUrl,
            source: source
        )
        let requestContext = LegadoRequestContextV2(source: source, maximumRequestTimeout: 30)

        let probe = AttemptProbe()
        let bytesURL = URL(string: "https://origin.example.com/bytes")!
        let executor = RequestExecutorV2(
            httpClient: HTTPClient(),
            cookieJarEnabled: true,
            httpSender: { _, _ in
                let attempt = probe.incrementAttempt()
                if attempt == 1 {
                    throw ParserError.networkError("temporary failure")
                }
                return HTTPResponse(
                    data: Data([0x41, 0x42, 0x43]),
                    statusCode: 200,
                    headers: ["Content-Type": "application/octet-stream"],
                    url: bytesURL,
                    requestURL: bytesURL,
                    message: "OK"
                )
            }
        )

        let execution = try await executor.execute(
            analyzeUrlRuntime: runtime,
            context: requestContext
        )

        XCTAssertEqual(probe.snapshotAttemptCount(), 2)
        XCTAssertEqual(execution.responseContext.attemptCount, 2)
        XCTAssertEqual(execution.responseContext.transportKind, .http)
        XCTAssertEqual(execution.responseContext.text, "414243")
        XCTAssertEqual(execution.responseContext.responseType, "hex")
    }
}
