# Toska — Comprehensive Pre-Submission Audit Brief

**For:** a fresh Claude Code session, run from `~/Desktop/toska`, no prior context.
**Date written:** 2026-05-13.
**Supersedes:** `PRE_SUBMISSION_AUDIT_SPEC.md` for this run. Read that as historical context only.
**Bar:** Toska is shipping to the App Store as a v1.0 anonymous UGC app handling vulnerable mental-health-adjacent content. The auditor's job is to find every bug, security hole, edge case, and cross-surface interaction failure before Apple, real users, and a motivated stalker do.

**Read this entire document end-to-end BEFORE running any tool calls. Do not skim.** This brief is dense on purpose; the audit will fail to find what it should if you start cold and pattern-match.

---

## 0. Mission

For every surface in the app, answer six questions:

1. **Does it work?** Code-and-rules layer correctness, verifiable without a device.
2. **Is it safe?** Under the Toska-specific threat model (anonymity-first; adversary is a motivated stalker who knows their target uses the app and wants to deanonymize, follow, contact, or harass them).
3. **Is it stable?** No crashes, no silent failures, no race conditions that strand state, no unbounded queries.
4. **Is it humane?** Does the moderation pipeline actually catch and remove harmful content within the 24h SLA the app advertises?
5. **Does it match its claims?** Privacy nutrition labels vs binary behavior; Terms-of-Service guarantees vs server-side enforcement; admin tooling vs the moderation contract.
6. **Is it submission-ready?** Apple's reviewer should not find anything you missed.

If any answer is "no" or "unverifiable from this position," **flag it explicitly**. The failure mode of this audit is rubber-stamping. Err toward "I cannot verify X without a real device" over "X looks fine."

Do NOT propose fixes. Findings only. The owner decides what to fix.

---

## 1. What Toska is

Anonymous breakup-talk iOS app. "Reddit, but only for breakups." SwiftUI front-end, Firebase backend (Firestore + Auth + Cloud Functions + FCM + App Check via App Attest). Marketing site at `https://www.toskaapp.com` (static, served from `docs/` via GitHub Pages). Admin dashboard at `https://www.toskaapp.com/admin.html`.

### The brand wedge

Anonymity. Every account gets a randomly-generated two-word-plus-number handle (`soft_evening_42`). No real names. No photos. No bios. No follower count visible by default. The differentiator from every other social app is that nobody can find you.

### The threat model

Two axes:

**Axis A — Anonymity break.** A motivated stalker (ex-partner, family member, abusive contact) knows the user uses Toska. They want any signal that lets them identify the user's handle, see their posts, or contact them. Anything that lets the stalker confirm "X uses Toska," correlate two posts to the same uid, deanonymize via metadata, or receive a push notification meant for X is a serious finding.

**Axis B — Content safety.** Toska is mental-health-adjacent. Users post vulnerable content during breakups. Harmful content includes: harassment, doxxing of ex-partners (real names, addresses), sexual content involving minors, self-harm instructions, content targeting protected classes. Apple's review takes UGC moderation extremely seriously for the 17+ rating; the app advertises a 24-hour moderation SLA and four UGC pillars (pre-publish filter, in-app report, in-app block, admin tooling) that must hold.

### Architecture (text diagram)

```
iOS Client (SwiftUI)
  ├── FirebaseAuth (Apple SSO / Google SSO / email-password)
  ├── Firestore SDK (direct reads + writes, gated by firestore.rules)
  ├── Firebase Functions SDK (callable + onRequest endpoints)
  ├── FirebaseMessaging (FCM push token, deep-link handling)
  ├── FirebaseAppCheck (App Attest in Release, debug token in Debug)
  ├── FirebaseAnalytics (Telemetry namespace, bounded event vocabulary)
  └── FirebaseCrashlytics (no setUserID — privacy contract)

Firebase Backend
  ├── Firestore (data tier)
  │     posts, replies, conversations, messages, feelingCircles,
  │     users/{uid}/private (FCM token, settings), users/{uid}/blocked,
  │     reports, dailyMoment, finalPosts, pendingDeletions, ...
  ├── Cloud Functions (functions/index.js, ~3188 lines)
  │     callable: confirmAdult, reconcileMyCounts, recordPolicyAcceptance,
  │                giphyProxy, deleteAccount, ...
  │     triggers: onCreate post → moderation, onCreate report → admin notify,
  │                onWrite blocked → cascade, onUpdate user → counter sync, ...
  │     scheduled: cleanup orphans, reap expired posts, reconcile counts
  └── FCM (push delivery; cleanup of stale tokens on invalid-token errors)

Marketing Site (docs/, GitHub Pages, served at toskaapp.com)
  ├── index.html
  ├── privacy.html  — must match PrivacyInfo.xcprivacy + ASC nutrition labels
  ├── terms.html    — must match toskaPolicyBody in ToskaTheme.swift
  └── admin.html    — moderation dashboard (admin-only via custom claim)

Repo also contains:
  ├── firestore.rules                 — 1159 lines, security tier
  ├── firestore.indexes.json          — query index definitions
  ├── firestore-tests/                — 141 Mocha tests via emulator
  └── functions/seedAppStoreDemo.js   — seeds App Store reviewer demo account
```

---

## 2. Surface inventory

Read this to know what exists. Don't audit everything line-by-line; use this to scope.

### iOS Swift (under `toska/`, total ~26K LOC)

| File | LOC | Purpose |
|---|---|---|
| `FeedView.swift` | 2199 | Main feed, scroll, post rendering, witness post, daily moment, explore |
| `ToskaTheme.swift` | 1564 | Theme, colors, age gate, policy acceptance, Telemetry namespace, friendlyAuthErrorMessage, policy body string |
| `SettingsView.swift` | 1396 | Settings, account delete, sign-out, FCM clear, exportData, change email/password |
| `PostDetailView.swift` | 1328 | Single post view, reply threading, likeListener, replyListener |
| `ProfileView.swift` | 1162 | Own profile, followers/following, reconcileCountsIfNeeded |
| `FeedViewModel.swift` | 1126 | Feed query, post scoring, blocked-user filtering, post cache |
| `ComposeView.swift` | 959 | Create post / reply, client-side moderation hint, drafts |
| `ConversationView.swift` | 914 | DM thread, message send, typing indicator, capturedUid recheck pattern |
| `OnboardingView.swift` | 788 | Multi-step onboarding (age gate, policy, breakup stage, handle) |
| `ExploreView.swift` | 729 | Topic-based discovery |
| `NotificationsView.swift` | 630 | In-app notifications inbox (likes, replies, follows, milestones) |
| `OtherProfileView.swift` | 613 | View another user's profile, block, report, message |
| `FeelingCircleView.swift` | 527 | Late-night ephemeral chat circles (dissolve at midnight) |
| `OnboardingView.swift` (already listed) | – | – |
| `ShareCardView.swift` | 814 | Generate exportable post card image |
| `DailyMomentView.swift` | 416 | Once-daily prompt feature |
| `CreateAccountView.swift` | 400 | Email signup path |
| `MainTabView.swift` | 367 | Tab bar, push deep-link routing, onboarding gating |
| `AppleSignInHelper.swift` | 333 | Apple SSO, hidden-email handling |
| `ContentView.swift` | 331 | Auth state gate, policy version bump check |
| `WeeklyRecapView.swift` | 323 | Weekly summary feature |
| `AnniversaryCardView.swift` | 272 | Stage-aware anniversary moments |
| `SplashView.swift` | 274 | Pre-auth landing, sign-in/up entry |
| `LastThingSaidView.swift` | 220 | Final-post feature |
| `MessagesListView.swift` | 252 | DM list, .userBlocked subscription, nav-push to ConversationView |
| `toskaApp.swift` | 214 | App entry, AppCheck init, Firebase configure |
| `PushNotificationManager.swift` | 191 | FCM token save/clear, push routing, cold-launch intent stash |
| `SignInView.swift` | 197 | Email sign-in path |
| `BlockedUsersCache.swift` | 173 | Singleton block-list cache, NSLock-guarded, listener with capturedUid |
| `PostInteractionManager.swift` | 487 | Like/save/follow toggles with optimistic UI + rollback |
| `TopView.swift` | 277 | Top-of-feed ranking |
| `GifPickerView.swift` | 262 | Giphy search proxy + attribution |
| `PostModels.swift` | 111 | Data structs |
| `PasswordResetView.swift` | 141 | Reset flow |
| `LateNightTheme.swift` | 134 | Time-of-day theming |
| `DraftsView.swift` | 146 | Drafts subcollection UI |
| `UserHandleCache.swift` | 120 | Singleton handle cache |
| `FirestoreExtensions.swift` | 107 | isValidFirestoreDocId, getDocumentAsync |
| `NetworkMonitor.swift` | 84 | Connectivity status |
| `OfflineBannerView.swift` | 23 | Offline UI |
| `MessageBubble.swift` | 55 | Single message render |
| `HapticManager.swift` | 58 | Haptics |
| `UserDefaultsKeys.swift` | 47 | Defaults keys (drafts, opt-outs, primer flags) |
| `NotificationNames.swift` | 33 | Notification.Name constants |

### Cloud Functions (`functions/`)

| File | LOC | Purpose |
|---|---|---|
| `index.js` | 3188 | Every callable, onRequest, trigger, scheduled function |
| `moderation.js` | 470 | Identifying-info detector (real names, contact info), evasion-hardened |
| `cleanup.js` | 119 | Dev/test database wipe script (NOT the GDPR-cascade path) |
| `seedAppStoreDemo.js` | 447 | Seeds App Store reviewer demo account + buddy accounts on staging or prod |
| `scrubLegacyPII.js` | 135 | One-shot scrub for legacy PII fields on user docs |

### Other

| Path | Purpose |
|---|---|
| `firestore.rules` (1159 lines) | Security tier; covers all collections + subcollections |
| `firestore.indexes.json` | Composite indexes for the feed, profile, conversation queries |
| `firestore-tests/firestore.test.js` + `moderation.test.js` | 141 emulator-based unit tests |
| `firestore-tests/e2e-test.mjs` | E2E test path |
| `docs/admin.html` (603 lines) | Moderation dashboard — auth via Firebase Auth custom claim; SLA tooling |
| `docs/index.html` + `privacy.html` + `terms.html` | Marketing + legal pages |
| `toska/PrivacyInfo.xcprivacy` | Apple privacy manifest |
| `toska/toska.Release.entitlements` | Release-build capabilities (push prod, App Attest prod, Sign in with Apple, associated domains) |
| `APP_STORE_METADATA.md` | Submission paste-into-ASC source of truth |
| `RUNBOOK.md` | Operational runbook (deploy, rollback, moderation procedures) |
| `PRE_SUBMISSION_REVIEW_2026_05_01.md` | Previous audit report — read for "what was found before" |

---

## 3. Tooling — how to actually verify things

### Run the Firestore rules tests
```
cd ~/Desktop/toska/firestore-tests && PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" npm test
```
141 tests; ~5 seconds. The `PERMISSION_DENIED` log noise is expected — those are negative-path tests.

### Build the iOS app
```
cd ~/Desktop/toska && xcodebuild -scheme toska -configuration Debug -destination 'generic/platform=iOS Simulator' build
```
SourceKit may print `No such module 'FirebaseCore'` etc. — those are cosmetic; the actual build succeeds.

### Syntax-check JS
```
node -c functions/<file>.js
```

### Hit Firebase Identity Platform admin REST API
The CLI is already authenticated as `salte@saltedevelopments.com`. To read Identity Platform config:
```
TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer $TOKEN" \
     -H "X-Goog-User-Project: toska-4ebf4" \
     "https://identitytoolkit.googleapis.com/admin/v2/projects/toska-4ebf4/config"
```
Substitute `toskastaging` for staging.

If the token is stale, `gcloud auth print-access-token` returns "Reauthentication failed" — the user must run `gcloud auth login` interactively. You CAN'T do this for them.

### Wire-level Firebase Auth tests
```
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=<API_KEY>" \
     -H "Content-Type: application/json" \
     -d '{"email":"<email>","password":"<pwd>","returnSecureToken":true}'
```
Web API keys for both projects are public-by-Firebase-design — they're in the Identity Platform admin config response and in `toska/GoogleService-Info*.plist`.

### Static greps you'll want
- PII to logs: `grep -rn --include="*.swift" -E "(print|NSLog|os_log)\([^)]*\b(uid|email|handle|message|postText|password)\b" toska/`
- Crashlytics setUserID: `grep -rn --include="*.swift" "setUserID\|setUserId" toska/`
- Tracking: `grep -rn --include="*.swift" "NSUserTracking\|ATTrackingManager" toska/`
- Hardcoded secrets: `grep -rEn "(api_key|secret|token).*=.*[\"'][a-zA-Z0-9]{20,}" toska/ functions/ --include="*.swift" --include="*.js"`

---

## 4. Prior audit history — DO NOT re-find these

Five audit rounds have already happened. The auditor should READ the closing-commit messages to know what's settled. Don't waste cycles re-discovering.

### 2026-05-01 — first comprehensive pre-submission review
- `PRE_SUBMISSION_REVIEW_2026_05_01.md` — green verdict, ship-it.
- Two HIGH items (24h SLA visibility in admin dashboard, M-1 confirmAdult fire-and-forget); two M-class UX items.
- Followup commits: `86307ef admin: surface 24-hour SLA on report dashboard (H-1)`, `1f8b75b backend: cleanup continuation + new-report alert (M-3, H-1)`, `8ca8e53 ios: pre-submission UX fixes (M-1, M-2, H-2)`.

### 2026-05-06 — security audit RUNBOOK addendum
- Commit `ed36d29`. RUNBOOK gained a "moderation operational" section.

### 2026-05-07 — pre-submission audit findings closed
- Commit `55c38b4` security: close 2026-05-07 pre-submission audit findings.
- Hardenings landed across functions + iOS surfaces.

### 2026-05-08 — second-pair-of-eyes audit
- Commit `ac21653` security: close 2026-05-08 second-pair-of-eyes audit findings.
- Commit `e249323` hardening: close 2026-05-08 deferred-list audit items.
- Closed: report flooding, cleanup symmetry, push payload validation, user-doc read tightening, schema lockdown, counter atomicity, identifying-info detector evasion (`54cf...`), reflections.authorId index, drafts plumbing.

### 2026-05-13 — deep iOS audit (this session)
- Commit `5c6d8b9` — M-1 email enumeration UI collapse, M-2 seeder credentials honesty.
- Commit `7e25d01` — three audit-hardening fixes:
  - `PostDetailView.fetchReplies` now captures uid at listener-creation time + rechecks in snapshot Task.
  - `MessagesListView` subscribes to `.userBlocked` notification, strips blocked rows locally.
  - `PushNotificationManager.clearFCMToken` now calls `Messaging.messaging().deleteToken()` first to invalidate at FCM service level + adds error logging on Firestore wipe.
- Email Enumeration Protection (`emailPrivacyConfig.enableImprovedEmailPrivacy`) verified true on both projects.

**If a finding matches one of these commits, double-check it's actually still present in the current code before reporting. The codebase has changed; a "finding" pulled from a stale read is noise.**

---

## 5. Audit framework

### Severity buckets

| Severity | Definition |
|---|---|
| **CRITICAL** | Anonymity break (any path that leaks identity, handle-to-uid mapping, or content across accounts), auth bypass, prod data corruption, content-moderation bypass that would let Apple reject the app. App is NOT submission-ready until fixed. |
| **HIGH** | Security issue (e.g., DoS, unbounded query, missing App Check, unauth'd callable), a state-machine bug that strands users, a contract violation between two surfaces (e.g., privacy manifest claims X but binary does Y). |
| **MEDIUM** | Race condition under load, listener leak, error-handling gap, UX bug that affects core flow. |
| **LOW** | Defense-in-depth nit, doc inconsistency, fragility-against-future-refactor. |

### Output format (strict)

For each finding:
```
[SEVERITY] file:line — one-sentence what's wrong.
Impact: one-sentence what breaks if exploited or triggered.
```

No fix suggestions. No code snippets in findings unless the finding requires reading 3+ lines to understand. If you can't verify without running the app on a device or hitting live production, say so explicitly under a separate **UNVERIFIABLE** section.

### Anti-patterns the auditor should avoid

- **Confident speculation.** "If the token verification fails silently in an outer try-catch that the auditor hasn't seen..." — that's not a finding; that's a hallucination. If you didn't read the code, don't claim a bug.
- **Re-finding closed items.** The audit history in §4 lists what's been closed. Verify present-state before reporting.
- **Severity inflation.** "Microsecond window" is not CRITICAL. "Defense-in-depth would be nice" is not HIGH. Calibrate.
- **Generic best-practice advice.** "Add more comments" is not an audit finding. Audits surface concrete defects.

---

## 6. Per-surface audits

### 6.1 Firestore rules (`firestore.rules`, 1159 lines)

Focus areas in priority order:

1. **Deny-by-default coverage.** The file ends with `match /{document=**} { allow read, write: if false; }` — verify nothing above accidentally opens a hole. Look for top-level `match /...` blocks that don't have explicit deny clauses for unmatched paths.

2. **Anonymous handle pinning.** Posts, replies, conversations must enforce `authorHandle == request.auth.uid`'s canonical handle from the user doc. Recent commits hardened this for posts + replies + convo participantHandles slot; verify drafts (added by `d076684`) and any other write path that includes a handle.

3. **PII immutability on user-doc updates.** Email, selectedMood, notifyLikes, pushEnabled, confirmedAdult etc. must be either unchanging-by-rule or server-only. `confirmAdult` Cloud Function uses Admin SDK to bypass rules — verify rules deny clients from writing `confirmedAdult` / `confirmedAdultAt` directly. 141 tests already cover this; check coverage gaps.

4. **Blocking enforcement (bidirectional).** When A blocks B: B can't read A's posts, B can't reply, B can't follow A, B can't create a convo with A, B can't send a message in an existing convo, B's notifications about A get suppressed (or just never created), A can't see B's content (client-side filter via BlockedUsersCache, server-side via rule). Trace every collection where a block matters.

5. **Cross-doc `get()` / `exists()` staleness.** Rules can read other docs to make decisions (e.g., "can this user create a convo with X? `get(/databases/.../users/$(X)/blocked/$(request.auth.uid)).exists() == false`"). These reads see committed state but don't serialize with concurrent writes. Look for TOCTOU races where the rule decision is racy but the impact is low (e.g., blocked user briefly sees a convo doc before their listener filters it).

6. **Counter writes.** Like/save/follow counters are updated by Cloud Function triggers, not clients. Rules should deny client writes to counter fields. Verify.

7. **Report-flooding protection.** Reports collection: rule should rate-limit by author. Recent commit `8f14379` hardened this; verify the rule logic and the test coverage.

8. **Schema lockdown.** A write should be denied if it contains unknown fields. `keys().hasOnly([...])` pattern. Verify every create + update rule has this.

9. **Owner-only subcollections.** `users/{uid}/private/data`, `users/{uid}/blocked`, `users/{uid}/notifications`, `users/{uid}/liked`, `users/{uid}/saved`, `users/{uid}/following`, `users/{uid}/followers`, `users/{uid}/drafts` — verify each has `allow read, write: if request.auth.uid == uid;` (or appropriate variation). Specifically: notifications should be readable by the owner but writable only by Cloud Functions; drafts should be both r+w by owner only.

10. **Cascade-delete protections.** `pendingDeletions/{uid}` rule should allow create only if the auth user is requesting their own deletion. The cascade Cloud Function uses Admin SDK to do the actual wipe.

11. **Coverage gaps.** Diff what `firestore.test.js` exercises vs every `allow` rule in the file. Branches not covered by a test are interesting. The test count (141) suggests good coverage but specific edge branches may be untested.

### 6.2 Cloud Functions (`functions/index.js`, 3188 lines + `moderation.js` + others)

For EACH callable, onRequest, and trigger:

- **Auth check:** does it verify `request.auth` (callable) or manually verify the Bearer ID token (onRequest)?
- **App Check:** does it require an App Check token? (Required for production.)
- **Authorization:** is the caller allowed to act on the target resource? Not just authenticated — *authorized*. (e.g., `deleteAccount` should only delete the calling user's account, never another.)
- **Input validation:** type checks, length caps, schema. Especially for any field that lands in Firestore or a push payload.
- **Idempotency:** if retried, does it produce duplicate writes? Counters double-incremented?
- **Error messages:** do they leak resource existence? "User X not found" vs generic "not found."
- **Rate limiting:** is there a per-uid cap? (`checkRateLimit` in `reconcileMyCounts` is the pattern — confirm coverage for other expensive endpoints like `giphyProxy`, `exportData`, `deleteAccount`.)

For triggers specifically:

- **`onCreate` post trigger:** runs moderation, sets `flagged` field, may delete the doc. Verify: detector reads from `moderation.js`, evasion-hardening still works on a few test inputs (zero-width spaces, leetspeak, emoji separators), what happens if the detector throws.
- **`onCreate` report trigger:** sends admin notification. Verify: no PII leaks into the admin email/push payload that wasn't already in the report (the reporter's identity should be visible to admins but not the reported user's content beyond what was in the report).
- **`onWrite` blocked trigger:** cascades — strips follow docs, possibly notifications. Verify symmetry: if A blocks B, both A→B and B→A follow docs are removed, both A's notifications-from-B and B's notifications-from-A are suppressed.
- **`onUpdate` user trigger:** counter sync. Verify atomicity: counter increments via transaction, retries via the `5ac2473 counter-trigger retries` pattern.

For scheduled functions:

- **Cleanup of orphans.** Verify scope of deletion (only what should be deleted; bounded query limits).
- **Reap expired posts.** Posts with TTL get deleted; verify the TTL field is server-set, not client-set.
- **Reconcile counters.** Periodic recompute. Verify the gate isn't too aggressive (Firestore writes are expensive).

**Specific files to deep-read:**

- `functions/moderation.js` — the identifying-info detector. Try inputs: `J​ohn` (zero-width), `J0hn`, `J 0 h n` (spaced), `John 🌟` (emoji separator), `j-o-h-n`, `John's` (possessive), `https://twitter.com/john_doe` (URL with handle), `(555) 123-4567` (phone), `johndoe@example.com` (email). The detector should flag every one of these. If any slips through, that's at minimum a HIGH (Apple 1.2 UGC moderation contract).

- `functions/seedAppStoreDemo.js` — recently audited (commit `5c6d8b9`). Verify the prod guard `--yes-this-is-prod` is still required, that the demo credentials block correctly distinguishes newly-minted vs reused accounts, and that no other secrets land in stdout.

- `functions/cleanup.js` — dev tooling only. Verify the prod-project guard (`NON_PROD_PROJECTS` set + `-test/-dev/-staging` suffix regex + `--allow-prod` flag).

- `functions/scrubLegacyPII.js` — verify it can't be triggered remotely; should be a manual one-shot.

### 6.3 iOS SwiftUI (cross-cutting deep read)

These are the bug classes static review of large async SwiftUI files actually catches. Apply each across every file in §2's iOS table.

1. **Firestore listener leaks.** Every `addSnapshotListener` should have a matching `.remove()` in `.onDisappear`, in the `.userDidSignOut` `.onReceive` handler, AND in any code path that replaces the listener (re-binding to `listener` without first calling `.remove()` is a silent leak). Listeners installed inside `.task {}` blocks need their parent Task cancellation to teardown.

2. **Captured-uid recheck pattern.** The codebase has a documented pattern: capture `uid` at listener-creation, recheck inside the snapshot callback before mutating `@State`. `PostDetailView.startLiveListener`, `BlockedUsersCache.startListening`, `UserHandleCache`, and (after commit `7e25d01`) `PostDetailView.fetchReplies` all do this. Check every OTHER listener in the codebase for this pattern: is it present? If not, can a fast sign-out + sign-in to a different account let a delayed snapshot land the previous user's content in the new user's view?

3. **Sign-out cleanup completeness.** Every `.onReceive(NotificationCenter.default.publisher(for: .userDidSignOut))` handler should: (a) call `.remove()` on any active listener, (b) clear any cached `@State` arrays/sets/dicts that contain other users' content. If a handler only removes the listener but leaves the data in `@State`, the next signed-in user briefly sees the previous user's data. Verify across every view file.

4. **Optimistic UI rollback.** When user toggles like/save/follow/block and the server write fails, the UI should revert. `PostInteractionManager.toggleLike:119` is the canonical rollback. Verify same pattern in `toggleSave`, `toggleFollow`, `BlockedUsersCache.block`, `BlockedUsersCache.unblock`.

5. **Async stale-response races.** User taps post B while post A is loading; A's slow response writes `@State` AFTER B's. Look for unguarded `Task {}` writes to view-bound `@State` where the captured ID could have changed by the time the response arrives.

6. **NotificationCenter handler accumulation.** `.onReceive(...)` in SwiftUI is fine. Any manual `NotificationCenter.default.addObserver(...)` outside `.onReceive` needs a matching `removeObserver`. Grep for direct `addObserver` calls.

7. **`@State` vs `@StateObject` vs `@ObservedObject`.** Wrong choice can cause state to be re-created on every re-render or shared across views unintentionally. Particular focus: `ComposeView` (presented as sheet/fullScreenCover — should it use `@StateObject` or be passed a parent's `@ObservedObject`?).

8. **Counter races.** Liking rapidly should produce a consistent final count. `RateLimiter.shared.isLikeInFlight` is the in-flight guard. Verify it's set BEFORE the optimistic update AND cleared in BOTH success and failure branches.

9. **Drafts subcollection.** Recent feature (`d076684`). Verify the listener teardown on signout + that writes only target the caller's own subcollection.

10. **Telemetry PII boundary.** `Telemetry.recordError(error, context: "...")` — verify the `context` strings never interpolate uid/email/handle/message text. `Telemetry.redactPII` regex (in `ToskaTheme.swift`) is defense in depth.

### 6.4 Admin dashboard + moderation pipeline (`docs/admin.html` + `functions/moderation.js` + report-related rules)

**This is the section the original brief under-specified. Audit it thoroughly.**

The admin dashboard is the only authenticated surface outside the iOS app. It's a static HTML page that loads Firebase JS SDK and authenticates via Firebase Auth using a custom claim (`admin: true`). All admin actions are gated by both the claim AND the rules-layer enforcement that reads it.

#### 6.4.1 Auth model

- Verify the admin custom claim is set ONLY through a Cloud Function that requires both App Check + an existing-admin's ID token (no client path).
- Verify the dashboard's client-side check is just UX; the rules layer is authoritative.
- Verify what happens when an admin's claim is revoked mid-session: pending writes should be denied; the dashboard should detect and force re-login.
- Account enumeration on admin login: are admin sign-in errors distinguishable from user sign-in errors? (Email Enumeration Protection is on; should cover both.)

#### 6.4.2 24-hour SLA tooling

The in-app `ReportSheet` promises reports are reviewed within 24 hours. Commit `86307ef` added SLA tracking to the dashboard.

- Verify the dashboard surfaces overdue (>24h) and aging (12–24h) reports.
- Verify the timestamp comparison uses report `createdAt`, not first-loaded-at or some client-side clock.
- Verify the count of overdue reports is correct (not stale, not double-counted).
- Verify the styling makes it physically hard for an admin to miss overdue items.

#### 6.4.3 Moderation queue lifecycle

For each report type (post, reply, conversation, user):

1. **Report creation:** rule allows, deduplication exists, rate-limited per-author.
2. **Admin visibility:** report appears in the queue. PII surfaced to admin should be only what's necessary to make a decision (reported content + report reason + reporter handle for context). Reported user's full content history should NOT be visible by default; admin should have to explicitly drill in.
3. **Admin action:** dismiss, remove, restrict. Each should write an audit-trail doc that no one can delete (including admins). Verify rules permit only admins to write the action doc and deny everyone (including admins) from deleting it.
4. **Notification of outcome:** does the reporter get notified that their report was actioned? Does the actioned user know what was removed and why? (Apple sometimes asks about this during review.)
5. **Appeals:** is there an appeal path? If not, document the contract clearly.

#### 6.4.4 Identifying-info detector (`functions/moderation.js`)

The hardest single component. Adversarial inputs:

| Input | Expected | Comment |
|---|---|---|
| `her name is Sarah` | flagged | literal real-name pattern |
| `her name is S​arah` | flagged | zero-width space |
| `her name is sarah` | flagged | case |
| `her name is S a r a h` | flagged | spaced letters |
| `her name is S.a.r.a.h` | flagged | punctuated |
| `she's sarah.smith@gmail.com` | flagged | email |
| `(555) 123-4567` | flagged | phone US |
| `+44 20 7946 0958` | flagged | phone international |
| `https://twitter.com/sarah_real` | flagged | handle via URL |
| `instagram: sarahreal` | flagged | platform handle inline |
| `lives at 123 Main St` | flagged | address |
| `🅢🅐🅡🅐🅗` | ? | unicode block stylization |
| `s̶a̶r̶a̶h̶` | ? | combining diacritics |
| `S A 𝓡 A H` | ? | mathematical alphanumeric symbols |

The detector won't catch every adversarial Unicode tomfoolery — call out which evasion paths still work. The 54cf evasion-hardening commit was a step forward; verify what's still slip-through-able.

Also verify:
- Detector runs server-side as the source of truth (client check is convenience).
- A post that fails the detector either never reaches `posts/` (preferred) OR is flagged + soft-deleted within the trigger before any reader sees it.
- Detector failures fail closed (post rejected) not open (post accepted with no flag).

#### 6.4.5 Admin abuse model

Admins are humans. What can a malicious admin do?

- Can an admin read a user's private subcollection (`users/{uid}/private/data` with FCM token)? Rules should deny even admins from this; the FCM token is a vector to impersonate-by-push.
- Can an admin read a DM thread they aren't a participant in? Rules should allow only for moderation purposes via a Cloud Function callable, with an audit-trail doc written. NO direct read.
- Can an admin delete a user's content silently with no audit trail?
- Can an admin elevate another user to admin? Should require two-admin approval ideally; at minimum, a Cloud Function with App Check.

### 6.5 State-machine flows

For each multi-step state machine, simulate every force-quit point and answer: on cold-start, do we land somewhere recoverable?

**Age-gate + policy-accept (signup):**

```
A. Tap "Sign up" → SplashView
B. Choose provider (Apple / Google / email)
   ├── Email: CreateAccountView → enter email/password → tap "create" →
   │     create FirebaseAuth user → create Firestore user doc →
   │     call confirmAdultServerSide → showOnboarding
   └── Apple/Google: SSO flow → AppleSignInHelper or Google helper →
         create Firestore user doc (if new) → showOnboarding
C. OnboardingView shows
   ├── AgeGateView ("i am 17 or older")
   │     onConfirmAdult → confirmAdultServerSideFireAndForget →
   │     showPolicyAcceptance = true
   ├── PolicyAcceptanceView (checkbox + accept)
   │     onAccept → recordPolicyAcceptance → next onboarding step
   ├── Breakup-stage selection
   ├── Handle selection
   └── Onboarding complete → MainTabView
```

Force-quit points to trace:
- Between create FirebaseAuth user and create Firestore user doc: orphaned auth user.
- Between create Firestore user doc and confirmAdultServerSide call: cold-start re-shows gate (correct).
- Between AgeGate tap and confirmAdult server write: cold-start re-shows gate (correct, but check `try?` doesn't silently fail without re-prompting).
- Between PolicyAcceptanceView tap and recordPolicyAcceptance: cold-start should re-show policy.
- Mid-handle-selection: handle is server-validated; verify partial state doesn't leak.

**Account deletion:**

```
SettingsView → "delete account" → confirm alert →
clearFCMToken →
Apple-revoke (background) →
pendingDeletion doc create →
auth.delete →
Cloud Function cascade (delete user doc + subcollections + posts + replies + messages) →
post .userDidSignOut
```

Force-quit points:
- After pendingDeletion doc but before auth.delete: the scheduled cleanup function should pick this up.
- After auth.delete but before cascade completes: cascade should be resumable.
- The user's posts persist briefly with `authorId` pointing at a now-deleted auth user — verify reads gracefully handle this.

**Mid-conversation block:**

```
ConversationView open → user taps menu → "block this person" →
BlockedUsersCache.block(otherUid, handle) →
optimistic insert into local set →
post .userBlocked →
write to users/{uid}/blocked/{otherUid} →
ConversationView's onReceive handles block (need to verify what it does)
```

Verify ConversationView dismisses or freezes on receiving `.userBlocked` for the other participant.

### 6.6 Authentication flows

- Email signup → CreateAccountView. Verify password strength enforced (Apple may flag weak password UX during review).
- Email sign-in → SignInView. Verify error messages use `friendlyAuthErrorMessage` and that 17009/17011 collapse to one message (audit-hardened commit `5c6d8b9`).
- Apple SSO → AppleSignInHelper. Verify hidden-email handling (`@privaterelay.appleid.com`), nonce generation per Apple's requirements, full-name capture on first sign-in only.
- Google SSO → uses GoogleSignIn SDK. Verify the OAuth client ID matches the `CFBundleURLSchemes` in `Info.plist`.
- Password reset → PasswordResetView. Verify success/failure messages don't reveal whether the email is registered (EEP should cover this server-side; UI should match).

### 6.7 Push notifications

- Token lifecycle: `didReceiveRegistrationToken` → `saveFCMToken` → write to `users/{uid}/private/data`. Verify the private subcollection rule denies reads from anyone but owner + the Cloud Function (Admin SDK).
- Token cleanup on sign-out: `clearFCMToken` calls `Messaging.deleteToken()` FIRST (commit `7e25d01`) to invalidate at FCM service level, then wipes from Firestore. Verify this still holds.
- Token cleanup on account delete: same as sign-out, plus Cloud Function should re-verify no stale tokens remain.
- Push payload construction in `sendPushNotification` (in `functions/index.js`): verify message content is NOT included (audit-closed by `8f14379`). Title + generic body only. Deep-link IDs validated by `isValidFirestoreDocId` on the iOS side.
- Push deep-link routing: `MainTabView` `.openPostFromPush` / `.openConversationFromPush` / `.openProfileFromPush`. The handlers only run when MainTabView is on screen, which only happens when signed in. Verify cold-launch via `PendingPushIntent` correctly survives the signed-out → signed-in transition (intent should be discarded if signed-out user opens app via push from a previous account).
- iOS 18.6 deployment target → real-device push delivery requires APNs; can't test without real device.

### 6.8 Anonymity boundary (cross-cutting)

The most important non-obvious thing the audit can catch.

- **Crashlytics:** verify `setUserID` is NEVER called. Grep confirms; re-verify in this audit.
- **Telemetry events:** verify event names + parameters are bounded vocabulary. No post content, no handle, no email, no uid.
- **Analytics:** same. Firebase Analytics opt-in by default? Check `Telemetry.isOptedIn`.
- **Logs:** no `print(uid)`, `NSLog(email)`, etc. Grep confirms.
- **PrivacyInfo.xcprivacy:** linked-to-user flags match reality.
- **GoogleSignIn / Apple SSO email handling:** stored where? Verify only in owner-only subcollection.
- **Push payloads:** verify no message text in payload (only generic notification body).
- **Admin dashboard:** confirm admins see what they need + nothing more. Reported content + reporter handle, NOT reported user's other posts or DMs.

---

## 7. Adversarial scenarios — trace each

For each scenario, trace what happens, what state ends up where, and whether the threat is realized.

### 7.1 Stalker enumeration

Bob suspects Alice uses Toska. He has her email.

- Bob tries Alice's email at sign-in with wrong password. Wire returns generic `INVALID_LOGIN_CREDENTIALS`. (Confirmed: Email Enumeration Protection on.)
- Bob tries Alice's email at signup. Firebase returns `EMAIL_EXISTS` (17007). UI says "an account with this email already exists." Bob knows Alice is registered.
- Is this a real anonymity break? Apple/Firebase consider 17007 "necessary UX" — you can't allow duplicate signups. Document explicitly whether this is accepted risk.

### 7.2 Cross-account contamination on shared device

Alice signs in, posts, signs out. Bob signs in on same device.

- FCM token: `clearFCMToken` invalidates at FCM, but Bob's sign-in triggers a fresh token via `didReceiveRegistrationToken`. Verify Bob's notifications go to Bob's doc + the device gets the new token.
- BlockedUsersCache: singleton with `currentUid` gate. Verify Alice's blocked list doesn't leak into Bob's session.
- UserHandleCache: same. Verify Alice's handle doesn't briefly appear in Bob's UI.
- Firestore listeners: every view's `.userDidSignOut` handler must teardown listeners + clear data. Verify across every view file.
- Cached posts in `FeedViewModel`: verify cleared on signout.

### 7.3 Push to signed-out user

Alice receives a push for a new reply. Before tapping, Alice signs out and Bob signs in.

- Alice's notification banner is system-managed; Bob will see it briefly.
- Bob taps Alice's notification. iOS launches the app. `didReceive` fires in `PushNotificationManager`. `PendingPushIntent` is stashed.
- ContentView renders. Auth state is "signed in as Bob." MainTabView mounts. `.openPostFromPush` fires with Alice's postId in userInfo.
- Bob is now routed to a post he may not have access to. If the post is private/blocked-to-him, PostDetailView shows blank. If accessible, he can read content that was intended for Alice.

**Is this a real anonymity break?** Post content is public-readable by design (Toska's feed is public). So Bob sees a post anyone could see. No anonymity break. But it's a confusing UX. Flag if any DM-related push could leak content to a non-participant.

### 7.4 Force-quit during age gate

User taps "i am 17 or older". App is killed before confirmAdult Cloud Function returns. Cold-start.

- ContentView checks user doc. `confirmedAdult` is false (because the server write didn't land). Onboarding re-shows the age gate. User taps again. Server write lands this time. Correct behavior.
- Pathological case: server is durably unreachable. User keeps tapping. `try?` swallows error. User is stuck unable to post (rule denies because `hasConfirmedAdult()` returns false). ComposeView catches the permission-denied and surfaces "still setting up your account — try again in a moment". Recoverable but visible.

### 7.5 Block evasion

A blocks B. Can B still:

- See A's posts? Rule should deny `posts/{postId}` read where post.authorId == A and B has been blocked by A. Trace.
- Reply to A's posts? Rule should deny reply create. Trace.
- Send a DM to A? Convo create rule reads A's blocked list. Trace.
- Send a DM to A via a *different* user's convo by spoofing? Rule pins authorId. Trace.
- Receive notifications about A? Notifications are created by Cloud Functions; verify the create rule + the trigger logic both check blocking.
- Follow A? Following subcollection rule. Trace.
- See A in feed? Client-side filter via BlockedUsersCache; server-side also denies the read.

### 7.6 Moderation evasion

Adversary posts identifying content, evading the detector. (See §6.4.4 for inputs.)

- Detector returns "clean" → post lands → readers see PII.
- Reporter flags → admin sees → admin removes → 24h SLA.
- If detector misses, the time-to-removal is bounded by report-and-action.
- What's the EXPECTED time-to-removal if no one reports? (None — the detector is the only gate.) This is the worst case to think about for adversarial inputs that evade detection.

### 7.7 Report flooding

Adversary reports victim 1000 times to overwhelm the moderation queue.

- Verify rate-limit on report creation per-author. Recent audit-closed `8f14379`.
- Verify admin queue dedupes reports by `(reportedDocId, reporterUid)` so spam doesn't multi-row.
- Verify the SLA tracker doesn't get gamed (1000 reports each at T=0 don't trigger overdue cascade at T+24h).

### 7.8 Admin token compromise

An admin's session token is stolen (phishing). Adversary tries to abuse admin powers.

- Can they delete content? Yes — that's the moderation action. Audit trail should show it.
- Can they elevate themselves? Only if a Cloud Function allows self-elevation, which it should not.
- Can they read DMs? Only via the Cloud Function with audit-trail. Verify no direct rule path for `admin: true` to read `conversations/*/messages/*`.
- Can they exfiltrate the database? Limited by rules even with admin claim. They can only read what an admin is supposed to see.

### 7.9 Cascade-deletion abuse

User deletes account. Cascade Cloud Function runs.

- Can a user trigger cascade on someone else's uid? No — `pendingDeletion/{uid}` rule should require `request.auth.uid == uid`.
- What if the cascade fails partway? Resumable.
- What about posts the user made? They get deleted. Replies to deleted posts? Orphaned — verify UI handles gracefully.
- DM conversations? The user's side is deleted; the other participant should see the convo as "user no longer exists" not a blank state.

### 7.10 Apple reviewer's edge cases

Apple's reviewer will:

- Sign in as the demo account (created by `seedAppStoreDemo.js`).
- Try to post identifying content like "her name is Olivia" — must be auto-deleted.
- Try to report a post.
- Try to block a user.
- Try to see the admin dashboard (no admin claim → should fail gracefully).
- Try to delete their account.
- Try the password reset flow.
- Tap a push notification (won't deliver because simulator).
- Toggle every Settings switch.

For each, trace what happens. Anything that crashes, hangs, or shows a confusing error is a likely reject.

---

## 8. Specific things known-uncertain — explicitly flag if you can't verify

The auditor working from this brief MUST mark these as UNVERIFIABLE if they can't run on a real device:

- Push notifications end-to-end (APNs delivery; simulator has 4 stacked App Check issues per maintainer's note).
- App Attest behavior on a fresh device (the first-run path).
- Universal Links from `applinks:www.toskaapp.com` (requires associated-domains validation via Apple's CDN; real-device install needed).
- Force-quit interruption recoverability (would require scripted force-quit at every state-machine intermediate, which means real device + breakpoint tooling).
- App-icon rendering on real home screen (1024x1024 only specified; iOS renders smaller).
- Battery / network behavior under flaky conditions.
- Sign in with Apple revocation flow (user revokes via Settings → Apple ID; what does the app do?).
- Anything time-of-day-gated (FeelingCircleView dissolves at midnight; LateNightTheme).

Don't speculate about these. Mark them UNVERIFIABLE and move on.

---

## 9. Deliverable format

Produce a single markdown file: `AUDIT_REPORT_<YYYY-MM-DD>.md`.

Structure:

```
# Toska — Audit Report
**Date:** YYYY-MM-DD
**Auditor:** Claude (read-only)
**Scope:** comprehensive pre-submission audit per AUDIT_BRIEF.md
**Build under review:** <CURRENT_PROJECT_VERSION value> / <MARKETING_VERSION>

## Verdict
🟢 GREEN — ship it.
🟡 YELLOW — ship after addressing listed High items.
🔴 RED — do not ship. Critical items block submission.

## Findings by severity

### Critical
(or "none")

### High
(or "none")

### Medium
(or "none")

### Low
(or "none")

## Unverifiable (real-device required)
- Bullet list

## What I did
- Files read in full
- Files spot-read
- Commands run
- Tools used

## What I did NOT cover
- Honest gaps in this audit

## Comparison to prior audits
- New findings vs prior audits
- Prior findings I verified still hold (with file:line)
- Prior findings I verified are now fixed
```

A finding looks like:
```
### F-1: [HIGH] toska/FeedView.swift:1543 — likeListener missing captured-uid recheck
**Impact:** A fast sign-out + sign-in to a different account can let a delayed like-count snapshot mutate the new user's view state, briefly showing the previous user's like state on a post.

**How to repro (static):** Compare to `PostDetailView.startLiveListener` (line 567) — that listener captures uid before the closure and rechecks inside the Task. FeedView.likeListener does not.

**Verification:** unit tests would not catch this; would manifest under hostile timing in TestFlight.
```

---

## 10. Tone and rigor

This is not a feel-good audit. The owner is shipping a UGC app to Apple's strictest review category (17+ with mental-health adjacency) under an LLC with a real D-U-N-S. A vague "looks fine" report is worse than no report.

- Be specific. `file:line` always.
- Be honest about uncertainty.
- Don't inflate severity to seem thorough.
- Don't downplay severity to seem agreeable.
- If the codebase is mostly clean (it is — five prior audits closed dozens of findings), say so. Don't manufacture findings.
- If you find something that seems too obvious to have been missed by five prior audits, ASSUME you're wrong and re-read carefully before reporting. Then either confirm or drop it.

When you find something real, the owner thanks you. When you find something fake, the owner has to verify your work and burn a session. Calibrate accordingly.

---

## 11. Practical session sequence

A sensible order for the auditor's work:

1. Read this brief end-to-end. (~10 min.)
2. Read `PRE_SUBMISSION_REVIEW_2026_05_01.md` for historical context. (~5 min.)
3. Run `git log --since="2026-05-01" --oneline` to see what's changed since the last green verdict. (~1 min.)
4. Run `firestore-tests` and `xcodebuild` to confirm green baseline. (~2 min.)
5. Spawn parallel sub-audit agents (if available) for: (a) Firestore rules + Cloud Functions, (b) iOS Swift surfaces by area, (c) Admin dashboard + moderation pipeline, (d) State machines. Each agent ~15–20 min.
6. Verify every claim each agent surfaces against the actual code BEFORE writing it as a finding. ~30% of agent findings will be false positives or stale; do not pass them through.
7. Do adversarial scenario tracing (§7) by reading the code paths, not by spawning more agents.
8. Write the report.

Estimated total: ~2–3 hours focused work. Longer if every section is thorough.

---

End of brief. Good hunting.
