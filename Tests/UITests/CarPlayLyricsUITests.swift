import XCTest

/// End-to-end checks of the iPhone app in demo mode (no Spotify account needed).
final class CarPlayLyricsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-resetState", "-demo"]
    }

    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDemoShowsSyncedLyricsThatAdvance() {
        app.launch()
        XCTAssertTrue(app.staticTexts["trackTitle"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["trackTitle"].label, "Open Road (Demo)")

        let current = app.descendants(matching: .any).matching(identifier: "currentLine").firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        let first = current.label
        screenshot("Demo lyrics")

        // Lines change every 4-5 seconds in the demo song.
        let changed = NSPredicate(format: "label != %@", first)
        expectation(for: changed, evaluatedWith: app.descendants(matching: .any).matching(identifier: "currentLine").firstMatch)
        waitForExpectations(timeout: 12)
        XCTAssertTrue(app.staticTexts["Demo lyrics"].exists)
    }

    func testTimingButtonsAdjustThisSong() {
        app.launch()
        let value = app.descendants(matching: .any).matching(identifier: "offsetValue").firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        func spoken() -> String { (value.value as? String) ?? "" }
        XCTAssertEqual(spoken(), "no adjustment")
        app.buttons["offsetEarlier"].tap()
        XCTAssertEqual(spoken(), "0.25 seconds earlier")
        app.buttons["offsetLater"].tap()
        app.buttons["offsetLater"].tap()
        XCTAssertEqual(spoken(), "0.25 seconds later")
        app.buttons["offsetReset"].tap()
        XCTAssertEqual(spoken(), "no adjustment")
    }

    func testDemoPauseStopsTheLyrics() {
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "currentLine").firstMatch.waitForExistence(timeout: 10))
        app.buttons["demoPlayPause"].tap()
        sleep(2)
        let paused = app.descendants(matching: .any).matching(identifier: "currentLine").firstMatch.label
        sleep(6)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "currentLine").firstMatch.label, paused)
        XCTAssertEqual(app.buttons["demoPlayPause"].label, "Play demo")
    }

    func testSettingsAboutAndLegalScreens() {
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        screenshot("Settings")

        app.swipeUp()
        app.buttons["Privacy Policy"].tap()
        XCTAssertTrue(app.staticTexts["Privacy Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "lrclib.net")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Terms of Use"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Don't read lyrics while driving")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["aboutLink"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "LRCLIB")).firstMatch.waitForExistence(timeout: 5))
        screenshot("About")
    }

    func testDeleteMyDataAsksFirstAndConfirms() {
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        app.swipeUp()
        app.swipeUp()
        app.buttons["deleteDataButton"].tap()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let confirm = dialog.buttons["Delete my data"]
        XCTAssertTrue(confirm.exists)
        XCTAssertTrue(dialog.buttons["Cancel"].exists, "a plain way out")
        confirm.tap()
        XCTAssertTrue(app.alerts["Your data was deleted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.buttons["Open Spotify account settings"].exists)
        app.alerts.buttons["OK"].tap()
    }

    func testFirstLaunchWithoutSpotifyOffersTheDemo() {
        app.launchArguments = ["-uiTesting", "-resetState"]
        app.launch()
        // CI builds have no Spotify Client ID, so the app explains setup; a configured build shows sign-in.
        let demoButton = app.buttons["tryDemoButton"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 10))
        screenshot("First launch")
        if app.buttons["signInButton"].exists {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Read only")).firstMatch.exists)
        }
        demoButton.tap()
        XCTAssertTrue(app.staticTexts["trackTitle"].waitForExistence(timeout: 10))
    }

    func testLargestAccessibilityTextSizeKeepsControlsReachable() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["offsetEarlier"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["offsetEarlier"].isHittable)
        XCTAssertTrue(app.buttons["offsetReset"].exists)
        screenshot("Accessibility XXXL")
    }
}
