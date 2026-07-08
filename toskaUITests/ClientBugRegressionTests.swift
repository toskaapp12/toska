import XCTest

// MARK: - Client-bug regression suite (2026-07-07)
//
// Pins four previously-fixed client bugs against the REAL staging backend
// (no UI_TESTING shortcuts — real auth, real Firestore, real rate limiter).
// Conventions copied from WalkthroughUITests: waitFor/forceTap helpers,
// snap() keepAlways screenshots, numbered methods (XCTest runs alphabetically),
// keychain-persisted auth (each launch usually lands straight on the feed).
//
// Regressions covered:
//   1. test01_editPostPersistsAfterSave — PostDetailView H3: saving an edit
//      used to revert the visible text to the pre-edit value on pop/re-push
//      (the live listener now mirrors server truth; currentText binding
//      updates immediately on save).
//   2. test02_letterDraftNotTruncated — ComposeView/EditPostView charLimit
//      floor: reopening a >500-char letter draft used to silently truncate
//      it to 500 (drafts persist text but not isLetter; ComposeView.onAppear
//      now restores letter mode when initialText exceeds the 500 cap).
//   3. testReplySendAppears — cheap proxy for the reply-offline guard fix.
//   4. test03_saveStateNoDrift — bookmark state drifted between the feed row
//      and post detail after navigating in and back.
//
// Staging test account: salinarotess+nice@gmail.com (seeded).
// Data hygiene: no new posts are created (rate limiter!) — tests edit an
// existing own post and restore it, create + delete one draft, and send one
// reply (best-effort deleted afterwards).

final class ClientBugRegressionTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: helpers (conventions from WalkthroughUITests)

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

    /// Type into an editor reliably. Sheets auto-focus their editor via a
    /// focusTask which races with a test-driven tap — re-tap until
    /// hasKeyboardFocus, then type at the app level. Long strings are typed
    /// in chunks (single 600-char typeText calls drop characters sometimes).
    func focusAndType(_ element: XCUIElement, _ text: String) {
        for _ in 0..<4 {
            if (element.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            element.tap()
            sleep(1)
        }
        typeInChunks(text)
    }

    func typeInChunks(_ text: String) {
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(150)
            app.typeText(String(chunk))
            remaining = remaining.dropFirst(chunk.count)
        }
    }

    /// Replace an editor's entire content: focus, Select All, delete, retype.
    func selectAllAndType(_ editor: XCUIElement, _ text: String) {
        for _ in 0..<4 {
            if (editor.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            editor.tap()
            sleep(1)
        }
        if let value = editor.value as? String, !value.isEmpty {
            editor.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 3) {
                selectAll.tap()
                app.typeText(String(XCUIKeyboardKey.delete.rawValue))
            } else {
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 10))
            }
        }
        typeInChunks(text)
    }

    /// Compose drafts persist across cancel by design (N-4 DraftStore) — clear
    /// the editor by deleting everything so a leaked buffer from a previous
    /// session doesn't contaminate this test (a leaked >500-char buffer would
    /// even auto-enable letter mode).
    func clearComposeEditor() {
        let editor = app.textViews.firstMatch
        guard editor.exists else { return }
        editor.tap()
        if let value = editor.value as? String, !value.isEmpty {
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

    // Feed anchor — the "for you" tab is unique to the logged-in feed (the old
    // "feedView" identifier no longer matches a single element).
    var feedView: XCUIElement { app.buttons["for you"] }

    /// Log in if we're at the splash (auth normally persists via keychain, so
    /// this is a no-op on every launch after the first).
    func ensureLoggedIn(file: StaticString = #filePath, line: UInt = #line) throws {
        if app.buttons["sign in"].waitForExistence(timeout: 5) {
            app.buttons["sign in"].tap()
            let email = app.textFields["emailField"]
            XCTAssertTrue(waitFor(email, 8), "Email field missing", file: file, line: line)
            email.tap()
            email.typeText("salinarotess+nice@gmail.com")
            let password = app.secureTextFields["passwordField"]
            password.tap()
            password.typeText("[REDACTED-ROTATED]")
            app.buttons["signInButton"].tap()
        }
        try XCTSkipUnless(waitFor(feedView, 30), "Feed not visible — not logged in?", file: file, line: line)
    }

    /// A per-run unique marker (keeps text predicates unambiguous and lets
    /// re-runs never collide with leftover data from an aborted run).
    static let nonce = String(Int(Date().timeIntervalSince1970) % 100_000)

    /// Feed/profile rows are buttons labelled "handle, age, text, tag" — find
    /// a row whose text we know is seeded on staging, scrolling a little if
    /// it isn't in the first screenful.
    func findRow(matching predicate: NSPredicate, swipes: Int = 3) -> XCUIElement? {
        let row = app.buttons.matching(predicate).firstMatch
        for attempt in 0...swipes {
            if row.waitForExistence(timeout: attempt == 0 ? 10 : 2) { return row }
            app.swipeUp()
        }
        return nil
    }

    var seededPostPredicate: NSPredicate {
        NSPredicate(format: "label CONTAINS 'first light' OR label CONTAINS 'the quiet' OR label CONTAINS 'storm'")
    }

    /// Feed action buttons (repost/like/save/share) are SIBLINGS of the row's
    /// NavigationLink in the accessibility tree, so they can't be scoped as
    /// descendants — match by geometry instead: the action row sits directly
    /// under the row's text block.
    func enabledActionButton(_ label: String, near row: XCUIElement) -> XCUIElement? {
        guard row.exists else { return nil }
        let rowFrame = row.frame
        let query = app.buttons.matching(NSPredicate(format: "label == %@ AND enabled == true", label))
        let count = min(query.count, 12)
        for i in 0..<count {
            let el = query.element(boundBy: i)
            guard el.exists else { continue }
            let y = el.frame.midY
            if y >= rowFrame.minY - 8 && y <= rowFrame.maxY + 80 { return el }
        }
        return nil
    }

    func waitForActionButton(_ label: String, near row: XCUIElement, _ timeout: TimeInterval = 8) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let el = enabledActionButton(label, near: row) { return el }
            usleep(500_000)
        } while Date() < deadline
        return nil
    }

    /// EditPostView's save can be interrupted by the anonymity alert or the
    /// gentle crisis check-in (e.g. when restoring a grief-flavored original
    /// text). Proceed through both so the save actually lands.
    func proceedThroughEditInterstitials() {
        let saveAnyway = app.buttons["save anyway"]
        if saveAnyway.waitForExistence(timeout: 2) { saveAnyway.tap() }
        // CrisisCheckInView proceed label is "i'm safe. share it." / "i'm okay. share it."
        let proceed = app.buttons.matching(NSPredicate(format: "label CONTAINS 'share it'")).firstMatch
        if proceed.waitForExistence(timeout: 2) { forceTap(proceed) }
    }

    /// Push into EditPostView from an open post detail (••• → "edit post").
    /// Returns the editor element, or fails the test.
    func openEditPost(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // The ••• starts at opacity 0 while the author id loads — generous wait.
        let more = app.buttons["Edit or delete post"]
        XCTAssertTrue(waitFor(more, 15), "••• (Edit or delete post) not found — not our own post?", file: file, line: line)
        forceTap(more)
        let editItem = app.buttons["edit post"]
        XCTAssertTrue(waitFor(editItem, 5), "'edit post' menu item missing", file: file, line: line)
        editItem.tap()
        XCTAssertTrue(waitFor(app.staticTexts["edit post"], 8), "EditPostView didn't open", file: file, line: line)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(waitFor(editor, 5), "Edit editor missing", file: file, line: line)
        return editor
    }

    // MARK: 01 — edit-post revert (PostDetailView H3)
    //
    // Saving an edit must show the NEW text on the detail page immediately AND
    // after popping back and re-pushing the post (the live listener used to
    // revert the visible text to the init-seeded pre-edit value). Restores the
    // original text afterwards — no new posts are created (rate limiter).
    func test01_editPostPersistsAfterSave() throws {
        try ensureLoggedIn()
        let marker = "rgredit\(Self.nonce)"

        // Own posts live on the Profile tab. Prefer the calm seeded walkthrough
        // post; fall back to any "(walkthrough)" post.
        app.buttons["Profile"].tap()
        sleep(2)
        XCTAssertTrue(waitFor(app.buttons["settings"], 8), "Not on profile (settings gear missing)")
        var row = findRow(matching: NSPredicate(format: "label CONTAINS 'quiet after the storm'"), swipes: 2)
        if row == nil {
            row = findRow(matching: NSPredicate(format: "label CONTAINS '(walkthrough)'"), swipes: 2)
        }
        guard let ownRow = row else {
            throw XCTSkip("No seeded own post found on profile — run WalkthroughUITests once to seed one")
        }
        forceTap(ownRow)
        XCTAssertTrue(waitFor(app.staticTexts["post"], 8), "Post detail didn't open")
        snap("01a-own-post-detail")

        // Edit: capture the original, replace the whole body with marker text.
        var editor = openEditPost()
        let original = (editor.value as? String) ?? ""
        XCTAssertFalse(original.isEmpty, "Editor opened empty — edit would clobber the post")
        let newText = "i rewrote this for a moment and it will be restored shortly. \(marker)"
        selectAllAndType(editor, newText)
        snap("01b-edit-typed")
        let save = app.buttons["save"]
        XCTAssertTrue(save.isEnabled, "save disabled — select-all replace didn't change the text?")
        save.tap()
        proceedThroughEditInterstitials()

        // Back on detail: the NEW text must be visible (H3 regression: it
        // used to revert to the pre-edit value).
        XCTAssertTrue(waitFor(app.staticTexts["post"], 10), "Didn't return to post detail after save")
        let newTextOnDetail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(waitFor(newTextOnDetail, 10), "Edited text not shown on detail right after save (edit reverted)")
        snap("01c-detail-after-save")

        // Pop to profile, re-push the same post: server truth must still be
        // the new text (the listener must not resurrect the stale init seed).
        forceTap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(waitFor(app.buttons["settings"], 8), "Didn't pop back to profile")
        var editedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        if !waitFor(editedRow, 10) {
            app.swipeDown() // nudge a refresh if the list is stale
            editedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        }
        XCTAssertTrue(waitFor(editedRow, 10), "Edited post row not found on profile after edit")
        forceTap(editedRow)
        XCTAssertTrue(waitFor(app.staticTexts["post"], 8), "Post detail didn't re-open")
        let newTextOnRepush = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(waitFor(newTextOnRepush, 10), "Edited text lost after pop + re-push (H3 regression)")
        snap("01d-detail-after-repush")

        // Cleanup: restore the original text via a second edit.
        editor = openEditPost()
        selectAllAndType(editor, original)
        let save2 = app.buttons["save"]
        XCTAssertTrue(save2.isEnabled, "restore save disabled")
        save2.tap()
        proceedThroughEditInterstitials()
        XCTAssertTrue(waitFor(app.staticTexts["post"], 10), "Didn't return to detail after restore")
        let originalPrefix = String(original.prefix(20))
        let restored = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", originalPrefix)).firstMatch
        XCTAssertTrue(waitFor(restored, 10), "Original text not restored on detail")
        snap("01e-detail-restored")
    }

    // MARK: 02 — letter-draft truncation (ComposeView charLimit floor)
    //
    // Drafts persist `text` but NOT `isLetter`. Reopening a >500-char letter
    // draft used to run the 500-cap onChange truncation, silently destroying
    // up to 1500 chars. Fix: ComposeView.onAppear restores letter mode when
    // initialText exceeds the normal cap. Pin it end-to-end: compose a ~590-
    // char letter, save as draft, reopen from Settings → drafts, assert the
    // full text survives, then delete the draft.
    func test02_letterDraftNotTruncated() throws {
        try ensureLoggedIn()
        let marker = "rgrdraft\(Self.nonce)"

        app.buttons["New post"].tap()
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Compose didn't open")
        clearComposeEditor() // drafts persist across cancel — start clean

        // Letter mode: envelope glyph in the compose toolbar. A first-time
        // hint alert may appear — dismiss via "got it".
        let letterToggle = app.buttons["Letter mode"]
        XCTAssertTrue(waitFor(letterToggle, 5), "Letter mode toggle missing from compose toolbar")
        forceTap(letterToggle)
        let gotIt = app.buttons["got it"]
        if gotIt.waitForExistence(timeout: 3) { gotIt.tap() }
        XCTAssertTrue(waitFor(app.buttons["Letter mode on"], 5), "Letter mode didn't turn on")
        snap("02a-letter-mode-on")

        // ~590 chars: 9 × 64-char sentence + unique end marker. All lowercase,
        // no names/digits-clusters — must not trip PII or crisis matchers.
        let sentence = "the tide keeps coming back in and i keep learning to watch it. "
        let body = String(repeating: sentence, count: 9) + "\(marker) end"
        let editor = app.textViews.firstMatch
        focusAndType(editor, body)
        let typed = (editor.value as? String) ?? ""
        // Guard: if the letter toggle silently failed, the 500-cap truncation
        // already ate the tail while typing — fail HERE with a clear message
        // rather than misattributing it to the draft round-trip.
        XCTAssertGreaterThan(typed.utf16.count, 500, "Text truncated while typing — letter mode not active?")
        snap("02b-letter-typed")

        let saveDraft = app.buttons["Save as draft"]
        XCTAssertTrue(waitFor(saveDraft, 5), "Save-as-draft button missing")
        XCTAssertTrue(saveDraft.isEnabled, "Save-as-draft disabled")
        saveDraft.tap()
        // Successful save dismisses the compose sheet.
        let deadline = Date().addingTimeInterval(10)
        while app.buttons["cancel"].exists && Date() < deadline { usleep(500_000) }
        XCTAssertTrue(waitFor(feedView, 10), "Compose didn't dismiss after saving draft")

        // Settings → drafts.
        app.buttons["Profile"].tap()
        sleep(2)
        let gear = app.buttons["settings"]
        XCTAssertTrue(waitFor(gear, 8), "Settings gear missing")
        forceTap(gear)
        XCTAssertTrue(waitFor(app.staticTexts["settings"], 8), "Settings didn't open")
        // The drafts row lives in the "content" group; .exists is true while
        // off-screen, so scroll until the row is inside the visible frame.
        let draftsRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'drafts'")).firstMatch
        for _ in 0..<8 {
            if draftsRow.exists && draftsRow.frame.maxY < app.frame.maxY - 100 && draftsRow.frame.minY > 100 { break }
            app.swipeUp()
            usleep(400_000)
        }
        XCTAssertTrue(draftsRow.exists, "drafts row not found in settings")
        // A tap right after swipeUp can be eaten by scroll-deceleration (it
        // stops the scroll instead of activating the row) — observed on the
        // first run: the 02c snap still showed settings. Settle first, then
        // verify we actually LEFT settings (its PRIVACY section header is
        // gone) and retry the tap if not.
        usleep(600_000)
        forceTap(draftsRow)
        for _ in 0..<3 {
            sleep(1)
            if !app.staticTexts["PRIVACY"].exists { break }
            forceTap(draftsRow)
        }
        XCTAssertFalse(app.staticTexts["PRIVACY"].exists, "drafts row tap never left settings")
        sleep(1)
        snap("02c-drafts-list")

        // Open our draft (row a11y label carries the full text incl. marker).
        let rowPredicate = NSPredicate(format: "label CONTAINS %@", marker)
        var draftRow = app.buttons.matching(rowPredicate).firstMatch
        if !waitFor(draftRow, 10) {
            draftRow = app.staticTexts.matching(rowPredicate).firstMatch
        }
        XCTAssertTrue(waitFor(draftRow, 5), "Saved letter draft not found in drafts list")
        forceTap(draftRow)
        XCTAssertTrue(waitFor(app.buttons["cancel"], 8), "Draft compose didn't open")
        sleep(2) // let onAppear seed initialText + restore letter mode

        // THE regression assertions: full length present, tail intact,
        // letter mode restored (the actual fix).
        let reopened = (app.textViews.firstMatch.value as? String) ?? ""
        snap("02d-draft-reopened")
        XCTAssertGreaterThan(reopened.utf16.count, 500,
                             "Letter draft truncated to \(reopened.utf16.count) chars on reopen (charLimit floor regression)")
        XCTAssertTrue(reopened.contains(marker), "End marker missing — tail of the letter draft was lost")
        XCTAssertTrue(reopened.hasSuffix("end"), "Draft tail altered — expected text to end with 'end'")
        XCTAssertTrue(app.buttons["Letter mode on"].exists, "Letter mode not restored when reopening a long draft")

        // Cleanup: close without changes (editingDraftId composes don't touch
        // the shared draft buffer), then swipe-delete the draft. BEST-EFFORT
        // ONLY — the regression assertions above already passed, and a flaky
        // swipe-action tap (the trash button reports non-hittable while the
        // row is still animating) must not fail the pin. A leftover draft is
        // the same footprint as a walkthrough run.
        app.buttons["cancel"].tap()
        sleep(1)
        let rowToDelete = app.buttons.matching(rowPredicate).firstMatch
        if waitFor(rowToDelete, 8) {
            rowToDelete.swipeLeft()
            let deleteBtn = app.buttons["delete"]
            if waitFor(deleteBtn, 5) {
                usleep(600_000) // let the swipe-action animation settle
                if deleteBtn.isHittable { deleteBtn.tap() }
                else { deleteBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                sleep(2)
            }
            snap("02e-draft-deleted")
        }
    }

    // MARK: 03 — save (bookmark) state drift
    //
    // Tap save on a feed row → label must flip to "Unsave post", survive a
    // push into the post detail and back, then flip back on unsave. The
    // action buttons are siblings of the row link in the a11y tree, so we
    // match them by geometry (directly under the row's text block).
    func test03_saveStateNoDrift() throws {
        try ensureLoggedIn()

        guard let row = findRow(matching: seededPostPredicate) else {
            throw XCTSkip("No seeded post row visible in feed")
        }

        // Reset: if this row is already saved from a previous run, unsave first.
        if let leftoverUnsave = enabledActionButton("Unsave post", near: row) {
            forceTap(leftoverUnsave)
            sleep(2)
        }

        guard let saveBtn = waitForActionButton("Save post", near: row) else {
            XCTFail("No 'Save post' button found near the target row")
            return
        }
        snap("03a-before-save")
        forceTap(saveBtn) // bookmark can sit under the floating glass bar
        let unsave = waitForActionButton("Unsave post", near: row)
        XCTAssertNotNil(unsave, "Label didn't flip to 'Unsave post' after tapping save")
        snap("03b-after-save")

        // Push into the post and check the detail agrees (detail re-checks
        // server truth via checkIfSaved — the drift bug showed stale state here
        // or lost it on the way back).
        forceTap(row)
        XCTAssertTrue(waitFor(app.staticTexts["post"], 8), "Post detail didn't open")
        let detailUnsave = app.buttons["Unsave post"].firstMatch
        XCTAssertTrue(waitFor(detailUnsave, 8), "Detail shows post as NOT saved after feed save (state drift)")
        snap("03c-detail-saved")
        forceTap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(waitFor(feedView, 8), "Didn't return to feed")

        // Back on the feed: still saved.
        guard let rowAgain = findRow(matching: seededPostPredicate) else {
            XCTFail("Target row not found after popping back to feed")
            return
        }
        let stillSaved = waitForActionButton("Unsave post", near: rowAgain)
        XCTAssertNotNil(stillSaved, "Saved state lost after navigating into the post and back (drift regression)")
        snap("03d-back-still-saved")

        // Cleanup + final flip: unsave → label returns to "Save post".
        if let unsaveBtn = stillSaved {
            forceTap(unsaveBtn)
        }
        let savedAgain = waitForActionButton("Save post", near: rowAgain)
        XCTAssertNotNil(savedAgain, "Label didn't flip back to 'Save post' after unsave")
        XCTAssertNil(enabledActionButton("Unsave post", near: rowAgain), "'Unsave post' still present after unsave")
        snap("03e-after-unsave")
    }

    // MARK: reply send appears (runs last — alphabetical after test0N_)
    //
    // Proxy regression test for the reply-offline guard fix. NOTE: this does
    // NOT cover the offline branch itself — simulating network loss isn't
    // practical in XCUITest against the real staging backend. It pins the
    // cheap invariant instead: a typed reply, once sent, actually appears in
    // the thread (send path works end-to-end, nothing swallowed client-side).
    func testReplySendAppears() throws {
        try ensureLoggedIn()
        let marker = "rgrreply\(Self.nonce)"

        guard let row = findRow(matching: seededPostPredicate) else {
            throw XCTSkip("No seeded post row visible in feed")
        }
        forceTap(row)
        XCTAssertTrue(waitFor(app.staticTexts["post"], 8), "Post detail didn't open")

        let replyField = app.textFields["say something gently…"]
        XCTAssertTrue(waitFor(replyField, 8), "Reply field missing")
        replyField.tap()
        replyField.typeText("here with you, always. \(marker)")
        snap("04a-reply-typed")
        // Send: circular arrow.up button next to the field (same fallbacks as
        // the walkthrough suite).
        let send = app.buttons.matching(NSPredicate(
            format: "identifier == 'arrow.up' OR label CONTAINS[c] 'send'")).firstMatch
        if send.exists { forceTap(send) }
        else if app.images["arrow.up"].exists { forceTap(app.images["arrow.up"]) }
        else { XCTFail("Send button not found"); return }

        // Real path: client writes pending_validation → staging validateReply
        // promotes it. The reply may need a scroll to materialize in the
        // LazyVStack, so poll + swipe.
        let replyText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        var appeared = false
        for _ in 0..<6 {
            if replyText.waitForExistence(timeout: 5) { appeared = true; break }
            app.swipeUp()
        }
        snap("04b-after-send")
        XCTAssertTrue(appeared, "Sent reply never appeared in the thread")

        // Cleanup (best-effort, no assertions): own-reply context menu →
        // "delete reply" → confirm. If any step doesn't materialize, the
        // reply is left behind — same footprint as a walkthrough run.
        // press(forDuration:) throws on a non-hittable element (the reply can
        // sit under the reply bar after the polling swipes) — nudge it into
        // view and give up quietly if it stays covered; cleanup is optional.
        if !replyText.isHittable { app.swipeUp(); usleep(400_000) }
        guard replyText.isHittable else { return }
        replyText.press(forDuration: 1.5)
        let deleteReply = app.buttons["delete reply"]
        if deleteReply.waitForExistence(timeout: 4) {
            deleteReply.tap()
            let confirm = app.buttons["delete"]
            if confirm.waitForExistence(timeout: 4) { forceTap(confirm) }
            sleep(2)
            snap("04c-reply-deleted")
        } else {
            app.tap() // dismiss the context menu if it opened without the item
        }
    }
}
