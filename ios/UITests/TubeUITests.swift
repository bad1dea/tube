import XCTest

/// Walks the main flows on a simulator and attaches a screenshot per step.
/// CI (ios-build.yml) enables the runner's sshd and passes its credentials as
/// TEST_RUNNER_TUBE_UITEST_*; without them the terminal steps still run
/// against a failed connection.
final class TubeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        var env = ["TUBE_UITEST": "1"]
        for k in ["TUBE_UITEST_HOST", "TUBE_UITEST_PORT", "TUBE_UITEST_USER", "TUBE_UITEST_PASSWORD"] {
            if let v = ProcessInfo.processInfo.environment[k] { env[k] = v }
        }
        app.launchEnvironment = env
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)[label].firstMatch
    }

    func testTour() throws {
        XCTAssertTrue(app.navigationBars["Tube"].waitForExistence(timeout: 10))
        shot("01-hosts")
        app.swipeUp()
        shot("02-hosts-library")
        app.swipeDown()

        // Connect to the real host.
        let runner = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'runner'")).firstMatch
        XCTAssertTrue(runner.waitForExistence(timeout: 5))
        runner.tap()
        let trust = app.buttons["Trust"]
        if trust.waitForExistence(timeout: 15) {
            shot("03-host-key")
            trust.tap()
        }
        let esc = element("Escape")
        XCTAssertTrue(esc.waitForExistence(timeout: 15), "key bar did not appear")
        sleep(3)
        shot("04-terminal")

        // The key row must scroll: F12 starts off screen.
        let f12 = element("F12")
        let row = app.scrollViews["keyRow"]
        XCTAssertTrue(row.exists)
        XCTAssertFalse(f12.isHittable, "F12 should start off screen")
        for _ in 0..<4 where !f12.isHittable { row.swipeLeft() }
        XCTAssertTrue(f12.isHittable, "key row did not scroll")
        shot("05-keyrow-scrolled")
        for _ in 0..<4 { row.swipeRight() }

        // Key panel and every tab (the {} tab crashed in build 3).
        element("Key panel").tap()
        sleep(1)
        shot("06-panel-keys")
        for tab in ["Snippets", "History", "Theme"] {
            let b = element(tab)
            XCTAssertTrue(b.waitForExistence(timeout: 5), "\(tab) tab missing")
            b.tap()
            sleep(1)
            shot("07-panel-\(tab.lowercased())")
        }
        element("Keys").tap()
        element("System keyboard").tap()
        sleep(1)

        // Long-press pad.
        let terminal = app.scrollViews["terminal"].firstMatch.exists ? app.scrollViews["terminal"].firstMatch : element("terminal")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.0)
        XCTAssertTrue(element("terminalPad").waitForExistence(timeout: 3), "pad did not appear")
        shot("08-pad")
        element("Close pad").tap()

        // Password key asks before typing anything.
        element("Type saved password").tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3), "password key typed without asking")
        shot("09-password-confirm")
        app.alerts.buttons["Cancel"].tap()

        element("Hosts").tap()
        sleep(1)
        shot("10-hosts-with-session")
    }
}
