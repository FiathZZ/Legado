import Foundation
#if canImport(Alamofire)
import Alamofire

nonisolated final class AlamofireTransport {
    private let requestTool = AlamofireRequestTool()

    init() {}

    func send(
        request: URLRequest,
        followRedirects: Bool,
        timeout: TimeInterval,
        enableCookieJar: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        try await requestTool.send(
            request: request,
            followRedirects: followRedirects,
            timeout: timeout,
            enableCookieJar: enableCookieJar
        )
    }

    func sendSync(
        request: URLRequest,
        followRedirects: Bool,
        timeout: TimeInterval,
        enableCookieJar: Bool
    ) throws -> (Data, HTTPURLResponse) {
        try requestTool.sendSync(
            request: request,
            followRedirects: followRedirects,
            timeout: timeout,
            enableCookieJar: enableCookieJar
        )
    }

    func shutdown() {
        requestTool.shutdown()
    }
}
#endif
