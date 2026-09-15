#if PERSONAL_CHATGPT
import SwiftUI
import WebKit

/// A persistent browser with an explicit, user-triggered composer helper.
/// No session-token extraction, private endpoints or API calls are used.
@MainActor final class ChatGPTBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var url: URL?
    @Published var loading = false
    @Published var failure: String?
    @Published var popup: WKWebView?
    @Published private(set) var automating = false
    @Published private(set) var automationMessage: String?
    private var automationTask: Task<Void, Never>?
    private var automationCancellationRequested = false
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

    func sendRegion(imageData: Data, prompt: String) {
        guard !automating else { return }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !imageData.isEmpty else {
            automationMessage = "질문과 선택 영역을 먼저 준비해 주세요."; return
        }
        automationCancellationRequested = false
        automating = true
        automationMessage = "이미지 첨부와 질문 입력을 준비하고 있습니다…"
        automationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automating = false; self.automationTask = nil }
            guard !self.automationCancellationRequested else {
                self.automationMessage = Self.message(for: "cancelled"); return
            }
            do {
                let status = try await self.prepareAndSubmit(imageData: imageData, prompt: prompt)
                self.automationMessage = Self.message(for: status)
            } catch {
                self.automationMessage = "화면이 바뀌어 전송 결과를 확인하지 못했습니다. 중복 전송하지 않도록 아래 ChatGPT 대화를 확인하세요."
            }
        }
    }

    // Also exercised against a real WKWebView with a local, isolated fixture.
    func prepareAndSubmit(imageData: Data, prompt: String, timeoutMS: Int = 20_000) async throws -> String {
        let value = try await webView.callAsyncJavaScript(ChatGPTComposerAutomation.script, arguments: [
            "imageBase64": imageData.base64EncodedString(), "prompt": prompt,
            "filename": "note-margin-\(UUID().uuidString.lowercased()).png",
            "operationID": UUID().uuidString, "timeoutMS": timeoutMS
        ], in: nil, contentWorld: .page)
        return (value as? [String: Any])?["status"] as? String ?? "submission_unknown"
    }
    func cancelAutomation() {
        guard automating else { return }
        automationCancellationRequested = true
        // Do not cancel only the Swift task: the JavaScript could otherwise
        // continue and click Send after the panel has disappeared.
        webView.evaluateJavaScript(ChatGPTComposerAutomation.cancelScript, completionHandler: nil)
    }
    private static func message(for status: String) -> String {
        switch status {
        case "submit_clicked": return "이미지와 질문을 넣고 ChatGPT 전송 버튼을 눌렀습니다. 아래 대화에서 결과를 확인하세요."
        case "login_required": return "먼저 아래 ChatGPT 화면에서 로그인해 주세요."
        case "existing_draft", "existing_attachment": return "ChatGPT 입력칸에 작성 중인 질문이나 첨부가 있습니다. 먼저 전송하거나 정리해 주세요. 기존 내용은 덮어쓰지 않았습니다."
        case "attachment_unconfirmed": return "첨부 완료를 확인하지 못해 자동 전송을 멈췄습니다. 아래 화면에서 이미지 상태를 확인하고 직접 전송하세요."
        case "cancelled", "draft_changed": return "자동 전송을 중단했습니다. 이미 준비된 질문·첨부는 웹 화면에서 확인하세요."
        case "dialog_open": return "ChatGPT에 열린 안내창을 먼저 확인하고 닫아 주세요. 자동 전송은 멈췄습니다."
        case "wrong_page": return "ChatGPT 대화 화면을 연 뒤 사용해 주세요. 로그인 화면에서는 자동 입력하지 않습니다."
        case "busy_or_unsupported": return "ChatGPT가 답변 중이거나 현재 입력 화면을 인식하지 못했습니다. 웹 화면을 확인해 주세요."
        default: return "현재 ChatGPT 화면에서 자동 처리를 완료하지 못했습니다. 아래 화면의 질문·첨부 상태를 확인해 직접 전송하세요."
        }
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

#if PERSONAL_CHATGPT
/// An experimental adapter for the visible ChatGPT composer, not a private API.
/// Selectors are intentionally narrow: an unrecognized page stays manual.
enum ChatGPTComposerAutomation {
    static let script = #"""
    const result = (status) => ({status});
    if (location.protocol !== 'https:' || location.hostname !== 'chatgpt.com') return result('wrong_page');
    const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).display !== 'none';
    if (Array.from(document.querySelectorAll('[data-logged-out]')).some(visible) ||
        Array.from(document.querySelectorAll('button')).some(e => visible(e) && ['로그인', 'Log in', 'Sign in'].includes(e.innerText.trim()))) return result('login_required');
    if (Array.from(document.querySelectorAll('[role="dialog"],dialog[open]')).some(visible)) return result('dialog_open');
    const candidates = Array.from(document.querySelectorAll('#mobile-composer-prompt, #prompt-textarea')).filter(visible);
    if (candidates.length !== 1) return result('unsupported');
    const editor = candidates[0];
    const form = editor.closest('form');
    if (!form) return result('unsupported');
    const text = () => editor instanceof HTMLTextAreaElement ? editor.value : editor.innerText;
    const submit = () => {
        const buttons = Array.from(form.querySelectorAll('[data-composer-submit],button[data-testid="send-button"]')).filter(visible);
        if (buttons.length !== 1) return null;
        const button = buttons[0];
        const label = button.getAttribute('aria-label');
        // A single button can change from send to stop while generating.
        if (button.hasAttribute('data-composer-submit') && label !== button.getAttribute('data-send-label')) return null;
        return button;
    };
    if (!submit()) return result('busy_or_unsupported');
    if (text().trim()) return result('existing_draft');
    if (Array.from(form.querySelectorAll('img')).some(visible) ||
        Array.from(form.querySelectorAll('input[type="file"]')).some(e => e.files?.length) ||
        Array.from(form.querySelectorAll('button')).some(e => visible(e) && /^(remove|delete|삭제|제거)/i.test(e.getAttribute('aria-label') || e.getAttribute('title') || ''))) return result('existing_attachment');
    const fileInputs = Array.from(form.querySelectorAll('input[type="file"]')).filter(e =>
        !e.disabled && !e.hasAttribute('capture') &&
        (e.accept.includes('image/') || e.accept.includes('.png')));
    const preferred = fileInputs.find(e => e.id === 'octane-mobile-composer-files-input');
    const input = preferred || (fileInputs.length === 1 ? fileInputs[0] : null);
    if (!input || typeof DataTransfer !== 'function' || typeof File !== 'function') return result('unsupported');
    const previous = window.__noteMarginComposerOperation;
    if (previous && !previous.finished) return result('busy_or_unsupported');
    const operation = {id: operationID, cancelled: false, finished: false, clicked: false};
    window.__noteMarginComposerOperation = operation;
    const initialURL = location.href;
    const valid = () => !operation.cancelled && location.href === initialURL && editor.isConnected && form.isConnected;
    const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
    try {
        const binary = atob(imageBase64);
        const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
        const transfer = new DataTransfer();
        transfer.items.add(new File([bytes], filename, {type: 'image/png'}));
        if (!valid()) return result('cancelled');
        input.files = transfer.files;
        input.dispatchEvent(new Event('change', {bubbles: true}));
        // Allow the website to accept/reject the image before editing its prompt.
        await wait(200);
        if (!valid()) return result('cancelled');
        if (text().trim()) return result('existing_draft');
        editor.focus();
        if (editor instanceof HTMLTextAreaElement) {
            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(editor, prompt);
            editor.dispatchEvent(new Event('input', {bubbles: true}));
        } else if (editor.isContentEditable) {
            const selection = window.getSelection();
            const range = document.createRange(); range.selectNodeContents(editor);
            selection.removeAllRanges(); selection.addRange(range);
            document.execCommand('insertText', false, prompt);
            editor.dispatchEvent(new Event('input', {bubbles: true}));
        } else return result('unsupported');
        if (text().trim() !== prompt.trim()) return result('input_not_accepted');
        let readySince = null;
        const deadline = Date.now() + timeoutMS;
        while (Date.now() < deadline) {
            if (!valid()) return result('cancelled');
            if (text().trim() !== prompt.trim()) return result('draft_changed');
            if (Array.from(document.querySelectorAll('[role="dialog"],dialog[open]')).some(visible)) return result('dialog_open');
            // Require a visible attachment receipt, not merely input.files.
            const receipt = form.innerText.includes(filename);
            const attachment = Array.from(form.querySelectorAll('img')).some(img =>
                visible(img) && img.complete && img.naturalWidth > 0 &&
                (img.getAttribute('alt') === filename || (receipt && /^(blob:|data:image\/)/.test(img.getAttribute('src') || ''))));
            const progressing = Array.from(form.querySelectorAll('[role="progressbar"],[aria-busy="true"]')).some(visible);
            const errors = Array.from(form.querySelectorAll('[role="alert"]')).some(e => visible(e) && e.innerText.trim());
            const button = submit();
            const ready = attachment && !progressing && !errors && button && !button.disabled && button.getAttribute('aria-disabled') !== 'true';
            if (ready) {
                readySince ??= Date.now();
                if (Date.now() - readySince >= 800) {
                    if (!valid() || !visible(button)) return result('cancelled');
                    operation.clicked = true;
                    button.click(); // Exactly one click; never retry after an uncertain result.
                    return result('submit_clicked');
                }
            } else readySince = null;
            await wait(150);
        }
        return result('attachment_unconfirmed');
    } catch (_) {
        return result(operation.clicked ? 'submission_unknown' : 'unsupported');
    } finally { operation.finished = true; }
    """#

    static let cancelScript = #"""
    if (window.__noteMarginComposerOperation) window.__noteMarginComposerOperation.cancelled = true;
    """#
}
#endif
