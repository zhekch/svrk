import XCTest

final class LifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testControlCenterDismissalLeavesAppInteractive() throws {
        let app = XCUIApplication()
        app.launch()

        let search = app.buttons["Search for a stop or a service"]
        XCTAssertTrue(search.waitForExistence(timeout: 60), "App never reached its interactive map UI")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let topRight = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.01))
        let controlCenter = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        let upper = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let controlCenterRoot = springboard.otherElements["cc-root-folder-view"]

        for round in 1...3 {
            topRight.press(forDuration: 0.1, thenDragTo: controlCenter)
            XCTAssertTrue(
                controlCenterRoot.waitForExistence(timeout: 5),
                "Control Center did not open in round \(round)"
            )

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Control Center visible, round \(round)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            bottom.press(forDuration: 0.1, thenDragTo: upper)

            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()

            let field = app.textFields["Station, or IC8, or 726"]
            XCTAssertTrue(
                field.waitForExistence(timeout: 5),
                "The app did not respond after Control Center round \(round)"
            )

            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
        }
    }
}
