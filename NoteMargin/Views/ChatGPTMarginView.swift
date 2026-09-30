import SwiftUI

struct ChatGPTMarginView: View {
    let conversationID: UUID?
    let project: NoteProject?
    var onClose: (() -> Void)? = nil
    var onSave: ((String) -> Void)? = nil
    var onSource: (() -> Void)? = nil
    @ObservedObject private var ai = MarginAIStore.shared
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var settings = false
    @State private var preview = true
    @State private var deleting = false
    private var chat: MarginConversation? { conversationID.flatMap { ai.conversation($0) } }
    private var readOnly: Bool { chat.map { $0.projectID != project?.id } ?? false }
    private var sending: Bool { conversationID.map { ai.sending.contains($0) } ?? false }
    var body: some View {
        Group {
            if let chat {
                VStack(spacing: 0) {
                    HStack {
                        Label("여백 대화", systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button { settings = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("ChatGPT 구독 연결")
                        Menu {
                            if let onSource { Button("원본 선택 영역으로", action: onSource) }
                            Button("대화 삭제", role: .destructive) { deleting = true }.disabled(sending)
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button { onClose?() } label: { Image(systemName: "xmark") }.accessibilityLabel("여백 대화 닫기").accessibilityIdentifier("ai-chat-close")
                    }.padding()
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DisclosureGroup("선택 이미지와 전송할 맥락", isExpanded: $preview) {
                                VStack(alignment: .leading, spacing: 10) {
                                if let image = UIImage(data: chat.imageData) { Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("ai-region-preview").frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 10)) }
                                Text(chat.sourceDescription).font(.caption)
                                Text("영역 선택 시점의 PDF·필기 이미지, 추출 텍스트, 이 대화 \(chat.messages.count)개 메시지, 고정 조건, 프로젝트 지침을 OpenAI로 전송합니다. 다른 노트는 포함하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                                if !chat.extractedText.isEmpty { Text(chat.extractedText).font(.caption).textSelection(.enabled) }
                                if let project, !project.agentInstructions.isEmpty { Text("프로젝트 지침: " + project.agentInstructions).font(.caption) }
                                Toggle("선택 이미지 첨부", isOn: Binding(get: { chat.includeImage != false }, set: { if !$0 || PlanModelSupport.acceptsImage(connection.model) { ai.configure(chat.id, includeImage: $0) } })).disabled(sending || (chat.includeImage == false && !PlanModelSupport.acceptsImage(connection.model)))
                                Text(PlanModelSupport.acceptsImage(connection.model) ? "공식 명세에서 이미지 입력이 확인된 모델입니다. 계정 정책에 따른 거절은 자동 재시도하지 않습니다." : "현재 모델의 이미지 입력을 확인하지 못했습니다. 이미지 입력이 확인된 모델을 선택하거나 첨부를 꺼 주세요.").font(.caption2).foregroundStyle(.secondary)
                                TextField("고정할 조건·허용 정리", text: Binding(get: { chat.pinnedConditions ?? "" }, set: { ai.configure(chat.id, conditions: $0) }), axis: .vertical).lineLimit(2...5).disabled(sending)
                                }
                            }
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(message.role == .user ? "나" : "ChatGPT").font(.caption.bold())
                                        if let status = message.status { Text(status.title).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    if message.role == .assistant {
                                        MathAnswerView(text: message.text.isEmpty ? (message.status == .streaming ? "답변을 기다리는 중…" : "저장된 텍스트 답변이 없습니다.") : message.text)
                                        HStack {
                                            Menu("복사") {
                                                Button("답변 원문 복사") { UIPasteboard.general.string = message.text }
                                                Button("수식 모아 복사") { UIPasteboard.general.string = AnswerPart.parse(message.text).filter(\.math).map(\.text).joined(separator: "\n\n") }
                                                    .disabled(!AnswerPart.parse(message.text).contains(where: \.math))
                                            }
                                            if let onSave { Button("노트에 저장") { onSave(message.text) }.disabled(message.text.isEmpty || message.status == .streaming) }
                                        }.font(.caption)
                                    } else { Text(message.text).textSelection(.enabled) }
                                    if let diagnostic = message.diagnostic {
                                        Text(diagnostic.summary).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    if let model = message.model { Text(model + " · " + (message.mode ?? .free).title).font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            if let error = ai.failures[chat.id] {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                if ai.needsSaving(chat.id) { Button("저장 다시 시도") { ai.retrySave(chat.id) } }
                            }
                            if !sending, chat.draft?.isEmpty != false,
                               let last = chat.messages.last, last.role == .assistant,
                               let status = last.status, status != .completed && status != .streaming,
                               let question = chat.messages.last(where: { $0.role == .user })?.text {
                                Button("질문 다시 입력") { ai.setDraft(question, for: chat.id) }.disabled(readOnly)
                            }
                        }.padding()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(connection.state.title).font(.caption)
                            Spacer()
                            Link("사용량 관리", destination: URL(string: "https://chatgpt.com/settings/usage")!).font(.caption)
                        }
                        HStack {
                            Picker("질문 모드", selection: Binding(get: { chat.mode ?? .free }, set: { ai.configure(chat.id, mode: $0) })) { ForEach(TutorMode.allCases) { Text($0.title).tag($0) } }
                            Picker("모델", selection: $connection.model) {
                                if connection.models.isEmpty { Text("연결 후 모델 선택").tag("") }
                                ForEach(connection.models) { Text($0.display_name).tag($0.slug) }
                            }
                        }.disabled(sending)
                        if readOnly { Text("이전 프로젝트의 대화입니다. 현재 프로젝트에서 새 영역 대화를 만들어 주세요.").font(.caption) }
                        if connection.state != .ready { Button("ChatGPT 구독 연결 확인") { settings = true } }
                        if (chat.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("기본 질문 · " + (chat.mode ?? .free).title).font(.caption.bold())
                                Text((chat.mode ?? .free).defaultQuestion).font(.caption).foregroundStyle(.secondary)
                            }.accessibilityIdentifier("ai-default-question-preview")
                        }
                        HStack(alignment: .bottom) {
                            TextField("직접 질문 입력 (선택)", text: Binding(get: { chat.draft ?? "" }, set: { ai.setDraft($0, for: chat.id) }), axis: .vertical)
                                .accessibilityIdentifier("ai-question-input").disabled(readOnly || sending)
                                .lineLimit(1...5).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            if sending { Button { ai.cancel(chat.id) } label: { Image(systemName: "stop.circle.fill").font(.title) }.accessibilityLabel("답변 중단") }
                            else {
                                Button { if ai.sendPlan(chat.draft ?? "", conversationID: chat.id, project: project) { preview = false } }
                                label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                                .accessibilityLabel("확인한 영역과 질문 보내기")
                                .disabled(readOnly || connection.state != .ready || connection.model.isEmpty || (chat.includeImage != false && !PlanModelSupport.acceptsImage(connection.model)) || ai.needsSaving(chat.id))
                            }
                        }
                    }.padding(12)
                }
                .sheet(isPresented: $settings) { ChatGPTPlanSettings() }
                .confirmationDialog("이 대화를 삭제할까요?", isPresented: $deleting) {
                    Button("대화 삭제", role: .destructive) { ai.delete(chat.id); if ai.conversation(chat.id) == nil { onClose?() } }
                }
            } else { ChatGPTPlanSettings() }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary)).shadow(color: .black.opacity(0.12), radius: 16)
        .onDisappear { if let conversationID { ai.flushDraft(conversationID) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { connection.cancelSignIn(); ai.cancelPlanRequests() }
        }
        .task { if connection.state == .ready && connection.models.isEmpty { await connection.refreshModels() } }
    }
}

struct ChatGPTPlanSettings: View {
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section("ChatGPT 구독으로 질문하기") {
                    Text(connection.state.title)
                    Text("이 앱의 질문은 연결된 ChatGPT 플랜의 사용량과 허용된 크레딧 설정에 영향을 받습니다. 선택 이미지와 질문·대화 맥락이 OpenAI로 전송됩니다.")
                    Text("현재 iPad 직접 로그인은 실기기 검증이 필요합니다. 시스템 로그인 중 취소하거나 3분 안에 콜백을 받지 못하면 안전하게 중단합니다.").font(.caption).foregroundStyle(.secondary)
                    if connection.state == .signingIn { ProgressView("시스템 인증 화면에서 진행하세요"); Button("로그인 취소") { connection.cancelSignIn() } }
                    else { Button("Continue with ChatGPT") { connection.connect() }.buttonStyle(.borderedProminent).tint(Color(uiColor: .label)).foregroundStyle(Color(uiColor: .systemBackground)).disabled(connection.signingOut) }
                    if connection.state == .permissionRequired {
                        Button("구독 사용 권한 다시 요청") { connection.connect(requestConsent: true) }
                    }
                    Link("사용량 관리", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }
                if !connection.profiles.isEmpty {
                    Section("저장된 계정 등록") {
                        ForEach(connection.profiles) { profile in
                            Button { connection.select(profile.id) } label: { HStack { Text(profile.title); Spacer(); if profile.id == connection.selected { Image(systemName: "checkmark") } } }
                        }
                        Button("다른 계정 추가") { connection.connect(newAccount: true) }
                        Button("모델 목록 새로 고침") { Task { await connection.refreshModels() } }
                        Button("로그아웃", role: .destructive) { connection.logout() }
                    }.disabled(connection.state == .signingIn || connection.signingOut)
                }
                if let notice = connection.notice { Section { Text(notice).font(.callout) } }
                Section { Text("기존 ChatGPT 대화 기록은 가져오지 않습니다. 영역 대화와 부분 답변은 이 앱에 저장됩니다. store:false는 외부 전송이나 모든 서버 보관이 없다는 뜻이 아닙니다.").font(.caption) }
            }
            .navigationTitle("ChatGPT 연결").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { connection.cancelSignIn(); dismiss() } } }
            .alert("ChatGPT 구독을 사용합니다", isPresented: $connection.welcome) {
                Button("확인") { connection.acknowledgeWelcome() }
            } message: { Text("질문은 플랜 사용량과 허용된 크레딧을 사용합니다. 사용량 관리에서 이 앱의 한도와 권한을 확인할 수 있습니다.") }
            .onChange(of: phase) { _, value in if value == .background { connection.cancelSignIn() } }
        }
    }
}
