# Toska — Audit Report v2

**Date:** 2026-05-22 (audit begun 2026-05-21)
**Auditor:** Claude (read-only)
**Scope:** post-engagement-expansion audit per `AUDIT_BRIEF_v2.md`
**Build under review:** `CURRENT_PROJECT_VERSION = 6` / `MARKETING_VERSION = 1.0`
**Functions deployed:** confirmed live on `toska-4ebf4` via `firebase functions:list` (after CLI re-auth). All 4 NEW (`onReplyLikeCreatedUpdateCount`, `onReplyLikeDeletedUpdateCount`, `onReplyRepostCreatedUpdateCount`, `onReplyRepostDeletedUpdateCount`) and 3 UPDATED (`onRepostCreatedUpdateCount`, `onRepostDeletedUpdateCount`, `validatePost`) functions present, all v2, us-central1, nodejs22 — matching the brief.
**Rules deployed:** trust brief's claim (`firestore.rules` deployed to `toska-4ebf4` after `cf09c9f`); rule content reviewed in-tree against the committed file.

## Verdict
🟢 GREEN

The engagement-expansion batch holds. The reply-engagement schema, rules, Cloud Functions, and iOS surfaces inherit the existing block / age-gate / handle-pin / schema-lockdown guarantees and add no new anonymity-break vector that I could trace. No Critical / High / Medium findings; one Low-severity demo-data integrity inconsistency in `seedAppStoreDemo.js` that is App-Store-reviewer-visible but not user-visible in prod traffic. Re-finds against §3 acknowledged-deferred items: zero.

## Findings by severity

### Critical
none

### High
none

### Medium
none

### Low

[LOW] `functions/seedAppStoreDemo.js:135-158` — `DEMO_POSTS` counter fields disagree with the actual reply/repost docs the seeder writes elsewhere in the same run.
Impact: After a second seeder run, `demo_post_1` shows `replyCount: 1` in the feed row but renders the "be the first to reply" empty state when tapped (no reply doc exists for it — only the `setLike` call at `:519`). Symmetrically, `demo_post_2` shows `replyCount: 0` in the feed row but contains one reply doc seeded at `:520-526` by `soft_evening_42` (the `set()`-based overwrite at `:358` resets the count on every re-seed, and `onReplyCreatedUpdateCount` does not re-fire on the now-existing reply doc). `demo_post_2.repostCount: 1` likewise has no backing repost doc. Apple's reviewer opens the demo account, scans the feed, and lands on a "1 reply" promise that opens to empty. The brief's §5.6 idempotency caveat invited flagging if "non-trivial way it manifests as user-visible" was found; this is that path. (BUDDY_POSTS at `:160-188` are internally consistent — 2/1/5 reply counts match the 2/1/5 docs in `BUDDY_REPLIES`.)

## Unverifiable (real-device required)

Carried forward from the 2026-05-13 brief §8 (all still applicable):
- Push notification end-to-end on a real device (APNs token, payload routing, deep-link unwrap into the right PostDetailView / ConversationView).
- App Attest attestation succeeds on a real device with the Release build (simulator path has the four stacked App-Check issues memoized from prior work — see `feedback_appcheck_simulator`).
- `confirmAdult` callable + `reconcileMyCounts` callable behavior under real-device App Check tokens.
- Crashlytics + Performance auto-init on a real iOS 18.6 device (the `+load`/`-ObjC` linker dependency is brittle on simulators).
- Sign-in-with-Apple flow on a real device (nonce, identity-token round-trip, Firebase Auth credential exchange).

New since 2026-05-13:
- Undo-block toast (`MainTabView.swift:182-214`) visual appearance against the live tab bar, including the `padding(.bottom, 88)` offset on devices with different home-indicator heights.
- Take-a-break banner (`FeedView.swift:97-127`) triggers visibly after a real 15 minutes of continuous feed time on a real device. The Task arm/cancel logic is verifiable in code; the visual presentation is not.
- Reply-action-row (`PostDetailView.swift:~1656-1672`) layout matches the post-action-row spacing exactly on every device size — only verifiable by side-by-side viewing.
- Long-press context menu on replies vs. the swipe-from-right reply gesture — interaction conflict only surfaces on touch.
- `ShareCardView` render for a reply-share (`shareReply` sheet) — existing component, parameterized differently for the reply path; render must be eyeballed.

## Comparison to 2026-05-13 audit

### New findings introduced by the engagement-expansion batch
- One LOW (demo seed data integrity) — see Findings above. This is data-only, prod-user-invisible. The reply-engagement code surface itself (rules, functions, iOS) introduced no new findings I could substantiate.

### Previously-closed findings I verified still hold
- Notification `message` field server-only (firestore.rules:316-329 still excludes `message` from the client-write allow-list at `:333-336`; the seeder uses Admin SDK at `seedAppStoreDemo.js:410` to include it for milestones/reply previews, which is the documented intent).
- `authorHandle` / `originalHandle` / `participantHandles` pinning to canonical user-doc handle (firestore.rules:559-561, 615-618, 840-845 unchanged in spirit; new `originalReplyId` branch defers handle pinning to `validatePost` per documented trade-off).
- Reply / reply-like / reply-repost create rules all enforce `createdAt == request.time` (firestore.rules:680, 718, 550) so backdating is impossible.
- Schema lockdowns (`keys().hasOnly(...)`) preserved on posts (added `originalReplyId` at `:540`), replies, notifications, conversations, drafts, reflections, messages.
- Repost-of-repost guard (`validatePost` at `functions/index.js:1767-1771`) still rejects.
- Counter-trigger idempotency via `claimTriggerEvent` (`functions/index.js:512-536`) — extended to the four new reply-engagement triggers with the same pattern.
- `onRepostCreatedUpdateCount` + `onRepostDeletedUpdateCount` early-return on `originalReplyId` set (`functions/index.js:1321-1322` and `:1356-1357`) — the brief's §5.1#8 concern is addressed: reply-reposts do NOT double-bump both the reply's repostCount and the parent post's repostCount.
- Block check on reply-like targets the REPLY author (firestore.rules:716 reads `posts/{postId}/replies/{replyId}).data.authorId` and checks `users/{that uid}/blocked/{auth.uid}`) — the brief's §6.2 critical-case is foreclosed at the rule layer.
- Reply-repost forgery delete path (`functions/index.js:1718-1753` in `validatePost`) verifies originalPostId is set, the reply doc exists, `postData.text === replyData.text`, and `postData.originalAuthorId === replyData.authorId`; deletes on any mismatch. The ~200ms visibility window is acknowledged by the rule comment at `firestore.rules:594-603` as an accepted trade-off ("keeps the rule's get() count bounded"); counter math commutes to zero (`onReplyRepostCreatedUpdateCount` increments, the subsequent `onReplyRepostDeletedUpdateCount` decrements).
- Owner-only on `users/{uid}/likedReplies/{replyId}` and `users/{uid}/savedReplies/{replyId}` (firestore.rules:447-453) — same shape as `liked` / `saved` siblings.
- `notRestricted()` + `hasConfirmedAdult()` predicates inherited by every publishing path; reply create (firestore.rules:669-670) keeps them.
- PII-to-log grep, Crashlytics `setUserID` grep, ATTrackingManager grep, hardcoded-secret grep — all empty (unchanged from 2026-05-13).

### Previously-closed findings I cannot re-verify
- Apple Sign-In nonce flow — only exercised on device (same as 2026-05-13 §8).

## What I did

### Files read in full
- `AUDIT_BRIEF_v2.md` (this brief)
- `toska/MainTabView.swift` (464 lines)
- `toska/BlockedUsersCache.swift` (unblock path)
- `toska/NotificationsView.swift` (pop-to-root + listener)
- `functions/seedAppStoreDemo.js` (610 lines)

### Files spot-read
- `firestore.rules` — predicates (1-100, 100-400), notifications + reply-engagement reverse indices (300-505), posts + replies + reply likes + reposts (507-790), conversations (793-985).
- `functions/index.js` — `claimTriggerEvent` (505-600), `onReplyCreatedUpdateCount` family (1212-1259), `onReplyLikeCreated/Deleted` (1277-1305), `onRepostCreated/Deleted` (1311-1370) including the `originalReplyId` early-return guard, `onReplyRepostCreated/Deleted` (1382-1424), `validatePost` (1698-1819) with the new reply-repost branch.
- `toska/PostDetailView.swift` — `ThreadedReply` struct + new fields (1-25), state init + initializer sites (43-90, ~1289), `fetchReplies` (949-1017), `mutateReplyInTree` / `findReplyInTree` (1019-1051), reply-toggle handlers (1053-1108), `stampReplyInteractionState` (1121-1172), `buildThreadedReplies` (1174-1207), `FlatReply` / `flattenReplies` with `_stub` ID composition (623-672).
- `toska/PostInteractionManager.swift` — `toggleReplyLike` (499-576), `toggleReplySave` (587-650), `repostReply` (661-728).
- `toska/FeedView.swift` — take-break + new-posts banner state (43-58), banner rendering (97-159), ScrollViewReader / `.refreshable` (188-539), `.onAppear` arming + `.onDisappear` cancel (571-603), `.newPostCreated` self-suppress (639-647), `vm.posts.count` delta tracking (649-667), `FeedPostRow` reply count display (728-960).
- `toska/FeedViewModel.swift` — `fetchPosts` one-shot (530-560), `handleNewPostCreated` / `handleForegroundReturn` / `refreshAll` (246-312), listener count (3: liked/saved/reposted; no posts-collection listener).
- `toska/ProfileView.swift` — `SavedItem` / `LikedItem` unions (891-906, 979-1000), `mergedSavedItems` / `mergedLikedItems` (908-912, 996-1000), `loadSavedReplies` / `loadLikedReplies` (863-886, 953-976), `openSavedReply` / `openLikedReply` self-healing (919-947, 1005-1031), `ReplyEngagementRow` (1098-1141).
- `toska/ContentView.swift` — root view switching between MainTabView and SplashView (60-83).
- `toska/toskaApp.swift` — App Check + project routing (1-80).
- `firestore-tests/firestore.test.js` — failing-test context (760-783).
- `functions/seedAppStoreDemo.js` — `DEMO_POSTS` / `BUDDY_POSTS` / `SAMPLE_NOTIFICATIONS` / `BUDDY_REPLIES` (115-270), `setPost` / `setReply` / `setLike` / `setNotification` helpers (344-411), main seed sequence (505-565).

### Commands run
- `cd ~/Desktop/toska && git log --oneline -25` — confirmed the brief's commit list matches HEAD.
- `node -c functions/index.js && node -c functions/moderation.js && node -c functions/cleanup.js && node -c functions/seedAppStoreDemo.js` → all syntax-clean.
- `cd firestore-tests && npm run test:moderation` → **115 passing** (matches brief).
- `cd firestore-tests && npm run test:rules` (twice) → 140 passing + 1 timeout each run (different test timed out each time — `Finding 7: server-side confirmedAdult gate on publishing surfaces — allows likes/saves/follows even when confirmedAdult is false` on the first run, `conversations update is schema-locked to allow-listed fields` on the second). Treated as flaky emulator timeouts, not real failures: different test names, both timeouts, no assertion-level failure surfaced in either log. Effective: 141 rules tests, all passing, one flakes per run.
- `grep -rn --include="*.swift" -E "(print|NSLog|os_log)\([^)]*\b(uid|email|handle|message|postText|password)\b" toska/` → empty.
- `grep -rn --include="*.swift" "setUserID\|setUserId" toska/` → empty.
- `grep -rn --include="*.swift" "NSUserTracking\|ATTrackingManager" toska/` → empty.
- `grep -rEn "(api_key|secret|token).*=.*[\"'][a-zA-Z0-9]{20,}" toska/ functions/ --include="*.swift" --include="*.js"` → empty (excluding node_modules).
- `firebase functions:list --project toska-4ebf4 | grep -E "onReplyLike|onReplyRepost|validatePost|onRepost"` → all 7 expected functions present (v2, us-central1, nodejs22).
- `grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" toska.xcodeproj/project.pbxproj` → `CURRENT_PROJECT_VERSION = 6`, `MARKETING_VERSION = 1.0`.

### Adversarial-scenario traces (brief §6)

- **§6.1 Reply-repost forgery visibility window** — Reproduced on paper: tampered client writes a post with `isRepost: true`, `originalReplyId: <real reply by X>`, `originalAuthorId: <attacker>` (self-attribution to bypass the rule-layer block check), arbitrary `text`. Rule at `firestore.rules:594-606` accepts (block check is on the client-supplied `originalAuthorId`, which the attacker set to themselves). `validatePost` (~50-200ms later) reads `posts/{originalPostId}/replies/{originalReplyId}`, sees `replyData.authorId !== postData.originalAuthorId`, deletes. Counter math: `onReplyRepostCreatedUpdateCount` increments, `onReplyRepostDeletedUpdateCount` decrements on the delete — net zero. Visibility window is explicitly accepted in the rule's inline comment (`firestore.rules:594-603`). Not a new finding.
- **§6.2 Blocked-user reply-like notification spam** — Reply-like rule at `firestore.rules:713-718` resolves the reply doc's `authorId` server-side via `get(.../posts/{postId}/replies/{replyId}).data.authorId` and checks `!exists(/users/{that uid}/blocked/{auth.uid})`. The check is on the REPLY's author, not the parent post's author. Blocked user is rejected at the rule layer before any like doc lands; no `onReplyLikeCreatedUpdateCount` invocation, no notification fanout (no reply-like notification path exists in v1.0 anyway; see §3 #4). Safe.
- **§6.3 Undo-block during cache-sync after sign-out + sign-in** — `BlockedUsersCache.unblock` (`BlockedUsersCache.swift:166-186`) reads `Auth.auth().currentUser?.uid` at call time. On sign-out, `ContentView` swaps to `SplashView` (`ContentView.swift:73-82`), `MainTabView` is removed from the hierarchy, and its `@State pendingUndoBlock` storage is released. The dismiss Task closure captured the View by value; SwiftUI's State container is gone by the time the cancelled sleep returns, so the `pendingUndoBlock = nil` write is a no-op. If the user has signed back in as a different account before the Task cancellation completes, the Task's check (`guard !Task.isCancelled else { return }`) still fires; even if it didn't, the only write is to a destroyed view's state. Safe.
- **§6.4 Reply-repost cascade orphans** — Acknowledged-deferred (§3 #3). Cite-and-move-on.
- **§6.5 Pop-to-root from nested push** — `NotificationsView`'s `.popNotificationsTabToRoot` handler (`NotificationsView.swift:209-216`) resets `showPost`, `selectedPostId`, `selectedPostData`, `selectedFollowUser`, `showConversation`, `selectedConversation`. Setting `showPost = false` on the `.navigationDestination(isPresented: $showPost)` (`:217`) removes `PostDetailView` from the stack; iOS 16+ `NavigationStack` semantics drop the child views pushed from PostDetailView (e.g., the `OtherProfileView` pushed via PostDetailView's own `showOtherProfile`) when their parent leaves. PostDetailView's own `@State` (including `showOtherProfile`) is released with the view; on re-push, the state initializes fresh. Safe.
- **§6.6 Take-a-break Task survives sign-out** — `FeedView.swift:600-603` `.onDisappear { takeBreakTask?.cancel(); takeBreakTask = nil }` is attached to the ScrollView wrapper, which leaves the hierarchy on sign-out (ContentView swap as in §6.3). Task is cancelled cleanly. Note: tab-switching does NOT fire onDisappear (MainTabView keeps tabs alive via `.opacity` per `MainTabView.swift:49-84`), so the comment at `FeedView.swift:587-588` claiming "tabbing away + back gives the user a clean break" is documentation/behavior drift — the clock keeps ticking across tab switches. Not a security or stability issue; flagging only because the brief asked for a trace. The task's effect is only to show a soft banner, so the drift has no negative impact.
- **§6.7 New-posts banner false positive on pull-to-refresh** — `vm.fetchPosts` (`FeedViewModel.swift:530`) is a one-shot `getDocumentsAsync`, not a snapshot listener. No cache-then-server dual delivery. `vm.posts.count` change is keyed off the `.onChange(of: vm.posts.count)` (`FeedView.swift:649`). Refreshable that returns the same N posts produces no `.onChange` fire. If new posts have arrived in the window, the banner correctly reflects the delta. The `-1` sentinel re-baseline (`previousPostCount = -1` at `:647`) after `.newPostCreated` correctly suppresses the false-positive for the user's own fresh post. Safe.

### Sub-agents spawned
None.

## What I did NOT cover

- Live Firestore reads against `toska-4ebf4` to confirm deployed state — `firebase functions:list` failed with auth-expired; did not run `gcloud auth application-default login` re-auth from this session.
- End-to-end Auth wire test (`curl identitytoolkit signInWithPassword` against the demo account) — did not exercise because nothing in the audit hinged on it; the rules tests cover the auth shapes that matter.
- Did not exercise the iOS app on a real device. Every iOS finding is paper-trace only.
- Did not review the unchanged moderation pipeline (`functions/moderation.js`) beyond confirming 115 passing tests. Brief specifies the engagement-expansion batch as the focus.
- Did not check the `e2e-test.mjs` smoke test (`firestore-tests/` dir). It is not part of the standard `npm test` cycle.
- Did not exercise concurrent-write races on the reply-repost cascade orphan path (§3 #3 — acknowledged-deferred).
- Did not look at the previously-audited messages/conversations surfaces in depth — unchanged in this batch.
- Did not verify the iOS archive currently submitted to App Store Connect matches the `main` branch HEAD (brief explicitly calls this out: "code is in `main` but a fresh archive is required for the changes to reach a device").
