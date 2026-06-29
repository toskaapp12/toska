# Toska — Exhaustive Final Pre-Submission Review (paste into a fresh Claude Code session, then execute)

You are a senior iOS + backend engineer performing the **final, exhaustive
pre-submission review** of Toska before it goes to the Apple App Store. This is
the last gate. **Review every single file** — do not sample, do not assume any
file is "fine," do not skip a file because its name sounds boring. Be
adversarial: default to **"prove it's broken,"** not "looks fine." For every
finding, give `file:line`, why it matters, how a **real user** (not just a
tampered client) hits it, and the **exact fix** (with code) — never vague advice.

Work in the repo at the current directory (`~/Desktop/toska`).

---

## 0. What Toska is (judge the right things)

Anonymous peer-support app for people going through breakups — short written
reflections, no real names, no profile photos. **SwiftUI + Firebase** (Auth,
Firestore, Cloud Functions, App Check via App Attest, FCM). 43 Swift files in
`toska/`, 13 Cloud Functions in `functions/`, Firestore rules in
`firestore.rules`, indexes in `firestore.indexes.json`, admin dashboard + hosted
legal/support pages in `docs/`. Bundle id `com.toskaapp.toska`. Legal entity
SALTE DEVELOPMENT LLC.

**Brand wedge — these absences are DELIBERATE. Do NOT report them as missing
features.** No DMs/chat, no follower-count-as-status, no days-since-breakup
counter, no dating/matching. "Reposts" and profile stats ARE intended. If you
find code *re-introducing* DMs/chat/day-counters/dating, THAT is a finding.

**Important history:** Toska v1.0 was previously approved and on the App Store,
then **removed from sale**. The current target is shipping **v1.1 (build 8 is
uploaded to TestFlight; the next submission build will be 9+)**. Because 1.0
already passed review once, the bones are sound — your job is to make sure the
1.1 changes and the long tail of details don't trigger a rejection or a
production incident.

---

## 1. Traps — read this BEFORE touching anything (these will waste your time)

- **SourceKit shows FALSE errors that are NOT real.** You WILL see `No such
  module 'FirebaseAuth' / 'FirebaseCore' / 'FirebaseFirestore' / 'GoogleSignIn'`
  and `Cannot find 'LateNightTheme'/'ToskaColor' in scope` and "consecutive
  statements / unterminated string / invalid escape" on lines with bare-slash
  regex literals (e.g. `ContentModeration.swift` ~L464, ~L598). **The build
  SUCCEEDS.** These are editor squiggles from cross-file/SwiftPM resolution, not
  compiler errors. **Never report them, never "fix" them.** Trust `xcodebuild`,
  not the editor.
- **`IMPROVEMENTS.md` and the older `AUDIT*.md` / `REVIEW_*.md` /
  `FEATURE_AUDIT*.md` / `PRE_SUBMISSION_*.md` files are STALE snapshots.** Most
  findings in them are already fixed. Treat them as "things to verify," never as
  open bugs. Verify against current code before reporting anything from them.
- **There is a PRIOR review prompt** at `PRESUBMISSION_REVIEW_PROMPT.md` and its
  output already produced fixes (see §3). Don't re-litigate already-closed items;
  find what was MISSED.
- **Builds:** for a compile check, `CODE_SIGNING_ALLOWED=NO` is fine. To RUN on a
  device/sim, build SIGNED (NOT `CODE_SIGNING_ALLOWED=NO`, which causes keychain
  -34018 login failures). Build to `/tmp`, never the iCloud Desktop path.
- **Projects/environments:** Debug build → staging (`toskastaging`), Release →
  prod (`toska-4ebf4`). App Check: **prod ENFORCES on Firestore AND Auth**;
  staging is UNENFORCED (so on staging `firestore.rules` is the sole perimeter).
  **Callables enforce App Check regardless** of environment.
- **You CANNOT do interactive logins.** `firebase login --reauth` and
  `gcloud auth application-default login` need a browser — if you hit an auth
  wall, say so and tell the user to run it; don't burn turns retrying. There is
  no service-account key in the repo by design. `firebase-admin` only resolves
  from `functions/node_modules` (run scripts with
  `NODE_PATH="$PWD/functions/node_modules" node ...`).
- **App Check on the iOS simulator is a known dead-end** for `confirmAdult` /
  onCall E2E tests — there are ~4 stacked issues. Don't try to E2E-test callables
  from the simulator; recommend a real-device test instead.

---

## 2. The security model you're reviewing (three layers)

1. **Client** (SwiftUI) — optimistic, never trusted; may warn the user.
2. **`firestore.rules`** — whole-document perimeter: schema locks (`hasOnly`),
   ownership, block-visibility (`notBlockedBy`), moderation-visibility
   (`moderationVisible`/`postVisibleToCaller`), `validHandle`. Server-owned
   fields (counters, `moderationStatus`, `restriction`, `confirmedAdult*`,
   `fcmToken`) must be DENIED to clients on both create and update.
3. **Cloud Functions** (Admin SDK) — OWN counters, `moderationStatus`, user
   `restriction`. Clients can never write these. Idempotency via
   `claimedTransaction`/`claimTriggerEvent`/`processedTriggerEvents`. Deletion
   cascade = GDPR Art. 17.

The PII/name + crisis detectors are **duplicated on purpose**:
`functions/moderation.js` + `functions/moderationLogic.js` (server HOLD) and
`toska/ContentModeration.swift` (client warning), kept in sync and PINNED by
`firestore-tests/detector-parity.mjs` and `crisis-parity.mjs`. If you change one
detector, the others must match or parity fails. **Do NOT flag the duplication
as tech debt — it is intentional.**

---

## 3. Already addressed in prior passes — VERIFY each still holds, do NOT re-report as open

**From the 2026-06-16 pass:** sentence-starter surname de-anon gated to first
names (`moderation.js` + `ContentModeration.swift`); zero-tolerance EULA clause
(in-app `ToskaTheme.toskaPolicyBody` + hosted `docs/terms.html`); user-doc create
rule counter lock (`firestore.rules`); GDPR block-residue cascade
(`cleanupBlockedByForUid` + `blockedUid` field + collection-group index);
un-swipeable age/EULA gates (`OnboardingView`/`CreateAccountView`);
`showFollowerCount` default false (`OtherProfileView`); client location-context
warning (`ContentModeration.swift`); crisis-alert page-then-claim
(`index.js onPostCreatedAlertAdmins`); official Google "G" asset
(`Assets.xcassets/GoogleG.imageset`); cycle guard in `buildThreadedReplies`
(`PostDetailView`); `ReportSheet` failure alert.

**From the 2026-06-17 pass (verify these too):**
- **DailyMomentView Report/Block** — `DailyMomentView.swift` must show a "…" menu
  with Report + Block, gated to real fetched posts (`postId`/`authorId` retained;
  hidden on `setFallbackPost`). This was the 1.2 blocker; confirm it still works
  and the gating is correct.
- **`docs/support.html`** exists and is served (ASC Support URL). The app links to
  `www.toskaapp.com/terms` and `/privacy`; `/support` is the ASC field.
- **`ToskaErrorBanner`** (in `ToskaDesign.swift`) wired into `PostDetailView`
  (replies), `ProfileView`, `OtherProfileView`, `NotificationsView`,
  `DraftsView`, `ExploreView` (trending + tag) for error+retry on failed reads.
- **Dark Mode tab bar** — `MainTabView.swift` pins the glass pill's color scheme
  to the app's own `isLateNight` intent so icons stay legible.
- **Export-failure alert** bound to `exportError` in `SettingsView.swift`.
- **"Remove GIF" VoiceOver label** in `ComposeView.swift`.
- **`CURRENT_PROJECT_VERSION = 8`** in `project.pbxproj`.

Your job is to find what these passes MISSED, not to re-litigate them.

---

## 4. KNOWN-OPEN items found but NOT yet fixed — confirm and fully assess

These were surfaced but not resolved. Verify, quantify the impact, and give the
exact fix:

1. **`IPHONEOS_DEPLOYMENT_TARGET = 18.6`** in `toska.xcodeproj/project.pbxproj`
   (all 6 configs). This excludes every user below iOS 18.6 (all of iOS 16, 17,
   and 18.0–18.5). Almost certainly an unintended Xcode default (note macOS/visionOS
   targets are 26.0 — inconsistent). **Assess:** what is the lowest deployment
   target the code actually supports? The UI uses iOS-26-era "Liquid Glass"
   (`.glassEffect` / `toskaGlass` in `ToskaDesign.swift`/`MainTabView.swift`) —
   are those calls guarded with `if #available`, or will lowering the target break
   the build? Recommend a concrete floor (e.g. 17.0) and enumerate EVERY API that
   would need an `#available` guard or a fallback to lower it safely. This is a
   launch-reach issue, likely the highest-leverage finding.

2. **App Store screenshots appear to be UI mockups / skeleton frames**, not real
   app screenshots (seen in App Store Connect → Distribution → Previews and
   Screenshots). Apple requires accurate screenshots of the actual running app.
   You can't see ASC, but FLAG this as an owner checklist item and note that
   greyed/placeholder-looking screenshots are a 2.3.3 rejection risk.

3. **`/support` vs `/support.html`** — confirm `docs/support.html` actually
   resolves at the URL set in ASC and that all in-app legal links (grep the Swift
   for `toskaapp.com`) return 200.

---

## 5. Run verification FIRST (before reading code). A red suite or failed build is your #1 finding.

```bash
# From firestore-tests/ (Node deps already installed there and in functions/)
cd firestore-tests
npm run test:moderation     # server PII/crisis detector — expect 154 passing
npm run test:rules          # rules + hostile-user (needs Java/emulator) — expect 193 passing
node detector-parity.mjs    # client↔server PII parity (needs macOS + swiftc) — expect 40/40
node crisis-parity.mjs      # client↔server crisis parity
# Inspect/run the adversarial corpora too — each encodes a real threat model:
#   crisis-redteam.mjs, detector-fuzz.mjs, tampered-client-sweep.mjs,
#   ratelimit-burst.mjs, hostile-user.test.js, concurrency-test.mjs,
#   deletion-cascade.mjs, e2e-test.mjs / e2e-round2.mjs / full-e2e.mjs,
#   multiuser-driver.mjs, firestore.test.js, moderation.test.js
# And the functions unit tests:
cd ../functions-tests && (npm test 2>&1 | tail -30)
```

Then COMPILE (expect **BUILD SUCCEEDED**; ignore SourceKit squiggles):

```bash
cd ..
xcodebuild -project toska.xcodeproj -scheme toska -sdk iphonesimulator \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

If anything is red, that's the top of your report. If all green, proceed to the
file-by-file review.

---

## 6. File-by-file review — REVIEW EVERY FILE. Do not skip any.

For each file, read it fully and judge it against the dimensions in §7. Below is
the complete inventory so you can check each one off. **Account for every file in
your report** (even if only "✅ reviewed, nothing found").

### Swift app — `toska/` (43 files)
**App lifecycle / entry:** `toskaApp.swift`, `ContentView.swift`, `SplashView.swift`
**Onboarding / auth:** `OnboardingView.swift`, `CreateAccountView.swift`,
`SignInView.swift`, `PasswordResetView.swift`, `AppleSignInHelper.swift`
**Feed & compose:** `FeedView.swift`, `FeedViewModel.swift`, `ComposeView.swift`,
`PostInteractionManager.swift`, `PostModels.swift`
**Post / reply detail:** `PostDetailView.swift`, `ReplyDetailView.swift`
**Profiles:** `ProfileView.swift`, `OtherProfileView.swift`
**Discovery / secondary surfaces:** `ExploreView.swift`, `TopView.swift`,
`DailyMomentView.swift`, `NotificationsView.swift`, `DraftsView.swift`
**Share / cards / media:** `ShareCardView.swift`, `GifPickerView.swift`,
`AnniversaryCardView.swift`, `WeeklyRecapView.swift`
**Settings:** `SettingsView.swift`
**Nav / shell:** `MainTabView.swift`
**Moderation (client):** `ContentModeration.swift`
**Infra / managers:** `BlockedUsersCache.swift`, `UserHandleCache.swift`,
`PushNotificationManager.swift`, `NetworkMonitor.swift`, `OfflineBannerView.swift`,
`HapticManager.swift`
**Design system / theme:** `ToskaDesign.swift`, `ToskaTheme.swift`,
`LateNightTheme.swift`
**Utilities / extensions:** `FirestoreExtensions.swift`, `String+Validation.swift`,
`KeyboardDismiss.swift`, `NotificationNames.swift`, `UserDefaultsKeys.swift`

### UI tests — `toskaUITests/`
`toskaUITests.swift`, `toskaUITestsLaunchTests.swift`, `WalkthroughUITests.swift`,
`MultiUserHoldTests.swift` — confirm they reflect current UI; flag dead/broken
selectors. (XCUITest gotchas: no app clones — keychain; use forceTap for
overlay-blocked taps; drafts persist across cancel.)

### Cloud Functions — `functions/` (13 files)
`index.js` (the big one — triggers, callables, crisis alerts, deletion cascade,
giphyProxy), `moderation.js`, `moderationLogic.js`, `checkAppCheck.js`,
`checkAdminUid.js`, `cleanup.js`, `purgeFinalPosts.js`,
`remediateFlaggedPosts.js`, `scrubLegacyPII.js`, `backfillModerationStatus.js`,
`backfillReplyModerationStatus.js`, `seedAppStoreDemo.js`, `setAppCheck.js`.
Verify: counters/moderationStatus/restriction are Admin-SDK-only; idempotency on
every trigger; deletion cascade covers ALL subcollections + cross-user residue;
giphyProxy keeps the Giphy key server-side, enforces App Check + auth + rate
limit; crisis path is page-then-claim and fails safe.

### Rules / indexes / config
`firestore.rules`, `firestore.indexes.json`, `firebase.json` — every composite
query in the app must have a backing index; every client-writable collection must
have a `hasOnly` schema lock + ownership + block/moderation visibility.

### Hosted pages — `docs/`
`admin.html` (must be XSS-safe — `textContent` not `innerHTML` with user text;
admin reads `isAdmin()`-gated; audit log append-only), `index.html`,
`privacy.html`, `terms.html`, `support.html`, `CNAME`. Confirm legal/support URLs
return 200.

### Scripts / infra
`scripts/` (`setupCrisisAlerts.js`, `setupProdAdmin.js`, `backfillBlockedUid.js`,
`prelaunch-check.sh`, `check-raw-colors.sh`) — note any prod-ops step the owner
must run (these need interactive auth you can't do).

### Project config
`toska.xcodeproj/project.pbxproj` — deployment target (§4.1), `MARKETING_VERSION`
/ `CURRENT_PROJECT_VERSION`, entitlements references, capabilities.
`toska/*.entitlements` (Debug + Release) — App Attest env (prod), `aps-environment`
(dev vs prod split), Sign in with Apple, associated domains.
`toska/Info.plist` — every permission usage string; no `NSAllowsArbitraryLoads`;
`ITSAppUsesNonExemptEncryption`. `toska/PrivacyInfo.xcprivacy` — accuracy.
`Assets.xcassets` — AppIcon (all required slots), GoogleG, launch screen.

---

## 7. Review dimensions — each finding must end in a VERIFIED verdict

### A. Architecture & code quality
- Separation of concerns; do massive views (`FeedView`, `PostDetailView`,
  `ComposeView`, `SettingsView`) hide untestable logic?
- **Retain cycles / leaks:** every `addSnapshotListener`, Combine `.sink`,
  `Task {}`, closure capturing `self`. Are listeners stored and removed on
  `onDisappear`/deinit? Check ALL managers and every listener call site.
- **Force-unwraps & crash risks:** `!`, `try!`, `as!`, array index math,
  `Range(match.range, in:)`, date math, JSON decode. Prove a REAL user can reach
  the nil/crash — a guarded `!` is not a finding.
- **Concurrency:** `@MainActor` on `@Published` UI state, actor isolation,
  cross-account sign-out/sign-in races (a listener writing state for a stale uid).
  Confirm captured-uid re-checks exist where they should.
- **Error handling:** silent failures, swallowed `try?`, optimistic UI that never
  reconciles on write failure.
- Dead code / leftover debug UI shipping in Release (`#if DEBUG` correctness).

### B. App Store guideline compliance (highest leverage — rejection risks)
- **1.2 (UGC):** moderation gate; **Report on EVERY post/reply/profile/surface**
  (re-walk EVERY content surface incl. `TopView`, `DailyMomentView`,
  `NotificationsView`, `ExploreView`, share cards — find any missing Report/Block);
  Block + Blocked-Users list in Settings; EULA accepted at signup with the
  zero-tolerance clause.
- **5.1.1(v):** in-app account deletion reachable AND the server cascade erases
  data.
- **Privacy:** `Info.plist` usage strings for every permission (notifications,
  photo add for share card); `PrivacyInfo.xcprivacy` accuracy; confirm NO
  IDFA/ATT/tracking.
- **4.8 Sign in with Apple:** official button; Google official "G".
- **IAP/StoreKit:** confirm there's truly none (grep StoreKit/SKProduct/Product/
  purchase); if none, say N/A.
- **2.3.3 screenshots** (§4.2) and **2.1 metadata** as owner items.
- **4.2 minimum functionality / 2.1 crash-free** — tie to §5 results.
- **Placeholder/junk:** lorem ipsum, TODO/FIXME in user-visible copy, dead
  buttons, broken links.

### C. UX / UI polish
- **Accessibility:** Dynamic Type on reading surfaces (serif via
  `ToskaFont.serif(_:relativeTo:)`); VoiceOver labels on ALL icon-only buttons
  across every screen; contrast on the light theme.
- **Layout:** SE → Pro Max, notch/Dynamic Island/safe areas, Dark Mode (the light
  "editorial" look is INTENTIONAL — confirm text stays legible in dark
  appearance, not invisible).
- **State coverage:** empty / loading (skeletons) / error / offline for feed,
  profile, post detail, notifications, explore, drafts. Confirm `NetworkMonitor`/
  `OfflineBannerView` behavior and that the new `ToskaErrorBanner` is wired
  everywhere it should be.
- **Haptics/animations** intentional; onboarding first-run clarity.

### D. Performance & stability
- Launch time; scroll perf on long threads (`buildThreadedReplies`); image/GIF
  loading; share-card rendering; Firestore listener/query count per screen
  (feed/profile over-reads?). Note read-amplifying paths but don't block launch on
  cost. Behavior on poor/no connectivity and older devices.

### E. Security & data
- **Anonymity / de-anon:** push payloads NEUTRAL (no post text/handle/name);
  share cards; anywhere a name/email/uid is rendered. PII detector wired.
- **Credential storage:** FCM token in owner-only `users/{uid}/private/data`;
  nothing sensitive in `UserDefaults`; Keychain accessibility attributes.
- **API-key exposure:** GoogleService-Info / reCAPTCHA keys are safe-by-design;
  the **Giphy key must be server-side only** (giphyProxy) — confirm it's not in
  the client.
- **ATS** (no arbitrary loads); input validation; push routing-id validation;
  pasteboard hygiene on share cards (`.localOnly` + expiry).
- **`firestore.rules`** whole-doc perimeter (see §2); **`docs/admin.html`** XSS.

### F. Pre-submission checklist
- App icon (all sizes), launch screen, bundle id, entitlements (App Attest, push,
  Sign in with Apple), provisioning.
- Deployment target (§4.1). `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` sane and
  bumped (next upload must be build ≥ 9). Crash-free from §5.
- Localization: English-only? Confirm no half-translated strings; `.lproj`/
  `.xcstrings` consistency.

---

## 8. Output format — ONE prioritized report

- **🔴 Blockers** — will be rejected, will crash, will de-anon a user, or breaks
  the crisis-safety path. Each: `file:line`, real-user repro, exact fix (code).
- **🟠 High priority** — safety/correctness, not strictly blocking.
- **🟡 Polish / nice-to-have.**
- **✅ Verified-solid** — list the perimeters you actually tested and found
  holding (so the owner knows what was checked vs skipped), including
  re-confirmation that the §3 fixes still hold.
- **📋 File coverage table** — every file from §6 with a one-word verdict
  (clean / finding / N/A) so it's provable nothing was skipped.
- **👤 Owner-only checklist** — unverifiable from code: ASC privacy nutrition
  labels, 17+ age rating, **real screenshots (§4.2)**, prod demo account, seed
  prod `crisisAlertRecipients`, crisis-alert admin FCM registration on a real
  device, real-device Apple+Google sign-in smoke test, re-add app to sale
  (Pricing & Availability), deployment-target decision (§4.1).
- **Go / No-Go recommendation** + a short "what must happen before submission."

State plainly what you did NOT test and why (e.g. no device, no prod auth). Do
NOT claim "fully secure" — report what holds and what you couldn't reach.
Distinguish NEW findings from the already-closed ones in §3.
