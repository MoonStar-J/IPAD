#if PERSONAL_CHATGPT
import SwiftUI
import WebKit
import UniformTypeIdentifiers

private struct RegionPNG: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PersonalChatGPTView: View {
    let conversationID: UUID?
    let project: NoteProject?
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var ai = MarginAIStore.shared
    @StateObject private var browser: ChatGPTBrowser
    @State private var showingRegion = false
    @State private var exporting = false
    @State private var help = false
    @State private var notice: String?
    @State private var pastedLink = ""
    @State private var linking = false
    @State private var deleting = false

    @MainActor init(conversationID: UUID?, project: NoteProject?, onClose: (() -> Void)? = nil, browser: ChatGPTBrowser? = nil) {
        self.conversationID = conversationID; self.project = project; self.onClose = onClose
        _showingRegion = State(initialValue: conversationID != nil)
        _browser = StateObject(wrappedValue: browser ?? ChatGPTBrowserTabs.shared.browser(
            for: conversationID, url: conversationID.flatMap { MarginAIStore.shared.conversation($0)?.webConversationURL }))
    }
    private var chat: MarginConversation? { conversationID.flatMap { ai.conversation($0) } }
    private var question: Binding<String> {
        Binding(get: { chat?.draft ?? "" }, set: { if let id = conversationID { ai.setDraft($0, for: id) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChatGPT · 개인용").font(.headline)
                    Text(chat?.projectTitle ?? "내 ChatGPT 계정으로 로그인").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("ChatGPT 홈", systemImage: "house") { browser.cancelAutomation(); browser.webView.load(URLRequest(url: ChatGPTWebContext.home)) }
                    Button("새로고침", systemImage: "arrow.clockwise") { browser.cancelAutomation(); browser.webView.reload() }
                    if chat != nil {
                        Button("대화 링크 직접 연결", systemImage: "link") { linking = true }
                        Button("이 여백 연결 삭제", systemImage: "trash", role: .destructive) { deleting = true }
                    }
                    Button("Safari로 열기", systemImage: "safari") {
                        openURL(ChatGPTWebContext.conversationURL(browser.url) ?? ChatGPTWebContext.home)
                    }
                    Button("로그인 · 첨부 도움말", systemImage: "questionmark.circle") { help = true }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 32) }
                .accessibilityLabel("ChatGPT 메뉴")
                Button { close() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("여백 대화 닫기").accessibilityIdentifier("ai-chat-close")
            }.padding(12)
            HStack {
                Button { browser.cancelAutomation(); browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.webView.canGoBack).accessibilityLabel("웹 뒤로")
                Image(systemName: "lock").font(.caption2)
                Text(browser.url?.host ?? "chatgpt.com").font(.caption).lineLimit(1)
                Spacer()
                if chat != nil { Text(chat?.webConversationURL == nil ? "대화 시작 후 링크 자동 저장" : "대화 링크 저장됨").font(.caption2) }
                if browser.loading { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, 14).padding(.bottom, 8)
            if let chat {
                DisclosureGroup(isExpanded: $showingRegion) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let image = UIImage(data: chat.imageData) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                                    .accessibilityLabel("선택한 PDF와 필기 이미지")
                                    .onDrag { NSItemProvider(object: image) }
                            }
                            Text(chat.sourceDescription).font(.caption).foregroundStyle(.secondary)
                            TextField("이 영역에 대한 질문", text: question, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(1...3).accessibilityIdentifier("personal-question").disabled(browser.automating)
                            HStack {
                                Button {
                                    browser.sendRegion(imageData: chat.imageData, prompt: ChatGPTWebContext.prompt(chat: chat, project: project, question: question.wrappedValue))
                                } label: {
                                    Label(browser.automating ? "첨부 확인 중…" : "ChatGPT로 보내기", systemImage: "arrow.up.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(browser.automating || question.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("personal-auto-send")
                                if browser.automating { Button("중단") { browser.cancelAutomation() } }
                            }
                            Text("자동 첨부 · 전송은 실험 기능입니다. ChatGPT 화면이 바뀌면 직접 전송이 필요할 수 있습니다.")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let message = browser.automationMessage {
                                Text(message).font(.caption).accessibilityIdentifier("personal-automation-status")
                            }
                            ViewThatFits {
                                HStack { transferButtons(chat) }
                                VStack(alignment: .leading) { transferButtons(chat) }
                            }
                            Text("직접 보내려면: ① 질문·자료 복사 → 아래 채팅에 붙여넣기  ② 이미지 복사 후 붙여넣기, 또는 PNG를 저장하고 ChatGPT의 +에서 첨부  ③ ChatGPT에서 전송")
                                .font(.caption).foregroundStyle(.secondary)
                            if let notice { Text(notice).font(.caption).foregroundStyle(.tint).accessibilityIdentifier("personal-notice") }
                        }.padding(.vertical, 8)
                    }.frame(maxHeight: 280)
                } label: { Label("선택 영역 · 질문 준비", systemImage: "viewfinder").font(.subheadline) }
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .accessibilityIdentifier("personal-region")
            }
            if let error = browser.failure {
                HStack {
                    Text(error).font(.caption)
                    Button("새로고침") { browser.cancelAutomation(); browser.webView.reload() }
                }.padding(12).background(Color.orange.opacity(0.1))
            }
            Divider()
            ChatGPTWebView(webView: browser.webView)
                .accessibilityIdentifier("personal-chatgpt-web")
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onChange(of: browser.url) { _, url in
            guard let id = conversationID, let clean = ChatGPTWebContext.conversationURL(url),
                  chat?.webConversationURL != clean else { return }
            ai.linkWebConversation(clean, to: id)
        }
        .onDisappear { browser.cancelAutomation(); if let id = conversationID { ai.flushDraft(id) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { browser.cancelAutomation() } }
        .onChange(of: browser.automating) { _, active in if active { showingRegion = true } }
        .fileExporter(isPresented: $exporting, document: RegionPNG(data: chat?.imageData ?? Data()), contentType: .png, defaultFilename: "note-margin-region") { result in
            switch result {
            case .success: notice = "PNG를 저장했습니다. ChatGPT의 +에서 파일을 첨부하세요."
            case .failure: notice = "PNG를 저장하지 못했습니다. 다시 시도해 주세요."
            }
        }
        .sheet(isPresented: Binding(get: { browser.popup != nil }, set: { if !$0 { browser.popup = nil } })) {
            if let popup = browser.popup { ChatGPTLoginPopup(webView: popup, onClose: { browser.popup = nil }) }
        }
        .alert("ChatGPT 사용 안내", isPresented: $help) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("실제 ChatGPT 웹 화면입니다. 기존에 가입한 로그인 방식으로 로그인하세요. 로그인 정보는 이 앱의 WebKit에 유지됩니다. Google·Apple 등의 로그인이나 보안 검증은 내장 브라우저를 거부할 수 있습니다. 이 경우 Safari에서 이용하세요. Safari 로그인은 이 앱으로 옮겨지지 않습니다.\n\nAPI 키와 API 요금은 사용하지 않습니다. ChatGPT 계정의 이용 한도가 적용됩니다. ‘ChatGPT로 보내기’는 웹 입력창에 이미지와 질문을 자동으로 넣고 첨부 상태를 확인한 뒤 한 번 전송합니다. 화면을 인식하지 못하면 중단하므로 직접 첨부·전송할 수도 있습니다. 프로젝트 지침은 ‘질문·자료 복사’에 포함됩니다. ChatGPT 프로젝트는 웹에서 직접 선택해야 하며 앱 프로젝트와 자동 동기화되지 않습니다. 답변 원문은 ChatGPT에, 대화 링크와 선택 영역은 이 앱에 저장됩니다.")
        }
        .confirmationDialog("이 여백의 선택 영역과 대화 연결을 삭제할까요? ChatGPT의 대화는 유지됩니다.", isPresented: $deleting, titleVisibility: .visible) {
            Button("여백 연결 삭제", role: .destructive) {
                guard let id = conversationID else { return }
                ai.delete(id)
                if ai.conversation(id) == nil { ChatGPTBrowserTabs.shared.close(id); close() }
            }
        }
        .alert("ChatGPT 대화 링크 연결", isPresented: $linking) {
            TextField("https://chatgpt.com/c/…", text: $pastedLink).textInputAutocapitalization(.never)
            Button("연결") {
                guard let id = conversationID, let clean = ChatGPTWebContext.conversationURL(URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines))) else {
                    notice = "chatgpt.com의 대화 주소를 입력해 주세요. 공유 링크는 지원하지 않습니다."; showingRegion = true; return
                }
                if ai.linkWebConversation(clean, to: id) { browser.webView.load(URLRequest(url: clean)) }
            }
            Button("취소", role: .cancel) {}
        } message: { Text("Safari에서 이용한 대화도 주소를 복사해 이 여백에 연결할 수 있습니다.") }
    }

    @ViewBuilder private func transferButtons(_ chat: MarginConversation) -> some View {
        Button("질문·자료 복사") {
            UIPasteboard.general.string = ChatGPTWebContext.prompt(chat: chat, project: project, question: question.wrappedValue)
            notice = "질문과 추출 텍스트를 복사했습니다. ChatGPT 입력칸에 붙여넣으세요."
        }.accessibilityIdentifier("personal-copy-prompt")
        Button("이미지 복사") {
            UIPasteboard.general.setData(chat.imageData, forPasteboardType: UTType.png.identifier)
            notice = "이미지를 복사했습니다. ChatGPT 입력칸에서 붙여넣으세요."
        }.accessibilityIdentifier("personal-copy-image")
        Button("PNG 저장") { exporting = true }
    }
    private func close() {
        browser.cancelAutomation()
        if let id = conversationID { ai.flushDraft(id) }
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct ChatGPTLoginPopup: View {
    let webView: WKWebView
    let onClose: () -> Void
    @State private var host = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(host).font(.caption).lineLimit(1)
                Spacer()
                Button("닫기", action: onClose)
            }.padding()
            ChatGPTWebView(webView: webView)
        }.onReceive(webView.publisher(for: \.url)) { host = $0?.host ?? "로그인 창" }
    }
}
#endif
