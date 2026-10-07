# 도구 팔레트 · 네모 선택 검증

2026-10-01. 기존 PencilKit 저장 파일과 필기 엔진을 사용하며 데이터 마이그레이션은 없습니다.

- `Canvas/DrawingSession.swift`: 도구 상태, 기존 실행 취소 경로에 선택 편집 연결, 원본 획을 보존하는 사각형 선택 모델.
- `Canvas/NotebookCanvas.swift`: 문서 좌표 기반 선택·이동·비율 유지 크기 조절, 복사·잘라내기·복제·붙여넣기·삭제. 드래그 도중 원본 필기를 변경하지 않고 목적지 테두리를 표시합니다.
- `Views/Design.swift`: 직접 작성한 SwiftUI 벡터 픽토그램, 접힌 원형 버튼, 전체 버튼 터치 영역.
- `Views/AIEditorCanvas.swift`, `Views/ChatGPTMarginView.swift`: 불투명 시스템 배경, 대화 목록의 기본 글자색, 새 도구 팔레트 연결.

복사한 필기는 앱 실행 중 다른 노트에 붙여넣을 수 있습니다. 시스템 클립보드 공유와 앱 종료 후 클립보드 복원은 추가하지 않았습니다. 선택 대상은 필기 획이며, PDF·사진·텍스트 항목은 기존 기능으로 편집합니다.

## 실제 실행

- `swift run --scratch-path /private/tmp/note-margin-memory-core CoreChecks`: **58/58 통과**.
- `python3 scripts/check_pdf_import.py`: **선택 관련 26개 단정문 통과**, 기존 PDF 가져오기·내보내기·문서 좌표·페이지 교체·획 지우개 저장 검사 통과. `scripts/ink_selection_checks.swift`를 실제 앱 소스와 함께 iPad 시뮬레이터에서 실행합니다.
- `python3 scripts/check_pdf_import.py --live-ui --only-testing CanvasLiveInkTests/CanvasLiveInkTests --only-testing CanvasLiveInkTests/StrokeEraserVisualTests --only-testing CanvasLiveInkTests/PageSwapVisualTests --only-testing CanvasLiveInkTests/InkToolsVisualTests`: 기존 긴 PDF 실시간 필기·페이지 잔상·지우개 미리보기 **3개 UI 테스트 통과**. 최초 새 도구 UI 검사는 접근성 식별자와 아이콘 터치 영역 오류로 실패하여 수정했습니다.
- `python3 scripts/check_pdf_import.py --live-ui --only-testing CanvasLiveInkTests/InkToolsVisualTests`: 수정 후 **1개 UI 테스트 통과**. 밝은/어두운 모드 각각 팔레트 접기·펼치기, 실제 네모 드래그, 복제·삭제, 대화 목록 표시를 검증했습니다.
- `xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMarginToolsXcode CODE_SIGNING_ALLOWED=NO build`: **통과**.
- `git diff --check`: 통과.

위 검사는 별도 시뮬레이터 앱과 합성 필기 데이터로 실행했습니다. 실제 iPad의 Apple Pencil 접촉·압력·더블 탭은 이번 검사에 포함하지 않았습니다. 로그인·모델·요청 전송·수식 렌더러는 변경하지 않았으며 실제 계정으로 AI 요청을 보내지 않았습니다.

## 실제 시뮬레이터 캡처

- [픽토그램 팔레트](previews/tools-pictograms-dark.png)
- [네모로 선택한 필기](previews/ink-rectangle-dark.png)
- [대화 목록의 글자 대비](previews/chat-history-readable-dark.png)

상호작용 참고: [Notability Select Tool](https://support.gingerlabs.com/hc/en-us/articles/360018646412-Select-Tool). 아이콘 이미지는 가져오지 않고 앱 내부 벡터 경로로 직접 제작했습니다.
