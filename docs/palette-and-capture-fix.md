# 팔레트 가장자리 이동 · 손글씨 캡처 수정

2026-10-01

## 원인과 변경

- `RegionContextService.capture`는 이미 PNG를 합성했지만 다크 모드의 현재 trait으로 PencilKit 이미지를 렌더링했습니다. 검은 필기가 흰색으로 바뀌어 흰 용지 위에서 보이지 않는 실패를 테스트로 재현했습니다.
- 캡처는 흰 용지와 실제 `PKCanvasView`에 맞춰 light trait에서 PDF·용지·삽입 항목·필기를 합성합니다. 원본 필기나 노트의 색을 변경하지 않습니다. 긴 PDF도 선택 영역만 최대 1800px로 렌더링합니다.
- `ContextBuilder → PlanRequest.serialize → ChatGPTPlanTransport` 경로에서 원본 스크린샷을 항상 `input_image`의 PNG data URL로 전송합니다. 자동 추출 PDF 텍스트는 요청에 자동 삽입하지 않습니다. 사용자 승인 전사문은 이미지를 대체하지 않고 보조 텍스트로만 함께 보냅니다.
- 로그인·모델 선택·스트리밍 경로는 유지했습니다. 최초 이미지와 이전 대화가 후속 요청에도 연결됩니다.
- `DockedDrawingTools`는 펼친 팔레트의 상단 손잡이 또는 접힌 원형 버튼을 드래그하여 화면 네 가장자리로 이동합니다. 팔레트 전체가 화면 안에 머물도록 제한하고 위치를 앱 설정에 저장합니다. 회전·화면 크기 변화·접기/펼치기에 맞춰 재배치합니다.

## 검증

- 수정 전 `python3 scripts/check_pdf_import.py`: `dark-mode screenshot keeps black handwritten ink visible` 실패를 재현.
- 수정 후 `swift run --scratch-path /private/tmp/note-margin-memory-core CoreChecks`: **59/59 통과**.
- `python3 scripts/check_pdf_import.py --plan`: **49개 실제 저장/모의 HTTP 검사 통과**, PDF·필기 캡처·기존 26개 선택 검사·도킹 기하 검사도 통과. 실제 HTTP 전송 지점에서 PNG를 다시 디코딩해 캡처 bytes 일치와 검은 필기 픽셀을 검사했습니다. 실제 계정으로 요청하지 않았습니다.
- `python3 scripts/check_pdf_import.py --live-ui --only-testing CanvasLiveInkTests/InkToolsVisualTests`: **통과**. 밝은/어두운 모드에서 상단·왼쪽으로 실제 드래그, 우측 하단으로 복귀, 접기/펼치기, 네모 필기 선택·복제·삭제를 검증했습니다.
- Xcode 저장소 `/Users/whans/Documents/IPAD/NoteMargin.xcodeproj`, `NoteMargin` 스킴, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` 빌드 통과.
- `git diff --check` 통과. 새로운 DB나 저장 형식 마이그레이션은 없습니다.

## 앱에서 확인

Xcode에서 iPad를 대상으로 다시 실행합니다. 팔레트의 위쪽 짧은 손잡이를 끌어 가장자리로 옮깁니다. 원형으로 접은 상태에서는 버튼 자체를 끕니다.

필기를 한 후 **질문 → 영역 선택 → 이 영역으로 질문**을 누릅니다. 미리보기에서 필기가 보이는지 확인하고 **내 풀이 검증**을 전송합니다.

이미 필기 없이 저장된 과거 캡처는 자동으로 재작성하지 않습니다. 기존 대화의 **… → 현재 문제에 추가**로 풀이 영역을 다시 캡처하면 이전 대화를 유지하면서 새 이미지를 보낼 수 있습니다.
