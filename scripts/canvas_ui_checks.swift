import XCTest
import UIKit

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
