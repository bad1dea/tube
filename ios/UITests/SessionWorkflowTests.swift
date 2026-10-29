import XCTest

/// Drives real sessions against the CI Mac's sshd as the throwaway user
/// (ios-build.yml). Every step makes the shell write a marker under ~/c on
/// the server; the workflow checks those files afterwards, so a pass means the
/// bytes really reached the shell, not just that the UI looked right.
final class SessionWorkflowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 1200
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

    func el(_ label: String) -> XCUIElement { app.descendants(matching: .any)[label].firstMatch }

    /// Type a shell line and give the remote time to run it.
    func run(_ line: String, wait: UInt32 = 2) {
        app.typeText(line + "\n")
        sleep(wait)
    }

    func tap(_ label: String, _ file: StaticString = #filePath, _ line: UInt = #line) {
        let e = el(label)
        if !e.waitForExistence(timeout: 5) {
            XCTFail("missing \(label)", file: file, line: line)
            return
        }
        // Key-row keys may be scrolled away.
        if !e.isHittable, app.scrollViews["keyRow"].exists {
            for _ in 0..<12 where !e.isHittable { app.scrollViews["keyRow"].swipeRight() }
            for _ in 0..<12 where !e.isHittable { app.scrollViews["keyRow"].swipeLeft() }
        }
        e.tap()
    }

    func connect(_ prefix: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no host row \(prefix)")
        row.tap()
        let trust = app.buttons["Trust"]
        if trust.waitForExistence(timeout: 20) {
            // Reading the fingerprint takes time; this must not time the login out.
            sleep(12)
            trust.tap()
        }
        XCTAssertTrue(el("Escape").waitForExistence(timeout: 20), "terminal did not open")
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 6) { tutorial.tap() }
        sleep(4)
    }

    func testSessionWorkflows() throws {
        XCTAssertTrue(app.navigationBars["Tube"].waitForExistence(timeout: 10))
        connect("runner,")
        shot("w01-connected")

        run("mkdir -p ~/c && cd ~/c && echo connected > ok-connect")
        run("echo typed > ok-typed")

        // Suggestion chip completes a line from history.
        run("touch ok-chip-seed")
        run("rm ok-chip-seed")
        app.typeText("touch ok-chip-s")
        let chip = app.buttons["Complete touch ok-chip-seed"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no suggestion chip")
        shot("w02-chip")
        chip.tap()
        run("")

        // One-shot CTRL then c interrupts a foreground job.
        run("sleep 25; touch bad-not-interrupted", wait: 1)
        tap("Control")
        app.typeText("c")
        sleep(1)
        run("echo $? > ok-ctrl-c")

        // Tab key reaches the shell's completion.
        run("touch tabtarget-file")
        app.typeText("cp tabtar")
        tap("Tab")
        sleep(1)
        run(" ok-tab")

        // Up arrow recalls the previous line.
        run("echo line >> ok-arrow")
        tap("Up")
        sleep(1)
        run("")
        shot("w03-shell")

        // vim: insert mode, Escape key, :wq.
        run("vim -u NONE -N ok-vim.txt", wait: 3)
        app.typeText("ihello from vim")
        tap("Escape")
        sleep(1)
        shot("w04-vim")
        run(":wq", wait: 2)

        // tmux: start, work inside, detach with CTRL then b, d.
        run("tmux new -s tube", wait: 3)
        run("touch ok-in-tmux")
        shot("w05-tmux")
        tap("Control")
        app.typeText("b")
        sleep(1)
        app.typeText("d")
        sleep(2)
        run("tmux ls > ok-tmux-ls; tmux kill-server")

        // screen: start, work inside, detach with CTRL then a, d.
        run("screen -S tube", wait: 3)
        run("touch ok-in-screen")
        shot("w06-screen")
        tap("Control")
        app.typeText("a")
        sleep(1)
        app.typeText("d")
        sleep(2)
        run("screen -ls > ok-screen-ls; screen -X -S tube quit")

        // Key panel: snippet runs, other tabs open.
        tap("Key panel")
        sleep(1)
        shot("w07-panel")
        tap("Snippets")
        sleep(1)
        let snippet = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Disk usage'")).firstMatch
        XCTAssertTrue(snippet.waitForExistence(timeout: 5), "snippet missing")
        snippet.tap()
        sleep(2)
        tap("History")
        sleep(1)
        shot("w08-history")
        tap("Theme")
        sleep(1)
        tap("Keys")
        tap("System keyboard")
        sleep(1)
        run("df -h > ok-snippet-df")

        // Pad on long press.
        el("terminal").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.0)
        XCTAssertTrue(el("terminalPad").waitForExistence(timeout: 3), "pad did not appear")
        shot("w09-pad")
        tap("Close pad")

        // Password key asks before typing.
        tap("Type saved password")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3), "password typed without asking")
        app.alerts.buttons["Cancel"].tap()
        sleep(1)

        // Files (SFTP).
        tap("Files (SFTP)")
        let cdir = app.buttons.matching(NSPredicate(format: "label CONTAINS 'c'")).firstMatch
        XCTAssertTrue(cdir.waitForExistence(timeout: 15), "file list empty")
        sleep(2)
        shot("w10-files")
        app.buttons["Done"].firstMatch.tap()
        sleep(2)

        // Second session to the same host, then switch between the two.
        tap("New session")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'runner,'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        XCTAssertTrue(el("Session runner 2").waitForExistence(timeout: 20), "second session not labelled")
        sleep(4)
        run("cd ~/c && echo two > ok-session2")
        shot("w11-two-sessions")
        tap("Session runner 1")
        sleep(2)
        run("echo one > ok-session1")
        shot("w12-switched-back")

        // A host with no saved password asks for one.
        tap("Hosts")
        sleep(1)
        connect("runner-nopw")
        let pw = app.secureTextFields["sessionPassword"]
        XCTAssertTrue(pw.waitForExistence(timeout: 20), "no password prompt")
        shot("w13-password-prompt")
        pw.tap()
        pw.typeText(ProcessInfo.processInfo.environment["TUBE_UITEST_PASSWORD"] ?? "")
        app.buttons["Connect"].firstMatch.tap()
        sleep(6)
        run("cd ~/c && echo prompted > ok-password-prompt")
        tap("Hosts")
        sleep(1)
        shot("w14-hosts")
    }
}
