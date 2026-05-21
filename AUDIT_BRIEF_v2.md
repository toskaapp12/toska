# Toska — Pre-Apple-Submission Audit Brief v2 (post-engagement-expansion)

**For:** a fresh Claude Code session, run from `~/Desktop/toska`, no prior context.
**Supersedes:** `AUDIT_BRIEF.md` (2026-05-13). Read that file's §0-§5 for the durable threat model + framework; this brief lists what's CHANGED since and tells you where to spend your time.
**Bar:** v1.0 anonymous UGC, 17+, mental-health-adjacent, SALTE DEVELOPMENT LLC publisher with real D-U-N-S. Same as before. Apple, real users, motivated stalkers. The audit-clean baseline from `AUDIT_REPORT_2026-05-13.md` was green — your job is to verify nothing introduced since regressed that.

**Read this entire document end-to-end BEFORE running any tool calls.**

---

## 0. Mission

For every surface modified since the 2026-05-13 audit, answer:

1. **Does it work?** Code-and-rules layer correctness.
2. **Is it safe?** Under the same threat model (anonymity break / stalker / UGC content safety).
3. **Is it stable?** No new race conditions, listener leaks, unbounded queries.
4. **Did it weaken the moderation contract?** Apple 1.2 UGC — every new write path must inherit the existing block / age-gate / handle-pin / schema-lockdown guarantees.
5. **Did it open a new anonymity-break vector?** Any new reverse-index, derived doc, push payload, or notification surface needs cross-account-correlation checking.

**Do NOT propose fixes. Findings only.** The owner decides what to fix.

**Do NOT re-find items listed under §3 (acknowledged-deferred).** Cite-and-move-on.

---

## 1. What changed since 2026-05-13

The 2026-05-13 audit closed green. The following commits landed since (in order). Read each commit message for the per-change rationale; this list is a map of where to look.

### Submission-day fixes (low risk, structural)
- `7e25d01` — three iOS audit-hardening fixes (PostDetailView.fetchReplies captured-uid recheck, MessagesListView .userBlocked subscription, PushNotificationManager.clearFCMToken FCM-level invalidate first).
- `5c6d8b9` — M-1 email enumeration UI collapse, M-2 seeder credentials honesty.
- `dc2658c` — swipe-down-on-header dismiss on PostDetailView.
- `faecde8` — Settings opens via navigation push (not sheet).
- `15cb2b2` — build bump 5→6.
- `62181bb` — review-mode policy view from Settings → "view content policy".
- `ae8bbf6` — "— tess" attribution removed from Settings.
- `1394d06` — fetchReplies listener errors surfaced (was silent-swallowed).

### Seeder + demo data
- `febabe4` — buddy posts seeded with actual reply docs (was inflated replyCount).
- `913aec2` — 7 sample notifications seeded for the demo account inbox.

### NEW FEATURE: full reply engagement (HIGH RISK SURFACE — focus here)
- `cf09c9f` — like / save / repost on replies, schema + rules + functions + iOS.
- `472875d` — saved replies in ProfileView "saved" tab.
- `f0460cc` — liked replies in ProfileView "liked" tab.
- `99ae22f` — comment + share icons on the reply action row.
- `eb10960` — reply action row layout matches FeedPostRow (order + spacing).

### Seamlessness batch (mostly UI)
- `df0614a` — tap-active-bell pops notifications tab to root.
- `ac809ff` — tab-scroll-to-top, pull-to-refresh on feed, undo-block toast.
- `191f622` — long-press context menu on replies + compose char counter.
- `78b4d5b` — take-a-break gentle reminder (15-min Task on feed).
- `21518fa` — "X new posts available" banner + reply chain show-more.
- `a9a2227` — suppress new-posts banner for the user's own fresh post.

### What's deployed where (verified live)
- **Rules:** `firestore.rules` deployed to prod `toska-4ebf4` after `cf09c9f`.
- **Cloud Functions:** 4 NEW (`onReplyLikeCreatedUpdateCount`, `onReplyLikeDeletedUpdateCount`, `onReplyRepostCreatedUpdateCount`, `onReplyRepostDeletedUpdateCount`) + 3 UPDATED (`onRepostCreatedUpdateCount`, `onRepostDeletedUpdateCount`, `validatePost`). All in us-central1, nodejs22, v2 triggers.
- **iOS:** code is in `main` but a fresh archive is required for the changes to reach a device. If you're auditing what's INSTALLED, treat the iOS layer as potentially-stale.
- **Seeded data:** demo account `appreview@toskaapp.com` on prod + staging populated with posts, replies, notifications, conversation, follow graph. Password is set to `crazybean1234` on both projects.

---

## 2. Tooling (updated counts)

### Run the full test suite
```
cd ~/Desktop/toska/firestore-tests && PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" npm test
```
Expect: **115 moderation passing + 141 rules passing = 256 total**. The moderation count went 91→115 in `ec0b06d` (phone-detector + combining-marks + ig: shorthand fixes — closed three findings from the 2026-05-13 audit).

### Check Cloud Functions JS syntax
```
node -c functions/index.js && node -c functions/moderation.js && node -c functions/cleanup.js && node -c functions/seedAppStoreDemo.js
```

### Verify deployed function set
```
firebase functions:list --project toska-4ebf4 | grep -E "onReplyLike|onReplyRepost|validatePost|onRepost"
```
Expect 7 lines — all the reply-counter + repost-counter + validatePost functions.

### Hit prod Firestore from Node (for verifying seeded data, reading rules-deployed state)
```
cd functions
GCLOUD_PROJECT=toska-4ebf4 node -e "
const admin = require('firebase-admin');
admin.initializeApp();
const db = admin.firestore();
(async () => { /* your query */ })();
"
```
Requires `gcloud auth application-default login` first; if expired (`invalid_grant`), you cannot run this and must mark Firestore queries as unverifiable.

### Wire-level Firebase Auth test
```
API_KEY=$(grep -A1 "API_KEY" toska/GoogleService-Info.plist | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"appreview@toskaapp.com","password":"crazybean1234","returnSecureToken":true}'
```

### Static greps that already passed 2026-05-13 but worth re-running
- PII to logs: `grep -rn --include="*.swift" -E "(print|NSLog|os_log)\([^)]*\b(uid|email|handle|message|postText|password)\b" toska/`
- Crashlytics setUserID: `grep -rn --include="*.swift" "setUserID\|setUserId" toska/`
- Tracking: `grep -rn --include="*.swift" "NSUserTracking\|ATTrackingManager" toska/`
- Hardcoded secrets: `grep -rEn "(api_key|secret|token).*=.*[\"'][a-zA-Z0-9]{20,}" toska/ functions/ --include="*.swift" --include="*.js"`

---

## 3. Acknowledged-deferred items — DO NOT report these

The owner knows about these. Re-reporting them is noise:

1. **Reply-like in-flight guard missing.** `PostInteractionManager.toggleReplyLike` lacks the `RateLimiter.shared.isLikeInFlight` check that `toggleLike` has. Rapid double-tap can desync optimistic state. v1.1 fix.
2. **Saved tab sort inconsistency.** `mergedSavedItems` sorts saved posts by `post.createdAt` (post creation time) and saved replies by `savedAt` (when bookmarked). Pre-existing for posts; more visible now with replies. v1.1 fix.
3. **No cascade-delete for reply-reposts** when the original reply is deleted. Reply-reposts (`posts/{uid}_replyrepost_{replyId}`) lingers; data is technically inconsistent but no user-visible bug (the repost renders from its own copied fields).
4. **No push notification on reply-like / reply-repost.** Reply author sees the count update on next visit; no push fires. Intentional v1.0 scope decision.
5. **Notification grouping deferred** (v1.1) — every notif renders as its own row even when N events on the same post in the same hour.
6. **Offline queue deferred** (v1.1) — current "offline, skipping" behavior is the v1.0 contract.
7. **Quiet hours deferred** (v1.1) — needs timezone storage; would expand the user-doc linkability surface.
8. **Blur-and-reveal for `concerningContent`** intentionally NOT implemented — the current model **filters concerning content out entirely** from feed/explore/trending (`FeedViewModel.swift:188` and mirrors). Changing to blur-and-reveal would *weaken* the safety filter. If you think the filter is too aggressive, that's a design discussion, not an audit finding.
9. **Self-repost guard on REPLIES is iOS-only.** `repostReply` has `guard uid != replyAuthorId else { return }`. Server doesn't enforce. A tampered client could create a self-repost — net effect is the user duplicating their own reply text into a top-level post. Not a security issue.
10. **No composite index on `(authorId, originalReplyId)`.** Sidestepped by deterministic doc IDs for repost dedup (`posts/{uid}_replyrepost_{replyId}`). Don't suggest adding the index unless you find a query that needs it.

---

## 4. Audit framework

Same as 2026-05-13. Re-stated for completeness.

### Severity buckets
- **CRITICAL:** anonymity break, auth bypass, prod data corruption, moderation bypass that would fail Apple 1.2. App not submission-ready until fixed.
- **HIGH:** DoS / unbounded query / missing App Check / unauth'd callable, state-machine bug stranding users, contract violation between two surfaces.
- **MEDIUM:** race condition under load, listener leak, error-handling gap, UX bug in core flow.
- **LOW:** defense-in-depth nit, doc inconsistency.

### Output format (strict)
For each finding:
```
[SEVERITY] file:line — one-sentence what's wrong.
Impact: one-sentence what breaks if exploited or triggered.
```

Mark anything requiring real-device validation as **UNVERIFIABLE**, don't speculate.

### Anti-patterns
- Confident speculation without reading the cited line.
- Re-finding items in §3 above.
- Severity inflation ("microsecond window" isn't CRITICAL).
- Generic best-practice advice that isn't a concrete defect.

---

## 5. Per-surface audits — where to spend time

### 5.1 Reply engagement schema + rules (highest priority)

**Files:** `firestore.rules` lines ~520-700 (posts hasOnly + repost validation, replies match block + nested likes match).

**Verify each:**
1. **Nested `match /posts/{postId}/replies/{replyId}/likes/{likeUserId}`** rule (firestore.rules ~636) — block check targets the REPLY's author (not the parent post's author). `keys().hasOnly(['createdAt'])` + `createdAt == request.time` schema lockdown. Tests in `firestore.test.js` are sparse for this branch; flag if you find paths not covered.
2. **`users/{uid}/likedReplies/{replyId}` + `users/{uid}/savedReplies/{replyId}`** reverse indices (firestore.rules ~444). Both are `if isOwner(userId)` — verify no path leaks data to other authenticated users. Verify schema isn't locked (it's intentionally open so the seed-time snapshot fields can land).
3. **`originalReplyId` in posts.hasOnly** (firestore.rules ~534). Verify reply-reposts can't carry extra spoofable fields.
4. **Reply-repost validation branch** (firestore.rules ~568). The branch defers full validation to `validatePost` Cloud Function but enforces block-check at the rule layer. Verify the block-check covers the REPLY's author (not the parent post's author). If a blocked user can repost the blocker's reply, that's CRITICAL.
5. **`validatePost`'s new reply-repost branch** (functions/index.js ~1620). Walks `posts/{originalPostId}/replies/{originalReplyId}`; verify text-match, authorId-match, exists-check. Deletes on mismatch.
6. **`onReplyLikeCreatedUpdateCount` + `onReplyLikeDeletedUpdateCount`** (functions/index.js ~1265). Same `claimTriggerEvent` idempotency pattern as post-like counter. Verify decrement-only-on-real-delete; verify no infinite trigger loops.
7. **`onReplyRepostCreatedUpdateCount` + `onReplyRepostDeletedUpdateCount`** (functions/index.js ~1340). Verify the originalReplyId guard prevents double-counting with `onRepostCreatedUpdateCount`.
8. **Modified `onRepostCreatedUpdateCount` + `onRepostDeletedUpdateCount`** (functions/index.js ~1280). Now early-returns if `originalReplyId` is set. Without this skip, reply-reposts would bump BOTH the reply's repostCount AND the parent post's repostCount. Verify the early-return.

### 5.2 New iOS state on PostDetailView

**File:** `toska/PostDetailView.swift`.

- **`ThreadedReply` struct gained fields** (`isLiked`, `isSaved`, `isReposted`, `repostCount`) with defaults. Two initializer sites at line ~900 and ~1208. The second site doesn't pass the new fields (relies on defaults). Verify Swift's auto-synthesized memberwise init handles this.
- **`stampReplyInteractionState`** (static helper, ~line 980) — runs after every fetchReplies snapshot, intersects reply IDs with the user's likedReplies/savedReplies subcollections + deterministic-id getDocument for own reply-reposts. Uses `withTaskGroup` for parallel reads. Verify the chunks-of-30 batching (Firestore `in:` operator limit).
- **`mutateReplyInTree` + `findReplyInTree`** (~line 940) — recursive tree walkers for the threaded list. Verify they handle the children array correctly without infinite loops.
- **`expandedDeepThreads: Set<String>`** state for the reply-chain show-more stub. Verify the stub's `id == "\(reply.id)_stub"` doesn't collide with any real reply ID.

### 5.3 New iOS state on MainTabView

**File:** `toska/MainTabView.swift`.

- **Undo-block toast** — `BlockedUserToast` struct + `pendingUndoBlock` state. Listens to `.userBlocked` notification. Auto-dismisses after 4s via Task. Verify:
  - Race: rapid block of two different users — second .userBlocked should REPLACE the first toast (not stack). The `withAnimation { pendingUndoBlock = ... }` does this; verify the dismiss task cancellation handles it.
  - Race: user taps undo just as the dismiss task fires — `undoToastDismissTask?.cancel()` runs before reassigning. Verify no double-fire.
  - Race: blocked user unblocked via toast, then user navigates to settings → blocked list — verify the cache state is consistent.

- **Tap-active-bell pop-to-root** — posts `.popNotificationsTabToRoot` notification. `NotificationsView` observes and resets `showPost`, `selectedPostData`, `selectedPostId`, `selectedFollowUser`, `showConversation`, `selectedConversation` to nil/false. Verify all pushed destinations actually clear (some may have additional dependent state).

- **Tap-active-tab scroll-to-top** — `tabIcon` helper posts `.scrollFeedToTop` / `.scrollTopTabToTop` / `.scrollProfileToTop`. FeedView already had this; TopView + ProfileView gained ScrollViewReader wrappers. Verify open/close brace pairs (auditor: `grep -n "ScrollViewReader\|// end ScrollViewReader" toska/*.swift`).

### 5.4 New iOS state on FeedView

**File:** `toska/FeedView.swift`.

- **`takeBreakBannerShown` + `takeBreakTask`** — 15-minute Task armed on onAppear, cancelled on onDisappear. Verify the task captures the view's lifetime correctly (no leak across sign-out).
- **`newPostsBadgeCount` + `previousPostCount`** — delta tracking via `.onChange(of: vm.posts.count)`. Verify the `-1` sentinel for initial state. Verify the local-author suppression in `.onReceive(.newPostCreated)` (commit `a9a2227`).
- **`.refreshable` on the feed** — calls `vm.fetchPosts()` (non-async) + sleeps 1.5s. Verify this doesn't conflict with the existing listener-based update path.

### 5.5 Profile saved/liked replies

**File:** `toska/ProfileView.swift`.

- **`SavedItem` and `LikedItem` enums** — sortable unions. Verify the sort comparator uses the right `createdAt` per variant.
- **`openSavedReply` and `openLikedReply`** — fetch the parent post on tap, navigate to PostDetailView. On 404 (parent post gone), they delete the orphan saved/liked-replies entry and remove from local array. Verify the self-healing path doesn't race with concurrent listener updates.
- **`ReplyEngagementRow`** — generic component used by both saved and liked tabs. Verify no styling regressions vs the post rows alongside it.

### 5.6 Seeder + sample data

**File:** `functions/seedAppStoreDemo.js`.

- **`SAMPLE_NOTIFICATIONS`** — 7 notifications seeded for demo. Verify the schema (`type`, `fromUserId`, `fromHandle`, `postId`, `isRead`, `createdAt`, optional `message`) matches what `NotificationsView` reads. The `message` field is server-only (rule excludes it from client writes); seeder uses Admin SDK so it can include it.
- **`BUDDY_REPLIES`** — 8 reply docs backing BUDDY_POSTS replyCount. Verify count integrity: post.replyCount == sum of seeded replies for that post.
- **Idempotency** — known caveat: first-time seed inflates replyCount because triggers fire on create. Second run re-sets the post doc (overwrite) so counts settle. Documented in `febabe4` commit message. **Do NOT flag** unless you find a non-trivial way it manifests as user-visible.

---

## 6. Adversarial scenarios — trace each

### 6.1 Reply-repost forgery
Tampered client writes a post doc with `isRepost: true`, `originalReplyId: <some-reply-id>`, `originalPostId: <some-other-post-id>`, `originalAuthorId: <victim-uid>`, `text: <fabricated-quote>`. Rule allows it (defers to validatePost). validatePost looks up `posts/{originalPostId}/replies/{originalReplyId}`, finds either:
- Reply doesn't exist → delete the fake repost. ✓
- Reply exists but text doesn't match → delete. ✓
- Reply exists, text matches, but originalAuthorId doesn't match reply.authorId → delete. ✓

**The bad case:** validatePost has a window (~200ms create-to-trigger) where the fake repost is publicly visible. Trace what happens in that window: feed listeners deliver the fake to other clients before validatePost deletes. Is this acceptable risk?

### 6.2 Blocked-user reply-like notification spam
A blocks B. B opens any reply by A and taps the heart.
- Rule check: `posts/{postId}/replies/{replyId}/likes/{B}` create — does the rule check `users/{A}/blocked/{B}`?
- Verify firestore.rules:~636 — the create rule must check the REPLY's author (A), not the parent post's author (could be C, unrelated).
- If the block check is on the wrong author, blocked users can still pump engagement on the blocker's replies.

### 6.3 Undo-block during cache-sync
User blocks X via toast. Cache.block fires .userBlocked. MainTabView shows toast. User immediately switches accounts (sign-out + sign-in). Toast's dismiss task continues running. Sign-in completes. Toast still shows or auto-dismisses. If "undo" is tapped post-sign-in, it calls `BlockedUsersCache.shared.unblock(userId)` which uses `Auth.auth().currentUser?.uid` (NEW user's uid). Result: tries to delete `users/{newUid}/blocked/{userId}` which doesn't exist. Safe but suspect — verify.

### 6.4 Reply-repost cascade orphans
A reply-reposts B's reply. B deletes the reply. The repost lingers (deterministic doc `{A_uid}_replyrepost_{replyId}`) with `originalReplyId` pointing at nothing. Trace:
- Does any flow ever read `posts/{originalPostId}/replies/{originalReplyId}` for this repost? If yes, missing doc → broken render.
- Is the repost's `repostCount` field on the (now-deleted) reply also gone? Yes — when the reply doc was deleted, its repostCount went with it. No drift.

### 6.5 Notifications tab pop-to-root from nested push
User taps a notification → drills into PostDetailView → taps a follow there → drills into OtherProfileView. Stack depth 2 from the notifications root. Tap bell. .popNotificationsTabToRoot fires. NotificationsView resets `showPost`, `selectedFollowUser`, etc. — but does this actually pop the FOLLOWED-on-from-PostDetailView push? Trace the NavigationStack state.

### 6.6 Take-a-break Task survives sign-out
User signs out while feed is on screen (15-min Task armed). onDisappear should cancel. But does it? FeedView's onDisappear is at line ~519. Verify the Task is actually cancelled — a leaked Task fires the banner after sign-out which would render in the SplashView context (broken).

### 6.7 New-posts banner false positive
User pulls-to-refresh on feed. listener re-delivers same posts. `vm.posts.count` stays the same. `.onChange` doesn't fire. ✓.
But what about cache-then-server delivery? Firestore SDK delivers cached snapshot first (count = X), then server snapshot (count = X). If they differ for a moment? Trace the listener delivery semantics.

---

## 7. Unverifiable (real-device required)

Same as 2026-05-13 brief §8. Plus these new items:

- Whether the undo-block toast looks right against the live tab bar (haven't seen on device).
- Whether the take-a-break banner triggers visibly on a real device after 15 min (haven't waited 15 min on device).
- Whether the reply-action-row layout matches the post-action-row spacing exactly on every device size.
- Whether the long-press context menu on replies opens cleanly without conflicting with the swipe-from-right reply gesture.
- Whether the ShareCardView render for a reply-share looks right (existing component, but parameterized differently).

Mark these UNVERIFIABLE; don't speculate.

---

## 8. Deliverable format

Single markdown file: `AUDIT_REPORT_v2_<YYYY-MM-DD>.md` at repo root.

```
# Toska — Audit Report v2
**Date:** YYYY-MM-DD
**Auditor:** Claude (read-only)
**Scope:** post-engagement-expansion audit per AUDIT_BRIEF_v2.md
**Build under review:** <CURRENT_PROJECT_VERSION> / <MARKETING_VERSION>
**Functions deployed:** <list verified live>
**Rules deployed:** verified deployed YYYY-MM-DD

## Verdict
🟢 GREEN / 🟡 YELLOW / 🔴 RED

## Findings by severity
### Critical (or "none")
### High (or "none")
### Medium (or "none")
### Low (or "none")

## Unverifiable (real-device required)
- bullets

## Comparison to 2026-05-13 audit
- New findings introduced by the engagement-expansion batch
- Previously-closed findings I verified still hold
- Previously-closed findings I cannot re-verify (cite specific lines)

## What I did
- Files read in full
- Files spot-read
- Commands run
- Sub-agents spawned (if any)

## What I did NOT cover
- Honest gaps
```

---

## 9. Tone

Same calibration as the 2026-05-13 brief. Codebase is mostly clean — five audit rounds + multiple follow-up closures. If you find five Critical items in a fresh audit, you're probably wrong about most of them; re-verify before reporting. If you find zero, double-check you actually exercised the new surfaces.

Apple-blocking findings now would be unusually bad given the prior audit's verdict. Anything you do find should hold under scrutiny — the owner has gotten very good at spotting noise.

End of brief. Good hunting.
