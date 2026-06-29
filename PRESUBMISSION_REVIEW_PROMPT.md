# Toska — Final Pre-Submission Engineering Review (paste into a fresh Claude Code session, then execute)

You are a senior iOS engineer doing the **final pre-submission code and product
review** of Toska before it goes to the App Store. Write a comprehensive,
brutally honest developer review. Go deep — this is the last gate, so **assume
nothing is "fine" until you've verified it against the running code.** Be
adversarial: default to "prove it's broken," not "looks fine." For every finding
give `file:line`, why it matters, how a *real user* (not just a tampered client)
hits it, and the **exact fix** — not vague advice.

---

## 0. What Toska is (judge the right things)

Anonymous peer-support app for people going through breakups — short written
reflections, no real names, no profile photos. SwiftUI + Firebase (Auth,
Firestore, Cloud Functions, App Check via App Attest, FCM). Repo at the current
directory (`~/Desktop/toska`). ~43 Swift files in `toska/`, Cloud Functions in
`functions/`, Firestore rules in `firestore.rules`, admin dashboard + hosted
legal pages in `docs/`.

**Brand wedge — these absences are DELIBERATE. Do NOT report them as missing
features.** No DMs/chat, no follower-count-as-status, no days-since-breakup
counter, no dating/matching. "Reposts" and profile stats ARE intended. If you
find code *re-introducing* DMs/chat/day-counters/dating, THAT is a finding.

## 1. Traps — read before touching anything (these will waste your time)

- **SourceKit shows false errors** that are NOT real: `No such module
  'FirebaseAuth' / 'FirebaseCore' / 'FirebaseFirestore' / 'GoogleSignIn'`, and
  "consecutive statements / unterminated string / invalid escape" on lines with
  bare-slash regex literals (e.g. `ContentModeration.swift` ~L464, ~L598). The
  **build succeeds**. Never report these; never "fix" them. Trust `xcodebuild`,
  not the editor squiggles.
- **`IMPROVEMENTS.md` and the older `AUDIT*.md` files are STALE snapshots.** Most
  findings are already fixed. Treat them as "things to verify," never as open
  bugs. Verify against current code before reporting anything from them.
- **Already fixed in the last review pass (2026-06-16) — do NOT re-report as
  open; instead VERIFY each still holds:** sentence-starter surname de-anon (gated
  to first names in `moderation.js` + `ContentModeration.swift`); zero-tolerance
  EULA clause (in-app `ToskaTheme.toskaPolicyBody` + hosted `docs/terms.html`);
  user-doc create rule counter lock (`firestore.rules`); GDPR block-residue
  cascade (`cleanupBlockedByForUid` + `blockedUid` field + collection-group
  index); un-swipeable age/EULA gates (`OnboardingView`/`CreateAccountView`);
  `showFollowerCount` default false (`OtherProfileView`); client location-context
  warning (`ContentModeration.swift`); crisis-alert page-then-claim
  (`index.js onPostCreatedAlertAdmins`); official Google "G" asset
  (`Assets.xcassets/GoogleG.imageset`); cycle guard in `buildThreadedReplies`
  (`PostDetailView`); `ReportSheet` failure alert. Your job is to find what the
  last pass MISSED, not to re-litigate it.
- **Builds:** for a compile check, `CODE_SIGNING_ALLOWED=NO` is fine. To RUN on a
  device/sim, build SIGNED (NOT `CODE_SIGNING_ALLOWED=NO`, which causes keychain
  -34018 failures). Build to `/tmp`, never the iCloud Desktop path.
- **Projects:** Debug build → staging (`toskastaging`), Release → prod
  (`toska-4ebf4`). App Check: prod ENFORCES on Firestore AND Auth; staging
  UNENFORCED (so on staging `firestore.rules` is the sole perimeter). Callables
  enforce App Check regardless.
- **You CANNOT do interactive logins.** `firebase login --reauth` and
  `gcloud auth application-default login` need a browser — if you hit an auth
  wall, say so and tell the user to run it; don't burn turns retrying. There is
  no service-account key in the repo by design. `firebase-admin` only resolves
  from `functions/node_modules` (run scripts with
  `NODE_PATH="$PWD/functions/node_modules" node ...`).

## 2. The security model you're reviewing (three layers)

1. **Client** (SwiftUI) — optimistic, never trusted; may warn the user.
2. **`firestore.rules`** — whole-document perimeter: schema locks (`hasOnly`),
   ownership, block-visibility (`notBlockedBy`), moderation-visibility
   (`moderationVisible`), `validHandle`.
3. **Cloud Functions** (Admin SDK) — OWN counters, `moderationStatus`, user
   `restriction`. Clients can never write these. Idempotency via
   `claimedTransaction`/`claimTriggerEvent`. Deletion cascade = GDPR Art. 17.

The PII/name + crisis detectors are **duplicated on purpose**:
`functions/moderation.js` + `functions/moderationLogic.js` (server HOLD) and
`toska/ContentModeration.swift` (client warning), kept in sync and PINNED by
`firestore-tests/detector-parity.mjs`. If you change one detector, the other
must match or parity fails.

## 3. Run verification FIRST (before reading code). A red suite or failed build is your #1 finding.

```bash
cd firestore-tests
npm run test:moderation     # server PII/crisis detector — expect 154 passing
npm run test:rules          # rules + hostile-user (needs Java/emulator) — expect 193 passing
node detector-parity.mjs    # client↔server parity (needs macOS + swiftc) — expect 40/40
# Also inspect firestore-tests/*.mjs and functions-tests/ for adversarial corpora
#   (crisis-redteam, detector-fuzz, tampered-client-sweep, ratelimit-burst, hostile-user).
```
Then compile (expect **BUILD SUCCEEDED**; ignore SourceKit):
```bash
xcodebuild -project toska.xcodeproj -scheme toska -sdk iphonesimulator \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```
If anything is red, that's the top of your report. If all green, proceed.

---

## Review dimensions — each must end in a VERIFIED verdict

### 1. Architecture & code quality
- Overall structure (it's roughly MVVM — `FeedViewModel`, view structs +
  managers like `PostInteractionManager`, `BlockedUsersCache`,
  `PushNotificationManager`). Is separation of concerns real, or do massive views
  (`FeedView`, `PostDetailView`, `ComposeView` are large) hide logic that should
  be testable? Does it scale?
- **Retain cycles / leaks:** closures capturing `self` strongly in Firestore
  listeners, `addSnapshotListener`, Combine sinks, `Task {}` blocks. Are
  listeners removed on `onDisappear`/deinit? Check the managers and every
  `addSnapshotListener` call site.
- **Force-unwraps & crash risks:** `!` on network/optional Firestore data, array
  index math, `Range(match.range, in:)`, date math, JSON decode. Prove the nil/
  crash is reachable by a real user — a guarded `!` is not a finding.
- **Concurrency:** `async/await`, actor isolation, `@MainActor` on UI state,
  cross-account races on sign-out/sign-in (listeners writing `@Published` state
  for a stale uid). Confirm captured-uid re-checks exist where they should.
- **Dead code / dup logic / tech debt** worth fixing before launch (the detector
  dup is intentional — don't flag it).
- **Error handling:** silent failures, swallowed `try?`, missing fallbacks,
  optimistic UI that never reconciles on write failure.

### 2. App Store guideline compliance (rejection risks — highest leverage)
- **1.2 (UGC):** moderation gate, Report on EVERY post/reply/profile, Block +
  Blocked-Users list in Settings, EULA accepted at signup with the zero-tolerance
  clause. (These were verified present last pass — re-confirm reachability and
  that no surface is missing a Report action.)
- **5.1.1(v):** in-app account deletion reachable (Settings → Delete Account) and
  the server cascade actually erases data.
- **Privacy:** `toska/Info.plist` usage strings for every permission requested
  (notifications, photo/camera if used by GIF picker / share card), and
  `toska/PrivacyInfo.xcprivacy` accuracy. ATT prompt only if tracking (Toska
  shouldn't track — verify no IDFA/ATT is needed). Flag ASC nutrition-label
  accuracy as an owner checklist item (you can't see ASC).
- **4.8 Sign in with Apple:** official `SignInWithAppleButton` used; Google button
  now uses the official "G" asset — verify it renders.
- **IAP/StoreKit:** Toska is free with no known purchases/subscriptions — VERIFY
  there's no StoreKit code; if truly none, this section is N/A (say so).
- **Placeholder/junk:** lorem ipsum, TODO/FIXME left in user-visible copy, broken
  links, dead buttons, debug-only UI. Confirm `toskaapp.com/terms` + `/privacy`
  return 200 (`curl -sI`).
- **4.2 / 2.1:** minimum functionality and crash-free — tie back to §3 results.

### 3. UX / UI polish
- **Accessibility:** Dynamic Type on reading surfaces (serif via
  `ToskaFont.serif(_:relativeTo:)` / `ToskaFont.replyBody`), VoiceOver labels on
  icon-only buttons across ALL screens, contrast.
- **Layout:** SE → Pro Max, notch/Dynamic Island/safe areas, Dark Mode (Toska has
  a deliberate light "editorial" look — confirm it's intentional, not broken, in
  dark appearance).
- **State coverage:** empty / loading (skeletons) / error / offline for feed,
  profile, post detail, notifications. Check `NetworkMonitor` / `OfflineBanner`
  behavior.
- **Haptics/animations:** intentional (`HapticManager`) vs default; onboarding
  first-run clarity.

### 4. Performance & stability
- Launch time, scroll perf on long threads, image/GIF loading (`GifPickerView`,
  share-card rendering), caching, listener/query count per screen (does profile
  or feed over-read Firestore?).
- Behavior on poor/no connectivity and older devices. Note read-amplifying paths
  but don't block launch on cost.

### 5. Security & data
- Token/credential storage (Keychain vs UserDefaults) — FCM token lives in the
  owner-only `users/{uid}/private/data`; confirm nothing sensitive is in
  `UserDefaults`.
- API-key exposure: the GoogleService-Info / reCAPTCHA / Giphy keys — which are
  safe-by-design to ship vs which must be server-side? (`giphyProxy` exists as a
  server proxy — confirm the Giphy key isn't also in the client.)
- ATS (no arbitrary `NSAllowsArbitraryLoads`), input validation, push payload
  routing-id validation (`PushNotificationManager`), pasteboard hygiene on share
  cards (`.localOnly` + expiry). Confirm pushes are neutral (no post text/handle).
- Admin: `docs/admin.html` must stay XSS-safe (no `innerHTML` with user text — it
  uses `textContent`). Admin reads `isAdmin()`-gated; audit log append-only.

### 6. Pre-submission checklist
- App icon (all sizes in `Assets.xcassets/AppIcon.appiconset`), launch screen,
  bundle id, entitlements (App Attest, push, Sign in with Apple), provisioning.
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` sane and bumped for the next
  upload. Crash-free verification from §3.
- Localization: if the app claims multiple languages, verify; if English-only,
  confirm no half-translated strings.

---

## Output format
Produce ONE prioritized report:
- **🔴 Blockers** — will get rejected, will crash, will de-anon a user, or breaks
  the crisis-safety path. Each: `file:line`, real-user repro, exact fix.
- **🟠 High priority** — safety/correctness, not strictly blocking.
- **🟡 Polish / nice-to-have.**
- **✅ Verified-solid** — list the perimeters you actually tested and found
  holding (so the owner knows what was checked vs skipped), including
  re-confirmation that the 2026-06-16 fixes still hold.
- **Owner-only checklist** — things unverifiable from code (ASC privacy labels,
  17+ age rating, prod demo account, crisis-alert admin FCM token registration on
  a real device, real-device sign-in smoke test).
- **Go / No-Go recommendation** + a short "what must happen before submission."

State plainly what you did NOT test and why. Do not claim "fully secure" — report
what holds and what you couldn't reach. Distinguish NEW findings from the
already-closed ones above.
