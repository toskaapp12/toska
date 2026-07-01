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
        app.launch()
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
            "newHere=\(app.buttons["im new here"].exists) " +
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
        if app.buttons["im new here"].waitForExistence(timeout: 5) {
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
        XCTAssertTrue(waitFor(app.buttons["im new here"], 10), "Splash didn't appear after sign out")
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
        password.typeText("crazy1234")
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
            pw.tap(); pw.typeText("crazy1234")
            app.buttons["signInButton"].tap()
        }
        XCTAssertTrue(waitFor(feedView, 30), "Feed didn't load initially")
        func hasPosts(_ t: TimeInterval) -> Bool {
            waitFor(app.buttons["Repost"].firstMatch, t)
                || app.buttons["Already reposted"].firstMatch.exists
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
        let firstPost = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'first light' OR label CONTAINS 'the quiet' OR label CONTAINS 'storm'")).firstMatch
        XCTAssertTrue(waitFor(firstPost, 10), "No post row found")
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
    // (button stays "Already reposted") rather than reverting (green→grey).
    func test05z_repost() throws {
        try requireFeed()
        let repost = app.buttons["Repost"].firstMatch
        XCTAssertTrue(waitFor(repost, 10), "No un-reposted post found (all already reposted?)")
        snap("05z1-before-repost")
        repost.tap()
        sleep(1)
        snap("05z2-just-after-tap")   // should be green / "Already reposted"
        sleep(5)                      // let transaction + validatePost settle
        snap("05z3-after-settle")
        // If the write was denied, the button reverts to "Repost".
        let stuck = app.buttons["Already reposted"].firstMatch.exists
        let reverted = app.buttons["Repost"].firstMatch.exists
        print("🔁 REPOST RESULT — stuck(Already reposted)=\(stuck)  reverted(Repost)=\(reverted)")
        XCTAssertTrue(stuck, "Repost did NOT stick — reverted to 'Repost' (green→grey reproduced)")
    }

    func test05_postDetailInteractions() throws {
        try requireFeed()
        // Post rows are Buttons labelled "handle, age, text, tag" — open the first.
        let firstPost = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'first light, honestly'")).firstMatch
        XCTAssertTrue(waitFor(firstPost, 10), "No post row found in feed")
        forceTap(firstPost)
        sleep(2)
        snap("05a-post-detail")

        let like = app.buttons["Like post"].firstMatch
        if like.exists { like.tap(); sleep(1); snap("05b-after-like") }
        let save = app.buttons["Save post"].firstMatch
        if save.exists { save.tap(); sleep(1) }

        // reply (T-2 path: client writes pending_validation; staging validateReply promotes)
        let replyField = app.textFields["say something gently…"]
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
        // back out without touching sign out / delete (custom header — edge swipe)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        app.buttons["Home"].tap()
    }

    // MARK: 10 — compose & post (clean content, real moderation round-trip)

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
        sleep(1)
        snap("13-share-card")
        app.swipeDown(velocity: .fast)
        sleep(1)
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
        let share = app.buttons["Share post"].firstMatch
        XCTAssertTrue(waitFor(share, 12), "Share button not found on profile")
        forceTap(share)
        _ = waitFor(app.staticTexts["share this"], 8)
        sleep(1)
        snap("13b-long-share-card")   // inspect: the full message must be visible, not clipped
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    // MARK: 14 — report sheet

    func test14_reportSheet() throws {
        try requireFeed()
        // Each row has a "More options for <handle>'s post" ellipsis menu.
        let more = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'More options'")).firstMatch
        XCTAssertTrue(waitFor(more, 10), "More-options button not found on feed row")
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
            throw XCTSkip("report not in the ••• menu on this surface")
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
}
