# Toska — pre-submission audit specification

This document is a self-contained brief for an AI auditor running a full
pre-submission check against the Toska iOS app. It is written so the
auditor can come in cold, build a complete model of the app, run every
verification that doesn't require a human, and produce a single
severity-ordered report suitable for go/no-go on App Store submission.

Read this document end-to-end before starting any tool calls. Do not skim.

---

## 0. Mission

For each surface in the app, answer four questions:

1. **Does it work end-to-end** at the code-and-rules layers we can verify
   without a real device?
2. **Is it safe** under the Toska-specific threat model (anonymity-first;
   adversary is a motivated stalker who knows their target uses the app)?
3. **Is it stable** — no crashes, no silent failures, no race conditions
   that strand state, no unbounded queries that OOM at scale?
4. **Is it submission-ready** — privacy disclosures match the binary,
   moderation flow exists, age-rating questionnaire is honest, demo
   account is wired?

If any answer is "no" or "unverifiable," surface it. The failure mode
of this audit is rubber-stamping; bias toward saying "I cannot verify
X without a real device" rather than assuming X works.

---

## 1. What Toska is (read this first — the threat model is unusual)

Toska is an anonymous social app for people going through breakups —
"Reddit, but only for breakups." Users post short reflections under
anonymous handles, react, follow, send DMs. **There are no real-name
profiles.** The brand wedge is privacy + emotional vulnerability.

### The threat model has two axes

**Axis 1 — deanonymization.** The single worst outcome for any user is:
a motivated abuser/stalker confirms "this anonymous account is my ex."
Treat any path that links an anonymous handle back to real identity
(Apple/Google sub claims, email, phone, FCM token, IP, device ID,
correlated timing, push lock-screen leakage, Crashlytics user ID, error
messages) as **P0**. The adversary is not a random skid — they may have
shared accounts/devices in the past, know the target's writing style,
posting habits, and social graph.

**Axis 2 — abuse.** Harassment via block bypass, follow griefing, report
flooding, DM intrusion (IDOR into private convos), moderation evasion
(posting identifying info about a third party — the ex). Even if no
deanon happens, abuse vectors that target one user are **P1**.

### Features deliberately NOT built (do not propose them)

The brand wedge depends on excluding features that work elsewhere:
- **No "days since the breakup" counter.** Some days you don't want
  to count.
- **No matching/dating.** This is not a dating app.
- **No follower-count flexing.** Counts are hidden by default.
- **No "follower-count badges" or "verified" markers.**

If an audit finding implies adding any of the above, flag it as
non-actionable and explain why.

---

## 2. Where the code lives

Repo root: `~/Desktop/toska` (macOS, local disk; this is on the user's
machine, not a remote).

| Area | Path |
|---|---|
| iOS app (SwiftUI) | `toska/*.swift` |
| iOS UI tests | `toskaUITests/` |
| Cloud Functions v2 (Node.js) | `functions/index.js` |
| Cloud Functions helper modules | `functions/moderation.js`, `functions/cleanup.js`, `functions/scrubLegacyPII.js` |
| Firebase security rules | `firestore.rules` |
| Firestore indexes | `firestore.indexes.json` |
| Rules unit tests | `firestore-tests/firestore.test.js` |
| Moderation tests | `firestore-tests/moderation.test.js` |
| E2E smoke test | `firestore-tests/e2e-test.mjs` |
| Operational runbook | `RUNBOOK.md` |
| App Store metadata draft | `APP_STORE_METADATA.md` (uncommitted, may not exist) |
| CI workflow | `.github/workflows/ci.yml` |
| Admin dashboard | `docs/admin.html` |
| Marketing site | `docs/index.html` etc. |
| Xcode project | `toska.xcodeproj/` |
| Firebase project config | `firebase.json`, `.firebaserc` |

---

## 3. Tech stack details an auditor must know

- **iOS**: SwiftUI, iOS deployment target see `toska.xcodeproj/project.pbxproj`. Bundle ID `com.toskaapp.toska`. Apple Team ID `4V9EFWWZ4Q`.
- **Auth**: Firebase Auth — Apple, Google, and email/password. Sign in with Apple is required (Apple's rule when you offer ANY third-party SSO).
- **Backend**: Firebase
  - Auth, Firestore, Cloud Functions v2 (us-central1), App Check (App Attest on real device, debug provider on simulator), FCM, Crashlytics, Performance.
  - Two projects: `toska-4ebf4` (prod) and `toskastaging`. Debug builds talk to staging; Release archives talk to prod. The strip is enforced by a build-phase script that removes `GoogleService-Info-Staging.plist` from Release archives (commit `84992d6`).
- **CI/CD**: `.github/workflows/ci.yml` auto-deploys `firestore.rules` to staging on merge to main via Workload Identity Federation. Functions and indexes are manual.
- **Admin tooling**: `docs/admin.html` — moderation queue UI, written as plain HTML/JS, served from GitHub Pages at `https://www.toskaapp.com/admin.html`. Rules require `/admins/{uid}` presence to read `/reports`.

### Two Firebase projects — DO NOT confuse them

| | Prod | Staging |
|---|---|---|
| Project ID | `toska-4ebf4` | `toskastaging` |
| Project number | `183467627187` | `260913424323` |
| `.firebaserc` alias | `prod` | `staging` |
| iOS Debug build → | NO | YES |
| iOS Release build → | YES | NO |
| Auto-deploys via CI | NO | rules only |

Always pass `--project prod` or `--project staging` explicitly to
`firebase` commands. Always set `GCLOUD_PROJECT=<id>` explicitly when
running `node scrubLegacyPII.js` or any `firebase-admin` script. Never
let auto-detection pick.

---

## 4. Audit history (what has been done — do not redo unless re-verifying)

The following work is committed to `main` and deployed to both staging
and prod as of the most recent audit pass. Treat findings already in
this list as already-addressed; if you encounter the same shape again,
verify the fix is intact rather than re-flagging.

### Pre-submission audit (2026-05-01, doc: `PRE_SUBMISSION_REVIEW_2026_05_01.md` if it exists)

Multiple correctness/UX fixes — see git log filtered on `pre-submission`,
`hardening`, `audit`. Load-bearing items:
- Counter trigger atomicity (`claimedTransaction` + `retry: true` on
  multi-write counter triggers; `5ac2473`)
- Cascade hardening on `onUserDocDeleted` (`8b9923c`, `a2d73ec`,
  `5ac2473`)
- Conversation block-on-create rule (`8b9923c`)
- Notification `fromHandle` pinning (`8b9923c`)
- Reflections privacy lockdown (`a2d73ec`)
- Feeling-circle update-rule fix (`99cdfd4`)

### Security audit (2026-05-06, four commits on main)

| Commit | Tier | Scope |
|---|---|---|
| `6ea9f30` | A | Rules + rules-tests: user-doc read tightening (P0 legacy PII + P1 block-aware), notifications `hasOnly` schema lockdown, posts/replies/messages `createdAt == request.time` pin, conversation `lastMessage` bundling, reflection author-only, +44 new tests. |
| `8f14379` | B | Cloud Functions: push payload privacy (handle removed from title/body), per-target report rate limit, `cleanupRepliesForUid` + paginated convo cascade + symmetric resume-on-error, moderation evasion (bidi strip + math-alpha fold), structured `counter_drift` logging, moderation timing jitter, rate-limit endpoint allow-list. +12 moderation tests, +1 firestore index. |
| `5919560` | C | iOS: surfaced FeelingCircle silent failures, OnboardingView rollback, ConversationView block-race notification guard, like double-tap in-flight guard, `Telemetry.redactPII`, mirrored server-side moderation evasion fixes. |
| `ed36d29` | D | RUNBOOK +196 lines: pre-deploy legacy-PII scrub sequencing, alerts to wire (counter_drift, report_target_flood, 24h SLA), console-level security settings checklist (Firebase / GCP / GitHub / iOS-Apple), known accepted gaps. |

### Deferred items (intentional — do not re-flag without justification)

- **`giphyProxy` `onCall` migration** — current `onRequest` impl manually
  verifies App Check + Auth + rate limit. Migration is hardening only and
  pairs with an iOS change. RUNBOOK Known accepted gaps.
- **RTL-reversed name evasion** in moderation detector. Strip closes
  display-time confusion; underlying name match doesn't reverse codepoints
  either way.
- **`recordPolicyAcceptance` fire-and-forget**. ContentView re-prompts
  on next launch when `acceptedPolicyVersion < currentPolicyVersion`.
- **`Telemetry.redactPII` is conservative-not-perfect**. Catches email /
  handle / uid / phone but not custom-format identifiers. Forcing function
  for callsites; not a guarantee.
- **Single-write counter triggers still claim-then-write**. Tier B added
  structured `counter_drift` logging instead. Architectural fix to
  migrate to `claimedTransaction + retry: true` is bigger and deferred.
- **24h SLA `reports_aged_24h` alert** — recipe in RUNBOOK; needs a new
  scheduled Cloud Function. Not yet wired.

---

## 5. How to verify (exact commands)

### Build the iOS app (catches Swift compile errors)

```sh
cd ~/Desktop/toska
xcodebuild -scheme toska -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`. Build time: 2-5 minutes cold.

`SourceKit` will repeatedly emit "No such module 'FirebaseAuth'" on
edited files — these are stale-index artifacts, NOT real errors.
`xcodebuild` is the truth.

### Run rules tests (Firestore emulator)

```sh
cd ~/Desktop/toska/firestore-tests
npm test
```

Expected: `112 passing` (as of 2026-05-06). Any failure = regression
in `firestore.rules`.

### Run moderation tests (pure-JS, no emulator)

```sh
cd ~/Desktop/toska/firestore-tests
PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" npx mocha --timeout 5000 moderation.test.js
```

Expected: `86 passing`. Failure = identifying-info detector regression.

### Syntax check Cloud Functions

```sh
cd ~/Desktop/toska
node --check functions/index.js
node --check functions/moderation.js
node --check functions/scrubLegacyPII.js
node --check functions/cleanup.js
```

Each must print nothing on success. Any error = syntax break.

### Verify Firestore index file is well-formed

```sh
cd ~/Desktop/toska
python3 -c "import json; json.load(open('firestore.indexes.json'))"
```

### Read recent commits

```sh
cd ~/Desktop/toska
git log --oneline -30
```

Skim the last ~25. Anything in the last 7 days has not yet had an
observation window in production.

---

## 6. Audit categories — for each, the auditor MUST exhaustively walk

### A. Functional correctness — every user-facing surface

For each surface listed below, trace the code path end-to-end:
SwiftUI view → Firebase write/callable → rule clause → Cloud Function
trigger (if any) → resulting state. Output: golden-path verdict
(VERIFIED / SUSPECT / BROKEN) plus 2-4 edge cases.

**Surfaces:**

1. **Account create** — `CreateAccountView.swift`, `AppleSignInHelper.swift`.
   Apple, Google, email/password. Each provider must result in a clean
   user doc + private subcollection write + age gate.
2. **Onboarding** — `OnboardingView.swift`. Age gate, breakup-stage
   selection, mood capture, first-post compose. The `finishOnboarding`
   helper added in commit `5919560` awaits writes — verify it is correctly
   wired at all skip-flow callsites.
3. **Confirm-adult callable** — `confirmAdult` in `functions/index.js`
   plus iOS callsites in `ToskaTheme.swift::confirmAdultServerSide`.
4. **Posting** — `ComposeView.swift` post path; drafts subcollection.
5. **Feed** — `FeedView.swift`, `FeedViewModel.swift`. Scoring, blocked-
   author filter (client-side only by design — Toska feed is public),
   breakupStage personalization.
6. **Likes** — `PostInteractionManager.toggleLike`. In-flight guard
   added in commit `5919560`. Verify rollback semantics.
7. **Reposts** — `PostInteractionManager.repost`. Verify
   `validatePost`'s repost forgery check rejects mismatched
   `originalAuthorId` / `text`.
8. **Replies** — `PostDetailView.postReplyNow`. Schema lockdown added
   in `6ea9f30`.
9. **Reflections** — `AnniversaryCardView.swift`. Author-only create
   added in `6ea9f30`.
10. **Following** — `OtherProfileView.swift`. Block enforcement on
    follower mirror create.
11. **Notifications** — `NotificationsView.swift` (read), notification
    create call sites in `PostInteractionManager`, `ConversationView`,
    `OtherProfileView`. Schema lockdown added in `6ea9f30`.
12. **Messaging** — `MessagesListView.swift`, `ConversationView.swift`.
    Phantom-convo close (8b9923c), per-uid map slot guards on
    `messageCount`/`typing`/`typingAt`/`lastRead`/`participantHandles`,
    `lastMessage` bundled with caller's `messageCount` increment
    (6ea9f30), block-race notification guard (5919560), 5-message-per-
    user cap.
13. **Profile** — `ProfileView.swift`, `OtherProfileView.swift`. Public
    projection only (handle, *Count, allowSharing, showFollowerCount,
    restricted). The non-owner read rule denies if blocked or if legacy
    PII present.
14. **Settings** — `SettingsView.swift`. Account delete dance (write
    `pendingDeletions`, then `Auth.currentUser?.delete()`), block-list
    management, link-backup-auth flow.
15. **Explore** — `ExploreView.swift`. Stage chips, tag aggregates,
    `meta/tagCounts` and `meta/breakupStageCounts`.
16. **Drafts** — `DraftsView.swift`, `ComposeView.swift` editing path.
17. **Feeling Circles** — `FeelingCircleView.swift`. Two-branch join
    (existence check + setData / arrayUnion), error UI added in
    `5919560`.
18. **Daily Moment** — `DailyMomentView.swift` (if present).
19. **Last Thing Said** — `LastThingSaidView.swift` (if present).
20. **Account deletion** — `SettingsView.deleteAccount`,
    `onUserDocDeleted` cascade, `runWithResume` wrapper, every cleanup
    helper (notifications, replies, reposts, reflections, follows,
    convos, circle messages, submitted reports, sub_*).

### B. Security — by attack category

Re-walk the security audit categories with a fresh eye. Do not assume
the prior pass found everything. Specifically:

#### B1. Firestore rules bypass

For every `match` block in `firestore.rules`:
- Schema lockdown completeness (`keys().hasOnly([...])`)
- `||` short-circuits — does the cheaper branch let through writes the
  expensive branch should deny?
- List query rules — for collection-group queries, verify the per-doc
  rule is restrictive enough that an enumerative attacker gets nothing
- `get()` / `exists()` cost amplification surfaces
- `request.time` pinning on every `createdAt` (drafts, circles, reports,
  posts, replies, messages, reflections, notifications all should pin)
- `request.auth.token.<claim>` abuse — only `request.auth.uid` is
  trustworthy; custom claims (`admin`) come from the `/admins` collection
  via `isAdmin()` predicate
- Conversation block-on-create — try every shape (size 1, size 3,
  ordering [victim, attacker], the `!exists` check on a deleted-but-
  blocked-subdoc-lingers user)
- Notification `fromHandle` pinning bypasses (omission, type confusion,
  Cyrillic/fullwidth confusable of a real handle, cross-user notifId)
- `/users/{uid}/private/{docId}` owner-only at every level including
  collection-group
- `/processedTriggerEvents` deny-all-client
- `/meta/{docId}` read-only for clients; verify aggregates don't leak
  per-user data via low-cardinality counts
- `/feelingCircles` create + update lockdown
- `/reports/{reportId}` reads admin-only; targets cannot read reports
  filed against them
- `/pendingDeletions/{uid}` create only by `isOwner(uid)`

#### B2. Cloud Functions trust boundaries

For every `onCall` callable + `onRequest` HTTP endpoint + Firestore
trigger in `functions/index.js`:
- Auth verified? App Check enforced (callable: `enforceAppCheck: true`;
  onRequest: manual `getAppCheck().verifyToken()`)?
- Argument validation: type, length, shape (no extra fields)?
- Failure-mode analysis: does the error message leak server state? Does
  it leak a uid/handle/email of another user?
- Triggers reading `event.data.data().authorId` and writing to
  `users/{authorId}/...` — can a client forge `authorId`?
- `claimedTransaction` + `retry: true` — verify the four counter
  triggers (`onLike{Created,Deleted}UpdateCounts`,
  `onFollow{Created,Deleted}UpdateCounts`) re-throw on commit failure
  AND have `retry: true` set in options form. The 5ac2473 commit was
  the fix for both.
- Single-write counter triggers (`onReply{Created,Deleted}UpdateCount`,
  `onRepost{Created,Deleted}UpdateCount`,
  `onPost{Created,Deleted}UpdateTagCounts`, `onBreakupStageChanged`,
  `onMessageCreatedUpdateCount`) — each should now call
  `logCounterDrift()` on caught error (added in 8f14379).
- Rate-limit doc keys at `rateLimits/{uid}_{endpoint}` — `endpoint`
  string must be in `RATE_LIMIT_ALLOWED_ENDPOINTS` (added in 8f14379);
  unknown endpoint must throw.
- `sendPushNotification` payload — confirm `${fromHandle}` is NOT in
  the title or body for any push type (verified in 8f14379). Confirm
  user-authored content (post text, message text, reply text) never
  appears in the push payload.
- Admin SDK usage — confirm no callable returns Admin-readable data
  to a non-admin caller.
- `monitorPendingDeletions` / `resumeUserCleanup` / scheduled functions
  — auth boundary (cron-only), can a forged client write trigger them
  against another uid?
- `onUserDocDeleted` cascade — every helper now goes through
  `runWithResume`. Verify all eight cleanup paths queue resume on both
  capHit AND error: convos, notifications, replies, reposts, reflections,
  circle messages, submitted reports, follows, plus sub_* (saved/liked/
  notifications/blocked/presence/private/drafts).

#### B3. Auth & account identity

- Anonymous sign-in unused (verify: `grep signInAnonymously toska/`).
- Sign in with Apple "Hide My Email" / private relay — verify email
  claim is stored only in `users/{uid}/private/data`, not in a
  queryable index.
- Handle uniqueness race — `generateUniqueHandle` should use a Firestore
  transaction or accept the rare collision; collision is non-fatal
  (handles are mutable, fungible).
- Handle reuse on account delete — `cleanupRepostsForUid` deletes
  reposts (so byline doesn't survive), `cleanupRepliesForUid` deletes
  replies (added in 8f14379). Verify both paths delete, not just
  rewrite-byline.
- `confirmedAdult` — server-only. Rule denies client writes to the
  field (`firestore.rules:170`). Confirm no iOS code writes
  `confirmedAdult` directly: `grep confirmedAdult toska/*.swift` should
  show only reads.

#### B4. Deanonymization

- **Push notification payloads** — `sendPushNotification` in
  `functions/index.js` around line 700. Verify title and body do NOT
  include `fromHandle` (the 8f14379 commit removed it). Verify post/
  reply/message text is NEVER in the payload (existing comment block
  documents this — verify it's still true).
- **Crashlytics** — `Crashlytics.crashlytics().setUserID(...)` should
  NOT be called anywhere. Verify: `grep setUserID toska/`.
- **`Telemetry.recordError`** — `ToskaTheme.swift::Telemetry.redactPII`
  should pre-scrub both context and `error.localizedDescription`
  (added in 5919560). Verify regex set covers email / @handle / uid-
  shaped / phone.
- **FCM token storage** — should live at `users/{uid}/private/data`
  (`fcmToken` field). Rule on `/private/{docId}` is owner-only.
  `sendPushNotification` reads from private first, falls back to legacy
  main-doc field.
- **Error messages returned to the client** — review every callable's
  error path; no message should include another user's identifier.
- **Timing oracles** — every rule with `exists()` against a path the
  caller controls is a potential timing oracle. Documented as P2 in
  the security audit; not closed for v1 (would need callable-with-
  fixed-latency wrapping). Re-flag only if the threat surface
  materially expands.
- **`containsNameOrIdentifyingInfo` timing** — `validatePost` and
  `validateReply` apply `moderationDeleteJitter()` (1500-3000ms random)
  before deleting name-flagged posts (added in 8f14379). Verify the
  jitter is on the name-detection branch only, not the blank/over-
  length paths.
- **Sign in with Apple Hide My Email** — verify the relay email is
  treated as an opaque identifier; the iOS code should not assume
  it matches the user's "real" email.

#### B5. Block / report / moderation

For every place that should respect a block (rule + function +
SwiftUI), verify the check exists. Surfaces:
- Repost a blocker's post (rule: `firestore.rules` posts create)
- Reply to a blocker's post (rule: replies create)
- Like a blocker's post (rule: likes create)
- Reflect on a blocker's post (rule: reflections create)
- Follow the blocker (rule: followers create)
- Notification to a blocker (rule: notifications create — every type
  branch has explicit `!exists(blocked)`)
- Profile read (rule: users read — added 6ea9f30)
- DM create (convo create — 8b9923c)
- DM message create (existing convo — explicit `!exists(blocked)`)
- Feed (client-side only by design; not a security gate, just UX)

For moderation evasion in `containsNameOrIdentifyingInfo`:
- All evasion vectors covered in `firestore-tests/moderation.test.js`
  (Cyrillic, fullwidth, leet, separator collapse, last names, dotted
  initials, apartment numbers, social URLs, bidi-strip, math alphas)
  — confirm tests still pass.
- New evasion classes not yet covered? Try: punycode IDN domains
  ("pаypаl.com"), zalgo combining-mark stacks, NFKD edge cases,
  emoji-substitution names ("J🅾HN"), regional indicator pairs.

For report flooding:
- Per-reporter cap (20/hour) — `rateLimitReports` in
  `functions/index.js`.
- Per-target cap (10/hour) — added in 8f14379. Verify the index
  `reports/(reportedUserId ASC, createdAt DESC)` exists in
  `firestore.indexes.json`.
- Auto-restrict from report count? No — only `checkRepeatOffenderPosts`
  acts on server-detected `flagged: true`. Verify this is still true
  (otherwise reports become a harassment tool).

#### B6. IDOR / data exposure

- Predictable doc IDs: `posts/{auto}` ✓, `users/{uid}` (uid is the
  identifier), `notifications/{auto}` ✓, `reposts` use deterministic
  `{uid}_repost_{postId}`, `feelingCircles/{circleId}` use `{tag}_{date}`.
  Verify no rule reads expose enumeration.
- `reflections` collection-group query by `authorId` — per-doc rule
  denies cross-user. The `firestore-tests` should confirm this; if
  Firestore semantics ever change, add a `match /{path=**}/reflections`
  deny-all as belt-and-braces.
- `MessagesListView` queries `participants array-contains uid` — the
  rule's `read` check requires `request.auth.uid in resource.data.participants`,
  enforced per-doc.
- `notifications` are under `users/{uid}/notifications` — owner-only
  read.
- `reports` — admin-only read.

#### B7. Race conditions

- Concurrent like/unlike — covered by `claimedTransaction` + retry: true.
- Account delete mid-action — `onUserDocDeleted` cascade is
  idempotent; admin-SDK writes against a missing user doc no-op.
- `confirmedAdult` flip race — rule snapshots are isolated; rule
  evaluation sees a consistent snapshot at write time.
- Block-then-message race — message rule evaluates `!exists(blocked)`
  at write time; ConversationView added an async block re-check
  before notification write (5919560) for defense-in-depth.

#### B8. App Check & transport

- `AppCheck.setAppCheckProviderFactory` in `toskaApp.swift` — App Attest
  for Release, debug provider for Debug.
- Every `onCall` should have `enforceAppCheck: true`.
- `giphyProxy` and `reconcileMyCounts` are `onRequest` — manual
  `getAppCheck().verifyToken()` + `getAuth().verifyIdToken()`. Verify
  the chain isn't bypassable.
- Debug token registration: documented in RUNBOOK. No debug token
  should be committed to the repo (`grep FIRAAppCheckDebugToken`,
  `grep "debug token"`, search for hex tokens).

#### B9. CI/CD & supply chain

- `.github/workflows/ci.yml` — verify the WIF-authed staging-rules-deploy
  job uses `push` (not `pull_request_target`) for privileged steps.
- `functions/package.json` and `package-lock.json` — spot-check
  dependencies for typosquats. Versions should be pinned.
- iOS Swift Package dependencies (`Package.resolved` if present, or
  `toska.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`).
- Branch protection on `main` — cannot verify from repo; flag in
  out-of-scope.

#### B10. Secrets & config

- `grep -r "AIza" .` — Firebase API keys in `GoogleService-Info.plist`
  are public client keys; expected. Service-account JSON keys would
  contain `"private_key"` — must NOT be in repo.
- `grep -r "BEGIN PRIVATE KEY" .` — must return nothing.
- `grep -r "service_account" .` — should only appear in code references,
  not actual keys.
- `.env` files anywhere — should be gitignored.
- Info.plist — no embedded credentials.
- Two `GoogleService-Info-*.plist` files; the staging one must be
  stripped from Release archives via the build-phase script (commit
  `84992d6`).

### C. Privacy disclosures match the binary

Critical for App Store submission. Walk `APP_STORE_METADATA.md`
section 8 ("App Privacy") and verify every claim against the actual
binary:

- Email collection — only via Firebase Auth providers; storage is
  `users/{uid}/private/data`. Not used for tracking.
- User content — posts/replies/messages/reflections all live in
  Firestore.
- User ID — Firebase Auth uid is the linking identifier across the
  data model. Verify Crashlytics does NOT auto-attach this (no
  `setUserID` call).
- Device ID — FCM token + App Check token. FCM token in private/data.
- Crash data — Crashlytics. Linked to user: NO unless `setUserID` is
  called.
- Performance data — Firebase Performance. Auto-collects without uid.
- Location — should NOT be collected. Verify: `grep CLLocationManager toska/`.
- Photos — only if compose allows attaching. Verify ComposeView.
- Tracking — should be NONE. Verify: `grep ATTrackingManager toska/`,
  `grep NSUserTracking toska/Info.plist`. If either appears, the
  binary IS asking for tracking permission and the privacy nutrition
  labels MUST disclose it.

### D. App Store compliance (legal / process)

Verify each is honest in `APP_STORE_METADATA.md`:
- Age rating: 17+ (User-Generated Content forces 17+ regardless of
  other answers). Cannot be lower.
- Encryption: standard HTTPS only; Info.plist should have
  `ITSAppUsesNonExemptEncryption = NO`.
- Demo account credentials present; review notes specific.
- Sign in with Apple offered (Apple's rule when offering Google SSO).
- Content rights — GIPHY usage acknowledged.
- Support URL, Marketing URL, Privacy Policy URL all reachable (not
  verifiable from repo; flag in out-of-scope).

### E. Stability — crashes, error handling, race conditions

For each iOS view that does Firebase writes:
- Are errors surfaced to the user, or silently swallowed via `try?`
  or `Telemetry.recordError`-only? The 5919560 commit fixed
  FeelingCircleView and OnboardingView; verify other views don't have
  the same shape (silent fail with no UI feedback).
- Are optimistic updates rolled back on failure?
- Is auth-session-expiry handled (the `Auth.auth().currentUser` check
  before optimistic update)?

For Cloud Functions:
- Every `onDocumentCreated/Updated/Deleted/Written` trigger handles
  the case where the doc was already deleted (via Admin SDK; updates
  to missing docs no-op).
- Long-running paginated helpers respect their `maxIterations` cap
  and queue resume on capHit.

### F. Performance — slow paths, unbounded queries, cost amplification

- Every Firestore query in iOS or Cloud Functions has either a
  `.limit(N)` clause or paginates via cursor.
- The `cleanupUserConversationsForUid` paginates at 50/page (added in
  8f14379). Confirm the inline `.where(participants array-contains
  uid).get()` shape is gone from `onUserDocDeleted`.
- Cloud Functions retry policy is bounded — `retry: true` on the four
  counter triggers, not on all triggers.
- Rate limits on every `onRequest` and `onCall` write surface.

### G. Data integrity — migrations, schema consistency

- `users/{uid}` legacy PII migration to `users/{uid}/private/data`.
  The `legacyPIIFieldsImmutable()` rule predicate denies write-side
  re-introduction. The `noLegacyPIIVisible()` predicate denies non-
  owner reads when legacy fields are still present. The
  `scrubLegacyPII.js` script cleans the long tail.
- Counter accuracy under load — multi-write counters use
  `claimedTransaction`; single-write counters use `claimTriggerEvent`
  + structured drift logging.
- Conversation `messageCount` per-uid map slot guards on the update
  rule.

### H. Moderation pipeline

End-to-end:
1. Client compose → server-side `containsNameOrIdentifyingInfo`
   (mirror of iOS detector) in `functions/moderation.js`
2. `validatePost` / `validateReply` runs on every create; deletes
   blank / over-length / name-containing / mismatched-repost content
   before any reader sees it
3. `onPostCreated` / `onReplyCreatedModerate` / `onMessageCreatedModerate`
   re-run moderation, soft-flag PII/spam/links, hard-delete hate/
   harassment/threat/sexual
4. `onPostUpdated` / `onReplyUpdated` re-run moderation on edits;
   hard-delete name-containing edits
5. `checkRepeatOffenderPosts` auto-restricts at 5 flagged posts in 7
   days; idempotent (skip if already restricted)
6. User report → `/reports/{auto}` doc create → `rateLimitReports`
   (per-reporter + per-target) → `notifyAdminsOfNewReport` Cloud
   Logging alert → admin reviews via `docs/admin.html` →
   `auditReportResolution` writes audit log entry

### I. Operational readiness

- RUNBOOK.md covers every incident scenario (rules rollback, functions
  rollback, stuck pending deletions, App Check enforcement disabled).
- Active alerts include sendPushNotification / onUserDocDeleted /
  validatePost error rate.
- Console-level security settings (RUNBOOK section) are checked off
  for prod (cannot verify from repo; flag).
- `counter_drift` alert policy wired (cannot verify from repo; flag
  in out-of-scope).
- `report_target_flood` alert policy wired (same).
- 24h SLA `reports_aged_24h` alert policy wired (same; recipe in
  RUNBOOK).

### J. Things only a real device can verify (must surface as
"unverified, requires manual QA")

- App Attest end-to-end on a real iPhone (the simulator path uses the
  debug provider — known different code path).
- APNs push delivery for every notification type (reply/like/follow/
  repost/save/message/milestone). The push payload privacy fix in
  8f14379 needs lock-screen verification.
- Sign in with Apple flow including Hide My Email and re-sign-in
  with rotated relay email.
- Image picker / GIF picker / camera permission prompts in ComposeView.
- Haptics on like/repost/match-style interactions.
- Pasteboard handling (privacy: don't auto-paste from clipboard).
- Deep links (notification tap → correct view; conversation push →
  ConversationView with right convoId).
- Biometric auth if SettingsView uses it for delete confirmation.
- VoiceOver / Dynamic Type on FeedView, ComposeView, NotificationsView,
  ConversationView.
- Background fetch / FCM token rotation after a delete-and-recreate-
  account flow.
- Multi-device messageCount sync.
- Phantom-convo regression test (verify the 8b9923c fix holds live).
- Feeling-circle second-joiner regression (verify the 99cdfd4 fix holds).

---

## 7. Output format

Per finding:

```
**Title** — one-line description
**Location** — file:line(s)
**Severity** — P0 (deanonymization, account takeover, mass-data
  exposure) / P1 (single-user-targeted exploit, persistent state
  corruption) / P2 (abuse vector, denial of service, escalates other
  findings) / P3 (defense-in-depth gap)
**Exploitability** — trivial / requires-tooling / requires-insider /
  theoretical
**PoC** — concrete attacker steps. If expressible as a Firestore
  rules-test snippet, do so.
**Impact** — what the attacker actually gets. Specifically state
  whether deanonymization is reachable.
**Fix sketch** — one or two sentences. Don't write code unless the
  user explicitly asks.
```

Then sections:

- **Findings I am UNCERTAIN about** — list things you couldn't fully
  trace, with the exact next read/test that would resolve.
- **Out of scope but flag** — operational/process gaps that aren't
  code (console settings, branch protection, IAM scope).
- **Manual QA on real device** — list everything from category J
  that must be walked.
- **Pre-submission go/no-go recommendation** — explicit. "Go" requires
  every category VERIFIED or accepted-with-rationale. "No-go" if any
  P0 or P1 is open.

---

## 8. Constraints

- **Do not modify code.** Do not deploy. Do not push. The auditor's
  job is to find issues, not fix them. Code changes are a separate
  pass.
- **Do not run live destructive operations.** Static analysis +
  emulator only.
- **Do not paste code to third-party services.** This is a confidential
  audit.
- **Use the Explore agent for broad searches.** Cite findings with
  file:line. Read `firestore-tests/firestore.test.js` and
  `firestore-tests/moderation.test.js` BEFORE flagging "uncovered" —
  don't re-flag a gap that's already pinned.
- **Cap report at 3000 words, severity-ordered (P0 first).** Be
  exhaustive on what's in scope, but tight; the value is in the
  specific findings, not the cataloging.
- **Push back hard.** The failure mode of this audit is rubber-
  stamping. If you cannot find a P0 or P1, re-check the
  deanonymization category specifically — the threat surface is broad
  and the bias should be toward "here's something I'm not certain
  about" rather than "looks fine."

---

## 9. Glossary (Toska-specific terms)

- **Stage** — breakup-recency stage. One of seven values:
  "it just happened" / "a few weeks in" / "months in" / "a year or
  more" / "still in it" / "they left" / "i left". Used for
  personalization. Stored in `users/{uid}/private/data.breakupStage`.
- **Reflection** — text the post author writes on their own anniversary
  card (a year-later return to the post). Lives at
  `posts/{postId}/reflections/{authorUid}`. Author-only writeable.
- **Feeling circle** — temporary group chat keyed by tag + date that
  dissolves at midnight. `feelingCircles/{tag}_{date}`.
- **Repost** — top-level `posts` doc with `isRepost: true` and
  `originalPostId` / `originalAuthorId` / `originalHandle` fields.
- **Drafts** — pre-publish text stored at `users/{uid}/drafts/{auto}`.
  Owner-only at every layer. Designed for "still in it" users.
- **Last Thing Said** — feature TBD; check `LastThingSaidView.swift`.
- **Daily Moment** — server-curated daily prompt; check
  `DailyMomentView.swift` and `dailyMoment` Firestore collection.
- **Restricted user** — a user the moderation pipeline auto-flagged
  (`restricted: true`, `restrictedUntil` for system; no expiry for
  admin). Cannot post/reply/message until expiry. Enforced by the
  `notRestricted()` rule predicate.
- **Adult-confirmed** — `confirmedAdult: true` on user doc. Set only
  via the `confirmAdult` Cloud Function (Admin SDK). Required to
  post/reply/DM (the `hasConfirmedAdult()` rule predicate).
- **App Check** — Firebase's attestation layer. App Attest on real
  device; debug provider on simulator (known different code path,
  documented in RUNBOOK simulator gotcha).
- **Toska Alerts** — Cloud Monitoring notification channel ID
  `projects/toska-4ebf4/notificationChannels/17038690850716525077`.
  Routes to `salte@saltedevelopments.com`.

---

## 10. The bar

The audit is "complete" when you can answer this question with a
direct yes or no, no hedging:

> **Can this app be submitted to App Store Review today, given that
> the manual-QA list (category J) goes clean?**

If yes, list the conditions. If no, name the open P0/P1 finding.
Anything in between — "mostly yes but I couldn't trace X" — must
appear in section "Findings I am UNCERTAIN about" with the exact
next read.

---

End of spec. The auditor's first action should be `git log --oneline -30`
to see the most-recent state of the world, then proceed through
section 6 in order.
