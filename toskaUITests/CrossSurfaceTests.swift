import XCTest

// THROWAWAY cross-surface driver (web guide §6C, 2026-07-09 verification
// sweep). Asserts web-created staging content renders in the iOS app.
// Delete after the Phase 1 sweep — not CI material.
final class CrossSurfaceTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    var feedView: XCUIElement { app.otherElements["feedView"] }

    func requireFeed() throws {
        if waitFor(app.buttons["sign in"], 5) {
            app.buttons["sign in"].tap()
            let email = app.textFields["emailField"]
            XCTAssertTrue(waitFor(email, 8), "Email field missing")
            email.tap(); email.typeText("salinarotess+nice@gmail.com")
            let pw = app.secureTextFields["passwordField"]
            // Never hardcode (2026-07-22 leak) — see ClientBugRegressionTests.
            guard let stagingPw = ProcessInfo.processInfo.environment["TOSKA_STAGING_TEST_PW"] else {
                XCTFail("TOSKA_STAGING_TEST_PW not set — pass TEST_RUNNER_TOSKA_STAGING_TEST_PW to xcodebuild")
                return
            }
            pw.tap(); pw.typeText(stagingPw)
            app.buttons["signInButton"].tap()
        }
        XCTAssertTrue(waitFor(feedView, 30), "Feed didn't load")
        sleep(3)
    }

    func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    /// Scroll-search the feed for any element whose label contains `needle`.
    func feedContains(_ needle: String, swipes: Int = 8) -> Bool {
        let pred = NSPredicate(format: "label CONTAINS[c] %@", needle)
        for attempt in 0...swipes {
            if app.descendants(matching: .any).matching(pred).firstMatch
                .waitForExistence(timeout: attempt == 0 ? 8 : 2) { return true }
            app.swipeUp()
            usleep(700_000)
        }
        return false
    }

    // Run BEFORE the web-side block of demo_u1.
    func test01_webContentRendersInFeed() throws {
        try requireFeed()
        // web-created post (s2 marker)
        XCTAssertTrue(feedContains("webtest s2"), "web-created post not in iOS feed")
        snap("cs-01a-web-post-in-feed")
        // web-created repost attribution (repost of demo_p3 by +nice)
        app.terminate(); app.launch()
        XCTAssertTrue(waitFor(feedView, 30))
        sleep(3)
        XCTAssertTrue(feedContains("reposted"), "web repost attribution row not in iOS feed")
        snap("cs-01b-web-repost-attribution")
        // demo_p1 present pre-block (control for test02)
        app.terminate(); app.launch()
        XCTAssertTrue(waitFor(feedView, 30))
        sleep(3)
        XCTAssertTrue(feedContains("kept your hoodie"), "demo_p1 not visible pre-block")
        snap("cs-01c-demo-p1-present")
    }

    // web like notification from anonymous_cd1b15f0 (webv1) on +nice's post.
    func test02_webLikeNotificationLands() throws {
        try requireFeed()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch.tap()
        XCTAssertTrue(waitFor(app.staticTexts["notifications"], 8), "Notifications didn't open")
        sleep(2)
        let pred = NSPredicate(format: "label CONTAINS[c] 'anonymous_cd1b15f0'")
        let row = app.descendants(matching: .any).matching(pred).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "webv1 like notification missing")
        snap("cs-02-web-like-notification")
    }

    // Run AFTER the web-side block of demo_u1: demo_p1 must be stripped.
    func test90_afterWebBlockDemoP1Stripped() throws {
        try requireFeed()
        // control: feed loaded and scrolls (web post still present)
        XCTAssertTrue(feedContains("webtest s2"), "feed control row missing — feed not loaded?")
        app.terminate(); app.launch()
        XCTAssertTrue(waitFor(feedView, 30))
        sleep(3)
        XCTAssertFalse(feedContains("kept your hoodie", swipes: 10),
                       "demo_p1 still visible on iOS after web-side block")
        snap("cs-90-demo-p1-stripped")
    }
}
