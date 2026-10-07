# 편집·가져오기 안정화 검증 기록 (2026-10-07)

## 기준과 실제 빌드

기준 커밋은 `9e3d3ac79836ff148dab6327a2a7ff3ca33c4ca6`이며 최신 로컬 변경을 먼저 보존했다. 작업 저장소와 현재 Xcode가 여는 `Documents/IPAD/NoteMargin.xcodeproj`에 수정 사항을 반영했다. `NoteMargin` 앱 타깃, 기존 Bundle ID와 서명 설정을 유지했다. 팔레트 배치의 별도 사용자 변경은 수정·커밋 대상에서 제외했다.

검증 환경: Mac16,13 / 메모리 24GiB, Xcode 27.0 (27A266a), iPad Pro 13 M5 시뮬레이터 iPadOS 26.5, 연결된 iPad A16 iPadOS 26.7.1. 테스트 노트·첨부·Keychain 항목은 별도 UUID 저장 위치를 사용한다. 실제 사용자 노트와 인증을 초기화하거나 앱을 삭제하지 않았다.

## 확인한 원인과 책임 변경

- **입력:** 손가락 필기 설정에서 첫 도형 드래그가 0pt 이동하는 현상을 실제 iPad와 시뮬레이터 UI 테스트로 재현했다. 입력 인식기 순서만으로 해결된다고 가정하지 않고 확정된 도형 선택의 입력 권한을 CanvasHostView에서 관리한다. 확정된 도형 선택 중에는 기존 drawing recognizer를 비활성화하고, 선택 해제·도구 전환으로 즉시 복원한다. 진행 중인 PencilKit 획에는 활성화 토글을 하지 않는다. 실제 iPad에서 같은 첫 드래그가 실패 → 통과로 바뀌었다.
- **표시 인계:** Session의 프로그램 drawing 할당은 `loading`으로 네이티브 재진입 콜백을 억제하는데, Host는 별도 `drawingDidChange` echo를 기다렸다. 그 대기를 제거하고 실제 확정 drawing, 네이티브 렌더 완료, 화면 트랜잭션 완료와 세대 검사를 사용한다. 별도 대기 불리언은 확정 drawing의 존재에서 계산한다. 지우개 인계의 임의 34ms 대기도 제거했다.
- **다크 배경:** ShapeHeldPreview만 `.light` trait를 강제해서 바깥의 동적 배경이 라이트 색으로 표시될 수 있었다. 표시 계층은 실제 컨테이너 trait를 따르고, 저장된 잉크 색을 보존하는 래스터화의 `.light`와 의도된 흰 종이는 유지한다. 종이 복사는 기존 타일을 공유한다.
- **배경 무효화:** 페이지 전체 비교로 도형 메타데이터·그룹·viewport까지 종이 타일을 비웠다. `PaperContent`는 종이/PDF/삽입 항목 픽셀에 영향을 주는 값만 비교하는 키다. 새 캐시가 아니다. 배율 정밀화는 기존 제스처 종료 경계에서 수행한다.
- **첫 지우기:** NativeInkRasterCache가 화면의 획마다 `PKDrawing.image`를 호출했다. 같은 캐시에서 수정하지 않는 획을 타일별 원래 순서대로 묶고, 이동/희미해지는 획의 순서에서 나눈다. 마스크·필압·형광펜은 네이티브 래스터를 유지한다. 다른 타일에서 들어오는 선택 획도 원래 겹침 순서를 지킨다. 미리보기 종료 시 타일 레이어도 제거한다.
- **revision 비용:** 획 지우기는 지운 인덱스를 이미 알고 있다. 이 정보로 기존 공간 인덱스와 살아남은 텍스처 연결을 갱신하여 다음 접촉에서 모든 획을 다시 비교하지 않는다. 전체 잔존 획 배열 구성은 확정 경계에서 한 번 수행한다. 32MiB LRU 한도·취소·세대 검사를 유지한다.
- **저장 후 도형 상실:** PKDrawing의 transform은 저장 과정에서 Float32 정밀도가 되는데 지문은 원래 Double을 사용했다. 소수점 이동/크기 조절 후 다시 열면 도형 연결이 풀렸다. 저장 정밀도로 지문을 계산하는 회귀 테스트를 먼저 실패시킨 후 수정했다. 저장 실패 시 drawing과 Undo를 먼저 변경하지 않는다.
- **렌더 실행 정책:** 순수 도형 피팅만 백그라운드에서 계산하고 네이티브 잉크 래스터는 기존 캐시와 같은 메인 액터에서 실행한다. Apple이 `PKDrawing.image`의 모든 호출에 메인 스레드를 강제한다는 주장이 아니라, 앱 안의 공유 렌더 작업을 직렬화한 정책이다.

새 PaperContent 타입은 배경의 실제 무효화 입력을 명시하기 위해서만 추가했다. 새 렌더 관리자, 저장 DB, 인증 서버는 만들지 않았다. 기존 ShapeEditing의 출처·라이선스는 유지했다.

## 원 우선 인식

원 피팅을 타원 성공 여부에서 분리했다. 유효한 원/타원 후보가 비슷할 때 축 비율 `1.24` 이하이면서 정규화 오차 차이 `0.022` 이하이면 원을 선호한다. 기존 신뢰도 `0.88`, 닫힘·분포·회전·최대 오차·다각형 검사는 유지한다. 1.14/1.18 비율의 약간 찌그러진 원, 1.35/1.7/2.4 타원, 회전·크기·흔들림·닫힘 오차와 기존 반례를 재현 가능한 fixture로 남겼다.

## 성능 측정 범위

[수정 전](fixtures/editing-performance-before.json), [수정 후](fixtures/editing-performance-after.json), [실기기](fixtures/editing-performance-ipad.json)에 단계별 원시 수치를 저장했다. 동일한 60/1,500획, 24점/획, 화면 800×1000, 배율 1/2.5, 같은 문서 위치와 지우개 경로를 사용했다. 일반 문서와 원 도형을 추가한 문서를 비교한다. 각 조건의 앱 자체 잉크 캐시는 차가운 상태로 시작하며 접촉 4회, 64개 입력 묶음을 실행한다.

실제 Host의 시작·이동·확정·저장을 호출한 내부 계측이며 Pencil의 입력-화면 지연을 측정한 것은 아니다. 프로세스 peak RSS는 앞선 테스트의 최고치도 포함하므로 개별 문서 메모리 또는 메모리 절감률로 해석하지 않는다. 타일을 묶으면 첫 준비 호출은 줄어들지만 처음 지워지는 획 주변 타일의 분할 비용이 이동 구간으로 일부 이동한다. 전체 단계 수치를 함께 비교해야 한다.

| 1,500획 조건 | 첫 준비 전 → 후 (ms) | 반복 준비 후 (ms) | 배경 / 잉크 래스터 횟수 전 → 후 |
|---|---:|---:|---|
| 일반 · 1배 | 3184.1 → 212.5 | 16.6–18.2 | 0 → 0 / 1664 → 20 |
| 일반 · 2.5배 | 1277.4 → 206.0 | 7.0–9.7 | 0 → 0 / 660 → 30 |
| 도형 포함 · 1배 | 3233.7 → 188.6 | 17.9–18.8 | 6 → 0 / 1668 → 20 |
| 도형 포함 · 2.5배 | 1181.5 → 253.3 | 6.3–8.2 | 70 → 0 / 664 → 30 |

시뮬레이터 비교 실행 `nm-verified-editing.xcresult` 1회의 결과다. 실기기 iPad A16에서는 도형 포함 1,500획 첫 준비가 1배 33.0ms, 2.5배 24.0ms였다. 같은 실기기의 수정 전 수치가 없으므로 실기기 향상률로 계산하지 않는다.

수정 전 비교 빌드는 작업 시작 소스를 별도 임시 디렉터리로 복사하고, 동일 입력을 전달하는 메서드와 계측만 삽입했다. 실제 앱의 원본 수정 경로를 대체하지 않는다.

## Google Drive: 구현과 한 번 필요한 설정

연결 → ASWebAuthenticationSession → OAuth code/state/PKCE 검증 → Keychain → 공식 모바일 Picker → PDF 다운로드 → 기존 PDFImportFlow 순서다. 연결 상태와 계정 표시, 재실행 후 복원, 만료 토큰 갱신, 다른 계정, 이 기기 연결 해제, 취소·권한 거절·네트워크 실패를 처리한다. 다른 계정 선택 시 이전 refresh token을 재사용하지 않는다. 연결 해제는 기기의 자격증명 삭제이며 Google 계정의 권한 철회는 계정 설정에서 한다.

현재 로컬/실제 Xcode 빌드에서 `GOOGLE_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`가 비어 있다. 등록 값을 찾지 못했으므로 **실계정 로그인·Picker 선택·다운로드 성공은 미검증**이다. 버튼은 항상 표시하며 설정 누락을 설명한다. 일반 사용자에게 Client ID를 입력받는 화면은 없다.

개발자가 한 번 할 설정:

1. Google Cloud 프로젝트에서 **Google Picker API와 Google Drive API**를 활성화한다.
2. Google Auth Platform의 앱 이름·지원 이메일·대상 사용자를 설정한다. 테스트 상태라면 사용할 Google 계정을 테스트 사용자로 등록한다.
3. iOS OAuth 클라이언트를 만들고 설치할 앱의 Bundle ID `com.yeobaek.notes`를 등록한다. 다른 Bundle ID의 타깃은 별도 클라이언트를 사용한다. 웹 클라이언트나 client secret을 앱에 넣지 않는다.
4. NoteMargin 타깃의 Debug/Release 사용자 정의 빌드 설정에 `GOOGLE_CLIENT_ID=<등록된 iOS client ID>`, `GOOGLE_REVERSED_CLIENT_ID=<점으로 구분된 client ID를 역순으로 한 값>`을 설정한다. Info.plist의 `GIDClientID`와 URL Types가 이 값을 참조한다. 설치 빌드의 확장된 Info.plist에서도 값과 URL scheme을 확인한다.
5. 빌드 후 파일 가져오기 → Google Drive 연결에서 로그인, 파일 선택, PDF 페이지 방식 선택을 확인한다. 취소·거절·계정 변경·재실행·권한 철회를 실제 계정으로 추가 검증한다.

공식 모바일 Picker는 `drive.file` 단독 scope와 `prompt=consent`, `trigger_onepick=true`를 사용한다. 프로필 scope를 섞지 않고 계정 표시는 Drive `about` 응답에서 읽는다. [Google 모바일 Picker 문서](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker), [iOS OAuth 문서](https://developers.google.com/identity/protocols/oauth2/native-app).

## 휴지통과 저장 호환

검색 중에도 확인창에 휴지통 전체 대상 수와 복구 불가를 표시한다. 확인 시 deletedAt을 다시 검사하며 일반/복원된 노트는 제외한다. 한 번 flush한 뒤 삭제 ID를 검증하고 라이브러리 변경을 묶어 저장한다. 첨부·AI 대화 정리 결과도 묶어 저장하며 N개 노트마다 전체 라이브러리를 저장하지 않는다.

기존 library.json에 optional `pendingAssetDeletions`만 추가했다. 파일 정리에 실패한 ID를 보존해 재실행 후 다시 시도할 수 있다. 기존 데이터는 변경 없이 읽힌다. 완료되지 않은 정리를 성공으로 표시하지 않으며 이미 복원/생성된 노트의 ID는 정리하지 않는다. 도형 파일 형식과 AI 대화 형식은 그대로다. 이전에 이미 연결이 끊긴 도형 메타데이터를 추측해 새로 만들지는 않는다.

## 실제 검증 기록

실행한 주요 명령 (공개 기록에서는 실기기 식별자를 생략):

```sh
swift run --scratch-path /private/tmp/note-margin-swift-build CoreChecks
swiftc -O -D SHAPE_RECOGNITION_STANDALONE -module-cache-path /private/tmp/note-margin-shape-module-cache NoteMargin/Canvas/ShapeRecognition.swift scripts/shape_recognition_checks.swift -o /private/tmp/nm-circle-final
/private/tmp/nm-circle-final
python3 scripts/check_pdf_import.py 188E829C-2789-42CD-A31C-E6296F097D26 --drawing-engine --reuse-work /var/folders/wb/hzygp7510z38b4vblx_m9xh00000gn/T/NoteMarginPDFChecks-qqfj_aqp
xcodebuild -project NoteMargin.xcodeproj -scheme NoteMargin -destination 'platform=iOS Simulator,id=188E829C-2789-42CD-A31C-E6296F097D26' -derivedDataPath /private/tmp/NoteMargin-editing -resultBundlePath /private/tmp/nm-final-origin-tests2.xcresult -collect-test-diagnostics never -only-testing:NoteMarginTests test
xcodebuild -project NoteMargin.xcodeproj -scheme NoteMargin -destination 'platform=iOS Simulator,id=188E829C-2789-42CD-A31C-E6296F097D26' -derivedDataPath /private/tmp/NoteMargin-editing -resultBundlePath /private/tmp/nm-verified-editing.xcresult -collect-test-diagnostics never -only-testing:NoteMarginTests -only-testing:NoteMarginUITests/EditorFlowTests/testFirstShapeDragAndCornerResize -only-testing:NoteMarginUITests/EditorFlowTests/testInfiniteShapeDragAndCornerResize -only-testing:NoteMarginUITests/EditorFlowTests/testInfiniteCanvasAcrossScreensAndReopen -only-testing:NoteMarginUITests/EditorFlowTests/testDarkLineHoldNextStrokeAndReopen -only-testing:NoteMarginUITests/EditorFlowTests/testRealAppLineHoldNextStrokeAndReopen test
xcodebuild -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin -destination 'platform=iOS,id=<IPAD_UDID>' -derivedDataPath /private/tmp/NoteMargin-device-editing -only-testing:NoteMarginUITests/EditorFlowTests/testFirstShapeDragAndCornerResize -only-testing:NoteMarginUITests/EditorFlowTests/testInfiniteShapeDragAndCornerResize -collect-test-diagnostics never -allowProvisioningUpdates test
xcodebuild -project /Users/whans/Documents/IPAD/NoteMargin.xcodeproj -scheme NoteMargin -destination 'platform=iOS,id=<IPAD_UDID>' -derivedDataPath /private/tmp/NoteMargin-device-editing -allowProvisioningUpdates build
```

CoreChecks 65/65, 최적화 Swift 도형 인식 649개 통과. 최종 앱 단위 검사 23개는 `nm-final-origin-tests2.xcresult`에서 통과했다. 기존 통합 검사(공간 revision 202, 활성 획 스냅샷 48, 도형 수명·속성·Undo 374, 직접 도형 편집 74, 영속 저장 30 및 기존 PDF·선택·화질·viewport 검사)도 통과했다.

시뮬레이터 UI 5개(첫 도형 편집, 무한 캔버스 도형 편집, 무한 캔버스 이동·저장·재열기, 라이트/다크 선 자동완성·다음 획)는 `nm-verified-editing.xcresult`에서 통과했다. Drive 설정 누락·휴지통 전체 삭제 UI 2개는 `nm-final-app-tests.xcresult`에서 통과했다. 실제 iPad UI 편집 흐름 2개는 `nm-device-permission.xcresult`에서 통과했다. 저장된 원 도형 fixture에 실제 손가락 드래그를 전달했으며, 변환 함수를 직접 호출해서 UI 성공으로 대신하지 않았다. 마지막 원점 취소 수정까지 실제 Xcode 앱 타깃의 기기용 빌드가 성공했고, 기존 Bundle ID로 연결된 iPad에 덮어 설치했다.

다크 선 자동완성의 실제 시뮬레이터 녹화 38.85초 중 스냅/다음 획 구간 29–33초의 81개 기록 프레임에서 화면 외곽 밝기는 최대 28.67/255, 종이 표본은 최소 254.37/255였다. [프레임 표본](fixtures/dark-transition-frames.json). 전환 전·중·후 이미지도 직접 확인했다. 이 측정은 화면 표본과 기록된 프레임 범위에 한정하며, 모든 Pencil/모든 도형/모든 디스플레이 프레임의 무결성 증명은 아니다. README의 편집 사진은 이 실제 시뮬레이터 화면이다.

중간 실패도 보존했다: 소수점 도형 저장 지문과 메타데이터 배경 캐시 검사가 수정 전 실패했다. 손가락 필기 켜짐의 첫 드래그는 시뮬레이터 전체 실행 및 실제 iPad에서 실패하여 입력 소유권을 수정했다. 실기기 Undo 버튼 검사는 화면 밖 중복 버튼을 탭하는 테스트 좌표 문제가 있어 실제 hittable 버튼을 선택하도록 고쳤다. 기존 캐시 검사는 모든 획이 개별 텍스처라는 전제를 제거하고, 개별 텍스처를 먼저 준비한 뒤 동일한 재사용 검증을 유지했다. 휴지통 컨텍스트 메뉴에서 XCUITest의 유휴 대기가 멈춘 실행은 중단했고, 삭제된 전용 fixture에서 실제 전체 삭제/취소 UI를 검사했다. 새 원점 취소 검사는 처음에 빈 객체 선택 레이어를 잘못 찾아 실패했으며 실제 표시 중인 필기 윤곽선을 찾아 검사하도록 수정한 후 전체 23개를 다시 통과했다.

## 변경 파일

- 편집 책임: `Canvas/DrawingSession.swift`, `NotebookCanvas.swift`, `ShapeCompletion.swift`, `PageRenderer.swift`, `InkSpatialIndex.swift`, `DrawingEngineMetrics.swift`.
- 원 판별: `Canvas/ShapeRecognition.swift`, `scripts/shape_recognition_checks.swift`.
- Drive: `Core/GoogleDriveOAuth.swift`, `Services/GoogleDriveImport.swift`. 기존 Info.plist URL 등록 경로 재사용.
- 휴지통: `App/NoteStore.swift`, `Core/Models.swift`, `Core/LibraryRepository.swift`, `Services/MarginAIStore.swift`, `Views/LibraryView.swift`.
- 검증: 기존 `Tests/AppTests/StabilityTests.swift`, `Tests/UITests/EditorFlowTests.swift` 확장. 통합 스크립트는 테스트 노트를 먼저 휴지통으로 옮긴 뒤 삭제하도록 새 안전 정책을 따른다.
- 문서: `AGENTS.md` 구조 원칙 7개, 기능·실제 화면 위주로 줄인 `README.md`, 이 기록과 전용 계측 JSON.

소스 파일 경로는 `NoteMargin/` 기준이다. 기존 ShapeEditing 계산·선택 도구·AI 요청·인증·노트 가져오기 구조를 재사용한다.

## 앱에서 확인

1. 손가락 필기를 켠 뒤 원을 그려 끝점에서 멈춘다. 선택된 도형의 내부를 바로 끌고 모서리를 끌어 비율 크기를 바꾼다. 밖을 눌러 해제한 뒤 박스 선택으로 다시 선택한다.
2. Undo/Redo, 획 지우기, 노트 닫기/다시 열기를 확인한다. 무한 캔버스에서 화면을 여러 번 이동한 뒤 같은 편집을 반복한다.
3. 다크/라이트에서 선·원 자동완성의 종이와 바깥 배경이 바뀌지 않는지 확인한다.
4. 최근 삭제된 항목에 테스트 노트를 넣고 검색으로 숨긴 상태에서도 ‘모두 영구 삭제’ 확인 수가 전체인지 확인한다. 취소 후 복원 가능 여부와 재시도 안내를 확인한다.
5. Drive는 위 OAuth 등록 후 실제 계정 로그인부터 PDF 가져오기까지 확인한다.

Apple Pencil의 실제 필압·기울기·손바닥 배제·여러 동시 접촉 및 장시간 고속 연속 입력은 자동 손가락 테스트로 대체할 수 없으며 미검증이다. 실계정 Google 동의 취소·권한 거절·Picker 파일 선택/다운로드·계정 변경은 등록 설정을 완료해야 검증할 수 있다. 공개 배포는 하지 않았다.
