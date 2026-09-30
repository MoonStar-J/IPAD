# ChatGPT 구독 연결 — 2026-09-30

## 적용 범위와 검증 수준

기존 iPadOS 17+ SwiftUI / UIKit / PencilKit / PDFKit 앱의 모든 타깃을 동일한 ChatGPT 구독 연결로 통합했다. 기본 스킴은 `NoteMargin`이며, `NoteMarginPersonal`은 이전 설치의 데이터 보존용 호환 스킴이다. API 키 UI·전송 클라이언트·공급자 선택과 로그인 WebView/DOM 자동 전송을 제거했다. 기존 API 키의 Keychain 항목은 읽거나 전송하지 않는다. Bundle Identifier, 서명 팀, 배포 대상, 노트 저장 루트는 유지한다. 이전 웹 대화 링크는 저장 호환성에만 사용한다.

Xcode에서 `Documents/IPAD`의 초기 커밋과 Mac용 `YeobaekChecks` 패키지를 열고 있었음을 확인했다. 최신 코드의 `NoteMargin.xcodeproj`를 열어 기본 앱 스킴을 사용해야 한다.

검증 수준은 다음과 같이 구분한다.

1. 빌드·모의 검사: 개인용 Debug 시뮬레이터 빌드, Core 40개, 토큰 세션·HTTP 12개, 실제 PDFKit/PencilKit 캡처 및 오프라인 개인용 통합 검사 통과. 뒤의 검증 기록 참조.
2. 실제 계정 로그인: **미검증**. 사용자가 시스템 인증 화면에서 로그인·동의해야 한다. 로컬 콜백 진단 결과는 아래 별도 기록하며, OpenAI 실계정 로그인을 대신하지 않는다.
3. 실제 이미지 질문 `response.completed`: **미검증**. 로그인 배지·모델 목록·모의 응답만으로 완료했다고 판단하지 않는다.

## 확인한 공식 규격

2026-09-30에 아래 공식 문서 본문과 공개 OIDC discovery/JWKS를 확인했다.

- [개인·오픈소스 앱 cookbook](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt): 직접 OAuth와 HTTP 추론. 기존 ChatGPT 대화 기록 접근 권한은 포함하지 않는다.
- [개요](https://developers.openai.com/siwc/token-sharing-open-source): 등록은 사용자/워크스페이스에 연결되며 설치 host와 구분한다. UUIDv4 `urn:uuid:` host ID를 설치별로 보존한다.
- [등록과 로그인](https://developers.openai.com/siwc/token-sharing-open-source/sign-in): 첫 등록은 `dynamic_agent_client`, 재로그인은 issued client ID. PKCE S256, state, nonce, 정확히 같은 loopback redirect URI와 direct scope를 사용한다.
- [계정과 세션](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions): 계정 등록별 자격 증명, 회전 refresh token, discovery의 revocation endpoint를 통한 해제.
- [토큰 참조](https://developers.openai.com/siwc/token-sharing-open-source/token-reference): 응답의 scope·expires_in·earliest_refresh_at을 따른다.
- [모델과 추론](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference): `/v1/models`의 `models` 배열에서 `visibility == list`만 서버 순서대로 표시하며 slug로 `/v1/responses`를 호출한다.
- [미리보기 제한](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations): `store:false`, `stream:true`, 전체 필요한 input, instructions를 사용한다. 상태 이어받기·background·생성 파라미터·Files API를 사용하지 않는다.
- [오류와 복구](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery): 권한, 부적격 계정, 앱/플랜 한도, 일시 장애, 잘못된 입력, terminal refresh 오류를 구분한다. 명시적인 권한 재요청에서만 `prompt=consent`를 사용한다.
- [UI 지침](https://developers.openai.com/siwc/ui-ux-guidelines): 최초 구독 사용 안내, 연결 상태, [사용량 관리](https://chatgpt.com/settings/usage)를 표시한다.
- [ID 토큰 검증](https://developers.openai.com/siwc/website): discovery의 JWKS와 issuer, issued client audience, expiry, nonce를 검증한다. 공개 discovery는 현재 RS256을 명시한다.

공식 DevKit의 `packages/local/package.json`은 `@siwc/local` 0.1.0, private 패키지, Node >=22이다. Electron/Node 예제는 Swift/iPad SDK가 아니므로 앱에 Node·Codex CLI·app-server를 추가하지 않았다. Swift Foundation/Network/AuthenticationServices/Security/CryptoKit으로 구현했다. API 키를 발급하거나 계정을 생성하지 않았다.

## iPad 시스템 인증 경로와 제약

OpenAI의 리다이렉트는 `http://127.0.0.1:<port>/auth/callback`이다. Apple의 [ASWebAuthenticationSession.Callback](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback)은 custom scheme 또는 associated domain HTTPS를 제공한다. 설치된 Xcode 26.6 / iOS 26.5 SDK 헤더에서도 이를 확인했다. HTTP를 custom scheme으로 가장하거나 associated domain HTTPS로 바꾸지 않는다.

구현 경로:

- `NWListener`를 IPv4 loopback `127.0.0.1`에만 동적 포트로 바인딩하고 ready 이후 시스템 인증 세션을 연다.
- Apple의 nullable `callbackURLScheme` API를 `nil`로 사용한다. HTTP 콜백을 AuthenticationServices가 앱 URL로 전달한다고 가정하지 않고, 실제 listener에서 받는다.
- 콜백의 호스트·포트·경로·중복 query·state·issued client ID를 검증한다. 유효한 콜백 이후 시스템 인증 창을 닫는다.
- 사용자 취소, 시작 실패, 180초 만료와 background 전환 시 listener/연결/인증 창을 닫는다. background 실행 연장이나 로그인 WKWebView는 없다.
- 이 조합이 OpenAI의 로그인/SSO/동의/보안 화면 전체에서 동작하는지는 **실제 iPad에서 확인해야 한다**. 검증 실패 시 인증을 중단하며 Mac 중계·토큰 복사를 요구하지 않는다.
- **2026-09-30 로컬 진단 통과:** iPad Pro 13-inch (M5) / iOS 26.5 시뮬레이터에서 시스템 인증 확인 창을 승인한 뒤 로컬 302 → loopback 콜백 수신과 인증 창 닫힘을 확인했다. 첫 진단은 앱 활성화 전 foreground window 검사에서 실패했다. 테스트를 앱 활성화 후 시작하도록 수정한 뒤 통과했다. iPadOS 17 및 실제 하드웨어/SSO는 미검증이다.
- `--auth-probe`는 DEBUG 테스트 앱에서만 로컬 302 → loopback 콜백을 시험한다. OpenAI에 접속하지 않고 토큰을 만들거나 저장하지 않는다. 로컬 성공은 실계정 성공과 다르다.

Apple 참고: [시스템 인증 세션](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/), [앱 백그라운드 실행](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

## 인증과 자격 증명

`ChatGPTOAuth.swift`는 시도별 난수, PKCE, callback 검증 및 RS256 ID token 검증을 담당한다. 공개 키는 OpenAI discovery/JWKS에서 가져오며 다른 issuer와 서버가 지시한 다른 호스트를 허용하지 않는다. Apple Security의 RSA 서명 검증 후 claims를 검사한다. JWT의 alg=none, 잘못된 서명·audience·nonce·issuer·만료·subject는 거부한다.

`ChatGPTCredentials.swift`는 설치 host ID와 계정 등록 전체를 하나의 Keychain item에 원자적으로 기록한다. 접근 등급은 `WhenUnlockedThisDeviceOnly`; 토큰이 노트 JSON, UserDefaults, 렌더러, 로그에 들어가지 않는다. 같은 이메일이어도 issued client ID가 다르면 별도 등록이다. 최초 콜백의 issued ID는 코드 교환 실패 시에도 보존한다.

갱신은 계정별 single-flight이며 새 refresh token을 받으면 JWKS 검증 전에 pending rotation을 Keychain에 보관한다. 검증 완료 후 토큰·scope·expiry를 함께 교체한다. 검증 중 네트워크가 끊기면 다음 시도에서 보관한 rotation을 검증하며 이미 소비한 refresh token을 다시 쓰지 않는다. 계정 전환·재로그인·로그아웃에서 세대 식별자로 늦은 응답을 차단한다.

로그아웃은 요청을 취소한 뒤 discovery의 revoke endpoint로 refresh token 해제를 시도하고 로컬 토큰을 삭제한다. 네트워크 오류로 원격 해제를 확인하지 못하면 명시한다. 발급된 client 매핑, 노트, 대화는 남긴다. 권한이 없으면 추론을 차단하며, 사용자에게 API 키 전환을 제안하지 않는다.

## 전송·맥락·보관

- `ChatGPTPlanTransport.swift`: OAuth bearer를 공식 `/v1/responses`로만 전송한다. 쿠키·캐시·HTTP redirect 재전송을 사용하지 않는다. 자동 재시도는 없다.
- `ChatGPTPlan.swift`: typed allowlist request (`model`, `instructions`, `input`, `store`, `stream`)만 직렬화한다. PDF/필기 스냅샷을 PNG data URL로 직접 첨부한다. OCR·요약·제목용 추가 AI 호출은 없다.
- 카탈로그에 없는 모델은 선택할 수 없다. reasoning·가격·성능 순위를 추정하지 않는다. 현재 공개 카탈로그 예제에는 모델별 이미지 capability 필드가 명시되지 않는다. 별도로 확인한 공식 모델 명세의 [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol), [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) exact slug만 이미지 입력을 허용한다. 이 표는 모델 선택 목록이나 가용성·성능 순위가 아니다. 계정 카탈로그에도 반드시 있어야 선택할 수 있다. 확인하지 않은 모델/alias의 이미지 요청은 UI와 request builder에서 차단한다. 새 모델은 공식 명세 확인 후 capability 표를 갱신해야 한다. 계정 정책에 따른 거절은 보존하고 자동 재전송하지 않는다.
- 최초 문제 이미지, 선택 텍스트, 고정 조건, 이 대화의 메시지, 해당 프로젝트 지침을 구성한다. 불완전한 이전 답변은 불완전하다고 표시한다. 다른 노트는 포함하지 않는다. 12 MB 로컬 요청 상한에서는 아무 맥락도 조용히 버리지 않고 전송을 막는다. 이 값은 모델의 토큰 한도/비용 상한이 아니다.
- `ServerSentEvents.swift`: byte 단위로 UTF-8을 보존하며 LF/CR/CRLF, 여러 data 행을 처리한다. sequence 중복 제거, completed만 성공 확정, failed/incomplete/중단/취소 분리. final text가 있으면 delta에 덧붙이지 않고 교체한다.
- UI는 약 80 ms 간격으로 갱신하고 대화 파일은 약 1초 및 terminal event 시 보존한다. 강제 종료 시 마지막 저장 간격의 일부 delta가 유실될 수 있다. 재실행 시 streaming 메시지는 interrupted로 복구하며 자동 전송하지 않는다.
- 안전한 오류 코드·HTTP status·request ID·param·body shape만 진단에 남긴다. 원본 오류 body/토큰/인증 URL은 저장하지 않는다.

## 데이터와 화면

기존 `MarginChats/<noteID>/<chatID>.json` 원장을 재사용한다. 새 항목은 모두 optional: 질문 모드, 고정 조건, 첨부 선택, 계정 등록 ID, schemaVersion=2, 메시지 status/mode/model/진단. 기존 JSON은 수정 없이 디코딩되며 저장 시 확장된다. 노트/PDF/PencilKit 파일 형식은 그대로다.

`PersonalChatGPTView`는 기존 사각형 선택과 여백 원형 아이콘에서 열린다. 캡처는 기존 `RegionContextService`/`PageRenderer`의 PDF 회전·연속 페이지 좌표 변환을 재사용한다. 프로젝트별 대화 범위도 유지한다. 전송 버튼 전에는 요청이 없다.

Markdown은 SwiftUI, LaTeX는 번들에 포함한 KaTeX 0.18.9로 표시한다. 수식은 개별 가로 스크롤 영역이며 원문·수식을 복사할 수 있다. 닫히지 않은 수식은 텍스트로 남긴다. inline 수식도 현재 별도 행으로 표시되는 제한이 있다. 렌더러는 nonpersistent WKWebView, local resource 전용 CSP, `trust:false`, 크기/확장 상한을 사용한다. 답변 문자열은 JS 코드가 아닌 structured argument로만 전달한다. 토큰은 전달하지 않는다. 외부 리소스/탐색/임의 HTML 실행을 차단한다. [KaTeX 보안](https://katex.org/docs/security), [옵션](https://katex.org/docs/options). 배포 파일 integrity 확인값과 MIT 라이선스는 MathResources에 포함했다.

‘노트에 저장’은 기존 편집 가능한 text element에 Markdown/LaTeX 원문을 삽입한다. 원본 필기는 덮어쓰지 않으며 같은 PencilKit undo manager에 카드 삽입/제거를 등록한다. 노트 카드 자체는 기존 일반 텍스트 렌더링이므로 수식 원문이 보인다. 대화 패널의 ‘원본 선택 영역으로’는 해당 페이지의 원래 사각형으로 확대한다.

## 실행 방법

1. 기존 Xcode 프로젝트에서 `NoteMargin` 스킴과 연결한 iPad를 선택하여 실행한다. 기존 Team/Bundle Identifier를 유지한다.
2. 보관함의 **ChatGPT 구독 연결 → Continue with ChatGPT**. 시스템 화면에서 직접 로그인·동의한다. 실패 시 오류를 확인한다. 토큰/비밀번호를 개발자에게 전달하지 않는다.
3. 구독 사용 안내를 확인하고 계정의 모델 목록을 불러온다. 이 단계는 추론 성공을 의미하지 않는다.
4. 노트에서 **질문 → 영역 조절 → 이 영역으로 질문**. 이미지·맥락·모드·모델을 확인하고 질문을 입력한 뒤 전송한다.
5. 답변 상태가 ‘완료’인지 확인한다. 후속 질문은 같은 여백 아이콘에서 이어간다. 실패한 질문은 자동으로 재전송하지 않는다.
6. **사용량 관리**는 공식 ChatGPT 설정을 연다. 잔여량/리셋 시간은 앱에서 추측하지 않는다.

## 실행한 검사

```sh
swift run --scratch-path /private/tmp/note-margin-siwc-core CoreChecks
# 40/40 통과

swiftc -parse-as-library -module-cache-path /private/tmp/note-margin-mac-modules \
  NoteMargin/Core/Models.swift NoteMargin/Core/AIModels.swift \
  NoteMargin/Core/ChatGPTPlan.swift NoteMargin/Core/ChatGPTOAuth.swift \
  NoteMargin/Core/ServerSentEvents.swift NoteMargin/Services/ChatGPTCredentials.swift \
  NoteMargin/Services/ChatGPTPlanTransport.swift scripts/plan_session_checks.swift \
  -o /private/tmp/note-margin-plan-session-checks
/private/tmp/note-margin-plan-session-checks
# 12/12 통과. URLProtocol 모의 응답, 외부 계정/추론 요청 없음.

xcodebuild -quiet -project NoteMargin.xcodeproj -scheme NoteMarginPersonal \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/NoteMarginSIWCDerivedData CODE_SIGNING_ALLOWED=NO build
# exit 0 (Debug 및 Release)

python3 scripts/check_pdf_import.py --auth-probe
# PASS: system authentication session + IPv4 loopback callback
# 시스템 확인 창에서 로컬 테스트를 승인. 실제 OpenAI 로그인/추론 아님.

xcodebuild -quiet -project NoteMargin.xcodeproj -scheme NoteMargin \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/NoteMarginSIWCAPI CODE_SIGNING_ALLOWED=NO build
# exit 0: 통합 전 기본 타깃 검사 기록

xcodebuild -quiet -project NoteMargin.xcodeproj -scheme NoteMarginPersonal \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/NoteMarginSIWCDevice CODE_SIGNING_ALLOWED=NO build
# exit 0: 실제 iPad SDK 빌드, 코드 서명·설치·배포 없음

python3 scripts/check_pdf_import.py --personal
# PASS: native personal panel, disconnected inference blocked, API-key path blocked,
# offline math renderer, answer card Undo/Redo, PDF capture checks
```

시뮬레이터에서 Keychain 저장/복원, 오프라인 KaTeX 렌더링, 외부 링크/HTML 차단, 닫히지 않은 수식 텍스트 유지, 답변 카드 삽입 Undo/Redo를 추가 검증했다. 실제 Pencil 입력과 장시간 필기 회귀, 실계정 SSO/동의·모델별 이미지 입력·사용량 오류·토큰 갱신/해제는 추가 기기 검증 대상이다. 과거 필기 회귀 테스트 통과 기록을 이번 변경의 실행 결과로 재사용하지 않는다. 앱 배포, 가입, 결제는 수행하지 않았다. 이후 사용자의 명시적 요청으로 통합 변경 `b660ed9`를 GitHub main에 push하고 원격 SHA를 확인했다.


## 2026-09-30 통합 후 검증

- 기본 `NoteMargin` Debug 시뮬레이터 빌드: 통과. API 분기와 `PERSONAL_CHATGPT` 컴파일 조건을 제거했다.
- `swift run --scratch-path /private/tmp/note-margin-siwc-core CoreChecks`: 40/40 통과.
- 위 `plan_session_checks.swift` 컴파일/실행: 12/12 통과, 실계정/외부 네트워크 사용 없음.
- `python3 scripts/check_pdf_import.py --plan`: 기본 타깃의 네이티브 패널, 미연결 전송 차단, Keychain, 오프라인 수식 렌더링, 답변 카드 Undo/Redo, PDF/필기 캡처 통과. `--personal`은 기존 검사 명령 호환용 별칭이며 별도 AI 모드를 활성화하지 않는다.
- 호환 `NoteMarginPersonal` Release 시뮬레이터 빌드: 통과. 동일한 OAuth/대화 코드와 표시 이름을 사용한다.
- 기존 Canvas 필기/페이지 전환/지우개 소스는 변경하지 않았다.
- 실계정 로그인과 실제 이미지 질문 응답 완료는 여전히 미검증이다.

- Xcode가 사용하던 `Documents/IPAD` 체크아웃은 초기 `ff01844`에서 통합 커밋으로 fast-forward했다. 앱 소스/리소스가 작업 폴더와 같은지 파일별 비교했으며, 로컬 서명 설정은 유지했다.
- 해당 IPAD 폴더에서 `xcodebuild -quiet -project NoteMargin.xcodeproj -scheme NoteMargin -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMarginUnifiedXcode CODE_SIGNING_ALLOWED=NO build`: exit 0. 실제 iPad 설치나 실계정 추론은 수행하지 않았다.
- Xcode 프로젝트 열기 UI는 마지막 단계에서 macOS 화면 제어 도구의 시간 초과로 완료 여부를 확인하지 못했다. `Documents/IPAD/NoteMargin.xcodeproj`를 열고 `NoteMargin` 스킴을 선택한다. `Package.swift`의 Mac 검증 스킴은 앱 실행용이 아니다.

## 2026-09-30 — 실기기 `not_sse` 연결 오류 수정

연결된 iPad의 실패한 대화에서 `diagnosticCode: not_sse`를 확인했다. 이전 구현은 성공 HTTP 응답에서도 MIME이 `text/event-stream`과 다르면 본문을 읽기 전에 종료했다. 기존 진단에는 실제 MIME/HTTP 상태/본문이 없어 당시 서버가 보낸 본문의 종류는 확정할 수 없다. 실기기 질문·이미지·이메일·토큰은 이 기록이나 테스트 fixture에 포함하지 않았다.

- Content-Type만으로 거부하지 않고 실제 SSE 시작 필드를 확인한다. 일반 JSON/바이너리/텍스트 MIME 또는 누락 헤더에서도 유효한 SSE를 처리한다. BOM, keepalive와 임의 청크 경계를 처리한다.
- 실제 JSON 오류는 서버 코드에 따라 분류한다. HTML·완료 이벤트가 없는 JSON을 정상 답변으로 간주하지 않으며, POST를 자동 재전송하지 않는다. 완료 기준은 [공식 모델·추론 문서](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)의 `response.completed`를 유지한다.
- 개별 질문의 전송/형식 오류는 사용 가능한 계정 전체를 오류 상태로 바꾸지 않는다. 인증·권한·한도 오류는 기존대로 차단한다. [공식 오류·복구 문서](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)를 대조했다.
- 실패 메시지에 안전하게 제한한 오류 코드·HTTP 상태·MIME·요청 ID를 표시한다. 본문이나 인증 정보를 저장/출력하지 않는다. 기존 진단 JSON은 그대로 호환된다.
- 실패한 질문은 ‘질문 다시 입력’으로 입력창에 복원한다. 실제 전송은 사용자가 전송 버튼을 눌렀을 때만 수행한다. 다크/라이트 모드의 로그인 버튼 전경색과 배경색을 명시했다.

검증:

- 이전 커밋의 transport로 `application/json` 헤더 + 정상 SSE 본문을 주면 `not_sse`가 발생함을 재현했다. 실제 서버 응답을 캡처한 fixture는 아니다.
- `swift run --scratch-path /private/tmp/note-margin-siwc-core CoreChecks`: **42/42** 통과.
- `scripts/plan_session_checks.swift`를 위 명령으로 컴파일/실행: **20/20** 통과. MIME 변형 4종, HTTP 200 JSON 오류, HTML 거부, 비스트리밍 JSON 거부, BOM 포함. 외부 계정/추론 사용 없음.
- `NoteMargin` Debug 시뮬레이터 빌드: 통과.
- `python3 scripts/check_pdf_import.py --plan`: 네이티브 패널·Keychain·수식·답변 카드 Undo/Redo·PDF 필기 캡처 통과.
- Canvas 필기·지우개·페이지 전환 코드는 수정하지 않았다. 수정 빌드의 실제 이미지 질문 완료는 사용자가 iPad에서 재확인해야 한다.
