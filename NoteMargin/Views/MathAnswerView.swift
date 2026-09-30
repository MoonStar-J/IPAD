import SwiftUI
import WebKit

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
