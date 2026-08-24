import Foundation
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

struct SourceVerificationBrowserResult: Codable {
    let url: String
    let body: String
}

@MainActor
final class SourceVerificationHelper: NSObject {
    static let shared = SourceVerificationHelper()
    fileprivate static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var activeBrowserController: SourceVerificationBrowserViewController?
    private var browserContinuation: CheckedContinuation<SourceVerificationBrowserResult, Error>?
    private var activeCodeController: VerificationCodeViewController?
    private var codeContinuation: CheckedContinuation<String, Never>?

    private override init() {
        super.init()
    }

    func startBrowser(
        source: BookSource?,
        url: String,
        title: String,
        headers: [String: String]
    ) async throws {
        _ = try await presentBrowser(
            source: source,
            url: url,
            title: title,
            headers: headers,
            // The Java bridge invokes this from its own task, so waiting here never blocks rule
            // evaluation. It does let a SwiftUI caller reload the source after the user confirms
            // and the WebView cookies have been copied back to the request cookie jar.
            waitForCompletion: true,
            refetchAfterSuccess: true
        )
    }

    func startBrowserAwait(
        source: BookSource?,
        url: String,
        title: String,
        headers: [String: String],
        refetchAfterSuccess: Bool = true
    ) async throws -> SourceVerificationBrowserResult {
        guard let result = try await presentBrowser(
            source: source,
            url: url,
            title: title,
            headers: headers,
            waitForCompletion: true,
            refetchAfterSuccess: refetchAfterSuccess
        ) else {
            throw ParserError.networkError("浏览器验证未返回结果")
        }
        return result
    }

    func getVerificationCode(source: BookSource?, imageURL: String) async -> String {
        guard codeContinuation == nil else {
            return ""
        }

        guard let presenter = topViewController() else {
            ParserLog.debug("SourceVerification", "verification code presenter unavailable source=\(source?.bookSourceName ?? "unknown")")
            return ""
        }

        let controller = VerificationCodeViewController(
            sourceName: source?.bookSourceName ?? "",
            imageURL: imageURL,
            requestHeaders: HTTPClient.resolvedSourceHeaders(baseUrl: imageURL, source: source)
        )
        activeCodeController = controller

        controller.onCancel = { [weak self] in
            self?.finishVerificationCode("")
        }
        controller.onConfirm = { [weak self] text in
            self?.finishVerificationCode(text)
        }

        presenter.present(controller, animated: true)

        return await withCheckedContinuation { continuation in
            self.codeContinuation = continuation
        }
    }

    private func presentBrowser(
        source: BookSource?,
        url: String,
        title: String,
        headers: [String: String],
        waitForCompletion: Bool,
        refetchAfterSuccess: Bool
    ) async throws -> SourceVerificationBrowserResult? {
        guard activeBrowserController == nil, browserContinuation == nil else {
            throw ParserError.networkError("已有进行中的浏览器验证")
        }

        guard let targetURL = URL(string: url) else {
            throw ParserError.invalidURL(url)
        }
        guard let presenter = topViewController() else {
            throw ParserError.networkError("无法定位当前窗口")
        }

        let controller = SourceVerificationBrowserViewController(
            sourceName: source?.bookSourceName ?? "",
            titleText: title,
            request: makeBrowserRequest(url: targetURL, headers: headers),
            onDone: { [weak self] browserController in
                Task { @MainActor [weak self] in
                    await self?.finishBrowser(
                        controller: browserController,
                        source: source,
                        initialURL: targetURL,
                        headers: headers,
                        refetchAfterSuccess: refetchAfterSuccess
                    )
                }
            },
            onClosedWithoutConfirmation: { [weak self] in
                self?.cancelBrowserIfNeeded()
            }
        )

        try await seedCookies(for: source, targetURL: targetURL, cookieStore: controller.cookieStore)

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen

        activeBrowserController = controller
        presenter.present(navigationController, animated: true)

        guard waitForCompletion else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.browserContinuation = continuation
        }
    }

    private func finishBrowser(
        controller: SourceVerificationBrowserViewController,
        source: BookSource?,
        initialURL: URL,
        headers: [String: String],
        refetchAfterSuccess: Bool
    ) async {
        let finalURL = controller.webView.url ?? initialURL

        do {
            try await syncCookies(from: controller.cookieStore, preferredURL: finalURL)
            let body: String
            if refetchAfterSuccess {
                body = try await refetchHTML(for: finalURL, source: source, headers: headers)
            } else {
                body = try await controller.currentHTML()
            }

            controller.dismiss(animated: true)
            finishBrowserContinuation(.success(SourceVerificationBrowserResult(url: finalURL.absoluteString, body: body)))
        } catch {
            controller.dismiss(animated: true)
            finishBrowserContinuation(.failure(error))
        }
    }

    private func cancelBrowserIfNeeded() {
        guard let controller = activeBrowserController else { return }
        controller.dismiss(animated: true)
        finishBrowserContinuation(.failure(ParserError.networkError("浏览器验证已取消")))
    }

    private func finishBrowserContinuation(_ result: Result<SourceVerificationBrowserResult, Error>) {
        activeBrowserController = nil
        guard let continuation = browserContinuation else { return }
        browserContinuation = nil
        continuation.resume(with: result)
    }

    private func finishVerificationCode(_ value: String) {
        activeCodeController?.dismiss(animated: true)
        activeCodeController = nil
        guard let continuation = codeContinuation else { return }
        codeContinuation = nil
        continuation.resume(returning: value)
    }

    private func makeBrowserRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)

        let cookieString = CookieManager.shared.getCookieString(for: url)
        if !cookieString.isEmpty {
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func refetchHTML(for url: URL, source: BookSource?, headers: [String: String]) async throws -> String {
        let httpClient = HTTPClient()
        defer { httpClient.shutdown() }

        var resolvedHeaders = headers.isEmpty
            ? HTTPClient.resolvedSourceHeaders(baseUrl: url.absoluteString, source: source)
            : headers
        let cookieString = CookieManager.shared.getCookieString(for: url)
        if !cookieString.isEmpty,
           resolvedHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Cookie") == .orderedSame }) == false {
            resolvedHeaders["Cookie"] = cookieString
        }

        var request = HTTPRequest(
            url: url.absoluteString,
            method: .get,
            headers: resolvedHeaders
        )
        request.followRedirects = true

        let response = try await httpClient.send(request: request)
        return response.text ?? String(data: response.data, encoding: .utf8) ?? ""
    }

    private func seedCookies(for source: BookSource?, targetURL: URL, cookieStore: WKHTTPCookieStore) async throws {
        var cookieEntries: [HTTPCookie] = []
        let domains = Set([
            targetURL.host,
            URL(string: source?.bookSourceUrl ?? "")?.host
        ].compactMap { $0 })

        for domain in domains {
            let cookieString = CookieManager.shared.getCookieString(domain: domain)
            cookieEntries.append(contentsOf: cookies(from: cookieString, targetURL: targetURL, domain: domain))
        }

        if let cookieJar = source?.cookieJar {
            cookieEntries.append(contentsOf: cookies(from: cookieJar, targetURL: targetURL, domain: targetURL.host))
        }

        let uniqueCookies = Dictionary(
            cookieEntries.map { ("\($0.domain)|\($0.path)|\($0.name)", $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values

        for cookie in uniqueCookies {
            await setCookie(cookie, into: cookieStore)
        }
    }

    private func syncCookies(from cookieStore: WKHTTPCookieStore, preferredURL: URL) async throws {
        let cookies = await allCookies(in: cookieStore)
        let host = preferredURL.host

        for cookie in cookies {
            let cookieDomain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let host, domainMatches(host: host, cookieDomain: cookieDomain) {
                CookieManager.shared.saveCookie(cookie, domain: host)
            } else {
                CookieManager.shared.saveCookie(cookie, domain: cookieDomain)
            }
        }
    }

    private func cookies(from cookieString: String, targetURL: URL, domain: String?) -> [HTTPCookie] {
        guard !cookieString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let resolvedDomain = (domain?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? targetURL.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedDomain.isEmpty else { return [] }

        return cookieString
            .split(separator: ";")
            .compactMap { rawEntry in
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }

                return HTTPCookie(properties: [
                    .name: String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines),
                    .value: String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines),
                    .domain: resolvedDomain,
                    .path: targetURL.path.isEmpty ? "/" : targetURL.path,
                    .secure: targetURL.scheme?.lowercased() == "https" ? "TRUE" : "FALSE"
                ])
            }
    }

    private func domainMatches(host: String, cookieDomain: String) -> Bool {
        host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
    }

    private func setCookie(_ cookie: HTTPCookie, into store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func topViewController() -> UIViewController? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScenes = windowScenes.filter { $0.activationState == .foregroundActive }
        let candidateScenes = activeScenes.isEmpty ? windowScenes : activeScenes

        let keyWindow = candidateScenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        return topViewController(from: keyWindow?.rootViewController)
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        if let navigationController = root as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = root as? UITabBarController {
            return topViewController(from: tabBarController.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}

private final class SourceVerificationBrowserViewController: UIViewController, WKNavigationDelegate {
    let webView: WKWebView
    let cookieStore: WKHTTPCookieStore

    private let titleText: String
    private let request: URLRequest
    private let sourceName: String
    private let onDone: (SourceVerificationBrowserViewController) -> Void
    private let onClosedWithoutConfirmation: () -> Void
    private var didConfirm = false

    init(
        sourceName: String,
        titleText: String,
        request: URLRequest,
        onDone: @escaping (SourceVerificationBrowserViewController) -> Void,
        onClosedWithoutConfirmation: @escaping () -> Void
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.cookieStore = configuration.websiteDataStore.httpCookieStore
        self.sourceName = sourceName
        self.titleText = titleText.isEmpty ? "验证" : titleText
        self.request = request
        self.onDone = onDone
        self.onClosedWithoutConfirmation = onClosedWithoutConfirmation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleText
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        if !sourceName.isEmpty {
            navigationItem.prompt = sourceName
        }

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(request)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true, !didConfirm {
            onClosedWithoutConfirmation()
        }
    }

    @objc private func doneTapped() {
        didConfirm = true
        onDone(self)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    func currentHTML() async throws -> String {
        let result = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        return (result as? String) ?? ""
    }
}

private final class VerificationCodeViewController: UIViewController {
    var onCancel: (() -> Void)?
    var onConfirm: ((String) -> Void)?

    private let sourceName: String
    private let imageURL: String
    private let requestHeaders: [String: String]
    private let imageView = UIImageView()
    private let textField = UITextField()
    private let statusLabel = UILabel()

    init(sourceName: String, imageURL: String, requestHeaders: [String: String]) {
        self.sourceName = sourceName
        self.imageURL = imageURL
        self.requestHeaders = requestHeaders
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 360, height: 320)
        title = sourceName.isEmpty ? "验证码" : sourceName

        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground

        textField.borderStyle = .roundedRect
        textField.placeholder = "输入验证码"
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "加载中..."
        statusLabel.numberOfLines = 0

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确认", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, confirmButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [imageView, statusLabel, textField, buttonStack])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            imageView.heightAnchor.constraint(equalToConstant: 140)
        ])

        Task { [weak self] in
            await self?.loadImage()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textField.becomeFirstResponder()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func confirmTapped() {
        onConfirm?(textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private func loadImage() async {
        guard let url = URL(string: imageURL) else {
            statusLabel.text = "验证码地址无效"
            return
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue(SourceVerificationHelper.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in requestHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let cookieString = CookieManager.shared.getCookieString(for: url)
            if !cookieString.isEmpty {
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            }

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = UIImage(data: data) else {
                statusLabel.text = "验证码图片无法解析"
                return
            }
            imageView.image = image
            statusLabel.text = imageURL
        } catch {
            statusLabel.text = "验证码加载失败: \(error.localizedDescription)"
        }
    }
}
#endif
