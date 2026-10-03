import XCTest

/// Exercises production views. Explicit --guide-demo launches inject only public
/// UI demonstration data into an isolated store and reject device commands.
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
    func testEnglishProductionViewDemonstrations() throws {
        try verifyDemonstrations(language: "en", my: "My Library", coordinates: "Enter Coordinates", cancel: "Cancel")
    }

    @MainActor
    func testTraditionalChineseProductionViewDemonstrations() throws {
        try verifyDemonstrations(language: "zh-Hant", my: "我的", coordinates: "輸入座標", cancel: "取消")
    }

    @MainActor
    private func launch(language: String, scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--guide-demo=\(scenario)",
            "-RouteLocation.appLanguage", language,
            "-RouteLocation.appearance", "light",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "en" ? "en_US" : "zh_TW"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func verifyDemonstrations(language: String, my: String, coordinates: String, cancel: String) throws {
        for scenario in ["singlePoint", "editor", "player", "library"] {
            let app = launch(language: language, scenario: scenario)
            if scenario == "editor" {
                XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Taipei 101 Demo")).firstMatch.waitForExistence(timeout: 20))
            } else {
                XCTAssertTrue(app.staticTexts["guide.fixture.ready"].waitForExistence(timeout: 20))
            }
            if scenario == "library" {
                app.tabBars.buttons[my].tap()
                XCTAssertTrue(app.staticTexts["Taipei 101"].waitForExistence(timeout: 10))
            }
            capture(app, name: "readme-\(language)-\(scenario)-demo")
            if scenario == "singlePoint" {
                let entry = app.buttons[coordinates]
                XCTAssertTrue(entry.waitForExistence(timeout: 5))
                entry.tap()
                let field = app.textFields.element(boundBy: 0)
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                field.tap()
                field.typeText("25.033964, 121.564468")
                capture(app, name: "readme-\(language)-coordinate-input-demo")
                app.buttons[cancel].tap()
                XCTAssertTrue(app.staticTexts["guide.fixture.ready"].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    @MainActor
    private func verifyGuide(language: String, settings: String, guide: String) throws {
        let app = launch(language: language, scenario: "guide")
        let settingsTab = app.tabBars.buttons[settings]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()
        let guideLink = app.buttons["settings.userGuide"]
        XCTAssertTrue(guideLink.waitForExistence(timeout: 10))
        capture(app, name: "readme-\(language)-settings")
        guideLink.tap()
        XCTAssertTrue(app.navigationBars[guide].waitForExistence(timeout: 10))
        capture(app, name: "readme-\(language)-guide")

        let center = app.buttons["guide.tutorialCenter"]
        XCTAssertTrue(center.waitForExistence(timeout: 5))
        center.tap()
        let firstPoint = app.buttons["tutorial.start.firstPoint"]
        XCTAssertTrue(firstPoint.waitForExistence(timeout: 5))
        capture(app, name: "readme-\(language)-tutorial-center")
        firstPoint.tap()
        let skip = app.buttons["tutorial.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        capture(app, name: "readme-\(language)-spotlight")
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5))
        // Skip only removes coaching. No simulation/restore action is pressed.
        settingsTab.tap()
        // Settings retains its navigation stack when the tour switches tabs.
        if app.buttons["tutorial.start.firstPoint"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

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
