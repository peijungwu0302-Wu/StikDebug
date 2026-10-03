import XCTest

/// Exercises the shipped UI. No pairing credentials or simulated device session
/// are installed; attachments show the real simulator app in its idle state.
final class RouteLocationGuideUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishGuideNavigationAndScreenshots() throws {
        try verifyGuide(language: "en", settings: "Settings", guide: "User Guide")
    }

    @MainActor
    func testTraditionalChineseGuideNavigationAndScreenshots() throws {
        try verifyGuide(language: "zh-Hant", settings: "設定", guide: "使用指南")
    }

    @MainActor
    private func verifyGuide(language: String, settings: String, guide: String) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-RouteLocation.appLanguage", language,
            "-RouteLocation.appearance", "light",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "en" ? "en_US" : "zh_TW"
        ]
        app.launch()
        let settingsTab = app.tabBars.buttons[settings]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()
        let guideLink = app.buttons["settings.userGuide"]
        XCTAssertTrue(guideLink.waitForExistence(timeout: 10))
        capture(app, name: "readme-\(language)-settings")
        guideLink.tap()
        XCTAssertTrue(app.navigationBars[guide].waitForExistence(timeout: 10))
        capture(app, name: "readme-\(language)-guide")

        // A broken destination or a lost back path fails this real navigation
        // check. Content has no connection/session actions to invoke.
        for topic in ["setup", "singlePoint", "coordinates", "routes", "library", "recovery", "health"] {
            let link = app.buttons["guide.topic.\(topic)"]
            for _ in 0..<6 where !link.isHittable { app.swipeUp() }
            XCTAssertTrue(link.waitForExistence(timeout: 5), "Missing guide topic: \(topic)")
            link.tap()
            let detail = app.scrollViews["guide.detail.\(topic)"]
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            if topic == "setup" || topic == "routes" {
                capture(app, name: "readme-\(language)-\(topic)")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars[guide].waitForExistence(timeout: 5))
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(guideLink.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
