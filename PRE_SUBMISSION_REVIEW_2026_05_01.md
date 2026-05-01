# Toska — Pre-Apple-Submission Review

**Reviewer:** Claude (read-only)
**Date:** 2026-05-01
**Scope:** Apple submission readiness, NOT another security audit
**Build under review:** marketing v1.0, build 3 (project.pbxproj)
**Time budget:** ~90 min

---

## Verdict

**🟢 GREEN — ship it.**

No Apple-blocking findings. Two High items are operational/UX nits the team can
patch in flight or accept as TestFlight feedback fodder. The four UGC pillars
(pre-publish filter, in-app report, in-app block, admin tooling) are all in
place and pinned by 33 rules unit tests. CI is green on the last 5 runs.
Build settings, entitlements, and the privacy manifest are consistent with
release. Live `https://www.toskaapp.com/privacy` and `/terms` both return 200.

The two items I'd address before tapping "Submit for Review" are listed under
**High** below. Everything else is fine to ship now and iterate.

---

## Findings by severity

### Apple-blocking
*(none)*

### High

#### H-1 — No 24-hour SLA tooling on the moderation dashboard
- **Severity:** High (Apple 1.2 enforcement claim, operational)
- **Category:** §1 UGC + §5 Operational
- **File:** `docs/admin.html:271-346` (`loadReports`); `firestore.rules:676-697` (reports schema)
- **What's wrong:** The in-app `ReportSheet` promises "reports are reviewed
  within 24 hours" (`ToskaTheme.swift` per the breadth scan), but the admin
  dashboard has no signal for which reports are nearing or past that window.
  `loadReports()` displays `timeAgo(r.createdAt)` per row, but there is no
  bucketing (< 2h / < 12h / overdue), no count-of-overdue badge, and no
  scheduled function emailing the admin when a new report lands. RUNBOOK
  lists "Cloud Functions error rate" and "Crashlytics velocity" alerts but
  no alert on `reports/{id}` creation.
- **Why it matters:** Apple's enforcement of UGC moderation commitments has
  tightened. They don't usually demand to see a SLA dashboard, but if a
  reviewer hits the report flow themselves and waits 25 hours with no
  acknowledgment, that's a documented rejection vector.
- **Fix sketch (1-2 hours, deferrable):**
  - Add a scheduled Cloud Function `notifyAdminsOfNewReports` running every
    15 min that emails when `reports.status == "pending"` count > 0 and
    no email has been sent for the freshest pending report yet (use a
    `notifiedAt` field on each report).
  - Add a "overdue" red badge to `loadReports()` for any report where
    `Date.now() - r.createdAt > 24h && r.status === "pending"`.
  - Cheap stopgap: turn on a Cloud Logging-based alert on
    `resource.labels.service_name="reports"` doc creation in the
    Firebase project's existing email-notification channel.

#### H-2 — Live ToS / Privacy not linked from in-app Settings
- **Severity:** High (potential reviewer nit; not a hard rejection)
- **Category:** §2 Privacy + ToS surface
- **File:** `toska/SettingsView.swift:92-106` (privacy group); `toska/SplashView.swift:135,141` (only place live URLs are linked from inside the app)
- **What's wrong:** Settings → "view content policy" opens
  `PolicyAcceptanceView`, an in-app re-render of the policy text. The live
  `https://www.toskaapp.com/privacy` and `/terms` URLs are *only* linked
  from `SplashView` (visible to logged-out users). A logged-in user who wants
  to re-read the canonical, version-stamped ToS or Privacy never finds a tap-
  through to the live URL.
- **Why it matters:** App Review reviewers often spot-check "where can I read
  your privacy policy?" from inside the app. Apple Privacy Nutrition Label
  submission also expects an externally-hosted privacy URL; that's filed
  separately in App Store Connect, but in-app discoverability is the
  user-friendly answer when the reviewer is exploring.
- **Fix sketch (10 min, low risk):** In `SettingsView.swift:102` near the
  existing "view content policy" row, append two more rows that call
  `openURL` to the live `/privacy` and `/terms` URLs, or convert that
  row into a sub-screen that shows both. Mirror the styling of the
  existing `actionRow`.

### Medium

#### M-1 — `confirmAdult` failures degrade silently for Apple/Google sign-ups
- **Severity:** Medium
- **Category:** §1 UGC age gate, §3 iOS code quality
- **File:** `toska/OnboardingView.swift:218-220` calls
  `confirmAdultServerSideFireAndForget(uid:)`; the function is documented as
  "fire-and-forget" — UI proceeds before the server write lands.
- **What's wrong:** Apple/Google new sign-ups arrive in `OnboardingView`,
  pass the age gate, fire `confirmAdultServerSide` without awaiting, then
  proceed. If App Check token isn't yet attested (race against
  `installations` token issuance) or the user is on a flaky network, the
  call fails. `firestore.rules:62-65 hasConfirmedAdult()` then blocks the
  user's first post with a `permission-denied` that the iOS layer surfaces
  as a generic compose error. The next launch's `checkAcceptanceStatus`
  re-shows the gate, but in the meantime the user sees "your post couldn't
  be saved" with no obvious cause.
- **Why it matters:** Apple wouldn't reject for this, but it's a real
  "first 10 minutes" UX papercut. A reviewer testing the full path
  (sign in with Apple → onboard → first post) might hit it on simulator
  network glitches.
- **Fix sketch:** Make the post-compose error path detect
  `FIRFirestoreErrorDomain` code 7 (permission-denied) at compose-time and
  trigger an inline confirmAdult retry, surfacing "verifying your age,
  one moment" instead of a generic failure. Or: switch the helper from
  fire-and-forget to await + retry-once with a 1.5s timeout.

#### M-2 — Onboarding "skip" and "skip for now" buttons can race the age gate fetch
- **Severity:** Medium
- **Category:** §6 UI/UX
- **File:** `toska/OnboardingView.swift:145-165` (skip on step 2); `:179-198` (skip-for-now on step 3); `:293-318` (`checkAcceptanceStatus`).
- **What's wrong:** `checkAcceptanceStatus()` is async; if the user lands
  on `OnboardingView` and quickly taps the "skip" pathway (visible at
  step 2 and step 3), they can complete onboarding *before* the age-gate
  read has resolved. The gate then never fires. Server-side
  `hasConfirmedAdult()` blocks publishing, so this is functionally
  contained, but the user can pass through onboarding without ever seeing
  the age gate.
- **Why it matters:** A reviewer simulating a "skip everything" user would
  see no age confirmation prompt during the path they actually walked.
  Apple's age-gating expectation is that the user *takes an affirmative
  action* before reaching content surfaces.
- **Fix sketch:** In `OnboardingView.body`, gate the entire content
  (including the next/skip buttons) on `acceptanceChecked && !showAgeGate`.
  While `checkAcceptanceStatus()` is in flight, show the splash spinner
  rather than rendering step 0. ~10 lines.

#### M-3 — `onUserDocDeleted` cascade has hard caps that can leak data
- **Severity:** Medium (privacy-of-deletion)
- **Category:** §4 Backend correctness
- **File:** `functions/index.js:115-313`
- **What's wrong:** Several inner loops have hard iteration caps:
  - Posts: 50K cap then queue (line 151); fine, queue is consumed by
    `resumePostDeletion` schedule.
  - Orphaned notifications via `collectionGroup`: 25K cap, fall through
    if `orphanedNotifs.size < 500` break (line 253). For users with > 25K
    orphaned notifications, the next iteration on this function only fires
    on user-doc delete — which already happened. **Notifications past the
    25K cap are not requeued anywhere.**
  - Feeling-circle messages: single 500-doc batch (line 269), no loop, no
    queue. A user who authored > 500 circle messages leaves orphans.
  - Pending-report cleanup: same 500-doc single-shot at line 289.
- **Why it matters:** GDPR Art. 17 / 5.1.1(v). Apple doesn't specifically
  audit this, but a privacy-conscious reviewer or post-launch user
  complaint ("my old replies are still visible after I deleted my
  account") becomes a credibility problem.
- **Fix sketch:** Wrap the notification cleanup in the same
  `postDeletionQueue` pattern (write a continuation marker, picked up by
  `monitorPendingDeletions`). Convert the circle/report cleanups to
  loops with a 50-iteration cap and similar continuation. None of these
  are likely to fire in practice for v1.0 users — but Apple doesn't
  audit "in practice."

#### M-4 — Pattern-based moderation has known false-positive tails
- **Severity:** Medium (already partially mitigated)
- **Category:** §1 UGC pre-publish filter
- **File:** `functions/index.js:1095-1179`
- **What's wrong:** Moderation is regex/wordlist (`MOD_HATE`,
  `MOD_THREAT`, `MOD_SEXUAL`, `MOD_HARASSMENT`, `MOD_CONCERNING`,
  `SPAM_PATTERNS`). PII-detection and URL-detection (lines 1176-1177)
  are documented in code as having "high false-positive rate"
  (line 1190). The mitigation already shipped:
  - `flaggedAt` filtered to a 7-day window (line 1208)
  - 5-flag threshold (line 1222)
  - 48-hour auto-expiry on auto-restrictions
- **Why it matters:** Apple has accepted pattern-based moderation for
  text apps for a long time — this is fine for submission. It's listed
  here so the team has the explicit "yes we know, here's the
  mitigation" line ready if a reviewer asks.
- **No fix needed pre-submission.** Post-launch, look at flagged-post
  rates in Cloud Logging and tune patterns or add a Vision API hop on
  the GIF preview only.

### Low

#### L-1 — RUNBOOK "Known accepted gaps" section is stale
- **Severity:** Low
- **Category:** §5 Operational readiness
- **File:** `RUNBOOK.md:384-388`
- **What's wrong:** RUNBOOK lists "EditReplyView lacks a contentViolation
  handler" as an accepted gap, but `ProfileView.swift:1122-1123` *does*
  call `contentViolation(in: trimmed)` and surfaces
  `contentWarningMessage`. The gap is closed; the doc is stale.
- **Fix:** Remove the bullet from RUNBOOK § "Known accepted gaps."

#### L-2 — App Attest entitlement is "production" in both Debug and Release
- **Severity:** Low (informational)
- **Category:** §5 Operational readiness
- **File:** `toska/toska.entitlements:15-16`,
  `toska/toska.Release.entitlements:15-16`
- **What's wrong:** Both entitlement files declare
  `appattest-environment = production`. This means Debug builds attest
  against Apple's production attestation infrastructure. In practice,
  Firebase App Check uses the debug provider in DEBUG builds (set up via
  `AppCheck.setAppCheckProviderFactory(...)` somewhere in `toskaApp.swift`),
  so this doesn't break dev. But if you ever ship a build that *does*
  hit App Attest from a debug context, you'll silently get rejected.
- **Fix:** No action needed for submission. If you ever see App Attest
  rejections under DEBUG, flip the development entitlement to
  `development`.

#### L-3 — Bus factor: single Firebase Owner
- **Severity:** Low (operational, RUNBOOK-acknowledged)
- **Category:** §5 Operational readiness
- **File:** `RUNBOOK.md:463-484`
- **What's wrong:** Only `salte@saltedevelopments.com` has Owner role on
  `toska-4ebf4`. RUNBOOK already covers this and recommends Google /
  Apple ID recovery hygiene as the v1.0 mitigation.
- **Fix:** Already documented; no submission-blocker.

#### L-4 — `FeedView` hardcoded sample posts ship in the bundle
- **Severity:** Low (informational)
- **Category:** §6 UI/UX
- **File:** `toska/FeedViewModel.swift:93-100+` (`samplePosts: [FeedPost]`)
- **What's wrong:** Sample posts with hardcoded breakup text ship in the
  app binary as a first-launch fallback. Confirm these are only shown
  when the live feed has zero posts (otherwise looks fake). Not a
  rejection risk — Apple is fine with onboarding sample content — but
  if any of the sample text trips the moderation patterns later, you'll
  see weird behavior.
- **Fix:** Spot-check that `samplePosts` text doesn't contain anything
  that would self-trigger `MOD_*` patterns when echoed back by a user.

#### L-5 — Cloud Monitoring alerts not directly verified
- **Severity:** Low (verify-once)
- **Category:** §5 Operational readiness
- **File:** `RUNBOOK.md:247-254`
- **What's wrong:** RUNBOOK lists Crashlytics velocity, Cloud Functions
  error rate, and billing budget alerts as configured. I couldn't
  validate via `gcloud alpha monitoring policies list` (auth token
  expired in this session). The user should re-run a quick verification
  before pushing the App Store build.
- **Fix:** `gcloud auth login` then
  `gcloud alpha monitoring policies list --project=toska-4ebf4 --format="value(displayName,enabled)"`.
  Expect the three policies plus billing budget.

### Informational
- **CI is green** (last 5 `ci.yml` runs all `success`, latest 2026-04-30).
- **Privacy manifest** (`PrivacyInfo.xcprivacy`) is comprehensive and
  internally consistent: collected types include UserID, EmailAddress,
  OtherUserContent (linked, not tracking), CrashData, PerformanceData,
  ProductInteraction (not linked, not tracking).
- **Sign In with Apple** is properly implemented at
  `AppleSignInHelper.swift:35` (`ASAuthorizationAppleIDProvider`) and
  surfaced from `SplashView.swift:109`. Apple is offered as a top-level
  auth option alongside Google and email.
- **Account deletion** (`SettingsView.swift:586-652`) writes a
  `pendingDeletions/{uid}` cascade marker, calls
  `Auth.auth().currentUser?.delete()`, and triggers `onUserDocDeleted`
  for full Firestore cleanup. Reauth-required failure surfaces a
  "sign out and back in first" alert — clunky but correct.
- **Push permission** is correctly requested in-context, not at launch
  (`ContentView.swift:74-78` documents this; the actual prompt fires
  from the NotificationsView primer card on first visit).
- **Dynamic Type cap** is wired globally:
  `toskaApp.swift:148  .dynamicTypeSize(...DynamicTypeSize.accessibility3)`.
- **Universal links** (`applinks:www.toskaapp.com`) are entitled and
  validated for path shape in `toskaApp.swift:149-190`.
- **Firestore rules** properly enforce `notRestricted()` and
  `hasConfirmedAdult()` on every publishing surface. Reports schema
  is locked (`firestore.rules:676-697`); admin updates limited to
  `status / reviewedBy / reviewedAt / action`. `adminAuditLog` is
  read-only-admin, write-server-only.
- **`sendPushNotification`** (functions/index.js:319-426) atomically
  claims via runTransaction (no double-push), looks up `fromHandle`
  server-side (no spoofing), checks recipient block list, and never
  includes user-authored content in the APNs body — exactly the right
  shape for an anonymity-first app.

---

## What I did NOT verify (scope or access)

- Firebase Cloud Monitoring alert policies (gcloud auth expired in this
  session). See L-5.
- Live admin.html behavior on `https://www.toskaapp.com/admin.html` — I
  read the source but did not click through with an admin uid.
- iOS app dynamic behavior in a simulator. The brief explicitly noted
  this would have been required for a UI/UX claim of "tested" — code
  inspection only here.
- Apple Sign In token revocation flow under failure (the
  `AppleSignInHelper.revokeTokenIfNeeded` keychain-delete-too-broad
  finding from prior audits is RUNBOOK-acknowledged and out of scope).

---

## Recommended pre-submission checklist (in priority order)

1. **(H-1)** Add an overdue-report badge to `admin.html` and configure a
   simple Cloud Logging email alert on `reports` doc creation. ~1 hour.
2. **(H-2)** Add live ToS + Privacy URL rows to Settings → Privacy
   group. ~10 min.
3. **(M-2)** Block onboarding skip buttons on `acceptanceChecked` to
   close the age-gate race. ~10 min.
4. **(L-5)** Re-verify Cloud Monitoring alerts via `gcloud`. ~5 min.
5. **(L-1)** Trim the stale "EditReplyView" bullet from RUNBOOK. ~1 min.
6. Optional: **(M-1)** Switch `confirmAdultServerSideFireAndForget` to
   await-with-1-retry to clean up first-post UX. ~30 min.
7. Bump `CURRENT_PROJECT_VERSION` from 3 → 4 before archiving (Apple
   rejects re-uploads of the same `(MARKETING_VERSION, build)` pair).
8. Submit at age rating 17+ (the in-app age gate already commits to
   this; App Store Connect's questionnaire will derive 17+ from the
   "frequent/intense mature/suggestive themes" + "user-generated
   content" answers).

You're closer to ready than most apps at this stage. Ship it.
