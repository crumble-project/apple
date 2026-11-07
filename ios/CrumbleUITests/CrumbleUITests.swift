import XCTest

/// Launches without a server to verify that connection setup remains reachable on first launch.
final class CrumbleUITests: XCTestCase {
  @MainActor func testFirstLaunchAndSettings() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CRUMBLE_TOKEN"] = ""
    app.launchEnvironment["CRUMBLE_SKIP_KEYCHAIN"] = "1"
    app.launch()
    let settings = app.buttons["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["serverURL"].exists)
    XCTAssertTrue(app.textFields["email"].exists)
    XCTAssertTrue(app.secureTextFields["password"].exists)
    XCTAssertTrue(app.buttons["Sign In"].exists)
    let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
    settingsScreenshot.name = "Connection settings"
    settingsScreenshot.lifetime = .keepAlways
    add(settingsScreenshot)
    app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "First launch"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testWorkspaceNavigationAndForms() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CRUMBLE_TOKEN"] = "test-token"
    app.launchEnvironment["CRUMBLE_URL"] = "http://127.0.0.1:1"
    app.launchEnvironment["CRUMBLE_SKIP_KEYCHAIN"] = "1"
    app.launch()
    XCTAssertTrue(app.buttons["New Conversation"].waitForExistence(timeout: 10))
    app.buttons["New Conversation"].tap()
    app.buttons["New Bot"].tap()
    XCTAssertTrue(app.navigationBars["New Agent"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Create"].exists)
    app.buttons["Cancel"].tap()

    app.buttons["Settings"].tap()
    for title in ["Memory", "Skills", "Automations", "Activity", "Integrations"] {
      app.buttons[title].firstMatch.tap()
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
      let action: String? =
        switch title {
        case "Memory": "New Memory"
        case "Skills": "New Shared Skill"
        case "Integrations": "Add Shared MCP Server"
        default: nil
        }
      if let action {
        app.buttons[action].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].exists)
        app.buttons["Cancel"].tap()
      }
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = title
      screenshot.lifetime = .keepAlways
      add(screenshot)
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
  }
}
