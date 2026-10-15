import SwiftUI
import WebKit
import PDFKit

struct AnswerPart: Identifiable {
    var id: Int
    var text: String
    var math: Bool
    /// Closed math only. An unfinished streamed expression stays selectable text.
    static func parse(_ text: String) -> [AnswerPart] {
        let pattern = #"(?s)\\\[(.*?)\\\]|\\\((.*?)\\\)|\$\$(.*?)\$\$|(?<!\\)\$([^\n$]+)\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.init(id: 0, text: text, math: false)] }
        let source = text as NSString
        var parts: [AnswerPart] = [], cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > cursor { parts.append(.init(id: cursor, text: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), math: false)) }
            if let range = (1..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                parts.append(.init(id: match.range.location, text: source.substring(with: range), math: true))
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { parts.append(.init(id: cursor, text: source.substring(from: cursor), math: false)) }
        return parts
    }
}
struct MathAnswerView: View {
    let text: String
    @State private var height: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sizeCategory) private var sizeCategory
    var body: some View {
        AnswerWebView(text: text, fontSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                      theme: colorScheme == .dark ? "dark" : "light", height: $height)
            .frame(height: height)
            .id(sizeCategory)
    }
}
private struct AnswerWebView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let theme: String
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear; view.scrollView.bounces = false
        view.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "MathResources") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = $height
        if coordinator.text != text || coordinator.fontSize != fontSize || coordinator.theme != theme {
            coordinator.text = text; coordinator.fontSize = fontSize; coordinator.theme = theme
            coordinator.revision += 1
        }
        coordinator.render(view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = false
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var text = "", theme = "light", fontSize: CGFloat = 17
        var revision = 0, renderedRevision = -1
        var loaded = false, rendering = false
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render(webView) }
        func render(_ view: WKWebView) {
            guard loaded, !rendering, revision != renderedRevision else { return }
            rendering = true
            let current = revision
            let arguments: [String: Any] = ["source": text, "revision": current, "fontSize": fontSize, "theme": theme]
            Task { @MainActor in
                do {
                    _ = try await view.callAsyncJavaScript("window.drawAnswer(source, revision, fontSize, theme)", arguments: arguments, in: nil, contentWorld: .page)
                    renderedRevision = current
                } catch { /* Keep the last rendered content and retry on the next update. */ }
                rendering = false
                if loaded && revision != current { render(view) }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(!loaded && action.request.url?.lastPathComponent == "renderer.html" && action.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
                  data["revision"] as? Int == revision, let value = data["height"] as? Double, value.isFinite else { return }
            let next = max(24, value)
            if abs(height.wrappedValue - next) > 0.5 { height.wrappedValue = next }
        }
    }
}

// Export the same offline Markdown/KaTeX DOM used by chat, one vector PDF page
// at a time. The raw Markdown remains in PageElement.text and summary.md.
extension MathAnswerView {
    @MainActor static func document(text: String, width: CGFloat, fontSize: CGFloat = 18) async throws -> (url: URL, height: CGFloat) {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1024), configuration: config)
        let navigation = AnswerDocumentNavigation()
        web.navigationDelegate = navigation
        guard let source = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "MathResources") else { throw CocoaError(.fileReadNoSuchFile) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigation.continuation = continuation
                web.loadFileURL(source, allowingReadAccessTo: source.deletingLastPathComponent())
            }
        } onCancel: { Task { @MainActor in web.stopLoading(); navigation.finish(CancellationError()) } }
        try Task.checkCancellation()
        let result = try await web.callAsyncJavaScript("""
            window.drawAnswer(source, 1, fontSize, 'light');
            // An offscreen web view may resolve fonts.ready before layout has
            // requested KaTeX's italic/symbol faces. Load the bundled faces first.
            await Promise.all([...document.fonts].map(font => font.load()));
            await document.fonts.ready;
            const style = document.createElement('style');
            style.textContent = 'pre{white-space:pre-wrap}table{display:table;width:100%}.math-display{overflow:visible}';
            document.head.append(style);
            for (const node of document.querySelectorAll('.math-display .katex-display')) {
                const content = node.querySelector('.katex');
                if (content && content.getBoundingClientRect().width > node.clientWidth) {
                    const scale = node.clientWidth / content.getBoundingClientRect().width;
                    node.style.height = (content.getBoundingClientRect().height * scale) + 'px';
                    content.style.transformOrigin = 'top left'; content.style.transform = `scale(${scale})`;
                }
            }
            return Math.ceil(document.getElementById('answer').getBoundingClientRect().height) + 4;
            """, arguments: ["source": text, "fontSize": fontSize], in: nil, contentWorld: .page)
        guard let height = result as? Double, height.isFinite, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        guard let output = CGContext(url as CFURL, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }
        var completed = false
        defer { output.closePDF(); web.stopLoading(); if !completed { try? FileManager.default.removeItem(at: url) } }
        for y in stride(from: 0.0, to: height, by: 1024) {
            try Task.checkCancellation()
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: y, width: width, height: min(1024, height-y))
            let data = try await web.pdf(configuration: configuration)
            try autoreleasepool {
                guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { throw CocoaError(.fileReadCorruptFile) }
                var bounds = page.getBoxRect(.mediaBox)
                output.beginPDFPage([kCGPDFContextMediaBox: NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)] as CFDictionary)
                output.drawPDFPage(page); output.endPDFPage()
            }
        }
        try Task.checkCancellation()
        completed = true
        return (url, height)
    }
}

@MainActor private final class AnswerDocumentNavigation: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func finish(_ error: Error? = nil) {
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(CocoaError(.fileReadUnknown)) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.lastPathComponent == "renderer.html" && action.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
