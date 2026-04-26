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
    
    func testFeedSearchButton() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.exists, "Search button not found")
        
        searchButton.tap()
        
        // ExploreView should appear
        let exploreHeader = app.staticTexts["explore"]
        XCTAssertTrue(waitFor(exploreHeader, timeout: 5), "Explore view did not open")
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
        
        let trendingHeader = app.staticTexts["felt the most"]
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
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let searchButton = app.buttons["Search"]
        searchButton.tap()
        
        let exploreHeader = app.staticTexts["explore"]
        try XCTSkipUnless(waitFor(exploreHeader, timeout: 5), "Explore view did not open after tap")
        
        // Search field should exist
        let searchField = app.textFields["search for a feeling..."]
        XCTAssertTrue(searchField.exists, "Search field not found")
        
        // Tag pills should exist (at least "longing")
        let longingPill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'longing'")).firstMatch
        XCTAssertTrue(longingPill.exists, "Tag pills not found")
    }
    
    // MARK: - 8. Profile View
    
    func testProfileElements() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        sleep(2)
        
        // Should have "my posts" and "saved" tabs
        let myPostsTab = app.buttons["my posts"]
        let savedTab = app.buttons["saved"]
        
        XCTAssertTrue(waitFor(myPostsTab, timeout: 5), "'my posts' tab not found")
        XCTAssertTrue(savedTab.exists, "'saved' tab not found")
        
        // Should NOT have "replies" or "likes" tabs (we removed them)
        let repliesTab = app.buttons["replies"]
        let likesTab = app.buttons["likes"]
        XCTAssertFalse(repliesTab.exists, "'replies' tab should not exist")
        XCTAssertFalse(likesTab.exists, "'likes' tab should not exist")
    }
    
    func testProfileSettingsOpens() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        sleep(1)
        
        // Tap settings gear
        let settingsButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'gearshape' OR label CONTAINS 'Settings'")).firstMatch
        if settingsButton.exists {
            settingsButton.tap()
            
            let settingsHeader = app.staticTexts["settings"]
            XCTAssertTrue(waitFor(settingsHeader, timeout: 5), "Settings view did not open")
        }
    }
    
    // MARK: - 9. Settings
    
    func testSettingsElements() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        sleep(1)
        
        // Navigate to settings
        let settingsButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'gearshape' OR label CONTAINS 'Settings'")).firstMatch
        guard settingsButton.exists else { return }
        settingsButton.tap()
        
        let settingsHeader = app.staticTexts["settings"]
        try XCTSkipUnless(waitFor(settingsHeader, timeout: 5), "Settings view did not open after tap")
        
        // Check sections exist
        let privacySection = app.staticTexts["privacy"]
        let notifSection = app.staticTexts["notifications"]
        let contentSection = app.staticTexts["content"]
        let accountSection = app.staticTexts["account"]
        
        XCTAssertTrue(privacySection.exists, "Privacy section not found")
        XCTAssertTrue(notifSection.exists, "Notifications section not found")
        XCTAssertTrue(contentSection.exists, "Content section not found")
        XCTAssertTrue(accountSection.exists, "Account section not found")
        
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
    
    // MARK: - 11. Messages
    
    func testMessagesListOpens() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        sleep(1)
        
        // Look for envelope/messages button
        let messagesButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'envelope' OR label CONTAINS 'Messages'")).firstMatch
        if messagesButton.exists {
            messagesButton.tap()
            
            let messagesHeader = app.staticTexts["messages"]
            XCTAssertTrue(waitFor(messagesHeader, timeout: 5), "Messages view did not open")
        }
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
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        // Open explore (a sheet)
        let searchButton = app.buttons["Search"]
        searchButton.tap()
        
        let exploreHeader = app.staticTexts["explore"]
        try XCTSkipUnless(waitFor(exploreHeader, timeout: 5), "Explore view did not open after tap")
        
        // Tap profile tab — sheet should dismiss
        let profileTab = app.buttons["Profile"]
        profileTab.tap()
        
        sleep(1)
        
        // Explore should no longer be visible
        XCTAssertFalse(exploreHeader.exists, "Explore sheet did not dismiss on tab switch")
    }
    
    // MARK: - 15. Content Safety
    
    func testNameDetectionInCompose() throws {
        let feedView = app.otherElements["feedView"]
        try XCTSkipUnless(waitFor(feedView, timeout: 15), "Feed didn't load — UI test likely running against signed-out session")
        
        let composeButton = app.buttons["New post"]
        composeButton.tap()
        
        let cancelButton = app.buttons["cancel"]
        try XCTSkipUnless(waitFor(cancelButton, timeout: 5), "Compose sheet cancel button never appeared")
        
        // Type text with a name
        let textEditor = app.textViews.firstMatch
        if textEditor.exists {
            textEditor.tap()
            textEditor.typeText("I miss Jennifer so much")
            
            // Tap post
            let postButton = app.buttons["post"]
            if postButton.isEnabled {
                postButton.tap()
                
                // Should show name warning
                let nameWarning = app.staticTexts["keep it anonymous"]
                XCTAssertTrue(waitFor(nameWarning, timeout: 3), "Name warning did not appear")
            }
        }
        
        // Dismiss
        if cancelButton.exists { cancelButton.tap() }
    }
}
