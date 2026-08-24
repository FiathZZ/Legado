import Foundation
import WebKit

private actor SerialGate {
    private var locked = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()

        if !locked {
            locked = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume()
        } else {
            locked = false
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - HeadlessWebView
/// Headless WKWebView renderer for JavaScript-rendered book source pages.
///
/// Must be called from a background Task and internally executes on MainActor.
/// Mirrors Android legado's `BackstageWebView` behavior for dynamic page rendering,
/// delayed JS evaluation, media source sniffing, unsafe SSL acceptance and cookie sync.
@MainActor
public final class HeadlessWebView: NSObject {

    // MARK: - Singleton

    public static let shared = HeadlessWebView()

    // MARK: - Types

    private enum Mode {
        case extractHTML
        case sniffSource(regex: NSRegularExpression)
        case overrideURL(regex: NSRegularExpression)
    }

    private struct PendingLoad {
        let mode: Mode
        let webJs: String?
        let delayMs: Int
        let continuation: CheckedContinuation<String, Error>
    }

    private static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let defaultExtractionJS = "document.documentElement.outerHTML"
    private static let resourceMessageName = "resourceSniffer"

    // MARK: - Properties

    private var webView: WKWebView?
    private var pendingLoad: PendingLoad?
    private var didResumeContinuation = false
    private var navigationTimeoutTask: Task<Void, Never>?
    private var currentBaseURL: URL?
    private let gate = SerialGate()
    public private(set) var lastLoadedURL: URL?

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Load a URL and return the rendered page HTML or evaluation result.
    public func fetchHTML(
        url: String,
        headers: [String: String] = [:],
        webJs: String? = nil,
        delayMs: Int = 0
    ) async throws -> String {
        try await fetchHTML(
            html: nil,
            url: url,
            headers: headers,
            webJs: webJs,
            delayMs: delayMs,
            timeoutMs: 30_000
        )
    }

    /// Load a URL or HTML and return the rendered page HTML or evaluation result.
    public func fetchHTML(
        html: String?,
        url: String,
        headers: [String: String] = [:],
        webJs: String? = nil,
        delayMs: Int = 0,
        timeoutMs: Int = 30_000
    ) async throws -> String {
        let normalizedURL = normalizedURLString(url)
        return try await startLoad(
            url: normalizedURL,
            html: html,
            headers: headers,
            webJs: webJs,
            delayMs: max(0, delayMs),
            timeoutMs: max(1, timeoutMs),
            mode: .extractHTML
        )
    }

    /// Load a URL or HTML and intercept a resource request matching `sourceRegex`.
    public func sniffSourceURL(
        url: String,
        headers: [String: String] = [:],
        sourceRegex: String,
        webJs: String? = nil,
        delayMs: Int = 0,
        timeoutMs: Int = 30_000
    ) async throws -> String {
        try await sniffSourceURL(
            html: nil,
            url: url,
            headers: headers,
            sourceRegex: sourceRegex,
            webJs: webJs,
            delayMs: delayMs,
            timeoutMs: timeoutMs
        )
    }

    /// Load a URL or HTML and intercept a resource request matching `sourceRegex`.
    public func sniffSourceURL(
        html: String?,
        url: String,
        headers: [String: String] = [:],
        sourceRegex: String,
        webJs: String? = nil,
        delayMs: Int = 0,
        timeoutMs: Int = 30_000
    ) async throws -> String {
        let regex = try NSRegularExpression(pattern: sourceRegex, options: [.caseInsensitive])
        let normalizedURL = normalizedURLString(url)
        return try await startLoad(
            url: normalizedURL,
            html: html,
            headers: headers,
            webJs: webJs,
            delayMs: max(0, delayMs),
            timeoutMs: max(1, timeoutMs),
            mode: .sniffSource(regex: regex)
        )
    }

    /// Load a URL or HTML and intercept the first navigation URL matching `overrideUrlRegex`.
    public func interceptOverrideURL(
        html: String?,
        url: String,
        headers: [String: String] = [:],
        js: String? = nil,
        overrideUrlRegex: String,
        delayMs: Int = 0,
        timeoutMs: Int = 30_000
    ) async throws -> String {
        let regex = try NSRegularExpression(pattern: overrideUrlRegex, options: [.caseInsensitive])
        let normalizedURL = normalizedURLString(url)
        return try await startLoad(
            url: normalizedURL,
            html: html,
            headers: headers,
            webJs: js,
            delayMs: max(0, delayMs),
            timeoutMs: max(1, timeoutMs),
            mode: .overrideURL(regex: regex)
        )
    }

    public func purge() {
        if pendingLoad != nil, !didResumeContinuation {
            complete(
                with: .failure(ParserError.networkError("WebView cancelled")),
                synchronizeCookies: false
            )
            return
        }

        resetPendingState(stopLoading: true, releaseWebView: true)
    }

    // MARK: - Private load flow

    private func startLoad(
        url: String,
        html: String?,
        headers: [String: String],
        webJs: String?,
        delayMs: Int,
        timeoutMs: Int,
        mode: Mode
    ) async throws -> String {
        try await gate.acquire()
        defer {
            Task {
                await gate.release()
            }
        }

        let targetURL = URL(string: url)
        currentBaseURL = targetURL
        let webView = makeWebViewIfNeeded()
        webView.navigationDelegate = self
        resetPendingState(stopLoading: true, releaseWebView: false)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingLoad = PendingLoad(
                    mode: mode,
                    webJs: webJs,
                    delayMs: delayMs,
                    continuation: continuation
                )
                self.didResumeContinuation = false
                self.lastLoadedURL = targetURL
                self.scheduleTimeout(milliseconds: timeoutMs)

                do {
                    if let html, !html.isEmpty {
                        if let baseURL = targetURL {
                            webView.loadHTMLString(html, baseURL: baseURL)
                        } else {
                            webView.loadHTMLString(html, baseURL: nil)
                        }
                    } else {
                        try self.loadRequest(url: url, headers: headers, in: webView)
                    }
                } catch {
                    self.complete(with: .failure(error))
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(with: .failure(ParserError.networkError("WebView cancelled")))
            }
        })
    }

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: Self.resourceMessageName)
        configuration.userContentController.addUserScript(resourceSnifferUserScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.customUserAgent = Self.defaultUserAgent
        self.webView = webView
        return webView
    }

    private func loadRequest(url: String, headers: [String: String], in webView: WKWebView) throws {
        guard let targetURL = URL(string: url) else {
            throw ParserError.invalidURL(url)
        }

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 30
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let cookieString = CookieManager.shared.getCookieString(for: targetURL)
        if !cookieString.isEmpty {
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        webView.load(request)
    }

    private func scheduleTimeout(milliseconds: Int) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            await MainActor.run {
                guard let self, self.pendingLoad != nil else { return }
                self.complete(with: .failure(ParserError.networkError("WebView timeout")))
            }
        }
    }

    private func runExtractionJS() {
        guard let pendingLoad, case .extractHTML = pendingLoad.mode, let webView else {
            return
        }

        let js = effectiveJavaScript(from: pendingLoad.webJs)
        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.complete(with: .failure(error))
                    return
                }
                let value = self.stringValue(from: result)
                self.complete(with: .success(value))
            }
        }
    }

    private func runSnifferJavaScriptIfNeeded() {
        guard let pendingLoad,
              case .sniffSource = pendingLoad.mode,
              let webJs = pendingLoad.webJs,
              !webJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let webView else {
            return
        }

        webView.evaluateJavaScript(webJs) { _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.complete(with: .failure(error))
                }
            }
        }
    }

    private func runOverrideJavaScriptIfNeeded() {
        guard let pendingLoad,
              case .overrideURL = pendingLoad.mode,
              let webJs = pendingLoad.webJs,
              !webJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let webView else {
            return
        }

        webView.evaluateJavaScript(webJs) { _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.complete(with: .failure(error))
                }
            }
        }
    }

    private func effectiveJavaScript(from webJs: String?) -> String {
        let trimmed = webJs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.defaultExtractionJS : trimmed
    }

    private func stringValue(from result: Any?) -> String {
        switch result {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case nil:
            return ""
        default:
            return "\(result ?? "")"
        }
    }

    private func syncCookies(for url: URL?) {
        guard let url, let webView else { return }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains(url.host ?? "") || (url.host?.contains(cookie.domain) == true) {
                CookieManager.shared.saveCookie(cookie, domain: url.host ?? cookie.domain)
            }
        }
    }

    private func normalizedURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "about:blank" : trimmed
    }

    private func complete(
        with result: Result<String, Error>,
        synchronizeCookies: Bool = true
    ) {
        guard let pendingLoad, !didResumeContinuation else { return }
        didResumeContinuation = true
        self.pendingLoad = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil

        let currentURL = webView?.url ?? currentBaseURL
        lastLoadedURL = currentURL

        let finishCompletion = { [weak self] in
            pendingLoad.continuation.resume(with: result)
            self?.resetPendingState(stopLoading: true, releaseWebView: true)
        }

        if synchronizeCookies, let currentURL, let webView {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor [weak self] in
                    for cookie in cookies where cookie.domain.contains(currentURL.host ?? "") || (currentURL.host?.contains(cookie.domain) == true) {
                        CookieManager.shared.saveCookie(cookie, domain: currentURL.host ?? cookie.domain)
                    }
                    finishCompletion()
                }
            }
        } else {
            finishCompletion()
        }
    }

    private func resetPendingState(stopLoading: Bool, releaseWebView: Bool = false) {
        if stopLoading {
            webView?.stopLoading()
        }
        pendingLoad = nil
        currentBaseURL = nil
        didResumeContinuation = false
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if releaseWebView {
            webView?.navigationDelegate = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.resourceMessageName)
            webView?.configuration.userContentController.removeAllUserScripts()
            webView?.loadHTMLString("", baseURL: nil)
            webView = nil
            lastLoadedURL = nil
        }
    }

    private func sourceURLMatches(_ url: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(location: 0, length: (url as NSString).length)
        return regex.firstMatch(in: url, options: [], range: range) != nil
    }

    private func resourceSnifferUserScript() -> WKUserScript {
        let script = #"""
        (function() {
            if (window.__legadoSnifferInstalled) {
                return;
            }
            window.__legadoSnifferInstalled = true;

            function post(url) {
                try {
                    if (!url) return;
                    window.webkit.messageHandlers.resourceSniffer.postMessage(String(url));
                } catch (e) {}
            }

            function flushPerformanceEntries() {
                try {
                    var entries = performance.getEntriesByType ? performance.getEntriesByType('resource') : [];
                    for (var i = 0; i < entries.length; i++) {
                        if (entries[i] && entries[i].name) {
                            post(entries[i].name);
                        }
                    }
                } catch (e) {}
            }

            var originalFetch = window.fetch;
            if (originalFetch) {
                window.fetch = function(input, init) {
                    try {
                        post(typeof input === 'string' ? input : (input && input.url) || '');
                    } catch (e) {}
                    return originalFetch.apply(this, arguments).then(function(response) {
                        try {
                            if (response && response.url) {
                                post(response.url);
                            }
                        } catch (e) {}
                        return response;
                    });
                };
            }

            var originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                try { post(url); } catch (e) {}
                return originalOpen.apply(this, arguments);
            };

            var originalSetAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value) {
                try {
                    if (name === 'src' || name === 'href') {
                        post(value);
                    }
                } catch (e) {}
                return originalSetAttribute.apply(this, arguments);
            };

            function wrapSrcSetter(proto) {
                try {
                    if (!proto) return;
                    var descriptor = Object.getOwnPropertyDescriptor(proto, 'src');
                    if (!descriptor || !descriptor.set) return;
                    Object.defineProperty(proto, 'src', {
                        configurable: true,
                        enumerable: descriptor.enumerable,
                        get: descriptor.get,
                        set: function(value) {
                            try { post(value); } catch (e) {}
                            return descriptor.set.call(this, value);
                        }
                    });
                } catch (e) {}
            }

            wrapSrcSetter(window.HTMLMediaElement && window.HTMLMediaElement.prototype);
            wrapSrcSetter(window.HTMLSourceElement && window.HTMLSourceElement.prototype);
            wrapSrcSetter(window.HTMLIFrameElement && window.HTMLIFrameElement.prototype);

            document.addEventListener('readystatechange', flushPerformanceEntries);
            window.addEventListener('load', function() {
                flushPerformanceEntries();
                setTimeout(flushPerformanceEntries, 1000);
                setTimeout(flushPerformanceEntries, 3000);
            });
        })();
        """#
        return WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

// MARK: - WKNavigationDelegate
extension HeadlessWebView: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pendingLoad else { return }
        let delay = max(0, pendingLoad.delayMs)
        if delay == 0 {
            switch pendingLoad.mode {
            case .extractHTML:
                runExtractionJS()
            case .sniffSource:
                runSnifferJavaScriptIfNeeded()
            case .overrideURL:
                runOverrideJavaScriptIfNeeded()
            }
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, self.pendingLoad != nil else { return }
            switch pendingLoad.mode {
            case .extractHTML:
                self.runExtractionJS()
            case .sniffSource:
                self.runSnifferJavaScriptIfNeeded()
            case .overrideURL:
                self.runOverrideJavaScriptIfNeeded()
            }
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        complete(with: .failure(error))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        complete(with: .failure(error))
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let pendingLoad,
              let requestURL = navigationAction.request.url?.absoluteString else {
            decisionHandler(.allow)
            return
        }

        switch pendingLoad.mode {
        case .sniffSource(let regex) where sourceURLMatches(requestURL, regex: regex):
            decisionHandler(.cancel)
            lastLoadedURL = navigationAction.request.url
            complete(with: .success(requestURL))
        case .overrideURL(let regex) where sourceURLMatches(requestURL, regex: regex):
            decisionHandler(.cancel)
            lastLoadedURL = navigationAction.request.url
            complete(with: .success(requestURL))
        default:
            decisionHandler(.allow)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let pendingLoad,
              case .sniffSource(let regex) = pendingLoad.mode,
              let responseURL = navigationResponse.response.url?.absoluteString,
              sourceURLMatches(responseURL, regex: regex) else {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        lastLoadedURL = navigationResponse.response.url
        complete(with: .success(responseURL))
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - WKScriptMessageHandler
extension HeadlessWebView: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.resourceMessageName,
              let pendingLoad,
              case .sniffSource(let regex) = pendingLoad.mode else {
            return
        }

        if let url = message.body as? String, sourceURLMatches(url, regex: regex) {
            complete(with: .success(url))
            return
        }

        if let urls = message.body as? [String], let matched = urls.first(where: { sourceURLMatches($0, regex: regex) }) {
            complete(with: .success(matched))
        }
    }
}
