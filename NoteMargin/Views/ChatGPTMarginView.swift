import SwiftUI

struct ChatGPTMarginView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let conversationID: UUID?
    let project: NoteProject?
    var onClose: (() -> Void)? = nil
    var onSave: ((MarginMessage, Bool) async throws -> Void)? = nil
    var onAttach: (() -> Void)? = nil
    var onSource: (() -> Void)? = nil
    @ObservedObject var ai = MarginAIStore.shared
    @ObservedObject var connection = ChatGPTPlanConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var insertion: Task<Void, Never>?
    @State private var insertionID: UUID?
    @State private var insertionNotice: AppMessage?
    @State private var settings = false
    @State private var preview = true
    @State private var deleting = false
    @State private var memory = false
    @State private var presetSettings = false
    @AppStorage(AIQuestionPreferences.key) private var presetData = Data()
    private var presets: [AIQuestionPreset] { (try? AIQuestionPreferences.decode(presetData)) ?? [] }
    private var selectedPreset: AIQuestionPreset {
        chat?.draftPreset ?? AIQuestionPreset.selected(id: chat?.presetID, mode: chat?.mode, from: presets)
    }
    @State private var quoting: MarginMessage?
    private var chat: MarginConversation? { conversationID.flatMap { ai.conversation($0) } }
    private var readOnly: Bool { chat.map { $0.projectID != project?.id } ?? false }
    private var sending: Bool { conversationID.map { ai.sending.contains($0) } ?? false }
    private func insert(_ message: MarginMessage, summarized: Bool) {
        guard insertion == nil, let onSave else { return }
        let operation = UUID(); insertionID = operation; insertionNotice = nil
        insertion = Task { @MainActor in
            defer { if insertionID == operation { insertion = nil; insertionID = nil } }
            do {
                try await onSave(message, summarized)
                insertionNotice = AppMessage("노트에 넣었습니다.")
            } catch is CancellationError { insertionNotice = AppMessage("취소되었습니다.") }
            catch { insertionNotice = AppMessage(error) }
        }
    }

    var body: some View {
        Group {
            if let chat {
                VStack(spacing: 0) {
                    HStack {
                        Label(localized("여백 대화", language: appLanguage), systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button { settings = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel(localized("ChatGPT 구독 연결", language: appLanguage))
                        Menu {
                            Button(localized("AI 질문 프리셋", language: appLanguage)) { presetSettings = true }
                            Button(localized("맥락 보기", language: appLanguage)) { memory = true }
                            if let onAttach { Button(localized("현재 문제에 추가", language: appLanguage), action: onAttach).disabled(sending || readOnly) }
                            if let onSource { Button(localized("원본 선택 영역으로", language: appLanguage), action: onSource) }
                            Button(localized("대화 삭제", language: appLanguage), role: .destructive) { deleting = true }.disabled(sending)
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button { onClose?() } label: { Image(systemName: "xmark") }.accessibilityLabel(localized("여백 대화 닫기", language: appLanguage)).accessibilityIdentifier("ai-chat-close")
                    }.padding()
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DisclosureGroup(localized("선택 이미지와 전송할 맥락", language: appLanguage), isExpanded: $preview) {
                                VStack(alignment: .leading, spacing: 10) {
                                if let image = UIImage(data: chat.imageData) { Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("ai-region-preview").frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 10)) }
                                Text(localizedSourceDescription(chat.sourceDescription, language: appLanguage)).font(.caption)
                                Text(localized("이 문제의 자료와 대화에서 이번 요청에 포함할 맥락을 구성합니다. 정확한 포함·제외 내역은 ‘맥락 보기’에서 확인하세요. 다른 문제는 포함하지 않습니다.", language: appLanguage)).font(.caption).foregroundStyle(.secondary)
                                Text(localized("선택한 영역의 PDF와 필기가 합쳐진 이미지 자체를 전송합니다.", language: appLanguage)).font(.caption).foregroundStyle(.secondary)
                                if let project, !project.agentInstructions.isEmpty { Text(localized("프로젝트 지침: ", language: appLanguage) + project.agentInstructions).font(.caption) }
                                Button(localized("맥락 보기 · 원본 / 전사문 · 조건 정정", language: appLanguage)) { memory = true }
                                Text(localized("원본 이미지와 추가 풀이 이미지를 같은 문제 안에서 보존합니다. 실제 포함 항목은 ‘맥락 보기’에서 확인하세요.", language: appLanguage)).font(.caption2).foregroundStyle(.secondary)
                                TextField(localized("고정할 조건·허용 정리", language: appLanguage), text: Binding(get: { chat.pinnedConditions ?? "" }, set: { ai.configure(chat.id, conditions: $0) }), axis: .vertical).lineLimit(2...5).disabled(sending)
                                }
                            }
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(message.role == .user ? localized("나", language: appLanguage) : "ChatGPT").font(.caption.bold())
                                        if let status = message.status { Text(status.title).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    if message.role == .assistant {
                                        MathAnswerView(text: message.text.isEmpty ? (message.status == .streaming ? localized("답변을 기다리는 중…", language: appLanguage) : localized("저장된 텍스트 답변이 없습니다.", language: appLanguage)) : message.text)
                                        HStack {
                                            Menu(localized("복사", language: appLanguage)) {
                                                Button(localized("답변 원문 복사", language: appLanguage)) { UIPasteboard.general.string = message.text }
                                                Button(localized("수식 모아 복사", language: appLanguage)) { UIPasteboard.general.string = AnswerPart.parse(message.text).filter(\.math).map(\.text).joined(separator: "\n\n") }
                                                    .disabled(!AnswerPart.parse(message.text).contains(where: \.math))
                                            }
                                            Button(localized("이 부분 질문", language: appLanguage)) { quoting = message }.disabled(sending || readOnly || message.text.isEmpty || message.status == .streaming)
                                            if onSave != nil {
                                                Menu(localized("노트에 저장", language: appLanguage)) {
                                                    Button(localized("답변 전체 옮기기", language: appLanguage)) { insert(message, summarized: false) }
                                                    Button(localized("요약해서 노트에 넣기", language: appLanguage)) { insert(message, summarized: true) }
                                                }.disabled(message.text.isEmpty || message.status == .streaming || insertion != nil || readOnly)
                                            }
                                        }.font(.caption)
                                    } else { Text(message.displayText(in: appLanguage)).textSelection(.enabled) }
                                    if let reply = message.replyTo { Text(localized("인용: ", language: appLanguage) + reply.quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    ForEach(chat.sourceAttachments.filter { (message.attachmentIDs ?? []).contains($0.id) }) { attachment in
                                        if let image = UIImage(data: attachment.data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160) }
                                        Text(localizedSourceDescription(attachment.sourceDescription, language: appLanguage)).font(.caption)
                                    }
                                    if let diagnostic = message.diagnostic {
                                        Text(diagnostic.summary).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    if let model = message.model { Text(model + " · " + (message.preset?.displayName(in: appLanguage) ?? localized((message.mode ?? .free).title, language: appLanguage))).font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            if insertion != nil {
                                ProgressView(localized("노트에 넣는 중…", language: appLanguage))
                                Button(localized("취소", language: appLanguage)) { insertion?.cancel() }
                            }
                            if let insertionNotice { Text(insertionNotice.text).font(.caption).textSelection(.enabled) }
                            if let error = ai.failures[chat.id] {
                                Text(error.text).font(.caption).foregroundStyle(.secondary)
                                if ai.needsSaving(chat.id) { Button(localized("저장 다시 시도", language: appLanguage)) { ai.retrySave(chat.id) } }
                            }
                            if !sending, chat.draft?.isEmpty != false,
                               let last = chat.messages.last, last.role == .assistant,
                               let status = last.status, status != .completed && status != .streaming,
                               chat.messages.contains(where: { $0.role == .user }) {
                                Button(localized("질문 다시 입력", language: appLanguage)) { ai.retryQuestion(chat.id) }.disabled(readOnly)
                            }
                        }.padding()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(connection.state.title).font(.caption)
                            Spacer()
                            Link(localized("사용량 관리", language: appLanguage), destination: URL(string: "https://chatgpt.com/settings/usage")!).font(.caption)
                        }
                        HStack {
                            Picker(localized("AI 질문 프리셋", language: appLanguage), selection: Binding(get: { chat.draftPreset == nil ? selectedPreset.id : "retry" }, set: { ai.selectPreset(chat.id, presetID: $0) })) {
                                if chat.draftPreset != nil { Text(localized("재시도 · ", language: appLanguage) + selectedPreset.displayName(in: appLanguage)).tag("retry") }
                                Text(localized("직접 질문 (기본 질문 없음)", language: appLanguage)).tag(AIQuestionPreset.direct.id)
                                ForEach(presets) { Text($0.name.isEmpty ? localized("이름 없는 프리셋", language: appLanguage) : $0.displayName(in: appLanguage)).tag($0.id) }
                            }.accessibilityIdentifier("ai-preset-picker")
                            Picker(localized("모델", language: appLanguage), selection: $connection.model) {
                                if connection.models.isEmpty { Text(localized("연결 후 모델 선택", language: appLanguage)).tag("") }
                                ForEach(connection.models) { Text($0.display_name).tag($0.slug) }
                            }
                        }.disabled(sending)
                        if chat.draftPreset != nil { Text(localized("이전 요청의 지침을 사용합니다. 새 지침으로 질문하려면 프리셋을 다시 선택하세요.", language: appLanguage)).font(.caption) }
                        else if selectedPreset.id == AIQuestionPreset.direct.id { Text(localized("선택한 프리셋이 없으므로 질문을 직접 입력해 주세요.", language: appLanguage)).font(.caption) }
                        if readOnly { Text(localized("이전 프로젝트의 대화입니다. 현재 프로젝트에서 새 영역 대화를 만들어 주세요.", language: appLanguage)).font(.caption) }
                        if connection.state != .ready { Button(localized("ChatGPT 구독 연결 확인", language: appLanguage)) { settings = true } }
                        if (chat.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(localized("기본 질문 · ", language: appLanguage) + selectedPreset.displayName(in: appLanguage)).font(.caption.bold())
                                Text(selectedPreset.question.isEmpty ? localized("질문을 직접 입력해 주세요.", language: appLanguage) : selectedPreset.displayQuestion(in: appLanguage)).font(.caption).foregroundStyle(.secondary)
                            }.accessibilityIdentifier("ai-default-question-preview")
                        }
                        if let reply = chat.draftReply {
                            HStack {
                                Text(localized("이 부분 질문: ", language: appLanguage) + reply.quote).font(.caption).lineLimit(3)
                                Button(localized("인용 해제", language: appLanguage)) { ai.setReply(nil, for: chat.id) }.font(.caption).disabled(sending)
                            }
                        }
                        HStack(alignment: .bottom) {
                            TextField(localized("직접 질문 입력 (선택)", language: appLanguage), text: Binding(get: { chat.draft ?? "" }, set: { ai.setDraft($0, for: chat.id) }), axis: .vertical)
                                .accessibilityIdentifier("ai-question-input").disabled(readOnly || sending)
                                .lineLimit(1...5).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            if sending { Button { ai.cancel(chat.id) } label: { Image(systemName: "stop.circle.fill").font(.title) }.accessibilityLabel(localized("답변 중단", language: appLanguage)) }
                            else {
                                Button { if ai.sendPlan(chat.draft ?? "", conversationID: chat.id, project: project) { preview = false } }
                                label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                                .accessibilityLabel(localized("확인한 영역과 질문 보내기", language: appLanguage))
                                .disabled(readOnly || connection.state != .ready || connection.model.isEmpty || ai.needsSaving(chat.id))
                            }
                        }
                    }.padding(12)
                }
                .sheet(isPresented: $presetSettings) { NavigationStack { AIQuestionPresetSettings().toolbar { ToolbarItem(placement: .confirmationAction) { Button(localized("완료", language: appLanguage)) { presetSettings = false } } } } }
                .sheet(isPresented: $memory) { ConversationMemoryView(id: chat.id, project: project) }
                .sheet(item: $quoting) { message in ReplySelectionView(message: message) { ai.setReply($0, for: chat.id) } }
                .sheet(isPresented: $settings) { ChatGPTPlanSettings() }
                .confirmationDialog(localized("이 대화를 삭제할까요?", language: appLanguage), isPresented: $deleting) {
                    Button(localized("대화 삭제", language: appLanguage), role: .destructive) { ai.delete(chat.id); if ai.conversation(chat.id) == nil { onClose?() } }
                }
            } else { ChatGPTPlanSettings() }
        }
        .background(Color(uiColor: .systemGroupedBackground), in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary)).shadow(color: .black.opacity(0.12), radius: 16)
        // The store owns accepted requests; closing/switching panels only saves
        // the draft. The stop button remains the explicit per-answer cancellation.
        .onChange(of: presetData) { _, _ in if let conversationID { ai.refreshPreset(conversationID) } }
        .onChange(of: sending) { _, value in if !value, let conversationID { ai.refreshPreset(conversationID) } }
        .onAppear { if let conversationID { ai.refreshPreset(conversationID) } }
        .onDisappear { insertion?.cancel(); if let conversationID { ai.flushDraft(conversationID) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { connection.cancelSignIn(); ai.cancelPlanRequests() }
        }
        .task { if connection.state == .ready && connection.models.isEmpty { await connection.refreshModels() } }
    }
}

struct ChatGPTPlanSettings: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    var onDone: (() -> Void)? = nil
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section(localized("ChatGPT 구독으로 질문하기", language: appLanguage)) {
                    Text(connection.state.title)
                    Text(localized("이 앱의 질문은 연결된 ChatGPT 플랜의 사용량과 허용된 크레딧 설정에 영향을 받습니다. 선택 이미지와 질문·대화 맥락이 OpenAI로 전송됩니다.", language: appLanguage))
                    Text(localized("현재 iPad 직접 로그인은 실기기 검증이 필요합니다. 시스템 로그인 중 취소하거나 3분 안에 콜백을 받지 못하면 안전하게 중단합니다.", language: appLanguage)).font(.caption).foregroundStyle(.secondary)
                    if connection.state == .signingIn { ProgressView(localized("시스템 인증 화면에서 진행하세요", language: appLanguage)); Button(localized("로그인 취소", language: appLanguage)) { connection.cancelSignIn() } }
                    else { Button("Continue with ChatGPT") { connection.connect() }.buttonStyle(.borderedProminent).tint(Color(uiColor: .label)).foregroundStyle(Color(uiColor: .systemBackground)).disabled(connection.signingOut) }
                    if connection.state == .permissionRequired {
                        Button(localized("구독 사용 권한 다시 요청", language: appLanguage)) { connection.connect(requestConsent: true) }
                    }
                    Link(localized("사용량 관리", language: appLanguage), destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }
                if !connection.profiles.isEmpty {
                    Section(localized("저장된 계정 등록", language: appLanguage)) {
                        ForEach(connection.profiles) { profile in
                            Button { connection.select(profile.id) } label: { HStack { Text(profile.title(in: appLanguage)); Spacer(); if profile.id == connection.selected { Image(systemName: "checkmark") } } }
                        }
                        Button(localized("다른 계정 추가", language: appLanguage)) { connection.connect(newAccount: true) }
                        Button(localized("모델 목록 새로 고침", language: appLanguage)) { Task { await connection.refreshModels() } }
                        Button(localized("로그아웃", language: appLanguage), role: .destructive) { connection.logout() }
                    }.disabled(connection.state == .signingIn || connection.signingOut)
                }
                if let notice = connection.notice { Section { Text(notice.text).font(.callout) } }
                Section { Text(localized("기존 ChatGPT 대화 기록은 가져오지 않습니다. 영역 대화와 부분 답변은 이 앱에 저장됩니다. store:false는 외부 전송이나 모든 서버 보관이 없다는 뜻이 아닙니다.", language: appLanguage)).font(.caption) }
            }
            .navigationTitle(localized("ChatGPT 연결", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(localized("완료", language: appLanguage)) { connection.cancelSignIn(); if let onDone { onDone() } else { dismiss() } } } }
            .alert(localized("ChatGPT 구독을 사용합니다", language: appLanguage), isPresented: $connection.welcome) {
                Button(localized("확인", language: appLanguage)) { connection.acknowledgeWelcome() }
            } message: { Text(localized("질문은 플랜 사용량과 허용된 크레딧을 사용합니다. 사용량 관리에서 이 앱의 한도와 권한을 확인할 수 있습니다.", language: appLanguage)) }
            .onChange(of: phase) { _, value in if value == .background { connection.cancelSignIn() } }
        }
    }
}
