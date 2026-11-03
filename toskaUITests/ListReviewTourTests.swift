import XCTest

// MARK: - List-integrity visual tour (2026-11-03)
// Drives the REAL app against staging with the seeded review data and attaches
// a named screenshot of every main screen, once in the light palette and once
// in the night palette (TOSKA_FORCE_NIGHT=1 relaunch). Read-only: it taps
// around, types a search, and never posts. Credentials come from
// TEST_RUNNER_TOSKA_EMAIL / TEST_RUNNER_TOSKA_STAGING_TEST_PW; the handle to
// open as "other profile" from TEST_RUNNER_TOSKA_TOUR_HANDLE and a snippet of
// a seeded prompt answer from TEST_RUNNER_TOSKA_TOUR_TEXT.
final class ListReviewTourTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = true }
    override func tearDownWithError() throws { app = nil }

    func launch(night: Bool) {
        app = XCUIApplication()
        applyAppCheckDebugToken(app)
        if night { app.launchEnvironment["TOSKA_FORCE_NIGHT"] = "1" }
        app.launch()
    }
    func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }
    @discardableResult func waitFor(_ e: XCUIElement, _ t: TimeInterval = 10) -> Bool { e.waitForExistence(timeout: t) }
    func forceTap(_ e: XCUIElement) {
        if e.isHittable { e.tap() } else { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }
    func tapIf(_ e: XCUIElement, _ t: TimeInterval = 4) -> Bool { if e.waitForExistence(timeout: t) { forceTap(e); return true }; return false }
    func back() {
        // Custom headers use a chevron button; fall back to an edge swipe.
        let candidates = [app.buttons["Back"], app.buttons["back"], app.buttons["chevron.left"], app.navigationBars.buttons.firstMatch]
        for c in candidates where c.exists && c.isHittable { c.tap(); sleep(1); return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 0)))
        sleep(1)
    }
    func scrollToTop(_ n: Int = 4) { for _ in 0..<n { app.swipeDown(); usleep(350_000) } }
    func findRow(containing text: String, swipes: Int = 6) -> XCUIElement? {
        let pred = NSPredicate(format: "label CONTAINS[c] %@", text)
        let row = app.descendants(matching: .any).matching(pred).firstMatch
        for i in 0...swipes {
            if row.waitForExistence(timeout: i == 0 ? 8 : 2) { return row }
            app.swipeUp(); usleep(600_000)
        }
        return nil
    }
    func acceptPolicyGateIfPresent() {
        let agree = app.buttons["i agree and continue"]
        guard agree.waitForExistence(timeout: 3) else { return }
        let checkbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "i confirm i am 18 or older")).firstMatch
        if checkbox.waitForExistence(timeout: 2) { checkbox.tap() }
        forceTap(agree)
    }
    func signInIfNeeded(_ p: String) {
        if waitFor(app.buttons["sign in"], 6) {
            snap("\(p)-00-splash")
            app.buttons["sign in"].tap()
            let email = app.textFields["emailField"]
            XCTAssertTrue(waitFor(email, 8), "Email field missing")
            snap("\(p)-00b-signin")
            email.tap(); email.typeText(ProcessInfo.processInfo.environment["TOSKA_EMAIL"] ?? "")
            let pw = app.secureTextFields["passwordField"]
            pw.tap(); pw.typeText(ProcessInfo.processInfo.environment["TOSKA_STAGING_TEST_PW"] ?? "")
            app.buttons["signInButton"].tap()
        }
        // "Save Password?" system sheet eats every later tap.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 6) { notNow.tap() }
        acceptPolicyGateIfPresent()
        // A fresh account may land in the onboarding walkthrough; step through it.
        for _ in 0..<8 {
            if app.buttons["for you"].exists { break }
            let next = app.buttons["next"]
            if next.waitForExistence(timeout: 3) { forceTap(next); usleep(600_000); continue }
            let other = app.buttons.matching(NSPredicate(format: "label IN %@", ["get started", "let's go", "done", "continue", "skip", "start"])).firstMatch
            if other.exists { forceTap(other); usleep(600_000); continue }
            break
        }
        XCTAssertTrue(waitFor(app.buttons["for you"], 40), "Feed didn't load")
        sleep(4)
    }

    func tour(_ p: String) {
        let handle = ProcessInfo.processInfo.environment["TOSKA_TOUR_HANDLE"] ?? ""
        let answerText = ProcessInfo.processInfo.environment["TOSKA_TOUR_TEXT"] ?? "answer today"
        signInIfNeeded(p)
        snap("\(p)-01-feed-top")
        app.swipeUp(); sleep(1); snap("\(p)-02-feed-scrolled")
        app.swipeUp(); app.swipeUp(); sleep(2); snap("\(p)-03-feed-deeper")
        scrollToTop(6)
        if tapIf(app.buttons["following"]) { sleep(4); snap("\(p)-04-following"); app.swipeUp(); sleep(1); snap("\(p)-04b-following-scrolled"); scrollToTop(); _ = tapIf(app.buttons["for you"]); sleep(1) }
        // search
        if tapIf(app.buttons["Search"].firstMatch) {
            sleep(1)
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 4) { field.tap(); app.typeText("quiet\n"); sleep(4); snap("\(p)-05-search") }
            _ = tapIf(app.buttons["Clear search"], 2)
            _ = tapIf(app.buttons["cancel"], 2)
            sleep(1)
        }
        // explore + tag detail
        if tapIf(app.buttons["explore"].firstMatch) {
            sleep(4); snap("\(p)-06-explore")
            if tapIf(app.buttons["longing"].firstMatch, 4) { sleep(3); snap("\(p)-07-explore-tag-longing"); back() }
            back(); sleep(1)
        }
        // prompt responses (today)
        if tapIf(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "what others said")).firstMatch) { sleep(4); snap("\(p)-08-prompt-responses"); back(); sleep(1) }
        // post detail (a seeded prompt answer, which also shows the answering line) + other profile
        if let row = findRow(containing: answerText) {
            forceTap(row); sleep(4); snap("\(p)-09-post-detail")
            app.swipeUp(); sleep(1); snap("\(p)-09b-post-detail-replies")
            scrollToTop(2)
            if !handle.isEmpty, tapIf(app.buttons[handle].firstMatch, 4) { sleep(4); snap("\(p)-10-other-profile"); back() }
            back(); sleep(1)
        }
        scrollToTop(6)
        // trending (most felt)
        if tapIf(app.buttons["Trending"]) {
            sleep(4); snap("\(p)-11-trending-today")
            if tapIf(app.buttons["this week"], 3) { sleep(3); snap("\(p)-12-trending-week") }
            if tapIf(app.buttons["all time"], 3) { sleep(3); snap("\(p)-13-trending-alltime") }
        }
        // notifications
        if tapIf(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch) { sleep(4); snap("\(p)-14-notifications") }
        // profile + tabs + settings
        if tapIf(app.buttons["Profile"]) {
            sleep(4); snap("\(p)-15-profile-posts")
            for tab in ["liked", "saved", "replies", "reposts"] { if tapIf(app.buttons[tab], 3) { sleep(3); snap("\(p)-16-profile-\(tab)") } }
            if tapIf(app.buttons["settings"], 3) { sleep(2); snap("\(p)-17-settings"); back() }
        }
        // compose
        _ = tapIf(app.buttons["Home"], 3); sleep(1)
        if tapIf(app.buttons["New post"], 4) { sleep(2); snap("\(p)-18-compose"); _ = tapIf(app.buttons["cancel"], 3) }
    }

    func test01_light() { launch(night: false); tour("light") }
    func test02_night() { launch(night: true); tour("night") }

    // Second pass: the remaining screens, reached by tab-bar coordinates (labels vary), plus an
    // accessibility dump so the labels can be fixed for next time.
    func tapBar(_ fx: CGFloat) { app.coordinate(withNormalizedOffset: CGVector(dx: fx, dy: 0.935)).tap(); sleep(3) }
    func dump(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func tour2(_ p: String) {
        signInIfNeeded(p)
        dump("\(p)-ax-feed")
        // prompt responses from the card at the top of the feed
        if tapIf(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "what others said")).firstMatch, 4) { sleep(4); snap("\(p)-20-prompt-responses"); dump("\(p)-ax-prompt"); back(); sleep(1) }
        else if tapIf(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "what others said")).firstMatch, 2) { sleep(4); snap("\(p)-20-prompt-responses"); back(); sleep(1) }
        // search pill → empty search state (explore entry)
        if tapIf(app.buttons["Search"].firstMatch, 3) { sleep(2); snap("\(p)-21-search-empty"); dump("\(p)-ax-search")
            if tapIf(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "explore")).firstMatch, 3) { sleep(4); snap("\(p)-22-explore"); dump("\(p)-ax-explore")
                if tapIf(app.buttons.matching(NSPredicate(format: "label ==[c] %@", "longing")).firstMatch, 3) { sleep(3); snap("\(p)-23-explore-tag"); back() }
                back(); sleep(1) }
            _ = tapIf(app.buttons["Clear search"], 2); _ = tapIf(app.buttons["cancel"], 2); sleep(1) }
        // tab bar: home 0.15, trending 0.30, write 0.50, notifications 0.70, profile 0.85
        if ProcessInfo.processInfo.environment["TOSKA_TOUR_SKIP_TRENDING"] != "1" {
            // 2026-11-03: opening this tab crashes the Debug build on the iOS 26 simulator (see the list review).
            tapBar(0.30); snap("\(p)-24-trending-today"); dump("\(p)-ax-trending")
            if tapIf(app.buttons["this week"], 3) { sleep(3); snap("\(p)-25-trending-week") }
            if tapIf(app.buttons["all time"], 3) { sleep(3); snap("\(p)-26-trending-alltime") }
        }
        tapBar(0.70); snap("\(p)-27-notifications"); dump("\(p)-ax-notifications")
        tapBar(0.85); snap("\(p)-28-profile-posts"); dump("\(p)-ax-profile")
        for tab in ["liked", "saved", "replies", "reposts"] { if tapIf(app.buttons[tab], 3) { sleep(3); snap("\(p)-29-profile-\(tab)") } }
        if tapIf(app.buttons["settings"], 3) { sleep(2); snap("\(p)-30-settings"); back() }
        tapBar(0.15); sleep(1)
        tapBar(0.50); snap("\(p)-31-compose"); dump("\(p)-ax-compose"); _ = tapIf(app.buttons["cancel"], 3)
        // other profile: open a seeded row, then the author handle
        let handle = ProcessInfo.processInfo.environment["TOSKA_TOUR_HANDLE"] ?? ""
        if !handle.isEmpty, let row = findRow(containing: "answer today") {
            forceTap(row); sleep(3); dump("\(p)-ax-detail")
            if tapIf(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", handle)).firstMatch, 3) || tapIf(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", handle)).firstMatch, 2) { sleep(4); snap("\(p)-32-other-profile"); dump("\(p)-ax-other"); back() }
            back()
        }
    }
    func test03_light_rest() { launch(night: false); tour2("light") }
    /// Minimal crash repro: sign in, open the trending tab, switch periods (2026-11-03 list review F0).
    func test05_trendingOnly() {
        launch(night: false); signInIfNeeded("trend")
        tapBar(0.30); snap("trend-01-today"); dump("trend-ax")
        if tapIf(app.buttons["this week"], 3) { sleep(3); snap("trend-02-week") }
        if tapIf(app.buttons["all time"], 3) { sleep(3); snap("trend-03-alltime") }
        app.swipeDown(); sleep(3); snap("trend-04-after-pull")
    }
    func test04_night_rest() { launch(night: true); tour2("night") }
}
