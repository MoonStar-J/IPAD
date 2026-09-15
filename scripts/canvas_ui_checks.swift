import XCTest
import UIKit

final class AIConnectionVisualTests: XCTestCase {
    @MainActor private func launchFixture() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ai-connection"]
        app.launch()
        XCTAssertTrue(app.buttons["open-connection-fixture"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["connection-fixture-status"].label, "PASS: no API key saved")
        app.buttons["open-connection-fixture"].tap()
        XCTAssertTrue(app.secureTextFields["ai-api-key"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func enterFakeKey(_ app: XCUIApplication, value: String = "fixture-key-not-valid") {
        let field = app.secureTextFields["ai-api-key"]
        field.tap()
        field.typeText(value)
    }

    @MainActor private func finishAndExpect(_ app: XCUIApplication, status: String) {
        // This is the exact path reported by the user: type a key, then tap
        // the top-right Done action without tapping the separate Save row.
        let done = app.buttons["complete-ai-connection"]
        done.tap()
        expectDismissed(app, status: status)
    }

    @MainActor private func expectDismissed(_ app: XCUIApplication, status: String) {
        let done = app.buttons["complete-ai-connection"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "label == %@", status), evaluatedWith: app.staticTexts["connection-fixture-status"])
        waitForExpectations(timeout: 5)
    }

    @MainActor private func cleanup(_ app: XCUIApplication) {
        app.buttons["cleanup-connection-fixture"].tap()
        XCTAssertEqual(app.staticTexts["connection-fixture-status"].label, "PASS: no API key saved")
    }

    @MainActor func testDoneSavesKeyAndReopeningDoesNotExposeIt() {
        let app = launchFixture()
        enterFakeKey(app)
        finishAndExpect(app, status: "PASS: OpenAI / gpt-5-mini")
        app.buttons["open-connection-fixture"].tap()
        // LabeledContent combines its label and value for accessibility.
        let storedStatus = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "API 키 저장됨")).firstMatch
        XCTAssertTrue(storedStatus.waitForExistence(timeout: 5))
        let field = app.secureTextFields["ai-api-key"]
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue, "Reopening must leave the credential field empty")
        app.buttons["cancel-ai-connection"].tap()
        XCTAssertTrue(app.buttons["cleanup-connection-fixture"].waitForExistence(timeout: 5))
        cleanup(app)
    }

    @MainActor func testKeyboardDoneSavesKey() {
        let app = launchFixture()
        enterFakeKey(app)
        // A newline from typeText invokes the focused SecureField's keyboard
        // action, covering submit independently of the navigation bar button.
        app.secureTextFields["ai-api-key"].typeText("\n")
        expectDismissed(app, status: "PASS: OpenAI / gpt-5-mini")
        cleanup(app)
    }

    @MainActor func testInvalidKeyShowsErrorAndKeepsSettingsOpen() {
        let app = launchFixture()
        enterFakeKey(app, value: "bad key")
        app.buttons["complete-ai-connection"].tap()
        let alert = app.alerts["연결 설정을 저장하지 못했습니다"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["API 키에 공백이나 줄바꿈이 포함되어 있습니다. 키를 다시 확인해 주세요."].exists)
        alert.buttons["확인"].tap()
        XCTAssertTrue(app.buttons["complete-ai-connection"].exists, "A failed save must retain the settings sheet")
        XCTAssertTrue(app.secureTextFields["ai-api-key"].exists)
        app.buttons["cancel-ai-connection"].tap()
        XCTAssertTrue(app.buttons["cleanup-connection-fixture"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["connection-fixture-status"].label, "PASS: no API key saved")
        cleanup(app)
    }

    @MainActor func testCancelDoesNotSaveTheEnteredKey() {
        let app = launchFixture()
        enterFakeKey(app)
        app.buttons["cancel-ai-connection"].tap()
        XCTAssertTrue(app.buttons["cleanup-connection-fixture"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["connection-fixture-status"].label, "PASS: no API key saved")
        cleanup(app)
    }

    @MainActor func testDoneSavesChangedModelWithoutReplacingExistingKey() {
        let app = launchFixture()
        enterFakeKey(app)
        finishAndExpect(app, status: "PASS: OpenAI / gpt-5-mini")
        app.buttons["open-connection-fixture"].tap()
        let model = app.textFields["ai-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        // Tap beyond the short model name to place the caret at its end.
        model.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        model.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        model.typeText("gpt-5.2")
        finishAndExpect(app, status: "PASS: OpenAI / gpt-5.2")
        cleanup(app)
    }

    @MainActor func testDoneSavesSelectedProviderAndItsModel() {
        let app = launchFixture()
        app.buttons["ai-provider"].tap()
        let gemini = app.buttons["Gemini"].firstMatch
        XCTAssertTrue(gemini.waitForExistence(timeout: 5))
        gemini.tap()
        XCTAssertEqual(app.textFields["ai-model"].value as? String, "gemini-2.5-flash")
        enterFakeKey(app)
        finishAndExpect(app, status: "PASS: Gemini / gemini-2.5-flash")
        cleanup(app)
    }
}

final class CanvasLiveInkTests: XCTestCase {
    @MainActor func testInkStaysAtTouchWhileDrawingDeepInLongPDF() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--live-ink"]
        app.launch()
        XCTAssertTrue(app.buttons["top"].waitForExistence(timeout: 30))
        let status = app.staticTexts["ink-status"]
        for location in ["top", "middle", "bottom"] {
            app.buttons[location].tap()
            for stroke in 0..<2 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.4 + Double(stroke) * 0.12))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.48 + Double(stroke) * 0.12))
                start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
                let passed = NSPredicate(format: "label BEGINSWITH 'PASS:'")
                expectation(for: passed, evaluatedWith: status)
                waitForExpectations(timeout: 5)
                XCTAssertTrue(status.label.hasPrefix("PASS:"), "\(location): \(status.label)")
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Long-PDF-\(location)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

@MainActor private func inkPixels(_ app: XCUIApplication, channel: Int) -> Int {
    let image = app.screenshot().image.cgImage!
    let crop = image.cropping(to: CGRect(x: Double(image.width) * 0.16, y: Double(image.height) * 0.28,
                                        width: Double(image.width) * 0.68, height: Double(image.height) * 0.4))!
    let width = crop.width, height = crop.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: pixels.count, by: 16).filter {
        pixels[$0 + channel] > 150 && pixels[$0 + (channel == 0 ? 2 : 0)] < 110 && pixels[$0 + 1] < 130
    }.count
}

final class PageSwapVisualTests: XCTestCase {
    @MainActor func testBlankPageNeverShowsPreviousInkBeforeAnyNewStroke() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap"]
        app.launch()
        XCTAssertTrue(app.buttons["페이지"].waitForExistence(timeout: 30))
        func select(_ number: Int) {
            app.buttons["페이지"].tap()
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT (label CONTAINS '페이지 중')", "\(number)페이지")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.buttons["3페이지 중 \(number)페이지, 페이지 관리"].waitForExistence(timeout: 5))
        }
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "red ink fixture must be visible")
        for _ in 0..<2 {
            select(2)
            XCTAssertEqual(inkPixels(app, channel: 0), 0, "blank page must not inherit red ink")
            XCTAssertEqual(inkPixels(app, channel: 2), 0, "blank page must not inherit blue ink")
            select(3)
            XCTAssertGreaterThan(inkPixels(app, channel: 2), 40, "saved blue ink must appear without drawing")
            XCTAssertEqual(inkPixels(app, channel: 0), 0, "red ink must not follow to blue page")
            select(2)
            XCTAssertEqual(inkPixels(app, channel: 2), 0, "blue ink must disappear on blank page")
            select(1)
            XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "red ink must return on its own page")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Page-swap-round-trip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class StrokeEraserVisualTests: XCTestCase {
    @MainActor func testStrokePreviewUntilLift() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--eraser"]
        app.launch()
        XCTAssertTrue(app.staticTexts["eraser-status"].waitForExistence(timeout: 30))
        app.pinch(withScale: 1.3, velocity: 1)
        app.buttons["Fit"].tap()
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "two-finger zoom with eraser must preserve ink")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
        expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:' OR label BEGINSWITH 'FAIL:'"), evaluatedWith: app.staticTexts["eraser-status"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["eraser-status"].label, "PASS: translucent preview until lift")
        XCTAssertEqual(inkPixels(app, channel: 0), 0, "all touched ink disappears on lift")
        app.buttons["Undo"].tap()
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "one undo restores the full stroke")
        app.buttons["Redo"].tap()
        XCTAssertEqual(inkPixels(app, channel: 0), 0, "redo removes the stroke again")
        app.buttons["Undo"].tap()
        app.buttons["Cancel while held"].tap()
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
        expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:' OR label BEGINSWITH 'FAIL:'"), evaluatedWith: app.staticTexts["eraser-status"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["eraser-status"].label, "PASS: cancelled without deletion")
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "cancel restores the untouched original")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Eraser-after-lift"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class MarginChatVisualTests: XCTestCase {
    @MainActor func testDraftSurvivesClosingItsMarginChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap"]
        app.launch()
        XCTAssertTrue(app.buttons["ai-question-start"].waitForExistence(timeout: 30))
        app.buttons["ai-question-start"].tap()
        let confirm = app.buttons["ai-region-confirm"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        confirm.tap()
        let input = app.textFields["ai-question-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Draft stays here")
        app.buttons["ai-chat-close"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        app.buttons["ai-margin-pin-0"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Draft stays here")
        // This flow deliberately never taps Send and requires no API key.
    }

    @MainActor func testQuestionRegionPreviewAndPageScopedPinRoundTrip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // This existing fixture opens the real editor with red ink on page 1,
        // a blank page 2 and blue ink on page 3. No API request is sent.
        app.launchArguments = ["--page-swap"]
        app.launch()
        let question = app.buttons["ai-question-start"]
        let confirm = app.buttons["ai-region-confirm"]
        let close = app.buttons["ai-chat-close"]
        let pin = app.buttons["ai-margin-pin-0"]
        XCTAssertTrue(question.waitForExistence(timeout: 30))
        XCTAssertFalse(pin.exists, "new note must not inherit another note's AI pins")
        let originalRed = inkPixels(app, channel: 0)
        XCTAssertGreaterThan(originalRed, 40, "red handwritten source is visible before selection")

        question.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        // Move the initial selection by dragging its interior. This exercises
        // the real overlay gesture without sending the gesture to PencilKit.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.48))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        confirm.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "confirming the rectangle opens its margin chat")
        XCTAssertFalse(confirm.exists, "confirming ends rectangle selection")
        XCTAssertTrue(app.descendants(matching: .any)["ai-question-input"].firstMatch.exists, "chat is ready for the user's question")

        func openPreviewAndCheckInk() {
            let disclosure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "선택 영역 보기")).firstMatch
            XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
            disclosure.tap()
            let preview = app.images["질문에 첨부될 PDF와 필기 영역"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5), "chat reveals the captured source image")
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: preview)
            waitForExpectations(timeout: 5)
            let image = preview.screenshot().image.cgImage!
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let red = stride(from: 0, to: pixels.count, by: 16).filter {
                pixels[$0] > 150 && pixels[$0 + 1] < 130 && pixels[$0 + 2] < 110
            }.count
            XCTAssertGreaterThan(red, 20, "the captured source preview includes the selected handwritten ink")
        }
        func waitForChatToClose() {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: close)
            waitForExpectations(timeout: 5)
        }
        openPreviewAndCheckInk()
        let sourceAttachment = XCTAttachment(screenshot: app.screenshot())
        sourceAttachment.name = "Margin-chat-source-preview"
        sourceAttachment.lifetime = .keepAlways
        add(sourceAttachment)

        close.tap()
        waitForChatToClose()
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "closing the chat leaves its circular margin pin")
        XCTAssertEqual(inkPixels(app, channel: 0), originalRed, "selection and chat must preserve the original ink presentation")
        pin.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "a pin opens its saved conversation")
        pin.tap()
        waitForChatToClose()
        XCTAssertTrue(pin.exists, "tapping an open pin collapses the chat without deleting it")

        // The system PencilKit palette may float over the footer. Use the
        // always-accessible page manager, as the existing page-swap test does.
        func selectPage(_ number: Int) {
            app.buttons["페이지"].tap()
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT (label CONTAINS '페이지 중')", "\(number)페이지")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
        }
        selectPage(2)
        XCTAssertTrue(app.buttons["3페이지 중 2페이지, 페이지 관리"].waitForExistence(timeout: 5))
        XCTAssertFalse(pin.exists, "a conversation pin must stay on its own page")
        XCTAssertFalse(close.exists)
        XCTAssertEqual(inkPixels(app, channel: 0), 0, "page change after AI interaction must not carry old ink")
        selectPage(1)
        XCTAssertTrue(app.buttons["3페이지 중 1페이지, 페이지 관리"].waitForExistence(timeout: 5))
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "returning to the source page restores its pin")
        pin.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        openPreviewAndCheckInk()
        close.tap()
        waitForChatToClose()
        XCTAssertEqual(inkPixels(app, channel: 0), originalRed, "returning from a page restores all source ink unchanged")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Margin-pin-page-round-trip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}


#if PERSONAL_CHATGPT
final class PersonalChatGPTVisualTests: XCTestCase {
    func testRegionTransferAndWebConversationSurviveHidingPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--personal-web"]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Offline ChatGPT browser fixture"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.secureTextFields.element.exists)
        if !app.textFields["personal-question"].exists && !app.textViews["personal-question"].exists {
            app.buttons["personal-region"].tap()
        }
        let question = app.textFields["personal-question"]
        // The multiline SwiftUI field may be exposed as a text view.
        let editor = question.exists ? question : app.textViews["personal-question"]
        editor.tap(); editor.typeText("Explain this")
        app.buttons["personal-copy-prompt"].tap()
        app.buttons["Check copied prompt"].tap()
        XCTAssertTrue(app.staticTexts["PASS: selected prompt copied"].exists)
        app.buttons["personal-copy-image"].tap()
        app.buttons["Check copied image"].tap()
        XCTAssertTrue(app.staticTexts["PASS: region image copied"].exists)
        app.buttons["personal-region"].tap()
        app.webViews.buttons["Open fixture conversation"].tap()
        XCTAssertTrue(app.staticTexts["https://chatgpt.com/c/offline-fixture"].waitForExistence(timeout: 5))
        app.buttons["ai-chat-close"].tap()
        app.buttons["Reopen personal chat"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Fixture conversation opened"].waitForExistence(timeout: 5))
        if !app.textFields["personal-question"].exists && !app.textViews["personal-question"].exists {
            app.buttons["personal-region"].tap()
        }
        XCTAssertEqual((app.textFields["personal-question"].exists ? app.textFields["personal-question"] : app.textViews["personal-question"]).value as? String, "Explain this")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
}

#endif
