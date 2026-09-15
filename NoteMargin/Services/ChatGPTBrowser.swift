#if PERSONAL_CHATGPT
import SwiftUI
import WebKit

/// A normal persistent browser. No injected scripts, session-token extraction,
/// private endpoints, or API requests are used for ChatGPT conversations.
@MainActor final class ChatGPTBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var url: URL?
    @Published var loading = false
    @Published var failure: String?
    @Published var popup: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL = ChatGPTWebContext.home, websiteDataStore: WKWebsiteDataStore? = nil, loadImmediately: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.url = view.url }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.loading = view.isLoading }
            }
        ]
        if loadImmediately { webView.load(URLRequest(url: ChatGPTWebContext.conversationURL(url) ?? ChatGPTWebContext.home)) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Keep authentication on its real origin; never disguise the address.
        if ["https", "about", "blob"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else {
            failure = "이 링크는 내장 브라우저에서 열 수 없습니다. 필요한 경우 메뉴에서 Safari로 열어 주세요."
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { failure = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = "웹 화면이 종료되었습니다. 새로고침해 주세요." }
    private func report(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // Do not echo authentication callback URLs or tokens in error text/logs.
        failure = "웹 화면을 불러오지 못했습니다. 네트워크를 확인하고 새로고침해 주세요. 로그인 반복 시 메뉴의 로그인 도움말을 확인하세요."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self; child.uiDelegate = self
        popup = child
        return child
    }
    func webViewDidClose(_ webView: WKWebView) { if popup === webView { popup = nil } }
}

/// Each margin pin has its own page; website cookies are shared inside this app.
/// Keep recent tabs alive when the user hides a pin, with bounded memory use.
@MainActor final class ChatGPTBrowserTabs {
    static let shared = ChatGPTBrowserTabs()
    private var tabs: [String: ChatGPTBrowser] = [:]
    private var recent: [String] = []
    func close(_ id: UUID) {
        tabs.removeValue(forKey: id.uuidString)
        recent.removeAll { $0 == id.uuidString }
    }
    func browser(for id: UUID?, url: URL?) -> ChatGPTBrowser {
        let key = id?.uuidString ?? "library"
        recent.removeAll { $0 == key }; recent.append(key)
        if let tab = tabs[key] { return tab }
        let browser = ChatGPTBrowser(url: url ?? ChatGPTWebContext.home)
        tabs[key] = browser
        while recent.count > 3 { tabs.removeValue(forKey: recent.removeFirst()) }
        return browser
    }
}

struct ChatGPTWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
