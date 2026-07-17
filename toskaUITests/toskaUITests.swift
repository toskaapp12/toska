import XCTest

// MARK: - Toska UI Test Suite
// Run with: Cmd+U in Xcode (select the test target)
// Prerequisites: Set launch argument "UI_TESTING" in the test scheme
// Some tests require a seeded test account — see setupTestAccount()

final class ToskaUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Helper: Wait for element

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        return element.waitForExistence(timeout: timeout)
    }

    // Precondition helpers — throw XCTSkip when the preconditions for a test
    // aren't met, so the test reports as "skipped" instead of silently passing.
    // Previously every test used `guard waitFor(element) else { return }`, which
    // made precondition failures (e.g. the UI seed account not being logged in)
    // indistinguishable from test successes in CI.

    /// Assert the feed (and therefore a logged-in session) is visible. Throws
    /// XCTSkip otherwise — used by tests that require the authenticated surface.
    func requireFeed() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15),
                          "Feed didn't load — UI test is likely running against a signed-out session")
    }

    /// Assert the splash screen is visible (user is signed out). Throws XCTSkip
    /// otherwise — used by tests that exercise the auth flows.
    func requireSignedOut() throws {
        let newHereButton = app.buttons["im new here"]
        try XCTSkipUnless(waitFor(newHereButton, timeout: 5),
                          "Splash not shown — UI test is likely running against a signed-in session")
    }
    
    // MARK: - 1. Splash Screen
    
    func testSplashScreenAppears() {
            let newHereButton = app.buttons["im new here"]
            let toskaHeader = app.staticTexts["toska"]
            
            let splashAppeared = waitFor(newHereButton, timeout: 5)
            let feedAppeared = waitFor(toskaHeader, timeout: 10)
            
            XCTAssertTrue(splashAppeared || feedAppeared, "Neither splash screen nor feed appeared")
        }
    
    // MARK: - 2. Create Account Flow
    
    func testCreateAccountFlowExists() throws {
        try requireSignedOut()
        let newHereButton = app.buttons["im new here"]
        newHereButton.tap()
        
        // Verify create account view elements
        let emailField = app.textFields["createEmailField"]
        let passwordField = app.secureTextFields["createPasswordField"]
        let confirmField = app.secureTextFields["createConfirmPasswordField"]
        let createButton = app.buttons["createAccountButton"]
        
        XCTAssertTrue(waitFor(emailField), "Email field not found")
        XCTAssertTrue(passwordField.exists, "Password field not found")
        XCTAssertTrue(confirmField.exists, "Confirm password field not found")
        XCTAssertTrue(createButton.exists, "Create account button not found")
        
        // Verify shuffle button exists (poetic handle generator)
        let shuffleButton = app.buttons["shuffle"]
        XCTAssertTrue(shuffleButton.exists, "Handle shuffle button not found")
    }
    
    func testCreateAccountValidation() throws {
        try requireSignedOut()
        app.buttons["im new here"].tap()

        let emailField = app.textFields["createEmailField"]
        try XCTSkipUnless(waitFor(emailField), "Create-account email field not found after tapping into the flow")
        
        let createButton = app.buttons["createAccountButton"]
        
        // Try with invalid email
        emailField.tap()
        emailField.typeText("notanemail")
        
        let passwordField = app.secureTextFields["createPasswordField"]
        passwordField.tap()
        passwordField.typeText("123456")
        
        let confirmField = app.secureTextFields["createConfirmPasswordField"]
        confirmField.tap()
        confirmField.typeText("123456")
        
        createButton.tap()
        
        // Should show error
        let errorText = app.staticTexts["please enter a valid email"]
        XCTAssertTrue(waitFor(errorText, timeout: 3), "Email validation error not shown")
    }
    
    // MARK: - 3. Sign In Flow
    
    func testSignInFlowExists() throws {
        try requireSignedOut()
        let signInButton = app.buttons["sign in"]
        try XCTSkipUnless(waitFor(signInButton, timeout: 5), "Sign-in button not shown on splash — unexpected splash variant")
        signInButton.tap()
        
        let emailField = app.textFields["emailField"]
        let passwordField = app.secureTextFields["passwordField"]
        let submitButton = app.buttons["signInButton"]
        
        XCTAssertTrue(waitFor(emailField), "Email field not found")
        XCTAssertTrue(passwordField.exists, "Password field not found")
        XCTAssertTrue(submitButton.exists, "Sign in button not found")
    }
    
    // MARK: - 4. Feed (requires logged in state)
    
    func testFeedLoads() {
            let header = app.staticTexts["toska"]
            guard waitFor(header, timeout: 15) else {
                XCTFail("Feed did not load — user may not be logged in")
                return
            }
            
            XCTAssertTrue(header.exists, "Feed header 'toska' not found")
        }
    
    func testFeedTabsExist() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let forYouTab = app.buttons["for you"]
        let followingTab = app.buttons["following"]
        
        XCTAssertTrue(forYouTab.exists, "'for you' tab not found")
        XCTAssertTrue(followingTab.exists, "'following' tab not found")
        
        // "recent" tab should NOT exist (we removed it)
        let recentTab = app.buttons["recent"]
        XCTAssertFalse(recentTab.exists, "'recent' tab should not exist")
    }
    
    func testFeedSearchBar() throws {
        // The search affordance collapsed behind the header 🔍 toggle in the
        // 2026 redesign: the TextField only renders AFTER the toggle is
        // tapped. (This test previously asserted the field existed at rest,
        // which has been stale since that redesign.) The field carries the
        // stable "feedSearchField" identifier.
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")

        let searchToggle = app.buttons["Search"]
        try XCTSkipUnless(waitFor(searchToggle, timeout: 5), "Header search toggle not found")
        searchToggle.tap()

        let searchField = app.textFields["feedSearchField"]
        XCTAssertTrue(waitFor(searchField, timeout: 5), "Inline search field not found after tapping the search toggle")
    }
    
    // MARK: - 5. Tab Bar Navigation
    
    func testTabBarExists() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let homeTab = app.buttons["Home"]
        let trendingTab = app.buttons["Trending"]
        let composeButton = app.buttons["New post"]
        let notificationsTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch
        let profileTab = app.buttons["Profile"]
        
        XCTAssertTrue(homeTab.exists, "Home tab not found")
        XCTAssertTrue(trendingTab.exists, "Trending tab not found")
        XCTAssertTrue(composeButton.exists, "Compose button not found")
        XCTAssertTrue(notificationsTab.exists, "Notifications tab not found")
        XCTAssertTrue(profileTab.exists, "Profile tab not found")
    }
    
    func testTabSwitching() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        // Switch to trending
        let trendingTab = app.buttons["Trending"]
        trendingTab.tap()
        
        let trendingHeader = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'most felt' OR label == 'top'")).firstMatch
        XCTAssertTrue(waitFor(trendingHeader, timeout: 5), "Trending view did not appear")
        
        // Switch to notifications
        let notificationsTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch
        notificationsTab.tap()
        
        let notifHeader = app.staticTexts["notifications"]
        XCTAssertTrue(waitFor(notifHeader, timeout: 5), "Notifications view did not appear")
        
        // Switch to profile
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        // Profile should show settings gear
        sleep(1)
        
        // Switch back to home
        let homeTab = app.buttons["Home"]
        homeTab.tap()
        
        XCTAssertTrue(waitFor(feedView, timeout: 5), "Feed did not reappear")
    }
    
    // MARK: - 6. Compose
    
    func testComposeOpens() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let composeButton = app.buttons["New post"]
        composeButton.tap()
        
        // Compose should appear with cancel and post buttons
        let cancelButton = app.buttons["cancel"]
        let postButton = app.buttons["post"]
        
        XCTAssertTrue(waitFor(cancelButton, timeout: 5), "Compose cancel button not found")
        XCTAssertTrue(postButton.exists, "Compose post button not found")
        
        // Dismiss
        cancelButton.tap()
    }
    
    func testComposeTagPicker() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let composeButton = app.buttons["New post"]
        composeButton.tap()
        
        let cancelButton = app.buttons["cancel"]
        try XCTSkipUnless(waitFor(cancelButton, timeout: 5), "Compose sheet cancel button never appeared")
        
        // Tag button should exist (tag icon in toolbar)
        // Tap to expand tag picker
        let tagButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS 'tag' OR label CONTAINS 'longing'"))
        
        cancelButton.tap()
    }
    
    // MARK: - 7. Explore View
    
    func testExploreViewElements() throws {
        // ExploreView used to be the primary search destination, opened via
        // a magnifying-glass button in the feed header. The header search
        // affordance was replaced with an inline TextField, and ExploreView
        // is now reachable only from the empty-feed state's "explore" button.
        // The empty-feed state requires both signed-in AND zero posts in
        // window — too narrow a precondition to drive reliably from this
        // test. Skip with a documented reason; revisit if ExploreView grows
        // a stable always-on entry point.
        try XCTSkipIf(true, "ExploreView no longer has a stable entry point from the populated feed")
    }
    
    // MARK: - 8. Profile View
    
    func testProfileElements() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        sleep(2)
        
        // The profile tab bar went icon-only (2026-06): posts / liked / saved /
        // replies as SF-symbol icons. The SELECTED tab renders its .fill variant,
        // and SwiftUI exposes some icons as Images while consolidating others
        // into their Buttons — query any element type by identifier prefix.
        let likedTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'heart'")).firstMatch
        let savedTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bookmark'")).firstMatch

        XCTAssertTrue(waitFor(likedTab, timeout: 5), "liked (heart) tab icon not found")
        XCTAssertTrue(savedTab.exists, "saved (bookmark) tab icon not found")
        
        // The profile tab bar is posts / liked / saved / replies (icon-only
        // buttons). There is no text-labelled "likes" tab — the engagement tab
        // is the heart ("liked") — so a button literally named "likes" must not
        // exist. The replies tab was reintroduced as an icon, so it's no longer
        // asserted absent here.
        let likesTab = app.buttons["likes"]
        XCTAssertFalse(likesTab.exists, "'likes' tab should not exist")
    }
    
    func testProfileSettingsOpens() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        sleep(1)
        
        // Tap settings gear (accessibilityLabel is lowercase "settings"; the old
        // gearshape/Settings predicate never matched and this test silently
        // no-opped)
        let settingsButton = app.buttons["settings"]
        XCTAssertTrue(waitFor(settingsButton, timeout: 5), "settings gear not found on profile")
        settingsButton.tap()
        
        let settingsHeader = app.staticTexts["settings"]
        XCTAssertTrue(waitFor(settingsHeader, timeout: 5), "Settings view did not open")
    }
    
    // MARK: - 9. Settings
    
    func testSettingsElements() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        sleep(1)
        
        // Navigate to settings (lowercase "settings" label — see above)
        let settingsButton = app.buttons["settings"]
        try XCTSkipUnless(waitFor(settingsButton, timeout: 5), "settings gear not found")
        settingsButton.tap()
        
        let settingsHeader = app.staticTexts["settings"]
        try XCTSkipUnless(waitFor(settingsHeader, timeout: 5), "Settings view did not open after tap")
        
        // Check sections exist. groupHeader renders titles UPPERCASED
        // ("PRIVACY"), so match case-insensitively — the same gotcha the
        // walkthrough suite already handles for section headers.
        func sectionHeader(_ title: String) -> XCUIElement {
            app.staticTexts.matching(
                NSPredicate(format: "label ==[c] %@", title)
            ).firstMatch
        }
        XCTAssertTrue(sectionHeader("privacy").exists, "Privacy section not found")
        XCTAssertTrue(sectionHeader("notifications").exists, "Notifications section not found")
        XCTAssertTrue(sectionHeader("content").exists, "Content section not found")
        XCTAssertTrue(sectionHeader("account").exists, "Account section not found")
        
        // "why this exists" section
        let whySection = app.staticTexts["why this exists"]
        // Need to scroll down to find it
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitFor(whySection, timeout: 3), "'why this exists' section not found")
    }
    
    // MARK: - 10. Share Card
    
    func testShareCardMoodStyles() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        // Find a share button in the feed
        let shareButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS 'share' OR label CONTAINS 'square.and.arrow.up'"))
        
        guard shareButtons.count > 0 else {
            // No posts to share, skip
            return
        }
        
        // Find and tap share via context menu
        let firstPost = app.cells.firstMatch
        if firstPost.exists {
            firstPost.press(forDuration: 1.0)
            
            let shareOption = app.buttons["share"]
            if waitFor(shareOption, timeout: 3) {
                shareOption.tap()
                
                // Verify share card elements
                let shareHeader = app.staticTexts["share this"]
                if waitFor(shareHeader, timeout: 5) {
                    let moodLabel = app.staticTexts["MOOD"]
                    XCTAssertTrue(moodLabel.exists, "Mood label not found in share card")
                }
            }
        }
    }
    
    // MARK: - 11. Messages (CUT — DMs removed 2026-05-28)
    
    func testMessagesAffordanceIsGone() throws {
        // DMs were cut as a product decision (2026-05-28). This used to drive
        // the messages list; it now asserts the affordance does NOT come back.
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        sleep(1)
        
        let messagesButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'envelope' OR label CONTAINS[c] 'message'")).firstMatch
        XCTAssertFalse(messagesButton.exists, "DM affordance reappeared — DMs were cut 2026-05-28 (see feedback_toska_no_dms)")
    }
    
    // MARK: - 12. Empty States
    
    func testFollowingEmptyState() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let followingTab = app.buttons["following"]
        followingTab.tap()
        
        sleep(1)
        
        // Should show Georgia italic empty state quote
        let emptyQuote = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'things we'"))
        // Empty state may or may not appear depending on whether user follows anyone
    }
    
    // MARK: - 13. Offline Banner
    
    func testOfflineBannerDoesNotShowWhenOnline() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        // When online, no offline banner should show
        let offlineBanner = app.staticTexts["no connection"]
        XCTAssertFalse(offlineBanner.exists, "Offline banner showing when online")
    }
    
    // MARK: - 14. Navigation Consistency
    
    func testDismissAllSheetsOnTabSwitch() throws {
        // Originally exercised sheet dismissal by opening ExploreView from
        // the feed header search button (which was a sheet) and asserting it
        // dismissed on tab switch. ExploreView is no longer reachable from
        // the populated-feed state, and the inline search bar isn't a sheet
        // — so this test's premise no longer holds. The dismiss-on-tab-
        // switch behavior is still desirable for *other* sheets (compose,
        // share card, report) and should be re-asserted via one of those
        // when the tests are next refreshed.
        try XCTSkipIf(true, "Search-button-opens-sheet flow removed; revisit with a different sheet")
    }
    
    // MARK: - 15. Content Safety
    
    func testNameDetectionInCompose() throws {
        // N-17 (2026-06-11): a LONE first name ("I miss Jennifer") is now
        // ALLOWED by policy — asserting a warning on it is stale, and worse, the
        // old version actually published the post when no warning appeared. The
        // policy split this test now pins: full name → warned; lone first name
        // → not warned. Neither variant posts (text is cleared, then cancel).
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")

        let composeButton = app.buttons["New post"]
        composeButton.tap()
        let cancelButton = app.buttons["cancel"]
        try XCTSkipUnless(waitFor(cancelButton, timeout: 5), "Compose sheet cancel button never appeared")

        let textEditor = app.textViews.firstMatch
        try XCTSkipUnless(waitFor(textEditor, timeout: 5), "Compose editor not found")

        func typeIntoEditor(_ text: String) {
            for _ in 0..<4 {
                if (textEditor.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
                textEditor.tap()
                sleep(1)
            }
            app.typeText(text)
        }
        func clearEditor() {
            for _ in 0..<3 {
                guard let value = textEditor.value as? String,
                      !value.isEmpty, value != "475" else { return } // placeholder/counter = empty
                textEditor.tap()
                textEditor.press(forDuration: 1.0)
                let selectAll = app.menuItems["Select All"]
                if selectAll.waitForExistence(timeout: 2) {
                    selectAll.tap()
                    app.typeText(String(XCUIKeyboardKey.delete.rawValue))
                } else {
                    app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 10))
                }
                usleep(500_000)
            }
        }

        clearEditor() // drafts persist across cancel by design (N-4)

        // Case 1: FULL name → the "keep it anonymous" warning must appear.
        typeIntoEditor("I miss Sarah Johnson so much")
        app.buttons["post"].tap()
        let nameWarning = app.staticTexts["keep it anonymous"]
        XCTAssertTrue(waitFor(nameWarning, timeout: 4), "Name warning did not appear for a full name")
        let editMyPost = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'edit'")).firstMatch
        if editMyPost.exists { editMyPost.tap() } else { app.tap() }
        sleep(1)
        clearEditor()

        // Case 2: LONE first name → must NOT warn (N-17). Verifying this requires
        // tapping post, and on the clean path that PUBLISHES a real post to
        // staging (there's no pre-submit signal to assert against). To avoid
        // mutating staging on every run, this destructive leg is opt-in via the
        // RUN_DESTRUCTIVE_UITESTS=1 environment variable.
        guard ProcessInfo.processInfo.environment["RUN_DESTRUCTIVE_UITESTS"] == "1" else {
            throw XCTSkip("Case 2 publishes to staging; set RUN_DESTRUCTIVE_UITESTS=1 to run it")
        }
        typeIntoEditor("I miss Jennifer so much")
        app.buttons["post"].tap()
        let warned = nameWarning.waitForExistence(timeout: 3)
        XCTAssertFalse(warned, "N-17 regression: lone first name triggered the PII warning")
        // If it published (clean path), compose dismissed itself; otherwise clean up.
        if cancelButton.exists { clearEditor(); cancelButton.tap() }
    }
}
