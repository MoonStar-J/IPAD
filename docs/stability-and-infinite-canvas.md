# 필기·가져오기 안정화 (2026-10-07)

## 실제 경로와 수정

- 실제 앱 타깃은 `NoteMargin.xcodeproj / NoteMargin`. Bundle ID와 사용자 서명 설정을 유지한다. 생성 스크립트도 기존 빌드 설정과 실행 스킴을 보존한다.
- 도형: `DrawingSession → ShapeCompletionController → ShapeRecognizer → ShapeStrokeCompleter → replaceDrawing → PKCanvasView`. 인식에는 정지 시작 전의 실제 샘플을 사용하고, Undo 원본에는 스냅 전 실제 샘플을 보존한다. 정지 구간의 작은 떨림을 도형의 변/둘레로 피팅하지 않는다.
- 확정은 자체 touch-ended와 PencilKit native-ended 및 일치하는 원본을 확인한다. 추정치 알림 뒤에 반드시 별도 drawing revision이 온다는 가정을 제거했다. 이후 동일 획의 늦은 native 수정은 기존 receipt로 복구하며 두 번째 Undo를 등록하지 않는다.
- 표시: 기존 종이 타일 + 기존 필기 + 보정 획의 미리보기를 유지한다. 문서용 light trait로 래스터와 뷰를 일치시키고, 설치된 drawing의 실제 렌더 콜백과 Core Animation 완료 후 인계한다. 별도 drawing echo는 요구하지 않는다. 다음 접촉이 먼저 오면 이전 미리보기를 해제한다.
- 선택 UI는 선택한 획이 있으면 펜 도구에서도 표시한다. 기존 직접 편집 로직은 유지한다. 재선택 시 최소 도형 메타데이터로 종류와 닮음 변형을 복원한다.
- `PKDrawing.dataRepresentation()`에는 drawing별 식별자가 있어 새 drawing을 생성해 해시하면 동일 획도 다르게 식별된다. 새 메타데이터는 stroke ID와 공개 path 좌표/transform의 결정적 SHA-256을 사용한다. 부분 지우기 mask 또는 변형된 경로는 도형으로 복원하지 않는다. 원본 잉크는 변경하지 않는다.
- 캔버스 교체 시 입력 policy와 손가락 이동 설정을 유지한다.
- 가져오기: `LibraryView`가 `PDFImportFlow` 하나를 소유한다. 파일 선택창은 URL을 한 번 전달하고, Reader 작업은 선택창과 별개 수명을 가진다. 같은 상위 시트에서 준비/옵션/실패를 전환하고, 상위 시트를 닫은 뒤 생성한 노트를 연다. 이전 picked/pending/deferred 준비결과와 두 번째 옵션 시트 경로를 제거했다. 취소 세대와 한 번 소비하는 준비결과로 늦은 결과/중복 생성을 막는다.
- 팔레트: 잡은 지점의 오프셋으로 자유 이동하고 놓을 때만 위치를 저장한다. 각 가장자리의 최종 크기, safe area, 실제 UI anchor 프레임으로 유효 구간을 구한다. 공간이 없으면 축소 버튼으로 접근한다. 팔레트를 위해 헤더/페이지 컨트롤을 이동하던 분기를 제거했다.
- 테마: AccentColor와 루트 `AppAppearance`만 사용한다. 시스템/라이트/다크 선택을 UserDefaults에 저장한다. 문서의 흰 종이와 원본 잉크/PDF는 독립적으로 유지한다.

## 무한 캔버스와 저장 호환

새 기본 노트만 `고정 페이지 / 무한 캔버스`를 선택한다. 기존 문서/PDF는 변환하지 않는다.

`NotePage`의 선택 필드 `canvasMode`, `viewport`, `inkShapes`가 없으면 기존 고정 페이지로 읽힌다. 원본은 계속 기존 PKDrawing 파일이다. 별도 DB나 원본 평탄화/손실 압축을 추가하지 않는다. 노트 복제는 기존 자산 복사 경로를 그대로 사용한다.

논리 좌표는 음수도 허용한다. 실제 터치 테스트에서 PencilKit은 음수 contentInset 영역에서 native tool을 시작하지 않았다. 그래서 표시용 작업 범위가 왼쪽/위로 확장될 때만 양수 native 원점을 조정하고, 공개 `PKDrawing.transformed`의 획 변환 행렬로 표시한다. 입력 샘플/전체 path 좌표를 매 입력이나 스크롤 프레임마다 다시 쓰지 않는다. 저장·선택·지우개·캡처는 원래 논리 좌표를 사용한다. 무한 노트의 Undo만 같은 논리 좌표 스냅샷을 등록해 표시 원점 변화에 영향받지 않게 했다. 원점 왕복 변환은 PKDrawing의 식별자를 새로 만들므로, 확정한 논리 스냅샷과 native 스냅샷을 짝으로 유지한다. 같은 native 콜백에서 재변환하지 않아 Undo/Redo와 선택·지우개 화면 인계가 동일 원본을 참조한다. 표시 원점 변경은 native 좌표의 보정 기록만 무효화하고, 이미 확정된 도형의 논리 좌표 선택은 유지한다. 기존 유한/PDF의 native Undo는 유지한다. 종이 배경은 기존 768px 가시 타일 캐시와 overscan을 사용한다. 빈 공간 이동 면적만큼 bitmap을 만들지 않는다. 작업 범위 확장으로 커지는 경계 타일만 다시 렌더하고, 내부 타일은 재사용한다. 지우개/선택/도형/영역 캡처는 같은 좌표계를 사용한다. 무한 노트에서는 페이지 넘김과 유한 페이지 중앙 정렬을 적용하지 않는다. 배율 버튼은 첫 필기 위치로 100% 복귀한다.

무한 노트 PNG/썸네일은 사용 영역을 최대 4096px 변으로 제한한다. PDF는 사용 영역을 768×1024 논리 좌표의 유한 페이지로 나눈다. 10,000페이지 초과는 오류로 중단한다. 저장된 원본 필기의 해상도는 바뀌지 않는다. 텍스트/사진도 음수 좌표를 유지하며 무한 노트에서는 숫자로 위치/크기를 편집한다.

## Google Drive 설정

파일 앱의 Drive 제공자를 대신 열지 않는다. 시스템 `ASWebAuthenticationSession → Google 계정/Picker → code와 picked_file_ids → PKCE token 교환 → 선택한 PDF metadata/alt=media → PDFImportFlow` 경로다. `drive.file` 단독 scope, `prompt=consent`, `trigger_onepick=true`, PDF MIME 필터, 단일 파일 선택을 요청한다. 다른 계정 선택은 별도 버튼이다.

설정이 없으면 **Google Drive 설정 필요**를 표시한다. 다음은 사용자의 Google Cloud 프로젝트에서 해야 한다.

1. Google Cloud 프로젝트에 **Google Drive API**와 **Google Picker API**를 활성화한다. OAuth 동의 화면의 앱 정보/대상 사용자를 구성하고 테스트 모드라면 사용할 Google 계정을 테스트 사용자에 추가한다.
2. OAuth Client를 **iOS** 유형으로 생성한다. 현재 NoteMargin 타깃의 기존 Bundle Identifier를 등록한다. 앱 Bundle ID를 변경하지 않는다.
3. NoteMargin 타깃의 Debug/Release User-Defined Build Settings에 `GOOGLE_CLIENT_ID`를 발급된 Client ID, `GOOGLE_REVERSED_CLIENT_ID`를 점 구분 순서를 뒤집은 값으로 설정한다. 예: `123.apps.googleusercontent.com` → `com.googleusercontent.apps.123`. 예시 값을 실제 앱에 넣지 않는다. Personal 타깃을 따로 빌드한다면 그 Bundle ID용 iOS client를 별도로 등록한다.
4. Info.plist의 GIDClientID/URL scheme은 위 설정을 참조한다. OAuth 반환 주소는 `<reversed-client-id>:/oauth2redirect`다. 웹용 client secret이나 임의 WKWebView 로그인은 사용하지 않는다.
5. 빌드 후 PDF 가져오기 → Google Drive에서 선택 → 계정 로그인/동의 → PDF 선택 → 페이지 배치 → 노트 열기를 확인한다. 이후 네트워크를 끊어 로컬 첨부가 열리는지 확인한다.

state/반환 스킴·경로·중복 파라미터를 검증하고 PKCE S256을 사용한다. 토큰은 이 기기에서 잠금 해제 후 접근 가능한 Keychain 항목에 저장하며 진단 로그에 출력하지 않는다. 다운로드 중 만료/401은 refresh token으로 한 번 갱신한다. 새 계정 선택 시 이전 계정의 refresh token을 혼용하지 않는다. 취소/권한 거절/비 PDF/다운로드 실패는 각각 공통 가져오기 화면으로 전달한다.

확인한 공식 문서:
- [Google desktop/mobile Picker](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker)
- [Native-app OAuth와 PKCE](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Drive 인증 범위](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [iOS client 설정](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Drive 다운로드](https://developers.google.com/workspace/drive/api/guides/manage-downloads)

Apple 콜백 계약은 설치된 SDK의 공개 `PencilKit/Headers/PKCanvasView.h`도 확인했다. 종료/추정치/drawing echo의 특정 순서를 보장하지 않는다. 이번 변경은 새 외부 소스 코드를 차용하지 않았다. 기존 ShapeEditing의 Excalidraw MIT 고지는 그대로 유지한다.

## 검증 상태

실제 작업 체크아웃과 Xcode에서 여는 `/Users/whans/Documents/IPAD`의 변경 소스를 일치시켰다. Xcode 체크아웃의 기존 빌드 설정과 LaunchAction은 보존했다. 앱을 삭제하거나 사용자 문서를 초기화하지 않았다.

실행한 기본/합성 검증:

```sh
swift run --scratch-path /private/tmp/NoteMargin-core-stability CoreChecks
# 65/65 통과
xcrun swiftc -O -D SHAPE_RECOGNITION_STANDALONE NoteMargin/Canvas/ShapeRecognition.swift scripts/shape_recognition_checks.swift -o /private/tmp/nm-shape-recognition
/private/tmp/nm-shape-recognition
# 523개 도형 인식 검사 통과
xcrun swiftc NoteMargin/Canvas/ShapeRecognition.swift NoteMargin/Canvas/ShapeEditing.swift scripts/shape_editing_math_checks.swift -o /private/tmp/nm-shape-math
/private/tmp/nm-shape-math docs/fixtures/shape-editing-upstream.json
# upstream fixture 344개에 대한 2174개 검사 통과
python3 scripts/check_pdf_import.py 188E829C-2789-42CD-A31C-E6296F097D26 --drawing-engine --reuse-work /var/folders/wb/hzygp7510z38b4vblx_m9xh00000gn/T/NoteMarginPDFChecks-qqfj_aqp
# 별도 테스트 앱: 공간 인덱스 202, 스냅샷 48, 도형 생명주기/Undo 374,
# 직접 편집 74, 저장 30 및 기존 PDF/필기/선택/뷰포트 검사 통과
```

실제 Xcode 프로젝트 빌드:

```sh
xcodebuild -quiet -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin \
  -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/NoteMargin-actual-final \
  CODE_SIGNING_ALLOWED=NO build
# exit 0. iPadOS 빌드이며 실제 iPad 설치/실행 결과는 아니다.
```

실제 앱 타깃은 iPad Pro 13-inch (M5), iOS 26.5 Simulator에서 테스트했다.

```sh
xcodebuild -quiet -project NoteMargin.xcodeproj -scheme NoteMargin \
  -destination 'platform=iOS Simulator,id=188E829C-2789-42CD-A31C-E6296F097D26' \
  -derivedDataPath /private/tmp/NoteMargin-stability CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

전체 실행은 **16/16 통과, exit 0**였다. 실제 시스템 파일 선택창을 거친 첫 가져오기·두 번째 연속 가져오기·취소 후 재시도, 테마 전환/재실행, 팔레트 드래그 중 헤더/페이지 컨트롤 고정, 실제 터치에 의한 선 보정과 다음 획, 음수 논리 위치의 무한 노트 필기·2단계 Undo/Redo·재열기를 확인했다.

이후 경계 타일 캐시와 선택 메뉴의 실제 팔레트 위치 참조를 보완했다. 관련 코드만 다시 검증한 명령은 위 명령의 `test` 앞에 다음 옵션을 추가한 것이다.

```sh
-only-testing:NoteMarginTests \
-only-testing:NoteMarginUITests/EditorFlowTests/testInfiniteCanvasAcrossScreensAndReopen \
-only-testing:NoteMarginUITests/EditorFlowTests/testPaletteDragLeavesHeaderAndPageControlsFixed \
-only-testing:NoteMarginUITests/EditorFlowTests/testRealAppLineHoldNextStrokeAndReopen
```

추가 경계 타일 테스트를 포함한 내부 테스트 12개와 관련 화면 테스트 3개, **15/15 통과, exit 0**였다. 전체 실행과 합치면 중복을 제외한 17개 앱 테스트 항목을 검증했다. 마지막으로 원점 변경 시 확정된 도형 선택을 보존하도록 보완한 뒤, 위 명령에 `-only-testing:NoteMarginTests`만 추가해 **12/12 통과, exit 0**를 재확인했다. 같은 최종 소스로 실제 Xcode 체크아웃의 iPadOS 빌드도 다시 통과했다.

중간 실패도 실제로 재현했다. 기존 shape Undo fixture는 정지 시작으로 인식 샘플을 자를 때 Undo 원본까지 잘려 실패했고, Undo에는 실제 스냅 전 샘플 전체를 사용해 해결했다. 무한 노트는 음수 UIScrollView 영역에서 native 입력이 시작되지 않아 표시 원점을 도입했다. 이어 원점 왕복 변환의 Drawing 식별자 변경으로 Undo 동등성 검사가 실패했으며, 원본 포인트·필압·굵기·변환은 동일함을 별도 검사한 뒤 논리 스냅샷을 보존해 해결했다. Undo의 기존 Drawing 동등성 검사는 유지하고 원본 획의 기하/속성 검사를 추가했다. 래스터 캡처 검사는 실제 캡처를 확인한 뒤 얇은 획의 앤티앨리어싱을 반영해 RGB 각 채널 임계값을 90에서 170(0–255 기준)으로 바꿨다. 원본 위치·변환 검사는 함께 유지했다.

## 앱에서 확인하기

1. 노트에 선을 그리고 끝에서 약 0.55초 멈춘다. 닿은 상태에서 선이 보정되고 다시 움직이면 시작점이 고정된 채 끝점이 따라온다. 원·타원·삼각형·사각형은 멈춤 후 펜을 떼면 바로 선택된다. 이동·크기 조절 후 Undo/Redo, 선택 해제·재선택·노트 재열기를 확인한다.
2. 팔레트 손잡이를 화면 가운데까지 끌었다 놓는다. 드래그 중에는 손가락을 따라오고, 놓으면 기존 헤더·페이지 버튼을 피해 가장자리에 정착한다.
3. PDF 가져오기 → 파일에서 선택 → PDF 하나 선택 → 페이지 배치 → 노트 열기를 확인한다. 취소 후 다시 선택하거나 연속으로 가져와도 된다.
4. 설정 → 화면 모드에서 시스템/라이트/다크를 바꾼 뒤 재실행한다. UI만 바뀌고 흰 종이·PDF·잉크 색은 유지돼야 한다.
5. 새 노트 → 무한 캔버스에서 여러 화면만큼 상하좌우 이동하여 필기한다. 선택·이동·지우기, Undo/Redo, 영역 AI 캡처, 노트 재열기와 PNG/PDF 내보내기를 확인한다. 배율 버튼은 첫 필기 위치로 돌아간다.

## 남은 실기기·계정 검증

연결된 iPad는 잠금/DDI 마운트 오류로 접근할 수 없었다. **실제 Apple Pencil의 필압·추정치 순서·입력 지연과 실기기 해결 완료는 확인하지 않았다.** 시뮬레이터의 손가락 이벤트 및 합성 샘플을 Pencil 측정으로 표현하지 않는다. 측정하지 않은 지연/프레임률 수치는 보고하지 않는다.

Google iOS OAuth Client 설정이 없어 **실계정 로그인 → Picker → PDF 다운로드는 미검증**이다. 위 Google 설정 후 해당 경로와 계정 변경·권한 거절·취소·다운로드 후 오프라인 재열기를 확인해야 한다. 구성 전 UI에는 ‘Google Drive 설정 필요’가 표시된다.
