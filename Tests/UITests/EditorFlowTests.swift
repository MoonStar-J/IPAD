import XCTest

final class EditorFlowTests: XCTestCase {
    @MainActor func testFirstShapeDragAndCornerResize() throws { try checkShapeEditing(infinite: false) }
    @MainActor func testInfiniteShapeDragAndCornerResize() throws { try checkShapeEditing(infinite: true) }
    @MainActor private func checkShapeEditing(infinite: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launchArguments = ["-fingerDrawing", infinite ? "NO" : "YES", "--editing-diagnostics", "-app.appearance", "dark"]
        if infinite { app.launchArguments.append("--infinite-editing-fixture") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Editing fixture"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["Editing fixture"].firstMatch.tap()
        let canvas = app.scrollViews["notebook-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), app.debugDescription)
        func frame() throws -> CGRect {
            let numbers = (canvas.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(numbers.count, 7, canvas.debugDescription)
            XCTAssertEqual(numbers[4], 1, "drag/resize must not add a native tail stroke")
            XCTAssertEqual(numbers[6], 0, "native rendering must take over the edit preview")
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        func coordinate(_ p: CGPoint) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
        }
        let initial = try frame()
        coordinate(CGPoint(x: initial.midX, y: initial.midY)).press(forDuration: 0.05,
            thenDragTo: coordinate(CGPoint(x: initial.midX + 85, y: initial.midY + 45)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let moved = try frame()
        XCTAssertEqual(moved.midX - initial.midX, 85, accuracy: 8, canvas.value as? String ?? "")
        XCTAssertEqual(moved.midY - initial.midY, 45, accuracy: 8)
        let corner = CGPoint(x: moved.maxX, y: moved.maxY)
        coordinate(corner).press(forDuration: 0.05,
            thenDragTo: coordinate(CGPoint(x: corner.x + moved.width * 0.25, y: corner.y + moved.height * 0.25)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let resized = try frame()
        XCTAssertGreaterThan(resized.width, moved.width * 1.18)
        XCTAssertEqual(resized.minX, moved.minX, accuracy: 3)
        XCTAssertEqual(resized.minY, moved.minY, accuracy: 3)
        XCTAssertEqual(resized.width / resized.height, moved.width / moved.height, accuracy: 0.01)
        coordinate(CGPoint(x: resized.maxX + 55, y: resized.maxY + 55)).tap()
        XCTAssertFalse(app.buttons["ink-selection-action-copy"].exists)
        try XCTUnwrap(app.buttons.matching(identifier: "실행 취소").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertEqual(try frame().width, moved.width, accuracy: 4)
        try XCTUnwrap(app.buttons.matching(identifier: "다시 실행").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertEqual(try frame().width, resized.width, accuracy: 4)
        app.buttons["ink-tool-selection"].tap()
        app.buttons["ink-selection-mode"].tap(); app.buttons["ink-selection-mode-box"].tap()
        coordinate(CGPoint(x: resized.minX - 16, y: resized.minY - 16)).press(forDuration: 0.05,
            thenDragTo: coordinate(CGPoint(x: resized.maxX + 16, y: resized.maxY + 16)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["ink-selection-action-copy"].waitForExistence(timeout: 5))
        XCTAssertEqual(try frame().width, resized.width, accuracy: 4)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Shape-direct-edit-dark"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["editor-library-back"].tap()
        app.terminate(); app.launch()
        app.staticTexts["Editing fixture"].firstMatch.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(try frame().width, resized.width, accuracy: 3)
        if !infinite {
            app.buttons["ink-tool-eraser"].tap()
            let rect = try frame()
            coordinate(CGPoint(x: rect.midX, y: rect.minY - 10)).press(forDuration: 0.05,
                thenDragTo: coordinate(CGPoint(x: rect.midX, y: rect.minY + 10)), withVelocity: .slow, thenHoldForDuration: 0.1)
            func count() -> Int { Int((canvas.value as? String ?? "").split(separator: ",")[4]) ?? -1 }
            XCTAssertEqual(count(), 0)
            try XCTUnwrap(app.buttons.matching(identifier: "실행 취소").allElementsBoundByIndex.first(where: \.isHittable)).tap(); XCTAssertEqual(count(), 1)
            try XCTUnwrap(app.buttons.matching(identifier: "다시 실행").allElementsBoundByIndex.first(where: \.isHittable)).tap(); XCTAssertEqual(count(), 0)
            try XCTUnwrap(app.buttons.matching(identifier: "실행 취소").allElementsBoundByIndex.first(where: \.isHittable)).tap(); XCTAssertEqual(count(), 1)
        }
    }
    @MainActor func testTrashAllIgnoresSearchAndCanCancel() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launchArguments = ["-app.appearance", "light", "--trashed-editing-fixture"]
        app.launch()
        let trash = app.buttons.matching(NSPredicate(format: "label CONTAINS '최근 삭제된 항목'")).firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 15)); trash.tap()
        let empty = app.buttons["trash-empty-all"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5)); XCTAssertTrue(empty.isEnabled)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("no matching note")
        empty.tap()
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS '1개'")).firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["취소"].tap()
        XCTAssertTrue(empty.isEnabled)
        empty.tap(); app.alerts.buttons["모두 영구 삭제"].tap()
        XCTAssertFalse(empty.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Trash-empty"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDriveConnectionEntryOffersGoogleSignIn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["library-import-pdf"].waitForExistence(timeout: 15)); app.buttons["library-import-pdf"].tap()
        XCTAssertTrue(app.buttons["pdf-import-google-drive"].waitForExistence(timeout: 5)); app.buttons["pdf-import-google-drive"].tap()
        XCTAssertTrue(app.buttons["Google에 로그인"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["다른 Google 계정 연결"].exists)
        XCTAssertFalse(app.staticTexts["앱 설정 필요"].exists)
        app.buttons["완료"].tap()
        XCTAssertTrue(app.buttons["pdf-import-files"].isHittable)
    }
    @MainActor func testSelectedPDFAndSummaryPromptControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Editing fixture,'")).firstMatch.tap()
        app.buttons["editor-summary"].tap(); app.buttons["summary-next"].tap()
        let prompt = app.textFields["summary-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
        prompt.tap(); prompt.typeText("이번 요청 지침")
        if app.buttons["키보드 가리기"].exists { app.buttons["키보드 가리기"].tap() }
        app.buttons["닫기"].tap(); app.buttons["editor-summary"].tap()
        XCTAssertEqual(app.textFields["summary-prompt"].value as? String, "이번 요청 지침")
        app.buttons["기본 요약 프롬프트 설정"].tap()
        XCTAssertTrue(app.textViews["default-summary-prompt"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["닫기"].tap()
        app.buttons["공유"].tap(); app.buttons["선택한 페이지를 PDF로 내보내기"].tap()
        let export = app.buttons["내보내기"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertFalse(export.isEnabled)
        app.buttons["전체 선택"].tap(); XCTAssertTrue(export.isEnabled)
        app.buttons["선택 해제"].tap(); XCTAssertFalse(export.isEnabled)
        app.buttons["1페이지, 선택 안 됨"].tap(); export.tap()
        XCTAssertTrue(app.cells["파일에 저장"].waitForExistence(timeout: 10), app.debugDescription)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "Selected-PDF-share"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testQuestionPresetSelectionPreservesDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Editing fixture,'")).firstMatch.tap()
        app.buttons["ai-question-start"].tap(); app.buttons["ai-region-confirm"].tap()
        let question = app.textFields["ai-question-input"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), app.debugDescription)
        question.tap(); question.typeText("보존할 직접 질문")
        app.buttons["ai-preset-picker"].tap(); app.buttons["힌트만"].tap()
        XCTAssertEqual(question.value as? String, "보존할 직접 질문")
        // Management opens from this panel without a new account request.
        app.buttons["더 보기"].tap(); app.buttons["AI 질문 프리셋"].tap()
        XCTAssertTrue(app.navigationBars["AI 질문 프리셋"].waitForExistence(timeout: 5))
        app.buttons["프리셋 추가"].tap()
        app.buttons.matching(identifier: "새 프리셋").allElementsBoundByIndex.last!.tap()
        let presetName = "UI preset " + UUID().uuidString.prefix(8)
        let name = app.textFields["preset-name"]
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + presetName)
        let defaultQuestion = app.textViews["preset-question"]
        defaultQuestion.tap(); defaultQuestion.typeText("UI default question")
        let instructions = app.textViews["preset-instructions"]
        instructions.tap(); instructions.typeText("UI answer style")
        if app.buttons["키보드 가리기"].exists { app.buttons["키보드 가리기"].tap() }
        app.navigationBars["프리셋 편집"].buttons["AI 질문 프리셋"].tap()
        XCTAssertTrue(app.buttons[presetName].exists)
        app.buttons["완료"].tap()
        app.buttons["ai-preset-picker"].tap(); app.buttons[presetName].tap()
        XCTAssertEqual(question.value as? String, "보존할 직접 질문")
        app.buttons["ai-chat-close"].tap(); app.buttons["editor-library-back"].tap()
        app.terminate(); app.launch()
        app.buttons["설정"].tap(); app.buttons["AI 질문 프리셋"].tap()
        XCTAssertTrue(app.buttons[presetName].waitForExistence(timeout: 5))
        app.buttons[presetName].tap()
        XCTAssertEqual(app.textViews["preset-question"].value as? String, "UI default question")
        XCTAssertEqual(app.textViews["preset-instructions"].value as? String, "UI answer style")
        app.navigationBars["프리셋 편집"].buttons["AI 질문 프리셋"].tap()
        app.buttons[presetName].swipeLeft(); app.buttons["삭제"].tap()
        XCTAssertFalse(app.buttons[presetName].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "Question-preset-settings"; attachment.lifetime = .keepAlways; add(attachment)

    }

    @MainActor func testSummaryDraftSurvivesConnectionAndRegionSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Editing fixture,'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["editor-summary"].waitForExistence(timeout: 10))
        app.buttons["editor-summary"].tap()
        app.buttons["summary-next"].tap()
        let name = app.textFields["summary-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(" 요약 초안")
        if app.buttons["키보드 가리기"].exists { app.buttons["키보드 가리기"].tap() }
        for _ in 0..<3 {
            if app.buttons["연결·계정 설정"].isHittable { break }
            app.descendants(matching: .any)["summary-form"].swipeUp()
        }
        app.buttons["연결·계정 설정"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        app.buttons["완료"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Editing fixture 요약 초안")
        if !app.buttons["범위 다시 선택"].isHittable { app.swipeUp() }
        app.buttons["범위 다시 선택"].tap()
        app.buttons["선택한 부분 요약하기"].tap()
        XCTAssertFalse(app.buttons["summary-next"].isEnabled)
        app.buttons["1페이지, 선택 안 됨"].tap()
        XCTAssertTrue(app.buttons["summary-next"].isEnabled)
        app.buttons["닫기"].tap()
        XCTAssertTrue(app.buttons["editor-summary"].waitForExistence(timeout: 5))
    }
    @MainActor func testInfiniteSummaryUsesExistingRectangleSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launchArguments = ["--infinite-editing-fixture"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Editing fixture,'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["editor-summary"].waitForExistence(timeout: 10)); app.buttons["editor-summary"].tap()
        app.buttons["선택한 부분 요약하기"].tap()
        XCTAssertFalse(app.buttons["summary-next"].isEnabled)
        app.buttons["사각형 영역 선택"].tap()
        let confirm = app.buttons["ai-region-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertEqual(confirm.label, "이 영역 요약")
        XCTAssertTrue(confirm.isEnabled); confirm.tap()
        XCTAssertTrue(app.buttons["summary-next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["summary-next"].isEnabled); app.buttons["summary-next"].tap()
        XCTAssertTrue(app.textFields["summary-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "선택한 사각형 영역")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["닫기"].tap()
    }
    @MainActor func testSummaryReaderMathThemesCopyAndReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        for theme in ["light", "dark"] {
            app.launchArguments = ["--summary-reader-fixture", "-app.appearance", theme]
            app.launch()
            let card = app.buttons["Summary rendering fixture, 요약"]
            XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["학습 요약"].firstMatch.waitForExistence(timeout: 10))
            app.buttons["원문 복사"].tap()
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Summary-" + theme; attachment.lifetime = .keepAlways; add(attachment)
            app.buttons["editor-library-back"].tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    // Explicit opt-in only: this uses the device's connected account and consumes usage.
    @MainActor func testConnectedAccountSummaryEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["NOTEMARGIN_LIVE_SUMMARY"] == "1" else {
            throw XCTSkip("Enable NOTEMARGIN_LIVE_SUMMARY for a single real-account summary.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        app.launchArguments = ["--live-summary-fixture"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Editing fixture,'")).firstMatch.tap()
        app.buttons["editor-summary"].tap()
        app.buttons["summary-next"].tap()
        let create = app.buttons["summary-create"]
        if !create.isHittable { app.swipeUp() }
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let ready = NSPredicate { _, _ in create.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30), .completed, "Connect an image-capable ChatGPT account/model on the iPad before running this test.")
        create.tap()
        let finished = NSPredicate { _, _ in app.staticTexts["완료"].exists || app.staticTexts["미완료 · 실패"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 180), .completed)
        XCTAssertTrue(app.staticTexts["완료"].exists, app.debugDescription)
        app.buttons["summary-open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "미분")).firstMatch.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Live-summary-saved"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "모든 노트")).firstMatch.tap()
        let card = app.buttons["Editing fixture, 요약"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "미분")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["이 요약에서 다시 시도"].exists)
    }
    @MainActor func makeNote(_ app: XCUIApplication, infinite: Bool = false, finger: Bool = true, appearance: String = "light") -> String {
        app.launchArguments = ["-fingerDrawing", finger ? "YES" : "NO", "--pencil-test-touch", "--shape-diagnostics", "-app.appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["library-create-note"].waitForExistence(timeout:20),app.debugDescription)
        app.buttons["library-create-note"].tap()
        let title="Regression-"+UUID().uuidString.prefix(8)
        let field=app.textFields["create-note-title"]
        XCTAssertTrue(field.waitForExistence(timeout:5));field.tap();field.typeText(String(title))
        if infinite { app.buttons["무한 캔버스"].tap() }
        app.buttons["create-note-confirm"].tap()
        XCTAssertTrue(app.buttons["editor-library-back"].waitForExistence(timeout:8),app.debugDescription)
        return String(title)
    }
    @MainActor func testRealAppLineHoldNextStrokeAndReopen() {
        checkLineHold(appearance: "light")
    }
    @MainActor func testDarkLineHoldNextStrokeAndReopen() {
        checkLineHold(appearance: "dark")
    }
    @MainActor private func checkLineHold(appearance: String) {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment["NOTEMARGIN_UI_FIXTURE"] = UUID().uuidString
        let title=makeNote(app, appearance: appearance)
        let canvas=app.scrollViews["notebook-canvas"].firstMatch
        let surface=canvas.exists ? canvas : app.otherElements["notebook-canvas"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout:5),app.debugDescription)
        let start=surface.coordinate(withNormalizedOffset:CGVector(dx:0.30,dy:0.36))
        let end=surface.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.42))
        start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:1.0)
        let next=surface.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.55))
        next.press(forDuration:0.01,thenDragTo:surface.coordinate(withNormalizedOffset:CGVector(dx:0.50,dy:0.6)),withVelocity:.fast,thenHoldForDuration:0.05)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Actual-app-line-and-next-stroke-" + appearance;screenshot.lifetime = .keepAlways;add(screenshot)
        XCTAssertGreaterThan(darkPixels(app),100,"white paper must retain visible native ink after snap")
        app.buttons["editor-library-back"].tap()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout:5));app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor-library-back"].waitForExistence(timeout:5))
        XCTAssertGreaterThan(darkPixels(app),100)
    }
    @MainActor func testPaletteDragLeavesHeaderAndPageControlsFixed() {
        continueAfterFailure=false
        let app=XCUIApplication();_=makeNote(app)
        let back=app.buttons["editor-library-back"].frame
        let zoom=app.buttons["editor-zoom"].frame
        let grip=app.otherElements["ink-tools-drag"].firstMatch
        XCTAssertTrue(grip.waitForExistence(timeout:5),app.debugDescription)
        for p in [CGVector(dx:0.5,dy:0.06),CGVector(dx:0.04,dy:0.55),CGVector(dx:0.55,dy:0.94)] {
            grip.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.2,thenDragTo:app.coordinate(withNormalizedOffset:p),withVelocity:.slow,thenHoldForDuration:0.1)
            XCTAssertEqual(app.buttons["editor-library-back"].frame,back)
            XCTAssertEqual(app.buttons["editor-zoom"].frame,zoom)
            XCTAssertTrue(app.buttons["editor-library-back"].isHittable)
        }
    }
    @MainActor func testFirstFileSelectionStaysInImportFlow() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--pdf-import-fixture"];app.launch()
        for (index, mode) in ["paged", "continuous"].enumerated() {
            XCTAssertTrue(app.buttons["library-import-pdf"].waitForExistence(timeout:15))
            app.buttons["library-import-pdf"].tap()
            let files = app.buttons["pdf-import-files"]
            XCTAssertTrue(files.waitForExistence(timeout:5)); files.tap()
            if index == 1 {
                let cancel = app.buttons["취소"].firstMatch
                XCTAssertTrue(cancel.waitForExistence(timeout:5)); cancel.tap()
                XCTAssertTrue(files.waitForExistence(timeout:5)); files.tap()
            }
            // A local PDF fixture, opened through the real system picker.
            let file=app.cells.matching(NSPredicate(format:"identifier == %@","Import Regression, pdf")).firstMatch
            XCTAssertTrue(file.waitForExistence(timeout:15),app.debugDescription)
            file.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.25)).tap()
            let layout=app.buttons["pdf-layout-" + mode]
            XCTAssertTrue(layout.waitForExistence(timeout:15),app.debugDescription);layout.tap()
            XCTAssertTrue(app.buttons["editor-library-back"].waitForExistence(timeout:15),app.debugDescription)
            app.buttons["editor-library-back"].tap()
        }
    }
    @MainActor func testInfiniteCanvasAcrossScreensAndReopen() {
        continueAfterFailure=false
        let app=XCUIApplication();let title=makeNote(app,infinite:true,finger:false)
        XCTAssertTrue(app.staticTexts["무한 캔버스"].firstMatch.exists)
        let surface=app.scrollViews["notebook-canvas"].firstMatch
        XCTAssertTrue(surface.exists)
        for _ in 0..<4 { surface.swipeDown(velocity:.slow);surface.swipeRight(velocity:.slow) }
        app.buttons["editor-library-back"].tap();app.terminate()
        app.launchArguments=["-fingerDrawing","YES","--pencil-test-touch","--shape-diagnostics","-app.appearance","dark"]
        app.launch();let note=app.staticTexts[title].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout:10));note.tap()
        XCTAssertTrue(app.buttons["editor-library-back"].waitForExistence(timeout:10))
        let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.4))
        start.press(forDuration:0.01,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.46)),withVelocity:.slow,thenHoldForDuration:0.8)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Infinite-negative-viewport-dark-ui";screenshot.lifetime = .keepAlways;add(screenshot)
        XCTAssertGreaterThan(darkPixels(app),100)
        let undo=app.buttons["실행 취소"].firstMatch, redo=app.buttons["다시 실행"].firstMatch
        let canUndo=expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:undo)
        wait(for:[canUndo],timeout:5)
        undo.tap();XCTAssertGreaterThan(darkPixels(app),100,"shape Undo restores the original freehand")
        undo.tap();XCTAssertLessThan(darkPixels(app),100,"the next Undo removes the original stroke")
        redo.tap();redo.tap();XCTAssertGreaterThan(darkPixels(app),100)
        app.buttons["editor-library-back"].tap();app.terminate();app.launch()
        XCTAssertTrue(note.waitForExistence(timeout:10));note.tap()
        XCTAssertTrue(app.buttons["editor-library-back"].waitForExistence(timeout:10))
        XCTAssertGreaterThan(darkPixels(app),100)
    }
    @MainActor func testAppearancePersistsAndCanFollowSystem() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=[];app.launch()
        for mode in ["다크","라이트","시스템"] {
            XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout:10));app.buttons["설정"].tap()
            let picker=app.buttons.matching(NSPredicate(format:"label BEGINSWITH '화면 모드'")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout:5),app.debugDescription);picker.tap()
            app.buttons[mode].tap()
            XCTAssertTrue(picker.label.contains(mode),picker.label)
            let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Appearance-"+mode;screenshot.lifetime = .keepAlways;add(screenshot)
            app.buttons["완료"].tap();app.terminate();app.launch()
            XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout:10));app.buttons["설정"].tap()
            XCTAssertTrue(picker.waitForExistence(timeout:5));XCTAssertTrue(picker.label.contains(mode),picker.label)
            app.buttons["완료"].tap()
        }
    }
    @MainActor private func darkPixels(_ app: XCUIApplication) -> Int {
        let image=app.screenshot().image.cgImage!
        let rect=CGRect(x:Double(image.width)*0.26,y:Double(image.height)*0.27,width:Double(image.width)*0.46,height:Double(image.height)*0.38)
        let crop=image.cropping(to:rect)!,width=crop.width,height=crop.height
        var pixels=[UInt8](repeating:0,count:width*height*4)
        let context=CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop,in:CGRect(x:0,y:0,width:width,height:height))
        return stride(from:0,to:pixels.count,by:4).filter { pixels[$0]<90 && pixels[$0+1]<90 && pixels[$0+2]<90 }.count
    }
}
