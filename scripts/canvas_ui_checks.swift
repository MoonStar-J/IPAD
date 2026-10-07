import XCTest
import UIKit

final class CanvasLiveInkTests: XCTestCase {
    @MainActor func testShapeSnapsBeforeLiftAndNextStrokeWorks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--live-ink", "--shape-held"]
        app.launch()
        XCTAssertTrue(app.buttons["top"].waitForExistence(timeout: 30))
        for location in ["top", "middle", "bottom"] {
            app.buttons[location].tap()
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.4))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.48))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
            XCTAssertEqual(app.staticTexts["shape-status"].label, "SNAPPED WHILE HELD")
            expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:'"), evaluatedWith: app.staticTexts["ink-status"])
            waitForExpectations(timeout: 5)
            let next = app.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.56))
            let nextEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.59))
            next.press(forDuration: 0.01, thenDragTo: nextEnd, withVelocity: .fast, thenHoldForDuration: 0.12)
            expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:'"), evaluatedWith: app.staticTexts["ink-status"])
            waitForExpectations(timeout: 5)
        }
    }

    @MainActor func testNativeDrawingSnapshotWhileContactHeld() {
        let app = XCUIApplication()
        app.launchArguments = ["--live-ink", "--native-held-probe"]
        app.launch()
        XCTAssertTrue(app.buttons["top"].waitForExistence(timeout: 30))
        app.buttons["top"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.4))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.48))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 2)
        expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:'"), evaluatedWith: app.staticTexts["ink-status"])
        waitForExpectations(timeout: 5)
    }

    @MainActor func testRapidShortStrokesAfterViewportMovement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--live-ink"]
        app.launch()
        XCTAssertTrue(app.buttons["top"].waitForExistence(timeout: 30))
        let status = app.staticTexts["ink-status"]
        for location in ["top", "middle", "bottom", "top"] {
            app.buttons[location].tap()
            for stroke in 0..<6 {
                let x = 0.28 + Double(stroke) * 0.065
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.46))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: x + 0.035, dy: 0.50))
                // Genuine short UIKit touch strokes, not synthetic PKDrawing insertion.
                // The brief hold lets the fixture sample viewport stability; it is
                // shorter than shape completion and does not measure Pencil latency.
                start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.12)
                expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:' OR label BEGINSWITH 'FAIL:'"), evaluatedWith: status)
                waitForExpectations(timeout: 5)
                XCTAssertTrue(status.label.hasPrefix("PASS:"), "\(location), stroke \(stroke): \(status.label)")
            }
        }
    }

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
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 4)
        expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:' OR label BEGINSWITH 'FAIL:'"), evaluatedWith: app.staticTexts["eraser-status"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["eraser-status"].label, "PASS: translucent preview until lift")
        XCTAssertEqual(inkPixels(app, channel: 0), 0, "all touched ink disappears on lift")
        XCTAssertEqual(app.staticTexts["eraser-current-tool"].label, "pencil · 2.5", "lift restores previous pencil and width")
        app.buttons["Undo"].tap()
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "one undo restores the full stroke")
        app.buttons["Redo"].tap()
        XCTAssertEqual(inkPixels(app, channel: 0), 0, "redo removes the stroke again")
        app.buttons["Undo"].tap()
        app.buttons["Cancel while held"].tap()
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 4)
        expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS:' OR label BEGINSWITH 'FAIL:'"), evaluatedWith: app.staticTexts["eraser-status"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["eraser-status"].label, "PASS: cancelled without deletion")
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "cancel restores the untouched original")
        XCTAssertTrue(app.staticTexts["eraser-current-tool"].label.hasPrefix("eraser"), "cancelled erase does not switch tools")
        app.buttons["부분 지우개"].tap()
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        expectation(for: NSPredicate(format: "label == 'pencil · 2.5'"), evaluatedWith: app.staticTexts["eraser-current-tool"])
        waitForExpectations(timeout: 5)
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
        let input = app.descendants(matching: .any)["ai-question-input"].firstMatch
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
            let preview = app.images["ai-region-preview"]
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


final class ChatGPTPlanVisualTests: XCTestCase {
    func testOfflinePreviewAndConnectionStatus() throws {
        let app = XCUIApplication(); app.launchArguments = ["--plan-ui"]; app.launch()
        XCTAssertTrue(app.staticTexts["여백 대화"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Offline PDF fixture"].exists)
        XCTAssertFalse(app.secureTextFields.element.exists)
        XCTAssertFalse(app.buttons["확인한 영역과 질문 보내기"].isEnabled)
        app.buttons["ChatGPT 구독 연결 확인"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["미연결"].exists)
    }
}

final class InkToolsVisualTests: XCTestCase {
    @MainActor private func rail(_ app: XCUIApplication, colors: Bool = false) -> XCUIElement {
        app.scrollViews[colors ? "ink-tools-color-rail" : "ink-tools-tool-rail"]
    }
    @MainActor private func reveal(_ item: XCUIElement, in rail: XCUIElement,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rail.waitForExistence(timeout: 5), file: file, line: line)
        let vertical = rail.frame.height > rail.frame.width
        var positions: [String] = []
        for attempt in 0..<12 {
            let frame = item.frame, viewport = rail.frame.insetBy(dx: 1, dy: 1)
            if item.isHittable && viewport.contains(frame.insetBy(dx: 1, dy: 1)) { return }
            let itemMiddle = vertical ? frame.midY : frame.midX
            let railMiddle = vertical ? viewport.midY : viewport.midX
            // A normal swipe crosses the entire ~200pt rail with inertia. That
            // jumped over middle tools in both directions. Use a short held drag
            // instead, ending at rest so each move advances at most one/two tools.
            let towardBeginning = frame.isEmpty ? attempt >= 6 : itemMiddle < railMiddle
            let extent = vertical ? viewport.height : viewport.width
            let distance = min(70, extent * 0.5)
            let half = distance / (vertical ? rail.frame.height : rail.frame.width) / 2
            let sign: CGFloat = towardBeginning ? 1 : -1
            let start = rail.coordinate(withNormalizedOffset: vertical
                ? CGVector(dx: 0.5, dy: 0.5 - sign * half)
                : CGVector(dx: 0.5 - sign * half, dy: 0.5))
            let end = rail.coordinate(withNormalizedOffset: vertical
                ? CGVector(dx: 0.5, dy: 0.5 + sign * half)
                : CGVector(dx: 0.5 + sign * half, dy: 0.5))
            positions.append("\(attempt): item=\(frame), rail=\(viewport)")
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("The palette rail must reveal \(item.identifier). \(positions.joined(separator: "; "))", file: file, line: line)
    }
    @MainActor private func dragHandle(_ app: XCUIApplication, x: Double, y: Double) {
        let handle = app.descendants(matching: .any).matching(identifier: "ink-tools-drag").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)),
                   withVelocity: .fast, thenHoldForDuration: 0.1)
    }
    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor func testFloatingEditorControlsAndReadableCaptureDestination() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The tools fixture provides one existing conversation, so confirmation
        // must offer a new conversation instead of silently reusing that one.
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-dark"]
        app.launch()
        let header = app.descendants(matching: .any).matching(identifier: "editor-floating-header").firstMatch
        let footer = app.descendants(matching: .any).matching(identifier: "editor-page-controls").firstMatch
        let canvas = app.descendants(matching: .any).matching(identifier: "notebook-canvas").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 40))
        XCTAssertTrue(footer.exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "editor-floating-header").count, 1,
                       "the header has its own container identity, not one repeated on every button")
        XCTAssertTrue(app.buttons["editor-library-back"].exists, "a container must preserve its child button identities")
        XCTAssertTrue(canvas.exists)
        let canvasFrame = canvas.frame
        let originalRed = inkPixels(app, channel: 0)
        XCTAssertGreaterThan(originalRed, 40)
        XCTAssertLessThan(footer.frame.width, app.frame.width * 0.6, "page controls do not form a full-width bottom bar")
        XCTAssertLessThan(footer.frame.height, 60)
        snapshot(app, "Floating-editor-controls-dark")

        app.buttons["ai-question-start"].tap()
        let confirm = app.buttons["ai-region-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: header)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: footer)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(canvas.frame, canvasFrame, "hiding controls does not reframe or resize the live canvas")
        XCTAssertFalse(app.buttons["library-import-pdf"].exists)
        XCTAssertFalse(app.buttons["새로운 노트"].exists)
        XCTAssertFalse(app.buttons["새 프로젝트"].exists)
        confirm.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "ai-capture-destination-picker").firstMatch
        let newConversation = app.buttons["ai-capture-new-conversation"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(newConversation.isHittable)
        XCTAssertEqual(newConversation.label, "새 문제")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ai-capture-existing-'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["library-import-pdf"].exists)
        // The dark picker uses opaque rows with neutral bright text, instead of
        // blue action text over a translucent gray system confirmation dialog.
        let rowImage = newConversation.screenshot().image.cgImage!
        var pixels = [UInt8](repeating: 0, count: rowImage.width * rowImage.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: rowImage.width, height: rowImage.height,
                                    bitsPerComponent: 8, bytesPerRow: rowImage.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(rowImage, in: CGRect(x: 0, y: 0, width: rowImage.width, height: rowImage.height))
        }
        var neutralTextPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 16) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if red > 190 && green > 190 && blue > 190 && abs(red - blue) < 18 {
                neutralTextPixels += 1
            }
        }
        XCTAssertGreaterThan(neutralTextPixels, 25, "the new-problem row has bright neutral foregrounds in dark mode")
        snapshot(app, "Readable-capture-destination-dark")
        newConversation.tap()
        let close = app.buttons["ai-chat-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(picker.exists)
        XCTAssertFalse(header.exists)
        XCTAssertFalse(footer.exists)
        XCTAssertEqual(canvas.frame, canvasFrame)
        close.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertEqual(canvas.frame, canvasFrame)
        XCTAssertEqual(inkPixels(app, channel: 0), originalRed, "capturing and closing leave handwriting at its original position")
        XCTAssertTrue(app.buttons["ai-margin-pin-1"].exists, "a new conversation gets its own pin")
        snapshot(app, "Floating-editor-restored-after-chat")

        // Repeat through the real Library fullScreenCover. A direct editor
        // fixture cannot catch a presenting home toolbar leaking over its child.
        app.terminate()
        app.launchArguments = ["--library-ui", "--library-reset", "--tools-dark"]
        app.launch()
        let homeImport = app.buttons["library-import-pdf"]
        XCTAssertTrue(homeImport.waitForExistence(timeout: 20))
        let noteCard = app.descendants(matching: .any).matching(identifier: "note-33333333-3333-3333-3333-333333333333").firstMatch
        XCTAssertTrue(noteCard.waitForExistence(timeout: 5)); noteCard.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        func assertHomeControlsHidden() {
            XCTAssertFalse(homeImport.isHittable, "home import must not overlap the open note")
            XCTAssertFalse(app.navigationBars.buttons["새로운 노트"].isHittable)
            XCTAssertFalse(app.navigationBars.buttons["새 프로젝트"].isHittable)
        }
        assertHomeControlsHidden()
        app.buttons["ai-question-start"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: header)
        waitForExpectations(timeout: 5)
        assertHomeControlsHidden()
        XCTAssertFalse(footer.exists)
        confirm.tap()
        if newConversation.waitForExistence(timeout: 2) { newConversation.tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        assertHomeControlsHidden()
        XCTAssertFalse(header.exists)
        snapshot(app, "Library-editor-AI-without-home-toolbar")
        close.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        assertHomeControlsHidden()
        app.buttons["editor-library-back"].tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: homeImport)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(header.exists)
        homeImport.tap()
        let driveImport = app.buttons["pdf-import-google-drive"]
        XCTAssertTrue(driveImport.waitForExistence(timeout: 5), "the restored home import opens its source chooser")
        XCTAssertTrue(app.buttons["pdf-import-files"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Google Drive를 선택하세요")).firstMatch.exists)
        snapshot(app, "PDF-import-Drive-instructions")
        app.buttons["닫기"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: driveImport)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(homeImport.isHittable)
        // No question is sent and no account/API access is required.
    }

    @MainActor func testSingleEraserRetapSettingsAndRememberedMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-dark", "--zoomed-eraser", "-fingerDrawing", "YES"]
        app.launch()
        let pen = app.buttons["ink-tool-pen"], eraser = app.buttons["ink-tool-eraser"]
        XCTAssertTrue(pen.waitForExistence(timeout: 40))
        dragHandle(app, x: 0.5, y: 0.95)
        reveal(pen, in: rail(app)); pen.tap()
        reveal(eraser, in: rail(app)); eraser.tap()
        let settings = app.descendants(matching: .any).matching(identifier: "ink-eraser-settings").firstMatch
        XCTAssertTrue(eraser.isSelected)
        XCTAssertFalse(settings.exists, "the first tap selects the eraser without opening a popup")
        XCTAssertEqual(app.buttons.matching(identifier: "ink-tool-eraser").count, 1)
        XCTAssertFalse(app.buttons["ink-tool-pixelEraser"].exists, "partial erasing is a mode of the one eraser")
        eraser.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "retapping the selected eraser opens its controls")
        let modes = app.segmentedControls["ink-eraser-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 3), "the popup preserves the segmented control's own identity")
        XCTAssertTrue(app.sliders["ink-eraser-width-slider"].exists)
        XCTAssertTrue(app.buttons["ink-eraser-settings-done"].exists)
        let partial = modes.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "ink-eraser-mode-partial", "부분")).firstMatch
        let stroke = modes.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "ink-eraser-mode-stroke", "획")).firstMatch
        partial.tap()
        XCTAssertTrue((eraser.value as? String ?? "").hasPrefix("부분 지우개"))
        let width = app.sliders["ink-eraser-width-slider"]
        XCTAssertTrue(width.exists)
        width.adjust(toNormalizedSliderPosition: 0)
        let narrow = eraser.value as? String
        width.adjust(toNormalizedSliderPosition: 1)
        XCTAssertNotEqual(eraser.value as? String, narrow, "the popup changes the actual eraser width")
        stroke.tap()
        XCTAssertTrue((eraser.value as? String ?? "").hasPrefix("획 지우개"))
        partial.tap()
        let remembered = eraser.value as? String
        snapshot(app, "Unified-eraser-settings-dark")
        app.buttons["ink-eraser-settings-done"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: settings)
        waitForExpectations(timeout: 3)
        reveal(pen, in: rail(app)); pen.tap()
        reveal(eraser, in: rail(app)); eraser.tap()
        XCTAssertTrue(eraser.isSelected)
        XCTAssertEqual(eraser.value as? String, remembered, "returning to eraser restores its last mode and width")
        XCTAssertFalse(settings.exists)
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "changing tool settings never erases existing handwriting")

        // Match the user's workflow: zoom the note, then use the remembered
        // partial eraser on that zoomed viewport.
        reveal(pen, in: rail(app)); pen.tap()

        let canvas = app.descendants(matching: .any).matching(identifier: "notebook-canvas").firstMatch
        XCTAssertTrue(canvas.exists)
        let zoom = app.buttons["editor-zoom"]
        XCTAssertTrue(zoom.exists)
        let zoomBeforeValue = zoom.value as? String ?? ""
        let zoomBefore = Int(zoomBeforeValue.filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(zoomBefore, 0, "the zoom control exposes the actual current percentage")
        let enlarge = app.buttons["fixture-zoom-2x"]
        XCTAssertTrue(enlarge.waitForExistence(timeout: 3))
        enlarge.tap()
        snapshot(app, "Partial-eraser-zoom-before-stroke")
        expectation(for: NSPredicate(format: "value != %@", zoomBeforeValue), evaluatedWith: zoom)
        waitForExpectations(timeout: 5)
        let zoomedValue = zoom.value as? String ?? ""
        let zoomedPercent = Int(zoomedValue.filter(\.isNumber)) ?? 0
        XCTAssertGreaterThanOrEqual(Double(zoomedPercent), Double(zoomBefore) * 1.5,
                                    "the canvas must actually be enlarged before testing partial erasing")
        reveal(eraser, in: rail(app)); eraser.tap()
        XCTAssertTrue(eraser.isSelected)
        let beforeErase = inkPixels(app, channel: 0)
        XCTAssertGreaterThan(beforeErase, 40)
        // Derive a crossing from the rendered red fixture after zoom, so this
        // gesture is independent of the device's size and the canvas fit scale.
        let image = app.screenshot().image.cgImage!
        let region = CGRect(x: Double(image.width) * 0.16, y: Double(image.height) * 0.28,
                            width: Double(image.width) * 0.68, height: Double(image.height) * 0.4).integral
        let crop = image.cropping(to: region)!
        var rgba = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var redCount = 0, redX: CGFloat = 0, redY: CGFloat = 0
        for pixel in stride(from: 0, to: rgba.count, by: 16) where rgba[pixel] > 150 && rgba[pixel + 1] < 130 && rgba[pixel + 2] < 110 {
            let offset = pixel / 4
            redX += CGFloat(offset % crop.width); redY += CGFloat(offset / crop.width); redCount += 1
        }
        XCTAssertGreaterThan(redCount, 40)
        let x = (region.minX + redX / CGFloat(redCount)) / CGFloat(image.width)
        let y = (region.minY + redY / CGFloat(redCount)) / CGFloat(image.height)
        let distance = 65 / app.frame.height
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y - distance))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y + distance))
        start.press(forDuration: 0.1, thenDragTo: finish, withVelocity: .slow, thenHoldForDuration: 0.15)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: pen)
        waitForExpectations(timeout: 5)
        let afterErase = inkPixels(app, channel: 0)
        XCTAssertLessThan(afterErase, beforeErase, "a partial eraser actually removes the crossed region while zoomed")
        XCTAssertGreaterThan(afterErase, 40, "partial erasing preserves the untouched portions of the same stroke")
        XCTAssertFalse(eraser.isSelected, "lifting the eraser restores the previous pen")
        XCTAssertEqual(zoom.value as? String, zoomedValue, "erasing and restoring the pen must keep the enlarged viewport")
        snapshot(app, "Partial-eraser-after-zoom-and-lift")
    }

    @MainActor func testSingleRowRailsScrollIndependently() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["ink-tool-pen"].waitForExistence(timeout: 40))
        dragHandle(app, x: 0.5, y: 0.95)
        let tools = rail(app), colors = rail(app, colors: true)
        let divider = app.descendants(matching: .any).matching(identifier: "ink-tools-drag").firstMatch
        XCTAssertEqual(tools.frame.midY, colors.frame.midY, accuracy: 1, "tools and colors occupy a single row")
        XCTAssertLessThanOrEqual(tools.frame.height, 44.5)
        XCTAssertLessThanOrEqual(colors.frame.height, 44.5)
        XCTAssertLessThan(tools.frame.maxX, divider.frame.midX)
        XCTAssertGreaterThan(colors.frame.minX, divider.frame.midX)
        let dividerBefore = divider.frame
        let firstColorBefore = app.buttons["ink-color-0"].frame
        tools.swipeLeft()
        XCTAssertEqual(divider.frame, dividerBefore, "the divider never scrolls with the tools")
        XCTAssertEqual(app.buttons["ink-color-0"].frame, firstColorBefore, "tool scrolling does not move colors")
        let selection = app.buttons["ink-tool-selection"]
        reveal(selection, in: tools)
        let selectionBefore = selection.frame
        colors.swipeLeft()
        XCTAssertLessThan(app.buttons["ink-color-0"].frame.minX, firstColorBefore.minX - 5, "colors have their own scroll range")
        XCTAssertEqual(selection.frame, selectionBefore, "color scrolling does not move the tool rail")
        XCTAssertEqual(divider.frame, dividerBefore)
        snapshot(app, "Single-row-independent-rails")
        // The same arrangement follows the long axis when docked on a side.
        dragHandle(app, x: 0.02, y: 0.5)
        XCTAssertEqual(tools.frame.midX, colors.frame.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(tools.frame.width, 44.5)
        XCTAssertLessThanOrEqual(colors.frame.width, 44.5)
        XCTAssertLessThan(tools.frame.maxY, divider.frame.midY)
        XCTAssertGreaterThan(colors.frame.minY, divider.frame.midY)
        let sideDivider = divider.frame
        let sideColor = app.buttons["ink-color-0"].frame
        tools.swipeUp()
        XCTAssertEqual(divider.frame, sideDivider)
        XCTAssertEqual(app.buttons["ink-color-0"].frame, sideColor)
        snapshot(app, "Single-column-independent-rails")
    }
    @MainActor func testUnifiedSelectionModeMenuAndLastMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-light"]
        app.launch()
        XCTAssertTrue(app.buttons["ink-tool-selection"].waitForExistence(timeout: 40))
        dragHandle(app, x: 0.5, y: 0.95)
        let tools = rail(app), selection = app.buttons["ink-tool-selection"]
        XCTAssertEqual(app.buttons.matching(identifier: "ink-tool-selection").count, 1)
        XCTAssertFalse(app.buttons["ink-tool-lasso"].exists, "freeform is a mode rather than another tool")
        XCTAssertFalse(app.buttons["ink-tool-rectangle"].exists, "box is a mode rather than another tool")
        reveal(selection, in: tools); selection.tap()
        XCTAssertTrue(selection.isSelected)
        XCTAssertEqual(selection.value as? String, "박스형")
        XCTAssertFalse(app.buttons["ink-width-settings"].exists, "selection modes do not expose pen width")
        let mode = app.buttons["ink-selection-mode"]
        reveal(mode, in: tools); mode.tap()
        let freeform = app.buttons["ink-selection-mode-freeform"]
        XCTAssertTrue(freeform.waitForExistence(timeout: 3))
        freeform.tap()
        XCTAssertEqual(selection.value as? String, "자유형")
        XCTAssertEqual(mode.value as? String, "자유형")
        XCTAssertEqual(app.staticTexts["ink-selection-status"].label, "필기를 자유형으로 둘러싸세요")
        XCTAssertTrue(app.buttons["ink-selection-menu"].exists, "both modes use the same editing actions")
        XCTAssertFalse(app.buttons["ink-width-settings"].exists)
        snapshot(app, "Unified-selection-freeform")

        let pen = app.buttons["ink-tool-pen"]
        reveal(pen, in: tools); pen.tap()
        XCTAssertFalse(app.buttons["ink-selection-mode"].exists)
        XCTAssertEqual(selection.value as? String, "자유형", "the shared icon remembers its last mode while using a pen")
        reveal(selection, in: tools); selection.tap()
        XCTAssertEqual(mode.value as? String, "자유형", "returning to selection restores the last mode")
        reveal(mode, in: tools); mode.tap()
        let box = app.buttons["ink-selection-mode-box"]
        XCTAssertTrue(box.waitForExistence(timeout: 3)); box.tap()
        XCTAssertEqual(selection.value as? String, "박스형")
        XCTAssertEqual(app.staticTexts["ink-selection-status"].label, "필기를 네모로 둘러싸세요")
        XCTAssertEqual(app.buttons.matching(identifier: "ink-tool-selection").count, 1)
        snapshot(app, "Unified-selection-box")
    }
    @MainActor func testFiveEditableColorsPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-light"]
        app.launch()
        XCTAssertTrue(app.buttons["ink-tool-pen"].waitForExistence(timeout: 40))
        dragHandle(app, x: 0.5, y: 0.95)
        let pen = app.buttons["ink-tool-pen"]
        reveal(pen, in: rail(app)); pen.tap()
        var saved: [String] = []
        for (index, name) in ["파랑", "빨강", "초록", "노랑", "검정"].enumerated() {
            let swatch = app.buttons["ink-color-\(index)"]
            reveal(swatch, in: rail(app, colors: true))
            let editor = app.staticTexts["펜 색상 \(index + 1) 변경"]
            if !swatch.isSelected {
                swatch.tap()
                XCTAssertTrue(swatch.isSelected)
                XCTAssertFalse(editor.exists, "first tap only selects a different color")
            }
            swatch.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 3), "one tap on selected color opens its editor")
            app.buttons[name + " 잉크"].tap()
            app.buttons["완료"].tap()
            saved.append(swatch.value as? String ?? "")
            XCTAssertEqual(saved.last?.count, 6)
        }
        snapshot(app, "Five-custom-colors")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["ink-color-0"].waitForExistence(timeout: 40))
        for index in 0..<5 {
            let swatch = app.buttons["ink-color-\(index)"]
            reveal(swatch, in: rail(app, colors: true))
            XCTAssertEqual(swatch.value as? String, saved[index], "each customized slot survives app restart")
        }
    }
    @MainActor func testFineWidthAndQuietSaving() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-light"]
        app.launch()
        XCTAssertTrue(app.buttons["ink-tool-pen"].waitForExistence(timeout: 40))
        dragHandle(app, x: 0.5, y: 0.95)
        let pen = app.buttons["ink-tool-pen"]
        reveal(pen, in: rail(app)); pen.tap()
        let width = app.buttons["ink-width-settings"]
        reveal(width, in: rail(app)); width.tap()
        let slider = app.sliders["ink-width-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(app.staticTexts["0.1"].waitForExistence(timeout: 3), "minimum ink width is 0.1 points")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        XCTAssertFalse(app.staticTexts["저장됨"].exists)
        XCTAssertFalse(app.staticTexts["저장 중…"].exists)
        app.buttons["더 보기"].tap()
        XCTAssertTrue(app.buttons["note-save-now"].waitForExistence(timeout: 3), "manual save stays available without a per-stroke banner")
        app.buttons["note-save-now"].tap()
        XCTAssertFalse(app.staticTexts["저장됨"].exists)
    }
    @MainActor func testAutomaticSelectionActionsInBothModesAndCollapsedPalette() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--page-swap", "--tools-ui", "--tools-light"]
        app.launch()
        XCTAssertTrue(app.buttons["ink-tool-selection"].waitForExistence(timeout: 40))
        dragHandle(app, x: 0.5, y: 0.95)
        let selection = app.buttons["ink-tool-selection"]
        reveal(selection, in: rail(app)); selection.tap()
        XCTAssertEqual(selection.value as? String, "박스형")
        let bar = app.descendants(matching: .any).matching(identifier: "ink-selection-actions").firstMatch
        XCTAssertFalse(bar.exists, "there are no actions before any handwriting is selected")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.68))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)

        func assertActions() {
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "selecting ink automatically reveals the actions without opening an edit menu")
            for id in ["duplicate", "cut", "copy", "paste", "group", "delete", "save"] {
                XCTAssertTrue(app.buttons["ink-selection-action-" + id].exists, "selection action is visible: " + id)
            }
            XCTAssertTrue(app.buttons["ink-selection-action-copy"].isHittable)
            XCTAssertTrue(app.buttons["ink-selection-action-save"].isHittable)
        }
        func dismissByOutsideTap() {
            // This is outside the actual fixture selection and away from the
            // bottom-centered palette. It tests the canvas tap recognizer.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.80)).tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)
            waitForExpectations(timeout: 5)
            XCTAssertFalse(app.buttons["ink-selection-action-copy"].exists)
        }
        assertActions()
        app.buttons["ink-selection-action-copy"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["ink-selection-action-paste"])
        waitForExpectations(timeout: 3)
        let collapse = app.buttons["ink-tools-collapse"]
        reveal(collapse, in: rail(app)); collapse.tap()
        XCTAssertTrue(app.buttons["ink-tools-expand"].waitForExistence(timeout: 3))
        assertActions()
        snapshot(app, "Automatic-box-actions-collapsed-palette")
        dismissByOutsideTap()
        XCTAssertTrue(app.buttons["ink-tools-expand"].exists, "deselection does not reopen the palette")

        app.buttons["ink-tools-expand"].tap()
        let mode = app.buttons["ink-selection-mode"]
        reveal(mode, in: rail(app)); mode.tap()
        let freeform = app.buttons["ink-selection-mode-freeform"]
        XCTAssertTrue(freeform.waitForExistence(timeout: 3)); freeform.tap()
        XCTAssertEqual(selection.value as? String, "자유형")
        // The public XCTest drag API cannot synthesize an arbitrary multi-segment
        // lasso. Freeform geometry is exercised by integration checks; here the
        // real Paste action creates an editable selection while freeform is active.
        let edit = app.buttons["ink-selection-menu"]
        reveal(edit, in: rail(app)); edit.tap()
        let paste = app.buttons["붙여넣기"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3)); XCTAssertTrue(paste.isEnabled); paste.tap()
        assertActions()
        XCTAssertEqual(selection.value as? String, "자유형")
        reveal(collapse, in: rail(app)); collapse.tap()
        assertActions()
        snapshot(app, "Automatic-freeform-actions-collapsed-palette")
        dismissByOutsideTap()
        XCTAssertGreaterThan(inkPixels(app, channel: 0), 40, "outside deselection leaves the original and pasted ink intact")
    }
    @MainActor func testRectangleAndPictogramsInBothAppearances() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for mode in ["light", "dark"] {
            app.launchArguments = ["--page-swap", "--tools-ui", "--tools-" + mode]
            app.launch()
            XCTAssertTrue(app.buttons["ink-tool-pen"].waitForExistence(timeout: 40))
            let handle = app.descendants(matching: .any).matching(identifier: "ink-tools-drag").firstMatch
            dragHandle(app, x: 0.5, y: 0.06)
            XCTAssertLessThan(handle.frame.minY, app.frame.minY + 150)
            XCTAssertEqual(rail(app).frame.midY, rail(app, colors: true).frame.midY, accuracy: 1)
            snapshot(app, "Palette-docked-top-" + mode)
            dragHandle(app, x: 0.02, y: 0.5)
            XCTAssertLessThan(handle.frame.minX, app.frame.minX + 35)
            XCTAssertEqual(rail(app).frame.midX, rail(app, colors: true).frame.midX, accuracy: 1)
            snapshot(app, "Palette-docked-left-" + mode)
            dragHandle(app, x: 0.98, y: 0.5)
            XCTAssertGreaterThan(handle.frame.minX, app.frame.maxX - 80)
            snapshot(app, "Palette-docked-right-" + mode)
            dragHandle(app, x: 0.5, y: 0.95)
            let collapse = app.buttons["ink-tools-collapse"]
            reveal(collapse, in: rail(app)); collapse.tap()
            XCTAssertTrue(app.buttons["ink-tools-expand"].waitForExistence(timeout: 5))
            snapshot(app, "Circular-pictogram-" + mode)
            app.buttons["ink-tools-expand"].tap()
            let selection = app.buttons["ink-tool-selection"]
            reveal(selection, in: rail(app)); selection.tap()
            XCTAssertEqual(selection.value as? String, "박스형", "the shared selection tool starts in box mode")
            let status = app.staticTexts["ink-selection-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.12))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.68))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            expectation(for: NSPredicate(format: "label BEGINSWITH '1획 선택'"), evaluatedWith: status)
            waitForExpectations(timeout: 6)
            snapshot(app, "Rectangle-selected-" + mode)
            let inkBeforeResize = inkPixels(app, channel: 0)
            let corner = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.12))
            let smaller = app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.28))
            corner.press(forDuration: 0.1, thenDragTo: smaller, withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertTrue(status.label.hasPrefix("1획 선택"))
            let reducedInk = inkPixels(app, channel: 0)
            XCTAssertGreaterThan(reducedInk, 40, "resizing preserves the selected handwriting")
            XCTAssertLessThan(Double(reducedInk), Double(inkBeforeResize) * 0.85, "dragging a selected corner scales the ink itself down")
            snapshot(app, "Rectangle-ink-scaled-down-" + mode)
            let larger = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.17))
            smaller.press(forDuration: 0.1, thenDragTo: larger, withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertGreaterThan(Double(inkPixels(app, channel: 0)), Double(reducedInk) * 1.10, "the same corner can enlarge the selected ink")
            snapshot(app, "Rectangle-ink-scaled-up-" + mode)
            let menu = app.buttons["ink-selection-menu"]
            reveal(menu, in: rail(app)); menu.tap()
            app.buttons["복제"].tap()
            XCTAssertTrue(status.label.hasPrefix("1획 선택"))
            menu.tap(); app.buttons["삭제"].tap()
            XCTAssertEqual(status.label, "필기를 네모로 둘러싸세요")
            let pen = app.buttons["ink-tool-pen"]
            reveal(pen, in: rail(app)); pen.tap()
            app.buttons["이 노트의 문제별 AI 대화 목록"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '새 질문'")).firstMatch.waitForExistence(timeout: 2) || app.popovers.firstMatch.exists)
            snapshot(app, "Opaque-chat-history-" + mode)
            app.terminate()
        }
    }
}


final class ProjectLibraryTests: XCTestCase {
    @MainActor func testLongPressDragHierarchyAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui", "--library-reset", "--tools-dark"]
        app.launch()
        let math = app.buttons["project-11111111-1111-1111-1111-111111111111"]
        let physics = app.buttons["project-22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(math.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["생각이 머무는 곳."].exists)
        math.press(forDuration: 1)
        XCTAssertTrue(app.buttons["프로젝트 설정"].waitForExistence(timeout: 3))
        app.buttons["프로젝트 설정"].tap()
        XCTAssertTrue(app.textFields["프로젝트 이름"].waitForExistence(timeout: 3))
        app.buttons["취소"].tap()
        math.press(forDuration: 0.8, thenDragTo: physics)
        physics.tap()
        XCTAssertTrue(math.waitForExistence(timeout: 5), "project must move inside another project")
        app.buttons["library-home"].tap()
        let noteCard = app.descendants(matching: .any)["note-33333333-3333-3333-3333-333333333333"].firstMatch
        XCTAssertTrue(noteCard.exists)
        noteCard.press(forDuration: 0.8, thenDragTo: physics)
        physics.tap()
        XCTAssertTrue(noteCard.waitForExistence(timeout: 5))
        noteCard.press(forDuration: 1)
        XCTAssertTrue(app.buttons["이름 및 표지 변경"].waitForExistence(timeout: 3))
        app.buttons["이동"].tap()
        XCTAssertTrue(app.buttons["물리 / 수학"].waitForExistence(timeout: 3))
        app.buttons["물리 / 수학"].tap()
        math.tap()
        XCTAssertTrue(noteCard.waitForExistence(timeout: 5))
        noteCard.press(forDuration: 0.8, thenDragTo: app.buttons["library-home"])
        XCTAssertFalse(noteCard.exists, "dragging to home must move note out")
        app.buttons["library-home"].tap()
        XCTAssertTrue(noteCard.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Project-home-dark"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        app.launchArguments = ["--library-ui", "--tools-light"]
        app.launch()
        XCTAssertTrue(physics.waitForExistence(timeout: 15))
        XCTAssertTrue(noteCard.exists)
        XCTAssertFalse(math.exists)
        physics.tap()
        XCTAssertTrue(math.waitForExistence(timeout: 5))
        app.navigationBars.buttons["새 프로젝트"].tap()
        let name = app.textFields["프로젝트 이름"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Vectors")
        app.buttons["저장"].tap()
        let created = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Vectors'")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 5), "new project must be created in current directory")
        let nested = XCTAttachment(screenshot: app.screenshot()); nested.name = "Nested-project-light"; nested.lifetime = .keepAlways; add(nested)
    }
}


final class ProjectSidebarTests: XCTestCase {
    @MainActor func testSidebarTreeDragToRootAndCreationLocation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui", "--library-tree", "--library-reset", "--tools-light"]
        app.launch()
        let math = app.buttons["sidebar-project-11111111-1111-1111-1111-111111111111"]
        let physics = app.buttons["sidebar-project-22222222-2222-2222-2222-222222222222"]
        let child = app.buttons["sidebar-project-44444444-4444-4444-4444-444444444444"]
        let leaf = app.buttons["sidebar-project-55555555-5555-5555-5555-555555555555"]
        XCTAssertTrue(leaf.waitForExistence(timeout: 20))
        func snapshot(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        snapshot("Sidebar-expanded-tree")
        app.buttons["project-toggle-11111111-1111-1111-1111-111111111111"].tap()
        XCTAssertFalse(child.exists); XCTAssertFalse(leaf.exists)
        app.buttons["project-toggle-11111111-1111-1111-1111-111111111111"].tap()
        XCTAssertTrue(leaf.exists)
        child.press(forDuration: 1, thenDragTo: physics, withVelocity: .slow, thenHoldForDuration: 0.6)
        physics.tap()
        XCTAssertTrue(app.buttons["project-44444444-4444-4444-4444-444444444444"].waitForExistence(timeout: 5))
        child.press(forDuration: 1, thenDragTo: app.buttons["project-root-drop"], withVelocity: .slow, thenHoldForDuration: 0.6)
        app.buttons["project-root-drop"].tap()
        XCTAssertTrue(app.buttons["project-44444444-4444-4444-4444-444444444444"].waitForExistence(timeout: 5), "sidebar drag must promote a project to root")
        child.tap()
        XCTAssertTrue(app.buttons["project-55555555-5555-5555-5555-555555555555"].exists, "nested contents must travel with the project")
        physics.tap()
        app.buttons["sidebar-new-project"].tap()
        let title = app.textFields["프로젝트 이름"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("RootDirect")
        app.buttons["저장"].tap()
        app.buttons["project-root-drop"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'project-' AND label BEGINSWITH 'RootDirect'")).firstMatch.waitForExistence(timeout: 5))
        physics.tap()
        app.navigationBars.buttons["새 프로젝트"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("RootChosen")
        app.buttons["project-parent-picker"].tap()
        let choices = app.buttons.matching(NSPredicate(format: "label == %@", "최상위 (홈)"))
        expectation(for: NSPredicate { _, _ in choices.allElementsBoundByIndex.contains { $0.isHittable } }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        choices.allElementsBoundByIndex.first { $0.isHittable }!.tap()
        XCTAssertTrue(app.buttons["저장"].waitForExistence(timeout: 5)); app.buttons["저장"].tap()
        app.buttons["project-root-drop"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'project-' AND label BEGINSWITH 'RootChosen'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("Sidebar-root-projects")
        app.terminate()
        app.launchArguments = ["--library-ui", "--tools-dark"]
        app.launch()
        XCTAssertTrue(child.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["project-44444444-4444-4444-4444-444444444444"].exists)
        XCTAssertTrue(leaf.exists)
        snapshot("Sidebar-restored-dark")
        XCTAssertTrue(math.exists)
    }
}


final class ShapeDirectEditVisualTests: XCTestCase {
    @MainActor func testSelectedShapeUsesRealTouchDragResizeAndOutsideTap() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--live-ink","--shape-edit"];app.launch()
        XCTAssertTrue(app.buttons["seed-shape"].waitForExistence(timeout:30))
        app.buttons["top"].tap();app.buttons["seed-shape"].tap()
        func data() throws -> [String:Any] {
            app.buttons["inspect-shape"].tap()
            return try JSONSerialization.jsonObject(with:Data(app.staticTexts["shape-edit-data"].label.utf8)) as! [String:Any]
        }
        func coordinate(_ p:[Double])->XCUICoordinate {
            app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:p[0],dy:p[1]))
        }
        let before=try data(),center=before["center"] as! [Double]
        XCTAssertEqual(before["ready"] as? Bool,true)
        let delta=[64.0,41.0],end=[center[0]+delta[0],center[1]+delta[1]]
        coordinate(center).press(forDuration:0.05,thenDragTo:coordinate(end),withVelocity:.slow,thenHoldForDuration:0.2)
        let moved=try data(),movedCenter=moved["center"] as! [Double]
        XCTAssertEqual(moved["count"] as? Int,1,"object drag cannot also create handwriting")
        XCTAssertEqual(moved["preview"] as? Bool,false,"native render handoff completes")
        XCTAssertEqual(movedCenter[0],end[0],accuracy:2);XCTAssertEqual(movedCenter[1],end[1],accuracy:2)
        XCTAssertEqual(moved["width"] as! Double,before["width"] as! Double,accuracy:0.01)
        let corners=moved["corners"] as! [[Double]],a=corners[0],h=corners[2]
        let grab=[h[0]+3,h[1]-4],target=[a[0]+(h[0]-a[0])*1.4+3,a[1]+(h[1]-a[1])*1.4-4]
        coordinate(grab).press(forDuration:0.05,thenDragTo:coordinate(target),withVelocity:.slow,thenHoldForDuration:0.2)
        let resized=try data()
        XCTAssertEqual(resized["count"] as? Int,1)
        XCTAssertEqual(resized["preview"] as? Bool,false)
        XCTAssertEqual((resized["width"] as! Double)/(moved["width"] as! Double),1.4,accuracy:0.03)
        XCTAssertEqual((resized["height"] as! Double)/(moved["height"] as! Double),1.4,accuracy:0.03)
        let fixed=(resized["corners"] as! [[Double]])[0]
        XCTAssertEqual(fixed[0],a[0],accuracy:2);XCTAssertEqual(fixed[1],a[1],accuracy:2)
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="Direct-shape-uniform-resize";attachment.lifetime = .keepAlways;add(attachment)
        app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.82)).tap()
        let deselected=try data()
        XCTAssertEqual(deselected["ready"] as? Bool,false)
        XCTAssertEqual(deselected["count"] as? Int,1,"outside tap only deselects")
        let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.7)),finish=app.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.72))
        start.press(forDuration:0.01,thenDragTo:finish,withVelocity:.fast,thenHoldForDuration:0.12)
        XCTAssertEqual(try data()["count"] as? Int,2,"next contact writes normally")
    }
}
