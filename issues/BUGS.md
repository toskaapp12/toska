# Known bugs — backlog

Format: severity · surface · status. "Pre-existing" = present before the
2026-10 launch-audit work; not a regression from it.

---

## SEC-UUID — HIGH uuid advisory (GHSA-w5hq-g745-h8pq) via gaxios in Cloud Functions

- **Severity:** HIGH advisory, but **not reachable** in our usage · **Surface:** functions (CI Security Watch "Dependency vulnerability scan") · **Status:** RESOLVED — lockfile fix committed (c2f0dcf) + functions deployed to staging + prod 2026-10-25; Security Watch green
- **What triggered it:** `npm audit --omit=dev --audit-level=high` in `functions/`
  found uuid GHSA-w5hq-g745-h8pq ("missing buffer bounds check in v3/v5/v6 when a
  `buf` arg is provided") — HIGH — pulled in transitively via **gaxios** (the HTTP
  client under google-auth-library / @google-cloud libs that firebase-admin uses).
  Also 2 moderate (gaxios 6.x → old uuid). The job fails on HIGH, hence red.
- **Reachability (plain language):** NOT reachable. The flaw only bites when uuid
  is called with a caller-supplied output buffer (v3/v5/v6 + `buf`). Google's libs
  use `uuid.v4()` with no buffer to mint request ids; our code never calls uuid
  with a buffer. No exploit path in Toska.
- **Fix:** `npm audit fix --omit=dev` in functions/ — lockfile-only bump that
  clears the HIGH (re-audit at `--audit-level=high` exits 0). 2 moderate remain
  (gaxios 6.x, below the gate; the documented "needs firebase-admin major" set).
  No Dependabot PR exists. 112 functions tests still pass.
- **Deploy:** functions dep change → **staging first, then prod on owner approval.**
  Currently applied to the working tree only; CI clears once the lockfile is committed.

---

## FCM-DIAG — REMOVED before launch ✓ (build 100, 2026-10-26)

- **Severity:** BLOCKING for launch · **Surface:** iOS (PushNotificationManager, toskaApp) · **Status:** RESOLVED — stripped in build 100 (0915117, 2026-10-26)
- Build 99 adds `recordFcmDiag()` which appends status strings (no user content)
  to the signed-in admin's own `private/data.fcmDiag` at each push-registration
  step, to diagnose the FCM account-switch token loss on a release TestFlight
  build (debugLog is stripped in release). Gated to admins (AdminManager) = the
  owner only. **MUST be removed before public launch:** delete `recordFcmDiag` +
  all its call sites (PushNotificationManager saveFCMToken/refreshFCMToken/
  reregister/didReceiveRegistrationToken, toskaApp didRegister/didFail), and
  one-time clear the owner's `fcmDiag` field. Diagnostic-only; not for prod users.

---

## TEST-ONBTARGET — wire a Swift unit-test target (follow-up)

- **Type:** test infra follow-up · **Surface:** Xcode project · **Status:** OPEN 2026-10-25
- The repo has only a UI-test target (`toskaUITests`, black-box, no `@testable`
  access). `toskaTests/OnboardingGateTests.swift` (ONB-1 matrix) needs a **Unit
  Testing Bundle** target with `@testable import toska` to run in Xcode/CI. Build
  98 shipped without waiting for it (ONB-1 logic matrix-verified 6/6 standalone).
  Add the target and include that file; then it runs with the suite.

---

## ONB-1 — existing accounts re-shown new-user onboarding on sign-in

- **Severity:** MED (UX + minor data-loss risk) · **Surface:** iOS (ContentView.verifyUserDocumentAsync) · **Status:** FIXED + shipped in build 98 (shouldShowOnboarding server/explicit-false/confirmedAdult gate; matrix 6/6)
- **Finding:** the gate is `data["hasCompletedOnboarding"] as? Bool ?? false; if
  !hasCompletedOnboarding { showOnboarding = true }` (ContentView:428-431). It's an
  ACCOUNT flag (user doc), not a device flag (owner's guess was close). Both accounts
  involved have `hasCompletedOnboarding=true` in Firestore, yet onboarding re-showed
  during rapid account-switching — so the `?? false` default fires onboarding on a
  stale/empty/cached read of the just-switched-to user doc (false negative), not a
  persistence failure.
- **Overwrite check:** onboarding completion writes only `hasCompletedOnboarding`,
  `selectedMood`, `breakupStage` (all merge). It does NOT write `allowSharing`,
  `handle`, or `confirmedAdult`, so re-running can't clobber those. The only data
  risk is overwriting `selectedMood`/`breakupStage`; the main harm is the UX.
- **Proposed fix (existing accounts skip onboarding entirely):** in verifyUserDocument
  (a) read the user doc from SERVER for the onboarding decision (no cache), (b) show
  onboarding ONLY on an explicit `hasCompletedOnboarding == false` from an existing
  doc — never default a missing/unknown read to false, and (c) treat any established
  account as onboarded (e.g. `confirmedAdult == true`), since attestation only
  happens at creation/onboarding. New accounts still onboard via the creation paths
  that post `.showOnboarding` (Splash/CreateAccount/AppleSignIn).

---

## RESET-1 — custom /auth page — DONE

- **Status:** SHIPPED to prod 2026-10-25. `webapp/auth.html` + `webapp/js/auth.js`,
  route `/auth` (firebase.json). Handles resetPassword (two fields, 8-char, eye
  toggles), verifyEmail, verifyAndChangeEmail, recoverEmail, fallback; reuses the
  app design system; dark mode; expired/used-link resend; App Check on prod.
  Verified in a real browser. NOTE: not reachable from real reset emails until the
  email action URL points at it (blocked — see below).

## AUTH-05 — email branding — RESOLVED (good enough for launch)

- **Status:** public-facing name set to **"Toska"** (verified: project displayName
  = "Toska"), so `%APP_NAME%` renders "Toska" in the default reset/verify/change
  emails. **Template text + action-URL editing is LOCKED for this project** (console
  banner "Email template updates are currently unavailable… contact Firebase
  Support"; admin API returns `EMAIL_TEMPLATE_UPDATE_NOT_ALLOWED`). So the default
  emails stay (now "Toska"-branded) and the custom /auth page isn't reachable from
  them until unlocked or Option B ships. Support ticket text is in chat 2026-10-25.

## RESET-EMAIL / Option B — branded sending via Resend (POST-LAUNCH, parked)

- **Severity:** post-launch polish · **Surface:** functions + iOS + web + DNS · **Status:** PARKED 2026-10-26 (default emails are fine for soft launch)
- **NOT EXPORTED (2026-10-26):** the `sendBrandedPasswordReset` block in
  functions/index.js is wrapped in a `/* PARKED … */` block comment, including
  its `defineSecret("RESEND_API_KEY")` + `defineString("RESET_FROM")`. This is
  deliberate: those param declarations ran at module load and made EVERY
  `firebase deploy` demand a RESEND_API_KEY secret + RESET_FROM value (it blocked
  the consent-fix staging deploy). **To resume:** uncomment the block and restore
  the `exports.` prefix (step 1 below). Confirmed never deployed to staging or prod.
- **Built, committed, UNDEPLOYED:** `sendBrandedPasswordReset` callable (functions/
  index.js, commit 91498b3) — App Check-enforced, enumeration-safe, rate-limited
  (3/h per email + 10/h per IP), `generatePasswordResetLink` → rewrite to
  `app.toskaapp.com/auth` → branded HTML via **Resend**. `RESET_FROM` defaults to
  Resend's onboarding domain. Clients NOT wired yet.
- **To resume (owner setup):** 1) create a Resend account; 2) make an API key;
  3) set it as a secret yourself (`npx firebase-tools functions:secrets:set
  RESEND_API_KEY --project toskastaging`, then prod) — Claude never sees it;
  4) add domain `toskaapp.com` in Resend → it shows the exact DKIM CNAMEs + SPF
  value + return-path; 5) add those in Squarespace (merge the SPF include into the
  single SPF TXT before `-all`; DKIM CNAMEs; return-path), keeping DMARC `p=reject`.
- **Then Claude:** deploy callable to staging + test to the owner's address; after
  Resend verifies the domain and a test shows spf=pass/dkim=pass/dmarc=pass, flip
  `RESET_FROM` → `noreply@toskaapp.com`, wire iOS (new build) + web "forgot
  password" to the callable, deploy prod. **Do NOT switch prod clients before DNS
  verification** (onboarding domain only delivers to the account owner).

---

## FEAT-HANDLE-CHANGE — post-signup handle change + backfill + block suggestion (post-launch)

- **Type:** FEATURE (post-launch) · **Surface:** iOS + web + rules + functions · **Status:** DEFERRED 2026-10-23
- **Why:** there is NO post-signup handle-change today (handles are set only at
  signup via the "shuffle" flow + `commitUserDocClaimingHandle`). Block hardening
  Option 3 (a gentle "want a fresh handle?" suggestion after blocking) depends on
  this, so Option 3 is deferred with it. The App Store "you can change it
  whenever" claim was removed because nothing backs it (2026-10-23).
- **Scope to build:**
  1. **Change mechanism:** generate a unique handle (`generateUniqueHandleAsync`),
     then ATOMICALLY release `handles/{oldLower}` + claim `handles/{newLower}` and
     update `users/{uid}.handle` in one batch/transaction (prevents squatting +
     uniqueness races). New rules path for a handle *update* (today the registry
     rule is create/delete only). Add a rate-limit (e.g. once per N days) and
     respect `bannedIdentities`/restricted-user checks.
  2. **Past-content backfill:** `authorHandle` is denormalized on every post,
     reply, and reflection with no backfill, so a change leaves old content under
     the old handle. A callable Cloud Function would paginate the user's `posts`
     (`where authorId==uid`), `replies` (collectionGroup `where authorId==uid`),
     reflections, and the follow-graph `handle` mirrors and batch-update
     `authorHandle`. Bounded + idempotent, but non-trivial (hundreds of docs,
     collectionGroup over replies, Admin SDK server-side). Decide forward-only vs
     backfilled at build time.
  3. **Option 3 block suggestion (the trigger):** after a block (on
     `.userBlocked`), show a calm, optional, dismissible sheet with a one-tap
     "give me a new handle". Approved wording (variant 2):
     > **a fresh handle?** they won't see your posts in their feed anymore. if
     > you'd feel more at ease, you can switch to a new random handle for anything
     > you write from now on. your older posts keep the handle they were written
     > under.  [ give me a new handle ] [ not now ]
     (If backfill ships, soften "older posts keep…" accordingly.)

---

## B94-MFA — iOS sign-in can't complete a TOTP second factor (BLOCKING) [FIRST]

- **Severity:** HIGH (blocking) · **Surface:** iOS sign-in (`toska/SignInView.swift`) · **Status:** FIXED 2026-10-23 (compiles; on-device verify after build 94)
- **Why blocking:** the owner's admin account now has TOTP MFA enrolled. iOS has
  no multi-factor sign-in handling, so signing out of the app = locked out of
  that account (the account crisis pages go to). The current iOS session stays
  valid (sessions persist through enrollment), so there's no live outage — but
  until this ships, DO NOT sign out of iOS on that account or change its
  password/revoke its tokens.
- **Fix:** implement the MFA resolver in the Swift sign-in path — catch the
  multi-factor-required error, get the `MultiFactorResolver`, prompt for the
  6-digit code, build `TOTPMultiFactorGenerator.assertionForSignIn(enrollmentID,
  code)` and `resolver.resolveSignIn(assertion)`. Mirror of the admin.html + web
  app.js web flow. Clear errors for wrong/expired code.
- **Recovery if locked out meanwhile:** Admin-SDK unenroll (ops doc) → sign in
  with password → re-enroll.

---

## B94-3 — Feed GIF shows a brief blank before loading (minor polish)

- **Severity:** LOW (polish, not a blocker) · **Surface:** iOS feed · **Status:** FIXED — neutral placeholder (stable reserved height + crossfade, `StableGifPreview` in ComposeView.swift) shipped in build 96 (5ff0121); build 102 (c246d6a) added off-main decode + decoded-image cache, WebP rendition w/ .gif fallback, and next-row prefetch. **Device-verify on 102.**
- **Reported:** 2026-10-23, owner device test on build 94. The B94-1 render-timing
  bug is fixed (GIF now appears without tapping in), but there's still a slight
  load delay where the row shows empty space before the GIF paints.
- **Quick idea:** render a placeholder while the GIF loads — a neutral
  rounded-rect at the GIF's aspect ratio (or a low-res thumbnail / first-frame
  still if the host exposes one), swapped for the animated GIF on load. Prevents
  the empty-gap flash and the row-height jump. `StableGifPreview` (FeedView.swift
  ~868) is the place; it already has the URL by value now.

---

## B94-FCM — FCM token not restored after sign-out/sign-in (crisis delivery)

- **Severity:** HIGH · **Surface:** iOS push registration · **Status:** FIXED + DEVICE-VERIFIED on build 95, 2026-10-23
- **Device verification (build 95):** all three recovery paths confirmed to write a
  fresh token to `private/data` — (1) sign-out → sign-in w/ TOTP, (2) Settings push
  toggle off → on, (3) foreground after a server-side token drop. Crisis delivery
  to the owner device confirmed restored.
- **Finding:** after the owner's build-94 sign-out → sign-in, `users/{ownerUid}/private/data`
  had **no `fcmToken`**; toggling in-app notifications back on set `pushEnabled:true`
  but STILL wrote no token (`fcmTokenUpdatedAt` stayed at the sign-out time), and
  reopening the app didn't help. Crisis pages would not reach the device.
- **Root cause (two gaps):**
  1. Sign-out calls `Messaging.deleteToken` (invalidates the token). On a
     same-session sign-in, `refreshFCMToken()` fires once via `.userDidSignIn` but
     the token isn't minted yet (no APNs re-registration), so it fetches nothing;
     `didReceiveRegistrationToken` never re-fires. Self-heals only on cold launch —
     and foreground (scenePhase `.active`) only cleared the badge, never retried.
  2. `SettingsView.requestPushPermissionIfNeeded()` `.authorized` branch did `break`
     — re-enabling the toggle wrote the pref but never re-registered/fetched a token.
  This hit ANY user who signed out and back in, not just MFA accounts.
- **Fix:** new `PushNotificationManager.reregisterForPush()` — re-registers APNs
  (so the delegate re-fires with a fresh token) + best-effort fetch+save, gated on
  granted permission. Wired to: `.userDidSignIn` (ContentView), app-foreground when
  signed in (ContentView scenePhase), and the Settings toggle `.authorized` branch.
- **Verify on build 95:** sign out → sign in → `fcmToken` present in private/data;
  toggle off/on restores it; foregrounding after a drop restores it.

---

## B94-1 — Feed GIF doesn't render until the row is re-laid-out (tap-in / scroll)

- **Severity:** LOW (cosmetic) · **Surface:** iOS feed · **Status:** FIXED 2026-10-23 — gifUrl now on the FeedPost model, set in feedPost(from:), row reads post.gifUrl (side-dict fallback kept). Compiles. Verified on device build 94 (renders without tapping; residual load-delay = B94-3).
- **Reported:** 2026-10-23, owner device test on build 93
- **Regression?** No. Pre-existing on 91/92 (established by code reading, not by running those builds — build 93's only iOS deltas were logging/wording/comments, which don't touch this path).

**Repro:**
1. Post a GIF, or open a fresh feed containing a just-created GIF post.
2. The post row appears with text but no GIF.
3. Tap into the post → the GIF shows. Back out → it now shows in the feed too. (Scrolling the row off/on screen also makes it appear.)

**Diagnosis:**
The feed row renders GIFs via `StableGifPreview` (FeedView.swift ~868), but the
row receives its URL *by value* at construction: `gifUrl: vm.postGifUrls[post.id]`
(FeedView.swift ~1880). `postGifUrls` is filled by
`FeedViewModel.extractPostMetadata(from:)` (FeedViewModel.swift ~1169-1171) from
the feed snapshot — which can populate *after* the rows first lay out. Because
the URL is captured at row-build time (nil then), the row doesn't rebuild when
`postGifUrls` later gains the entry, until SwiftUI re-lays the row for another
reason (scroll, or returning from PostDetailView, which reads the doc directly).

**Proposed fix (build 94):**
Make the row read `gifUrl` reactively instead of by captured value — e.g. have
`FeedPostRow` take the `postId` and look up `vm.postGifUrls[id]` inside its own
`body` with `vm` as an `@ObservedObject`, so a `@Published` change to
`postGifUrls` re-renders it. Alternatively, carry `gifUrl` on the `FeedPost`
model itself and set it during the same snapshot parse that builds the row data
(single source of truth), avoiding the side-dictionary timing entirely. Verify
with a GIF post appearing in a live feed without any tap/scroll.

---

## B94-2 — Repost not reflected in the feed until manual refresh

- **Severity:** LOW–MED · **Surface:** iOS repost + feed · **Status:** FIXED 2026-10-23 — repost() now posts .postInteractionChanged (unrepost already did); the dead handleInteractionChanged 'repost' case now fires so all copies + the shared store flip immediately. Compiles.
- **Reported:** 2026-10-23, owner device test on build 93
- **Regression?** No. Pre-existing on 91/92 (same basis as B94-1).

**Repro:**
1. Repost a post.
2. The feed doesn't show the repost / updated state immediately.
3. Pull-to-refresh → it appears.

**Diagnosis:**
Reposting writes a new post doc (`{uid}_repost_{postId}`). The feed uses a
snapshot listener (FeedViewModel `addSnapshotListener`, ~1021/1038/1057), so the
new doc *does* arrive on the next snapshot — but the **optimistic** UI update at
action time isn't applied, so there's a visible gap until the listener delivers
(or the user refreshes). The reposted-state set (`repostedPostIds`,
InteractionStateStore) and/or the inserted repost row aren't updated in the same
turn as the tap.

**Proposed fix (build 94):**
On a successful repost, optimistically (a) add the id to `repostedPostIds` so the
button flips immediately, and (b) insert/refresh the repost entry locally rather
than waiting for the snapshot — mirroring how like/save optimistic updates are
handled. Reconcile with the listener's authoritative copy when it arrives (guard
against a double-insert when the snapshot delivers the same doc). Verify a repost
shows in the feed with no manual refresh, and that the count/state stays correct
after the listener catches up.

---

*Both found during the build-93 production verification pass. Critical paths
(sign-in, feed load, GIF post, crisis detection + 988 + crisis page push,
moderation) all confirmed working on 93; these two are cosmetic/feedback polish.*

---

## B94-W — Full web sharing-consent UI (checkbox at sign-up + web settings toggle)

- **Severity:** MED (consent/privacy) · **Status:** OPEN — build 94 / web
- **Context:** As of 2026-10-23 web sign-up sets `allowSharing: false` (opt-in; stops the silent opt-in that had no wording and no control). But web still has NO way for a user to turn sharing *on* later, and no wording is shown. iOS has a Settings toggle; web has nothing.
- **Proposed:** (a) add an optional checkbox at web sign-up with the SEO-01 wording ("share publicly — your post may be featured on the toska website and appear in Google search. your handle is never shown."), unchecked by default, writing `allowSharing` accordingly; (b) add a sharing toggle to the web app (settings/profile) so web users can see and change it, matching iOS. Reuse `showSharing` wording verbatim from iOS SettingsView.
- **Policy wording re-edit (when this ships):** update privacy.html:127 and terms.html:113 — they currently say "new accounts start with it off; turn it on/off in the toska iPhone app under Settings → Privacy." Once the web sharing toggle exists, drop "iPhone app" and mention the web setting; once sign-up checkboxes exist (both platforms), mention the at-sign-up choice.
- **Do not** change existing accounts.

## B94-iOS — Sharing opt-in on iOS (defaults done; sign-up choice pending)

- **Severity:** MED (consent/privacy) · **Status:** FIXED 2026-10-23 — defaults false at all 3 paths + opt-in checkbox on the email sign-up form (CreateAccountView). Apple/Splash button flows keep default-off + Settings opt-in (no form to host a checkbox — owner to decide if a post-Apple-signup prompt is wanted).
- **Done (2026-10-23):** creation default flipped to `allowSharing: false` at all three paths — CreateAccountView, AppleSignInHelper, SplashView. Settings toggle unchanged (still the opt-in control). Read-fallbacks (`?? true`) deliberately left so existing/legacy accounts are unchanged.
- **Pending (build 94):** add an optional choice at sign-up (CreateAccountView + Apple/Splash onboarding) showing the SEO-01 wording, unchecked by default, that sets `allowSharing` at creation. Keep the Settings toggle.
- **Do not** change existing accounts.

---

## B94-APPLE — one-time post-signup sharing prompt for Apple/Splash (deferred)

- **Status:** DEFERRED (owner decision 2026-10-23). Apple/Splash button flows keep allowSharing:false at creation + Settings opt-in. Future nicety: a one-time "share publicly?" prompt (SEO-01 wording) after an Apple/Splash first sign-up so those users see the choice without opening Settings.

---

## TECH-DEBT-RULES-CEILING — posts-create rule is AT the 1000-expression limit (post-launch refactor)

- **Severity:** tech debt (blocks future rule-layer security changes) · **Surface:** firestore.rules · **Status:** OPEN, logged 2026-10-26
- The `allow create` on `match /posts/{postId}` evaluates right at Firestore's hard **1000-expression ceiling**. Confirmed empirically: adding consent binding B (one `||` clause + a `get()`) made the emulator reject even the happy path with `Unable to evaluate ... maximum of 1000 expressions ... for 'create'`. The clause was reverted; B now lives in Cloud Functions + render-gates instead (see CONSENT-B below).
- **Impact:** any NEW post-create security constraint cannot be added at the rule layer until expressions are freed. New checks must go into `validatePost`/render gates, which carry a brief visibility window the rule layer doesn't.
- **Fix direction (post-launch):** either (a) split the posts-create rule (factor repost vs original into separate `match` legs or helper functions to shrink the evaluated chain), or (b) move some existing checks into `validatePost` to reclaim headroom. Measure with the emulator after each change.

---

## CONSENT-B/C — sharing opt-in enforced server-side (render-gate + re-stamp)

- **Severity:** MED (consent/privacy) · **Surface:** functions · **Status:** DEPLOYED PROD 2026-10-26 + committed (c246d6a) — staging probe 9/9 (`consent-render-gate-probe.mjs`), prod smoke: consenting author renders 200, non-consenting 404s
- **Why not in rules:** B (bind isShareable→allowSharing at post-create) couldn't fit the create rule (see TECH-DEBT-RULES-CEILING). Enforced instead at every public render surface + a server re-stamp.
- **B render-gate:** `evaluateSharePage` now takes the author's LIVE `allowSharing` and 404s when it isn't true — covering `/p/` (sharePage), `/og/*.png` (shareCardImage), the sitemap, and publicFeed (batched author lookup). Closes tampered self-stamps, stored-flag drift, and "turned sharing off after sharing."
- **B re-stamp:** `validatePost` clears `isShareable` on an ORIGINAL post when the author's live consent is off (so the in-app share button respects it too). Reposts untouched (rule-pinned to the original author's consent).
- **C:** `onAllowSharingChanged` now queries own posts by `authorId` only and branches on `isRepost` in code — the old `.where("isRepost","==",false)` silently skipped field-less originals, so revocation never retracted them.
- **Tests:** sharePage.test.js +3 consent cases (21/21 pass). Staging probe pending (post w/ allowSharing false, and author-turns-off-after-sharing, must 404 on every public surface).

---

## CONSENT-A/D/E — client opt-in hardening (iOS + web)

- **Severity:** MED (consent/privacy) · **Surface:** iOS + web · **Status:** FIXED + committed (c246d6a) — web live in prod; iOS in build 102 (on TestFlight, hand-test 2026-10-27)
- **A (iOS):** `UserHandleCache.allowSharing` now defaults **false** (was true) + reset to false in `stopListening`; `ComposeView.postNow` reads the real `allowSharing` from the same user-doc snapshot it fetches for the handle when the cache is still unloaded — so a post composed in the post-sign-in/account-switch window is never over-shared, and a genuine opt-in isn't dropped.
- **D:** flipped the `?? true` consent reads to `?? false` (fail closed) — UserHandleCache:87, FeedView:561, PostDetailView:1152, ProfileView:973/1068, ShareCardView:48, SettingsView:611, PostInteractionManager reply-repost author read:1032, and web writes.js createPost. LEFT `?? true` on the repost-mirror reads (PostInteractionManager:414, web writes.js:229) — rules pin a repost's isShareable to `== original.get('isShareable', true)`, so flipping only that side would reject reposts of field-less originals.
- **E (web):** `createPost` adds `&& !isMidnight` to isShareable, matching iOS (ComposeView excludes expiresAtMidnight).

---

## WEB-AUTH-LATENCY — slow web sign-in/sign-up (step 1 FIXED; minInstances DECLINED)

- **Severity:** perf · **Surface:** web (app.js) + functions · **Status:** step 1 SHIPPED prod 2026-10-26 (c246d6a); minInstances **decided AGAINST** (owner, 2026-10-26)
- **Symptom:** web sign-in paused a beat; sign-up sat ~10s on the same screen.
- **Root cause:** reCAPTCHA Enterprise App Check token was minted lazily on the
  first attested call (the submit click), not on page load; signup additionally
  waited on two cold-start functions in the account-creation critical path
  (`blockBannedSignups` beforeUserCreated, `confirmAdult` callable).
- **Step 1 shipped:** (a) warm App Check — mint a token at page load so it's
  ready by submit; (b) "setting up your space…" progress message on signup;
  (c) un-await `confirmAdult` and retry it in-session (safe: the 18+ gate is
  enforced server-side — posts AND replies create rules require
  `hasConfirmedAdult()`, firestore.rules:1154/1615, and `confirmedAdult` is
  server-owned, so routing can't bypass the age check).
- **minInstances — DECLINED (owner 2026-10-26):** after the warm-up, sign-in is
  noticeably faster, so the App Check mint was the dominant cost, not function
  cold starts. Not worth ~$6–12/mo for always-warm `blockBannedSignups` +
  `confirmAdult`. **Revisit only if** signup feels slow again in the 5–10s range
  (that would point back at those two cold starts); then `minInstances: 1` on
  just those two is the fix. Sign-in is unaffected by minInstances (no blocking
  function on that path).

---

## WEB-PW-8 — web signup accepted 7-char passwords / unclear message (FIXED)

- **Severity:** MED (auth policy mismatch) · **Surface:** web (app.js) · **Status:** FIXED 2026-10-27 — staging-verified, DEPLOYED PROD hosting + committed (7a3cd07)
- Found in the 2026-10-27 full-app-test pass: web signup had no client length check, the placeholder said "at least 6 characters", and the weak-password error mapped to "…at least 6", contradicting the server's 8-char policy.
- **Fix:** placeholder → "at least 8 characters"; client-side `pw.length < 8` guard with "password must be at least 8 characters."; weak-password / password-does-not-meet-requirements error mapped to the same 8-char message. Staging-verified: 7-char blocked with the correct message.

---

## WEB-HANDLE-FORMAT — web accounts got anonymous_<uuid> instead of word-pair handles (FIXED, new accounts)

- **Severity:** MED (cross-surface parity / brand) · **Surface:** web (app.js) · **Status:** FIXED 2026-10-27 for NEW accounts — staging-verified (`sadly_wound_916`), DEPLOYED PROD hosting + committed (7a3cd07)
- Web `claimHandleAndCreateUserDoc` generated `anonymous_<uuid8>`; iOS generates `{adjective}_{noun}_{1-999}`. Fix ports the EXACT iOS word lists (ContentModeration.swift handleAdjectives/handleNouns, 30+30 — keep in sync) to app.js `HANDLE_ADJECTIVES`/`HANDLE_NOUNS` + `randomWordHandle()`; same batched handles/{h} registry claim; the last-resort fallback after 4 collisions (≈900k combos) stays WORD-BASED with a wide 6-digit number (`randomWordHandle(999999)`) — **never anonymous_** (owner 2026-10-27) — so signup can't hard-fail and no anonymous_ handles are ever minted.
- **Existing prod `anonymous_` handles: 3 of 11 users** (3 registry rows) — the web-created accounts. **NOT migrated** — only new accounts change. Migrating the 3 would ripple through the handle registry + byline pins; left for a separate owner decision.

---

## APPCHECK-STAGING-DEBUG — iOS simulator App Check debug token registered (STAGING ONLY)

- **Severity:** test infra · **Surface:** iOS UI tests vs staging · **Status:** DONE 2026-10-27 (fixed-token setup)
- The iOS simulator uses `AppCheckDebugProviderFactory` (toskaApp.swift:87, `#if DEBUG` only — Release uses AppAttestProviderFactory and NEVER reads FIRAAppCheckDebugToken). Authenticated UI tests stalled at "Feed didn't load after sign-in" because the debug token wasn't registered — and `xcodebuild test` reinstalls the app each run, rotating the token, so a one-off captured token never sticks.
- **Repeatable setup (fixed token):**
  1. A fixed UUID lives in the gitignored `~/Desktop/toska/.local-credentials.md` as `TOSKA_STAGING_APPCHECK_DEBUG_TOKEN=<uuid>` (NOT committed — repo is public).
  2. It's registered as a debug token on the **staging** iOS app ONLY: `projects/260913424323/apps/1:260913424323:ios:a6631554b2614bed01ff76/debugTokens` (displayName `sim-uitest-fixed`). **Never prod.** (The old rotating `sim-uitest-2026-10-27` token was deleted.)
  3. `build/ios-uitest.sh` exports `TEST_RUNNER_FIRAAppCheckDebugToken` (read from the creds file); XCTest forwards `TEST_RUNNER_`-prefixed vars to the runner, and each auth test class's `setUpWithError` calls `applyAppCheckDebugToken(app)` (WalkthroughUITests.swift) to put it in `app.launchEnvironment["FIRAAppCheckDebugToken"]` for the DEBUG debug-provider.
- Also: run `-parallel-testing-enabled NO` (clone keychain -34018) and pass staging creds as `TEST_RUNNER_TOSKA_EMAIL` / `TEST_RUNNER_TOSKA_STAGING_TEST_PW`.

---

## IOS-SIM-AUTH-FEED — authenticated iOS UI tests don't load the feed on the simulator (post-launch test-infra)

- **Severity:** test-infra (NOT a product bug) · **Surface:** iOS XCUITest vs staging · **Status:** OPEN, deferred post-launch 2026-10-27. **Authenticated iOS flows are tested BY HAND on a real device for now.**
- **Symptom:** every authenticated UI test (`WalkthroughUITests.test02_login`, `test02z_coldLaunchFeedRenders`, all `CrossSurfaceTests`, `ShareCardInteractionTests`) fails at "Feed didn't load after sign-in." Sign-in (Auth) succeeds; the feed never populates in the simulator. Web sign-in loads the feed fine on the same staging backend, so **the data/rules are correct — this is simulator-specific.**
- **What I learned (2026-10-27), ruling out App Check:**
  - The simulator's debug token does NOT rotate — it persists in the app container (`D1C03947…`) across `xcodebuild test` reinstalls.
  - Registering that exact token for staging (run `by759021c`) did **not** fix the feed load.
  - A fixed injected token (`FIRAAppCheckDebugToken` via `launchEnvironment`) was **ignored** — the persisted UserDefaults token wins unless the container is erased first.
  - Both paths → identical "Feed didn't load." **So App Check registration is not the fix**; the blocker is deeper (matches the long-standing "simulator has ~4 stacked App Check issues" note).
- **Non-auth iOS tests pass** (splash, logged-out feed, sign-in/create-account flow existence, launch, perf, sign-out, probe) — those remain useful CI/local signal.
- **Next steps (post-launch):** either run the auth UI tests on a **registered real device** (reliable), or, to make the simulator path work, `simctl erase` before the run so the injected fixed token is used AND dig into why the feed listener doesn't populate under the debug App Check provider. The harness is ready for a real device (fixed token registered; `applyAppCheckDebugToken` hook wired into every auth test class).

---

## DELETION-CASCADE — §11 GDPR cascade verified clean (2026-10-27)

- **Severity:** verification · **Surface:** functions (staging) · **Status:** PASS 2026-10-27
- `firestore-tests/deletion-cascade.mjs` (live staging): after deleting users/V, NO residue — V's post, reply, like, repost, user subtree, O's follower/following entries for V, and V's report all removed; O.followerCount correctly decremented to 0.

---

## CRISIS-TEST-CLEANUP — automated crisis test tripped the staging watchdog (FIXED)

- **Severity:** test hygiene (false crisis alert) · **Surface:** staging crisis watchdog · **Status:** FIXED 2026-10-27
- **What happened:** the 2026-10-27 full-app-test `fulltest-backend-probe` created a crisis post to verify it's held. The crisis trigger wrote an `undeliveredCrisisPages/crisisAlert_<postId>` record; the probe deleted the POST but not that record. Staging has no real `crisisAlertRecipients`, so the record stayed unclaimed, and `crisisDeliveryWatchdog` paged "[STAGING] crisis page UNDELIVERED" ~15min later (04:17 UTC, post `ftpost_crisis_mvq5ni4e`). **Prod was clean** (undeliveredCrisisPages = 0 in that window).
- **Fix:** (1) deleted the stray staging record; (2) `fulltest-backend-probe.mjs` teardown now waits for the trigger, then deletes `undeliveredCrisisPages/crisisAlert_<id>` + `processedTriggerEvents/crisisAlert_<id>` for every test post; (3) `fulltest-cleanup.mjs` sweeps the same records for test-post patterns. Any future automated crisis test cleans up after itself, so the staging watchdog won't false-alarm.
- **Note:** the crisis *hold* behavior is correct — the watchdog did its job; the gap was test teardown, not the safety path.

---

## M5 — Apple Sign-In silently no-ops when no presentation window (FIXED)

- **Severity:** MED (auth) · **Surface:** iOS (AppleSignInHelper) · **Status:** FIXED + committed (c246d6a), in build 102
- `presentationAnchor` returned a throwaway `UIWindow()` when no foreground key window was found → the Apple sheet presented over an invisible window and the continuation hung ("button does nothing"). Fix: try the active scene's key window, then any scene's key window, then any window; if truly none, resume the continuation with an error ("Couldn't start Sign in with Apple. Please try again.") so the UI surfaces it, then return a detached anchor only to satisfy the non-optional API.

---

## M4 — "back to login" raced clearFCMToken against signOut (FIXED)

- **Severity:** MED (push/account hygiene) · **Surface:** iOS (ContentView verify-error escape hatch) · **Status:** FIXED + committed (c246d6a), in build 102
- The escape-hatch button called fire-and-forget `clearFCMToken()` then `signOut()` immediately; `clearFCMTokenAndWait` reads `currentUser?.uid`, which `signOut()` clears first, so the Firestore `fcmToken` delete could be skipped (stale token → pushes to the wrong account). Fix: wrap in a `Task { @MainActor }` and `await clearFCMTokenAndWait()` before `signOut()`, matching every other sign-out path.

---

## M3 — uncancelled 15s sign-in sweep Task can complete after the user leaves (OPEN)

- **Severity:** MED (auth lifecycle) · **Surface:** iOS (SignInView ~296) · **Status:** OPEN, logged 2026-10-26
- On a 30s email-sign-in timeout, a bare `Task` polls `currentUser` for 15s with no cancellation on disappear. If the user backs out, it can still complete sign-in and `dismiss()` out from under them. Not a cross-account leak (the late `signIn` only sets the just-submitted credential). Fix: store the task, cancel in `.onDisappear`, and require `currentUser` was nil at call start.

---

## M2 — dead DM-cleanup step still runs each account-deletion cascade (OPEN)

- **Severity:** LOW (vestigial) · **Surface:** functions (cleanupUserConversationsForUid ~501) · **Status:** OPEN, logged 2026-10-26
- DMs were cut (conversations/messages denied in rules), so no convo docs exist, yet every deletion pays a `participants array-contains uid` query, and the comment block still asserts live DM-cleanup semantics. Harmless; drop the step or mark it vestigial.

---

## LOW-BATCH-2026-10-26 — minor review findings (OPEN)

- **Severity:** LOW · **Surface:** iOS/functions · **Status:** OPEN, logged 2026-10-26
- **L1** — BlockedUsersCache not started on the inline sign-in success paths (SignInView/AppleSignInHelper/SplashView/CreateAccountView start only UserHandleCache; block cache starts via toskaApp.swift:181 auth-state callback). Ordering window where a feed can render before blocks load. Fix: start BlockedUsersCache alongside UserHandleCache on each path.
- **L2** — New-account rollback orphans the claimed handle-registry entry (AppleSignInHelper ~165/211, parallel Google/email paths): rollback deletes the auth user but not the handle claim, slowly burning handles.
- **L3** — `FeedViewModel` client filter defaults missing `moderationStatus` to `"live"` (fail-open). Low risk (all posts created with an explicit status); prefer fail-closed.
- **L5** — `unrepostReply` (PostInteractionManager ~1150) only deletes the deterministic doc and doesn't broadcast `.postDeleted`, unlike `unrepost`; a legacy reply-repost row could linger until refresh.
- **L4 (nit)** — `SettingsView` ~1060 `var url` should be `let` (compiler warning only).
