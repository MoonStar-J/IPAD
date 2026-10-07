# 스크린샷 대화 맥락 기록

## 확인한 경로와 실제 원인

2026-09-30, SwiftUI/UIKit/PencilKit/PDFKit 앱과 기존 `MarginChatRepository`의 노트별 JSON 저장을 확인했다. 적용할 AGENTS.md는 없었다. 인증은 기존 공식 Sign in with ChatGPT를 유지한다.

기존 경로는 `AIEditorCanvas.capture → MarginAIStore.create/sendPlan → PlanRequest.build → ChatGPTPlanTransport.stream → POST /v1/responses`였다. 첫 이미지의 PNG bytes는 이미 JSON에 저장되었고, includeImage가 false가 아니면 매 요청 data URL로 다시 전송되었다. 사용자·assistant 기록도 순서대로 보내며 현재 질문은 한 번 추가했다. 따라서 “항상 최초 이미지/이전 답변이 누락됐다”는 원인은 발견하지 않았다.

확인한 결함은 매 캡처마다 새 대화 생성, 추가 이미지 연결 불가, 기존 이미지 토글에 따른 무조건 제외, 손상/빈 이미지 검증 누락, 명시적 답장 대상/정정/불변 요청 기록/입력 예산의 부재였다. 실제 빈 이미지 요청이 성공하는 실패 테스트를 먼저 실행했다(기존 43개 성공 + 새 1개 실패).

변경 후 실제 경로:

1. 질문 화면에서 새 문제를 만들거나 기존 문제에 캡처를 추가한다. 추가 캡처는 전송 없이 원본 이미지와 출처를 atomic 저장한다.
2. `sendPlan`이 현재 질문의 안정적 ID와 답장 참조를 붙인다.
3. UI·인증·네트워크와 독립된 `ContextBuilder`가 의미상 자료를 고른다.
4. `PlanRequest.serialize`가 실제 data URL과 역할별 입력 배열로 변환하고 HTTP bytes 제한을 검사한다.
5. 사용자 질문, 빈 assistant 결과, 불변 manifest, 모델·인증 세대·지침을 같은 기존 JSON에 atomic 저장한 뒤 기존 HTTP/SSE 전송을 시작한다.
6. 같은 request ID/thread/auth generation/model의 이벤트만 결과에 적용한다. 취소/중단/실패/부분/완료를 구분한다. 재시작은 streaming을 interrupted로 바꾸며 재전송하지 않는다.

## 변경 파일

| 파일 | 변경 |
| --- | --- |
| `Core/AIModels.swift`, `Core/ConversationMemory.swift` | 추가 저장 모델, ContextBuilder, 보호 원문, 예산, 압축 fingerprint/유효성 |
| `Core/ChatGPTPlan.swift` | 의미상 선택과 제공자 직렬화 분리, 실제 이미지·payload 제한 |
| `Core/ServerSentEvents.swift` | 공급자가 보고한 usage만 선택적으로 읽기 |
| `Services/MarginAIStore.swift` | 기존 atomic 저장/실제 전송에 연결, run·초안·인용·정정·압축 수명 관리 |
| `Services/ChatGPTPlanConnection.swift` | 테스트용 HTTP 의존성 주입만 추가; 기본 인증 흐름 동일 |
| `Views/AIEditorCanvas.swift` | 새 문제/기존 문제 선택, 같은 문제에 캡처 추가, 원본 위치 복귀 |
| `Views/ChatGPTMarginView.swift`, `Views/ConversationMemoryView.swift` | 인용 선택, 맥락·정정·전사·예산·압축·실제 요청 기록 화면 |
| `Tests/CoreChecks/MemoryChecks.swift`, `PlanChecks.swift`, `main.swift` | 최종 JSON·회귀·마이그레이션 검사, 정상 PNG fixture |
| `scripts/memory_store_checks.swift`, `pdf_integration_app.swift`, `check_pdf_import.py` | 격리 앱에서 실제 저장·HTTP 전송 경로를 모의 서버로 검증 |
| `NoteMargin.xcodeproj/project.pbxproj`, `README.md`, 이 문서와 fixture manifest | 새 파일 등록, 사용법·검증 기록 |

표의 Core/Services/Views는 `NoteMargin/` 아래 경로다. 작업 시작 때 존재한 프로젝트/스킴 변경은 그대로 보존했다. GitHub에 push하거나 배포하지 않았다.

## 저장과 마이그레이션

`Documents/NoteMargin/MarginChats/<noteID>/<threadID>.json`을 계속 사용한다. DB/서버/임베딩/OCR 시스템을 추가하지 않았다. 원본 이미지 bytes는 기존 `imageData` 한 곳에 유지하고 `originalAttachment`에는 SHA-256, 크기, PNG MIME, 좌표·페이지, 캡처 버전 및 승인된 전사문 이력 등 메타데이터만 저장한다. `sourceAttachments`가 원본을 해석할 때 bytes를 결합한다. 추가 이미지는 attachment에 immutable 캡처 bytes와 introducing message ID를 저장한다. 같은 bytes를 두 번 첨부한 의미적 발생은 둘 다 보존한다. 임시 경로/만료 URL/현재 PDF 재렌더링에 의존하지 않는다.

원래 대화 필드는 유지하고 새 optional 필드를 추가한 schemaVersion 3이다. 구버전 대화는 load에서 메타데이터를 유도해 atomic 저장한다. 파손된 bytes는 새 이미지로 꾸미지 않고 unavailable로 판정해 요청을 막는다. 노트/PDF/필기 저장, bundle ID, Keychain은 변경하지 않는다. 계정/프로젝트 경계는 기존 검사를 유지한다.

메시지 순서는 기존 배열이 권위 있는 순서다. 메시지 UUID/원문 revision/해시로 각 요청의 선택 항목을 기록한다. 첫 캡처는 thread ID를 가진 가상 user 자료 턴이다. 기존 발언은 인라인 편집·삭제/분기하지 않는 append-only 정책이다. 잘못 읽은 조건은 별도 정정 기록으로 추가한다. 전체 대화 삭제만 기존 확인 절차를 따른다. 전사문 수정과 요약 검토도 이력을 보존한다.

## 맥락 선택과 예산

짧은 대화는 모든 원문과 원본 이미지를 순서대로 재전송한다. 현재 질문이 텍스트여도 이미지가 유지된다. 정확한 인용문은 원본 답변 ID/revision과 함께 저장한다. UI는 렌더링된 수식 glyph 대신 원본 Markdown/LaTeX에서 선택하므로 LaTeX가 바뀌지 않는다.

기본 앱 정책은 입력 추정 24,000, 그중 출력/오차 여유 4,000, HTTP JSON 12,000,000 bytes, 최근 user 턴 2개다. 입력 예산은 UI에서 6,000~200,000으로 조절 가능하다. 이는 검증된 모델 용량/잔여 구독량/공급자 출력 상한이 아니다. 로컬 tokenizer는 추가하지 않았으며 텍스트 UTF-8 bytes/3, 이미지별 1024 + 512px tile당 256이라는 보수적 정책 추정이다. 이미지 bytes를 문자 토큰으로 계산하지 않는다. 추정치는 실제 공급자 토큰과 다를 수 있다.

전체 재전송이 예산 안이면 저장된 요약이 있어도 쓰지 않는다. 초과할 때만 유효한 요약과 최근 원문을 조합한다. 사용자 발언 전체, 원본 문제 이미지, 추가 이미지, 고정 조건, 정정, 인용 대상 원문을 보호한다. 수식 기호를 포함한 assistant 답변은 전체를 보호한다. 이 보수적 보호로 긴 수학 대화는 압축 이득이 작거나 없을 수 있다. 자연어로 제시된 중요한 조건/정리는 ‘조건 고정’으로 명시하는 것이 좋다. assistant 주장은 검증된 사실로 취급하지 않는다.

2026-10-01 수정: 원본 스크린샷은 모든 요청에 필수로 포함한다. 승인 전사문은 보조 자료로만 함께 전송하며 이미지를 대체하지 않는다. PDF 자동 추출 텍스트는 요청에 자동 삽입하지 않는다. 다크 모드에서도 흰 용지 기준으로 필기를 렌더링한다.

## 선택적 압축

자동 추가 호출은 구현하지 않았으며 항상 꺼져 있다. ‘대화 압축 → 추가 요청 1회로 압축’은 기존 구독 전송 경로로 별도 요청 한 번만 실행한다. 일반 질문에 자동 요약/OCR/제목/라우팅 요청은 없다. 압축은 예산에 맞는 과거의 완결된 턴 prefix를 원본으로 읽는다. 이전 요약만 반복 재요약하지 않는다.

응답은 approaches / assistantClaims / rejectedApproaches / openQuestions / uncertainties 문자열 배열 JSON을 로컬 검증한다. 보장되지 않은 structured-output 필드를 전송하지 않는다. coverage와 원문/이미지/조건/정정 fingerprint를 저장하고 결과 도착 시 재검사한다. 수정·삭제·정정·추가 이미지·전사 정책 변경은 관련 snapshot을 무효화한다. 원본 append만으로는 재요약하지 않는다. 실패/취소/형식 오류/오래된 결과는 원본을 덮어쓰지 않고 자동 repair 요청도 하지 않는다.

요약은 ‘미검토 AI 요약’이며 사용자 검토/수정은 새 snapshot 버전을 만든다. 형식 검증은 수학적 정확성 검증이 아니다. 필수 자료만으로 예산이나 bytes 제한을 넘으면 질문을 보존하고 조치 가능한 오류를 표시한다.

## 공식 전송 계약 확인 (2026-09-30)

- [SIWC 모델과 추론](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference): 기존 HTTP `/v1/responses` OAuth Bearer 연결, store:false/stream:true 유지.
- [SIWC 제한](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations): HTTP previous_response_id/conversation에 기억을 맡기지 않는다. 필요한 input history를 명시한다. system 항목 대신 기존 instructions를 사용한다. 추가 요청 키는 넣지 않는다.
- [Reasoning](https://developers.openai.com/api/docs/guides/reasoning): 일반 API의 encrypted_content replay는 별도 기능이다. 현재 앱의 SIWC 계정/모델별 호환성을 확인하지 않았으므로 opaque output을 수집/재입력하지 않는다. assistant 표시 원문을 한 번만 텍스트 입력으로 복원한다. 모델 변경에도 같은 원문·이미지 복원 경로를 사용한다.
- [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching): 캐시는 영속 기억을 대체하지 않는다. 변경되지 않은 지침/원문 순서/PNG 인코딩을 유지하고 캐시 제어 필드는 추가하지 않는다. 공급자가 보고한 usage.input_tokens/output_tokens/input_tokens_details.cached_tokens만 선택적으로 기록한다. 캐시 적중이나 절약액을 추정하지 않는다.
- [WebSocket](https://developers.openai.com/api/docs/guides/websocket-mode): 이번 구현에는 추가하지 않았다. 동일 연결 continuation/재연결 fallback을 구현한 것으로 주장하지 않는다. HTTP/SSE 원본 재구성이 기준이다.

## 관찰 가능성과 개인정보

‘맥락 보기’는 로컬에서 실제 선택할 이미지/원문/인용/요약 범위/제외 ID/추정치를 보여준다. 요청별 manifest에는 메시지 UUID/revision/hash/역할/선택 이유, 이미지 SHA-256/소속 턴, 승인 전사 해시, summary ID/coverage, 지침 hash, canonical payload hash, bytes가 있다. 토큰·쿠키·base64·원문 텍스트는 manifest에 없다. 실제 원문을 보는 미리보기는 로컬 사용자 화면이며 진단 로그가 아니다.

요청별 원문 지침은 재구성을 위해 개인 대화 JSON에 보존하고 manifest/일반 진단에서는 제외한다. JSON 대화 백업 자체는 원본 이미지와 텍스트를 포함하는 개인 데이터이며 인증 정보는 포함하지 않는다. run 카운트는 전송 직전 기록을 포함하므로 서버 수락/정확히 한 번 실행의 증명이 아니다. 공급자 usage가 없으면 nil이며 0으로 지어내지 않는다. 첫 텍스트 시간은 로컬 측정이다.

## 앱에서 확인

1. Xcode `NoteMargin` 스킴으로 기존 앱을 업데이트한다(앱 삭제 불필요).
2. 문제 영역 캡처 → 새 문제 → 첫 질문. 후속 텍스트 질문 전에 ‘… → 맥락 보기’에서 원본 이미지와 첫 답변을 확인한다.
3. 답변 아래 ‘이 부분 질문’ → 원문 문장/수식 범위 선택 → 이 부분 질문 → 후속 질문 전송.
4. ‘… → 현재 문제에 추가’ 또는 다른 페이지 캡처 뒤 기존 문제 선택 → 풀이 이미지 첨부. 동일 thread에서 질문한다.
5. ‘맥락 보기 → 조건 고정·정정’에서 금지 정리, `n^3 → n^2`를 기록한다. 과거 원문과 정정 기록이 함께 남는다.
6. 대화가 충분히 길면 ‘대화 압축’을 명시적으로 실행하고 결과를 검토한다. 예산 안에서는 계속 원문을 사용한다.
7. 질문 초안을 남기고 앱을 종료·재실행한 뒤 노트 대화 목록에서 같은 문제를 연다. 이미 진행 중이던 요청은 자동 재전송되지 않는다.
8. 별도 ‘새 문제’로 캡처한 대화의 맥락에는 다른 문제 자료가 없는지 확인한다.

## 검증 기록

아래 결과는 로컬 fixture/모의 HTTP와 시뮬레이터 검사다. 사용자 제공 상태에 따르면 기존 실계정 로그인·이미지 응답은 동작하지만, 이번 맥락 기능의 실제 계정 추론은 실행하지 않았다. 일반 검사에서 구독 사용량을 소비하지 않았다.

실행한 검사:

```sh
swift run --scratch-path /private/tmp/note-margin-memory-core CoreChecks
python3 scripts/check_pdf_import.py --plan
swiftc -parse-as-library -module-cache-path /private/tmp/note-margin-mac-modules \
  NoteMargin/Core/Models.swift NoteMargin/Core/AIModels.swift \
  NoteMargin/Core/ConversationMemory.swift NoteMargin/Core/ChatGPTPlan.swift \
  NoteMargin/Core/ChatGPTOAuth.swift NoteMargin/Core/ServerSentEvents.swift \
  NoteMargin/Services/ChatGPTCredentials.swift NoteMargin/Services/ChatGPTPlanTransport.swift \
  scripts/plan_session_checks.swift -o /private/tmp/note-margin-plan-session-checks
/private/tmp/note-margin-plan-session-checks
xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj \
  -scheme NoteMargin -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMarginMemoryXcode \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
```

- CoreChecks **57/57 PASS**: 최종 JSON 검사, 최초 이미지/답변/현재 질문 순서·중복, 다중 이미지/분리된 문제, 정확한 LaTeX 인용, 조건 정정, 금지 정리, 승인 전사문/시각 참조 원본 복원, 손상 이미지, 초과 예산, cold reload, 취소/수정/삭제에 따른 요약 무효화, 구버전 저장 호환성, redacted manifest.
- 시뮬레이터의 실제 `MarginAIStore → repository → builder → serializer → ChatGPTPlanTransport` + URLProtocol 모의 서버 경로 **27/27 PASS**. 전송 전 저장, 미리보기와 실제 manifest 일치, 두 일반 질문에 추론 두 번만 발생, 다중 이미지/출처, 저장소 재생성, 자동 재전송 없음, 취소, 사용량 보고 필드, 압축 실패·성공·취소, 초안 보존을 검사했다. 동일 실행에서 기존 native panel/Keychain/오프라인 수식 렌더러/PDF 영역/답변 카드 Undo·Redo 검사도 PASS.
- 기존 OAuth session/SSE 회귀 검사 **20/20 PASS**. 실제 계정/네트워크를 사용하지 않았다.
- 주 작업 폴더의 simulator 및 iPad 빌드, Xcode 작업 폴더(`/Users/whans/Documents/IPAD`)의 iPad 빌드 성공. 코드 서명/실기기 설치는 수행하지 않았다.
- `git diff --check` 성공. `NoteMargin/Canvas` 파일 변경 없음. Xcode의 사용자 Package.swift/스킴/서명 설정과 기존 Yeobaek 프로젝트는 보존했다.

효율 측정은 **합성 fixture의 로컬 추정치**이다. 긴 대화 full 15,377 → compact 4,832로 줄면서 원본 이미지 1개를 유지했다. 공급자 실제 토큰/플랜 절약량이 아니다. 짧은 두 질문에서 압축 호출은 0이었다.

[모의 후속 요청 manifest 원본](fixtures/screenshot-followup-manifest.json)은 실제 직렬화된 두 번째 요청에서 생성한 것으로, 문제 자료 user → U1 user → A1 assistant → U2 user 순서와 원본 이미지 SHA-256, 인용 대상, 제외 없음, 전송 bytes/추정치를 확인할 수 있다. 토큰/쿠키/원문/이미지 bytes를 넣지 않았다.

남은 검증/선택 기능: 실제 iPad에서 원문 선택 터치·다른 페이지의 원본 위치 복귀·종료/재실행 및 실제 계정 수학 답변을 확인해야 한다. 시뮬레이터 검사는 수학적 정답이나 공급자의 영구 기억을 보장하지 않는다. 자동 압축, provider-native compaction, opaque reasoning/output replay, cache 제어, WebSocket continuation은 이번 구현에 포함하지 않았다. 전체 assistant 메시지의 원문 편집/분기는 지원하지 않고 정정을 추가하는 정책이다. 문장으로만 표현된 모든 수학 조건의 자동 판별은 보장하지 않으므로 중요한 조건은 명시적으로 고정한다.
