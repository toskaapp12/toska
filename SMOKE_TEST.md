# Toska — Pre-Submission Smoke Test

Walk through this end-to-end on a **real device** (not simulator — App Check is broken on simulator per the known gotchas) before archiving for App Store submission. Each item has a checkbox, expected behavior, and a "notes" line for anomalies. If anything fails, fix before submitting.

---

**Build under test:** ____________  **Marketing version:** 1.0
**Device + iOS:** ____________________________________________
**Date:** ____________  **Tester:** ____________

---

## A. Cold launch + auth

### A1. Fresh install — first launch
- [ ] Delete the app, reinstall from TestFlight, open it
  - Expected: SplashView appears with "sign in" and "create account" buttons
  - Notes: ________________________________________________

### A2. Create account (email) — **the age-gate fix lives here**
- [ ] Tap "create account"
- [ ] Enter a fresh email + password
- [ ] Tap "create account" — age gate appears
- [ ] Tap "I'm 17+" — policy acceptance appears
- [ ] Tap accept
  - Expected: signup completes, lands on the onboarding mood picker (NOT another age gate)
  - **If you see a second age gate, the `recentlyConfirmedAdult` flag fix isn't working.**
  - Notes: ________________________________________________

### A3. Sign in with Apple
- [ ] Sign out, return to SplashView
- [ ] Tap "Sign in with Apple"
- [ ] Complete the Apple Sign-In sheet
  - Expected: lands on feed (if returning user) OR onboarding (if first time)
  - Notes: ________________________________________________

### A4. Sign in with Google
- [ ] Sign out, tap "Sign in with Google"
- [ ] Complete the Google sheet
  - Expected: same as Apple — feed or onboarding
  - Notes: ________________________________________________

### A5. Email sign-in (existing user)
- [ ] Sign out, tap "sign in"
- [ ] Use the demo account: `appreview@toskaapp.com` / `crazybean1234`
  - Expected: lands on feed with seeded demo data (3 demo posts, 3 buddy posts)
  - Notes: ________________________________________________

### A6. Password reset
- [ ] On sign-in screen, tap "forgot password"
  - Expected: PasswordResetView **slides in from the right** (not pops up from bottom)
- [ ] Enter the demo email, tap "send reset link"
  - Expected: success state appears
  - Notes: ________________________________________________

---

## B. Feed (home tab) — the most-seen surface

### B1. Feed renders
- [ ] Confirm posts load (demo account has at least 6 visible)
- [ ] Confirm tag chips on posts show **icon + name** (flame for anger, moon.stars for longing, etc.)
- [ ] Confirm action icons (bubble, repost, bookmark, share, heart) feel substantial (17pt)
  - Notes: ________________________________________________

### B2. Repost provenance
- [ ] Find a reposted post in the feed
  - Expected: small "↻ @handle reposted" line appears above the post
  - Notes: ________________________________________________

### B3. Press-state tint
- [ ] Touch and hold any post row
  - Expected: subtle gray tint fades in while held; clears when you lift
  - Notes: ________________________________________________

### B4. Like burst animation
- [ ] Tap heart on any post
  - Expected: heart fills with color AND a brief pink heart burst expands outward + fades
  - Notes: ________________________________________________

### B5. Tap a post → PostDetailView slides in
- [ ] Tap any post body
  - Expected: PostDetailView **slides from the right** (not pops up from bottom)
  - Expected: **tab bar slides off-screen** so the reply composer at the bottom is fully visible
  - Notes: ________________________________________________

### B6. Reply composer visible (the bug from the screenshot)
- [ ] On PostDetailView, look at the bottom of the screen
  - Expected: "say what you feel..." text field is visible above the home indicator (NOT hidden behind the tab bar)
  - Notes: ________________________________________________

### B7. Swipe-back works everywhere
- [ ] From PostDetailView, swipe from the left edge of the screen toward the right
  - Expected: PostDetailView slides back, feed reappears, tab bar slides back in
  - Notes: ________________________________________________

### B8. Pull-to-refresh
- [ ] Pull down on the feed to refresh
  - Expected: spinner shows for ~1.5s, posts reload
  - Notes: ________________________________________________

### B9. "X new posts" banner (hard to test without second account)
- [ ] Skip unless you have a second account that can post while you're on the feed
  - Notes: ________________________________________________

---

## C. Compose

### C1. Tap "+" → compose opens
- [ ] Tap the central "+" button on the tab bar
  - Expected: compose view appears (currently still slides up from bottom — fullScreenCover not converted, see commit db66964 for scope notes)
  - Notes: ________________________________________________

### C2. Type a post + pick a tag
- [ ] Type some text
- [ ] Tap the tag icon → tag picker appears
- [ ] Tap a tag
  - Expected: tag picker dismisses, tag pill shows on the compose area
  - Notes: ________________________________________________

### C3. GIF picker (slides in from right now)
- [ ] Tap the GIF button
  - Expected: GIF picker **slides in from the right** (was a sheet before)
- [ ] Search for "happy", tap a GIF
  - Expected: picker dismisses, GIF appears in compose
- [ ] Swipe from left edge to back out
  - Expected: returns to compose
  - Notes: ________________________________________________

### C4. Post it
- [ ] Tap "post" with a non-empty text
  - Expected: compose dismisses, returns to feed, your new post appears at top
  - Notes: ________________________________________________

### C5. Cancel mid-typing — draft persists
- [ ] Open compose again, type "test draft 123"
- [ ] Tap cancel (or swipe down)
- [ ] Tap "+" to reopen
  - Expected: "test draft 123" is still there
  - Notes: ________________________________________________

---

## D. Engagement

### D1. Reply
- [ ] Open a post, tap the reply composer, type "test reply"
- [ ] Tap send arrow
  - Expected: reply appears in the thread immediately
  - Notes: ________________________________________________

### D2. Reply rows are modernized
- [ ] Look at the reply you just posted (or any seeded reply)
  - Expected: handle is 14pt blue semibold, body is Georgia 15pt, action icons are 17pt
  - Notes: ________________________________________________

### D3. Like a reply
- [ ] Tap the heart on a reply
  - Expected: heart fills, count updates
  - Notes: ________________________________________________

### D4. Save a reply
- [ ] Tap the bookmark on a reply
  - Expected: bookmark fills blue
  - Notes: ________________________________________________

### D5. Repost a reply
- [ ] Tap the repost icon on a reply (only available on someone else's reply)
  - Expected: icon turns green, brief pulse animation, repost count increments
  - Notes: ________________________________________________

### D6. Share a reply
- [ ] Tap share on a reply
  - Expected: ShareCardView **slides in from the right**
- [ ] Swipe from left edge to back out
  - Notes: ________________________________________________

### D7. Long-press reply menu
- [ ] Long-press a reply (not yours)
  - Expected: context menu appears with report / block options
  - Notes: ________________________________________________

---

## E. Profiles

### E1. Tap a handle → OtherProfileView slides in
- [ ] Tap any handle in the feed or in a thread
  - Expected: OtherProfileView slides in; tab bar hides
  - Expected: ToskaHeader shows the user's handle as a 22pt bold title (left-aligned)
  - Expected: stats row shows 16pt bold counts (followers / following / felt)
  - Expected: "follow" button is a full-width pill
  - Notes: ________________________________________________

### E2. Follow + unfollow from OtherProfileView
- [ ] Tap "follow" → button changes to "following"
- [ ] Tap "following" → button changes back to "follow"
  - Notes: ________________________________________________

### E3. Open own profile
- [ ] Tap person icon in tab bar
  - Expected: ToskaHeader shows your handle as 22pt title, envelope + gear icons trail
  - Expected: stats row shows 16pt bold counts
  - Notes: ________________________________________________

### E4. Open followers list — **the original complaint surface**
- [ ] Tap "followers" stat
  - Expected: list **slides in from the right** (not pops up from bottom)
  - Expected: handle is 15pt semibold blue, more breathing room than before
- [ ] Swipe from left edge to back out
  - Notes: ________________________________________________

### E5. Open following list + unfollow inline
- [ ] Tap "following" stat
  - Expected: list slides in
  - Expected: each row has a "following" pill button on the right
- [ ] Tap a "following" pill
  - Expected: confirmation alert "unfollow @handle? you can re-follow anytime"
- [ ] Tap "unfollow"
  - Expected: row animates out
  - Notes: ________________________________________________

### E6. Tap follower row → profile
- [ ] In the followers list, tap a row
  - Expected: that user's profile pushes in (slide from right)
  - Notes: ________________________________________________

### E7. Tabs (posts / replies / saved / liked)
- [ ] On own profile, tap each tab
  - Expected: tab content swaps, active tab has blue underline
  - Notes: ________________________________________________

---

## F. Messages + Conversations

### F1. Open messages from envelope icon
- [ ] On own profile, tap envelope icon (top right)
  - Expected: MessagesListView slides in
  - Expected: ToskaHeader shows "messages" as 22pt bold title
  - Expected: each conversation row has a 44pt avatar circle, 15pt semibold blue handle
  - Notes: ________________________________________________

### F2. Open a conversation
- [ ] Tap a conversation
  - Expected: ConversationView slides in
  - Expected: header shows 18pt bold handle + 11pt sub-line ("X messages left" or "conversation sealed")
  - Expected: message bubbles are Georgia 16pt, 12pt semibold sender handle
  - Notes: ________________________________________________

### F3. Send a message
- [ ] Type and send a message in any conversation
  - Expected: bubble appears immediately, count drops by 1
  - Notes: ________________________________________________

### F4. Tap ellipsis → report/block
- [ ] Tap the ellipsis in the conversation header
  - Expected: report / block options appear
  - Notes: ________________________________________________

### F5. Start a new conversation
- [ ] On someone else's profile, tap the envelope button (DM)
  - Expected: ConversationView slides in for that user
  - Notes: ________________________________________________

---

## G. Notifications

### G1. Open notifications tab
- [ ] Tap the bell icon
  - Expected: notifications list shows
  - Expected: each row has a soft tinted circle icon (15pt symbol) — pink for likes, blue for replies, green for follows, gold for milestones
  - Expected: title is 22pt bold "notifications" via ToskaHeader
  - Notes: ________________________________________________

### G2. Bell badge sits next to bell
- [ ] Confirm the unread count badge is positioned at the top-right of the bell icon (NOT floating off in empty space)
  - Notes: ________________________________________________

### G3. Tap a notification
- [ ] Tap any notification
  - Expected: appropriate destination opens (post detail / profile / conversation), and the destination **slides in from the right**
  - Notes: ________________________________________________

### G4. Tap-active-bell → pop to root
- [ ] From a pushed-in notification destination, tap the bell again
  - Expected: pops back to the notifications root list
  - Notes: ________________________________________________

### G5. Push notification (requires a 2nd account)
- [ ] Have a second account like or reply to one of your posts
  - Expected: push notification appears on lock screen / banner
- [ ] Tap the push
  - Expected: opens the app and routes to the relevant destination
  - Notes: ________________________________________________

---

## H. Settings

### H1. Open settings
- [ ] On own profile, tap gear icon
  - Expected: SettingsView slides in
  - Expected: ToskaHeader title "settings", row labels 15pt medium with bigger padding
  - Notes: ________________________________________________

### H2. Change email — slides in from right
- [ ] Tap "change email"
  - Expected: ChangeEmailView **slides in** (not pops up)
- [ ] Swipe from left edge to back out
  - Notes: ________________________________________________

### H3. Change password — slides in from right
- [ ] Tap "change password"
  - Expected: ChangePasswordView slides in
  - Notes: ________________________________________________

### H4. Drafts — slides in
- [ ] Tap "drafts"
  - Expected: list slides in
  - Expected: each draft shows Georgia 16pt body with proper spacing
- [ ] Tap a draft
  - Expected: compose opens with that draft loaded
  - Notes: ________________________________________________

### H5. Blocked users
- [ ] Tap "blocked users"
  - Expected: list slides in
  - Expected: any users you've blocked appear
  - Notes: ________________________________________________

### H6. Toggle a notification preference
- [ ] Flip any toggle (gentle check-in, push, etc.)
  - Expected: toggle animates, change persists on next view enter
  - Notes: ________________________________________________

### H7. Sign out
- [ ] Tap "sign out", confirm
  - Expected: returns to SplashView
  - Notes: ________________________________________________

### H8. View content policy
- [ ] After re-sign-in, Settings → "view content policy"
  - Expected: policy view appears (currently still as fullScreenCover with swipe-from-left dismiss)
  - Notes: ________________________________________________

---

## I. Block + report

### I1. Block someone via context menu
- [ ] Long-press a post not owned by you → "block @handle"
  - Expected: confirmation, user blocked
  - Expected: undo-block toast appears at the bottom for 4 seconds
- [ ] Tap "undo" within 4 seconds
  - Expected: user unblocked
  - Notes: ________________________________________________

### I2. Report a post
- [ ] On a post not owned by you, tap the ellipsis menu → "report"
  - Expected: ReportSheet slides in
- [ ] Pick a reason, submit
  - Expected: confirmation shown
  - Notes: ________________________________________________

### I3. Verify blocked user's content is gone
- [ ] Block a user whose post is in your feed
  - Expected: their post disappears from the feed immediately (no refresh needed)
  - Notes: ________________________________________________

---

## J. Trending (top tab)

### J1. Open trending
- [ ] Tap the chart icon in the tab bar
  - Expected: ToskaHeader shows "felt the most" 22pt title + "right now" status dot in trailing slot
  - Expected: top 3 ranks show 20pt bold colored numbers
  - Expected: each row shows 14pt handle, Georgia 16pt body, tag pill with icon
  - Notes: ________________________________________________

### J2. Tap a ranked post
- [ ] Tap any ranked post
  - Expected: PostDetailView slides in
  - Notes: ________________________________________________

### J3. Scroll-to-top by tapping active tab
- [ ] Scroll the trending list down, then tap the chart icon again
  - Expected: list animates scroll to top
  - Notes: ________________________________________________

---

## K. Explore (from feed empty state or explore button)

### K1. Open Explore
- [ ] Trigger Explore (typically via feed's empty state CTA or a search affordance)
  - Expected: slides in from the right
  - Expected: tag chip rail starts anchored at "longing" (first chip, not mid-scrolled)
  - Notes: ________________________________________________

### K2. Tap a tag chip
- [ ] Tap any tag chip
  - Expected: tag-filtered feed shows
  - Notes: ________________________________________________

### K3. Search
- [ ] Type something in the search field
  - Expected: results show, tag chips hide
  - Notes: ________________________________________________

---

## L. App-wide consistency checks

### L1. Every navigation slides
- [ ] Confirm there's no "pops up from the bottom" navigation anywhere except: compose (+), daily moment, weekly recap, sign-in/sign-up flow, onboarding, push-notification deep links
- [ ] All the above should still support **swipe from left edge** to dismiss
  - Notes: ________________________________________________

### L2. Tab bar hides on every drill-in
- [ ] Drill into post detail, profile, conversation, settings, follow list, messages — for each, confirm the tab bar slides off the bottom
- [ ] Swipe back — tab bar slides back in
  - Notes: ________________________________________________

### L3. ToskaHeader on every page
- [ ] Confirm every navigable page has the 22pt bold left-aligned title pattern (not the old centered tiny title)
  - Notes: ________________________________________________

### L4. No app crashes
- [ ] Background and foreground the app a few times during the test
- [ ] Force-quit and reopen
  - Expected: no crashes, state restores reasonably
  - Notes: ________________________________________________

### L5. Offline behavior
- [ ] Turn on Airplane mode
- [ ] Try to scroll feed (should load cached content)
- [ ] Try to post (should fail gracefully — "offline" message somewhere)
- [ ] Turn Airplane mode off
- [ ] Try again — should work
  - Notes: ________________________________________________

---

## M. Edge cases worth touching

### M1. Long post text
- [ ] Find or create a post with very long text (close to 2000 char limit)
  - Expected: renders without overflow, scrollable
  - Notes: ________________________________________________

### M2. Letter post
- [ ] Find a "letter" post in the feed (small envelope icon)
  - Expected: collapsed preview with "read this letter..." link
- [ ] Tap to expand
  - Expected: full letter shows
  - Notes: ________________________________________________

### M3. Midnight post
- [ ] Find a post with the moon icon (posted between 11pm-3am)
  - Expected: small moon icon renders next to time
  - Notes: ________________________________________________

### M4. Reduce-motion
- [ ] In iOS Settings → Accessibility → Motion → enable Reduce Motion
- [ ] Tap a heart in the feed
  - Expected: heart fills but no burst animation (reduce-motion check honors)
  - Notes: ________________________________________________

### M5. Dynamic Type (text-size accessibility)
- [ ] In iOS Settings → Display & Brightness → Text Size → bump up a few notches
- [ ] Reopen the app
  - Expected: text scales reasonably; no critical UI clipped
  - Notes: ________________________________________________

---

## N. Final pre-archive verification

- [ ] Build number bumped (`CURRENT_PROJECT_VERSION` in Xcode project settings) — currently `6`, bump to next
- [ ] App version `1.0` (or whatever you're shipping)
- [ ] `firebase functions:list --project toska-4ebf4` confirms latest functions are deployed
- [ ] `firestore.rules` deployed to prod (per audit report)
- [ ] Demo account `appreview@toskaapp.com` / `crazybean1234` works on prod
- [ ] Demo account has seeded posts, replies, notifications, follow graph (per `seedAppStoreDemo.js` re-run on prod)
- [ ] `Info.plist` → `ITSAppUsesNonExemptEncryption` set correctly
- [ ] `PrivacyInfo.xcprivacy` reviewed for App Store privacy declarations
- [ ] App Store Connect → reviewer notes drafted (explain demo account login + what to test)
- [ ] App Store Connect → metadata (description, keywords, screenshots) complete
- [ ] App Store Connect → age rating set to 17+
- [ ] App Store Connect → UGC content rights declaration set

---

## Anything that failed

Use this section to capture anything that surprised you, broke, or felt off:

```
Item: ____________________________________________
What happened: ____________________________________
Expected: _________________________________________
Severity (blocking / annoying / cosmetic): ________
```

---

When every checkbox in sections A-N is checked, the app is functionally ready for App Store submission.
