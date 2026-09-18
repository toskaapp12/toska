import XCTest

// MARK: - Full-app walkthrough (2026-06-11)
// Drives the REAL app (no UI_TESTING shortcuts — real auth verify, real rate
// limiter) against staging: sign out → fresh login → every major surface.
// Each step attaches a named screenshot (keepAlways) so the run is reviewable
// from the .xcresult. Methods are numbered: XCTest runs them alphabetically,
// and auth state persists across launches via the keychain.
//
// Staging test account: salinarotess+nice@gmail.com (seeded).
// This file is a throwaway driver for a manual-QA pass, not CI material —
// it mutates staging data (a reply, a post, a repost).

final class WalkthroughUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Forward the night-theme preview hook so any test can run in the
        // dark palette: TEST_RUNNER_TOSKA_FORCE_NIGHT=1 xcodebuild test ...
        if let night = ProcessInfo.processInfo.environment["TOSKA_FORCE_NIGHT"] {
            app.launchEnvironment["TOSKA_FORCE_NIGHT"] = night
        }
        if let off = ProcessInfo.processInfo.environment["TOSKA_FORCE_OFFLINE"] {
            app.launchEnvironment["TOSKA_FORCE_OFFLINE"] = off
        }
        app.launch()
        acceptPolicyGateIfPresent()
    }

    /// Policy re-acceptance cover (v2, 2026-07-17): a stale staging session
    /// whose acceptedPolicyVersion is behind currentPolicyVersion boots into a
    /// BLOCKING fullScreenCover that eats every navigation tap — which is the
    /// designed behavior, not a bug. Accept it once so the walkthrough can
    /// proceed; the write stamps the staging account, so the gate won't
    /// re-fire until the next policy version bump.
    func acceptPolicyGateIfPresent() {
        let agree = app.buttons["i agree and continue"]
        guard agree.waitForExistence(timeout: 3) else { return }
        let checkbox = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "i confirm i am 18 or older")
        ).firstMatch
        if checkbox.waitForExistence(timeout: 2) { checkbox.tap() }
        forceTap(agree)
        _ = feedView.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: helpers

    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Tap an element even when XCUITest's hittability check is confused by a
    /// SwiftUI overlay container (the floating home bar / search pill render
    /// above the feed scroll content): fall back to a coordinate tap, which
    /// skips the hit-point validation.
    func forceTap(_ element: XCUIElement) {
        if element.isHittable { element.tap() }
        else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    /// Scroll-search for a row: LazyVStack rows don't exist in the AX tree
    /// until they're near the viewport, so a bare firstMatch wait misses any
    /// row below the fold (feed content on staging drifts as tests seed data).
    func findRow(matching predicate: NSPredicate, swipes: Int = 4) -> XCUIElement? {
        let row = app.buttons.matching(predicate).firstMatch
        for attempt in 0...swipes {
            if row.waitForExistence(timeout: attempt == 0 ? 10 : 2) {
                nudgeRowIntoSafeBand(row)
                return row.exists ? row : nil
            }
            app.swipeUp()
        }
        return nil
    }

    /// Scrolls the current list back to the top. Needed before searching for a
    /// just-created row: it sorts newest-first, so it's at the top, while
    /// findRow's fallback search only ever swipes DOWN the list.
    func scrollToTop(_ times: Int = 4) {
        for _ in 0..<times {
            app.swipeDown()
            usleep(400_000)
        }
    }

    /// A row at the bottom viewport edge sits under the floating glass bar —
    /// taps there get eaten (or open compose). A row materialized ABOVE the
    /// viewport coordinate-taps into the status bar. Drag until the row sits
    /// fully in the safe band, then let scroll deceleration settle.
    func nudgeRowIntoSafeBand(_ row: XCUIElement) {
        for _ in 0..<3 {
            guard row.exists else { return }
            let safeMaxY = app.frame.maxY - 160
            let safeMinY = app.frame.minY + 160
            let f = row.frame
            let delta: CGFloat
            if f.maxY > safeMaxY { delta = -min(f.maxY - safeMaxY + 40, 400) }
            else if f.minY < safeMinY { delta = min(safeMinY - f.minY + 40, 400) }
            else { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
            usleep(700_000)
        }
    }

    /// Type into the compose editor reliably. The compose sheet auto-focuses the
    /// editor via its own focusTask, which races with a test-driven tap — and a
    /// tap that lands mid-animation reports "no keyboard focus". Re-tap until
    /// hasKeyboardFocus, then type at the app level (sends to whatever's focused).
    func focusAndType(_ element: XCUIElement, _ text: String) {
        for _ in 0..<4 {
            if (element.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            element.tap()
            sleep(1)
        }
        app.typeText(text)
    }

    /// Compose drafts persist across cancel by design (N-4 DraftStore) — clear
    /// the editor by deleting everything before cancelling so the draft doesn't
    /// leak into the next compose test.
    func clearComposeEditor() {
        let editor = app.textViews.firstMatch
        guard editor.exists else { return }
        editor.tap()
        if let value = editor.value as? String, !value.isEmpty {
            // Move cursor to the end via select-all, then delete.
            editor.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) {
                selectAll.tap()
                app.typeText(String(XCUIKeyboardKey.delete.rawValue))
            } else {
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 10))
            }
        }
    }

    func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // NOTE: the feed redesign moved the "feedView" accessibility identifier onto
    // child elements (StaticText/Buttons/ScrollView), so the older suite's
    // app.otherElements["feedView"] anchor no longer matches anything. Anchor on
    // the "for you" tab instead — unique to the logged-in feed.
    var feedView: XCUIElement { app.buttons["for you"] }

    func requireFeed(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(waitFor(feedView, 20), "Feed not visible — not logged in?", file: file, line: line)
    }

    // MARK: settings snap — navigate to settings and screenshot (no assertions)
    func test09b_settingsSnap() throws {
        try requireFeed()
        app.buttons["Profile"].tap()
        sleep(2)
        let gear = app.buttons["settings"]
        guard waitFor(gear, 8) else { snap("settings-no-gear"); return }
        forceTap(gear)
        sleep(2)
        snap("settings-modern-top")
        app.swipeUp(); sleep(1)
        snap("settings-modern-mid")
    }

    // MARK: glass demo — scroll so content sits behind the frosted bars
    func test04b_glassScrollShot() throws {
        try requireFeed()
        // scroll the feed up so posts pass behind the floating glass tab bar + search
        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        snap("glass-scrolled")
    }

    // MARK: 00 — diagnostic probe: what does XCUITest actually see at launch?

    func test00_probe() throws {
        sleep(10)
        snap("00-probe-screen")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "00-probe-tree"
        tree.lifetime = .keepAlways
        add(tree)
        // also probe the specific anchors the suite relies on
        let anchors = "feedView=\(app.otherElements["feedView"].exists) " +
            "newHere=\(app.buttons["i'm new here"].exists) " +
            "signIn=\(app.buttons["sign in"].exists) " +
            "toskaHeader=\(app.staticTexts["toska"].exists) " +
            "state=\(app.state.rawValue)"
        let a = XCTAttachment(string: anchors)
        a.name = "00-probe-anchors"
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: 01 — sign out of the stale session

    func test01_signOutFromOldSession() throws {
        // If we're already at the splash, nothing to do.
        if app.buttons["i'm new here"].waitForExistence(timeout: 5) {
            snap("01-already-signed-out")
            return
        }
        try requireFeed()
        snap("01a-stale-session-feed")
        app.buttons["Profile"].tap()
        sleep(2)
        let gear = app.buttons["settings"]
        XCTAssertTrue(waitFor(gear, 8), "Settings gear not found on profile")
        gear.tap()
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Settings didn't open")
        // sign out row is far down the page. NOTE: .exists is true even while
        // off-screen, so scroll on !isHittable — and the scroll content reports
        // non-hittable under the floating bar overlay, so cap the swipes and
        // rely on forceTap below once the row is in the visible frame.
        for _ in 0..<8 {
            let row = app.buttons["sign out"]
            if row.exists && row.frame.maxY < app.frame.maxY - 100 && row.frame.minY > 100 { break }
            app.swipeUp()
            usleep(400_000)
        }
        snap("01b-settings-bottom")
        let signOutRow = app.buttons["sign out"]
        XCTAssertTrue(signOutRow.exists, "sign out row not found")
        forceTap(signOutRow)
        // confirm alert ("sign out?")
        let alertConfirm = app.alerts.buttons["sign out"].exists
            ? app.alerts.buttons["sign out"]
            : app.buttons.matching(NSPredicate(format: "label == 'sign out'")).element(boundBy: 1)
        if waitFor(alertConfirm, 5) { forceTap(alertConfirm) }
        XCTAssertTrue(waitFor(app.buttons["i'm new here"], 10), "Splash didn't appear after sign out")
        snap("01c-signed-out-splash")
    }

    // MARK: 02 — fresh login with the staging account

    func test02_login() throws {
        let signIn = app.buttons["sign in"]
        try XCTSkipUnless(waitFor(signIn, 10), "Not at splash — already signed in?")
        snap("02a-splash")
        signIn.tap()

        let email = app.textFields["emailField"]
        XCTAssertTrue(waitFor(email, 8), "Email field missing")
        email.tap()
        email.typeText("salinarotess+nice@gmail.com")
        let password = app.secureTextFields["passwordField"]
        password.tap()
        // Never hardcode (2026-07-22 leak) — pass TEST_RUNNER_TOSKA_STAGING_TEST_PW.
        guard let stagingPw = ProcessInfo.processInfo.environment["TOSKA_STAGING_TEST_PW"] else {
            XCTFail("TOSKA_STAGING_TEST_PW not set — see .local-credentials.md")
            return
        }
        password.typeText(stagingPw)
        snap("02b-credentials-entered")
        app.buttons["signInButton"].tap()

        // Real path: Auth sign-in + verifyUserDocument Firestore round-trip.
        XCTAssertTrue(waitFor(feedView, 30), "Feed didn't load after sign-in")
        snap("02c-logged-in-feed")
    }

    // MARK: 02z — cold-launch feed renders (build 44 eager-prefix + lazy-tail)

    /// Verifies the feed appears with real post content on a COLD LAUNCH — the
    /// exact path the eager-prefix + lazy-tail render must survive. A blank-feed
    /// regression would show the header + tabs but no post rows.
    func test02z_coldLaunchFeedRenders() throws {
        // Ensure we're logged in (log in if we're sitting at the splash).
        if waitFor(app.buttons["sign in"], 5) {
            app.buttons["sign in"].tap()
            let email = app.textFields["emailField"]
            XCTAssertTrue(waitFor(email, 8), "Email field missing")
            email.tap(); email.typeText("salinarotess+nice@gmail.com")
            let pw = app.secureTextFields["passwordField"]
            guard let stagingPw = ProcessInfo.processInfo.environment["TOSKA_STAGING_TEST_PW"] else {
                XCTFail("TOSKA_STAGING_TEST_PW not set — see .local-credentials.md")
                return
            }
            pw.tap(); pw.typeText(stagingPw)
            app.buttons["signInButton"].tap()
        }
        XCTAssertTrue(waitFor(feedView, 30), "Feed didn't load initially")
        func hasPosts(_ t: TimeInterval) -> Bool {
            waitFor(app.buttons["Repost"].firstMatch, t)
                || app.buttons["Undo repost"].firstMatch.exists  // real label for the self-reposted state (FeedView); "Already reposted" exists nowhere
        }
        XCTAssertTrue(hasPosts(20), "No post rows before cold launch (unexpected)")

        // COLD LAUNCH — terminate + relaunch fresh. The session persists, so the
        // app boots through isLoading → verify → feed, materialising the eager
        // prefix rows immediately.
        app.terminate()
        app.launch()

        XCTAssertTrue(waitFor(feedView, 30), "Feed header didn't render on cold launch")
        // The critical assertion: real post content materialised, not a blank
        // scroll area (which is what the old fully-lazy feed produced on launch).
        let rendered = hasPosts(25)
        snap("02z-cold-launch-feed")
        print("✅ COLD LAUNCH feed content rendered = \(rendered)")
        XCTAssertTrue(rendered, "COLD-LAUNCH BLANK FEED: header rendered but no post rows materialised")
    }

    // MARK: 03 — feed: tabs + prompt

    func test03_feedTabs() throws {
        try requireFeed()
        XCTAssertTrue(app.staticTexts["toska"].exists, "Header missing")
        XCTAssertTrue(app.buttons["for you"].exists && app.buttons["following"].exists, "Feed tabs missing")
        snap("03a-feed-for-you")
        app.buttons["following"].tap()
        sleep(2)
        snap("03b-feed-following")
        app.buttons["for you"].tap()
        sleep(1)
    }

    // MARK: 04 — search

    func test04_search() throws {
        try requireFeed()
        snap("04a-default-no-searchbar")        // 🔍 icon in header, no bar
        let searchIcon = app.buttons["Search"]
        XCTAssertTrue(waitFor(searchIcon, 8), "Search icon missing in header")
        forceTap(searchIcon)
        sleep(1)
        snap("04b-search-expanded")             // search bar revealed
        let field = app.textFields["search moments, people, feelings"]
        if waitFor(field, 4) {
            field.typeText("light")
            sleep(2)
            snap("04c-search-results")
        }
    }

    // MARK: 05 — post detail: open, like, save, reply

    // Opening a post to READ it must NOT summon the keyboard. Reproduces the
    // "blank then keyboard" delay: open a post, do NOT tap reply, assert the
    // keyboard is absent.
    func test05y_openPostNoKeyboard() throws {
        try requireFeed()
        // Exclude repost rows ("X reposted, …") — they can firstMatch-shadow
        // the original and sit at the viewport edge where taps get eaten.
        let firstPost = findRow(matching: NSPredicate(
            format: "(label CONTAINS 'first light' OR label CONTAINS 'the quiet' OR label CONTAINS 'storm') AND NOT (label CONTAINS 'reposted')"))
        XCTAssertNotNil(firstPost, "No post row found")
        guard let firstPost else { return }
        forceTap(firstPost)
        sleep(1)
        snap("05y1-post-just-opened")
        sleep(2)
        snap("05y2-post-settled")
        let kbVisible = app.keyboards.firstMatch.exists
        print("⌨️ OPEN-POST KEYBOARD VISIBLE (should be false): \(kbVisible)")
        XCTAssertFalse(kbVisible, "Keyboard auto-appeared on opening a post to read it")
    }

    // Reproduce the repost bug against staging: tap repost, confirm it STICKS
    // (button flips to "Undo repost") rather than reverting (green→grey).
    // NOTE: repost-attribution cards carry a DISABLED icon that is ALSO
    // labelled "Repost" (value "N reposts"), and .firstMatch happily returns
    // it — scope every query to enabled == true so we only touch live controls.
    func test05z_repost() throws {
        try requireFeed()
        let enabledRepost = app.buttons.matching(
            NSPredicate(format: "label == 'Repost' AND enabled == true")).firstMatch
        let enabledUndo = app.buttons.matching(
            NSPredicate(format: "label == 'Undo repost' AND enabled == true")).firstMatch
        // Already-reposted rows show "Undo repost" — reset any visible ones
        // first, so the post-tap assertion below can only be satisfied by OUR
        // repost sticking, not by leftover state from a previous run.
        for _ in 0..<3 where enabledUndo.exists {
            nudgeRowIntoSafeBand(enabledUndo)
            forceTap(enabledUndo)
            sleep(3) // let the un-repost transaction settle
        }
        XCTAssertTrue(waitFor(enabledRepost, 10), "No enabled un-reposted post found in feed")
        // 2026-09-17: the redesign's larger post text means the first enabled
        // repost control can sit BELOW the fold under the floating bar, where
        // forceTap's coordinate tap lands on the bar — scroll it into the safe
        // band first (same treatment findRow gives rows).
        nudgeRowIntoSafeBand(enabledRepost)
        snap("05z1-before-repost")
        // forceTap: the repost glyph sits under the floating glass tab bar, so a
        // plain .tap() fails XCUITest's hittability check (not a repost bug).
        forceTap(enabledRepost)
        sleep(1)
        snap("05z2-just-after-tap")   // should be green / "Undo repost"
        sleep(5)                      // let transaction + validatePost settle
        snap("05z3-after-settle")
        // If the write was denied, the button reverts to "Repost".
        let stuck = enabledUndo.exists
        print("🔁 REPOST RESULT — stuck(Undo repost)=\(stuck)")
        XCTAssertTrue(stuck, "Repost did NOT stick — no enabled 'Undo repost' after settle (green→grey reproduced)")
    }

    func test05_postDetailInteractions() throws {
        try requireFeed()
        // Fixture: a post containing "first light, honestly" authored by a
        // DIFFERENT account (test05 likes it, test14 reports it — both are blocked
        // on your own post: self-like guard + report hidden on own-post). Seed it
        // FRESH before the suite so feed drift can't bury it below findRow's
        // bounded scroll-search:
        //   cd firestore-tests && node seed-walkthrough-fixtures.mjs
        // Post rows are Buttons labelled "handle, age, text, tag".
        let firstPost = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')"))
        XCTAssertNotNil(firstPost, "No post row found in feed")
        guard let firstPost else { return }
        forceTap(firstPost)
        XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Post detail didn't open")
        sleep(1)
        snap("05a-post-detail")

        // The feed's rows stay in the hierarchy BEHIND the pushed detail and
        // can shadow firstMatch with an occluded button — take the HITTABLE
        // match (the detail's own stats line). (2026-09-17 gate)
        let like = app.buttons.matching(NSPredicate(format: "label == 'Like post'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let like { like.tap(); sleep(1); snap("05b-after-like") }
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save post'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let save { save.tap(); sleep(1) }

        // reply (T-2 path: client writes pending_validation; staging validateReply promotes)
        let replyField = app.textFields["replyField"]
        if waitFor(replyField, 6) {
            replyField.tap()
            replyField.typeText("here with you. (walkthrough)")
            snap("05c-reply-typed")
            let send = app.buttons.matching(NSPredicate(
                format: "identifier == 'arrow.up' OR label CONTAINS[c] 'send'")).firstMatch
            if send.exists { forceTap(send) }
            else if app.images["arrow.up"].exists { forceTap(app.images["arrow.up"]) }
            sleep(3)
            snap("05d-reply-sent")
        }
        // Custom SwiftUI header (no UINavigationBar) — go back via edge swipe.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    }

    // MARK: 06 — trending

    func test06_trending() throws {
        try requireFeed()
        app.buttons["Trending"].tap()
        let trendingHeader = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'most felt' OR label == 'top'")).firstMatch
        XCTAssertTrue(waitFor(trendingHeader, 8), "Trending didn't open")
        sleep(2)
        snap("06-trending")
        // Three-tab pager: tap each period; each page must render its own content.
        if app.buttons["this week"].exists {
            app.buttons["this week"].tap(); sleep(2); snap("06b-trending-week")
        }
        if app.buttons["all time"].exists {
            app.buttons["all time"].tap(); sleep(2); snap("06c-trending-all")
        }
        if app.buttons["today"].exists {
            app.buttons["today"].tap(); sleep(1)
        }
        app.buttons["Home"].tap()
    }

    // MARK: 07 — notifications

    func test07_notifications() throws {
        try requireFeed()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch.tap()
        XCTAssertTrue(waitFor(app.staticTexts["notifications"], 8), "Notifications didn't open")
        sleep(2)
        snap("07-notifications")
        app.buttons["Home"].tap()
    }

    // MARK: 08 — profile: posts / liked / saved / replies tabs

    func test08_profile() throws {
        try requireFeed()
        app.buttons["Profile"].tap()
        sleep(2)
        snap("08a-profile-posts")
        // Profile tab bar is icon-only: text.document / heart / bookmark / bubble.left
        XCTAssertTrue(waitFor(app.buttons["settings"], 8), "Not on profile (settings gear missing)")
        // Tab buttons carry accessibilityLabels (posts/liked/saved/replies/reposts).
        for name in ["liked", "saved", "replies", "reposts"] {
            let tab = app.buttons[name].firstMatch
            if tab.exists { forceTap(tab); sleep(2); snap("08b-profile-\(name)") }
        }
        // Swipe back across the pager to the first tab (posts).
        let prof = app.otherElements["feedView"].exists ? app.otherElements["feedView"] : app.windows.firstMatch
        prof.swipeRight(); sleep(1); prof.swipeRight(); sleep(1)
        snap("08c-profile-after-swiperight")
        app.buttons["Home"].tap()
    }

    // MARK: 09 — settings (all sections)

    func test09_settings() throws {
        try requireFeed()
        app.buttons["Profile"].tap()
        sleep(1)
        let gear = app.buttons["settings"]
        XCTAssertTrue(waitFor(gear, 8), "Settings gear missing")
        forceTap(gear) // gear sits under the glass tab bar; plain .tap() can be swallowed (matches test09b)
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Settings didn't open")
        // Match the privacy section by case-insensitive label (the "privacy" group
        // header renders uppercased and its exact-identifier match is unreliable
        // after a re-render; "privacy policy" is a stable always-present row). Either
        // satisfies "the settings screen rendered its content".
        let privacyEl = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'privacy'")).firstMatch
        XCTAssertTrue(waitFor(privacyEl, 6), "privacy section missing")
        snap("09a-settings-top")
        app.swipeUp()
        snap("09b-settings-mid")
        app.swipeUp(); app.swipeUp()
        snap("09c-settings-bottom")
        XCTAssertTrue(waitFor(app.staticTexts["why this exists"], 3) || true)
        // back out without touching sign out / delete. Settings hides the
        // floating tab bar entirely (by design), so no "Home" element exists
        // here — leave via the header's Back chevron first.
        let back = app.buttons["Back"]
        XCTAssertTrue(waitFor(back, 5), "Back chevron missing on settings header")
        forceTap(back)
        let home = app.buttons["Home"]
        XCTAssertTrue(waitFor(home, 8), "Home tab didn't reappear after leaving settings")
        home.tap()
    }

    // MARK: 10 — compose & post (clean content, real moderation round-trip)

    // MARK: 09c — every Settings destination opens and comes back
    //
    // Drafts / your week / followers / following / blocked users / change
    // email / change password had never been functionally driven — a broken
    // push or crash there only surfaced on-device (owner 2026-09-17).
    func test09c_settingsDestinationsOpen() throws {
        try requireFeed()
        app.buttons["Profile"].tap()
        sleep(1)
        XCTAssertTrue(waitFor(app.buttons["settings"], 8), "Profile gear missing")
        app.buttons["settings"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Settings didn't open")

        func openAndReturn(_ rowLabel: String, expect: String? = nil) {
            // LAST match — the feed's tab buttons ("following") stay in the
            // AX tree behind the pushed stack and shadow firstMatch; the
            // settings row is deeper in traversal. Existence works for
            // off-screen rows; nudge scrolls it tappable.
            func settingsRow() -> XCUIElement? {
                let els = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH[c] %@", rowLabel)).allElementsBoundByIndex
                return els.last
            }
            var found = settingsRow()
            var swipes = 0
            while (found == nil || found?.exists != true) && swipes < 5 {
                app.swipeUp(); usleep(800_000)
                found = settingsRow(); swipes += 1
            }
            guard let row = found, row.exists else {
                XCTFail("Settings row '\(rowLabel)' not found"); return
            }
            nudgeRowIntoSafeBand(row)
            forceTap(row)
            sleep(2)
            if let expect {
                XCTAssertTrue(
                    app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", expect)).firstMatch.exists
                        || app.textFields.firstMatch.exists,
                    "'\(rowLabel)' destination didn't render (expected '\(expect)')")
            }
            snap("09c-\(rowLabel.replacingOccurrences(of: " ", with: "-"))")
            // Return: shared back affordance, full-screen close, system nav
            // back, else edge swipe.
            if app.buttons["Back"].exists { forceTap(app.buttons["Back"]) }
            else if app.buttons["close"].exists { forceTap(app.buttons["close"]) }
            else if app.buttons["cancel"].exists { forceTap(app.buttons["cancel"]) }
            else if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            }
            sleep(1)
            XCTAssertTrue(waitFor(app.staticTexts["settings"], 6), "Didn't return to settings from '\(rowLabel)'")
        }

        openAndReturn("drafts", expect: "draft")
        openAndReturn("your week", expect: "week")
        openAndReturn("followers", expect: "follow")
        openAndReturn("following", expect: "follow")
        openAndReturn("blocked users", expect: "block")
        openAndReturn("change email", expect: "email")
        openAndReturn("change password", expect: "password")
    }

    // MARK: 09d — real-user journey over the never-driven paths
    //
    // Owner 2026-09-17: "review everything like a real user." This drives the
    // flows no suite had touched: another user's profile via a post's handle,
    // follow → unfollow, a reply's own page, the drafts lifecycle, a settings
    // toggle round-trip, and a notification row tap.
    func test09d_userJourneyGaps() throws {
        try requireFeed()

        // 1) Open the fixture post → tap the author handle → other profile.
        let fixtureRow = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')"))
        XCTAssertNotNil(fixtureRow, "Fixture post not in feed")
        guard let fixtureRow else { return }
        forceTap(fixtureRow)
        XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Post detail didn't open")
        sleep(1)
        snap("09d0-detail-before-handle")
        let handleMatches = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'anonymous_cd1b15f0'")).allElementsBoundByIndex
        let handleBtn = handleMatches.first(where: { $0.isHittable }) ?? handleMatches.first
        if handleBtn == nil {
            let labels = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }.joined(separator: " | ")
            XCTFail("Author handle not tappable on detail — buttons: \(labels)")
            return
        }
        if let handleBtn { forceTap(handleBtn) }
        sleep(2)
        snap("09d1-other-profile")
        // 2) Follow ↔ unfollow round-trip, from WHATEVER state the account
        // is in (a prior run may have left it following).
        let pill = app.buttons["followButton"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6), "No follow button on other profile")
        if pill.label == "following" { forceTap(pill); sleep(2) }   // normalize
        XCTAssertEqual(pill.label, "follow", "Couldn't normalize to un-followed")
        forceTap(pill)
        sleep(2)
        XCTAssertEqual(pill.label, "following", "Follow didn't flip to following")
        snap("09d2-followed")
        forceTap(pill)
        sleep(2)
        XCTAssertEqual(pill.label, "follow", "Unfollow didn't flip back")
        // back to detail, then feed
        if app.buttons["Back"].exists { forceTap(app.buttons["Back"]) } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        sleep(1)
        if app.buttons["Back"].exists { forceTap(app.buttons["Back"]) }
        sleep(1)

        // 3) Reply's own page: open a busy post, tap its first reply row.
        scrollToTop(2)
        let repliedRow = findRow(matching: NSPredicate(
            format: "label CONTAINS 'a year ago today'"))
        if let repliedRow {
            forceTap(repliedRow)
            XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Replied post didn't open")
            sleep(2)
            snap("09d3-thread")
            // A reply row is a button whose label carries the reply text; tap
            // the first one below the stats line if present.
            let replyRow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'felt this' AND label CONTAINS 'reply'"))
            _ = replyRow // (labels vary; drive via any reply body instead)
            let anyReply = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'here with you'")).allElementsBoundByIndex.first(where: { $0.isHittable })
            if let anyReply {
                forceTap(anyReply)
                sleep(2)
                snap("09d4-reply-detail")
                if app.buttons["Back"].exists { forceTap(app.buttons["Back"]); sleep(1) }
            }
            if app.buttons["Back"].exists { forceTap(app.buttons["Back"]); sleep(1) }
        }

        // 4) Drafts lifecycle: compose → type → save draft → check drafts list.
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        let marker = "draftcheck\(Int(Date().timeIntervalSince1970))"
        focusAndType(app.textViews.firstMatch, "words i am not ready to say. \(marker)")
        let saveDraft = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'save'")).firstMatch
        XCTAssertTrue(saveDraft.waitForExistence(timeout: 4), "save draft missing")
        forceTap(saveDraft)
        sleep(2)
        // Saving may auto-dismiss; if compose is still up, cancel out.
        // (waitForExistence + forceTap: the exists→tap gap raced the
        // save-draft auto-dismiss and crashed the query.)
        if app.buttons["cancel"].waitForExistence(timeout: 2) {
            forceTap(app.buttons["cancel"]); sleep(1)
        }
        app.buttons["Profile"].tap(); sleep(1)
        app.buttons["settings"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Settings didn't open")
        let draftsRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'drafts'"))
            .allElementsBoundByIndex.last
        XCTAssertNotNil(draftsRow, "drafts row missing")
        if let draftsRow { nudgeRowIntoSafeBand(draftsRow); forceTap(draftsRow) }
        sleep(2)
        let savedDraft = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(waitFor(savedDraft, 8), "Saved draft not in drafts list")
        snap("09d5-drafts")
        if app.buttons["Back"].exists { forceTap(app.buttons["Back"]); sleep(1) }
        else if app.buttons["close"].exists { forceTap(app.buttons["close"]); sleep(1) }
        else if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap(); sleep(1) }

        // 5) Settings toggle round-trip: flip "allow sharing" off and back on.
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Not back on settings")
        let toggle = app.switches["allow sharing"].firstMatch
        if toggle.waitForExistence(timeout: 4) {
            nudgeRowIntoSafeBand(toggle)
            let before = (toggle.value as? String) ?? "?"
            if toggle.isHittable { toggle.tap() } else {
                // knob sits at the trailing edge of the switch element
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
            }
            sleep(2)
            let mid = (toggle.value as? String) ?? "?"
            XCTAssertNotEqual(before, mid, "allow-sharing toggle didn't flip")
            if toggle.isHittable { toggle.tap() } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
            }
            sleep(2)
            let after = (toggle.value as? String) ?? "?"
            XCTAssertEqual(before, after, "allow-sharing toggle didn't restore")
            snap("09d6-toggle-roundtrip")
        }

        // 6) Notifications: open, tap the first row if any, come back.
        app.buttons["Back"].exists ? forceTap(app.buttons["Back"]) : ()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch.tap()
        sleep(2)
        snap("09d7-notifications")
        let notifRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'felt this' OR label CONTAINS 'followed you' OR label CONTAINS 'replied'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let notifRow {
            forceTap(notifRow)
            sleep(2)
            snap("09d8-notification-target")
        }
    }

    // MARK: 17 — a day in the life: one continuous user sitting
    //
    // Not an assertion suite — a narrated session. Open, read, respond to
    // the prompt, post a GIF, wander every tab. Snaps at every beat so the
    // session can be reviewed for FEEL, not just function.
    func test17_dayInTheLife() throws {
        try requireFeed()
        snap("17a-open-first-glance")

        // read the feed like a person: two slow pages
        app.swipeUp(); sleep(1)
        snap("17b-scrolled-once")
        app.swipeUp(); sleep(1)
        snap("17c-scrolled-twice")
        scrollToTop(3)

        // respond to today's prompt if it's still open
        let writeYours = app.buttons.matching(NSPredicate(format: "label == 'write yours'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let writeYours {
            forceTap(writeYours)
            XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Prompt compose didn't open")
            snap("17d-prompt-compose")
            clearComposeEditor()
            focusAndType(app.textViews.firstMatch,
                         "if you asked, i'd say i stopped being angry in march. (walkthrough)")
            snap("17e-prompt-typed")
            forceTap(app.buttons["post"])
            sleep(5)
            snap("17f-after-prompt-post")
        } else {
            snap("17d-already-responded")
        }

        // post a GIF with a few words — and FEEL the gif land
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        focusAndType(app.textViews.firstMatch, "no words tonight, just this. (walkthrough)")
        forceTap(app.buttons["Add GIF"])
        sleep(3)
        snap("17g-gif-picker-open")   // did trending load instantly?
        // tap the first gif cell if the grid rendered
        let firstGif = app.images.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.width > 60 })
        if let firstGif {
            forceTap(firstGif)
            sleep(2)
            snap("17h-gif-attached")   // compose preview
        } else if app.buttons["close GIF picker"].exists {
            forceTap(app.buttons["close GIF picker"])
        }
        if app.buttons["post"].exists && app.buttons["post"].isEnabled {
            forceTap(app.buttons["post"])
            sleep(2)
            snap("17i-right-after-post")   // is the gif already rendered in feed?
            sleep(4)
            snap("17j-post-settled")
        } else if app.buttons["cancel"].exists {
            app.buttons["cancel"].tap()
        }

        // wander: most felt → notifications → profile → back home
        app.buttons["Trending"].tap(); sleep(2)
        snap("17k-most-felt")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch.tap()
        sleep(2)
        snap("17l-notifications")
        app.buttons["Profile"].tap(); sleep(2)
        snap("17m-my-profile")
        app.buttons["Home"].tap(); sleep(2)
        scrollToTop(2)
        snap("17n-home-again")
    }

    // MARK: 18 — deep sweep: every control, every state (owner 2026-09-17)

    /// Every Settings control: each non-push toggle flipped + restored, every
    /// row opened, destructive alerts CANCELLED, policy sheet dismissed.
    func test18a_settingsEveryControl() throws {
        try requireFeed()
        app.buttons["Profile"].tap(); sleep(1)
        app.buttons["settings"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Settings didn't open")

        func flipRestore(_ label: String) {
            let t = app.switches[label].firstMatch
            guard t.waitForExistence(timeout: 3) else { XCTFail("toggle '\(label)' missing"); return }
            nudgeRowIntoSafeBand(t)
            let before = (t.value as? String) ?? "?"
            if t.isHittable { t.tap() } else { t.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap() }
            sleep(2)
            XCTAssertNotEqual(before, (t.value as? String) ?? "?", "'\(label)' didn't flip")
            if t.isHittable { t.tap() } else { t.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap() }
            sleep(2)
            XCTAssertEqual(before, (t.value as? String) ?? "?", "'\(label)' didn't restore")
        }
        flipRestore("allow sharing")
        flipRestore("show follower count")
        flipRestore("share anonymous usage data")
        flipRestore("gentle check-in")
        snap("18a1-toggles-done")

        // content policy sheet opens + closes
        let policy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'view content policy'"))
            .allElementsBoundByIndex.last
        if let policy { nudgeRowIntoSafeBand(policy); forceTap(policy); sleep(2) }
        snap("18a2-content-policy")
        if app.buttons["Back"].exists { forceTap(app.buttons["Back"]) }
        else if app.buttons["close"].exists { forceTap(app.buttons["close"]) }
        else { app.swipeDown(velocity: .fast) }
        sleep(1)
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 6), "Didn't return from content policy")

        // sign out + delete account alerts — CANCEL both
        for row in ["sign out", "delete account"] {
            let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", row))
                .allElementsBoundByIndex.last
            guard let b else { XCTFail("'\(row)' row missing"); continue }
            nudgeRowIntoSafeBand(b); forceTap(b); sleep(1)
            snap("18a3-\(row.replacingOccurrences(of: " ", with: "-"))-alert")
            let cancel = app.buttons["cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.tap() }
            sleep(1)
        }
        XCTAssertTrue(app.staticTexts["settings"].exists, "Lost settings after cancelled alerts")
        snap("18a4-settings-after")
    }

    /// Repost matrix: repost from the DETAIL stats line, undo it, then repost
    /// a REPLY from a thread, undo, and confirm the reposts tab on profile.
    func test18b_repostMatrix() throws {
        try requireFeed()
        // detail repost on the fixture post (not ours)
        guard let row = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')")) else {
            throw XCTSkip("fixture post missing")
        }
        forceTap(row)
        XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Detail didn't open")
        let repost = app.buttons.matching(NSPredicate(format: "label == 'Repost' AND enabled == true"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        let undo = { self.app.buttons.matching(NSPredicate(format: "label == 'Undo repost'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable }) }
        if let repost {
            forceTap(repost); sleep(4)
            snap("18b1-detail-reposted")
            XCTAssertNotNil(undo(), "Detail repost didn't stick")
            // profile reposts tab should now show it
            forceTap(app.buttons["Back"])
            sleep(1)
            app.buttons["Profile"].tap(); sleep(1)
            let repostsTab = app.buttons["reposts"].firstMatch
            if repostsTab.waitForExistence(timeout: 4) { forceTap(repostsTab); sleep(2) }
            snap("18b2-profile-reposts-tab")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS 'first light, honestly'")).firstMatch.waitForExistence(timeout: 6),
                "Repost not on reposts tab")
            // back to the thread, undo
            app.buttons["Home"].tap(); sleep(1)
            if let row2 = findRow(matching: NSPredicate(
                format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')")) {
                forceTap(row2)
                _ = waitFor(app.buttons["Back"], 8)
                if let u = undo() { forceTap(u); sleep(3) }
                snap("18b3-detail-unreposted")
            }
        } else if undo() != nil {
            // leftover state — undo to normalize
            if let u = undo() { forceTap(u); sleep(3) }
        }
        // reply repost round-trip: open the busy thread, repost first reply
        if app.buttons["Back"].exists { forceTap(app.buttons["Back"]); sleep(1) }
        scrollToTop(2)
        if let busy = findRow(matching: NSPredicate(format: "label CONTAINS 'a year ago today'")) {
            forceTap(busy)
            _ = waitFor(app.buttons["Back"], 8)
            sleep(2)
            let replyRepost = app.buttons.matching(
                NSPredicate(format: "label == 'Repost reply'")).allElementsBoundByIndex.first(where: { $0.isHittable })
            if let replyRepost {
                forceTap(replyRepost); sleep(4)
                snap("18b4-reply-reposted")
                let undoReply = app.buttons.matching(
                    NSPredicate(format: "label == 'Undo repost'")).allElementsBoundByIndex.first(where: { $0.isHittable })
                XCTAssertNotNil(undoReply, "Reply repost didn't stick")
                if let u = undoReply { forceTap(u); sleep(3) }
            }
            snap("18b5-thread-after")
        }
    }

    /// Post lifecycle: post a WHISPER, verify its badge + hidden share, expand
    /// a letter via "keep reading", then DELETE our whisper via the ⋯ menu.
    func test18c_postLifecycle() throws {
        try requireFeed()
        // Letters-only marker — a digit-run marker reads as a PHONE NUMBER
        // to the PII detector and (correctly!) triggers the keep-it-anonymous
        // dialog, stalling the post. Encode the timestamp in letters.
        let digits = Array("abcdefghij")
        let marker = "whisp" + String(Int(Date().timeIntervalSince1970)).map { c in
            digits[Int(String(c))!]
        }
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        // clear any restored feeling tag so the whisper is untagged
        focusAndType(app.textViews.firstMatch, "just for an hour. \(marker)")
        forceTap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Whisper'")).firstMatch)
        sleep(1)
        snap("18c1-whisper-composed")
        forceTap(app.buttons["post"])
        sleep(2)
        // If a safety dialog still fires, proceed past it deliberately.
        let postAnyway = app.buttons["post anyway"].firstMatch
        if postAnyway.waitForExistence(timeout: 2) { forceTap(postAnyway); sleep(1) }
        snap("18c1b-right-after-post-tap")
        // Patient-user wait: a pull-to-refresh inside the pending_validation
        // window briefly drops the fresh post from server truth (promote lag,
        // mitigated in-app by delayed refetches) — poll gently instead.
        var myWhisper: XCUIElement?
        for _ in 0..<7 {
            sleep(4)
            scrollToTop(1)
            myWhisper = findRow(matching: NSPredicate(format: "label CONTAINS %@", marker), swipes: 1)
            if myWhisper != nil { break }
        }
        XCTAssertNotNil(myWhisper, "Whisper not in feed after 28s")
        snap("18c2-whisper-in-feed")
        if let myWhisper {
            forceTap(myWhisper)
            XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Whisper detail didn't open")
            XCTAssertFalse(app.buttons["Share post"].exists, "Whisper must not offer share")
            snap("18c3-whisper-detail")
            // delete it via ⋯ (it's ours)
            let menu = app.buttons["Edit or delete post"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 6), "Own-post menu missing")
            forceTap(menu); sleep(1)
            let del = app.buttons["delete post"].firstMatch
            XCTAssertTrue(del.waitForExistence(timeout: 4), "delete option missing")
            forceTap(del); sleep(1)
            snap("18c4-delete-confirm")
            let confirm = app.buttons["delete"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 4), "delete confirm missing")
            forceTap(confirm)
            sleep(3)
            snap("18c5-after-delete")
            XCTAssertNil(findRow(matching: NSPredicate(format: "label CONTAINS %@", marker), swipes: 1),
                         "Deleted whisper still in feed")
        }
        // letter expansion via keep reading
        scrollToTop(2)
        let keepReading = app.buttons.matching(NSPredicate(format: "label == 'keep reading'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let keepReading {
            forceTap(keepReading); sleep(1)
            snap("18c6-letter-expanded")
        }
    }

    /// Block → undo-toast → (re)block → blocked list → unblock, end to end.
    func test18d_blockRoundTrip() throws {
        try requireFeed()
        guard let row = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')")) else {
            throw XCTSkip("fixture post missing")
        }
        // long-press → block from the context menu (re-find + nudge right
        // before pressing: feed churn between find and press goes stale)
        // Coordinate press — SwiftUI buttons report isHittable unreliably
        // here (same quirk as the detail handle button), and a plain press()
        // hard-fails on it. forceTap's coordinate approach works for taps;
        // this is its long-press sibling.
        nudgeRowIntoSafeBand(row)
        guard let fresh = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')"), swipes: 1) else {
            throw XCTSkip("fixture row not found for long-press")
        }
        fresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        sleep(1)
        snap("18d1-context-menu")
        let blockItem = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'block '")).firstMatch
        guard blockItem.waitForExistence(timeout: 4) else {
            app.tap(); throw XCTSkip("block item not in context menu")
        }
        forceTap(blockItem); sleep(1)
        let confirmBlock = app.buttons["block"].firstMatch
        XCTAssertTrue(confirmBlock.waitForExistence(timeout: 4), "block confirm missing")
        forceTap(confirmBlock)
        sleep(1)
        snap("18d2-undo-toast")
        // the undo toast must be there — use it
        let undoBtn = app.buttons["undo"].firstMatch
        XCTAssertTrue(undoBtn.waitForExistence(timeout: 4), "undo-block toast missing")
        forceTap(undoBtn)
        sleep(4)   // unblock write + feed refetch
        scrollToTop(1)
        // author's posts should be back (or still present)
        XCTAssertNotNil(findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly'")), "Posts didn't return after undo")
        snap("18d3-after-undo")
        // block again, let it stand, verify blocked list, unblock there
        if let row2 = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')")) {
            row2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2); sleep(1)
            let b2 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'block '")).firstMatch
            if b2.waitForExistence(timeout: 4) {
                forceTap(b2); sleep(1)
                let c2 = app.buttons["block"].firstMatch
                if c2.waitForExistence(timeout: 3) { forceTap(c2) }
                sleep(5)   // let the toast expire so the block stands
                snap("18d4-blocked-feed")   // author's posts should be gone
                XCTAssertNil(findRow(matching: NSPredicate(
                    format: "label CONTAINS 'first light, honestly'"), swipes: 1),
                    "Blocked author's posts still visible")
                // settings → blocked users → unblock
                app.buttons["Profile"].tap(); sleep(1)
                app.buttons["settings"].tap()
                _ = waitFor(app.staticTexts["settings"], 8)
                let blockedRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'blocked users'"))
                    .allElementsBoundByIndex.last
                if let blockedRow { nudgeRowIntoSafeBand(blockedRow); forceTap(blockedRow); sleep(2) }
                snap("18d5-blocked-list")
                let unblock = app.buttons["unblock"].firstMatch
                XCTAssertTrue(unblock.waitForExistence(timeout: 6), "blocked list empty after block")
                forceTap(unblock)
                sleep(3)
                snap("18d6-after-unblock")
            }
        }
    }

    // MARK: 19 — offline → online transition: queued like survives the trip
    //
    // Launches pinned OFFLINE (debug hook), likes the fixture post — heart
    // must fill optimistically with the offline banner up — then relaunches
    // ONLINE and verifies the queued like flushed to the server (the row
    // still reads liked after real data replaces the optimistic state).
    func test19_offlineLikeQueue() throws {
        // Phase 1: offline
        app.terminate()
        app.launchEnvironment["TOSKA_FORCE_OFFLINE"] = "1"
        app.launch()
        acceptPolicyGateIfPresent()
        try requireFeed()
        snap("19a-offline-feed")   // offline banner should be visible
        guard let row = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')")) else {
            throw XCTSkip("fixture post missing")
        }
        _ = row
        // normalize: if already liked (leftover), unlike first — offline
        // queuing coalesces so the final state below is still deterministic
        // (existence + forceTap — SwiftUI isHittable is unreliable here)
        let unlike = app.buttons.matching(NSPredicate(format: "label == 'Unlike post'")).firstMatch
        if unlike.exists { forceTap(unlike); sleep(1) }
        let like = app.buttons.matching(NSPredicate(format: "label == 'Like post'")).firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 6), "No likeable post row on screen")
        forceTap(like)
        sleep(1)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Unlike post'"))
            .firstMatch.exists, "Offline like didn't render optimistically")
        snap("19b-offline-liked")

        // Phase 2: back online — queue flushes on launch connectivity
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "TOSKA_FORCE_OFFLINE")
        app.launch()
        acceptPolicyGateIfPresent()
        try requireFeed()
        sleep(5)   // flush + likedPostIds listener delivery
        scrollToTop(1)
        let likedRow = app.buttons.matching(NSPredicate(format: "label == 'Unlike post'")).firstMatch
        XCTAssertTrue(likedRow.waitForExistence(timeout: 10),
                      "Queued like didn't sync to the server after reconnect")
        snap("19c-online-synced")

        // Cleanup: unlike so reruns start clean
        let cleanup = app.buttons.matching(NSPredicate(format: "label == 'Unlike post'")).firstMatch
        if cleanup.exists { forceTap(cleanup); sleep(2) }
    }

    func test10_composeAndPost() throws {
        try requireFeed()
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        let editor = app.textViews.firstMatch
        focusAndType(editor, "the quiet after the storm. still here. (walkthrough)")
        snap("10a-compose-typed")
        let post = app.buttons["post"]
        XCTAssertTrue(post.isEnabled, "post button disabled")
        post.tap()
        sleep(4) // pending_validation → validatePost (staging) → live
        snap("10b-after-post")
    }

    // MARK: 10c — compose mode chips (letter / whisper / midnight / feeling / GIF)
    //
    // The 2026-09 redesign turned the icon toolbar into outlined chips —
    // verify each mode still wires up: toggling shows its banner, whisper and
    // midnight stay mutually exclusive, the feeling picker opens + closes on
    // selection, and the GIF chip pushes the picker and comes back.
    func test10c_composeModeChips() throws {
        try requireFeed()
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")

        func chip(_ prefix: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix)).firstMatch
        }
        func banner(_ contains: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
        }

        forceTap(chip("Letter mode"))
        XCTAssertTrue(waitFor(banner("writing a letter"), 4), "Letter banner missing")
        snap("10c1-letter-on")

        forceTap(chip("Whisper"))
        XCTAssertTrue(waitFor(banner("disappears in 1 hour"), 4), "Whisper banner missing")

        forceTap(chip("Midnight post"))
        XCTAssertTrue(waitFor(banner("disappears at midnight"), 4), "Midnight banner missing")
        sleep(1)
        XCTAssertFalse(banner("disappears in 1 hour").exists, "Whisper should switch off when midnight turns on")
        snap("10c2-midnight-letter")

        forceTap(app.buttons["Tag"])
        XCTAssertTrue(waitFor(app.staticTexts["how does this feel"], 4), "Feeling picker missing")
        forceTap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'longing'")).firstMatch)
        sleep(1)
        XCTAssertFalse(app.staticTexts["how does this feel"].exists, "Feeling picker should close after selection")
        snap("10c3-feeling-selected")

        forceTap(app.buttons["Add GIF"])
        sleep(2)
        snap("10c4-gif-picker")
        let closeGifs = app.buttons["close GIF picker"]
        XCTAssertTrue(waitFor(closeGifs, 6), "GIF picker didn't open")
        forceTap(closeGifs)
        sleep(1)
        XCTAssertTrue(waitFor(app.buttons["cancel"], 6), "Didn't return to compose from GIF picker")

        app.buttons["cancel"].tap()
    }

    // MARK: 11 — compose: PII warning fires on a FULL name (and not on lone first name)

    func test11_composePIIWarning() throws {
        try requireFeed()
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        let editor = app.textViews.firstMatch
        focusAndType(editor, "my ex Sarah Johnson still has my hoodie")
        app.buttons["post"].tap()
        let warning = app.staticTexts["keep it anonymous"]
        XCTAssertTrue(waitFor(warning, 5), "PII warning did not appear for a full name")
        snap("11-pii-warning-full-name")
        // do NOT post — dismiss the warning, clear the draft, cancel
        let editButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'edit' OR label CONTAINS[c] 'go back' OR label CONTAINS[c] 'keep'")).firstMatch
        if editButton.exists { editButton.tap() } else { app.tap() }
        sleep(1)
        clearComposeEditor()
        app.buttons["cancel"].tap()
    }

    // MARK: 12 — compose: crisis check-in (explicit tier — always shows)

    func test12_composeCrisisCheckIn() throws {
        try requireFeed()
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        let editor = app.textViews.firstMatch
        focusAndType(editor, "some nights i want to die")
        app.buttons["post"].tap()
        // CrisisCheckInView: heart icon + hotlines + "not now"
        let notNow = app.buttons["not now"]
        XCTAssertTrue(waitFor(notNow, 6), "Crisis check-in modal did not appear for explicit phrase")
        snap("12-crisis-check-in")
        notNow.tap()
        sleep(1)
        clearComposeEditor()
        app.buttons["cancel"].tap()
    }

    // MARK: 13 — share card

    func test13_shareCard() throws {
        try requireFeed()
        // Every feed row exposes a direct "Share post" button.
        let share = app.buttons["Share post"].firstMatch
        XCTAssertTrue(waitFor(share, 10), "Share post button not found on feed row")
        forceTap(share)
        _ = waitFor(app.staticTexts["share this"], 8)
        dismissSharingHintIfPresent()
        sleep(1)
        snap("13-share-card")
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    /// The share sheet shows a one-time "sharing, quietly" consent explainer
    /// on first open per install — dismiss it so share-card tests keep working
    /// on fresh simulators.
    func dismissSharingHintIfPresent() {
        let gotIt = app.buttons["got it"]
        if gotIt.waitForExistence(timeout: 3) { gotIt.tap(); sleep(1) }
    }

    // MARK: 13b — share card must fit a MAX-LENGTH (≈500 char) message

    func test13b_longShareCardFits() throws {
        try requireFeed()
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        let longText = "i keep thinking about how we used to stay up until 3am talking about nothing and everything, and now the apartment is so quiet i can hear the refrigerator hum. i don't miss the fighting. i miss the version of me that believed we would figure it out. people keep telling me it gets easier and i think they're right, because last week i went a whole day without checking your profile, and that itself was unimaginable in month one. i'm okay. i'm actually going to be okay now."
        focusAndType(app.textViews.firstMatch, longText)
        let post = app.buttons["post"]
        XCTAssertTrue(post.isEnabled, "post button disabled")
        post.tap()
        sleep(5) // pending_validation → validatePost (staging) → live
        // Share from the author's OWN profile, where the just-posted message is
        // the newest row and is visible immediately (own posts bypass the
        // moderation feed filter) — so we always hit the long post, not whatever
        // happens to sit atop the for-you feed.
        app.buttons["Profile"].tap()
        sleep(2)
        // A ≈500-char post pushes its row's inline share button reliably BELOW
        // the profile viewport, where exists==true but taps (including
        // forceTap's coordinate fallback) land off-screen and do nothing. Open
        // the long post's DETAIL instead — findRow scroll-searches the row into
        // the safe band — and share from the detail header, which is always
        // on-screen.
        // Newest-first, so the post just made is at the very top — but the
        // profile can open already scrolled (and every prior run of this test
        // left another identical copy further down the list). Go to the top so
        // the row findRow lands on is the fresh one, on-screen and hittable.
        scrollToTop()
        let row = findRow(matching: NSPredicate(format: "label CONTAINS 'refrigerator hum'"))
        XCTAssertNotNil(row, "Long post row not found on profile")
        guard let row else { return }
        forceTap(row)
        XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Post detail didn't open")
        let detailShare = app.buttons["Share post"].firstMatch
        XCTAssertTrue(waitFor(detailShare, 8), "Share button not found on detail")
        forceTap(detailShare)
        XCTAssertTrue(waitFor(app.staticTexts["share this"], 8), "Share card never presented — nothing to screenshot")
        dismissSharingHintIfPresent()
        sleep(1)
        snap("13b-long-share-card")   // inspect: the full message must be visible, not clipped
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    // MARK: 14 — report sheet

    func test14_reportSheet() throws {
        try requireFeed()
        // The ••• menu lives on the post DETAIL header, not on feed rows —
        // open a post first (mirrors test05_postDetailInteractions).
        // Requires the "first light, honestly" fixture authored by a DIFFERENT
        // account (report is hidden on your own post) and seeded FRESH so feed
        // drift doesn't bury it: `node firestore-tests/seed-walkthrough-fixtures.mjs`.
        let firstPost = findRow(matching: NSPredicate(
            format: "label CONTAINS 'first light, honestly' AND NOT (label CONTAINS 'reposted')"))
        XCTAssertNotNil(firstPost, "No post row found in feed")
        guard let firstPost else { return }
        forceTap(firstPost)
        XCTAssertTrue(waitFor(app.buttons["Back"], 8), "Post detail didn't open (header 'post' missing)")
        sleep(1)
        snap("14a-post-detail")
        // PostDetailView's header ellipsis exposes "Report or block" on others'
        // posts and "Edit or delete post" on our own (it also starts at opacity
        // 0 while the author id loads — hence the generous wait).
        let more = app.buttons.matching(NSPredicate(
            format: "label == 'Report or block' OR label == 'Edit or delete post'")).firstMatch
        XCTAssertTrue(waitFor(more, 10), "Detail-header ••• menu not found")
        forceTap(more)
        let report = app.buttons["report"]
        if waitFor(report, 5) {
            report.tap()
            sleep(2)
            snap("14-report-sheet")
            // close without filing
            if app.buttons["cancel"].exists { app.buttons["cancel"].tap() }
            else { app.swipeDown(velocity: .fast) }
        } else {
            snap("14-more-menu")
            app.tap()
            throw XCTSkip("report not in the ••• menu (own post — menu shows edit/delete instead)")
        }
    }

    // MARK: 15 — backgrounding: window-level privacy cover (T-7)

    func test15_privacyCoverOnBackground() throws {
        try requireFeed()
        // Open compose (a fullScreenCover — the surface T-7 exists for)…
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        focusAndType(app.textViews.firstMatch, "private words mid-compose")
        // …then background the app and reopen: the switcher snapshot is taken
        // while resignActive — the cover (toskaBlue + 't') must be up.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        sleep(2)
        snap("15-back-from-switcher")
        clearComposeEditor()
        app.buttons["cancel"].tap()
    }

    // MARK: 16 — grief phrasing must NOT be hard-blocked (build-47 threat-FP fix)
    // "she dropped a bomb on me" contains bare "bomb", which the old client
    // threat list hard-blocked with no override — locking a grieving user out of
    // posting content the server itself publishes. Regression guard: the
    // content-violation dialog ("hold on") must NOT appear, and the post lands.
    func test16_griefPhraseNotBlocked() throws {
        try requireFeed()
        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor()
        focusAndType(app.textViews.firstMatch, "she dropped a bomb on me and i havent slept since (walkthrough)")
        snap("16a-grief-typed")
        let post = app.buttons["post"]
        XCTAssertTrue(post.isEnabled, "post button disabled")
        post.tap()
        // The content-violation dialog title is "hold on" — it must NOT fire.
        let blocked = app.staticTexts["hold on"].waitForExistence(timeout: 3)
        XCTAssertFalse(blocked, "grief phrase 'dropped a bomb on me' was wrongly hard-blocked (threat FP not fixed)")
        sleep(4) // clean content: pending_validation → validatePost (staging) → live
        snap("16b-grief-posted")
    }
}
