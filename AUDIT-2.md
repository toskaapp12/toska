# Toska — Security Re-Review (AUDIT-2)

**Scope:** Independent adversarial re-review of the remediation recorded in `AUDIT.md` (`f9ccf13`, branch `main`).
**Date:** 2026-06-09
**Method:** Every prior fix re-traced to source (line-cited); the M-1 five-layer feature walked end-to-end; rules threat-modeled as the *sole* perimeter (App Check enforcement is OFF); the running test suites executed against the Firestore/Auth emulators; one new rules finding proven with a throwaway emulator test before reporting.

**Headline:** The remediation is real. Every backend fix (F-1…F-6, R-1, R-2, M-1, A-1) and every client fix (S-1, S-2, E-1, E-2, L-3) is present in the code and behaves as described — I confirmed the F-1 atomic-counter rewrite, the F-2 like-cleanup wiring, the M-1 reply-hold state machine (incl. `replyCount` integrity under hold↔live↔remove), and the R-1 post lock independently. The security *perimeter* still holds.

The re-review nonetheless found **10 new items**, two of them Medium and rule-level. The most important pattern: **the R-1 fix was applied to posts but not to the structurally-identical reply `update` rule** — and M-1 just turned replies into a moderated, audit-relevant surface, so that gap now matters. Separately, a verification-integrity problem: **the `hostile-user.test.js` suite — which contains the R-1 regression test and every M-1 anti-bypass assertion — is orphaned and never runs**, locally or in CI, contrary to AUDIT.md's "172 rules tests, all in CI."

---

## 1. Verification table — prior findings

Legend: ✅ confirmed fixed (re-traced) · ⚠️ fix present but incomplete · 🔁 regressed · ℹ️ unchanged-by-design.

| ID | Claimed fix | Verdict | Evidence / caveat |
|---|---|---|---|
| **R-1** | Post author-update `hasOnly(['text','editedAt'])` | ✅ | `firestore.rules:747`. **Proven**: my emulator control case shows `update({text, trustedByAdmin:true})` on a post is **denied**. But the *regression test* lives only in the orphaned suite — see **N-8**. |
| **R-2** | `users` read gains `isAdmin()` leg | ✅ | `firestore.rules:202-206`. Admin can read un-scrubbed user docs. |
| **M-2** | Year/number pre-strip; `looksLikeFullName` English-bigram guard | ✅ (tests green) | `moderation.js` fixes present; **142/142 moderation tests pass**. Not independently re-red-teamed — the detector corpus is large; I relied on the passing suite. |
| **F-1** | 11 counter triggers → atomic `claimedTransaction`+`retry` | ✅ | `index.js:721` (`claimedTransaction`). **16** trigger bodies now use it (audit's "11" undercounts the later reply-visibility/like/repost pairs); claim lands inside the tx (`:738`), re-throws on commit failure, per-`subKey` dedup. No counter trigger still uses old `claimTriggerEvent`. Read-target-first cannot drop a legit count (missing parent = no counter). |
| **F-2** | `cleanupLikesForUid` walks indices + third-party like docs | ✅ | `index.js:336`, wired into cascade (`:873`) + resume dispatch (`:3514`). Cascade runs after auth user is gone, so the "like created mid-cleanup" race is bounded. |
| **F-3** | `checkRepeatOffenderPosts` `orderBy('flaggedAt','desc')` | ✅ | `index.js:2532`. |
| **F-4** | `validatePost` self-applies hold (`holdReconciledPost`) | ✅ | `index.js:2054-2064`; else-branch covered; `setPendingReview` idempotent; `reconcilePostVisibility` backstop retained. Caveat: `validatePost` body still not wrapped in a single try/catch, but each inner write is guarded — acceptable. |
| **F-5** | `checkRateLimit` `failClosed`; `giphyProxy` passes `true` | ✅ | `index.js:784/813`, `:3656`. `reconcileMyCounts`/`confirmAdult` intentionally fail open. |
| **F-6** | `clearRepostsOfPost` + queue + `resumeRepostCleanup` | ✅ | `index.js:1625/3455`. Continuation re-queries and terminates (deleted reposts drop out each pass). |
| **S-1** | GIF host allowlist + 8 MB + 120-frame caps | ✅ | Guards on the **shared render path** `StableGifPreview`/`GifLoadGuard` (`ComposeView.swift:1002-1113`), used by Feed + PostDetail + replies. Host checked **before** download. A hostile `gifUrl` written directly to Firestore is rejected at the host gate. Caveat: byte cap applied after full buffer (acceptable — host pinned to Giphy). |
| **S-2** | Report success alert only on `error==nil` | ✅ | `PostDetailView.swift:983`, `OtherProfileView.swift:565`, `ReportSheet.swift:1636`. |
| **E-1** | Debug fails closed (`fatalError`) on missing staging plist | ✅ | `toskaApp.swift:73`. |
| **E-2** | `reconcileMyCounts` URL from `options.projectID` | ✅ | `ProfileView.swift:700-704`. |
| **L-1** | Crisis-alert push body neutralized | ✅ | Push bodies generic & content/handle-free for all types (`index.js:1103-1135`). |
| **L-2** | Logs `reportedUserId`, not handle | ✅ | Confirmed in `notifyAdminsOfNewReport`. Residual admin-only attribution issue → **N-10**. |
| **L-3** | `RateLimiter` prunes by window | ✅ | `NetworkMonitor.swift:67-76`. |
| **A-1** | `FALLBACK_ADMIN_UIDS` = real prod admin | ✅ | `index.js:2791` = `alcxPIqLQZcTIwF5wjJMkK1yPlW2`. |
| **M-1** | Reply pending-review hold across 5 layers | ⚠️ | Functions/rules/indexes/migration **correct and verified** (incl. `replyCount` integrity, held-text notification suppression `index.js:3243`, repost-of-held `#3a`, liker-list `#3b`). **Incomplete on the client drill-down** → **N-3**. And the analogous reply-`update` lock was never added → **N-1**. |
| **AC-1** | App Check enforcement | 🔁 (still off) | Unchanged; correctly recorded as an open console action. Full attack-surface enumeration in §3. |

---

## 2. New findings

Format: **ID · Severity · Layers** — summary, repro, fix. "New" = not in AUDIT.md.

### N-1 · Medium · rules — Reply `update` has no `hasOnly`: byline spoof + arbitrary-field injection (the R-1 class, not applied to replies)
The post `update` rule got `hasOnly(['text','editedAt'])` for R-1. The structurally-identical **reply** `update` rule (`firestore.rules:835-845`) still uses only a *denylist* and **no `hasOnly`**, and does **not re-pin `authorHandle`**. So a reply author can change fields the create-rule deliberately locks.

**Repro (proven on the emulator):** as the reply's author,
- `update({text:"…", authorHandle:"handle_victim"})` → **succeeds** → the reply now renders under the victim's byline ("@victim replied: …") for the post author and every thread reader. This is exactly the spoofing the create-time `authorHandle` pin (`:821`) defends against, re-opened via update.
- `update({text:"…", trustedByAdmin:true})` → **succeeds** → arbitrary scratch field injected onto a reply doc (the R-1 "future trigger may trust this" risk). The identical injection on a *post* is correctly **denied** (R-1).

The held-reply self-approve vector is *not* exploitable (the denylist does include `moderationStatus`/`pendingReason`/`pendingApproved*`), so this is byline-integrity + field-injection, not a moderation bypass — but it's the same wedge R-1 closed, on a surface M-1 just made audit-relevant. **(App Check off makes it trivially reachable; even on, a tampered legit-app client reaches it.)**

**Fix:** mirror R-1 — `… && request.resource.data.diff(resource.data).affectedKeys().hasOnly(['text','editedAt'])` on the author leg (keep the denylist as defense-in-depth; keep the `isAdmin()` leg). Add the regression to a suite that actually runs (see N-8).

### N-2 · Medium · functions + admin.html — Single-post deletion orphans the post's `replies`/`likes`/`reflections` subtrees (incl. held PII replies)
There is **no `onDocumentDeleted("posts/{postId}")` trigger that deletes the post's own subcollections.** The only such trigger, `onPostDeletedCleanupReposts` (`index.js:1651`), clears reposts *pointing at* the post — never its own `replies`/`likes`/`reflections` (verified by reading it + full trigger inventory). The post's subtree is swept **only** by the account-deletion cascade (`cleanupPostsForUid`) and `cleanupExpiredPosts`.

The iOS author single-delete masks this by cleaning subcollections client-side (`PostDetailView.swift:1004`) — but that path is best-effort (abandoned if the app is killed) and, crucially, **`docs/admin.html` `removePost`/`deletePost` delete only the post doc** (admin.html:867/930). So **every admin moderation removal** (from reports, flagged, crisis, and the new pending tabs) orphans the full reply/like/reflection subtree forever (parent gone → no re-fire, no cascade).

**Impact:** primarily storage/cost residue, but it is a **GDPR/anonymity concern specifically because of M-1** — held `pending_review` replies (which may contain real PII, the whole reason the hold exists) persist indefinitely under a deleted parent. Two independent sub-reviews (functions + admin.html) reached this conclusion.

**Fix:** add `onDocumentDeleted("posts/{postId}")` that `deleteCollection`s the post's `replies` (and their `likes`), `likes`, `reflections` with a resume-queue for >cap (the `deleteCollection` helper already exists at `index.js:34`; model the queue on F-6's `repostCleanupQueue`). Don't rely on the client.

### N-3 · Low-Medium · client — M-1 incomplete: held reply renders as a normal post in the `ReplyDetailView` drill-down
The thread list correctly banners + suppresses held replies (`PostDetailView.swift:1811`), but the whole reply row is a `NavigationLink` to `ReplyDetailView` **with no `isPending` guard** (`:1758`). `ReplyDetailView` seeds from the passed reply but its child listener filters `moderationStatus == "live"` (`ReplyDetailView.swift:322`), so a held focal reply shows **no "under review" banner, a working composer, and live like stats**, and its focal refresh never fires. Scope-limited (a held reply is visible only to its own author, so this is a self-consistency leak, not third-party exposure), but it breaks the M-1 model exactly where AUDIT.md said "ReplyDetailView made rule-safe." **Fix:** suppress navigation (or render the banner + hide composer/interactions) when `reply.isPending`.

### N-4 · Medium · client / on-device — Grief drafts stored in plaintext UserDefaults, not Keychain
Compose drafts ("the conversation you can't bring yourself to have") and per-post reply drafts are persisted in `@AppStorage`/`UserDefaults`: `composeDraftText`/`composeDraftTag` (`ComposeView.swift:27`) and `toska_replyDraft_<postId>` (`PostDetailView.swift:563`). UserDefaults plists are unencrypted at rest (readable on an unlocked/jailbroken device or from an unencrypted backup). Secrets are otherwise handled correctly (Apple auth code in Keychain w/ `AfterFirstUnlock`; Firebase tokens SDK-managed). **Fix:** store drafts in Keychain or an encrypted store given the explicit "partner could see / recognize" threat model.

### N-5 · Medium · client / on-device — No app-switcher privacy blur on backgrounding
No privacy screen/blur/redaction when the app backgrounds; `scenePhase` is used only for badge/theme (`ContentView.swift:185`). The iOS app-switcher snapshot captures whatever sensitive grief content (post text, drafts, mood) is on screen, fully legible. Notable for an app whose entire premise is private content. **Fix:** overlay a blur/redaction view on `.inactive`/`.background`.

### N-6 · Low · client / on-device — "Copy text" leaves grief text on the system clipboard with no expiry / not local-only
`ShareCardView.swift:271` writes `UIPasteboard.general.string` with no `expirationDate` and no `.localOnly` — copied grief text persists on the system pasteboard indefinitely and can sync to other Apple devices via Universal Clipboard. The image-share path already does this right (`+300s` expiry, `:803`). **Fix:** mirror the image path's options on the text copy.

### N-7 · Low · client — Feed like-count flicker (missing listener-suppression that PostDetailView has)
`PostDetailView.toggleLike` uses a `suppressListenerUntil` window to absorb the snapshot echo (`PostDetailView.swift:813/830`); `FeedPostRow.toggleLike` (`FeedView.swift:1291`) has no such window, and `onChange(of: likes)` unconditionally overwrites the optimistic count (`:1229`). A re-delivery in the ~1-2 s before the Cloud Function increments the server count snaps the count back then forward → visible flicker. Eventually consistent, no data/crash issue. **Fix:** mirror the suppression window in `FeedPostRow`.

### N-8 · Low (but verification-integrity) · tests/CI — `hostile-user.test.js` is orphaned: the R-1 + M-1 anti-bypass tests never run
`firestore-tests/package.json` `test:rules` runs **only `firestore.test.js`**; `npm test` = `moderation.test.js` + `firestore.test.js`. **`hostile-user.test.js` is referenced by no npm script and imported by nothing** — it does not execute locally or in CI. That file holds the R-1 regression assertion and the M-1 held-reply/anti-self-approve/`#3a`/`#3b` rules tests; `firestore.test.js` (the suite that *does* run) has **no** assertion for the post-update `hasOnly` lock (only a comment). So a future regression to any of those security-critical rules would pass CI silently. Actual executed totals: **129 rules + 142 moderation + 60 functions = 331** — not the "172 rules / 372–374 total, all in CI" AUDIT.md claims. **Fix:** add `hostile-user.test.js` to the `test:rules` mocha invocation (and to CI) and add the N-1 regression there.

### N-9 · Low / informational · docs — `admin.html` comments assert App Check is "ENFORCED in prod" (it is OFF)
`admin.html:173-178` states Firestore App Check is enforced. It is not (AC-1). Not a vuln itself, but a documentation hazard: a maintainer could weaken an `isAdmin()` rule believing App Check is a second layer. It isn't — rules are the sole perimeter. **Fix:** correct the comment to point at AC-1.

### N-10 · Low (residual) · functions + rules — Admin-attributed audit fields still come from client-written values
`auditUserRestriction`/`auditPostModeration`/`auditPostDeletion` attribute actions from `restrictedBy`/`pendingApprovedBy`/`crisisReviewedBy`/`unflaggedBy`/`deletedBy`/`reviewedBy`. R-1 closed the **non-admin** forge path (those fields are now admin-only to write). But any authenticated **admin** can still stamp *another admin's* uid → frame them in `adminAuditLog`. Not reachable by a normal hostile client; matters only in a multi-admin future as a tamper-evidence gap. **Fix (optional):** have the functions derive the acting admin from an authenticated callable context rather than a client-written field.

---

## 3. AC-1 — the rules-only attack surface (App Check OFF)

With Firestore App Check unenforced, **`firestore.rules` is the only thing between an attacker and the database** for every direct read/write. Document triggers fire *after* the write and verify neither App Check nor `request.auth`. Enumerated, what that exposes:

**(a) Rate limiting — entirely outside the perimeter.** All throttling lives in callables, triggers, or the iOS `RateLimiter`; rules cannot count aggregate writes. A direct client can mass-create posts/replies/likes/follows/reports with no rule-level ceiling. `rateLimitReports`/`rateLimitNotifications`/auto-hide are post-write triggers — they can hide/delete *after* the fact, but the write and its (billed) trigger already ran. **Consequences:** content spam, moderation-queue flooding, and **financial DoS** — a like/unlike or follow/unfollow loop fires billed counter triggers indefinitely (counts stay correct via F-1 dedup; *cost* is unbounded). This is the single biggest reason AC-1 is the top remaining item.

**(b) Moderation is timing-based, not gate-based.** `validatePost`/`validateReply` are post-write triggers. The "start-hidden" model protects *feed-query* clients (they filter `moderationStatus == 'live'`, which doesn't match a not-yet-stamped doc). But a direct client that creates a post **omitting** `moderationStatus` produces a doc that the read rule defaults to `live` (`firestore.rules:552`, `.get(...,'live')`), so a direct `get` by anyone who knows the id can read it during the sub-second pre-trigger window. Acknowledged/sub-second, but it exists only because moderation isn't a rule gate.

**(c) Rule-level holes found this pass:** **N-1** (reply-update byline spoof + field injection) and the **N-2** residue path are the concrete rules/seam gaps reachable directly.

**What is correctly rules-enforced (not in the gap list):**
- **Age gate** — `hasConfirmedAdult()` is enforced *in rules* on post/reply create (`firestore.rules:557/802`), not just the client. Good.
- **Restriction** — `notRestricted()` enforced in rules on post/reply create. Good.
- **Callables** (`confirmAdult`, `giphyProxy`, `reconcileMyCounts`) verify App Check **directly** (`enforceAppCheck:true` / manual header check) — these stay protected regardless of Firestore enforcement, so the paid Giphy key and `confirmedAdult` writes are *not* in the AC-1 gap.
- **Byline/forgery, graph enumeration, block-bypass, self-escalation, cut collections, audit-log/admin reads** — all rule-gated; the prior hostile-user analysis (and my re-read) hold, with the N-1 exception.

**Bottom line:** flipping App Check to Enforced (both projects, Firestore + Auth) closes (a) and (b) wholesale. Until then, N-1 and N-2 are the rule/seam items worth fixing regardless, because a tampered build of the *legitimate* app passes App Check too.

---

## 4. Console-only items the owner must verify (cannot confirm from code)

1. **AC-1 — App Check enforcement (CORRECTED 2026-06-09 — see N-11).** The audit's "App Check is OFF in prod" was a **tooling misread**, not the real state. Verified true state via the corrected tool: **prod `toska-4ebf4` Firestore = `ENFORCED`** (App Check is *live* — the worst-case "rules are the sole perimeter" never applied to prod Firestore), prod **Auth (identitytoolkit) = `UNENFORCED`**, staging Firestore + Auth = `UNENFORCED`. The remaining action is narrower than the audit implied: move prod **Auth** → `ENFORCED`, then staging → `ENFORCED`, after the usual pre-flight (verified-request rate ≈ 100% in the UNENFORCED monitoring metrics, admin.html reCAPTCHA working, debug tokens registered, **real-device App Attest confirmed** since prod Firestore enforcement is already live). `storage` is not an App Check service here (`Service not supported`) and Toska uses no Storage — moot.
2. **Prod ↔ `main` parity** for rules **and** functions (deploy history / `--dry-run`). CI auto-deploys rules to staging only; prod is manual.
3. **`scrubLegacyPII.js` completion %.** Drives the residual exposure window for R-2 — until it's 100%, un-scrubbed user docs deny non-owner reads entirely (degraded `OtherProfileView`), and any still-present legacy PII on the main doc is the thing the migration was meant to remove.
4. **Staging dataset** — confirm it holds only synthetic (`seedAppStoreDemo.js`) data, no real user PII (it now receives M-1 E2E test writes).
5. **Firestore TTL** actually configured on `processedTriggerEvents.expiresAt`, and that `repostCleanupQueue` / resume sweeps are draining (F-6) — code is correct but the TTL/schedule config is console-side.

---

## 5. Areas reviewed with no new issue (stated explicitly)

- **F-1 counter rewrite** — walked concurrent delete-during-increment, retry idempotency, read-first short-circuit, resume replay: no double-count or drop. Correct.
- **M-1 `replyCount` integrity** — hold↔live↔remove transitions, create/delete ends, deduped via `claimedTransaction`: cannot go negative-permanent or inflate; the held-reply inflation vector the prior pass found is closed (clients can't self-stamp `pending_review`, `firestore.rules:807`).
- **Deletion cascade (F-2)** — partial-failure resume, post-auth-deletion timing: bounded and idempotent.
- **Admin dashboard** — every privileged write (approve/unflag/crisis/restrict/remove/resolve, and the new pending-replies approve/remove) is independently `isAdmin()`-gated in rules; the collection-group pending query is `isAdmin()`-or-own; **no XSS sink** in any render path incl. the new pending tab; no secrets beyond public web config. (Only gaps: N-2 orphaning and N-9 comment.)
- **Deep links / URL schemes** — only the Google reversed-client-id scheme, handled solely by `GIDSignIn`; no `onOpenURL`, no universal links. Clean.
- **Normal-user push payloads** — generic, handle-free, content-free for every type; routing `data` carries only opaque uids/ids. No lock-screen leak (L-1's concern does not extend to normal users).
- **Crash/force-unwrap surface** — re-confirmed clean on the interaction paths; `@MainActor` discipline holds; the optimistic-UI race is cosmetic (N-7), not a crash/data-integrity bug.
- **Migration window** — `backfillReplyModerationStatus.js` is project-guarded, paginated, and idempotent ("only touches docs missing the field," re-runnable). The deploy-order window (replies created by an old client between backfill and functions deploy) is closed by the now-deployed `onReplyCreatedModerate` stamping new replies; one-time and historical.

---

*Artifacts: this file (`AUDIT-2.md`). One throwaway emulator test proved N-1 (reply-update spoof succeeds; same injection denied on a post) and was removed. Running suites re-executed green: 129 rules + 142 moderation + 60 functions = 331 (note the orphaned hostile-user suite, N-8).*

---

## 6. Remediation (2026-06-09)

All ten new findings addressed. Backend changes are emulator-verified; client (Swift) changes are written but **must be compiled + manually tested in Xcode on the owner's side** (no iOS build available in the review environment — the only diagnostics seen were the expected `No such module 'FirebaseAuth'` package-resolution noise).

**Test status after fixes:** `npm test` (firestore-tests) now runs **175 rules** (firestore.test.js + the newly-wired hostile-user.test.js, incl. the N-1 regression) + **142 moderation**; functions-tests **62** (incl. 2 new N-2 `clearPostSubtree` tests). All green.

| ID | Sev | Layer(s) | Fix | Verified |
|---|---|---|---|---|
| **N-1** | Med | rules | Reply `update` now `hasOnly(['text','editedAt'])` (`firestore.rules:840`), mirroring R-1. Byline spoof + field injection closed. | ✅ emulator: control edit succeeds; authorHandle spoof + scratch-field injection now denied (`hostile-user.test.js` "N-1 FIXED") |
| **N-2** | Med | functions | New `clearPostSubtree` helper + `onPostDeletedCleanupSubtree` trigger (fires on every post delete) + `resumePostSubtreeCleanup` scheduler + `postSubtreeCleanupQueue` (`index.js`). Deletes the post's replies (+ nested reply-likes), likes, reflections; held PII replies no longer orphan. Idempotent, bounded, resume-queued for mega-threads. | ✅ functions-tests: deletes held PII reply + nested likes + post likes + reflections; idempotent on empty subtree |
| **N-3** | Low-Med | client | Held (`isPending`) reply rows no longer navigate into `ReplyDetailView` (`.disabled(item.reply.isPending)`, `PostDetailView.swift`) — the row already shows the PendingReviewBanner inline; the normal-post detail surface is removed for held replies. | ⚠️ needs iOS build |
| **N-4** | Med | client | Drafts moved off plaintext UserDefaults into a new `DraftStore` (`UserDefaultsKeys.swift`) — a file with `NSFileProtectionComplete` (encrypted while locked) + excluded-from-backup. Rewired compose (`ComposeView`) + reply (`PostDetailView`) + sign-out clear (`ContentView`, now `clearAll()`). `get()` migrates & scrubs any legacy UserDefaults copy. | ⚠️ needs iOS build |
| **N-5** | Med | client | App-switcher privacy screen — a `toskaBlue` cover over logged-in surfaces when `scenePhase != .active` (`ContentView.swift`), so grief content isn't captured in the multitasking snapshot. | ⚠️ needs iOS build |
| **N-6** | Low | client | "Copy text" pasteboard write now uses `.expirationDate` (+300s) + `.localOnly` (`ShareCardView.swift`), matching the image-share path — no lingering/Universal-Clipboard sync of grief text. | ⚠️ needs iOS build |
| **N-7** | Low | client | `FeedPostRow` like-count now uses a `suppressLikeListenerUntil` window (mirrors `PostDetailView`) so the optimistic count doesn't flicker on a feed re-delivery (`FeedView.swift`). | ⚠️ needs iOS build |
| **N-8** | Low | tests/CI | `hostile-user.test.js` wired into `test:rules` (`firestore-tests/package.json`) so it runs locally + in CI; added the N-1 regression block. The R-1/M-1 anti-bypass assertions now actually execute. | ✅ runs (175 rules) |
| **N-9** | Low | docs | `admin.html` App Check comment corrected — it no longer falsely claims enforcement; states rules are the sole perimeter until AC-1 is flipped. | ✅ |
| **N-10** | Low | functions/rules | Left as documented residual (admin-only audit-attribution; not reachable by a normal client). No code change — fixing requires deriving the acting admin from callable context, disproportionate pre-launch. | n/a (accepted) |
| **N-13** | **Medium** | functions | **M-2 phone false-positive fix was incomplete — the server hold path still FPs on year/number lists.** Surfaced by the round-2 E2E (`e2e-round2.mjs`): *"we dated in 2019 2020 2021 2022 2023"* was **held** on staging. Root cause: there are *three* PII detectors. M-2 fixed `moderation.js`'s `containsNameOrIdentifyingInfo`, but `validatePost`/`validateReply` decide holds via `computePostFlagReason`/`computeReplyFlagReason` → `containsPII` → **`hasPhoneNumber` (index.js)**, which counted *total* digits ≥10 — so year lists, score/duration/weight lists, any 10+ digits across short tokens false-positived as `personal_information`. Real, user-facing on prod + staging. **Fix (two passes — the verification round caught a regression in the first):** a first attempt keyed on "≤4 digit groups" still FP'd 4-element lists *and* dropped many-group international numbers (`+33 6 12 34 56 78`). The shipped fix matches phone-**shaped** patterns (NANP 3-3-4, `+`/`00` international, bare 10–11-digit run), so number *lists* match none while real phones (incl. +CC) do; crisis lines excluded. 11 regression tests in `functions.test.js` (incl. the FP/FN cases that caught the regression); verified end-to-end via `computePostFlagReason`. | ✅ local + 73 functions tests green; ⚠️ needs deploy to prod+staging to clear the live FP |
| **N-14** | Medium (pre-existing, UX) | client+functions | **Client/server crisis-hold divergence.** With the "gentle check-in" toggle OFF, `crisisCheckLevelRespectingSetting` returns nil for *soft* crisis phrases (`ToskaTheme.swift`), so the client shows **no** warning and posts silently — but the server (`isPostConcerning` over `MOD_CONCERNING`, which includes the soft tier) **holds** it at `pending_review`, and it never appears in feed with no explanation. Only bites users who turned the toggle off (defaults on). **Deliberately NOT changed unilaterally** — spans 3 safety-critical paths (`isPostClean`/`holdReconciledPost`/`onPostCreated`); how soft-distress content is handled for vulnerable users is a product/clinical call warranting owner sign-off. Proposed: soft-concern → flag `concerningContent` for the admin queue but stay LIVE (don't silently hide); explicit crisis → keep holding + paging. Awaiting owner confirmation. |
| **N-15** | Low | functions | **`apt`/`suite`/`apartment` substring false-positive.** Both PII detectors flagged benign text (*"adapt to change"*, *"the suite life"*, *"my apartment is empty now"*) as `personal_information`. **Fixed:** removed the loose substrings from `index.js`'s `identifyingPhrases` and `moderation.js`'s `IDENTIFYING_PATTERNS`; real unit numbers are still caught by moderation.js's gated Layer-2 regex (`\b(apt\|unit\|suite\|ste)…\d+`, requires a number). Verified 7/7 (FPs clear, *"apt 4b"/"suite 300"/"unit 12"* still caught); 142 moderation tests still green. | ✅ verified; ⚠️ needs deploy |
| **N-16** | Low | functions | **Reply-repost stranding on reply delete.** When a reply was deleted (by `clearPostSubtree` (N-2), `cleanupPostsForUid`, `cleanupExpiredPosts`), reply-reposts (top-level `posts` with `originalReplyId` pointing at it) orphaned with a dangling id. **Fixed:** new `onReplyDeletedCleanupReposts` trigger deletes them on reply delete (each reply-repost's own `onPostDeletedCleanupSubtree` drains its subtree). Functions-test added; verified. | ✅ verified; ⚠️ needs deploy |
| **N-12** | Low (informational) | rules | **Users-doc UPDATE rule has no `hasOnly`** (surfaced by the live E2E rig, `full-e2e.mjs`). A user can add arbitrary *non-sensitive* scratch fields to their own (public-readable) user doc — same schema-lock class as R-1/N-1. The sensitive fields (counters, restriction, `confirmedAdult`, legacy PII) ARE denied, and the age-gate denies a real `confirmedAdult` self-grant (E2E-verified). Low risk: injected fields aren't rendered by the client and no trigger trusts them. Left as an accepted documented gap (a `hasOnly` on the user doc is brittle — many legit fields written by signup/onboarding/settings); lockable if desired by adding a `hasOnly([...])` enumerating the allowed user-doc fields. | n/a (accepted) |
| **N-11** | **High (audit correctness)** | tooling/docs | **`checkAppCheck.js` silently misreported App Check state**, which is the root of the audit's wrong AC-1 conclusion. It never checked `res.ok` and set no quota project, so the firebaseappcheck API's 403 ("quota project not set" under user ADC) was read as `body.enforcementMode \|\| "(unset)"` → printed **`(unset)` for every service regardless of reality**. Fixed: added `x-goog-user-project` + a `res.ok` guard; added `setAppCheck.js` (view both projects / change enforcement with a prod guard). **Verified true state:** prod Firestore **ENFORCED**, prod Auth UNENFORCED, staging both UNENFORCED — i.e. prod Firestore App Check was *already live*, contradicting AC-1. | ✅ both scripts run clean; state reproduced twice |

**iOS build checklist for the owner** (client changes can't be compiled here):
- App compiles clean; `DraftStore` is in `UserDefaultsKeys.swift` (no new file → no `.xcodeproj` change needed).
- Compose a post, background the app → drafts persist and restore; the app-switcher shows the privacy cover, not the content.
- A pre-existing (UserDefaults) draft from an older build still restores once, then lives in the protected file (legacy copy scrubbed).
- Tap a held ("under review") reply → it does **not** open as a normal post.
- "Copy text" from a share card → clipboard clears after 5 min and doesn't sync to other Apple devices.
- Like a post in the feed → count doesn't flicker on refresh.
