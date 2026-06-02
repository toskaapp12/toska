# Toska — Full Function Audit Handoff (2026-06-02)

> **Purpose.** This is a complete, function-by-function map of the Toska backend, rules, iOS client, and admin dashboard, written so a fresh reviewer (human or agent) can audit **security, monitoring, edge cases, errors, and bugs** without re-discovering the architecture. Each entry says what the unit does, its trust boundary, and **what to scrutinize**.
>
> **Ground rules for the reviewer**
> - Cite exact `file:line`; verify against the real code (this doc can drift). If a cited line doesn't match, re-locate by symbol name.
> - Admin SDK (Cloud Functions) and IAM/REST writes **bypass** Firestore rules. The iOS client and `docs/admin.html` are subject to rules — that's the real client trust boundary.
> - Prod project = `toska-4ebf4`; staging = `toskastaging`. Prod Firestore + App Check are **enforced**. iOS uses App Attest; admin.html uses reCAPTCHA Enterprise; the simulator needs a registered App Check **debug token**.
> - Pending-review model (2026-05/06): posts are created hidden (`moderationStatus` absent or `"pending_validation"`), and `validatePost` promotes clean ones to `"live"`. Feed queries pin `moderationStatus == "live"`. Bad posts flip to `"pending_review"` and never reach feeds.
> - Tests: `firestore-tests/` (emulator rules tests + mocha moderation tests). 163 rules + 131 moderation passing as of this writing.

---

## 1. Architecture & data model

**Stack:** SwiftUI iOS client → Firebase (Auth, Firestore, Cloud Functions v2 [node], FCM, App Check). Static admin dashboard on GitHub Pages (`docs/`, served from `main` branch at `www.toskaapp.com/admin.html`).

**Top-level Firestore collections** (see `firestore.rules` for the authoritative shape):

| Collection | Purpose | Notable subcollections |
|---|---|---|
| `users/{uid}` | profile, counts, restriction flags, `confirmedAdult` | `following`, `followers`, `notifications`, `saved`, `liked`, `likedReplies`, `savedReplies`, `blocked`, `presence`, `private/data` (fcmToken, PII), `drafts` |
| `posts/{postId}` | posts + reposts | `replies/{replyId}` (+ `replies/*/likes`), `likes/{uid}`, `reflections/{id}` |
| `conversations/{id}` | **DMs — product-CUT**; rules/functions remain for legacy data | `messages/{id}` |
| `feelingCircles/{id}` | ephemeral group spaces | `messages/{id}` |
| `dailyMoment`, `finalPosts/{uid}` | daily prompt + "final post" | |
| `reports/{id}` | user reports (post/user/message/conversation) | |
| `admins/{uid}` | `{ role: "admin" }` — the admin gate | |
| `adminAuditLog/{id}` | server-written audit trail (admin SDK only) | |
| `processedTriggerEvents/{eventId}` | idempotency claim docs (TTL-swept) | |
| `pendingDeletions/{uid}` | account-deletion work queue | |
| `meta/{doc}` | aggregate counters (tagCounts, etc.) | |
| `system/crisisAlertRecipients` | admin uids for crisis paging | |

**Key cross-cutting concern — idempotency.** Eventarc is at-least-once. Triggers that must not double-act claim `processedTriggerEvents/{event.id}` via `claimTriggerEvent` or run inside `claimedTransaction`. **Co-path-trigger trap:** multiple triggers fire on the same `posts/{postId}` create (`validatePost`, `onPostCreated`, `onPostCreatedUpdateTagCounts`, `rateLimitPosts`, `onPostCreatedAlertAdmins`). They share the same `event.id`. Only ONE may claim `event.id` for a given document event or it starves the others. `onPostCreatedUpdateTagCounts` claims `event.id`; `onPostCreatedAlertAdmins` deliberately uses a **per-post** key (`crisisAlert_<id>`) to avoid the collision. **A reviewer adding a claim to any co-path trigger must namespace the key.**

---

## 2. Cloud Functions — `functions/index.js` (50 exports)

Trust note: every `onCall`/`onRequest` is internet-reachable; every `onDocument*` runs with admin privileges on data that may have been written by a tampered client (rules are the gate for what the client could write).

### 2a. Counter triggers (idempotency- & race-sensitive)

| Function | Trigger | What to scrutinize |
|---|---|---|
| `onLikeCreatedUpdateCounts` (1233) | create `posts/*/likes/*` | uses `claimedTransaction`? increments `likeCount` + author `totalLikes`. Check both increment atomically and dedup on redelivery. |
| `onLikeDeletedUpdateCounts` (1277) | delete like | mirror decrement; floor at 0? double-fire. |
| `onReplyCreatedUpdateCount` (1306) | create reply | **claim-then-write pattern** — claims `event.id` FIRST then updates; if the update throws, the claim is set so redelivery skips → **permanent off-by-one** (logged via `logCounterDrift`, not recovered). Same pattern in 1340/1371/1386/1405/1441/1476/1498/1582/1612/1704/3246. Verify whether this matters for each. |
| `onReplyDeletedUpdateCount` (1340) | delete reply | decrement; same drift caveat. |
| `onReplyLikeCreated/DeletedUpdateCount` (1371/1386) | reply like ±| reply `likeCount`. |
| `onRepostCreated/DeletedUpdateCount` (1405/1441) | repost ± | original post `repostCount`. Check repost-of-deleted-original. |
| `onReplyRepostCreated/DeletedUpdateCount` (1476/1498) | reply-repost ± | |
| `onFollowCreated/DeletedUpdateCounts` (1582/1612) | follow ± | follower/following counts both sides. Races with `reconcileMyCounts` (now transactional). |
| `onPostCreatedUpdateTagCounts` (1743) | create post | **claims `event.id`** (the one co-path claimer). `meta/tagCounts` increment. |
| `onPostDeletedUpdateTagCounts` (1770) | delete post | decrement tag count. |
| `onMessageCreatedUpdateCount` (3246) | create DM message | DM surface is CUT; legacy. `clientCountedV1` skip path. Decrement double-fire risk noted (`onMessageCreatedModerate`). |
| `onBreakupStageChanged` (1704) | write `users/*` | stage transition counter/notification. Check loop-guard on self-writes. |
| `onLikeWritten` (1638) | create like | **milestone notifications** at like counts [10,25,...]. Reads racy `likeCount` (maintained by a *separate* trigger) → milestones can be missed or mis-timed. No `claimTriggerEvent` (dedup relies on deterministic notif id `milestone_<post>_<count>`). KNOWN MEDIUM. |

**Counter-drift class (open):** the 12 "claim-first-then-write" triggers can permanently drift by one on a post-claim failure. Migration to `claimedTransaction{retry:true}` was applied to likes/follows but not the rest. Accepted/logged today.

### 2b. Post validation & moderation

| Function | Trigger | What it does / scrutinize |
|---|---|---|
| `validatePost` (1792) | create post | **The promotion gatekeeper.** Validates reposts (existence + text + authorId match; deletes forgeries), blank/length, PII (`containsNameOrIdentifyingInfo` → `setPendingReview("pii")`). Then `if (isPostClean(text)) setPostLive(...)`. Valid reposts → `setPostLive`. Bound to `secrets`? No (no Perspective). **Check:** the `isPostClean` union (PII + flag + crisis) vs `onPostCreated`'s independent checks — they must agree so a post isn't promoted then immediately held. Fail-open behavior if a sub-check throws. |
| `onPostCreated` (2409) | create post | Crisis-most-severe-first: `if (concerning) setPendingReview("crisis", {concerningContent, [flagged]})` else `if (flagReason) setPendingReview(...)`. Runs `checkRepeatOffenderPosts`. **Check:** ordering vs `validatePost`'s promotion (race window); `setPendingReview` overriding a just-set `live`. |
| `onPostUpdated` (2493) | update post | Re-moderation on edit. Bails if `before.text === after.text` (loop guard). Crisis-first, then PII, then flagReason. **Check:** edit that introduces crisis+PII; the skip-guard `flagAlreadyCorrect`. |
| `onPostCreatedAlertAdmins` (2585) | create post | Pages admins on `isPostExplicitCrisis`. Idempotent via `crisisAlert_<postId>` claim. Reads FCM tokens from `users/{uid}/private/data`. **Check:** `FALLBACK_ADMIN_UIDS` hardcoded (2.x); failure modes when recipients/tokens missing (must not retry-storm). |
| `onReportCreatedAutoHide` (3192) | create report | 3+ distinct reporters in 24h → `setPendingReview("user_reports")`. Query bounded `.orderBy(createdAt desc).limit(60)`. **Check:** distinct-reporter set correctness under the limit; no idempotency claim (benign via `setPendingReview` idempotency). |
| `reconcilePostVisibility` (1978) | schedule 30m | Backstop: scans posts older than 10m / newer than 24h with absent or `pending_validation` status, re-decides (promote clean / `holdReconciledPost`). **Check:** the 24h window misses older stuck posts; can't query "missing field" so it scans + filters in JS (bounded by `.limit(500)`). |
| `validateReply` (2024) | create reply | blank/length/PII → delete (replies use delete, not hold). **Check:** delete races with the create-counter increment. |
| `onReplyCreatedModerate` (2690) / `onReplyUpdated` (2713) | reply create/update | `computeReplyFlagReason` → `applyReplyModeration`. **Check:** parity with post moderation; soft-flag vs delete. |
| `onMessageCreatedModerate` (2744) | create DM message | hate/threat → delete + `messageCount` decrement. **No idempotency claim → redelivery double-decrements** (KNOWN MEDIUM, bounded: DM surface is cut). |

### 2c. Rate limiting (per-uid sliding window via `checkRateLimit`)

| Function | Trigger | Notes |
|---|---|---|
| `rateLimitPosts` (2067) | create post | Tier limits; deletes over-limit posts. **Check:** delete vs counter races; the window storage collection. |
| `rateLimitReplies` (2798) | create reply | |
| `rateLimitNotifications` (2988) | create notification | |
| `rateLimitReports` (3129) | create report | Tier 2: 10/hr per target (bounds the brigade). |

### 2d. Notifications

| Function | Trigger | Notes |
|---|---|---|
| `sendPushNotification` (907) | create `users/*/notifications/*` | Transactional `processed` claim. Reads fcmToken from `private/data`. **Check:** token cleanup on invalid-token send errors; payload shape; doesn't leak across users. |
| `enrichReplyNotification` (3038) | create notification | Adds parent context. **Check:** reads only what it should; no PII leak into notification body (note `message` field is server-only per rules). |

### 2e. Account deletion / GDPR (Art. 17) — the cascade

| Function | Trigger | Notes |
|---|---|---|
| `onUserDocDeleted` (760) | delete `users/*` | Master cascade. Calls the `cleanup*ForUid` helpers via `runWithResume` (resumable, `queueUserCleanupContinuation`). **Check completeness:** posts(+subcols), follows(both sides), notifications, reposts, reflections, circle messages, conversations+messages, submitted reports, private/saved/liked/blocked/presence/drafts. **Known residual gaps:** other users' `blocked/{deletedUid}` rows and surviving `posts/*/likes/{deletedUid}` are NOT cleaned (residual uid refs + likeCount inflation). |
| `onPendingDeletionCreated` (1173) | create `pendingDeletions/*` | Kicks off deletion. |
| `resumePostDeletion` (3293) / `resumeUserCleanup` (3343) | schedule 60m | Resume partial cascades. **Check:** the resume cursor/idempotency; infinite-loop guard. |
| `monitorPendingDeletions` (3425) | schedule 60m | Alerting on stuck deletions. |
| `onPostDeletedCleanupReposts` (1539) | delete post | Removes reposts pointing at a deleted original. |
| `cleanupProcessedTriggerEvents` (2896) | schedule 24h | TTL sweep of claim docs. |
| `cleanupExpiredPosts` (2924) | schedule 60m | Whisper/midnight `expiresAt` posts. |
| `cleanupExpiredCircles` (2957) | schedule 60m | Ephemeral circles. |

### 2f. Callable / HTTP (internet-facing — auth is critical)

| Function | Type | Auth posture / scrutinize |
|---|---|---|
| `giphyProxy` (3487) | `onCall` | `enforceAppCheck:true` + `request.auth` check. Giphy key via `defineSecret("GIPHY_KEY")`. **Check:** key not echoed in errors (it sanitizes `api_key=`), input validation, SSRF-style abuse. |
| `reconcileMyCounts` (3579) | `onRequest` | Manually verifies App Check token **and** `verifyIdToken` (because `enforceAppCheck` is onCall-only). Recount in a `runTransaction` (fixed 2026-06-01). `checkRateLimit` 6/day. **Check:** CORS `false`; the manual auth path; aggregation-in-transaction. |
| `confirmAdult` (3693) | `onCall` | `enforceAppCheck:true` + auth. Admin-SDK writes `confirmedAdult` (clients can't). **Check:** idempotency; rules truly forbid client writes of the field. |

### 2g. Audit & SLA

| Function | Trigger | Notes |
|---|---|---|
| `auditUserRestriction` (3758) | update `users/*` | Writes `adminAuditLog` on `restricted` transitions. Actor inferred from `restrictedBy`. |
| `auditReportResolution` (3778) | update `reports/*` | On `status` change. Actor from `reviewedBy`. |
| `auditPostModeration` (3804) | update `posts/*` | Gated on `pendingApprovedBy`/`crisisReviewedBy` newly appearing (so auto-holds don't spam). |
| `auditPostDeletion` (3844) | delete `posts/*` | Reads `deletedBy` (admin stamps it before delete) else `"author"`. |
| `notifyAdminsOfNewReport` (3885) | create report | Structured `WARNING` log for a Cloud Monitoring alert policy. |
| `checkReportSLA` (2853) | schedule 60m | 24h SLA tracking (Apple 1.2 promise). |

### 2h. Shared helpers (`functions/index.js`)

`deleteCollection` (34), `cleanup*ForUid` (73–410), `logCounterDrift` (410), `moderationDeleteJitter` (435, timing-oracle defense), `setPendingReview` (465, idempotent on already-pending), `setPostLive` (508, promotes absent/`pending_validation`, never `pending_review`/`live`), `isPostClean` (527, PII∧flag∧crisis), `runWithResume`/`queueUserCleanupContinuation` (546/570), `claimTriggerEvent` (606, fail-open), `claimedTransaction` (662), `checkRateLimit` (725), `holdReconciledPost` (1954), `hasPhoneNumber` (2102), `containsPII` (2134), `containsURL` (2159), `matchesCrisisPhrase` (2271, normalization), `isPostExplicitCrisis`/`isPostConcerning` (2284/2331), `computePostFlagReason` (2313), `checkRepeatOffenderPosts` (2349), `flagReasonToPendingReason` (2473), `computeReplyFlagReason`/`applyReplyModeration` (2661/2672), `writeAuditEntry` (3747).

**Review focus on helpers:** `claimTriggerEvent` fails OPEN on Firestore error (over-count once rather than drop) — confirm that's acceptable per call site. `setPendingReview` early-returns if already `pending_review` and only merges `extraFields` — a client-created `pending_review` would block a later reason write (this is why client create uses `pending_validation`, not `pending_review`).

### 2i. `functions/moderation.js` (PII + name detection)

`containsNameOrIdentifyingInfo` (entry), `canonicalize` (unicode/confusable/fullwidth fold + invisible-strip + lowercase), `aggressiveNormalizeForNameMatch` (canonicalize + de-leet + spaced-letter collapse), `looksLikeFullName` (two-capitalized-words shape, 2026-06-02), `foldFullwidthDigits`, `STRIP_INVISIBLE_RE`. Dictionaries: `COMMON_NAMES`, `COMMON_LAST_NAMES`, `AMBIGUOUS_WORDS`, `SAFE_CAPITALIZED_WORDS`, `SAFE_PROPER_NOUN_BIGRAMS`, `IDENTIFYING_PATTERNS`, `RELATIONSHIP_PREFIXES`, `NAMED_PATTERNS`, `LOCATION_CONTEXT_PATTERNS`, `STREET_REGEX`, `SOCIAL_SHORTHAND_RE`, `CRISIS_NUMBERS`. Covered by `firestore-tests/moderation.test.js`.

**Known ceiling (document, don't "fix" with a phrase):** keyword/dictionary detection cannot catch bare/lowercase names (`"Tess salinaro"`) or novel crisis phrasings. The real fix is NER/ML; the backstop is report+block+admin. Crisis vocabulary lives in `index.js` (`MOD_CRISIS_EXPLICIT`/`MOD_CRISIS_SOFT` → `MOD_CONCERNING`/`MOD_EXPLICIT_CRISIS`); name/PII lives in `moderation.js`. **Client mirrors** of both live in `FeedView.swift` (`explicitCrisisPhrases`/`softConcernPhrases`, `containsNameOrIdentifyingInfo`) — keep in sync.

### 2j. One-off scripts (not deployed triggers — run manually)

`cleanup.js`, `scrubLegacyPII.js`, `remediateFlaggedPosts.js`, `backfillModerationStatus.js` (stamps `live` on legacy posts), `seedAppStoreDemo.js`, `checkAdminUid.js`, `checkAppCheck.js`, `scripts/setupProdAdmin.js`. **Review:** these use Admin SDK / ADC — make sure none are wired as deployable functions or leak creds.

---

## 3. Firestore rules (`firestore.rules`, ~1280 lines)

Helpers: `isAuth`, `isOwner(uid)`, `isAdmin()` (reads `admins/{uid}.role == "admin"`), `postVisibleToCaller(postId)` (live∨author∨admin — subcollections inherit it), `notRestricted()`, `hasConfirmedAdult()`.

Review each `match` block for: (a) can a tampered client write fields it shouldn't (`hasOnly` allowlist complete?), (b) can a non-owner/non-admin read what it shouldn't, (c) list-vs-get leaks, (d) `resource == null` first-write probes.

| Block (line) | Key invariants to verify |
|---|---|
| `users/{uid}` (143) | `confirmedAdult`/`restricted*` are server-only; handle regex `^[a-zA-Z0-9_-]+$`; block-aware reads. |
| `following`/`followers` (251/272) | schema-locked to `{handle, createdAt}`; self-follow + block guards; owner-only reads. |
| `notifications` (303) | `fromHandle` pinned to caller; `message` field server-only; type-specific create rules (repost notif id pinning). |
| `saved/liked/likedReplies/savedReplies/blocked/presence` (463–490) | owner-only. |
| `private/data` (499) | owner-only (fcmToken, PII). |
| `drafts` (518) | owner-only. |
| `posts/{postId}` (537) | **read gate** `moderationStatus=='live' ∨ author ∨ admin` (518-style); **create** schema `hasOnly` allowlist incl. `moderationStatus` constrained to `pending_validation`; createdAt pinned to `request.time`; authorHandle pinned; **repost** + **reply-repost** verified at write layer (text/authorId/handle match, block check); **update** denies counter/moderation fields to clients; admin-update leg currently has **no `hasOnly`** (open MEDIUM). |
| `replies` (747) + `replies/*/likes` (810) | reads inherit `postVisibleToCaller`; create schema-locked, createdAt pinned, block check, authorHandle pinned. |
| `posts/*/likes` (826) | reads inherit `postVisibleToCaller`; create block-checked. |
| `reflections` (840) | reflection-author or post-author only. |
| `conversations`+`messages` (896/1050) | DMs cut; legacy rules (participant pin, schema lock). |
| `feelingCircles`+`messages` (1098/1159) | participant-only writes. |
| `dailyMoment`/`finalPosts` (1195/1200) | `finalPosts/{uid}` read currently `isAuth()` (LOW: uid-keyed, possible enumeration). |
| `reports` (1232) | text cap; `reportedBy` pinned; create-only for clients. |
| `admins` (1255) | read owner-only; **write: nobody** (provisioned out-of-band). |
| `adminAuditLog` (1264) | read admins; write nobody (Admin SDK only). |
| `processedTriggerEvents` (1275) / `pendingDeletions` (1279) | server-only. |
| collection-group `replies` (~1306) | restricted to `resource.data.authorId == request.auth.uid` (closes the held-post reply dump). |
| `meta` (1324) | read-all aggregate counters; write nobody. |

---

## 4. iOS client (`toska/*.swift`, ~24k lines)

**Cross-session leak pattern (audit every async load):** capture `uid` at start; after every `await`, **recheck `Auth.auth().currentUser?.uid == uid` before writing `@State`**, and clear state on `.userDidSignOut`. Verified-clean loaders mirror this; the reviewer should grep every `addSnapshotListener` / `.task` / `getDocuments` callback for missing rechecks (recent fixes: `ProfileView.loadMyReplies`, `loadPresenceStreak`).

**Listeners:** every `addSnapshotListener` must be stored in a `ListenerRegistration?` and removed on `onDisappear`/`deinit`/sign-out. `FeedViewModel` listeners reset via `MainTabView.userDidSignOut`. Caches (`BlockedUsersCache`, `UserHandleCache`) tear down via the app-level auth state listener (`toskaApp.swift`).

**Key files:** `toskaApp.swift` (app entry, auth state, App Check/App Attest setup), `MainTabView`/`ContentView` (nav + sign-out fan-out), `FeedView`/`FeedViewModel` (feed queries — all pin `moderationStatus == "live"`; **client mirrors of crisis + name detectors live in FeedView.swift**), `ComposeView`/`PostInteractionManager` (post + repost create — stamp `moderationStatus: "pending_validation"`), `PostDetailView`/`ReplyDetailView` (threads, edit re-moderation, GIF preview via `StableGifPreview`), `ProfileView`/`OtherProfileView` (profiles, follow, reply tabs), `NotificationsView`, `ExploreView`/`TopView` (ranked feeds), `OnboardingView`/`CreateAccountView`/`SignInView`/`AppleSignInHelper` (auth + age gate via `confirmAdult`), `SettingsView` (data export, account deletion), `ToskaTheme` (incl. `CrisisCheckInView`, crisis resources), `ShareCardView` (share images — Photos-add permission). DMs (`ConversationView`/`MessagesListView`/`MessageBubble`) are legacy/cut.

**Review focus:** force-unwraps on Firestore-bearing optionals; edit paths that bypass moderation (post/reply edit calls re-validation?); `AsyncImage`/GIF in body-recomputing parents (use `StableGifPreview`); crisis/self-harm UI HIG-compliance; post-delete reverse-index cleanup; Info.plist privacy strings vs. actually-used permissions; entitlements vs. AASA (`docs/.well-known/apple-app-site-association`).

---

## 5. Admin dashboard (`docs/admin.html`, served from `main/docs`)

Publicly reachable; **security perimeter is Firestore rules** (a cloned page gains nothing without an `admins/{uid}` doc). XSS-safe: all user strings via `.textContent`/`createTextNode` (no `innerHTML`). App Check via reCAPTCHA Enterprise (`RECAPTCHA_SITE_KEY`).

Functions: `signIn`/`switchTab`/`loadTab`; tabs `loadReports` (527), `loadPending` (330, `moderationStatus=="pending_review"`), `loadFlagged` (634), `loadCrisis` (437), `loadRestricted` (700); actions `approvePending` (409, sets `moderationStatus:"live"`+`pendingApprovedBy`), `markCrisisReviewed` (511), `dismissReport`/`removePost`/`restrictUser`/`restrictUserDirect`/`unflagPost`/`deletePost` (stamps `deletedBy` before delete)/`unrestrictUser`.

**Review:** every privileged action must be denied by rules to a non-admin (verify against `firestore.rules`); approve/restrict actions write an actor stamp (for `auditPost*` triggers); last-writer-wins races on crisis/pending review; that `removePost`/`dismissReport` don't leave a report-held post stuck hidden (no restore path from the reports tab — the pending tab is the restore surface).

---

## 6. Known residuals / open items (don't re-report as new)

- **Counter-drift (MEDIUM):** 12 claim-first counter triggers can drift by one on post-claim failure (logged, not recovered).
- **`onLikeWritten` milestone race (MEDIUM):** reads racy `likeCount`; milestones can be missed/duplicated; deterministic notif id mitigates push dup.
- **`onMessageCreatedModerate` double-decrement (MEDIUM, cut surface).**
- **Admin `posts` update leg has no `hasOnly` (MEDIUM):** narrows only the *web* admin client (Admin SDK bypasses rules anyway).
- **Cascade-delete residuals (LOW):** other users' `blocked/{deletedUid}` + surviving `likes/{deletedUid}` (likeCount inflation).
- **`finalPosts/{uid}` read is `isAuth()` (LOW):** uid-keyed enumeration if content is sensitive.
- **Held-posts direct-get window:** mostly closed (new posts start `pending_validation`); legacy absent-field posts default to `live` in the read rule for safety.
- **Moderation ceiling:** bare/lowercase names + novel crisis phrasings need NER/ML (deferred); report+block+admin is the backstop. No AI moderation wired in (evaluated Perspective [no self-harm model] and OpenAI Moderation [has it]; deferred).
- **Reconciler window:** `reconcilePostVisibility` only re-checks the last 24h.

---

## 7. Reviewer checklist (suggested order)

1. **Rules end-to-end** — per `match` block, the four questions in §3. Especially: post create allowlist (can a client set `flagged:false`/`moderationStatus:"live"`?), subcollection read inheritance, reply-repost verification, admin gate consistency.
2. **Callable/HTTP auth** — `giphyProxy`, `reconcileMyCounts`, `confirmAdult`: App Check + auth on every path; no secret leakage.
3. **Idempotency** — every `onDocument*` that mutates a counter/sends a push/pages a human: does redelivery double-act? Co-path `event.id` collisions (§1).
4. **Moderation flow** — `validatePost` ↔ `onPostCreated` agreement; promotion vs hold race; `setPendingReview`/`setPostLive` guards; crisis ordering; PII + name + crisis detection gaps (run `moderation.test.js`, add evasion cases).
5. **GDPR cascade** — `onUserDocDeleted` completeness (§2e); resume/idempotency; residual reverse indices.
6. **iOS cross-session** — every async load rechecks captured uid; listeners torn down on sign-out; force-unwraps; edit-bypasses-moderation; crisis UI.
7. **Admin** — XSS sinks; rules deny non-admin writes; audit stamps present.
8. **Release** — Info.plist privacy strings vs used permissions; ATS; ATT consistency with `PrivacyInfo.xcprivacy`; entitlements vs AASA; report+block flow (Apple 1.2).
9. **Monitoring** — confirm log-based alert policies exist for: `notifyAdminsOfNewReport` (`jsonPayload.tag="new_report_for_review"`), counter-drift (`logCounterDrift`), function error rates, `monitorPendingDeletions`, crisis paging failures. (These are *configured in Cloud Monitoring*, not in code — verify they exist in prod.)

## 8. How to exercise it

- **Rules tests:** `cd firestore-tests && PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" firebase emulators:exec --only firestore,auth --project=toska-test 'npx mocha --timeout 15000 firestore.test.js'`
- **Moderation tests:** `cd firestore-tests && npx mocha moderation.test.js`
- **Functions load (catches reference errors syntax-check misses):** `cd functions && node -e "require('./index.js')"`
- **Live behavior probe (bypasses rules via IAM token; staging or prod):** create a `posts` doc via Firestore REST with `gcloud auth print-access-token` + `x-goog-user-project`, wait ~10s, read back `moderationStatus`/`pendingReason`, then delete. (Used this session to verify crisis + name holds.)
- **Simulator:** debug build targets **staging**; needs the App Check **debug token** registered (App Check API) or sign-in returns `403 App attestation failed`.

---

*Generated 2026-06-02. Verify line numbers against current `HEAD` before relying on them.*
