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

- **Severity:** BLOCKING for launch · **Surface:** iOS (PushNotificationManager, toskaApp) · **Status:** OPEN 2026-10-25
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

- **Severity:** LOW (polish, not a blocker) · **Surface:** iOS feed · **Status:** OPEN
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
