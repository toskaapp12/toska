import XCTest

// MARK: - Multi-user live-session holder (2026-06-11)
// One instance of this runs per simulator, each with different TEST_RUNNER_
// env creds: it signs out of any stale session, signs in as its assigned
// account, opens the shared target post, then HOLDS the screen for several
// minutes while an SDK driver makes the other accounts interact. The
// orchestrating session screenshots each simulator during the hold to verify
// live listeners (replies appearing, counts ticking) across 5 real clients.
//
// Env (pass via TEST_RUNNER_ prefix on xcodebuild):
//   TOSKA_EMAIL / TOSKA_PW   — this simulator's account
//   TOSKA_POST_TEXT          — text of the post row to open (default below)
//   TOSKA_HOLD_SECONDS       — hold duration (default 300)

final class MultiUserHoldTests: XCTestCase {

    func test_holdOnSharedPost() throws {
        let env = ProcessInfo.processInfo.environment
        let email = env["TOSKA_EMAIL"] ?? "salinarotess+nice@gmail.com"
        // No fallback (2026-07-22 leak) — pass TEST_RUNNER_TOSKA_PW to xcodebuild.
        guard let pw = env["TOSKA_PW"] ?? env["TOSKA_STAGING_TEST_PW"] else {
            throw XCTSkip("TOSKA_PW not set — see .local-credentials.md")
        }
        let postText = env["TOSKA_POST_TEXT"] ?? "midnight check-in, all of us"
        let holdSeconds = UInt32(env["TOSKA_HOLD_SECONDS"] ?? "300") ?? 300

        let app = XCUIApplication()
        app.launch()

        func waitFor(_ e: XCUIElement, _ t: TimeInterval = 10) -> Bool { e.waitForExistence(timeout: t) }
        func forceTap(_ e: XCUIElement) {
            if e.isHittable { e.tap() }
            else { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        }

        // 1. Sign out if a session is live (fresh installs land on the splash).
        if waitFor(app.buttons["for you"], 15) {
            app.buttons["Profile"].tap()
            sleep(2)
            let gear = app.buttons["settings"]
            XCTAssertTrue(waitFor(gear, 8), "settings gear missing")
            gear.tap()
            _ = waitFor(app.staticTexts["settings"], 8)
            for _ in 0..<8 {
                let row = app.buttons["sign out"]
                if row.exists && row.frame.maxY < app.frame.maxY - 100 && row.frame.minY > 100 { break }
                app.swipeUp()
                usleep(400_000)
            }
            forceTap(app.buttons["sign out"])
            let confirm = app.alerts.buttons["sign out"]
            if waitFor(confirm, 5) { forceTap(confirm) }
        }

        // 2. Sign in as the assigned account.
        XCTAssertTrue(waitFor(app.buttons["sign in"], 15), "splash didn't appear")
        app.buttons["sign in"].tap()
        let emailField = app.textFields["emailField"]
        XCTAssertTrue(waitFor(emailField, 8), "email field missing")
        emailField.tap()
        emailField.typeText(email)
        let pwField = app.secureTextFields["passwordField"]
        pwField.tap()
        pwField.typeText(pw)
        app.buttons["signInButton"].tap()
        XCTAssertTrue(waitFor(app.buttons["for you"], 30), "feed didn't load after sign-in")
        sleep(3)

        // 3. Open the shared target post.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", postText)).firstMatch
        XCTAssertTrue(waitFor(row, 15), "target post row not found in feed")
        forceTap(row)
        sleep(2)
        XCTAssertTrue(app.staticTexts[postText].waitForExistence(timeout: 10), "post detail didn't open")

        // 4. Hold while the SDK driver makes the other users interact.
        sleep(holdSeconds)
    }
}
