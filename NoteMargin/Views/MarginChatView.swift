import SwiftUI

struct MarginChatView: View {
    let conversationID: UUID
    let note: Notebook
    let project: NoteProject?
    let onClose: () -> Void
    @ObservedObject private var ai = MarginAIStore.shared
    @State private var connecting = false
    @State private var showingSource = false
    @State private var deleting = false

    private var chat: MarginConversation? { ai.conversation(conversationID) }
    private var sending: Bool { ai.sending.contains(conversationID) }
    private var question: Binding<String> {
        Binding(get: { ai.conversation(conversationID)?.draft ?? "" }, set: { ai.setDraft($0, for: conversationID) })
    }

    var body: some View {
        if let chat {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("여백 대화").font(.headline)
                        Text(chat.projectTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("AI 연결", systemImage: "key") { connecting = true }
                        Button("대화 삭제", systemImage: "trash", role: .destructive) { deleting = true }.disabled(sending)
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 36) }
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 32, height: 36) }
                        .accessibilityLabel("여백 대화 닫기").accessibilityIdentifier("ai-chat-close")
                }.padding(14)
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DisclosureGroup(isExpanded: $showingSource) {
                                if let image = UIImage(data: chat.imageData) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .accessibilityLabel("질문에 첨부될 PDF와 필기 영역")
                                }
                                Text(chat.sourceDescription).font(.caption).foregroundStyle(.secondary)
                                if !chat.extractedText.isEmpty {
                                    Text(chat.extractedText).font(.caption).textSelection(.enabled)
                                }
                                Text("영역을 선택한 시점의 내용입니다.").font(.caption2).foregroundStyle(.secondary)
                            } label: { Label("선택 영역 보기", systemImage: "viewfinder").font(.subheadline) }
                            if chat.messages.isEmpty {
                                Text("이 부분에서 궁금한 것을 물어보세요.")
                                    .font(.title3.weight(.medium)).padding(.top, 12)
                                Text("선택 영역의 이미지·추출 텍스트와 이 대화, 프로젝트 지침을 선택한 AI에 보냅니다. API 사용료는 별도입니다.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("AI 연결 설정") { connecting = true }.font(.subheadline)
                            }
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == .user ? "나" : "AI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if message.role == .assistant { Text(.init(message.text)).textSelection(.enabled) }
                                    else { Text(message.text).textSelection(.enabled) }
                                }
                                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(message.role == .user ? Color.accentColor.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            if sending { ProgressView("답변을 기다리는 중…").font(.caption).id("progress") }
                            if let error = ai.failures[chat.id] ?? (!sending && chat.messages.last?.role == .user ? "아직 답변을 받지 못했습니다. 다시 시도하면 같은 질문을 보냅니다." : nil) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(error).font(.caption).foregroundStyle(.secondary)
                                    if ai.needsSaving(chat.id) { Button("저장 다시 시도") { ai.retrySave(chat.id) } }
                                    else if chat.messages.last?.role == .user && chat.belongs(to: note) {
                                        Button("다시 시도") { ai.send("", conversationID: chat.id, note: note, project: project, retry: true) }.disabled(sending)
                                    }
                                    Button("AI 연결 설정") { connecting = true }
                                }.font(.caption)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(16)
                    }
                    .onChange(of: chat.messages.count) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: sending) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
                }
                Divider()
                if chat.belongs(to: note) {
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("이 영역에 대해 질문하세요", text: question, axis: .vertical)
                            .lineLimit(1...5).textFieldStyle(.plain).padding(10)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("ai-question-input")
                        if sending {
                            Button { ai.cancel(chat.id) } label: { Image(systemName: "stop.circle.fill").font(.title) }
                                .accessibilityLabel("AI 답변 중단")
                        } else {
                            Button {
                                ai.send(question.wrappedValue, conversationID: chat.id, note: note, project: project)
                            } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                                .disabled(question.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.needsSaving(chat.id))
                                .accessibilityLabel("AI에 질문 보내기").accessibilityIdentifier("ai-send")
                        }
                    }.padding(12)
                } else {
                    Text("이전 프로젝트에 저장된 대화입니다. 현재 프로젝트에서는 새 질문을 만들어 주세요.")
                        .font(.caption).foregroundStyle(.secondary).padding(14)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 20)).shadow(color: .black.opacity(0.14), radius: 20, y: 8)
            .onDisappear { ai.flushDraft(conversationID) }
            .sheet(isPresented: $connecting) { AIConnectionSettingsView() }
            .confirmationDialog("이 여백 대화를 삭제할까요?", isPresented: $deleting, titleVisibility: .visible) {
                Button("대화 삭제", role: .destructive) { ai.delete(chat.id); if ai.conversation(chat.id) == nil { onClose() } }
            }
        }
    }
}
