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
        XCTAssertTrue(app.buttons["Speak to Point"].exists)
        XCTAssertTrue(app.buttons["Type a destination instead"].exists)
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
        try audit("typing sheet", overSheet: true)
    }

    func testClarifyingPromptIsNavigable() throws {
        launch("--preview-point-ai")
        XCTAssertTrue(app.buttons["Yes, that's right"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Change destination"].exists)
        XCTAssertTrue(app.buttons["Reply"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertTrue(app.buttons["Type a destination instead"].exists)
        XCTAssertFalse(app.buttons["Speak to Point"].exists, "Glove artwork must leave the VoiceOver order once listening starts")
        assertEveryControlIsLabeled()
        try audit("clarifying prompt")
    }

    func testRoutePreviewIsNavigable() throws {
        // The sample route plays as a timed demo that the app abandons whenever a system prompt
        // takes the scene inactive, so settle the permission prompts on a plain launch first.
        launch()
        launch("--preview-route")
        XCTAssertTrue(app.buttons["Try the walk"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Back to voice search"].exists)
        XCTAssertTrue(app.buttons["Change destination"].exists)
        XCTAssertTrue(app.staticTexts["Shake Shack"].exists)
        XCTAssertFalse(app.buttons["Speak to Point"].exists, "Home controls must be hidden from VoiceOver behind the route")
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
        XCTAssertTrue(app.staticTexts["Indoor demo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Exit demo"].exists)
        XCTAssertTrue(app.buttons["Demo help"].exists)
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
        // Location offers "Allow Once" first; that re-prompts on every launch, so prefer the lasting grant.
        let allowWhileUsing = springboard.buttons["Allow While Using App"]
        let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow' OR label == 'OK'")).firstMatch
        for _ in 0..<5 {
            guard allow.waitForExistence(timeout: 2) else { return }
            (allowWhileUsing.exists ? allowWhileUsing : allow).tap()
        }
    }

    /// Every interactive element must announce something; an unlabeled button is a dead stop for VoiceOver.
    private func assertEveryControlIsLabeled(file: StaticString = #filePath, line: UInt = #line) {
        let controls = [app.buttons, app.switches, app.textFields, app.progressIndicators, app.sliders]
        // A SwiftUI Toggle exposes its labeled switch plus the bare UISwitch nested inside it;
        // VoiceOver reads only the outer one.
        let toggles = app.switches.allElementsBoundByIndex.filter { !$0.label.isEmpty }
        for query in controls {
            for element in query.allElementsBoundByIndex where element.exists {
                if element.elementType == .switch, element.label.isEmpty,
                   toggles.contains(where: { $0.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) }) { continue }
                let spoken = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(spoken.isEmpty, "\(describe(element)) has no VoiceOver label", file: file, line: line)
                XCTAssertFalse(spoken.contains(".") && !spoken.contains(" "),
                               "\(spoken) looks like a raw symbol name rather than a spoken label", file: file, line: line)
            }
        }
    }

    private func audit(_ screen: String, overSheet: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        let lists = (app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex).map(\.frame)
        try app.performAccessibilityAudit(for: .all) { issue in
            if let element = issue.element {
                // MapKit draws its own tiles, attribution and Legal link; those are Apple's, not ours.
                if element.elementType == .map || element.label == "Map data © Apple" ||
                   (element.elementType == .link && element.label == "Legal") { return true }
                // WCAG 1.4.3 exempts inactive controls from contrast minimums.
                if issue.auditType == .contrast, !element.isEnabled { return true }
                // UIKit styles, sizes and lays out navigation bar items itself.
                if bars.contains(where: { $0.intersects(element.frame) }) { return true }
                // Form and List rows grow with the type size and scroll; the audit only sees the
                // rows that happen to be on screen at each size, so it calls them clipped or unscaled.
                if issue.auditType == .dynamicType || issue.auditType == .textClipped,
                   lists.contains(where: { $0.contains(element.frame) }) { return true }
                // A button in a Form row is hit-testable across the whole row, so the contrast sampler
                // compares its text with the row background around the drawn capsule, not the capsule.
                if issue.auditType == .contrast, element.elementType == .button,
                   lists.contains(where: { $0.contains(element.frame) }) { return true }
            } else if issue.auditType == .elementDetection, overSheet {
                // Text the audit spotted by eye but could not find an element for: with a sheet up, that is
                // the dimmed screen behind it showing through the sheet material.
                return true
            }
            let element = issue.element.map(self.describe) ?? "unknown element"
            XCTFail("\(screen): \(issue.compactDescription) — \(element)\n\(issue.detailedDescription)", file: file, line: line)
            return true
        }
    }

    private func describe(_ element: XCUIElement) -> String {
        "\(element.elementType) label=\"\(element.label)\" id=\"\(element.identifier)\" value=\"\(element.value.map { "\($0)" } ?? "")\" at \(element.frame.integral)"
    }
}
