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
        // Custom headers (ToskaHeader) expose a "back" button; tap it even when XCUITest
        // thinks it isn't hittable. The edge-swipe fallback is a last resort only: a
        // synthetic interactive-pop gesture followed by tab taps left SwiftUI animating
        // and XCUITest waiting for idle (2026-11-04 tour, not an app issue).
        let byLabel = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label CONTAINS[c] %@", "back", "back")).firstMatch
        if byLabel.waitForExistence(timeout: 3) { forceTap(byLabel); sleep(2); return }
        if app.navigationBars.buttons.firstMatch.exists { forceTap(app.navigationBars.buttons.firstMatch); sleep(2); return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 0)))
        sleep(3)
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
        // A restored session whose account was deleted (previous seed cleaned up) lands on
        // "setting up your account" — go back to login first.
        let backToLogin = app.buttons["back to login"]
        if backToLogin.waitForExistence(timeout: 4) { forceTap(backToLogin); sleep(2) }
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
        XCTAssertTrue(waitFor(app.buttons["for you"], 90), "Feed didn't load")
        // The keychain "Save Password?" sheet can also land AFTER the feed; clear it again.
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
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
    /// Compose-hang diagnostic (2026-11-04): tap "write" from the tab bar, then stay OFF the accessibility
    /// tree for 90 s so a host-side `sample` can show what the app's main thread is doing. Screenshots are
    /// taken from the host (simctl) during that window; this test only asserts that the app survives.
    func test06_composeOpenHold() {
        launch(night: false); signInIfNeeded("compose")
        sleep(2); tapBar(0.50)
        sleep(90)
        snap("compose-after-90s")
        _ = tapIf(app.buttons["cancel"], 10)
    }
    /// Bottom-inset check (2026-11-04): scroll each top-level screen to its very end and screenshot,
    /// so the last row's relation to the floating tab bar is visible. Needs an account with ≥ 8 posts.
    func test07_scrollToBottoms() {
        launch(night: false); signInIfNeeded("inset")
        func toBottom(_ name: String) { for _ in 0..<8 { app.swipeUp(); usleep(350_000) }; sleep(1); snap("inset-\(name)-bottom") }
        toBottom("feed")
        tapBar(0.30); toBottom("trending")
        tapBar(0.70); toBottom("notifications")
        tapBar(0.85); toBottom("profile-posts")
        if tapIf(app.buttons["liked"], 3) { sleep(2); toBottom("profile-liked") }
        if tapIf(app.buttons["replies"], 3) { sleep(2); toBottom("profile-replies") }
        tapBar(0.15); scrollToTop(8)
        if tapIf(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "what others said")).firstMatch, 4) { sleep(3); toBottom("prompt-responses"); back() }
    }
    /// Build 120 checks (2026-11-04): own-post repost tap shows the gentle notice (feed row + detail), the feed's prompt
    /// card top padding is intact, the profile survives slow diagonal drags without jumping to the top, and the
    /// prompt responses screen shows its empty state with a "write yours" button on a day with no answers.
    func test08_build120() {
        launch(night: false); signInIfNeeded("b120")
        snap("b120-01-feed-top")
        let handle = ProcessInfo.processInfo.environment["TOSKA_TOUR_HANDLE"] ?? ""
        let notNowLate = app.buttons["Not Now"]; if notNowLate.waitForExistence(timeout: 3) { notNowLate.tap() }
        // FEED: my own row's repost count ("N reposts" / "1 repost"; the profile tab is just "reposts")
        let statPred = NSPredicate(format: "label MATCHES %@", "^[0-9]+ reposts?$")
        let feedStat = app.buttons.matching(statPred).firstMatch
        if feedStat.waitForExistence(timeout: 6) { feedStat.tap(); usleep(350_000); snap("b120-02a-feed-own-repost-notice") }
        sleep(3)
        if app.buttons["back"].exists { back() }
        // PROFILE: slow diagonal drags on the list first (screenshots along the way), then the own-row tap
        tapBar(0.85); sleep(2)
        if notNowLate.waitForExistence(timeout: 2) { notNowLate.tap() }
        for i in 0..<4 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 12, dy: -420)))
            usleep(900_000); snap("b120-03-profile-drag-\(i)")
        }
        sleep(2); snap("b120-04-profile-settled")
        scrollToTop(4)
        let repostStat = app.buttons.matching(statPred).firstMatch
        if repostStat.waitForExistence(timeout: 6) { repostStat.tap(); usleep(350_000); snap("b120-02-profile-own-repost-notice") }
        sleep(3)
        if app.buttons["back"].waitForExistence(timeout: 1) { back(); sleep(1) }
        // open my own post → detail → tap the repost count
        if let row = findRow(containing: "b120:") { forceTap(row); sleep(3)
            let d = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ reposts?$")).firstMatch
            if d.waitForExistence(timeout: 5) { forceTap(d); usleep(700_000); snap("b120-05-detail-own-repost-notice") }
            back(); sleep(1) }
        // prompt responses empty state
        tapBar(0.15); scrollToTop(8)
        if tapIf(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "what others said")).firstMatch, 4) { sleep(4); snap("b120-06-prompt-responses-empty"); back() }
        _ = handle
    }
    func test05_trendingOnly() {
        launch(night: false); signInIfNeeded("trend")
        tapBar(0.30); snap("trend-01-today"); dump("trend-ax")
        if tapIf(app.buttons["this week"], 3) { sleep(3); snap("trend-02-week") }
        if tapIf(app.buttons["all time"], 3) { sleep(3); snap("trend-03-alltime") }
        app.swipeDown(); sleep(3); snap("trend-04-after-pull")
    }
    func test04_night_rest() { launch(night: true); tour2("night") }
    /// Feed scroll depth (build 121, owner 2026-11-04: "the feed also feels stuck"): flick / drag the for-you
    /// feed and log the topmost visible row after every pass — a pass whose top row doesn't move is a stall.
    /// Runs until "no more posts to show" is on screen or the pass budget is spent. Then the same on most felt.
    func test10_feedDepth() {
        launch(night: false); signInIfNeeded("fdepth")
        let notNowLate = app.buttons["Not Now"]; if notNowLate.waitForExistence(timeout: 3) { notNowLate.tap() }
        var log = ""
        func topRow() -> String {
            // firstMatch = topmost row in hierarchy order; one query per pass (enumerating every
            // staticText on a 150-post feed took minutes per pass and timed the driver out).
            let t = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "b121")).firstMatch
            guard t.exists else { return "none" }
            return String(t.label.prefix(12)).replacingOccurrences(of: "\n", with: " ") + "@y\(Int(t.frame.minY))"
        }
        func flush(_ phase: String) { let a = XCTAttachment(string: log); a.name = "fdepth-log-\(phase)"; a.lifetime = .keepAlways; add(a) }
        func run(_ name: String, passes: Int, endLabel: String, move: () -> Void) {
            var prev = topRow(); var stalls = 0; var ended = -1
            log += "\(name) start: top=\(prev)\n"
            for i in 1...passes {
                move(); usleep(900_000)
                let now = topRow()
                let end = app.staticTexts[endLabel]
                let endVisible = end.exists && end.frame.minY < app.frame.height - 60 && end.frame.minY > 0
                if now == prev { stalls += 1; log += "\(name) \(i): STALL top=\(now)\n"; snap("fdepth-\(name)-stall-\(i)") }
                else { log += "\(name) \(i): top=\(now)\n" }
                if i % 8 == 0 { snap("fdepth-\(name)-\(i)") }
                if endVisible { ended = i; snap("fdepth-\(name)-end-\(i)"); break }
                prev = now
            }
            log += "\(name): ended=\(ended) stalls=\(stalls)\n"; flush(name)
        }
        // FEED — flicks, then slow drags, then diagonal drags (sideways drift like a thumb)
        run("flick", passes: 30, endLabel: "no more posts to show") { self.app.swipeUp() }
        tapBar(0.15); scrollToTop(14); sleep(1)
        run("drag", passes: 30, endLabel: "no more posts to show") {
            let s = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            s.press(forDuration: 0.08, thenDragTo: s.withOffset(CGVector(dx: 8, dy: -520)))
        }
        tapBar(0.15); scrollToTop(14); sleep(1)
        run("diag120", passes: 30, endLabel: "no more posts to show") {
            let s = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            s.press(forDuration: 0.08, thenDragTo: s.withOffset(CGVector(dx: -120, dy: -450)))
        }
        let followingVisible = app.staticTexts["follow someone to see their words here"]
        log += "after diag: following empty-state on screen=\(followingVisible.exists && followingVisible.frame.minX >= 0 && followingVisible.frame.minX < app.frame.width - 10)\n"
        snap("fdepth-feed-final")
        // MOST FELT — flicks + diagonal on "today"
        tapBar(0.30); sleep(3); snap("fdepth-top-start")
        run("top-flick", passes: 12, endLabel: "—no-end—") { self.app.swipeUp() }
        scrollToTop(8); sleep(1)
        run("top-diag120", passes: 12, endLabel: "—no-end—") {
            let s = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            s.press(forDuration: 0.08, thenDragTo: s.withOffset(CGVector(dx: -120, dy: -450)))
        }
        snap("fdepth-top-final")
        let a = XCTAttachment(string: log); a.name = "fdepth-log"; a.lifetime = .keepAlways; add(a)
    }
    /// Build 121 safeguard (owner 2026-11-05): the kept-alive hidden column must be out of the accessibility
    /// tree (accessibilityHidden), so VoiceOver / the accessibility inspector only see the visible column.
    /// XCUITest reads the same accessibility tree, so hidden content must not resolve here at all.
    func test12_hiddenColumnsAccessibility() {
        launch(night: false); signInIfNeeded("a11y")
        let notNowLate = app.buttons["Not Now"]; if notNowLate.waitForExistence(timeout: 3) { notNowLate.tap() }
        let followingEmpty = app.staticTexts["follow someone to see their words here"]
        let promptCard = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "what others said")).firstMatch
        var log = ""
        // FEED — for you visible: prompt card present, following's empty state absent
        log += "for-you: promptCard=\(promptCard.exists) followingEmpty=\(followingEmpty.exists)\n"
        XCTAssertFalse(followingEmpty.exists, "following column leaks into the tree while for-you is shown")
        // switch to following (empty for this account) and back
        XCTAssertTrue(tapIf(app.buttons["following"], 4)); sleep(2); snap("a11y-01-following")
        log += "following: promptCard=\(promptCard.exists) followingEmpty=\(followingEmpty.exists)\n"
        XCTAssertTrue(followingEmpty.waitForExistence(timeout: 4), "following empty state should be visible")
        XCTAssertFalse(promptCard.exists, "for-you column (prompt card) leaks into the tree while following is shown")
        XCTAssertTrue(tapIf(app.buttons["for you"], 4)); sleep(2); snap("a11y-02-for-you-again")
        log += "for-you again: promptCard=\(promptCard.exists) followingEmpty=\(followingEmpty.exists)\n"
        XCTAssertTrue(promptCard.waitForExistence(timeout: 4)); XCTAssertFalse(followingEmpty.exists)
        // MOST FELT — visit all three periods; each column's empty state / list must only resolve while shown
        tapBar(0.30); sleep(3)
        let quiet = app.staticTexts["everyone is being quiet right now."]
        func periodState(_ name: String) -> String {
            let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "0")).count // "01", "02"… rank labels
            return "\(name): emptyStates=\(quiet.exists ? app.staticTexts.matching(NSPredicate(format: "label == %@", "everyone is being quiet right now.")).count : 0) rankLabels=\(rows)"
        }
        log += periodState("today") + "\n"
        for p in ["this week", "all time", "today"] {
            XCTAssertTrue(tapIf(app.buttons[p], 4)); sleep(3); snap("a11y-top-\(p.replacingOccurrences(of: " ", with: "-"))")
            let st = periodState(p); log += st + "\n"
            // Never more than ONE period's empty state in the tree, whichever periods are empty.
            XCTAssertLessThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "everyone is being quiet right now.")).count, 1, "hidden most-felt column leaks into the tree on \(p)")
        }
        let a = XCTAttachment(string: log); a.name = "a11y-log"; a.lifetime = .keepAlways; add(a)
    }
    /// Build 122: share / report / block / context menu still work from rows after the per-row covers and
    /// dialogs moved to the single app-level RowPresenter — feed, search, profile, most felt → detail, detail.
    func test13_rowActions() {
        launch(night: false); signInIfNeeded("rowact")
        let notNowLate = app.buttons["Not Now"]; if notNowLate.waitForExistence(timeout: 3) { notNowLate.tap() }
        var log = ""
        let reportTitle = app.staticTexts["why are you reporting this?"]
        func dismissReport() { if !tapIf(app.buttons["cancel"].firstMatch, 2) { if !tapIf(app.buttons["back"].firstMatch, 2) { back() } }; sleep(1) }
        func longPress(_ e: XCUIElement) {
            // Coordinate press: XCUITest refuses press() on a row it deems not hittable (NavigationLink label).
            e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        }
        func checkMenu(on row: XCUIElement, where name: String) {
            longPress(row); sleep(1); snap("rowact-\(name)-menu")
            let hasReport = app.buttons["report"].firstMatch.waitForExistence(timeout: 3)
            let blockBtn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "block ")).firstMatch
            log += "\(name): menu report=\(hasReport) block=\(blockBtn.exists) share=\(app.buttons["share"].firstMatch.exists) felt=\(app.buttons["felt this"].exists || app.buttons["unlike"].exists)\n"
            if hasReport {
                app.buttons["report"].firstMatch.tap()
                let ok = reportTitle.waitForExistence(timeout: 5); log += "\(name): report sheet=\(ok)\n"; snap("rowact-\(name)-report")
                XCTAssertTrue(ok, "report sheet did not open from \(name)"); dismissReport()
                longPress(row); sleep(1)
                if blockBtn.waitForExistence(timeout: 3) {
                    blockBtn.tap()
                    let dlg = app.buttons["block"].firstMatch.waitForExistence(timeout: 4); log += "\(name): block dialog=\(dlg)\n"; snap("rowact-\(name)-block")
                    XCTAssertTrue(dlg, "block dialog did not open from \(name)"); _ = tapIf(app.buttons["cancel"].firstMatch, 3); sleep(1)
                }
                longPress(row); sleep(1)
                if app.buttons["share"].firstMatch.waitForExistence(timeout: 2) {
                    app.buttons["share"].firstMatch.tap()
                    let sc = app.buttons["Close"].firstMatch.waitForExistence(timeout: 5); log += "\(name): share card=\(sc)\n"; snap("rowact-\(name)-share")
                    XCTAssertTrue(sc, "share card did not open from \(name)"); _ = tapIf(app.buttons["Close"].firstMatch, 3); sleep(1)
                } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); sleep(1) }
            } else if app.buttons["share"].firstMatch.exists {
                // Own rows: no report/block, but share must still open the card from the app-level host.
                // (Two "share" buttons can be on screen — the menu item and the action bar — hence firstMatch.)
                app.buttons["share"].firstMatch.tap()
                let sc = app.buttons["Close"].firstMatch.waitForExistence(timeout: 5); log += "\(name): share card=\(sc)\n"; snap("rowact-\(name)-share")
                XCTAssertTrue(sc, "share card did not open from \(name)"); _ = tapIf(app.buttons["Close"].firstMatch, 3); sleep(1)
            } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); sleep(1) }
        }
        // FEED — a row by another author (seeded "b122 w")
        if let row = findRow(containing: "b122 w") { checkMenu(on: row, where: "feed") } else { log += "feed: no w row found\n" }
        // SEARCH — header search, query the seeded text
        tapBar(0.15); scrollToTop(8)
        if tapIf(app.buttons["Search"], 3) {
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 3) { field.tap(); field.typeText("b122 w\n"); sleep(3); snap("rowact-search")
                if let row = findRow(containing: "b122 w", swipes: 2) { checkMenu(on: row, where: "search") } else { log += "search: no row\n" }
                _ = tapIf(app.buttons["cancel"].firstMatch, 2); _ = tapIf(app.buttons["Clear search"].firstMatch, 1)
            }
        }
        // PROFILE — own rows: context menu opens (felt/save), no report/block by design
        tapBar(0.85); sleep(2)
        if let row = findRow(containing: "b122 #", swipes: 2) { checkMenu(on: row, where: "profile-own") }
        // MOST FELT → detail → detail's own report
        tapBar(0.30); sleep(3); _ = tapIf(app.buttons["all time"], 3); sleep(3)
        let firstRank = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "felt this")).firstMatch
        if firstRank.waitForExistence(timeout: 4) { forceTap(firstRank); sleep(3); snap("rowact-top-detail")
            if tapIf(app.buttons["report"], 3) { let ok = reportTitle.waitForExistence(timeout: 5); log += "detail(from most felt): report sheet=\(ok)\n"; XCTAssertTrue(ok); dismissReport() }
            else { log += "detail(from most felt): no direct report button (menu-based)\n" }
            back(); sleep(1)
        }
        let a = XCTAttachment(string: log); a.name = "rowact-log"; a.lifetime = .keepAlways; add(a)
    }
    /// Quick probe (build 121): does the profile's tab selector pin under the header after scrolling?
    func test11_profilePinProbe() {
        launch(night: false); signInIfNeeded("pin")
        let notNowLate = app.buttons["Not Now"]; if notNowLate.waitForExistence(timeout: 3) { notNowLate.tap() }
        tapBar(0.85); sleep(3); snap("pin-00-top")
        app.swipeUp(); sleep(2); snap("pin-01-after-1-flick")
        let sel = app.buttons["liked"]
        var log = "after 1 flick: liked tab buttons=\(app.buttons.matching(identifier: "liked").count) exists=\(sel.exists) y=\(sel.exists ? Int(sel.frame.minY) : -1)\n"
        app.swipeUp(); app.swipeUp(); sleep(2); snap("pin-02-after-3-flicks")
        log += "after 3 flicks: liked tab buttons=\(app.buttons.matching(identifier: "liked").count) exists=\(sel.exists) y=\(sel.exists ? Int(sel.frame.minY) : -1)\n"
        // Pinned selector sits just under the header (y ≈ 118 on a 15 Pro Max); unpinned it would be off screen.
        XCTAssertTrue(sel.exists && sel.frame.minY > 0 && sel.frame.minY < 400, "tab selector not pinned after scrolling")
        forceTap(sel); sleep(2); snap("pin-03-tapped-felt-while-pinned")
        let a = XCTAttachment(string: log); a.name = "pin-log"; a.lifetime = .keepAlways; add(a)
    }
    /// Profile scroll depth (build 121 diagnosis, 2026-11-04): with a 30-post account, count how many swipes
    /// (fast flicks, then slow drags) it takes until the LAST post ("b121-LAST") is on screen and hittable.
    /// A healthy list reaches it in ~6–8 flicks and never loses ground; the owner's phone needed many
    /// up-and-down passes. Also records the list's reported frame after each pass.
    func test09_profileDepth() {
        launch(night: false); signInIfNeeded("depth")
        let notNowLate = app.buttons["Not Now"]; if notNowLate.waitForExistence(timeout: 3) { notNowLate.tap() }
        tapBar(0.85); sleep(3)
        if notNowLate.waitForExistence(timeout: 2) { notNowLate.tap() }
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "b121-LAST")).firstMatch
        var log = ""
        func status(_ tag: String) {
            // Cheap: one query for the marker row (no hierarchy enumeration, no isHittable — with the
            // build-121 eager list every row is in the tree and per-element round-trips took minutes).
            let ex = last.exists
            let fr = ex ? last.frame : .zero
            // Topmost visible post number via firstMatch (hierarchy order == list order).
            let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "b121 #", last.label)).firstMatch
            let topLabel = first.exists ? String(first.label.prefix(9)) + "@y\(Int(first.frame.minY))" : "none"
            log += "\(tag): first=\(topLabel) last exists=\(ex) frameY=\(Int(fr.minY)) maxY=\(Int(fr.maxY)) screenH=\(Int(app.frame.height))\n"
        }
        func flush(_ phase: String) { let a = XCTAttachment(string: log); a.name = "depth-log-\(phase)"; a.lifetime = .keepAlways; add(a) }
        status("start")
        var reachedFlick = -1
        for i in 1...14 {
            app.swipeUp(); usleep(900_000); status("flick \(i)")
            if i == 4 || i == 8 || i == 12 { snap("depth-flick-\(i)") }
            if reachedFlick < 0, last.exists, last.frame.maxY < app.frame.height - 100, last.frame.minY > 300 { reachedFlick = i; snap("depth-flick-reached-\(i)"); break }
        }
        log += "REACHED by flick after: \(reachedFlick)\n"
        snap("depth-flick-end"); flush("flick")
        scrollToTop(12); sleep(1); status("after scroll to top")
        var reachedDrag = -1
        for i in 1...24 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.08, thenDragTo: start.withOffset(CGVector(dx: 8, dy: -520)))
            usleep(500_000); status("drag \(i)")
            if i % 6 == 0 { snap("depth-drag-\(i)") }
            if reachedDrag < 0, last.exists, last.frame.maxY < app.frame.height - 100, last.frame.minY > 300 { reachedDrag = i; snap("depth-drag-reached-\(i)"); break }
        }
        log += "REACHED by drag after: \(reachedDrag)\n"
        snap("depth-drag-end"); flush("drag")
        // Diagonal drags — a thumb drifts sideways; does the horizontal pager steal the gesture (page flips to
        // "felt", or the vertical scroll is cancelled and the list stops short)?
        for (dx, name) in [(90, "diag90"), (160, "diag160")] {
            scrollToTop(12); sleep(1)
            if tapIf(app.buttons["posts"], 2) { sleep(1) }
            status("\(name) start")
            var reached = -1
            for i in 1...16 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                start.press(forDuration: 0.08, thenDragTo: start.withOffset(CGVector(dx: -dx, dy: -450)))
                usleep(500_000); status("\(name) \(i)")
                // The felt page exists in the lazy pager as soon as it's a neighbour; only an ON-SCREEN frame means a flip.
                let feltEmpty = app.staticTexts["nothing felt yet."]
                if feltEmpty.exists, feltEmpty.frame.minX >= 0, feltEmpty.frame.minX < app.frame.width - 10 {
                    log += "\(name) \(i): PAGE FLIPPED to felt (x=\(Int(feltEmpty.frame.minX)))\n"; snap("depth-\(name)-flipped-\(i)")
                    if tapIf(app.buttons["posts"], 2) { sleep(1) }; continue
                }
                if i % 5 == 0 { snap("depth-\(name)-\(i)") }
                if reached < 0, last.exists, last.frame.maxY < app.frame.height - 100 { reached = i; snap("depth-\(name)-reached-\(i)"); break }
            }
            log += "REACHED by \(name) after: \(reached)\n"; flush(name)
        }
        let a = XCTAttachment(string: log); a.name = "depth-log"; a.lifetime = .keepAlways; add(a)
    }
}
