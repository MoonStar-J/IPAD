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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(AnswerPart.parse(text)) { part in
                if part.math {
                    VStack(alignment: .leading, spacing: 2) {
                        LocalMathView(expression: part.text)
                        Button("수식 복사") { UIPasteboard.general.string = part.text }.font(.caption2)
                    }
                } else { Text(.init(part.text)).font(.callout).textSelection(.enabled).environment(\.openURL, OpenURLAction { _ in .discarded }) }
            }
        }
    }
}
private struct LocalMathView: View {
    let expression: String
    @State private var height: CGFloat = 70
    var body: some View { MathWebView(expression: expression, height: $height).frame(height: height) }
}
private struct MathWebView: UIViewRepresentable {
    let expression: String
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear; view.scrollView.isScrollEnabled = true
        view.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "MathResources") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.expression = expression
        if context.coordinator.loaded { context.coordinator.render(view) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var expression = "", rendered = ""
        var loaded = false
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render(webView) }
        func render(_ view: WKWebView) {
            guard expression != rendered else { return }; rendered = expression
            let value = expression
            Task { try? await view.callAsyncJavaScript("window.drawMath(expression)", arguments: ["expression": value], in: nil, contentWorld: .page) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(!loaded && action.request.url?.lastPathComponent == "renderer.html" && action.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? Double, value.isFinite else { return }
            height.wrappedValue = max(44, min(480, value))
        }
    }
}
