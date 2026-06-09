# Toska — Forensic Security Audit

**Status:** Recon pass complete. Deep-dives pending sign-off.
**Auditor:** principal iOS/Swift + Firebase security engineer (adversarial, verifies comments as claims).
**Date:** 2026-06-08
**Repo:** `/Users/tesssalinaro/Desktop/toska` @ `main`

Every claim below is traced to a real file. Findings are labeled **Confirmed** (path followed end-to-end) or **Suspected** (looks wrong, needs runtime/console confirmation). Rule/function *comments* are treated as claims, not facts.

---

## 0. Artifact inventory (the two "may-be-missing" backend files)

| Artifact | Status | Notes |
|---|---|---|
| `storage.rules` | **Absent — and correctly so.** | `firebase.json` has **no `"storage"` block**. Grep of all 41 Swift files for `FirebaseStorage` / `Storage.storage` / `StorageReference` → **zero hits**. **No Firebase Storage in use → no storage.rules to audit.** (Images/GIFs are Giphy URLs + on-device share-card rendering; no user uploads to GCS.) **Confirmed.** |
| `docs/admin.html` | **Present** (861 lines, 43 KB). Audited — see §5 below. | Served publicly via GitHub Pages (`docs/CNAME` → `www.toskaapp.com`, `.nojekyll` present). Not in a `firebase.json` hosting block. |
| `firestore.rules` | Present, 1054 lines, read in full. | |
| `firestore.indexes.json` | Present, 10 KB. | Not yet cross-checked against the queries admin.html / feed require. |
| Existing tests | **Present** — `firestore-tests/` with **129 `it()` rules-emulator tests** (`firestore.test.js`), a `moderation.test.js`, and `e2e-test.mjs` (live staging smoke). CI (`.github/workflows/ci.yml`) runs them on every push/PR. | The brief's "no tests exist" is true *only for the iOS project*; the rules layer is well-tested. Some tests reference now-cut DM/circle message-notification paths (stale but harmless). |

---

## 1. Repo & system map

**App:** SwiftUI iOS/macOS, 41 `.swift` files, ~22,335 lines. Firebase Auth (Sign in with Apple + Google + email/password) + Cloud Firestore + APNs/FCM push + App Check (App Attest). Anonymous breakup-talk social app ("moments"/posts, replies, feed, explore, follow, block, drafts, likes/saves, reposts incl. reply-reposts, reports, anniversary/daily/weekly cards). **No DMs** (cut), no FeelingCircles (cut), no finalPosts (cut).

**Backend:** `functions/` — `index.js` (3834 lines, ~40 deployed functions), `moderation.js` (643 lines, PII/name/crisis engine), `cleanup.js`, + 7 maintenance scripts. Node 22, `firebase-admin` 13.8, `firebase-functions` 7.2.

### Three security layers
1. **Swift client** (optimistic UI, reads/writes Firestore, invokes 3 callables/HTTP).
2. **`firestore.rules`** (1054 lines, heavily commented; whole-doc allow/deny granularity).
3. **Cloud Functions** (Admin SDK, **bypasses rules**, owns every security-critical write — counters, moderationStatus, restriction, confirmedAdult, notification `message`).

The entire write-trust boundary for document triggers is `firestore.rules`: **no Firestore document trigger verifies App Check or `request.auth`** — they trust that the rule layer gated whatever client write fired them. Only the 3 callables/HTTP endpoints verify the caller directly.

---

## 2. Two-environment / deploy topology

| | Prod | Staging |
|---|---|---|
| Project id | `toska-4ebf4` | `toskastaging` |
| iOS plist | `GoogleService-Info.plist` | `GoogleService-Info-Staging.plist` |
| Selected by | `#else` (Release) — `toskaApp.swift:74` | `#if DEBUG` — `toskaApp.swift:63-66` |
| App Check provider | `AppAttestProviderFactory` (`toskaApp.swift:50`) | `AppCheckDebugProviderFactory` (`:48`) |
| Rules deploy | **Manual** (`firebase deploy`, per RUNBOOK) | **Auto** on push to `main` via CI (WIF, no stored SA key) |

- **Release can never load staging** — the staging branch is `#if DEBUG`, compiled out of Release. **Confirmed.**
- **Inverse risk (Suspected, Low):** a Debug build with a *missing* staging plist **silently falls back to prod** with only a `print` warning (`toskaApp.swift:67-72`). Not fail-closed.
- **Cross-call (Suspected, Low):** `reconcileMyCounts` is called via a **hardcoded prod URL** `https://us-central1-toska-4ebf4.cloudfunctions.net/...` (`ProfileView.swift:696`), so a Debug/staging build hits the **prod** function. It attaches staging-issued tokens → prod App Check/ID-token verify should reject (cross-project). Functional bug, not a privilege escalation, but worth confirming it fails closed.
- **Staging-vs-prod rules parity:** CI auto-deploys rules to staging; prod is manual. Whether prod currently matches `main` and whether **functions** are deployed to both is **cannot-verify from code** (needs console / `firebase deploy` history). The CI comment claims this was added to *close* a prior staging-drift gap.
- **App Check ENFORCEMENT (cannot-verify from code; Critical-if-off):** rules/admin.html/comments and user memory all *claim* Firestore App Check is **Enforced** in prod. Initialization ≠ enforcement. Must be confirmed in **both** consoles (Firestore/Auth) — `functions/checkAppCheck.js` exists to inspect. Flagged for verification.

---

## 3. Authoritative data model (verified against rules + client)

```
users/{uid}                     public projection: handle, followerCount, followingCount,
                                totalLikes, allowSharing, showFollowerCount, restricted,
                                createdAt, hasCompletedOnboarding, acceptedPolicyVersion/At
                                SERVER-OWNED: confirmedAdult(+At), restricted(+At/By/Until),
                                followerCount/followingCount/totalLikes/postCount
  /private/{docId}              owner-only PII: email, selectedMood, breakupStage, fcmToken,
                                notify* prefs, pushEnabled, gentleCheckIn
  /following/{followedId}       owner-only read; {handle, createdAt}
  /followers/{followerId}       owner-only read; {handle, createdAt}
  /notifications/{notifId}      owner read; type-gated create (see §4); message = server-only
  /saved/{postId}               owner-only
  /liked/{postId}               owner-only
  /likedReplies/{replyId}       owner-only
  /savedReplies/{replyId}       owner-only
  /blocked/{blockedId}          owner create/delete; read by owner OR the blocked user
  /presence/{dateId}            owner-only
  /drafts/{draftId}             owner-only; {text<=2000, createdAt==req.time, updatedAt}

posts/{postId}                  authorId, authorHandle(pinned), text<=2000, createdAt==req.time,
                                likeCount/repostCount/replyCount(==0 at create, server-owned after),
                                tag, gifUrl, isRepost/isLetter/isWhisper/isMidnightPost/isShareable,
                                expiresAt, original{PostId,Handle,AuthorId,ReplyId}, promptDate,
                                moderationStatus(client may only set 'pending_validation')
                                SERVER-OWNED: moderationStatus 'live'/'pending_review', pendingReason,
                                pendingDetectedAt, flagged, flagReason, flaggedAt, concerningContent,
                                pendingApproved{At,By}, crisisReviewed{At,By}, unflagged{By,At}, deleted{By,At}
  /replies/{replyId}            authorId, authorHandle(pinned), text<=500, createdAt==req.time,
                                likeCount(==0), parentPostText/Handle, parentReplyId, gifUrl
    /likes/{likeUserId}         {createdAt==req.time}
  /likes/{likeUserId}           like doc
  /reflections/{reflectionId}   post-author-only create; {authorId, text<=500, createdAt}

dailyMoment/{dateId}            read: isAuth; write: false (server-only)
reports/{reportId}              create: isAuth+self+pinned-shape; read/update: admin; delete: false
admins/{uid}                    read: isOwner; write: false
adminAuditLog/{entryId}         read: admin; write: false (server-only)
processedTriggerEvents/{id}     read/write: false (dedup ledger, server-only)
pendingDeletions/{uid}          create/update(cancelled only)/delete: owner; read: false
meta/{docId}                    read: isAuth; write: false  (tagCounts, breakupStageCounts)
conversations, feelingCircles, finalPosts   read/write: false (CUT)
{path=**}/replies/{replyId}     collection-group read: own-author only
{document=**}                   default deny
```

---

## 4. Tri-layer contract table (client ↔ rule ↔ function)

Disagreements are flagged `⚠`. "OK" = client write shape, rule, and function expectations agree.

| Path / action | Swift call site | Governing rule | Function(s) | Verdict |
|---|---|---|---|---|
| `users/{uid}` create | `AppleSignInHelper:119`, `SplashView:197`, `CreateAccountView:335` | `users` create (handle regex, no confirmedAdult*) | `onUserDocDeleted` (delete cascade) | OK |
| `users/{uid}` update prefs/handle | `SettingsView:622`, `OnboardingView:482` | owner update minus server-owned + `legacyPIIFieldsImmutable()` | `auditUserRestriction` (on `restricted` change) | OK |
| user counters | client writes `0` only at create | counters in denied `affectedKeys` on update | `onFollow*`, `onLike*`, `reconcileMyCounts` | OK |
| `confirmedAdult` | never written by client (read only) | denied at create+update | `confirmAdult` callable only | OK |
| `users/{uid}` **read by admin** | admin.html `loadRestricted`, `restrictUserDirect` | read = `isOwner OR (isAuth && !blocked && noLegacyPIIVisible())` — **no `isAdmin()` leg** | — | ⚠ **Suspected:** admin cannot read a target user doc that still carries legacy PII; restricted-users tab silently drops unscrubbed accounts. Functional moderation gap. Deep-dive §later. |
| post create | `ComposeView:909` | `posts` create (notRestricted + hasConfirmedAdult + shape + moderationStatus pin + handle pin + repost lockdown) | `validatePost` → `setPostLive`/`setPendingReview`; `onPostCreated` moderation; tag/rate triggers | OK (rule pins more than client sends) |
| repost create | `PostInteractionManager:404,715` | repost branch verifies original authorId/text/handle pre-trigger | `validatePost` reply/post-repost verify; `onRepostCreatedUpdateCount` | OK — rule now closes the pre-trigger visibility window |
| post update (edit) | `PostDetailView:1632` | author update minus counters/moderation/flag fields | `onPostUpdated` re-moderate | ⚠ **Suspected (Low):** `deletedBy`/`deletedAt` are **not** in the author-update denylist → an author can self-stamp `deletedBy` and mislead `auditPostDeletion` attribution. Audit-log integrity only. |
| reply create | `PostDetailView:1417`, `ReplyDetailView:381` | `replies` create (notRestricted + hasConfirmedAdult + shape + handle pin + block check) | `validateReply`, `onReplyCreatedModerate`, `onReplyCreatedUpdateCount` | OK |
| like / save / follow | `PostInteractionManager`, `OtherProfileView` | per-subcollection owner/block rules | `onLike*`, `onFollow*` counters | OK |
| notification create | `PostInteractionManager:472`, `OtherProfileView:478` | per-type `exists()` proof + `fromHandle` pin + deterministic notifId + schema allow-list; `message` server-only | `sendPushNotification` (re-resolves handle, block check, dedup), `enrichReplyNotification` (backfills `message`) | OK — strongest rule in the file |
| report create | `PostDetailView:957`, `OtherProfileView:548`, `ToskaTheme:1633` | self + status='pending' + createdAt pin + shape + size caps | `rateLimitReports`, `onReportCreatedAutoHide`, `notifyAdminsOfNewReport` | OK |
| account deletion | `SettingsView:707` (`pendingDeletions` create) | owner create/delete | `onPendingDeletionCreated` → `onUserDocDeleted` → `cleanup*ForUid` cascade + resume queues | OK (cascade termination verified by mapping agent; one >5000-repost orphan edge) |
| cut collections | only dead-code/comments in 5 Swift files | `if false` | cleanup helpers drain legacy docs | OK — **no live client read/write to cut collections** (verified by grep; all references are comments/vestigial structs) |
| callables | see §4b | — | — | |

### 4b. Callable / HTTP contract

| Callable | Swift caller | App Check | Auth | Rate limit | Server-owned writes |
|---|---|---|---|---|---|
| `confirmAdult` (onCall) | `ToskaTheme:1295` (5 call sites) | `enforceAppCheck:true` | `request.auth.uid` required | 5/hr | `confirmedAdult(+At)` — sole writer |
| `giphyProxy` (onCall) | `GifPickerView:205` | `enforceAppCheck:true` | `request.auth` required | 60/min | none (Giphy key via Secret Manager) |
| `reconcileMyCounts` (onRequest) | `ProfileView:696` (raw POST, **prod URL hardcoded**) | manual `X-Firebase-AppCheck` verify | manual `Bearer` ID-token verify | 6/day | `followerCount`/`followingCount` (transactional recount) |
| `checkRateLimit` | *not called from client* (client uses local `RateLimiter`) | — | — | — | server-internal helper only |

---

## 5. Admin dashboard (`docs/admin.html`) — first-pass read

- **Hosting:** public GitHub Pages at `www.toskaapp.com` (CNAME). The in-file comment correctly retracts an earlier "not publicly served" claim.
- **Perimeter = Firestore rules.** Auth: Firebase email/password → `onAuthStateChanged` → `getDoc(admins/{uid})` and checks `role === "admin"` (`admin.html:269-270`); non-admins are signed out. A non-admin who signs in passes the *UI* gate only — every privileged write is `isAdmin()`-gated server-side. **Confirmed** the client-side admin check is not the security boundary.
- **App Check:** uses a dedicated **Web** Firebase app (`appId 1:183467627187:web:fd3f93867a2a54f90756c6`) + **reCAPTCHA Enterprise** site key `6LfKrQUt...` (`admin.html:177-185`). This is required because Firestore App Check is enforced per-app. **Confirmed present in code**; actual enforcement state is console-dependent (§2).
- **XSS:** all user-controlled strings rendered via `textContent` / `createTextNode` (helpers `span`/`setText`), **no `innerHTML` interpolation** anywhere; `confirm()`/toast render as plain text. Handles additionally constrained to `^[a-zA-Z0-9_-]+$` at the rule layer. **Confirmed — no obvious stored-XSS sink.** (Deep-dive will re-scan every render path incl. report `text`, `reasonLabel`, `pendingReason`.)
- **Action scope:** approve/dismiss/restrict/unflag/delete write only fields the admin rule allow-lists (`reports`: status/reviewedBy/reviewedAt/action; `users`: restricted/restrictedAt/restrictedBy; `posts`: via `isAdmin()` full-update). `markCrisisReviewed`/`approvePending`/`unflagPost` write extra post fields (`crisisReviewedBy`, `pendingApprovedBy`, `unflaggedBy`) — allowed because the post admin-update rule is unconstrained `isAdmin()`. **OK**, but the audit functions infer acting-admin from these client-written fields (spoofable only by an admin, low risk).
- **No secrets:** only public Firebase web config + public reCAPTCHA site key. **Confirmed.**

---

## 6. Preliminary observations queued for deep-dive (NOT yet confirmed bugs)

These surfaced during recon and will be traced/emulator-tested in the deep-dive pass. Listed so nothing is lost; severities are provisional.

1. **App Check enforcement state** (prod + staging, Firestore/Auth) — *cannot-verify from code*. Worst-case Critical (App Attest init without enforcement = open API). Run `checkAppCheck.js`. [§2]
2. **`users` read rule has no `isAdmin()` leg** — admin can't read unscrubbed user docs; restricted-users moderation tab degrades. Suspected, Medium (moderation completeness). [§4]
3. **`claimTriggerEvent` non-atomic + fail-open** counter drift (reply/repost/tag/breakup-stage triggers) — code self-documents a silent ±1 drift trap; `reconcileMyCounts` is the only repair. Verify it can't permanently desync. Suspected, Medium. [functions]
4. **`checkRateLimit` and `claimTriggerEvent` fail OPEN** on Firestore error — outage disables throttling + dedup simultaneously. Suspected, Medium. [functions]
5. **`deletedBy`/`deletedAt` author-writable on posts** → audit-attribution spoof. Suspected, Low. [§4]
6. **`onPostDeletedCleanupReposts` 5000-cap, no continuation** → >5000 reposts of one post orphan. Suspected, Low. [functions]
7. **Debug→prod plist fallback** is print-only, not fail-closed. Suspected, Low. [§2]
8. **`reconcileMyCounts` hardcoded prod URL** — staging build cross-calls prod. Suspected, Low. [§2/§4b]
9. **`FALLBACK_ADMIN_UIDS` hardcoded uid** for crisis paging (`index.js:2595`) + `checkAdminUid.js` seeded-vs-actual UID mismatch warning — verify the real prod admin doc is correct and no stale seeded admin retains access. Suspected, Medium. [functions/scripts]
10. **`notRestricted()` `!exists()` fall-through** — confirm it's neutralized for posts/replies by `hasConfirmedAdult()` (which requires the doc to exist) and can't be abused. Likely OK; verify. [rules]
11. **Stale rules tests** referencing cut DM/circle message-notification paths — confirm they're inert, not masking a regression. Low. [tests]
12. **`firestore.indexes.json` vs required queries** (admin.html composite indexes, feed `moderationStatus==live` + order) — not yet cross-checked. [config]
13. **Swift crash/memory pass** not yet done (force-unwraps, `try!`, threading). Listener lifecycle already mapped → **no leaks found** (all 12 listeners stored + removed). [Swift]
14. **Moderation engine false-pos/neg** on legitimate posts with names/numbers/URLs — `moderation.test.js` exists; deep-dive will assess accuracy + user-visible `pending_review` UX. [moderation]

---

# PART II — DEEP-DIVE FINDINGS

Deep-dive complete (full + live emulator). **Baseline: 129/129 rules tests + 131 moderation tests pass.** I added `firestore-tests/hostile-user.test.js` (23 new tests, all pass) executing the §3-F adversary scenarios; the three `assertSucceeds` cases there *confirm* finding **R-1** below.

## 7. Executive summary

Toska is, for a solo-built v1, an **unusually hardened** codebase: the rules file is the most carefully reasoned layer (every clause traceable, 129 regression tests), Firestore decode is uniformly defensive (no Codable crash paths), all 12 listeners tear down, optimistic writes roll back, and the 3 callables correctly enforce App Check + auth + rate limits. The security *perimeter* (can a hostile user read PII / enumerate the graph / self-escalate / forge a byline / spam pushes / write cut collections) **held against every emulator test**.

The real risks are not perimeter breaks — they are **(a) a content-moderation engine whose false-positive rate is high and whose reply path deletes legit user content permanently and silently**, **(b) eventual counter/data drift with no reconciler**, and **(c) one confirmed rule gap that lets any user forge admin audit-log entries.** None are remote-code or mass-data-exfil class; the worst-case security impact is audit-log integrity and a viewer-OOM crash.

**Top 5 fixes, in order:**
1. **M-1 (High):** Stop hard-deleting replies on a moderation hit. Reply PII/abuse → `validateReply`/`onReplyUpdated` **permanently delete** with no banner/appeal, and the PII detector's FP rate is high (bare first names, two-capitalized-words). Route replies through the same recoverable `pending_review` hold as posts. `functions/index.js:2042,2711`.
2. **M-2 (High):** Fix the two highest-volume moderation false-positives — the **year/number-list phone FP** (`moderation.js:519`, separator-collapse runs before year-strip) and **`looksLikeFullName`** flagging every media title/band/landmark (`moderation.js:118`). Both naturally occur in grief posts.
3. **R-1 (Medium, Confirmed via emulator):** Post **author-update** rule (`firestore.rules:718`) has a field denylist but **no `hasOnly` schema lock**, omitting `deletedBy`/`unflaggedBy`/`crisisReviewedBy` — any user can inject these on their own post and **forge `adminAuditLog` entries**, or inject arbitrary scratch fields a future trigger may trust. Add `hasOnly` + extend the denylist.
4. **F-1 (Medium):** `claimTriggerEvent` (reply/repost/tag/breakup-stage counters) is non-atomic and **fails open**; a failure after the claim drifts the counter permanently with **no reconciler** (`reconcileMyCounts` only fixes follower/following). Migrate these to `claimedTransaction`+`retry`, or add a scheduled recount. `functions/index.js:606`.
5. **F-2 (Medium):** No `cleanupLikesForUid` in the deletion cascade — a deleted user's like docs on **other** users' posts persist (GDPR residue + permanently inflated `likeCount`/`totalLikes`). Add the collection-group cleanup helper.

**Cannot-verify (needs console/prod access), worst-case-rated:** App Check **enforcement** state (init ≠ enforcement) in both projects — user's own records assert prod Firestore App Check is *Enforced*; **re-confirm before relying on it** (if off → Critical, makes every rule bypassable via direct REST with a stolen token). Plus prod-vs-staging rules/functions deploy parity and `scrubLegacyPII.js` completion %.

## 8. Findings table

| ID | Sev | Conf/Susp | Location | Issue | Impact | Fix |
|---|---|---|---|---|---|---|
| **AC-1** | Crit-if-off | Cannot-verify | both consoles | App Check **enforcement** not verifiable from code; init present (`toskaApp.swift:50`) | If unenforced, every rule bypassable via REST + stolen ID token | Run `checkAppCheck.js`; confirm Enforced on Firestore+Auth, both projects |
| **M-1** | High | Confirmed | `index.js:2042,2711` | Reply PII/abuse = **hard delete**, no banner/appeal; PII FP rate high | Silent permanent loss of legit user content + re-post loop | Route replies to recoverable `pending_review`; add reply pending banner |
| **M-2** | High | Confirmed | `moderation.js:519,118` | Year/number-list trips phone heuristic; `looksLikeFullName` flags titles/bands/places | Legit grief posts held; on replies, deleted | Strip years/small-nums before separator-collapse; downgrade bigram signal |
| **R-1** | Medium | **Confirmed (emulator)** | `firestore.rules:718` | Author-update has no `hasOnly`; denylist omits `deletedBy`/`unflaggedBy`/`crisisReviewedBy` | Any user forges `adminAuditLog` entries / injects arbitrary post fields | Add `hasOnly([...])`; add the 3 attribution fields to denylist |
| **F-1** | Medium | Confirmed | `index.js:606,1297` | `claimTriggerEvent` non-atomic + fail-open; no reconciler for reply/repost/tag/stage counts | Permanent monotonic counter drift | Use `claimedTransaction`+`retry` or scheduled recount |
| **F-2** | Medium | Confirmed | `index.js` (absent helper) | No `cleanupLikesForUid` for likes on others' posts | GDPR residue + inflated `likeCount`/`totalLikes` after deletion | Add collection-group like-cleanup keyed on like-doc id==uid |
| **R-2** | Medium | Confirmed | `firestore.rules:195` | `users` read rule has **no `isAdmin()` leg** | admin.html can't read unscrubbed user docs; restricted-users tab drops them | Add `|| isAdmin()` to the users read rule |
| **F-3** | Medium | Confirmed | `index.js:2344` | `checkRepeatOffenderPosts` `.limit(20)` with no `orderBy` | >20-flag offender evades auto-restriction (fail-safe direction) | Add `.orderBy('flaggedAt','desc')` before limit |
| **F-4** | Medium | Confirmed | `index.js:1934` | `validatePost` no try/catch; no-op on flag/crisis-only posts | Post stuck hidden up to ~30min (backstop covers) | Wrap in try/catch; explicit else → pending_review |
| **S-1** | Medium | Suspected | `ComposeView.swift:1042,1081` | GIF render: no host allowlist / size / frame cap on stored `gifUrl` | Hostile `gifUrl` OOM-crashes every viewer who scrolls past | Validate host (giphy/tenor) + cap bytes/frames before decode |
| **A-1** | Medium | Confirmed | `checkAdminUid.js:23`, `index.js:2595` | Seeded-vs-actual admin UID mismatch warning; inconsistent `FALLBACK_ADMIN_UIDS` | Admin lockout OR future account silently inherits admin | Run script vs prod; ensure `admins/` = real auth uid only; reconcile literal |
| **S-2** | Med-Low | Confirmed | `PostDetailView.swift:957,344` | Report `addDocument` fire-and-forget; "reported" alert shown even on denial | User believes report filed when rule denied it | Add completion handler; alert only on `error==nil` |
| **F-5** | Low-Med | Confirmed | `index.js:747,622` | `checkRateLimit` + `claimTriggerEvent` both fail **open** on Firestore error | Outage simultaneously drops throttling + dedup | Fail closed for `giphyProxy` (paid quota) at least |
| **F-6** | Low | Confirmed | `index.js:1538` | `onPostDeletedCleanupReposts` 5000-cap, no continuation | >5000 reposts of one post orphan | Queue continuation keyed by `originalPostId` |
| **E-1** | Low | Confirmed | `toskaApp.swift:67` | Debug build falls back to **prod** if staging plist missing (print only) | Dev work can hit prod data | Fail closed (assert) in Debug |
| **E-2** | Low | Confirmed | `ProfileView.swift:696` | `reconcileMyCounts` hardcoded prod URL | Staging build cross-calls prod (fails closed on token verify) | Derive URL from active project |
| **L-1** | Low | Confirmed | `index.js:2616` | Crisis-alert push embeds raw post text + handle in FCM body | Crisis content on admin lock screen (vs app's own push-privacy model) | Send neutral body; admin opens dashboard for content |
| **L-2** | Low | Confirmed | `index.js:2822,3826` | Logs `reportedHandle`/`reportedBy` to Cloud Logging | Handle↔report linkage persisted (anonymity model) | Log uids only, not handles |
| **L-3** | Low | Confirmed | `NetworkMonitor.swift:58` | `RateLimiter` per-post dicts grow unbounded per session | Minor memory growth (no crash) | Evict old entries |

## 9. Critical & High deep-dives

### M-1 — Reply moderation = silent permanent deletion (High, Confirmed)
`validateReply` (`index.js:2042`) and `onReplyUpdated` (`:2711`) call `containsNameOrIdentifyingInfo` and, on a hit, **`ref.delete()`** the reply — no hold, no banner, no appeal. The reply path has no `pending_review` state at all (only posts do). Meanwhile the detector's FP rate is high: emulator-validated trips include `I miss John`, `I cant stop thinking about David`, `My therapist Karen helped me`, `Last Night was the worst`, `The Notebook made me cry`, `I went to Central Park alone`, `We loved Pearl Jam concerts`. On a **post** these are a recoverable hold (author sees a `PendingReviewBanner`); on a **reply** they vanish with zero feedback. The code comment at `index.js:2643` claims replies are *soft-flagged* for PII — that is dead code, because `validateReply` deletes on the same create event first. **Fix:** give replies the same recoverable `pending_review` hold + a `PostDetailView` pending banner; at minimum, demote `looksLikeFullName`/bare-name signals to soft-flag-not-delete on replies.

### M-2 — Two high-volume moderation false-positives (High, Confirmed)
- **Year/number lists →** `moderation.js:519` collapses `(\d)[-.\s()]+(?=\d)` *before* the `\b\d{4,5}\b` year-strip; word boundaries are gone, so `I dated her in 2019 2020 2021 2022 2023` → a 20-digit run → phone-number hit. Any post listing several years/scores/durations separated by spaces is held. **Fix:** peel years/small numbers *before* the separator-collapse, or exclude whitespace from the collapse class around 4-digit tokens.
- **`looksLikeFullName` →** `moderation.js:118` flags any two consecutive Capitalized words not in a ~60-entry `SAFE_PROPER_NOUN_BIGRAMS` allowlist. Media titles, bands, landmarks, capitalized phrases all trip. A static allowlist cannot cover the long tail. **Fix:** require name/relationship context for the bigram signal, or downgrade it to soft-flag (compounds with M-1 since on replies it currently deletes).
- **False negatives (lower priority, deliberate evasions):** spelled-out digits (`five five five…`), spelled-out emails (`name at gmail dot com`), UK postcodes / non-US street words, spaced initials without dots (`J S`). The confusable/leet/reversal/fullwidth/combining-mark hardening for *obfuscated real names* is genuinely strong; the gap is plaintext-non-US / spelled-out contact info.

### R-1 — Author can forge admin audit entries (Medium, Confirmed via emulator)
Post **create** locks the schema with `hasOnly([...])` (`firestore.rules:565`), but post **update** (`:718`) only checks a field *denylist* — there is no `hasOnly`. The denylist (`:722-737`) lists counters + flag/moderation/pendingApproved fields but **omits `deletedBy`, `deletedAt`, `unflaggedBy`, `unflaggedAt`, `crisisReviewedBy`, `crisisReviewedAt`**. `hostile-user.test.js` confirms a non-admin author can `update({text:"hello", unflaggedBy:"some_admin_uid"})` on their own post (assertSucceeds). `auditPostModeration` (`index.js:3711`) fires on `unflaggedBy` newly appearing and writes an `adminAuditLog` entry attributing a `post.unflag` to the named uid → **any user can spam/forge the moderation audit trail and frame a specific admin.** They can also inject arbitrary scratch fields (`trustedByAdmin:true` — also assertSucceeds). **Fix:**
```
allow update: if ((isAuth() && resource.data.authorId == request.auth.uid)
    && request.resource.data.text is string
    && request.resource.data.text.size() > 0 && request.resource.data.text.size() <= 2000
    && request.resource.data.diff(resource.data).affectedKeys()
         .hasOnly(['text','editedAt','gifUrl','tag'])   // <- add: lock the author-editable set
  ) || isAdmin();
```
(Admins keep the unconstrained `isAdmin()` leg for dashboard writes.)

### AC-1 — App Check enforcement (Critical if off; Cannot-verify from code)
App Attest is initialized (`toskaApp.swift:50`) and all 3 callables set `enforceAppCheck:true`, but **document-trigger writes and direct Firestore reads/writes are gated only by rules** — if Firestore App Check enforcement is *not* actually flipped to Enforced in the console, a stolen/minted ID token + direct REST call bypasses App Attest entirely (the rules still apply, but App Check is the layer that stops non-app clients). User records assert prod is Enforced; `checkAppCheck.js` exists to confirm. **This is the single highest-leverage thing to verify before launch**, in both `toska-4ebf4` and `toskastaging`, for Firestore and Auth.

## 10. Hostile-user analysis (§3-F) — emulator results

All run against `firestore.rules` in the emulator (`hostile-user.test.js`, 23/23 pass):

| Scenario | Result | Cited clause |
|---|---|---|
| (a) read others' `private`/PII | **Denied** | `private/{docId}` owner-only `:495` |
| (b) enumerate social graph | **Denied** | `following`/`followers` read `isOwner` `:265,284` |
| (c) write/edit/delete others' docs | **Denied** | per-path author/owner gates |
| (d) inflate own counters | **Denied** | counters in update denylist `:244` |
| (e) spam notifications/pushes | **Denied** | per-type `exists()` + deterministic notifId + `fromHandle` pin `:367` |
| (f) bypass blocking | **Denied** | block `!exists()` on follow/like/reply/save/repost |
| (g) read `reports`/`admins`/`adminAuditLog`/`processedTriggerEvents` | **Denied** | `:954,977,986,997` |
| (h) self-grant admin / self-unrestrict / self-confirm-adult / self-publish live | **Denied** | `admins write:false`; restriction+confirmedAdult+moderationStatus denylists |
| (i) forge byline (post/reply/repost/notif `fromHandle`) | **Denied** | authorHandle/originalHandle/fromHandle pins to user-doc handle |
| (j) write cut collections (`conversations`/`feelingCircles`/`finalPosts`) + `meta`/`dailyMoment` | **Denied** | `if false` / `write:false` |
| (k) callable abuse (App Check/auth/rate-limit bypass, giphy SSRF, reconcile cross-project) | **Denied** (code-traced) | `enforceAppCheck`, manual verify, whitelisted `mode`, bounded `limit`, encoded `q` |
| **Audit-attribution injection on own post** | **ALLOWED — finding R-1** | author-update missing `hasOnly` `:718` |

## 11. Cloud Functions audit (summary; details in §9 + findings table)
- **Atomicity/dedup:** `claimedTransaction`+`retry` (likes/follows) is correct & idempotent; `claimTriggerEvent` (replies/reposts/tags/stage) is non-atomic + fail-open with no reconciler → **F-1**. `reconcileMyCounts`' transactional recount is clobber-safe (Confirmed).
- **Callables:** `confirmAdult`/`giphyProxy`/`reconcileMyCounts` all enforce App Check + auth + rate-limit in correct order; giphy SSRF/param-injection/key-leak hardened; reconcile method/CORS/cross-project all correct (Confirmed).
- **Moderation pipeline:** start-hidden model closes the visibility window for current clients (`setPostLive` is the sole `'live'` promoter, refuses to override `pending_review`); anti-recursion guards correct; **F-3** (offender evasion >20 flags) and **F-4** (no try/catch) are the gaps.
- **Deletion cascade:** terminates (bounded + resume queues); follow-edge decrements correctly route through triggers; gaps are **F-2** (likes-on-others not cleaned) and **F-6** (>5000 reposts).
- **Audit attribution:** inferred from client-written fields — combined with **R-1** this is forgeable by any user, not just admins.
- **Secrets/logging:** no committed secrets; `GIPHY_KEY` via Secret Manager + scrubbed; moderation.js logs no post text. Minor: **L-1**/**L-2** leak content/handles to push/Cloud Logging.

## 12. Edge-case matrix (per flow)
| Flow | Handled | Unhandled / Wrong |
|---|---|---|
| nil/empty/long text | ✅ trimmed, capped client+rule | — |
| emoji/RTL/ZWJ/combining in posts | ✅ canonicalized for moderation | — |
| handle charset abuse | ✅ no user-facing handle editor; generator always valid | — |
| rapid double-tap (post/like/follow) | ✅ in-flight guards + deterministic repost IDs | — |
| pagination boundaries / cursor drift | ✅ dedup Set + fixed cursor (`FeedViewModel:708`) | — |
| backgrounding mid-async | ✅ uid re-checked after await | — |
| network loss mid-write | ✅ rollback + NetworkMonitor guard | report write (**S-2**) shows false success |
| malformed/partial Firestore doc | ✅ all hand-decoded `as? ?? default` | — |
| large GIF | — | **S-1** no cap → viewer OOM |
| held post (author view) | ✅ `PendingReviewBanner` | no in-app appeal link |
| **held/deleted reply** | ❌ | **M-1** silent permanent delete, no feedback |
| crisis post held | partial | help resources shown only at compose-time, not on the server-held banner |

## 13. Data-integrity report
- **Write-vs-rule-vs-decode shapes agree** for posts/replies/notifications/reports (rule `hasOnly` ⊇ client writes; client decode defaults every field). The one shape asymmetry is **R-1** (update has no `hasOnly`).
- **Counter desync:** follower/following/like/totalLikes are atomic+reconcilable; **reply/repost/tag/breakup-stage counters can drift permanently (F-1)** with no reconciler. `reconcileMyCounts` covers only follower/following.
- **Half-write windows:** post create → validate/moderate triggers leave a sub-second hidden window (closed for current clients by start-hidden). Reply create fires validate+moderate+count triggers independently — a moderation delete races the count increment but `onReplyDeletedUpdateCount` compensates.
- **serverTimestamp** used everywhere ordering/dating matters (Confirmed across all write sites); rules pin `createdAt == request.time` on posts/replies/drafts/reports/reflections/notifications.
- **Deletion residue:** **F-2** (likes-on-others), **F-6** (>5000 reposts), and intentionally-retained reports-against-user are the known residues.

## 14. Crash & memory report
**Exceptionally clean.** Full inventory: 1 `try!` (constant regex, safe), 0 `as!`/force-cast, 0 reachable `fatalError`, 0 `.first!`/`.last!`, 2 real `!` (guarded Unicode scalar math, safe), 2 `URL(string:)!` (literal constants). **No crash path reachable from Firestore/network/user input** — all decode is `as? ?? default`; threaded reply build is cycle-guarded (`PostDetailView:1335`). Threading disciplined (`@MainActor` + `NSLock` on `BlockedUsersCache`); **no listener leaks** (all 12 stored + removed); no retain cycles (`[weak self]` in all class listeners/timers). The only memory item is **L-3** (RateLimiter dict growth) and the only data-driven crash is **S-1** (GIF OOM).

## 15. Two-environment & deployment review
- Release **cannot** load staging (`#if DEBUG` compiles it out) — Confirmed. Inverse: Debug→prod fallback on missing plist (**E-1**, Low).
- Rules auto-deploy to **staging** via CI (WIF, no stored key — well configured); **prod is manual**. Prod-vs-`main` parity and **functions** deploy parity to both projects are **cannot-verify from code** — confirm via `firebase deploy` history / console.
- App Check enforcement per project: **AC-1**, cannot-verify.
- Maintenance scripts carry prod guards (`--allow-prod`, `--yes-this-is-prod`, dry-run defaults) — good. **A-1**: reconcile the admin UID before launch.
- Staging PII (real vs `seedAppStoreDemo.js` synthetic): unverified — confirm staging holds no real user PII.

## 16. Open questions / cannot-verify (what to provide)
1. **App Check enforcement** state, both projects, Firestore+Auth — run `node functions/checkAppCheck.js` with prod ADC, paste output. (AC-1)
2. **Prod rules + functions** currently match `main`? (`firebase deploy --only firestore:rules --dry-run`, function deploy history.)
3. **`scrubLegacyPII.js`** run status / % of user docs still carrying legacy PII (drives R-2 severity).
4. **Prod `admins/` collection** contents — exactly the real auth uid? (run `checkAdminUid.js`). (A-1)
5. Staging dataset: real PII or synthetic?

## 17. Recommended tests (prioritized)
1. **Rules-emulator (highest value, harness exists):** keep `hostile-user.test.js`; add a regression for R-1 *after* fixing it (author-update `hasOnly`). Run both suites in CI against **both** projects' rules, not just staging.
2. **Function unit tests — ✅ NOW BUILT** (`functions-tests/`, 14 passing, wired into CI): the M-1 reply-hold transitions (`setReplyPendingReview`/`setReplyLive`), F-2 like cleanup + capHit, F-1 `claimedTransaction` idempotency + rollback-on-error, F-5 rate-limit window, and deletion-cascade termination. *Still worth adding later:* moderation severity-mapping at the trigger level (post-hold vs reply-delete asymmetry, soft-vs-explicit crisis routing) — the pure detector is tested but the trigger-level action mapping isn't.
3. **Moderation corpus test:** the FP/FN tables in §9 as fixtures — lock the year-list + `looksLikeFullName` fixes and prevent regressions.
4. **iOS (none exist):** a decode-fuzz test feeding malformed Firestore docs to the post/reply/notification decoders (assert no crash); a GIF-render bound test for S-1.

---

# PART III — REMEDIATION STATUS (2026-06-08)

All fixes below verified: **142 moderation tests + 153 rules tests (129 baseline + 24 hostile-user) pass; `node --check` clean on functions.**

| ID | Status | What changed |
|---|---|---|
| **R-1** | ✅ Fixed + emulator-verified | `firestore.rules` post author-update now `hasOnly(['text','editedAt'])`; hostile tests flipped to assert denial (pass). |
| **R-2** | ✅ Fixed | `users` read rule gained an `isAdmin()` leg. |
| **M-2** | ✅ Fixed + 11 regression tests | `moderation.js`: pre-collapse strip of year/number lists; `looksLikeFullName` skips common-English title bigrams unless a token is a known first name. FPs cleared, real names + intl phones still caught. |
| **F-1** | ✅ Fixed | 11 counter triggers migrated `claimTriggerEvent` → atomic `claimedTransaction`+`retry:true` (read-inside-tx short-circuit on deleted parent). Permanent drift closed. |
| **F-2** | ✅ Fixed | New `cleanupLikesForUid` walks `liked`/`likedReplies` indices, deletes third-party like docs (fires count-correction triggers) + index entries; wired into cascade + resume dispatch. |
| **F-3** | ✅ Fixed | `checkRepeatOffenderPosts` now `orderBy('flaggedAt','desc')`; composite index added. |
| **F-4** | ✅ Fixed | `validatePost` self-applies the flag/crisis hold (`holdReconciledPost`) instead of depending solely on `onPostCreated`. |
| **F-5** | ✅ Fixed | `checkRateLimit` gained `failClosed`; `giphyProxy` passes `true` (paid quota fails closed). |
| **F-6** | ✅ Fixed | `clearRepostsOfPost` helper + `repostCleanupQueue` + scheduled `resumeRepostCleanup` drains >5000-repost orphans. |
| **L-1** | ✅ Fixed | Crisis-alert push body neutralized; raw text + handle removed from payload. |
| **L-2** | ✅ Fixed | `notifyAdminsOfNewReport` logs `reportedUserId` instead of `reportedHandle`. |
| **S-1** | ✅ Fixed | GIF render: Giphy host allowlist + 8 MB byte cap + 120-frame cap (`ComposeView.swift`). |
| **S-2** | ✅ Fixed | Report write uses completion handler; success alert only on `error==nil` (`PostDetailView`/`OtherProfileView`). |
| **E-1** | ✅ Fixed | Debug build now fails closed (`fatalError`) on missing staging plist. |
| **E-2** | ✅ Fixed | `reconcileMyCounts` URL derived from `FirebaseApp.options.projectID`. |
| **L-3** | ✅ Fixed | `RateLimiter` prunes entries older than its window. |
| **AC-1** | ⚠️ **CONFIRMED GAP — High** | `checkAppCheck.js` (2026-06-08): `enforcementMode=(unset)` for firestore, identitytoolkit, AND storage → App Check is **UNENFORCED** in prod (refutes the prior "ENFORCED" assumption). Callables are still protected (`enforceAppCheck:true` + manual verify); direct Firestore is protected by rules only. **Fix = console action, carefully:** verify unverified-request rate ≈ 0 + admin.html reCAPTCHA working + debug tokens registered, THEN flip Firestore/Auth to Enforced. Enforcing naively locks out legit users. |
| **A-1** | ✅ Resolved | `checkAdminUid.js` (2026-06-08): real admin UID `alcxPIqLQZcTIwF5wjJMkK1yPlW2` matches the seeded `admins/{uid}` (role:admin). No orphan, no lockout. Residual Low: `FALLBACK_ADMIN_UIDS` literal (`index.js:2595`, `fKcz0r7…`) ≠ real admin uid — crisis-alert push would misroute; seed `system/crisisAlertRecipients` or fix the literal. |
| **M-1** | ✅ Built (all layers) + rules emulator-verified; ⚠️ iOS needs your build/test | Full recoverable pending-review hold for replies. Server, rules, indexes, migration, and admin dashboard done and tested; the SwiftUI thread changes can't be compiled here — build + manual-test on your side. |

## M-1 — the reply pending-review hold (BUILT)

PII replies are no longer hard-deleted. They're held at `moderationStatus == "pending_review"`: hidden from other readers, shown to their author with an "under review" banner, and rescuable by an admin. Hard-delete is retained only for low-false-positive abuse (hate/threat/sexual/harassment). Implemented across all five layers:

1. **Functions** (`functions/index.js`): `setReplyPendingReview` + `setReplyLive` helpers; `validateReply` and `onReplyUpdated` PII paths now HOLD instead of delete; clean replies are promoted to `"live"` (so they're queryable, mirroring `setPostLive`); `applyReplyModeration` routes PII/link → hold, abuse → delete.
2. **Rules** (`firestore.rules`): reply read gate (`moderationStatus=='live' || authorId==me || isAdmin`); reply update anti-self-approve denylist + admin leg; reply delete admin leg; collection-group replies admin leg (for the dashboard).
3. **Indexes** (`firestore.indexes.json`): replies `(moderationStatus, createdAt)`, `(authorId, moderationStatus)`, and collection-group `(moderationStatus, pendingDetectedAt DESC)`.
4. **Migration** (`functions/backfillReplyModerationStatus.js`): stamps `moderationStatus:"live"` on every existing reply (paginated, dry-run default).
5. **Client** (`PostDetailView.swift`, `ReplyDetailView.swift`): the thread reads with two rule-safe queries (live + the author's own) merged chronologically; held replies render `PendingReviewBanner` with the interaction row suppressed; `ThreadedReply` gained `createdAt`/`isPending`/`pendingReasonLabel`.
6. **Admin** (`docs/admin.html`): new "pending replies" tab — collection-group query on held replies with approve/remove/restrict-author actions.

**Rules verification:** 9 new emulator tests in `hostile-user.test.js` (held reply hidden from third party, visible to author + admin, author can't self-approve, admin can approve, legacy reply still readable) — all pass (162 total).

### Edge-case hardening (2026-06-09) — 3 fixes from the adversarial pass
- **#1 `replyCount` inflation FIXED.** A held reply was counted at create but stayed hidden, letting a user inflate any post's `replyCount` by spamming held PII replies. New `onReplyVisibilityCountAdjust` trigger adjusts the count on the visible↔hidden transition (held −1, approved +1), `onReplyDeletedUpdateCount` skips an already-hidden reply, and create/delete handle the ends — atomic + deduped via `claimedTransaction` (same discipline as F-1). 6 new functions tests.
- **#3a repost-of-held-reply FIXED.** The reply-repost rule now requires the original reply's `moderationStatus == 'live'` — can't republish hidden content. 2 new rules tests.
- **#3b held-reply liker list FIXED.** The reply-likes read rule now gates on the reply's own `moderationStatus` (live / own-author / admin), mirroring the reply read rule. 3 new rules tests.
- **#2 link-mislabel FIXED.** `validateReply`/`onReplyUpdated` now label a URL-bearing held reply `abuse_link` (not `pii`) via a `containsURL` discriminator (bare domains were already held + labelled correctly by `onReplyCreatedModerate`). 2 new tests.
- **A-1 fallback admin uid FIXED.** `FALLBACK_ADMIN_UIDS` corrected from a test-account uid to the real prod admin (`alcxPIqLQZcTIwF5wjJMkK1yPlW2`) so crisis pages route correctly even before `system/crisisAlertRecipients` is seeded.
- **Deliberately left as documented Low (with reason):** (i) a held reply still triggers a *generic* "someone replied" notification — the push can't be cleanly suppressed (`sendPushNotification` races the hold), so deleting the in-app entry would create push-without-in-app inconsistency; (ii) `enrichReplyNotification` previews the actor's *newest* reply (imprecise but never leaks held text) — fixing needs the client to carry the specific `replyId`, disproportionate to a Low cosmetic; (iii) rate-limited held-reply admin-queue noise.
- The critical property — **a tampered client cannot self-stamp a reply's `moderationStatus`** to bypass the hold — is emulator-verified (`hasOnly` lock). **Test totals: 172 rules + 142 moderation + 58 functions = 372.**

### M-1 verified end-to-end on deployed STAGING (2026-06-09)
Deployed the M-1 rules + reply functions + indexes to **toskastaging** and ran the reply migration (10 existing replies → live). Then a real-authenticated-user E2E (client SDK, `salinarotess+nice@gmail.com`) against deployed staging confirmed: a PII reply ("my ex Sarah Johnson") is **HELD** by the deployed `validateReply` (`moderationStatus=pending_review`, `pendingReason=pii`) — not deleted; a clean reply is promoted to **live**; query A (`moderationStatus==live`) **excludes** the held reply; query B (`authorId==me`) **includes** it (both indexes built, queries rule-safe in prod conditions); admin-approve flips it back to live and it rejoins the thread. Plus: app **compiles clean** (0 errors) and **launches clean** (UI launch test 4/4) on an iPhone 17 simulator. Prod untouched.

### Adversarial re-review (2026-06-08, independent eyes on rules + functions)
Rules: R-1, R-2, and all five M-1 legs **confirmed correct and Firestore-list-query-safe** — no held-reply leak through read / collection-group / update / delete. Functions: F-1 (all 11 trigger conversions), F-2, F-4, F-5, F-6, L-1, L-2, and `__test` **confirmed correct** (no counter double-count/loss, no orphaned deletion, no clean-reply-invisible in the happy path, `__test` inert in deploy). Findings:
- **FIXED — reply-moderation reliability gap.** `validateReply`/`onReplyCreatedModerate`/`onReplyUpdated` were no-retry, and replies have no `reconcilePostVisibility` backstop — so a transient Firestore error mid-moderation could leave a reply field-less, and a field-less *clean* reply is invisible to everyone but its author forever. Added `retry: true` (handlers are idempotent). 
- **Low, documented, not fixed:** (d) the reply-*likes* read rule gates on parent-post visibility, not the reply's own `moderationStatus` — a held reply's liker list is readable *if* you know the auto-generated replyId (not discoverable through any rule-permitted path, so not currently exploitable; closing it would add a `get()` to every reply-like read); (e) `enrichReplyNotification` previews the actor's *newest* reply, so if their newest is clean but an older one was held, the suppression previews the clean reply's text instead — not a PII leak (the held text is never shown), just imprecise; pre-existing.

### M-1 follow-up checks (post-build review)
- **Held-reply notification leak — FOUND + FIXED.** `enrichReplyNotification` backfilled a reply's text into the post author's in-app notification preview with no `moderationStatus` check — so a held PII reply's text reached the recipient even though the reply was hidden. Fixed (suppress the preview for `pending_review` replies; regression-tested). The push body was already generic (no leak there); repost-of-held-reply can't be exploited (the rule's text-match gate requires reading the hidden text).
- **Known-minor, NOT fixed (Low, documented):** (a) a held reply still counts toward the post's `replyCount` (other users see a count including a reply they can't see) until approved/removed — cosmetic; (b) a held reply's `likes` subcollection is still readable to anyone who can see the parent post (liker uids only, no text; held replies are rarely liked); (c) the post author still gets a generic "someone replied" notification/push for a held reply → tapping shows the thread without it.

### ⚠️ DEPLOY ORDER (must be followed — out of order breaks production)
1. **`node functions/backfillReplyModerationStatus.js --dry-run`** then without `--dry-run` — backfill ALL existing replies to `"live"` FIRST. (If the client's `where moderationStatus == "live"` deploys before this, every existing reply vanishes from threads.)
2. **`firebase deploy --only firestore:indexes`** — wait for the new reply indexes to finish building.
3. **`firebase deploy --only firestore:rules,functions`** — rules + functions together.
4. **Push `docs/admin.html`** (GitHub Pages).
5. **Build, manual-test, and ship the iOS client.**

### What you must verify on the iOS side (can't compile here)
- The app builds (I added `createdAt`/`isPending`/`pendingReasonLabel` to `ThreadedReply` — all three call sites updated, but confirm a clean build).
- Post a reply containing a name (e.g. "I miss Sarah Johnson") → it shows to you with the "under review" banner, is NOT visible from a second account, and the admin pending-replies tab can approve it back into the thread.
- Normal replies still appear instantly (the author's-own query covers the pre-promotion window, so no flicker).
- `ReplyDetailView` drill-down still loads (it shows live children only; held replies surface in the main thread).

---
*Artifacts produced: `AUDIT.md`; `firestore-tests/hostile-user.test.js` (33 passing, incl. M-1 reply-hold); 11 new `moderation.test.js` cases; **`functions-tests/` — new emulator-backed Cloud Functions unit suite (14 passing), wired into CI**; `functions/backfillReplyModerationStatus.js` (M-1 migration); reply composite indexes. Backend fixes in `firestore.rules`, `functions/index.js`, `functions/moderation.js`, `firestore.indexes.json`, `docs/admin.html`, `.github/workflows/ci.yml`; client fixes in `ComposeView`, `PostDetailView`, `ReplyDetailView`, `OtherProfileView`, `ProfileView`, `toskaApp`, `NetworkMonitor`. A test-only `module.exports.__test` was added to `functions/index.js` (inert in deploy — Firebase only deploys CloudFunction exports). No production data touched; no deploy performed.*
