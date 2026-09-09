import XCTest

final class CanvasLiveInkTests: XCTestCase {
    @MainActor func testInkStaysAtTouchWhileDrawingDeepInLongPDF() {
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
