import XCTest

/// VoiceOver audit of every screen reachable without live services, a glove or a physical iPhone.
/// Each test drives the real app, checks the labels a VoiceOver user hears, then runs Xcode's
/// accessibility audit (element descriptions, hit regions, traits, Dynamic Type, clipping, contrast).
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    // MARK: Screens

    func testHomeScreenIsNavigable() throws {
        launch()
        XCTAssertTrue(app.staticTexts["Where to?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Speak a destination"].exists)
        XCTAssertTrue(app.buttons["Type a destination instead"].exists)
        XCTAssertTrue(app.buttons["Test beacons"].exists)
        XCTAssertTrue(deviceSetupButton.exists, "Device setup button needs a label describing connection state")
        assertEveryControlIsLabeled()
        try audit("home")
    }

    func testTypingSheetIsNavigable() throws {
        launch()
        app.buttons["Type a destination instead"].tap()
        XCTAssertTrue(app.textFields["Place or address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Find destination"].exists)
        XCTAssertFalse(app.buttons["Find destination"].isEnabled, "Empty destination must not be searchable")
        XCTAssertTrue(app.buttons["Cancel"].exists)
        assertEveryControlIsLabeled()
        try audit("typing sheet")
    }

    func testClarifyingPromptIsNavigable() throws {
        launch("--preview-point-ai")
        XCTAssertTrue(app.buttons["Yes, that's right"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Change destination"].exists)
        XCTAssertTrue(app.buttons["Reply"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertTrue(app.buttons["Type a destination instead"].exists)
        XCTAssertFalse(app.buttons["Speak a destination"].exists, "Glove artwork must leave the VoiceOver order once listening starts")
        assertEveryControlIsLabeled()
        try audit("clarifying prompt")
    }

    func testRoutePreviewIsNavigable() throws {
        launch("--preview-route")
        XCTAssertTrue(app.buttons["Try the walk"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Back to voice search"].exists)
        XCTAssertTrue(app.buttons["Change destination"].exists)
        XCTAssertTrue(app.staticTexts["Shake Shack"].exists)
        XCTAssertFalse(app.buttons["Speak a destination"].exists, "Home controls must be hidden from VoiceOver behind the route")
        XCTAssertEqual(app.buttons["Try the walk"].label, "Try the walk", "Decorative arrow must not be read as part of the button")
        assertEveryControlIsLabeled()
        try audit("route preview")

        app.buttons["Try the walk"].tap()
        XCTAssertTrue(app.buttons["End walk"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Simulate correct pointing"].exists)
        assertEveryControlIsLabeled()
        try audit("route walk")
    }

    func testDeviceSetupIsNavigable() throws {
        launch("--device-setup")
        XCTAssertTrue(app.navigationBars["Device setup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
        assertEveryControlIsLabeled()
        try audit("device setup")
    }

    func testBeaconTestIsNavigable() throws {
        launch("--test-beacons")
        XCTAssertTrue(app.staticTexts["Nearby beacon test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
        XCTAssertTrue(app.buttons["Test vibration"].exists)
        assertEveryControlIsLabeled()
        try audit("beacon test")
    }

    // MARK: Helpers

    private var deviceSetupButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open device setup'")).firstMatch
    }

    private func launch(_ arguments: String...) {
        app.launchArguments = arguments
        app.launch()
        allowSystemPrompts()
    }

    /// Microphone, speech, location, Bluetooth and camera prompts belong to Springboard, not the
    /// app under audit. Accept them so the audited hierarchy is the app's own.
    private func allowSystemPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow' OR label == 'OK'")).firstMatch
        for _ in 0..<5 {
            guard allow.waitForExistence(timeout: 2) else { return }
            allow.tap()
        }
    }

    /// Every interactive element must announce something; an unlabeled button is a dead stop for VoiceOver.
    private func assertEveryControlIsLabeled(file: StaticString = #filePath, line: UInt = #line) {
        let controls = [app.buttons, app.switches, app.textFields, app.progressIndicators, app.sliders]
        for query in controls {
            for element in query.allElementsBoundByIndex where element.exists {
                let spoken = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(spoken.isEmpty, "\(element.elementType) at \(element.frame) has no VoiceOver label", file: file, line: line)
                XCTAssertFalse(spoken.contains(".") && !spoken.contains(" "),
                               "\(spoken) looks like a raw symbol name rather than a spoken label", file: file, line: line)
            }
        }
    }

    private func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try app.performAccessibilityAudit(for: .all) { issue in
            // MapKit draws its own tiles and annotations; contrast there is Apple's, not ours.
            if issue.auditType == .contrast, issue.element?.elementType == .map { return true }
            XCTFail("\(screen): \(issue.compactDescription)\n\(issue.detailedDescription)", file: file, line: line)
            return true
        }
    }
}
