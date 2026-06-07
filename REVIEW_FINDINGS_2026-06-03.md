# TOSKA — FULL APP REVIEW & FIX
**Living findings document — started 2026-06-03**
Reviewer role: Apple App Review engineer + staff iOS/Firebase security auditor.
Repo: `~/Desktop/toska` · prod `toska-4ebf4` · staging `toskastaging` (App Check ENFORCED in prod).

> Status legend: **BLOCKER** (must resolve before submit) · **HIGH** · **MED** · **LOW**
> Verification legend: ✅ verified-in-code-this-pass · 📄 from existing audit docs (unverified by me) · ⏳ not yet verified

---

## 0. EXECUTIVE SUMMARY / GO–NO-GO

**Status after 2026-06-07 fix session: the three submission blockers are resolved in code + verified locally. Remaining gate is a prod DEPLOY (not yet done — deploy authorization is per-round) + standard pre-submission checks.**

The codebase is genuinely well-hardened (default-deny rules, schema lockdown, server-side moderation, idempotent counters on *post* docs, real account-deletion cascade). Three things blocked a clean submission; product decisions were taken (D1/D2/D3) and the fixes applied and verified:

| ID | Sev | One-liner | Status |
|----|-----|-----------|--------|
| BW-1 | BLOCKER | Follower/following COUNTS displayed by default on `OtherProfileView`. | **Decision D1: KEEP counts (product-owner call, 2026-06-07).** Wedge exception accepted by owner. SEC-1 still fixed so counts can't be forged. |
| SEC-1 | BLOCKER/HIGH | `followerCount`/`followingCount`/`totalLikes`/`postCount` client-forgeable in the `users` update rule. | **FIXED** — fields added to the update deny-list; only Admin SDK (Cloud Functions) can write them. Emulator-tested (3 new tests). |
| BW-2 | BLOCKER | DM backend fully live (rules accept writes + deployed `onMessageCreated*` + live index + seeded demo convo) despite cut UI. | **Decision D2: REMOVE.** Rules deny conversations/messages; index dropped; demo seeder cleaned; both trigger functions removed; 3 dead Swift files deleted. Emulator-tested + app compiles. |
| D3 | — | `FeelingCircleView` built but unreachable; live `feelingCircles` rules. | **Decision D3: CUT.** Rules deny feelingCircles/messages; Swift view deleted; `cleanupExpiredCircles` janitor kept to drain leftovers. Emulator-tested + compiles. |

Everything else is HIGH/MED/LOW and mostly already documented/accepted in prior audits. Details below.

### 0.1 FIXES APPLIED THIS SESSION (2026-06-07) — all local-verified, NOT deployed
| # | Change | File(s) | Verification |
|---|--------|---------|--------------|
| 1 | Lock aggregate counters (SEC-1) | `firestore.rules` (users update deny-list) | rules emulator: 3 new SEC-1 tests pass (forge denied, normal update allowed) |
| 2 | Deny conversations + messages | `firestore.rules` | emulator: create/read/message-create all denied |
| 3 | Deny feelingCircles + messages | `firestore.rules` | emulator: create/read/message-create all denied |
| 4 | Drop conversations composite index | `firestore.indexes.json` | valid JSON |
| 5 | Remove demo conversation seeding | `functions/seedAppStoreDemo.js` | `node --check` passes |
| 6 | Remove `onMessageCreatedModerate` + `onMessageCreatedUpdateCount` | `functions/index.js` | `node --check` passes; `cleanupExpiredCircles` kept as drainer |
| 7 | Delete dead Swift files | `MessagesListView/ConversationView/MessageBubble/FeelingCircleView.swift` | no external code refs (comments only); `xcodebuild` BUILD SUCCEEDED (signing disabled) |
| — | Update obsolete rules tests | `firestore-tests/firestore.test.js` | **full suite: 129 passing, 0 failing** |

**Whole rules suite green (129 passing). App target compiles clean** (the only build failure is the CodeSign step — an environment keychain limitation, not a code error).

### 0.2 REMAINING BEFORE SUBMIT
1. **Deploy** the rules + indexes + functions to prod/staging (removes the DM triggers + conversations index; activates the deny rules). **Not done — needs per-round deploy authorization.** Recommend deploy order: indexes → rules → functions, staging first.
2. **App Check "Enforced"** re-confirm on prod Firestore at submission.
3. ~~DM plumbing remnants~~ — **DONE** (CLEAN-1, 2026-06-07): all removed, app compiles, rules green.
4. Pre-existing documented items (CORR-1 password-reset enumeration UI, DEL-1 cascade orphan caps) — confirm-accept.

---

## 1. PHASE 1 — THE MAP

### 1.1 Product, in one paragraph
Toska is an anonymous, breakup-focused social app — "Reddit but only for breakups." Users sign in (email / Apple / Google), pass a self-declared 18+ age gate enforced server-side via the `confirmAdult` callable, accept a content policy, and post under randomly-generated handles (e.g. `soft_evening_42`) with no real names, photos, or bios. Core loop: **feed (for-you / following) → compose post or threaded reply → react (like "felt" / save / repost) → block/report bad actors → optional emotional "moments" (daily prompt, weekly recap, anniversary reflections, ephemeral feeling circles).** The user is emotionally vulnerable (mid-breakup); the brand wedge is radical anonymity. Explicit non-goals (any of which is a *bug* if present): **DMs/chat, matching/dating, follower-count status, days-since-breakup counters.**

### 1.2 Screen inventory (44 Swift files)
Full per-screen detail (purpose, nav entry, Firestore reads/writes, function calls, state coverage) is captured in the screen-map appendix below. Navigation root: `toskaApp → ContentView` (auth/policy/onboarding state machine) `→ MainTabView` (4 tabs: **feed, top, notifications, profile** + floating compose). `ExploreView` and `FeelingCircleView` are reachable from feed/empty-state chrome, **not** tabs.

**Reachability of forbidden surfaces (✅ verified this pass):**
- **DMs:** `MessagesListView` / `ConversationView` / `MessageBubble` compile but have **zero instantiation** (`grep "MessagesListView(" → none`). Push `.conversation` intent is explicitly dropped (`MainTabView.swift:330 → break`). **UI unreachable.** Backend live — see BW-2.
- **Followers:** counts shown on `OtherProfileView.swift:88–96`; `showFollowerCount` **defaults to `true`** (`:23` and `?? true` at `:307`). Own `ProfileView` shows no counts. Follow/following *lists* currently being moved from ProfileView → Settings (uncommitted working-tree diff). **Reachable & default-on** — see BW-1.
- **Days-since counter / matching / dating:** none found. ✅ clean.

### 1.3 Cloud Functions inventory
~50 exported functions (full table in appendix). Trigger functions for counters use `claimTriggerEvent` / `claimedTransaction` for idempotency. The three callables/HTTP endpoints:
- `confirmAdult` (onCall, `enforceAppCheck:true`, rate-limited 5/hr) — ✅ age gate is server-authoritative; client cannot write `confirmedAdult` (rules line 221/237).
- `giphyProxy` (onCall, `enforceAppCheck:true`, 60/min) — ✅ Giphy key is a Secret Manager binding, never returned, errors sanitized of `api_key=`. Good.
- `reconcileMyCounts` (onRequest) — ✅ manually verifies App Check header + ID token, reconciles only the caller's own uid. Good (despite being onRequest).

### 1.4 Interaction matrix (cross-feature scenarios)
| Scenario | Behavior | Finding |
|---|---|---|
| Post deleted while user mid-reply / viewing detail | PostDetailView handles 404; reply create would fail rule (post gone) | OK |
| User restricted mid-session | rules `notRestricted()` gate on posts/replies/messages/circle-msgs; iOS checks `UserHandleCache.isRestricted` | OK ✅ (rules verified) |
| Auth change (sign-out/delete/token expiry) mid-session | ContentView retry loop + captured-uid rechecks (per docs) | 📄 mostly OK; cold-start block race documented (CORR-3) |
| Denormalized counts under concurrency/offline replay | *Post* counters (likeCount/replyCount/repostCount) are server-only + idempotent ✅; **user-doc aggregate counts (followerCount/followingCount/totalLikes/postCount) are client-writable** ❌ | **SEC-1** |
| Notification → deleted/hidden/blocked content | type-specific rule validation on notification create; `enrichReplyNotification` deletes bogus notifs | OK ✅ |
| Block applied while content on-screen | `BlockedUsersCache` filters; rule denies cross-block reads/writes. Cold-start + OtherProfileView-shell frame leak | 📄 CORR-3 (documented, accepted) |
| Account deletion cascade | `onUserDocDeleted` cascades posts/replies/follows/notifs/etc., resumable via queues | 📄 hard-cap orphan gaps (DEL-1, documented/accepted) |
| Admin dashboard mutates a live-listened doc | app listeners reflect moderation status; pending_review hidden by rule | OK |

---

## 2. PHASE 2 — FINDINGS

### 2.0 BRAND-WEDGE VIOLATIONS (decisions required — not changed unilaterally)

#### BW-1 — Follower/following counts displayed by default · **BLOCKER** · ✅ verified
- **Where:** `toska/OtherProfileView.swift:88–96` renders `followerCount` / `followingCount` as bold count badges, gated on `showFollowerCount`, which **defaults to `true`** (`OtherProfileView.swift:23`; load path `data["showFollowerCount"] as? Bool ?? true` at `:307`). The memory note `feedback_toska_do_not_build` lists "follower-count status" as a wedge-breaker that must never ship.
- **Why it matters:** This is exactly the forbidden "follower-count status." Default-on means every profile shows a public follower count unless the user opts out. Apple won't reject for this, but it violates the product's own non-negotiable brand wedge.
- **Note:** The uncommitted working-tree diff (ProfileView/SettingsView) is *adding* follower/following list links into Settings — moving toward MORE follower surfacing, not less. Surfacing this so the direction is intentional.
- **Recommended fix (pending decision):** Remove the count display from `OtherProfileView` (keep follow purely as a private feed filter, if follow is kept at all). See DECISION D1.

#### BW-2 — DM subsystem: UI cut, backend fully live · **BLOCKER** · ✅ verified
- **Evidence the UI is dead:** no `MessagesListView(`/`ConversationView(` instantiation; `MainTabView.swift:330` drops `.conversation` push intent.
- **Evidence the backend is LIVE:**
  - `firestore.rules` lines ~896–1095: `conversations/{convoId}` and `.../messages/{messageId}` accept reads/creates from participants (well-hardened, but *open for writes*).
  - `functions/index.js:2732 exports.onMessageCreatedModerate`, `:3234 exports.onMessageCreatedUpdateCount` — deployed and would fire on any message write.
  - `firestore.indexes.json:77` — `conversations` composite index still live.
  - 📄 `seedAppStoreDemo.js` seeds a demo conversation + 2 messages (per BACKEND_SMOKE_RESULTS.md) → **an App Review tester on the demo account could see DM data**.
- **Why it matters:** A product-cut surface that still accepts writes is both a brand-wedge violation and a reviewer red flag ("there's a messaging backend — is this a hidden chat feature?"). A motivated client could write directly to `conversations`/`messages` and exercise a chat system that's supposed to not exist.
- **Recommended fix (pending decision):** Lock the rules to `allow read, write: if false;`, undeploy the `onMessageCreated*` functions, drop the index, strip the demo seeder's conversation block, and (separately) delete the dead Swift files. **Do NOT rip out a whole subsystem without sign-off** — see DECISION D2.

### 2.1 Security findings

#### SEC-1 — User-doc aggregate counters are client-forgeable · **BLOCKER/HIGH** · ✅ verified
- **Where:** `firestore.rules:230–248` (`users` update rule). The owner-update branch blocks only `handle`, `fcmToken`, `restricted*`, `confirmedAdult*`, and legacy-PII fields. **`followerCount`, `followingCount`, `totalLikes`, `postCount` are NOT in the blocked set.**
- **Impact:** Any authenticated user can `setData(["followerCount": 999999], merge: true)` on their own `users/{uid}` doc. These are the exact fields `OtherProfileView` reads and displays (BW-1). Result: forgeable social-proof / fake follower-count status. The Cloud Functions (`onFollowCreatedUpdateCounts` etc.) *also* write these via Admin SDK, so legit writes work — but nothing stops client overwrites.
- **Note on prior audits:** This reconciles the contradiction between agents — the *post* counters (likeCount/replyCount/repostCount on `posts/`) ARE locked (rules line 727); the *user-doc aggregates* are not. `FEATURE_AUDIT_2026-06-03.md §7.5` called this out; it is real.
- **Recommended fix:** Add `followerCount`, `followingCount`, `totalLikes`, `postCount` to the owner-update `hasAny([...])` deny list (lines 235–237), so only the Admin SDK (Cloud Functions) can write them. Add a rules-test in `firestore-tests/`. *If the follow feature is removed entirely (D1), the follower/following fields become moot but `totalLikes`/`postCount` still need locking.*

#### SEC-2 — `onMessageCreatedModerate` counter-correction can drift on failure · **MED** · 📄 (agent-identified, not re-verified)
- `functions/index.js:~2767–2775`: when a DM is moderation-deleted, the `messageCount` decrement is best-effort; a failed delete logs a warning and leaves the count inflated, no retry. Moot if BW-2 is resolved by undeploying DM functions.

### 2.2 Correctness / edge cases (carried from prior audits — 📄, mostly accepted)
- **CORR-1 — Email enumeration on password reset:** `PasswordResetView` surfaces error 17011 (no-account) verbatim. Firebase project-level Email Enumeration Protection is 📄 reported enabled on prod+staging, so the residual is UI-only. **HIGH-ish, mitigated.** Worth a small UI fix (collapse to neutral message like SignIn does). ⏳ verify Firebase console flag at submission.
- **CORR-2 — `FeelingCircleView` fully built but zero call sites:** 📄 (FEATURE_AUDIT §4.6). Either dead code or a wiring regression. Rules for `feelingCircles` are live. ⏳ verify reachability. Decision-adjacent (D3).
- **CORR-3 — Block cold-start frame leak:** `BlockedUsersCache` listener warm-up + `OtherProfileView` shell render before mutual-block check → brief content flash. Documented, accepted, rule-enforced underneath.
- **DEL-1 — Account-deletion cascade hard caps:** notifications >25K, circle messages >500, reports >500 not requeued; other users' `blocked/{deletedUid}` reverse rows and `posts/*/likes/{deletedUid}` mirrors not cleaned (residual uid refs + likeCount inflation). 📄 5.1.1(v)/GDPR-relevant; documented/accepted. Re-confirm acceptable before submit.
- **MOD-1 — Moderation evasion gaps:** bare formatted phone numbers, combining-mark uppercase names, lowercase `ig:` shorthand bypass create-time detector; soft-flag pipeline + admin SLA catch within sub-second. 📄 LOW/MED, accepted.

### 2.3 Apple App Review compliance status
| Guideline | Status | Notes |
|---|---|---|
| 5.1.1(v) account deletion | ✅ real in-app delete + cascade | DEL-1 orphan gaps to confirm-accept |
| 1.2 UGC safety | ✅ report + block + server moderation + 24h SLA copy | **Mute not implemented** (report+block only — generally acceptable). Verify report/block backend effects on device. |
| Age gate | ✅ server-enforced (`confirmAdult`, rule-gated publish) | 📄 confirmAdult fire-and-forget on OAuth signup (accepted UX papercut) |
| Sign in with Apple | ✅ present (`AppleSignInHelper`) | required because Google SSO offered — satisfied |
| Privacy nutrition label | ⏳ verify | no `setUserID` (crash data unlinked) per 📄; no ad/tracking SDKs per 📄; confirm image-picker decision (none wired) |
| App Check enforced (prod) | ⏳ **verify at submission** | 📄 noted as silently flippable to Unenforced during outages |

---

## 3. DECISIONS — RESOLVED 2026-06-07
- **D1 (Followers): KEEP follow + counts.** Product-owner decision, overriding the brand-wedge "no follower-count status" guidance with full context. No follow UI removed. SEC-1 (count fields can't be forged) was still applied. *Note: this reverses the prior `feedback_toska_do_not_build` guidance for the follower-count item specifically; days-since-counter and matching/dating remain forbidden.*
- **D2 (DMs): REMOVE.** Done (see 0.1 #2,#4,#5,#6,#7).
- **D3 (FeelingCircle): CUT.** Done (see 0.1 #3,#7).

### CLEAN-1 — Inert DM/circle plumbing remnants · **DONE 2026-06-07** · build + rules verified
Removed all reviewer-visible and internal DM/circle remnants; app compiles (`BUILD SUCCEEDED`) and rules suite still 129 passing:
- `SettingsView.swift` — removed the `notifyMessages` toggle + model field + pref read/write (kept the `FieldValue.delete()` legacy-scrub so stale field is cleaned from existing docs).
- `NotificationsView.swift` — removed the `type == "message"` tap/color/icon/display-text branches (legacy message notif now falls through to a no-op via empty postId).
- `PushNotificationManager.swift` — removed `.conversation` Kind, the `conversationId` field + parsing, and the dead `"message"` push route.
- `MainTabView.swift` — removed the `.conversation` intent switch arm.
- `NotificationNames.swift` — removed `openConversationFromPush`.
- `ToskaTheme.swift` — removed `ReportTarget.conversation` (+ all switch arms), `Telemetry.ReportTargetType.conversation`, `SkeletonFeed.Kind.conversation`, and `SkeletonConversationRow`.
- `UserDefaultsKeys.swift` — removed the unused `messageDraft(conversationId:)` helper.
- `firestore.rules` — removed the dead `type == 'message'` notification-create branch.
- `firestore.indexes.json` — kept the `messages`/`authorId` fieldOverride (serves circle-message draining via `cleanupExpiredCircles`).

## 4. Could-not-fix-safely (yet) / blocked on decisions
- All of section 2.0 + SEC-1's follower portion are gated on D1/D2. SEC-1's `totalLikes`/`postCount` lock is safe to do independent of any decision.
- Phase-2 verification (signed simulator build, rules emulator, device test for `confirmAdult`/App Check paths) not yet run — pending which fixes are authorized.

## 5. Remaining blockers for GO
Code blockers (BW-1 via D1, BW-2, SEC-1, D3) are **resolved + locally verified**. Remaining gates are operational, listed in **§0.2**: (1) prod deploy of rules/indexes/functions — *needs per-round deploy authorization, not yet done*; (2) re-confirm App Check Enforced on prod; (3) optional CLEAN-1 follow-up; (4) confirm-accept pre-existing CORR-1/DEL-1.

**Revised recommendation: 🟡 GO once the deploy in §0.2 lands and App Check is re-confirmed.** No unresolved code-level blockers remain.

---

## APPENDIX A — per-screen map, APPENDIX B — full function table, APPENDIX C — full rules-by-collection audit
(Captured from the four mapping passes; available on request — omitted here for length. Key load-bearing claims in those appendices were independently re-verified above where they conflicted: DM reachability, follower-count display+default, and user-doc counter writability.)
