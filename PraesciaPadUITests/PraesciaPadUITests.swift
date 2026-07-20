import XCTest

final class PraesciaPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeExplainsSafetyAndOffersFileImport() {
        let app = launch()

        XCTAssertTrue(app.buttons["welcome-open-scan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["safety-notice"].exists)
        XCTAssertTrue(app.staticTexts["RESEARCH PROTOTYPE · NOT FOR DIAGNOSIS"].exists)
    }

    @MainActor
    func testCorruptScanShowsRecoverableError() {
        let app = launch(mode: "error")

        XCTAssertTrue(app.staticTexts["scan-error-message"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["scan-error-message"].label, "The selected UI test fixture is corrupt.")
        XCTAssertTrue(app.buttons["scan-error-retry"].isEnabled)
    }

    @MainActor
    func testLoadedScanShowsFactsAndUpdatesRegionVisibilityAndDescription() {
        let app = launch(mode: "loaded")

        XCTAssertTrue(app.otherElements["anatomy-view"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["9 × 9 × 9"].exists)
        XCTAssertTrue(app.staticTexts["12 × 12 × 12 mm"].exists)
        XCTAssertTrue(app.staticTexts["16-bit signed integer"].exists)

        let region = app.buttons["region-select-3"]
        XCTAssertTrue(region.waitForExistence(timeout: 5))
        scrollToHittable(region, in: app)
        region.tap()
        let description = app.staticTexts["region-description"]
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        XCTAssertTrue(description.label.localizedCaseInsensitiveContains("higher-intensity band"))
        XCTAssertTrue(app.staticTexts["description-source"].exists)

        let visibility = app.buttons["region-visibility-3"]
        XCTAssertEqual(visibility.value as? String, "Visible")
        visibility.tap()
        XCTAssertEqual(visibility.value as? String, "Hidden")
    }

    @MainActor
    func testMeasurementCanBeUndoneAndCleared() {
        let app = launch(mode: "measurement")
        let measure = app.buttons["measure-toggle"]
        XCTAssertTrue(measure.waitForExistence(timeout: 15))
        measure.tap()

        let value = app.staticTexts["measurement-value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "5.0 mm")

        let undo = app.buttons["measurement-undo"]
        let clear = app.buttons["measurement-clear"]
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(clear.isEnabled)
        undo.tap()
        XCTAssertEqual(value.label, "Tap point 2 of 2")
        clear.tap()
        XCTAssertEqual(value.label, "Tap point 1 of 2")
        XCTAssertFalse(undo.isEnabled)
        XCTAssertFalse(clear.isEnabled)
    }

    @MainActor
    private func launch(mode: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let mode { app.launchEnvironment["PRAESCIA_UI_TEST_MODE"] = mode }
        app.launch()
        return app
    }

    @MainActor
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) {
        guard !element.isHittable else { return }
        app.scrollViews.firstMatch.swipeUp()
    }
}
