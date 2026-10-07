# 일반 후속 질문 전송 수정 (2026-10-01)

이번 작업은 장기 기억 기능 확장이 아니라 기존 패널의 일반 후속 질문 오류 수정이다. 기존 작업과 데이터는 보존했다. 추가 UI·자동 요약·OCR·조건 고정·DB·WebSocket 기능은 만들지 않았다.

## 원인과 수정

첨부 화면의 `invalid_value · HTTP 400 · input[2].content[0]`은 첫 assistant 답변의 content를 가리킨다. 기존 직렬화는 사용자 질문과 assistant 답변에 모두 `[{"type":"input_text","text":...}]`를 썼다. 첫 질문에는 이전 assistant가 없어 성공하지만, 후속 질문부터 잘못된 assistant content가 포함됐다.

`PlanRequest.Input.encode`에서 사용자 자료는 기존 input_text/input_image 배열로 보내고, 저장된 assistant 답변은 공식 Responses 예제의 `{"role":"assistant","content":"이전 답변 원문"}` 형태로 보낸다. 임의의 output ID나 서버 대화 ID를 만들지 않는다. 이미지 bytes는 첫 자료 메시지의 PNG data URL로 유지한다.

공식 근거: [Responses의 수동 대화 이력 예제](https://developers.openai.com/api/docs/guides/conversation-state), [SIWC HTTP의 전체 input 이력과 제한](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations). `store:false`, `stream:true`, 기존 OAuth와 모델 선택을 유지한다.

`MarginAIStore`의 기존 대화 배열·저장·스트리밍 경로를 재사용한다. 서버 입력 한도/HTTP 400 거절에서도 질문과 인용을 입력창에 복원한다. 동일 질문을 사용자가 명시적으로 재전송하면 이미 저장한 user 턴을 재사용하고, 실패 기록은 남긴다. 연속해서 거절되어도 질문을 중복 추가하지 않는다. 자동 재전송은 하지 않는다.

## 실제 검사

이전 모의 서버는 assistant의 잘못된 content도 성공으로 처리했다. 이를 놓친 회귀 검사를 보완했다.

- 수정 전 코어 재현: `assistant content must not be an input_text block` 실패, 57/58.
- 수정 후 `swift run --scratch-path /private/tmp/note-margin-memory-core CoreChecks`: **58/58 통과**.
- `python3 scripts/check_pdf_import.py --plan`: **47개 저장/전송 검사 통과**. URLProtocol 모의 서버가 잘못된 assistant 배열을 HTTP 400으로 거절한다. 실제 `sendPlan → 저장 → 직렬화 → ChatGPTPlanTransport`를 실행한다.
- 일반 질문 L1 → 답변 A1 → L2 → A2 → L3의 각 실제 HTTP body에서 원본 이미지 1개와 시간순 원문을 검사했다. 질문 3번에 답변 요청 3회, 보조 AI 호출 0회.
- 새 대화에 이전 대화의 질문/답변이 섞이지 않음, 첫 질문 성공, 입력 한도 오류 뒤 초안 보존, 연속 거절 뒤 명시적 재전송 시 질문 1회 포함을 검사했다.
- 기존 인증·SSE 모의 회귀 검사 `plan_session_checks.swift`: **20/20 통과**.
- Xcode 복사본에서 `xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMarginMemoryXcode CODE_SIGNING_ALLOWED=NO build`: **성공**. `git diff --check`도 통과했다.
- 동일 시뮬레이터 실행에서 기존 오프라인 수식·PDF 캡처·답변 카드 Undo/Redo 검사도 통과했다.

실제 계정 추론을 실행한 결과는 아니다. 수정 빌드를 기존 iPad 앱에 Xcode로 실행한 후 같은 대화에서 후속 질문을 확인해야 한다. 저장 형식 마이그레이션은 추가하지 않았다.

수정 파일: `NoteMargin/Core/ChatGPTPlan.swift`, `NoteMargin/Services/MarginAIStore.swift`, `Tests/CoreChecks/MemoryChecks.swift`, `scripts/memory_store_checks.swift`. 기존 로그인/모델 선택/스트리밍 파서/수식 렌더러/필기 파일은 이번 작업에서 수정하지 않았다.
