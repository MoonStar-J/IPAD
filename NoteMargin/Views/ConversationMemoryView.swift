import SwiftUI

/// Exact source selection, rather than copying rendered LaTeX glyphs back into a lossy string.
struct ReplySelectionView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let message: MarginMessage
    let onSelect: (MessageReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("문장이나 수식을 길게 눌러 범위를 선택하세요. 수식은 LaTeX 원문 그대로 인용됩니다.", language: appLanguage)).font(.callout)
                SourceSelectionText(text: message.text, selected: $selected)
                Text(selected.isEmpty ? localized("선택한 원문 없음", language: appLanguage) : selected).font(.caption).lineLimit(5)
            }.padding().navigationTitle(localized("이 부분 질문", language: appLanguage))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(localized("이 부분 질문", language: appLanguage)) {
                            onSelect(.init(messageID: message.id, revision: message.sourceRevision, quote: selected)); dismiss()
                        }.disabled(selected.isEmpty || !message.text.contains(selected))
                    }
                }
        }
    }
}
private struct SourceSelectionText: UIViewRepresentable {
    let text: String
    @Binding var selected: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator; view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceSelectionText
        init(_ parent: SourceSelectionText) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange, source = parent.text as NSString
            parent.selected = range.location + range.length <= source.length ? source.substring(with: range) : ""
        }
    }
}

struct ConversationMemoryView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let id: UUID
    let project: NoteProject?
    @ObservedObject private var ai = MarginAIStore.shared
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    @Environment(\.dismiss) private var dismiss
    @State private var before = ""
    @State private var after = ""
    @State private var compressionConsent = false
    @State private var transcriptionImage: ConversationAttachment?
    @State private var reviewing: MemorySnapshot?
    private var chat: MarginConversation? { ai.conversation(id) }
    private var result: Result<(ContextPlan, ContextManifest), Error> {
        Result { try ai.previewContext(id, project: project, model: connection.model) }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let chat {
                    Section(localized("이번 질문의 맥락", language: appLanguage)) {
                        Text(localized("작성 중 질문과 선택한 유형의 기본 질문을 반영한 로컬 미리보기입니다. 전송하면 불변 기록이 별도로 저장됩니다.", language: appLanguage)).font(.caption)
                        switch result {
                        case .success(let preview):
                            let plan = preview.0, manifest = preview.1
                            Text(localized("이미지 %@개 · 원문 메시지 %@개 · 요약으로 대체 %@개", "\(manifest.images.count)", "\(manifest.messages.count)", "\(manifest.omitted.count)", language: appLanguage))
                            Text(localized("입력 추정 %@ · 이미지 추정 %@ · HTTP %@ bytes", "\(manifest.estimatedTokens)", "\(manifest.estimatedImageTokens)", "\(manifest.httpBytes)", language: appLanguage)).font(.caption)
                            if manifest.estimatedTokens > chat.policy.usable { Text(ContextAction.overflow.localizedDescription).foregroundStyle(.orange) }
                            if manifest.snapshotID != nil { Text(localized("압축 범위: 과거 메시지 %@개. 보호 조건·수식·인용 대상은 원문으로 유지합니다.", "\(manifest.summaryCoverage.count)", language: appLanguage)).font(.caption) }
                            ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                                DisclosureGroup(item.role == "assistant" ? localized("이전 답변 원문", language: appLanguage) : localized("질문 / 원본 자료", language: appLanguage)) {
                                    Text(item.text).font(.caption).textSelection(.enabled)
                                    ForEach(item.images) { image in
                                        if let ui = UIImage(data: image.data) { Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 200) }
                                        Text(localizedSourceDescription(image.sourceDescription, language: appLanguage)).font(.caption)
                                    }
                                }
                            }
                            DisclosureGroup(localized("민감 정보 제외 manifest", language: appLanguage)) { Text(manifest.redactedJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        case .failure(let error): Text(error.localizedDescription).foregroundStyle(.orange)
                        }
                    }
                    Section(localized("문제 원본 · 전사문", language: appLanguage)) {
                        ForEach(chat.sourceAttachments) { image in
                            VStack(alignment: .leading) {
                                Text(localizedSourceDescription(image.sourceDescription, language: appLanguage))
                                Text(image.useApprovedText ? localized("원본 이미지와 확인된 보조 전사문 사용", language: appLanguage) : localized("원본 사용 설정", language: appLanguage)).font(.caption)
                                Button(localized("원본 / 확인된 텍스트 설정", language: appLanguage)) { transcriptionImage = image }.disabled(ai.sending.contains(id) || chat.projectID != project?.id)
                            }
                        }
                    }
                    Section(localized("조건 고정 · 정정", language: appLanguage)) {
                        TextField(localized("예: 로피탈 정리는 사용하지 않음", language: appLanguage), text: Binding(get: { chat.pinnedConditions ?? "" }, set: { ai.configure(id, conditions: $0) }), axis: .vertical)
                        TextField(localized("잘못 읽은 원문 (예: n^3)", language: appLanguage), text: $before)
                        TextField(localized("올바른 조건 (예: n^2)", language: appLanguage), text: $after)
                        Button(localized("정정 기록 추가", language: appLanguage)) { ai.correct(id, before: before, after: after); before = ""; after = "" }.disabled(before.isEmpty || after.isEmpty)
                        ForEach(chat.corrections ?? []) { correction in
                            Text("\(correction.before) → \(correction.after)").font(.caption).textSelection(.enabled)
                        }
                    }.disabled(chat.projectID != project?.id)
                    Section(localized("입력 예산과 대화 압축", language: appLanguage)) {
                        Stepper(localized("앱 입력 예산: %@", "\(chat.policy.inputTokens)", language: appLanguage), value: Binding(get: { chat.policy.inputTokens }, set: { ai.setBudget(id, tokens: $0) }), in: 6000...200000, step: 2000)
                        Text(localized("모델 용량이나 잔여 구독량이 아닙니다. 텍스트 UTF-8 크기와 이미지 크기로 보수적으로 추정하며, %@은 출력·추정 오차 여유로 남깁니다. 공급자의 출력 상한을 설정하지 않습니다.", "\(chat.policy.reserveTokens)", language: appLanguage)).font(.caption)
                        Text(localized("자동 압축은 사용하지 않습니다. 짧은 질문은 답변 요청 1회만 사용합니다. ‘대화 압축’은 연결된 플랜을 사용하는 추가 요청 1회입니다.", language: appLanguage)).font(.caption)
                        Button(localized("대화 압축", language: appLanguage)) { compressionConsent = true }.disabled(ai.sending.contains(id))
                        ForEach((chat.snapshots ?? []).reversed()) { snapshot in
                            VStack(alignment: .leading) {
                                Text(localized("%@개 메시지 · %@", "\(snapshot.coverage.count)", "\(chat.valid(snapshot) ? (snapshot.reviewed ? localized("사용자 검토됨", language: appLanguage) : localized("미검토 AI 요약", language: appLanguage)) : localized("무효화됨", language: appLanguage))", language: appLanguage)).font(.caption)
                                Button(localized("요약 검토·수정", language: appLanguage)) { reviewing = snapshot }.disabled(!chat.valid(snapshot))
                            }
                        }
                        if let error = ai.failures[id] { Text(error.text).font(.caption).foregroundStyle(.orange) }
                    }.disabled(ai.sending.contains(id) || chat.projectID != project?.id)
                    Section(localized("실제 요청 기록", language: appLanguage)) {
                        Text(localized("답변 %@회 · 압축 %@회 (시작 전 저장 기록 포함)", "\((chat.runs ?? []).filter { $0.kind == .answer }.count)", "\((chat.runs ?? []).filter { $0.kind == .compression }.count)", language: appLanguage)).font(.caption)
                        ForEach((chat.runs ?? []).reversed()) { run in
                            DisclosureGroup("\(run.kind == .answer ? localized("답변", language: appLanguage) : localized("압축", language: appLanguage)) · \(run.state.title)") {
                                Text(run.manifest.redactedJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if let ms = run.firstTextMilliseconds { Text(localized("첫 텍스트까지 %@ms", "\(ms)", language: appLanguage)) }
                                if let input = run.reportedInputTokens { Text(localized("공급자 보고 입력 토큰: %@", "\(input)", language: appLanguage)) }
                                if let output = run.reportedOutputTokens { Text(localized("공급자 보고 출력 토큰: %@", "\(output)", language: appLanguage)) }
                                if let cached = run.reportedCachedTokens { Text(localized("공급자 보고 캐시 토큰: %@", "\(cached)", language: appLanguage)) }
                            }
                        }
                    }
                }
            }.navigationTitle(localized("맥락 보기", language: appLanguage))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(localized("완료", language: appLanguage)) { dismiss() } } }
                .confirmationDialog(localized("대화 압축에 ChatGPT 플랜을 사용합니다", language: appLanguage), isPresented: $compressionConsent) {
                    Button(localized("추가 요청 1회로 압축", language: appLanguage)) { _ = ai.compress(id, project: project) }
                } message: { Text(localized("이전 원문과 이미지는 보존됩니다. 결과는 검토되지 않은 요약이며, 입력 예산을 넘을 때만 사용됩니다.", language: appLanguage)) }
                .sheet(item: $transcriptionImage) { image in TranscriptionView(image: image) { text, use in ai.setTranscription(id, imageID: image.id, text: text, use: use) } }
                .sheet(item: $reviewing) { snapshot in SummaryReviewView(snapshot: snapshot) { summary in ai.reviewSummary(id, snapshotID: snapshot.id, summary: summary) } }
        }
    }
}
private struct TranscriptionView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let image: ConversationAttachment
    let onSave: (String, Bool) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let ui = UIImage(data: image.data) { Image(uiImage: ui).resizable().scaledToFit() }
                Text(localized("원본 스크린샷은 항상 전송합니다. 직접 확인한 전사문은 보조 설명으로 함께 보낼 수 있습니다.", language: appLanguage))
                TextEditor(text: $text).frame(minHeight: 160)
                Button(localized("원본 이미지와 전사문 함께 사용", language: appLanguage)) { onSave(text, true); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(localized("원본 이미지만 사용", language: appLanguage)) { onSave(text, false); dismiss() }
            }.navigationTitle(localized("원본 / 전사문", language: appLanguage))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { dismiss() } } }
                .onAppear { text = image.approvedTranscription ?? image.extractedText }
        }
    }
}
private struct SummaryReviewView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let snapshot: MemorySnapshot
    let onSave: (DiscussionSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = false
    var body: some View {
        NavigationStack {
            VStack {
                Text(localized("AI가 생성한 요약입니다. 수학적 정확성을 보장하지 않습니다. 원문 보호 항목은 별도로 유지됩니다.", language: appLanguage)).font(.caption)
                TextEditor(text: $text)
                if error { Text(localized("문자열 배열 5개를 가진 JSON 형식을 유지해 주세요.", language: appLanguage)).foregroundStyle(.orange) }
            }.padding().navigationTitle(localized("요약 검토·수정", language: appLanguage))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(localized("검토 완료", language: appLanguage)) {
                        guard let data = text.data(using: .utf8), let summary = try? JSONDecoder().decode(DiscussionSummary.self, from: data) else { error = true; return }
                        onSave(summary); dismiss()
                    } }
                }.onAppear {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    text = (try? encoder.encode(snapshot.summary)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                }
        }
    }
}
