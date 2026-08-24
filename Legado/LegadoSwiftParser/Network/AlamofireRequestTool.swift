import Foundation
#if canImport(Alamofire)
@preconcurrency import Alamofire

private nonisolated struct AlamofireSessionKey: Hashable {
    let followRedirects: Bool
    let timeoutMillis: Int
}

/// Prevents new Alamofire requests from being admitted after shutdown starts.
/// Existing requests are cancelled by the owning Session. We intentionally let the
/// URLSession drain instead of invalidating it while Alamofire may still be creating
/// the underlying task.
nonisolated final class AlamofireRequestCreationGate {
    private let lock = NSLock()
    private var isShutdown = false

    func withRequestCreation<Value>(_ body: () -> Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutdown else { return nil }
        return body()
    }

    func shutdown() {
        lock.lock()
        isShutdown = true
        lock.unlock()
    }
}

private nonisolated final class LenientServerTrustManager: ServerTrustManager, @unchecked Sendable {
    private let evaluator: any ServerTrustEvaluating = DisabledTrustEvaluator()

    nonisolated override init(
        allHostsMustBeEvaluated: Bool = false,
        evaluators: [String: any ServerTrustEvaluating] = [:]
    ) {
        super.init(allHostsMustBeEvaluated: false, evaluators: [:])
    }

    nonisolated override func serverTrustEvaluator(forHost host: String) throws -> (any ServerTrustEvaluating)? {
        evaluator
    }
}

private nonisolated struct AlamofireRedirectHandler: RedirectHandler {
    let followRedirects: Bool

    func task(
        _ task: URLSessionTask,
        willBeRedirectedTo request: URLRequest,
        for response: HTTPURLResponse,
        completion: @escaping (URLRequest?) -> Void
    ) {
        guard followRedirects else {
            completion(nil)
            return
        }

        completion(adaptedRedirectRequest(for: task, redirectRequest: request, response: response))
    }

    private func adaptedRedirectRequest(
        for task: URLSessionTask,
        redirectRequest: URLRequest,
        response: HTTPURLResponse
    ) -> URLRequest {
        guard let originalRequest = task.originalRequest,
              let originalMethod = originalRequest.httpMethod?.uppercased() else {
            return redirectRequest
        }

        var adaptedRequest = redirectRequest
        let statusCode = response.statusCode
        let shouldKeepBody = preservesBodyOnRedirect(method: originalMethod, statusCode: statusCode)

        if permitsRequestBody(method: originalMethod) {
            if redirectsToGET(method: originalMethod, statusCode: statusCode) {
                adaptedRequest.httpMethod = HTTPMethod.get.rawValue
                adaptedRequest.httpBody = nil
                removeBodyHeaders(from: &adaptedRequest)
            } else {
                adaptedRequest.httpMethod = originalMethod
                adaptedRequest.httpBody = shouldKeepBody ? originalRequest.httpBody : nil
                if shouldKeepBody {
                    if adaptedRequest.value(forHTTPHeaderField: "Content-Type") == nil,
                       let contentType = originalRequest.value(forHTTPHeaderField: "Content-Type") {
                        adaptedRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
                    }
                    if adaptedRequest.value(forHTTPHeaderField: "Content-Length") == nil,
                       let body = originalRequest.httpBody,
                       !body.isEmpty {
                        adaptedRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
                    }
                } else {
                    removeBodyHeaders(from: &adaptedRequest)
                }
            }
        } else {
            adaptedRequest.httpMethod = originalMethod
        }

        if !isSameConnection(from: originalRequest.url, to: adaptedRequest.url) {
            adaptedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        }

        return adaptedRequest
    }

    private func permitsRequestBody(method: String) -> Bool {
        switch method.uppercased() {
        case HTTPMethod.get.rawValue, HTTPMethod.head.rawValue:
            return false
        default:
            return true
        }
    }

    private func preservesBodyOnRedirect(method: String, statusCode: Int) -> Bool {
        redirectsWithBody(method: method) || statusCode == 307 || statusCode == 308
    }

    private func redirectsToGET(method: String, statusCode: Int) -> Bool {
        statusCode != 307 && statusCode != 308 && !redirectsWithBody(method: method)
    }

    private func redirectsWithBody(method: String) -> Bool {
        method.caseInsensitiveCompare("PROPFIND") == .orderedSame
    }

    private func removeBodyHeaders(from request: inout URLRequest) {
        request.setValue(nil, forHTTPHeaderField: "Transfer-Encoding")
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
    }

    private func isSameConnection(from originalURL: URL?, to redirectedURL: URL?) -> Bool {
        guard let originalURL, let redirectedURL else {
            return false
        }

        return originalURL.scheme?.caseInsensitiveCompare(redirectedURL.scheme ?? "") == .orderedSame &&
            originalURL.host?.caseInsensitiveCompare(redirectedURL.host ?? "") == .orderedSame &&
            resolvedPort(for: originalURL) == resolvedPort(for: redirectedURL)
    }

    private func resolvedPort(for url: URL) -> Int {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return -1
        }
    }
}

private nonisolated struct AlamofireTransportRetrier: RequestRetrier {
    func retry(
        _ request: Request,
        for session: Session,
        dueTo error: any Error,
        completion: @escaping (RetryResult) -> Void
    ) {
        let attempt = request.retryCount
        guard attempt < 2 else {
            completion(.doNotRetry)
            return
        }

        let nsError = error.asAFError?.underlyingError as NSError? ?? error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            completion(.doNotRetry)
            return
        }

        let retryableCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorCannotLoadFromNetwork
        ]

        guard retryableCodes.contains(nsError.code) else {
            completion(.doNotRetry)
            return
        }

        completion(.retryWithDelay(0.15 * Double(attempt + 1)))
    }
}

/// 基于 Alamofire 的统一请求工具层。
/// 负责 session 复用、超时、重定向、宽松 TLS 与轻量重试，避免在 HTTPClient 中堆叠运输层兼容细节。
nonisolated final class AlamofireRequestTool {
    private static let trustManager = LenientServerTrustManager()

    private let lock = NSLock()
    private let requestCreationGate = AlamofireRequestCreationGate()
    private var sessions: [AlamofireSessionKey: Session] = [:]
    private let interceptor = Interceptor(retriers: [AlamofireTransportRetrier()])

    init() {}

    func shutdown() {
        requestCreationGate.shutdown()

        lock.lock()
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        for session in activeSessions {
            session.cancelAllRequests()
        }
    }

    func send(
        request: URLRequest,
        followRedirects: Bool,
        timeout: TimeInterval,
        enableCookieJar: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        guard let session = session(for: followRedirects, timeout: timeout) else {
            throw ParserError.networkError("HTTP session 已关闭")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let dataRequest = perform(
                request: request,
                with: session,
                enableCookieJar: enableCookieJar,
                completion: { result in
                    continuation.resume(with: result)
                }
            )
            if dataRequest == nil {
                continuation.resume(throwing: ParserError.networkError("HTTP session 已关闭"))
            }
        }
    }

    func sendSync(
        request: URLRequest,
        followRedirects: Bool,
        timeout: TimeInterval,
        enableCookieJar: Bool
    ) throws -> (Data, HTTPURLResponse) {
        guard let session = session(for: followRedirects, timeout: timeout) else {
            throw ParserError.networkError("HTTP session 已关闭")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var output: Result<(Data, HTTPURLResponse), Error> = .failure(ParserError.networkError("Alamofire 同步请求未开始"))
        var activeRequest: DataRequest?

        guard let request = perform(
            request: request,
            with: session,
            enableCookieJar: enableCookieJar,
            completion: { result in
                resultLock.lock()
                output = result
                resultLock.unlock()
                semaphore.signal()
            }
        ) else {
            throw ParserError.networkError("HTTP session 已关闭")
        }
        activeRequest = request

        let waitTimeout = DispatchTime.now() + max(timeout + 1, 2)
        if semaphore.wait(timeout: waitTimeout) == .timedOut {
            activeRequest?.cancel()
            throw ParserError.networkError("同步请求超时")
        }

        resultLock.lock()
        defer { resultLock.unlock() }
        return try output.get()
    }

    private func session(for followRedirects: Bool, timeout: TimeInterval) -> Session? {
        let key = AlamofireSessionKey(
            followRedirects: followRedirects,
            timeoutMillis: max(1000, Int(timeout * 1000))
        )

        return requestCreationGate.withRequestCreation {
            lock.lock()
            defer { lock.unlock() }

            if let existing = sessions[key] {
                return existing
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = max(timeout, timeout * 2)
            configuration.waitsForConnectivity = false
            configuration.httpCookieStorage = HTTPCookieStorage.shared
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil

            let session = Session(
                configuration: configuration,
                interceptor: interceptor,
                serverTrustManager: Self.trustManager,
                redirectHandler: AlamofireRedirectHandler(followRedirects: followRedirects),
                cachedResponseHandler: ResponseCacher(behavior: .doNotCache)
            )
            sessions[key] = session
            return session
        }
    }

    private func perform(
        request: URLRequest,
        with session: Session,
        enableCookieJar: Bool,
        completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void
    ) -> DataRequest? {
        requestCreationGate.withRequestCreation {
            if enableCookieJar,
               let url = request.url,
               let storage = session.session.configuration.httpCookieStorage {
                CookieManager.shared.applyCookies(to: storage, for: url)
            }

            let dataRequest = session.request(request)
            dataRequest
                .validate { _, _, _ in
                    .success(())
                }
                .responseData(
                    queue: .global(qos: .userInitiated),
                    emptyResponseCodes: [200, 202, 204, 205],
                    emptyRequestMethods: [.get, .post, .head]
                ) { response in
                    switch response.result {
                    case .success(let data):
                        guard let httpResponse = response.response else {
                            completion(.failure(ParserError.networkError("Alamofire 缺少 HTTP 响应")))
                            return
                        }
                        if enableCookieJar,
                           let finalURL = httpResponse.url,
                           let storage = session.session.configuration.httpCookieStorage {
                            CookieManager.shared.absorbCookies(from: storage, for: finalURL)
                        }
                        completion(.success((data, httpResponse)))
                    case .failure(let error):
                        if let httpResponse = response.response, response.data != nil {
                            if enableCookieJar,
                               let finalURL = httpResponse.url,
                               let storage = session.session.configuration.httpCookieStorage {
                                CookieManager.shared.absorbCookies(from: storage, for: finalURL)
                            }
                            completion(.success((response.data ?? Data(), httpResponse)))
                            return
                        }

                        let message = self.transportErrorMessage(for: error)
                        completion(.failure(ParserError.networkError(message)))
                    }
                }
            return dataRequest
        }
    }

    private func transportErrorMessage(for error: AFError) -> String {
        let nsError = (error.underlyingError as NSError?) ?? (error as NSError)
        let baseMessage = error.underlyingError?.localizedDescription ?? error.localizedDescription

        if nsError.domain == NSURLErrorDomain || nsError.domain == kCFErrorDomainCFNetwork as String {
            return "\(baseMessage) [\(nsError.domain):\(nsError.code)]"
        }

        guard nsError.domain != NSCocoaErrorDomain else {
            return baseMessage
        }
        return "\(baseMessage) [\(nsError.domain):\(nsError.code)]"
    }
}
#endif
