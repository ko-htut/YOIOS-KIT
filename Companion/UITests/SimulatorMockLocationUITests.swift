import Foundation
import XCTest

final class SimulatorMockLocationUITests: XCTestCase {
    private let app = XCUIApplication()
    private let bundleIdentifier = "local.minthanhtut.YIOSKitCompanion"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func configuration() throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["YIOS_SIMULATOR_BRIDGE_CONFIG"],
                                  "Start the simulator test bridge with the test script.")
        XCTAssertFalse(value.isEmpty)
        return value
    }

    private func launch(configuration: String) {
        app.launchEnvironment["YIOS_SIMULATOR_BRIDGE_CONFIG"] = configuration
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let tab = app.tabBars.buttons["Mock Location"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let set = app.buttons["simulatorMockSetButton"]
        if !set.waitForExistence(timeout: 8) {
            print("Mock Location accessibility diagnostic: " + app.debugDescription)
            XCTFail("The Mock Location controls did not appear after opening the tab.")
        }
    }

    private func scrollTo(_ element: XCUIElement) {
        if element.exists && element.isHittable { return }
        for _ in 0..<4 {
            app.swipeDown()
            if element.exists && element.isHittable { return }
        }
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "The requested simulator control is accessible.")
    }

    private func replace(_ identifier: String, with text: String) {
        let field = app.textFields[identifier]
        scrollTo(field)
        field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        XCTAssertEqual(field.value as? String, text, "Coordinate editing must replace the complete prior value.")
        // Set/Clear also dismiss the keyboard before dispatching a request.
        if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
    }

    private func coordinate(latitude: String, longitude: String) {
        replace("simulatorMockLatitudeField", with: latitude)
        replace("simulatorMockLongitudeField", with: longitude)
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        scrollTo(button)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
        button.tap()
    }

    private func awaitValue(_ value: String, identifier: String, timeout: TimeInterval = 25) {
        let element = app.staticTexts[identifier]
        scrollTo(element)
        let predicate = NSPredicate(format: "value == %@", value)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func awaitLabel(_ value: String, identifier: String, timeout: TimeInterval = 25) {
        let element = app.staticTexts[identifier]
        scrollTo(element)
        let predicate = NSPredicate(format: "label == %@", value)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func allowLocationIfRequested() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return }
        let allow = alert.buttons["Allow While Using App"]
        XCTAssertTrue(allow.exists, "The location request explains its purpose before access is granted.")
        allow.tap()
    }

    private func attach(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func test01SetTwoPlacesClearAndReopen() throws {
        let config = try configuration()
        app.resetAuthorizationStatus(for: .location)
        launch(configuration: config)
        tap("simulatorMockClearButton")
        awaitValue("cleared", identifier: "simulatorMockVerificationState")
        coordinate(latitude: "16.8409", longitude: "96.1735")
        tap("simulatorMockSetButton")
        allowLocationIfRequested()
        awaitValue("verified", identifier: "simulatorMockVerificationState")
        awaitLabel("16.84090, 96.17350", identifier: "simulatorMockObservedCoordinate")
        awaitLabel("Software simulation reported by iOS", identifier: "simulatorMockSourceEvidence")
        attach("Yangon verified through Core Location")

        coordinate(latitude: "1.3521", longitude: "103.8198")
        tap("simulatorMockSetButton")
        awaitValue("verified", identifier: "simulatorMockVerificationState")
        awaitLabel("1.35210, 103.81980", identifier: "simulatorMockObservedCoordinate")
        attach("Singapore replaces the previous location")

        app.terminate()
        launch(configuration: config)
        // A restored host acknowledgement cannot become a fresh GPS observation.
        scrollTo(app.staticTexts["simulatorMockVerificationState"])
        XCTAssertNotEqual(app.staticTexts["simulatorMockVerificationState"].value as? String, "verified")
        XCTAssertFalse(app.staticTexts["simulatorMockObservedCoordinate"].exists)
        tap("simulatorMockClearButton")
        awaitLabel("Clear accepted by the Mac", identifier: "simulatorMockStatus")
        awaitValue("cleared", identifier: "simulatorMockVerificationState")
        XCTAssertFalse(app.staticTexts["simulatorMockObservedCoordinate"].exists)
        attach("Clear accepted without claiming real GPS")
    }

    func test02InvalidCoordinateCannotBecomeVerified() throws {
        launch(configuration: try configuration())
        coordinate(latitude: "91", longitude: "96.1735")
        XCTAssertFalse(app.buttons["simulatorMockSetButton"].isEnabled)
        scrollTo(app.staticTexts["simulatorMockVerificationState"])
        XCTAssertNotEqual(app.staticTexts["simulatorMockVerificationState"].value as? String, "verified")
    }

    func test03MissingBridgeCannotSetLocation() {
        launch(configuration: "")
        XCTAssertFalse(app.buttons["simulatorMockSetButton"].isEnabled)
        XCTAssertFalse(app.buttons["simulatorMockClearButton"].isEnabled)
        scrollTo(app.staticTexts["simulatorMockVerificationState"])
        XCTAssertNotEqual(app.staticTexts["simulatorMockVerificationState"].value as? String, "verified")
        XCTAssertFalse(app.staticTexts["simulatorMockObservedCoordinate"].exists)
        attach("Missing bridge is unavailable")
    }

    func test04WrongSessionCannotBecomeVerified() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configuration().utf8)) as? [String: Any])
        object["sessionID"] = UUID().uuidString
        let invalid = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        launch(configuration: invalid)
        tap("simulatorMockRefreshButton")
        scrollTo(app.staticTexts["simulatorMockError"])
        XCTAssertTrue(app.staticTexts["simulatorMockError"].waitForExistence(timeout: 8))
        scrollTo(app.staticTexts["simulatorMockVerificationState"])
        XCTAssertNotEqual(app.staticTexts["simulatorMockVerificationState"].value as? String, "verified")
        XCTAssertFalse(app.staticTexts["simulatorMockObservedCoordinate"].exists)
        attach("Wrong bridge session is rejected")
    }

    func test05DeniedPermissionCannotBecomeVerified() throws {
        app.terminate()
        app.resetAuthorizationStatus(for: .location)
        defer { app.resetAuthorizationStatus(for: .location) }
        launch(configuration: try configuration())
        tap("simulatorMockSetButton")
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        let deny = alert.buttons["Don’t Allow"].exists ? alert.buttons["Don’t Allow"] : alert.buttons["Don't Allow"]
        XCTAssertTrue(deny.exists)
        deny.tap()
        scrollTo(app.staticTexts["simulatorMockError"])
        XCTAssertTrue(app.staticTexts["simulatorMockError"].waitForExistence(timeout: 8))
        scrollTo(app.staticTexts["simulatorMockVerificationState"])
        XCTAssertNotEqual(app.staticTexts["simulatorMockVerificationState"].value as? String, "verified")
        XCTAssertFalse(app.staticTexts["simulatorMockObservedCoordinate"].exists)
        attach("Denied location permission remains unverified")
    }
}
