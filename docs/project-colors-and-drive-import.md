# 프로젝트 색상과 Google Drive PDF 가져오기

프로젝트는 채워진 폴더 아이콘으로 표시합니다. 폴더와 왼쪽 프로젝트 점은 같은 `CoverColor`를 사용합니다. 프로젝트 생성·설정의 **폴더 색상**에서 바꿀 수 있으며, 기존 색상 필드가 없는 프로젝트는 블루로 표시합니다. 이름만 변경하는 기존 저장 경로는 프로젝트 색상을 유지합니다.

## Google Drive에서 가져오기

1. iPad에 Google Drive 앱을 설치하고 사용할 Google 계정으로 로그인합니다.
2. 파일 앱의 **둘러보기 → … → 편집**에서 **Google Drive** 위치를 켭니다.
3. 노트 여백의 **PDF 가져오기 → Google Drive에서 선택**을 누릅니다.
4. 시스템 파일 선택 화면의 둘러보기 또는 사이드바에서 **Google Drive**를 선택한 뒤 PDF를 고릅니다.
5. 페이지가 여러 장이면 기존과 같이 **하나로 이어 붙이기 / 페이지별로 보기**를 선택합니다.

앱은 iPad 시스템 문서 선택기를 사용합니다. Google 계정 로그인과 접근 권한은 Google Drive 앱에서 관리합니다. 문서 선택기는 PDF 사본을 가져오며 원본 파일을 이동하거나 수정하지 않습니다. Drive 위치가 보이지 않거나 다운로드에 실패하면 인터넷 연결, Drive 로그인 상태, 파일 접근 권한을 확인합니다.

Apple은 파일 앱의 Google Drive 위치 연결을 [공식 안내](https://support.apple.com/ko-kr/102238)에서 지원합니다. Google 계정 전환은 [Google Drive iPhone·iPad 안내](https://support.google.com/drive/answer/2424384?co=GENIE.Platform%3DiOS&hl=ko)를 따릅니다. 구현은 [`UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)`](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(foropeningcontenttypes:ascopy:))와 보안 범위를 유지한 `NSFileCoordinator` 읽기를 사용합니다.

## 검증

```sh
xcrun swiftc -parse-as-library -module-cache-path /private/tmp/NoteMarginImportModuleCache NoteMargin/Core/Models.swift NoteMargin/Core/LibraryRepository.swift NoteMargin/Services/PDFImportReader.swift scripts/project_import_checks.swift -o /private/tmp/note-margin-project-import-checks
/private/tmp/note-margin-project-import-checks
```

검사는 구버전 프로젝트 호환, 색상 저장·재로드·이동 보존, 가져온 바이트 독립성, 원본 보존, 읽기 실패와 취소를 확인합니다. 시스템 파일 조정 서비스에 접근할 수 있는 환경에서 실행해야 합니다. 실제 iPad의 Google Drive 로그인·클라우드 다운로드는 별도 기기 확인 대상입니다.
