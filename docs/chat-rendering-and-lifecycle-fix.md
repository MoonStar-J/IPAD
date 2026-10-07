# 강조 표시와 대화 전환 중 답변 유지

## 수정

- `MathResources/renderer.js`: CommonMark는 `**“문장”**는`처럼 닫는 따옴표와 한글 조사 사이의 별표를 강조 끝으로 해석하지 않았다. Markdown 파서의 두 별표 경계 판단에서 한글 등 CJK 문자와 문장부호가 붙은 경우만 보완했다. 저장된 원문·복사 내용은 바꾸지 않는다. 이스케이프된 별표, 코드, LaTeX, 미완성 스트리밍 텍스트는 기존 처리를 유지한다.
- `Views/ChatGPTMarginView.swift`: 화면 사라짐에서 수행하던 요청 취소를 제거하고 작성 중 질문 저장만 남겼다. 기존 앱 공용 `MarginAIStore`가 대화 ID별로 요청을 소유한다. 다른 대화의 질문도 각자의 응답 메시지에 저장한다.
- `Services/MarginAIStore.swift`: 수신 중 응답에 현재 선택 모델이 같은지 검사하던 조건을 제거했다. 이미 전송한 요청은 전송 시점의 모델로 완료하고, 새 모델 선택은 다음 요청부터 적용한다. 계정 세대 검증은 유지한다.

새 DB나 저장 스키마 변경은 없다. 이미 취소된 답변을 자동 재전송하지 않는다. 명시적 중단, 계정 변경/로그아웃, 앱 백그라운드 진입 시의 기존 취소 정책은 유지한다. 앱 종료·백그라운드에서 무제한 실행을 보장하는 변경은 아니다.

## 실제 검증 (2026-10-01)

- 변경 전 JavaScriptCore에서 번들 Markdown 파서에 스크린샷 형태의 한글 문장을 전달하여 별표가 남는 것을 재현했다. 변경 후 `<strong>…</strong>` 출력 확인.
- `python3 scripts/check_pdf_import.py --plan`: 변경 전 실제 SwiftUI 질문 패널을 전환하면 `switching panels retains A through completion` 검사 실패. 변경 후 저장/직렬화/스트리밍 검사 **60개 통과**, 번들 WKWebView 강조·수식·보안 렌더링 검사와 PDF 캡처 검사 통과.
- 패널 A에서 응답 수신 중 실제 `UIHostingController`의 루트 화면을 B로 교체한다. A의 onDisappear 발생을 확인하고 B 질문도 전송한다. 두 응답의 완료 상태·내용·각 대화 저장·새 저장소 인스턴스의 복원을 확인한다. 패널 전체 닫기와 향후 모델 선택 변경 후에도 원래 모델의 답변이 완료됨을 검증한다.
- 기존 명시적 중단 회귀 검사도 통과한다. 질문 2개는 응답 요청 2회로만 처리되며 화면 전환은 추가 요청을 만들지 않는다.
- 렌더러 검사는 따옴표/괄호와 한글 조사, 이스케이프 별표, 코드, LaTeX 원문, 미완성 강조가 닫힌 뒤 굵게 바뀌는 경우를 포함한다.

- `swift run --scratch-path /private/tmp/note-margin-memory-core CoreChecks`: **59/59 통과**.
- Xcode 사용 폴더 `/Users/whans/Documents/IPAD`에 변경 파일 7개를 동기화하고 바이트 일치를 확인했다. `xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMarginToolsXcode CODE_SIGNING_ALLOWED=NO build`: **종료 코드 0**, 서명 없는 iPad 빌드 성공.
- `git diff --check`: 통과.

스트리밍은 URLProtocol 모의 서버를 이용했다. 실제 계정 사용량을 소비하는 호출이나 실제 iPad 응답 수신 검사는 수행하지 않았다.

## 앱에서 확인

1. Xcode에서 연결한 iPad로 다시 실행한다.
2. 한 영역에 질문하고 답변을 받는 도중 다른 여백 대화 아이콘으로 이동한다.
3. 원래 대화로 돌아오면 완료된 답변이 남는다. 다른 대화에서도 질문하면 각 답변은 자기 대화에 저장된다.
4. `**“설명”**는` 형태가 들어 있는 기존 답변을 열면 별표 대신 굵은 글씨로 표시된다. 닫히지 않은 강조나 명시적으로 이스케이프된 별표는 원문 의미대로 남는다.
