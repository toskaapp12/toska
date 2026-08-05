import XCTest

/// Live-drive of the share card sheet (2026-07-31 overhaul): opens a real
/// post's share sheet on staging and exercises every control — moods, the
/// custom color well (must open the system wheel — regression: the old
/// invisible-overlay picker never received taps on device), fonts, sizes,
/// alignment, ratios, felt toggle, fragment picker, save, share — with
/// screenshots at each step. Run serially against a booted sim:
///   xcodebuild test -only-testing:toskaUITests/ShareCardInteractionTests
///     -parallel-testing-enabled NO -destination 'id=<UDID>'
/// Requires TEST_RUNNER_TOSKA_STAGING_TEST_PW in the environment.
final class ShareCardInteractionTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: helpers (mirrors WalkthroughUITests)

    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    func forceTap(_ element: XCUIElement) {
        if element.isHittable { element.tap() }
        else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    var feedView: XCUIElement { app.buttons["for you"] }

    func loginIfNeeded() throws {
        if waitFor(app.buttons["sign in"], 8) {
            app.buttons["sign in"].tap()
            let email = app.textFields["emailField"]
            XCTAssertTrue(waitFor(email, 8), "Email field missing")
            email.tap(); email.typeText("salinarotess+nice@gmail.com")
            let pw = app.secureTextFields["passwordField"]
            guard let stagingPw = ProcessInfo.processInfo.environment["TOSKA_STAGING_TEST_PW"] else {
                XCTFail("TOSKA_STAGING_TEST_PW not set — see .local-credentials.md"); return
            }
            pw.tap(); pw.typeText(stagingPw)
            app.buttons["signInButton"].tap()
            // "Save Password?" system sheet can eat every later tap.
            let notNow = app.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        }
        XCTAssertTrue(waitFor(feedView, 30), "Feed didn't load")
        // Policy re-acceptance gate (stale staging sessions).
        let agree = app.buttons["i agree and continue"]
        if agree.waitForExistence(timeout: 3) {
            let checkbox = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "i confirm i am 17 or older")
            ).firstMatch
            if checkbox.waitForExistence(timeout: 2) { checkbox.tap() }
            forceTap(agree)
        }
    }

    /// Open the share sheet from a visible shareable feed row, preferring a
    /// row near a LONG post (fragment section needs >120 chars) — scan the
    /// visible Share buttons and pick the one whose neighboring row text is
    /// longest. label.length isn't a valid AX predicate key, so filter in
    /// Swift.
    func openShareSheet() {
        var share = app.buttons["Share post"].firstMatch
        XCTAssertTrue(waitFor(share, 15), "No shareable post row found")
        // Tap the first Share button, keeping it out of the floating-bar
        // band (taps there get eaten); retry up to 3 times.
        for _ in 0..<3 {
            share = app.buttons["Share post"].firstMatch
            guard share.exists else { break }
            if share.frame.maxY > app.frame.maxY - 180 || share.frame.minY < 120 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05,
                            thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
                usleep(700_000)
                share = app.buttons["Share post"].firstMatch
            }
            forceTap(share)
            if waitFor(app.staticTexts["share this"], 6) { break }
        }
        XCTAssertTrue(app.staticTexts["share this"].exists, "Share sheet didn't open")
        // First-open transparency hint ("sharing, quietly") blocks the sheet
        // until acknowledged — dismiss it (once-only per install).
        let gotIt = app.buttons["got it"]
        if gotIt.waitForExistence(timeout: 4) { gotIt.tap(); sleep(1) }
    }

    /// Scroll the share sheet's content so below-the-fold controls (more
    /// options, fragment section) rise above the pinned save/share bar —
    /// coordinate taps on controls hidden behind that bar hit the bar.
    func scrollSheetUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: -350)))
        usleep(700_000)
    }

    // MARK: the whole drive, in order

    func test_shareCard_fullDrive() throws {
        try loginIfNeeded()
        openShareSheet()
        snap("01-sheet-initial")

        // ---- Mood row navigation: chips beyond the right edge can't even
        // answer isHittable ("activation point invalid"), so drag the row by
        // coordinates (anchored at the row's y) until the target's frame is
        // fully on screen.
        let dawn = app.buttons["dawn"]
        XCTAssertTrue(waitFor(dawn, 5), "dawn chip missing — mood row absent")
        let rowY = dawn.frame.midY

        func chipVisible(_ e: XCUIElement) -> Bool {
            e.exists && e.frame.width > 1 && e.frame.minX >= 0
                && e.frame.maxX <= app.frame.width
        }
        func swipeMoodRowLeft() {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.85, dy: rowY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.12, dy: rowY))
            start.press(forDuration: 0.05, thenDragTo: end)
            usleep(700_000)
        }
        func reveal(_ e: XCUIElement) {
            for _ in 0..<8 where !chipVisible(e) { swipeMoodRowLeft() }
        }

        // Select dusk, verify the selection trait sticks.
        let dusk = app.buttons["dusk"]
        reveal(dusk)
        XCTAssertTrue(chipVisible(dusk), "dusk chip not reachable by scrolling")
        dusk.tap()
        sleep(1)
        XCTAssertTrue(dusk.isSelected, "dusk chip did not report selected")
        snap("02-dusk-selected")

        // ---- Custom color: scroll to the end of the row, tap the WELL.
        let well = app.colorWells.firstMatch
        reveal(well)
        XCTAssertTrue(chipVisible(well), "Custom color well not found in mood row")
        snap("03-custom-chip-visible")
        forceTap(well)

        // CORE ASSERTION: the system color picker must actually open.
        let wheelOpened = waitFor(app.staticTexts["Colors"], 6)
            || app.buttons["Grid"].exists || app.buttons["Spectrum"].exists
        snap("04-color-wheel")
        XCTAssertTrue(wheelOpened, "Tapping the color well did NOT open the system color picker")

        // Pick a color from the grid (tap a coordinate inside the grid area),
        // then close the picker sheet.
        if app.buttons["Grid"].exists { app.buttons["Grid"].tap(); sleep(1) }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
        sleep(1)
        snap("05-color-picked")
        let close = app.buttons["close"].exists ? app.buttons["close"] : app.buttons["Close"]
        if close.exists { close.tap() } else { app.swipeDown() }
        sleep(1)
        snap("06-card-custom-color")
        // Custom chip should now be the selected mood.
        let customChip = app.otherElements["Custom color"].firstMatch
        if customChip.exists {
            XCTAssertTrue(customChip.isSelected, "Custom mood not selected after picking a color")
        }

        // ---- Font cycle: serif → sans → typewriter → hand → serif.
        for expected in ["sans", "typewriter", "hand", "serif"] {
            let cycler = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Font:")
            ).firstMatch
            XCTAssertTrue(cycler.exists, "Font cycle button missing")
            forceTap(cycler)
            usleep(600_000)
            XCTAssertTrue(
                app.buttons["Font: \(expected). Tap to change."].exists,
                "Font cycle did not advance to \(expected)")
        }
        snap("07-fonts-cycled")

        // ---- Size + alignment.
        forceTap(app.buttons["Large text"])
        forceTap(app.buttons["Align left"])
        usleep(600_000)
        XCTAssertTrue(app.buttons["Large text"].isSelected, "Large size not selected")
        XCTAssertTrue(app.buttons["Align left"].isSelected, "Left align not selected")
        snap("08-large-left")

        // ---- Ratio: reveal more options, switch to square. The options row
        // sits below the fold — scroll it clear of the pinned share bar first.
        scrollSheetUp()
        snap("08b-scrolled-to-options")
        forceTap(app.buttons["Show shape and felt-count options"])
        sleep(1)
        let square = app.buttons["square"]
        XCTAssertTrue(waitFor(square, 5), "square ratio button missing")
        forceTap(square)
        sleep(1)
        XCTAssertTrue(square.isSelected, "square ratio not selected")
        snap("09-square")

        // ---- Felt count toggle (only present when feltCount > 0).
        let feltToggle = app.buttons["Hide felt count"]
        if feltToggle.exists {
            forceTap(feltToggle)
            usleep(400_000)
            XCTAssertTrue(app.buttons["Show felt count"].exists, "Felt toggle didn't flip")
            forceTap(app.buttons["Show felt count"])
        }

        // ---- Fragment picker (present only for long multi-sentence posts).
        let fragToggle = app.buttons["Share just a line"]
        if fragToggle.exists {
            // Snapshot the toggle's position BEFORE tapping: the tap flips its
            // accessibility label to "Hide line picker", so any later read of
            // `fragToggle.frame` re-runs the "Share just a line" query, finds
            // nothing, and fails the test with a snapshot error instead of
            // exercising the picker.
            let toggleMinY = fragToggle.frame.minY
            forceTap(fragToggle)
            sleep(1)
            snap("10-fragment-picker-open")
            // Tap the first sentence row (a plain button inside the section
            // whose label is the sentence text — first long-labeled button
            // below the toggle; length filtering must happen in Swift).
            let sentenceRow = app.buttons.allElementsBoundByIndex.first(where: {
                $0.exists && $0.frame.minY > toggleMinY
                    && $0.label.count > 15 && !$0.label.hasPrefix("Font:")
            })
            if let row = sentenceRow {
                forceTap(row)
                sleep(1)
                snap("11-fragment-selected")
                XCTAssertTrue(
                    app.buttons.matching(NSPredicate(format: "label CONTAINS 'sharing'")).firstMatch.exists
                        || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sharing'")).firstMatch.exists,
                    "Fragment selection did not update the label")
                // Back to full post so save/share test the normal path.
                let whole = app.buttons["share the whole post"]
                if whole.exists { forceTap(whole) }
            }
        } else {
            snap("10-no-fragment-section-short-post")
        }

        // ---- Save to Photos (grant permission at the system prompt).
        forceTap(app.buttons["Save to Photos"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for grantLabel in ["Allow Full Access", "Allow Access to All Photos", "Add Photos Only", "OK"] {
            let b = springboard.buttons[grantLabel]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
        let savedText = app.staticTexts["saved to your photos"]
        XCTAssertTrue(waitFor(savedText, 15), "Save confirmation never appeared")
        snap("12-saved-confirmation")
        forceTap(app.buttons["okay"])
        sleep(1)

        // ---- Share: system sheet must appear; cancel must NOT celebrate.
        forceTap(app.buttons["Share"])
        let activitySheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(waitFor(activitySheet, 15), "System share sheet didn't appear")
        snap("13-share-sheet")
        // Dismiss (drag the sheet down); confirmation must not show.
        activitySheet.swipeDown()
        sleep(2)
        XCTAssertFalse(
            app.staticTexts["someone's going to feel less alone\nbecause of what you just shared"].exists,
            "Cancel celebrated as if shared")
        snap("14-share-cancelled")

        // ---- Persistence: the saved look must survive a relaunch.
        forceTap(app.buttons["Close"])
        sleep(1)
        app.terminate()
        app.launch()
        try loginIfNeeded()
        openShareSheet()
        sleep(1)
        snap("15-relaunch-sheet")
        // The look used at SAVE time (custom color + serif + large + left +
        // square, felt back on) must be restored. Ratio lives behind "more
        // options" — check the always-visible ones via traits.
        XCTAssertTrue(app.buttons["Large text"].isSelected, "Size did not persist across relaunch")
        XCTAssertTrue(app.buttons["Align left"].isSelected, "Alignment did not persist across relaunch")
        scrollSheetUp()
        forceTap(app.buttons["Show shape and felt-count options"])
        sleep(1)
        XCTAssertTrue(app.buttons["square"].isSelected, "Ratio did not persist across relaunch")
        snap("16-persisted-look")
    }
}
