import XCTest
import Foundation
import Network
@testable import Legado

final class JavaBridgeFileBridgeTests: XCTestCase {
    override func setUpWithError() throws {
        try clearBridgeCache()
    }

    override func tearDownWithError() throws {
        try clearBridgeCache()
    }

    func testReadTxtFileDecodesRelativeLocalFileWithCharsetFallback() throws {
        let fileURL = bridgeRootURL()
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("chapter.txt")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try gb18030Data(for: "第一章 测试内容").write(to: fileURL)

        let bridge = makeBridge()
        let result = bridge.readTxtFile("fixtures/chapter.txt")

        XCTAssertEqual(result, "第一章 测试内容")
    }

    func testDownloadFileReturnsReadableRelativePathForHTTPScript() async throws {
        let server = try LocalHTTPTextServer(body: "console.log('phase7-file-bridge');", contentType: "application/javascript; charset=utf-8")
        try server.start()
        defer { server.stop() }

        let bridge = makeBridge()
        let relativePath = await callOnBackground {
            bridge.downloadFile(server.url.absoluteString)
        }

        XCTAssertFalse(relativePath.isEmpty)
        XCTAssertFalse(relativePath.hasPrefix(bridgeRootURL().path))
        XCTAssertEqual(bridge.readTxtFile(relativePath), "console.log('phase7-file-bridge');")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testCacheFileAndImportScriptReuseHTTPContentWithinRetentionWindow() async throws {
        let server = try LocalHTTPTextServer(body: "var imported = 42;", contentType: "application/javascript; charset=utf-8")
        try server.start()
        defer { server.stop() }

        let bridge = makeBridge()

        let first = await callOnBackground {
            bridge.cacheFile(server.url.absoluteString, 3600)
        }
        let second = await callOnBackground {
            bridge.importScript(server.url.absoluteString)
        }

        XCTAssertEqual(first, "var imported = 42;")
        XCTAssertEqual(second, "var imported = 42;")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testImportScriptSupportsLocalRelativePaths() throws {
        let fileURL = bridgeRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("helper.js")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "function helper(){return 1;}".data(using: .utf8)?.write(to: fileURL)

        let bridge = makeBridge()
        XCTAssertEqual(bridge.importScript("scripts/helper.js"), "function helper(){return 1;}")
    }

    private func makeBridge() -> JavaBridge {
        JavaBridge(
            baseUrl: "https://example.com",
            source: nil,
            variableStore: ParserVariableStore(writeScope: .source),
            requestURL: "https://example.com",
            requestHeaders: [:]
        )
    }

    private func bridgeRootURL() -> URL {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesURL.appendingPathComponent("JSBridgeCache", isDirectory: true)
    }

    private func clearBridgeCache() throws {
        let rootURL = bridgeRootURL()
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }

    private func gb18030Data(for string: String) throws -> Data {
        let encodingValue = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let encoding = String.Encoding(rawValue: encodingValue)
        guard let data = string.data(using: encoding) else {
            throw XCTSkip("Unable to encode GB18030 test fixture")
        }
        return data
    }

    private func callOnBackground<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }
}

private final class LocalHTTPTextServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Legado.tests.LocalHTTPTextServer")
    private let body: String
    private let contentType: String
    private let requestLock = NSLock()
    private var internalRequestCount = 0

    var requestCount: Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        return internalRequestCount
    }

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/script.js")!
    }

    init(body: String, contentType: String) throws {
        self.body = body
        self.contentType = contentType
        self.listener = try Self.makeListener()
    }

    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startupError = error
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            throw NSError(domain: "LocalHTTPTextServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listener startup timed out"])
        }
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.receive(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            self.requestLock.lock()
            self.internalRequestCount += 1
            self.requestLock.unlock()

            let bodyData = Data(self.body.utf8)
            let header = [
                "HTTP/1.1 200 OK",
                "Content-Type: \(self.contentType)",
                "Content-Length: \(bodyData.count)",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")
            var responseData = Data(header.utf8)
            responseData.append(bodyData)

            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func makeListener() throws -> NWListener {
        var lastError: Error?
        for portValue in UInt16(21000)...UInt16(21100) {
            do {
                return try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: portValue)!)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "LocalHTTPTextServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate test port"])
    }
}
