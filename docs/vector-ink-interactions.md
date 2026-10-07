# 필기 지우개·선택 최적화

> 후속 수정: 아래 벡터 미리보기에서 원본보다 획이 굵어지는 문제가 확인되어, 표시는 [PencilKit 원본 이미지 캐시](native-ink-and-selection-actions.md)로 교체했습니다. 공간 인덱스·충돌 검사·공통 스크롤 구조는 유지합니다. 아래 수치는 당시 구현의 검사 기록입니다.

## 확인한 원인

획 지우개는 coalesced 입력 점마다 교차하는 획을 `PKDrawing.image`로 렌더하고 RGBA 픽셀을 읽었다. 새로운 획에 닿으면 화면 전체의 정상/반투명 필기 이미지도 재생성했다. 네모 선택 역시 픽셀 단위 충돌 검사와 전체 배경·필기 스냅샷을 사용했다. 긴 PDF와 획이 많은 페이지에서 입력 처리와 렌더링이 경쟁하는 구조였다.

빗금의 특정 GPU 드라이버 원인까지 확인한 것은 아니다. 두 기능에 공통된 반복 이미지 생성·재합성 경로를 제거했다.

PDF는 이전에는 PKCanvasView의 형제 뷰에서 scroll delegate를 따라 움직였다. 현재는 공개 UIView API로 native canvas의 맨 아래 자식으로 배치한다. 종이와 필기가 같은 UIScrollView bounds 이동을 받으므로 pan offset을 별도 화면에 뒤늦게 복제하지 않는다. 확대 배율만 종이에 적용하며 offset을 이중 적용하지 않는다. PKCanvasView는 여전히 화면 크기이고 페이지마다 교체하는 기존 잔상 방지 구조를 유지한다.

## 현재 동작

- 선택 도구 한 개 → `선택 방식`에서 **자유형 / 박스형** 선택. 마지막 방식 기억. 두 방식 모두 이동·모서리 크기 조절·복사·잘라내기·붙여넣기·복제·삭제·실행 취소 사용.
- 문서 좌표의 획 경계를 공간 셀에 인덱싱한다. 실제 후보만 공개 PencilKit spline/압력/펜촉 방향/마스크/획 변환으로 검사한다. 빠르게 움직인 지우개도 coalesced 점 사이를 연결한 경로로 검사한다.
- 변경되지 않은 PKDrawing의 기하 캐시는 지우개와 선택이 공유한다. 빈 공간이나 이미 지워질 획에 다시 닿을 때 이미지를 생성하지 않는다.
- 미리보기는 기존 PDF 타일의 CGImage를 공유하고 획별 CAShapeLayer를 유지한다. 포인터 이동 중에는 경로 생성·원본 직렬화·PKDrawing 대입 대신 opacity/transform을 바꾼다. 깊은 PDF 위치에서도 획 경로를 로컬 좌표로 옮겨 표시한다.
- 획 지우개는 닿은 획을 반투명으로 유지하고 지나간 부분을 흰색으로 표시한 뒤 손을 떼면 한 번에 삭제한다. 마지막 펜 복귀와 한 번의 undo를 유지한다.
- 선택 이동·크기 조절은 테두리와 필기에 같은 변환을 적용한다. 확정 후 native render callback 및 짧은 화면 반영 구간을 거쳐 임시 미리보기를 제거한다. 새 입력/페이지 전환은 오래된 복귀 작업을 취소한다.

미리보기 경로는 편집 중에만 사용한다. PencilKit의 연필 질감·입자까지 복제하는 대체 필기 엔진은 아니다. 저장/내보내기/AI 캡처/취소/확정에는 원본 PKDrawing을 계속 사용한다. 필압·색상·마스크·좌표·획 순서와 기존 저장 형식은 유지되며 마이그레이션은 없다.

## 공개 구현에서 참고한 구조

코드를 복사하지 않고 아래 공개 구현의 구조를 현재 PencilKit 앱에 맞게 독립 구현했다.

- [Saber의 종이·PDF·필기 공통 하위 트리](https://github.com/saber-notes/saber/blob/5b396a40406c75835741f5c4555bc10ae816f121/lib/components/canvas/inner_canvas.dart#L105-L165), [단일 화면 변환](https://github.com/saber-notes/saber/blob/5b396a40406c75835741f5c4555bc10ae816f121/lib/components/canvas/interactive_canvas.dart#L1139-L1168).
- [Saber의 획 경로 캐시](https://github.com/saber-notes/saber/blob/5b396a40406c75835741f5c4555bc10ae816f121/lib/components/canvas/_stroke.dart#L37-L62), [캐시된 형상을 검사하는 지우개](https://github.com/saber-notes/saber/blob/5b396a40406c75835741f5c4555bc10ae816f121/lib/data/tools/eraser.dart#L47-L71). 공간 셀 인덱스는 이 앱에 추가한 최적화다.
- [Jottre의 네이티브 PKDrawing·저장 debounce](https://github.com/antonlorani/jottre/blob/a4ac34d3b5e38c0293c6319e877058bd5e49ece6/Sources/EditJotPage/EditJotViewModel.swift#L130-L151). 이 앱의 기존 백그라운드 저장 병합을 유지한다.

Saber/Jottre는 GPL-3.0이며 소스나 에셋을 앱에 복사하지 않았다. Notability는 이 작업에서 공개 소스 앱으로 취급하지 않았다.

## 실기 확인

1. 현재 Xcode의 NoteMargin 스킴으로 iPad에 다시 실행한다.
2. 필기가 많은 PDF에서 획 지우개를 빠르게 이동한다. 닿은 획만 흐려지고 손을 떼면 삭제되며 마지막 펜으로 돌아오는지 확인한다.
3. 선택 도구의 방식 메뉴에서 자유형과 박스형을 번갈아 사용한다. 선택한 필기를 이동하고 모서리로 확대/축소한 뒤 실행 취소한다.
4. 긴 PDF 아래쪽에서도 반복하고 두 손가락으로 빠르게 pan/pinch한다. 종이와 필기의 위치 관계가 유지되는지 확인한다.
5. 페이지를 바꾸고 다시 돌아와 필기 및 저장 상태를 확인한다.

실제 Apple Pencil 입력 지연·발열·120Hz 프레임 시간은 시뮬레이터 결과로 대신하지 않는다. 최초 PDF 타일 생성은 여전히 제한된 메인 스레드 작업이므로 복잡한 PDF의 모든 프레임 시간을 보장하지 않는다.

## 실행 결과

환경: Xcode 26.6, iPad Pro 13형 시뮬레이터(iPadOS 26.5). 실제 계정 요청 없이 별도 테스트 앱 `com.notemargin.integrationcheck`에서 실행했다.

```sh
python3 scripts/check_pdf_import.py --plan
python3 scripts/check_pdf_import.py --live-ui \
  --only-testing CanvasLiveInkTests/CanvasLiveInkTests \
  --only-testing CanvasLiveInkTests/PageSwapVisualTests \
  --only-testing CanvasLiveInkTests/StrokeEraserVisualTests \
  --only-testing CanvasLiveInkTests/InkToolsVisualTests
python3 scripts/check_pdf_import.py --live-ui \
  --reuse-work /var/folders/wb/hzygp7510z38b4vblx_m9xh00000gn/T/NoteMarginPDFChecks-vdgdh2_6 \
  --only-testing CanvasLiveInkTests/StrokeEraserVisualTests
python3 scripts/check_pdf_import.py --plan \
  --reuse-work /var/folders/wb/hzygp7510z38b4vblx_m9xh00000gn/T/NoteMarginPDFChecks-vdgdh2_6
xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj \
  -scheme NoteMargin -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/NoteMarginToolsXcode CODE_SIGNING_ALLOWED=NO build
```

- 최종 통합 검사 **성공(exit 0)**: 저장 30항목, 대화 저장·요청 60항목, PDF·필기·선택·Undo/Redo·화면 맞춤의 절반 축소·0.1pt 펜 회귀 검사.
- 추가 기하 검사 **성공**: 420획 공간 인덱스/캐시, 빠른 지우개 이동, 압력·변환·마스크·투명 획, 자유형과 박스형 구분, 오목하거나 구멍이 있는 선택 범위, 원본 보존.
- 실제 터치 UI 검사 **총 8개 고유 테스트 통과**: 최초 묶음은 7/8 통과했고 흰 지우개 경로 검사가 실패했다. 크기 없는 알파 마스크 대신 화면 범위로 클리핑하도록 수정한 후 해당 검사를 다시 실행해 1/1 통과했다. 수정 후 8개 전체를 한 번에 다시 실행한 결과는 아니다.
- 밀집 획 미리보기의 픽셀 검사에서 spline 제어점이 실제 곡선 위 점이라는 잘못된 테스트 가정을 발견했다. 공개 PencilKit 보간 지점으로 검사를 수정하고 최종 통합 검사를 통과했다.
- 80,000pt 문서의 y=70,000 부근 지우개 검사 **성공**: 흰 경로, 인접 원본 획, 취소 보존, 화면 크기로 제한된 레이어 확인.
- 실제 Xcode 체크아웃의 iPad용 일반 빌드 **성공(exit 0)**. 코드 서명 없이 빌드했으며 사용자 iPad에 설치하거나 Apple Pencil로 측정한 결과는 아니다.

180개의 짧은 편집 가능 PencilKit 획으로 실제 CanvasHost 경로를 호출한 최종 계측:

| 항목 | 결과 |
| --- | ---: |
| 최초 박스 선택과 미리보기 준비 | 7.937ms |
| 이 중 선택 판정 | 0.496ms |
| 이 중 미리보기 준비 | 7.440ms |
| 캐시된 자유형 선택 판정 | 2.368ms |
| 120회 이동 갱신 합계 | 3.777ms |
| 이동 갱신 중앙값 / 최댓값 | 0.031ms / 0.042ms |
| 이동 중 획 경로 재생성 | 0회 |
| 종이·native canvas 좌표 일치 검사 | 36회 통과 |

최적화 도중 첫 계측의 선택 준비는 575.223ms였다. 완전히 포함된 획에도 복잡한 교차 계산을 하던 경로를 줄인 뒤 위 결과를 얻었다. 이는 기존 배포 앱과의 Apple Pencil 지연 비교가 아닌, 같은 합성 fixture에 대한 개선 전후 CPU 경로 계측이다. 화면 캡처·검사·직렬화 비용은 타이밍에서 제외한다.

변경 파일: `DrawingSession.swift`(공간 캐시·선택/지우개 판정), `NotebookCanvas.swift`(공통 스크롤 부모·벡터 미리보기), `PageRenderer.swift`(종이 변환·타일 공유), `Design.swift`(통합 선택 도구), `ink_selection_checks.swift`·`canvas_ui_checks.swift`(회귀 검사), `check_pdf_import.py`(격리 테스트 빌드 재사용).

검사 화면: [자유형 선택 메뉴](previews/unified-selection-freeform.png), [선택 크기 조절](previews/vector-selection-scale-dark.png), [밀집 획 선택](previews/dense-ink-retained.png), [획 지우개](previews/dense-ink-eraser-trail.png), [긴 문서 아래쪽 지우개](previews/deep-ink-eraser-trail.png).
