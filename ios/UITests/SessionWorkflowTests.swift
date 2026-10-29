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

    /// expectKeyBar is false when the host will ask for a password first:
    /// the password field has focus, so the terminal's key bar is not up.
    func connect(_ prefix: String, expectKeyBar: Bool = true) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        // Lists only create rows that are on screen.
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no host row \(prefix)")
        row.tap()
        let trust = app.buttons["Trust"]
        if trust.waitForExistence(timeout: 20) {
            // Reading the fingerprint takes time; this must not time the login out.
            sleep(12)
            trust.tap()
        }
        if expectKeyBar {
            XCTAssertTrue(el("Escape").waitForExistence(timeout: 20), "terminal did not open")
        }
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 6) { tutorial.tap() }
        sleep(4)
    }

    /// Generate a key, install it on the runner over the saved password, then
    /// log in with it. The workflow checks sshd's log for "Accepted publickey".
    func testKeyInstallAndLogin() throws {
        XCTAssertTrue(app.navigationBars["Tube"].waitForExistence(timeout: 10))
        let keysRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SSH Keys'")).firstMatch
        for _ in 0..<6 where !(keysRow.exists && keysRow.isHittable) { app.swipeUp() }
        keysRow.tap()
        tap("Add Key")
        tap("Generate New Key")
        tap("Generate")
        let keyRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'tube@'")).firstMatch
        XCTAssertTrue(keyRow.waitForExistence(timeout: 5), "generated key not listed")
        keyRow.tap()
        XCTAssertTrue(el("publicKey").waitForExistence(timeout: 5))
        shot("k01-key")
        tap("Install on a Server")
        tap("install-runner")
        tap("Install")
        let trust = app.buttons["Trust"]
        if trust.waitForExistence(timeout: 20) { trust.tap() }
        let usedBy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Used by runner'")).firstMatch
        XCTAssertTrue(usedBy.waitForExistence(timeout: 30), "key install did not finish")
        shot("k02-installed")
        app.navigationBars.buttons.firstMatch.tap()
        if app.buttons["Done"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }
        let hosts = app.navigationBars["Tube"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 5))
        sleep(2)
        for _ in 0..<6 where !app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'runner,'")).firstMatch.isHittable {
            app.swipeDown()
        }

        connect("runner,")
        run("mkdir -p ~/c && touch ~/c/ok-key-login")
        shot("k03-key-session")
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

        // Drags on the terminal. cat in canonical mode stores the escape
        // sequences it receives, which the workflow then checks.
        let term = el("terminal")
        func drag(_ from: CGVector, _ to: CGVector) {
            term.coordinate(withNormalizedOffset: from)
                .press(forDuration: 0.05, thenDragTo: term.coordinate(withNormalizedOffset: to))
            sleep(1)
        }
        run("cat > ok-swipe-keys", wait: 1)
        drag(CGVector(dx: 0.8, dy: 0.35), CGVector(dx: 0.2, dy: 0.35))    // ← arrows
        run("")
        tap("Control")
        app.typeText("d")
        sleep(1)
        // With mouse reporting on, a vertical drag becomes wheel events.
        run("printf '\\033[?1000h\\033[?1006h'; cat > ok-wheel", wait: 1)
        drag(CGVector(dx: 0.5, dy: 0.25), CGVector(dx: 0.5, dy: 0.6))     // finger down = wheel up
        run("")
        tap("Control")
        app.typeText("d")
        sleep(1)
        run("printf '\\033[?1000l\\033[?1006l'")
        shot("w03b-swipes")

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
        // Full-screen apps use the last row (tmux status, vim command line);
        // it must not be under the keyboard's session strip.
        let termBottom = el("terminal").frame.maxY
        let stripTop = el("Hosts").frame.minY
        XCTAssertLessThanOrEqual(termBottom, stripTop + 1, "terminal extends under the key bar (\(termBottom) > \(stripTop))")
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
        // The host list behind the sheet has the same row; tap the sheet's.
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'runner,'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        let picker = rows.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(picker, "no tappable host in the picker")
        picker?.tap()
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
        connect("runner-nopw", expectKeyBar: false)
        let pw = app.secureTextFields["sessionPassword"]
        XCTAssertTrue(pw.waitForExistence(timeout: 20), "no password prompt")
        shot("w13-password-prompt")
        pw.tap()
        pw.typeText(ProcessInfo.processInfo.environment["TUBE_UITEST_PASSWORD"] ?? "")
        app.buttons["Connect"].firstMatch.tap()
        XCTAssertTrue(el("Escape").waitForExistence(timeout: 20), "terminal did not take the keyboard after the password prompt")
        sleep(4)
        run("cd ~/c && echo prompted > ok-password-prompt")
        // A logout closes the session quietly, even with a non-zero status.
        run("false; exit", wait: 3)
        if !app.navigationBars["Tube"].exists { tap("Hosts") }
        sleep(1)
        XCTAssertFalse(app.buttons["Disconnect runner-nopw"].exists, "session stayed open after exit")
        XCTAssertFalse(el("Last Connection Failed").exists, "exit shown as a failure")
        shot("w14-hosts")

        // Disconnect from the host list: one with its x, the rest with Disconnect All.
        let x = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Disconnect runner'")).firstMatch
        for _ in 0..<4 where !(x.exists && x.isHittable) { app.swipeDown() }
        XCTAssertTrue(x.waitForExistence(timeout: 5), "no disconnect button on open sessions")
        let before = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Disconnect runner'")).count
        x.tap()
        sleep(1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Disconnect runner'")).count, before - 1)
        if app.buttons["Disconnect All"].exists { app.buttons["Disconnect All"].tap() }
        sleep(1)
        XCTAssertFalse(app.staticTexts["Open"].exists, "sessions still open")
        shot("w15-disconnected")
    }
}
