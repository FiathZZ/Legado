import SwiftUI
import WebKit

struct RssReaderView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel: RssReaderViewModel
    let source: RssSourceEntity
    let article: RssArticleSummary

    init(source: RssSourceEntity, article: RssArticleSummary) {
        self.source = source
        self.article = article
        _viewModel = StateObject(wrappedValue: RssReaderViewModel(source: source, article: article))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("正在加载正文…")
            } else if let html = viewModel.renderedHTML {
                RssWebView(
                    html: html,
                    requestURL: nil,
                    baseURL: source.loadWithBaseUrl ? URL(string: article.link) : nil,
                    enableJavaScript: source.enableJs,
                    injectJavaScript: source.injectJs
                )
            } else if let url = viewModel.fallbackURL {
                RssWebView(
                    html: nil,
                    requestURL: url,
                    baseURL: nil,
                    enableJavaScript: source.enableJs,
                    injectJavaScript: source.injectJs
                )
            } else {
                ContentUnavailableView("正文为空", systemImage: "doc.text.magnifyingglass")
            }
        }
        .background(themeManager.color(.appBackground))
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            await viewModel.load()
        }
        .alert("阅读失败", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

private struct RssWebView: UIViewRepresentable {
    let html: String?
    let requestURL: URL?
    let baseURL: URL?
    let enableJavaScript: Bool
    let injectJavaScript: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(injectJavaScript: injectJavaScript)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = enableJavaScript
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.injectJavaScript = injectJavaScript
        if let html {
            webView.loadHTMLString(html, baseURL: baseURL)
        } else if let requestURL {
            webView.load(URLRequest(url: requestURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var injectJavaScript: String?

        init(injectJavaScript: String?) {
            self.injectJavaScript = injectJavaScript
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let injectJavaScript,
                  !injectJavaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            webView.evaluateJavaScript(injectJavaScript)
        }
    }
}
