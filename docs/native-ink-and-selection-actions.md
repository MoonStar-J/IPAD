# 필기 미리보기 두께와 선택 편집

## 원인과 수정

이전 지우개·선택 미리보기는 PencilKit 획을 `CAShapeLayer`로 다시 채웠다. 점의 크기를 채워진 펜촉으로 취급하고 opacity를 0…1로 제한했으므로, 원래 PencilKit의 잉크별 농도·입자·압력 렌더링과 달랐다. Apple 문서에서 [점의 opacity는 0…2 범위의 잉크 농도 배수](https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct/opacity)로 설명한다. 이를 일반 레이어 opacity로 적용하면 같은 외형을 얻을 수 없다.

이번 수정은 기하 경로를 선택·충돌 판정에만 사용한다. 화면에는 원본 획과 randomSeed를 보존한 `PKDrawing.image(from:scale:)` 결과를 사용한다. 이미 렌더된 이미지에 기하 경로의 opacity를 다시 곱하지 않는다. 지우개는 닿은 획에만 35% 농도를 적용하며, 선택 이동은 같은 원본 이미지의 위치만 바꾼다.

이미지는 화면 배율에 맞춘 512px 이하 타일로 캐시하며, 긴 PDF 전체 크기의 이미지를 만들지 않는다. 같은 화면 범위에서 이동할 때 재렌더하지 않고, 새로운 원본 영역이 필요할 때만 타일을 추가한다. 큰 선택을 축소하면 선택용 이미지 해상도도 2의 거듭제곱 단계로 줄인다. 미세한 크기 변화마다 다시 렌더하지 않으며, 선택하지 않은 획은 원래 화면 해상도를 유지한다.

캐시에는 32MiB 한도를 두고 표시 중 레이어는 필요한 타일을 별도로 보유한다. 따라서 32MiB는 전체 앱 또는 전체 표시 이미지의 메모리 상한을 뜻하지 않는다. 입력이 멈춘 뒤 캐시를 짧은 배치로 준비하고, 새 필기 입력·화면 이동 시 작업을 취소한다. 변경되지 않은 획은 삭제로 인덱스가 달라져도 기존 이미지를 재사용하며, transform·mask·잉크·점 데이터가 바뀐 획은 재사용하지 않는다. 새 `PKDrawing` 래퍼의 문서 동등성을 획 동등성으로 사용하지 않는다.

`PKDrawing.image`는 메인 액터에서 호출한다. [PiecesOfPaper의 실기 주의 사항](https://github.com/0si43/PiecesOfPaper/blob/main/docs/GOTCHAS.md)에 기록된 백그라운드 PencilKit 이미지 렌더 문제도 참고했다. 사용자 기기에서 같은 내부 문제가 발생했다고 단정한 것은 아니다.

## 선택 편집

- 박스형·자유형 모두 선택이 끝나면 선택 영역 가까이에 편집 바가 나타난다. 팔레트가 접혀 있어도 표시한다.
- 복제, 잘라내기, 복사, 붙여넣기, 그룹화/그룹 해제, 삭제, 저장을 제공한다.
- 선택 바깥을 손가락이나 Pencil로 탭하면 선택을 해제한다. 두 손가락 화면 이동과 선택 내부 이동·모서리 크기 조절은 유지한다.
- 그룹 정보는 기존 페이지 메타데이터에 저장한다. 그룹의 한 획을 선택하면 남아 있는 그룹 획 전체가 선택된다.
- 저장은 편집 가능한 `.drawing`과 PNG를 공유 화면으로 전달한다. 파일 앱 등 원하는 위치로 저장할 수 있다.

[Notability의 그룹·선택 사용 흐름](https://support.gingerlabs.com/hc/en-us/articles/7005107341210-Group-Content-and-Make-Custom-Stickers)을 참고했다. Notability 자체 코드나 에셋을 포함한 것은 아니며, 이 앱의 저장은 파일 내보내기이다.

## 데이터와 검증

기존 페이지는 선택 그룹 필드가 없어도 읽는다. 필기 원본을 이미지로 덮어쓰거나 PDF·대화 저장 형식을 변경하지 않는다. 새로 복제하는 획은 질감 seed를 유지하면서 식별자를 분리한다.

새 그룹 정보만 페이지의 optional `inkGroups`에 저장한다. 과거 버전에서 복제한 획의 ID가 충돌하면 선택한 복제본의 식별자만 분리하며 원래 질감 seed는 유지한다. 이때 필기와 메타데이터 저장 중 실패하면 원본을 복원하고 화면 변경·undo 등록을 진행하지 않는다. 기존 노트의 일괄 재작성이나 별도 DB는 없다.

실행 환경: Xcode 26.6, iPad Pro 13-inch (M5) / iPadOS 26.5 시뮬레이터. `com.notemargin.integrationcheck`의 별도 앱 데이터로 검증했다.

```sh
python3 scripts/check_pdf_import.py --plan --reuse-work /var/folders/wb/hzygp7510z38b4vblx_m9xh00000gn/T/NoteMarginPDFChecks-vdgdh2_6
python3 scripts/check_pdf_import.py --live-ui --reuse-work /var/folders/wb/hzygp7510z38b4vblx_m9xh00000gn/T/NoteMarginPDFChecks-vdgdh2_6 --only-testing CanvasLiveInkTests/InkToolsVisualTests/testAutomaticSelectionActionsInBothModesAndCollapsedPalette --only-testing CanvasLiveInkTests/StrokeEraserVisualTests
xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMarginToolsXcode CODE_SIGNING_ALLOWED=NO build
git diff --check
```

검증 내용:

- 실제 미리보기와 PencilKit 원본 이미지 비교: 펜·연필·형광펜·단색 펜, 압력·opacity·마스크·randomSeed, 원점과 y=70,000 지점. 선택 이동·지우개 시작·지우지 않은 획의 농도 비율 1.00000~1.00001, 면적 비율 1.00000. 지운 획만 농도 0.34902. 겹친 형광펜의 교차 영역은 원본 대비 약 0.972로 허용 오차 6% 안이다.
- 같은 화면의 120회 이동에서 새 래스터화와 기하 재생성 없음. 삭제 후 바뀌지 않은 획 재사용과, 이동한 획의 오래된 이미지 거부 확인.
- 길이 9,520pt의 선택을 5%로 축소해 필요한 해상도의 타일 4개만 추가 생성. 이어지는 미세 크기 변경 120회에서 추가 래스터화 없음. 원본 필기 바이트 유지.
- 박스·자유형 선택의 그룹 확장, 재실행 복원, 이동 후 그룹 유지, 복제본 ID 분리, 그룹화/해제 undo·redo, 저장 실패 시 원본 보존, `.drawing`·PNG 재읽기 확인.
- 기존 필기 저장 30개 검사, PDF·선택·화면 변환 검사, 대화 저장/요청 60개 검사 통과.
- XCTest UI 2개 통과, 실패 0개: 박스 선택 후 7개 작업 버튼, 복사 후 붙여넣기, 자유형 모드의 선택 상태, 접힌 팔레트에서 메뉴 표시, 외부 탭 해제, 지우개를 뗐을 때 삭제. 자유형의 임의 곡선 드래그 전체는 XCTest로 재현하지 않았고, 자유형 경로의 실제 선택·그룹 판정은 별도 프로덕션 코드 검사로 실행했다.

시뮬레이터 합성 180획의 측정은 캐시가 없을 때 준비 약 340ms, 같은 캐시로 다시 준비 약 1.09ms, 120회 이동 처리 합계 약 3.23ms였다. 이것은 host 메서드 시간이며 Apple Pencil의 실제 입력 지연 측정이 아니다. 유휴 시간 사전 준비와 획 재사용으로 입력 중 초기 렌더 부담을 줄였지만, 단일 대형 획 렌더가 4ms 이내라는 보장은 없다. 실제 iPad의 Pencil 입력 및 GPU 성능은 별도 확인이 필요하다.

선택 메뉴 화면: [박스 선택](previews/native-box-selection-actions.png), [자유형 모드](previews/native-freeform-selection-actions.png).

## 앱에서 확인

1. Xcode의 `NoteMargin`으로 iPad에 다시 실행한다.
2. 서로 다른 굵기·색의 획을 쓰고 획 지우개를 댄다. 닿지 않은 획의 굵기가 유지되고, 닿은 획만 반투명해졌다가 펜을 떼면 사라져야 한다.
3. 선택 도구에서 박스형 또는 자유형으로 여러 획을 고른다. 7개 작업 메뉴가 자동으로 떠야 한다. 내부를 드래그하고 모서리로 크기를 바꿔 본다.
4. 그룹화 후 바깥을 탭해 해제하고 그룹의 한 획만 선택한다. 전체 그룹이 선택되어야 하며, 앱을 다시 열어도 유지되어야 한다.
5. 저장을 누르면 `.drawing`과 PNG가 공유 화면에 나오고 파일 앱 등으로 저장할 수 있다.
