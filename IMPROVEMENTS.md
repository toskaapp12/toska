# Toska Improvement Backlog — Synthesis

## Executive Summary

This is a mature, security-hardened codebase that has clearly survived multiple audits — idempotency machinery is correct and well-documented, optimistic-update logic is centralized, caches handle cross-account races carefully, and the inline comments preserve hard-won bug-fix history. The dominant cost across nearly every area is **not correctness but duplication and file cohesion**: the same logic (cleanup loops, counter triggers, share-card renderers, pre-post moderation gates, data-loaders, card skeletons) is hand-mirrored across 3-12 sites and kept in sync by comment discipline alone. Three mega-files (`index.js` at 4352 lines, `FeedView.swift` at 2817, `ToskaTheme.swift` at 1801) conflate unrelated concerns and bury the real logic. The **design system is genuinely well-built but barely adopted** — 344 raw `Color(hex:)` and 552 raw `.system(size:)` calls bypass it, and its reactive-theme mechanism is dead code. The two highest-leverage *risk* items are the crisis/PII wordlists drifting between server and client (a real safety regression class) and the custom-styled Apple/Google sign-in buttons (a likely App Store rejection). Accessibility (Dynamic Type, VoiceOver labels) is the weakest cross-cutting dimension for a self-described "reading app." There are zero automated tests around the most subtle logic (idempotency, thread-build, onboarding rollback).

---

## TOP 10 — DO THESE FIRST

Ranked by impact-to-effort. Brand-safe, concrete, high-leverage.

| # | Title | Area | Impact | Effort | Why |
|---|-------|------|--------|--------|-----|
| 1 | Route client `crisisLevel` through the same normalize+no-space matcher the server uses | fn-moderation | high | small | `su1c1dal` / `s u i c i d e` gets the server hold but NOT the gentle check-in — fails the exact person the feature exists for |
| 2 | Replace custom Apple/Google text buttons with `SignInWithAppleButton` + official Google asset | ios-auth | high | medium | Effectively launch-blocking — hand-rolled auth buttons are a known HIG/4.8 rejection |
| 3 | Move the ~1035-line PII/moderation engine out of `FeedView.swift` into `ContentModeration.swift` | ios-feed | high | small | Pure move, no behavior change; nearly halves the file and makes moderation findable |
| 4 | Make crisis/PII wordlists a single source of truth (JSON → Node + iOS resource) | fn-moderation | high | medium | Removes the entire "updated server, forgot client" safety-regression class |
| 5 | Collapse 9 cleanup helpers + 3 resume schedulers into paginated-deleter factories | fn-lifecycle | high | medium | ~200+ lines of duplicated delete loops; the orderBy bug at :312 is exactly what drift causes |
| 6 | Extract `evaluatePrePostGate(_:)` for the 5 copy-pasted compose/reply moderation gates | ios-compose | high | medium | A new check or gate-order change must hit 5 sites or surfaces silently diverge |
| 7 | Lazy-load profile tabs instead of eager-fetching all six datasets on open | ios-profile | high | medium | Cuts profile-open Firestore reads 60-80% for users who don't switch tabs |
| 8 | Add header count badges via `getCountFromServer` for every moderation queue | admin | high | medium | Moderator on default tab sees `flagged:0` while posts wait unseen; 1 read vs 50 |
| 9 | Extract `renderCard(...)` builder for the 6 admin queue loaders | admin | high | medium | ~400 lines of duplicated card skeleton; restrict-author block pasted verbatim 4× |
| 10 | Fix Explore "trending" to actually rank by engagement (recency-decayed likeCount) | ios-discovery | high | small | The likeCount tiebreaker never fires — "explore" is just the 5 newest posts |

---

## Findings by Theme

### Theme 1 — Decompose the mega-files

The single biggest maintainability lever. Three files conflate 4-6 concerns each.

- **`FeedView.swift:1781-2815`** — cut the 1035-line "Content Safety / Content Moderation / handle-generation" block into `ContentModeration.swift` + `HandleGeneration.swift`. Imported by 6 non-feed files. Pure move. *(high / small — do first)*
- **`FeedView.swift:70-769`** — decompose the 700-line single-expression body into named subviews: `takeBreakBanner` (97-127), `newPostsBanner` (134-159), `feedTabs` (165-194), `inlineSearchBar`+`categoryPills` (257-363), `emptyFeedState` (412-466), post `ForEach` (468-519). Preserve documented gotchas (VStack-not-LazyVStack, no outer `.id`). *(high / medium)*
- **`functions/index.js` (whole file, 4352 lines)** — split into `lifecycle.js`, `counters.js`, `moderationTriggers.js`, `push.js`, `callables.js`, `audit.js`, shared `util.js`; `index.js` becomes a barrel re-export. Do incrementally, one module per PR. The inline `MOD_*` lists belong in the existing sibling `moderation.js`. *(medium / large)*
- **`ToskaTheme.swift` (1801 lines)** — misnamed junk-drawer; real tokens live in `ToskaDesign.swift`. Move `Color(hex:)` init + cached brand colors + `ToskaFormatters` into `ToskaDesign.swift`; split `AgeGate`/`Policy`/`Report`/`Skeletons` into own files. At minimum rename to `ToskaCore.swift`. Use xcodegen/Xcode to add files safely rather than fearing pbxproj. *(medium / medium)*
- **`PostDetailView.swift:1094-1445`** — lift the self-contained reply-thread machinery (two listeners, recombine, tree-build, stamping) into a `@MainActor ReplyThreadModel`; makes it unit-testable and lets `ReplyDetailView` reuse it. *(low / large — only if this view keeps growing)*
- **`OnboardingView.swift` (811 lines)** — pull static copy (`moodPrompts`, `breakupStages`) into `OnboardingContent`, persistence into an `OnboardingViewModel`. *(medium / large)*

### Theme 2 — Kill the duplication (DRY)

Same logic hand-mirrored across many sites; drift is the recurring failure mode.

**Cloud Functions**
- **`index.js:208-458`** — 5 cleanup helpers are byte-identical paginate-500/batch-delete loops; extract `paginatedBatchDelete(queryFn)`. `cleanupPosts`/`cleanupReposts` share a second shape → `paginatedDocDelete(queryFn, perDocFn)`. *(high / medium)*
- **`index.js:3619-3701`** — 3 resume schedulers are the same queue-drainer; extract `drainQueue(collectionName, workerFn)`. *(medium / small)*
- **`index.js` counter triggers (1390, 1422, 1516, 1529, 1559, 1590, 1621, 1642, 1978, 2003)** — 6+ single-ref counters share one body; extract `incrementCounter(eventId, subKey, ref, field, delta)`, collapsing ~120 lines. The like/follow paired triggers (1314, 1351, 1817, 1844) fold on top. *(medium / medium)*
- **`index.js:906` vs `:3746`** — `subs[]` and `ALLOWED_SUB_RESUME` already drifted once (T-3, stranded GDPR residue); hoist one `USER_SUBCOLLECTIONS` const both reference. *(low / small)*
- **`index.js:1386, 1420, 1482`** — the "what counts as a counted reply" rule lives in 3 places; extract one `isReplyCounted(replyData)` predicate. *(low / small)*

**Firestore rules**
- **`firestore.rules` (~10 sites)** — inline `!exists(.../blocked/...)` → `function notBlockedBy(targetUid)`. *(medium / small)*
- **`firestore.rules:597, 831, 939`** — the `moderationStatus=='live' \|\| authorId==uid \|\| isAdmin()` trio → `function moderationVisible(data)`; highest-churn pattern in the file. *(medium / small)*
- **`firestore.rules:208, 240`** — handle-validation triple → `function validHandle(h)`. *(low / small)*
- **`firestore.rules:481-526`** — `saved`/`liked` and `likedReplies`/`savedReplies` are byte-identical pairs; share `isOwnerOnlyIndex()` + cross-reference comment. *(low / small)*
- **`firestore.rules:601-757`** — the 150-line post-create expression: extract `validPostRepost()` / `validReplyRepost()` from the two near-parallel repost sub-branches. *(medium / medium)*

**Admin**
- **`admin.html:348-913`** — extract `renderCard({...})` + `restrictAuthorButton()` + `metaRow()`; restrict-author block pasted verbatim at 454, 557, 663, 853. Cuts file ~in half. *(high / medium)*
- **`admin.html` loaders** — wrap each in `runLoader(container, fn)` for uniform loading/error UI (currently inconsistent error styles). *(low / small)*

**iOS**
- **5 compose/reply sites (`ComposeView:805`, `PostDetailView:1481`+`1722`, `ProfileView:1581`, `AnniversaryCardView:230`)** — extract `evaluatePrePostGate(_:) -> PrePostGate` enum. Riskiest duplication in compose. *(high / medium)*
- **3 share-card renderers (`DailyMomentView:349`, `WeeklyRecapView:285`, vs `ShareCardView:677`)** — route through `ShareCardView` or a shared `ToskaQuoteCard`; DailyMoment's hand-rolled image lacks ShareCardView's `.localOnly`/expiry privacy guards. ~120 lines. *(medium / medium)*
- **`ShareCardView:429-497` vs `677-749`** — preview and export are the same tree with a scale factor; extract `CardBody(scale:)` so WYSIWYG is structural. *(medium / medium)*
- **`FeedViewModel:387-443`** — `fetchLiked/Saved/RepostedPostIds` are identical; one `attachIdListener(query:transform:)` keeps the captured-uid safety pattern consistent. *(medium / small)*
- **`ProfileView:797` & `:1023`** — `loadSavedPosts`/`loadLikedPosts` 95% identical → `loadPostRefs(from:)`. *(medium / small)*
- **`ProfileView:1077` & `OtherProfileView:350`** — reply fan-out duplicated → shared `MyReply.load(forAuthor:limit:)`. *(medium / medium)*
- **3 user-doc creation sites (`CreateAccountView:335`, `AppleSignInHelper:119`, `SplashView:197`)** — already drifted on `acceptedPolicyVersion`; extract `createUserDocument(uid:email:handle:extraFields:)`. *(medium / medium)*
- **4 email-regex sites (`CreateAccountView:260`, `SignInView:157`, `PasswordResetView:116`, `SettingsView:918`)** — one `String.isValidEmail`. *(medium / small)*
- **3 orphaned-auth rollback sites (`CreateAccountView:394`, `AppleSignInHelper:160`, `SplashView:263`)** — extract `rollbackOrphanedAuthAccount(...)`; SplashView's Google path is missing the hard-signout guard. *(medium / medium)*
- **`CreateAccountView:227` & `OnboardingView:262`** — extract one `AgeAndPolicyGate` wrapper for the legally-sensitive gate. *(medium / medium)*
- **`BlockedUsersCache:47` & `UserHandleCache:62`** — extract `UidScopedListener` for the security-relevant captured-uid re-check. *(medium / medium)*
- **`ExploreView:498-606`** — 3 post-query+expiry+parse blocks → `liveNonExpiredPosts(query:)`. *(medium / medium)*
- **`SettingsView:142-220`** — 5 NavigationLink rows hand-roll HStack+chevron (with inconsistent tokens); add `navRow(...)` mirroring existing `actionRow`. *(medium / small)*

### Theme 3 — Firestore read-cost

Read-sensitive app; several home-screen and profile paths over-fetch.

- **`ProfileView:330`** — eager-load all 6 tab datasets on open → lazy per-tab. Biggest single lever (60-80% fewer reads). *(high / medium)*
- **`FeedViewModel:359-371`** — `refreshAll()` fires 9 queries per refresh; `fetchEmotionalWeather` (6h) is a strict subset of `fetchMostUnsaidAndDailyMoment` (24h) — fetch the 24h set once, derive both. ~50 reads/refresh. *(medium / medium)*
- **`FeedViewModel:618-727`** — `fetchPosts` pulls 60 to render 20; name the constants and consider lowering the candidate pool to ~40. *(medium / medium)*
- **`admin.html:609-625`** — crisis queue filters `crisisReviewedAt` *after* `limit(50)`, so unreviewed older items silently vanish once >50 concerning posts exist; add the composite index and filter server-side. Correctness-of-coverage. *(medium / medium)*
- **`ExploreView:411-441`** — `fetchPeopleFeelingThis` reads 50 to surface 5 handles; derive from the `fetchPostsForTag` snapshot already fetched, or lower limit to ~20. *(medium / small)*
- **`ProfileView:665` & `:747`** — same `authorId` count() aggregation fired twice per open; drop one. *(low / small)*
- **`WeeklyRecapView:213-269`** — two full-week queries (limit 50 + 100); fetch once at 100, derive all three stats. *(low / small)*
- **`OnboardingView:696`** — `fetchStageCohortCount` re-reads the whole counts doc on every tap; fetch once, cache, index locally. *(low / small)*
- **`ContentView:290-378`** — new-account verify loop polls getDocument up to 8× (~28s); a one-shot snapshot listener fires instantly and costs 1 read. *(low / small)*
- **`NotificationsView:554`** — 3s mark-all-read sweep fires even with zero unread; guard with `contains(where: isUnread)`. *(low / small)*
- **`PostDetailView:1390`** — reply-repost state = N getDocument reads per recombine (up to 500); batch via `(authorId, originalReplyId)` index, or cache already-stamped ids. *(low / medium)*
- **`MainTabView:28,387`** — once visited, tab listeners run for the whole session; verify TopView/ProfileView actually pause heavy listeners (opacity-0 views don't get `onDisappear`). *(low / medium)*

### Theme 4 — Design-system adoption

Strong foundation, near-zero adoption — the "one place to change the palette" promise is currently false.

- **App-wide** — 344 raw `Color(hex:)` + 552 raw `.system(size:)` bypass the tokens. Don't big-bang: promote the 5 most-repeated hexes (`e4e6ea`×33, `c45c5c`×26, `c9a97a`×23, `0a0908`×20) to named statics, sweep file-by-file, add a DEBUG lint that fails on new raw `Color(hex:`. *(high / large)*
- **`LateNightTheme.swift:66-98`** — the reactive theme mechanism is dead: zero views hold `@Environment(LateNightThemeManager.self)`, so the 5am flip never reliably repaints (and the 60s timer at :53 burns wakeups for nothing). Either make `ToskaColor` route through an `@Observable` read, or add the `@Environment` to the root container. *(high / medium)*
- **32 stray Georgia refs across 11 screens** (e.g. `FeedView:417`) — system standardized on Newsreader but two serifs ship side-by-side; replace with `ToskaFont.serifItalic(size:)`. Confirm whether ShareCardView's 12 Georgia refs are a deliberate divergence and document it. *(medium / medium)*
- **`ToskaDesign.swift:82-87`** — `ToskaEmotion` forwards to `tagColor`/`sharedTags` that live in `FeedView` — dependency arrow points the wrong way. Move the tag data down into the design layer. *(low / small)*
- **`ToskaDesign.swift:111-138`** — modifier doc-comments disagree with code (`toskaScreenTitle` says 26 but is 24; `toskaPostBody` says 16/lineSpacing 8 but is 14/4). Fix comments; drop redundant size restatements. *(low / small)*
- **`ToskaDesign.swift:147-173`** — `ToskaCardShadow`/`ToskaFloatingShadow` duplicate light/dark stacks; extract a `ShadowSpec` table. *(low / small)*
- **`OfflineBannerView:17`, `MainTabView:239`** — status colors hardcoded as hex; promote to `ToskaColor.statusPositive/Negative/Attention`. *(low / small)*
- **`NotificationsView:409`** — `iconColor`/`iconName` are parallel switches; collapse to one `enum NotifType { var icon; var color }` (mirrors ToskaEmotion). *(low / small)*

### Theme 5 — Accessibility

Weakest cross-cutting dimension for a "reading app."

- **Type system (whole app)** — near-zero Dynamic Type; the only related line *clamps* scaling (`toskaApp.swift:204`). Use `Font.custom(name, size:, relativeTo: .body)` for content styles so Newsreader scales. Table-stakes for a reading product and a likely review point. *(high / large)*
- **`ProfileView:129`, `OtherProfileView:130`, `SettingsView:485`** — icon-only tab buttons and `Toggle("")` toggles have no VoiceOver labels; add `.accessibilityLabel` + `.isSelected`. *(medium / small)*
- **`NotificationsView:278`** — rows read icon + 2 Texts as disjoint fragments and never convey unread; `.accessibilityElement(children: .combine)` + unread-state label. Same on TopView hero/rest rows. *(medium / small)*
- **`WeeklyRecapView:24, 158`** — close button missing `.accessibilityLabel("Close")` (DailyMoment/ShareCardView have it); stats read as disconnected `12`/`posts`. *(medium / small)*
- **`admin.html:92`** — no keyboard nav for the queue; roving tabindex on tabs, `tabindex=0` + Enter on cards, j/k + a/d/r shortcuts. *(medium / medium)*
- **`admin.html:58, 1023`** — toast has no `role=status`/`aria-live`; timers leak (no `clearTimeout`). *(low / small)*

### Theme 6 — Safety / moderation parity

The highest-leverage *risk* cluster. Brand-aligned, anonymity-preserving.

- **`FeedView.swift:1875` vs `index.js:2640`** — client `crisisLevel` is plain `.contains` while server normalizes leet/unicode/spacing; route client through the same matcher (already ported for the name detector). *Top finding.* *(high / small)*
- **`index.js:2541` ↔ `FeedView:1800`** — crisis lists kept in sync by "Mirror of" comments only; ship one JSON consumed by Node + bundled as iOS resource. Same for name/title wordlists. Removes the whole "updated server, forgot client" class. *(high / medium)*
- **`index.js:2692`** — `MOD_THREAT`/`MOD_HARASSMENT` use raw `text.includes` while crisis is evasion-hardened, so `k y s` bypasses; reuse `matchesCrisisPhrase` for all phrase axes. *(medium / small)*
- **`index.js:2396-2480`** — `containsPII` runs 4 pre-checks then calls `containsNameOrIdentifyingInfo`, which the comment says is "a strict superset" — two parallel PII detectors in two files. Delete the redundant pre-checks or fold their unique bits into `moderation.js`. *(medium / medium)*
- **`moderation.js:660-737`** — detector re-canonicalizes the same tokens 2-3× per call; compute canonical token once and reuse across Layers 4/4.5. *(low / small)*

### Theme 7 — Tech debt & stale narrative

- **`index.js:460-488`** — `logCounterDrift` is fully dead and its comment implies drift alerting exists when it doesn't (worse than nothing); delete it. If drift alerting is wanted, make it a Cloud Monitoring policy. *(medium / small)*
- **`index.js:3965-4036`** — `reconcileMyCounts` is the last `onRequest` with 30 lines of hand-rolled App Check + Bearer + verifyIdToken; migrate to `onCall({enforceAppCheck:true})` (the giphyProxy/confirmAdult comments document the exact payoff). *(medium / small)*
- **`index.js:1-13`** — no `setGlobalOptions`; the deletion cascade runs at the 256MB floor it's explicitly paginating to avoid OOM-ing. Raise `onUserDocDeleted`/resume sweeps to 512MB + explicit timeout, and add `maxInstances` to counter triggers (viral-post bill-spike insurance). *(medium / small)*
- **`index.js:675-699`** — `claimTriggerEvent` now has one caller (synthetic crisisAlert key); its big "THE dedup primitive" comment is stale. Rename/relocate or fold into `claimedTransaction`. *(low / small)*
- **`admin.html:185-193`** — N-9 comment asserts Firestore App Check is NOT enforced; memory verified 2026-06-11 that it IS. This 80-line stale narrative actively misleads; trim to one line, move history to AUDIT.md. *(low / small)*
- **`firestore.rules` (:20, :819, :921, :1163)** — comments cross-reference rules by hardcoded line numbers that have already rotted (`:518`→actually `:597`); use function/match names instead. *(low / small)*
- **`PostDetailView.swift:2047`** — block dialog says "posts or messages" after DMs were cut; the parallel `ReplyDetailView:252` correctly says "posts or replies." Fix the string. *(low / small)*
- **`OtherProfileView:105`, `MainTabView:156`, `NotificationNames:36`** — dead DM/conversation code paths and comments; tracked cleanup so contributors don't mistake them for live features. *(low / small)*
- **`firestore.rules:103-141`** — legacy-PII field list enumerated in two functions in different shapes; colocate with a "KEEP IN SYNC" canonical list, or finish `scrubLegacyPII` to retire both guards. *(medium / medium)*
- **`WeeklyRecapView:36-156`** — mangled indentation from a bad paste; run swift-format. *(low / small)*
- **TopView/Explore/Notifications/FeedViewModel** — unconditional emoji `print()` on hot paths in release; wrap in `#if DEBUG` or route to os_log. *(low / small)*

### Theme 8 — Admin moderator-workflow

- **`admin.html:305`** — no auto-refresh or manual refresh; moderators work a frozen snapshot. Add a refresh button + optional 30-60s poll (crisis queue especially). *(medium / small)*
- **`admin.html:367`** — bulk actions only on pending-posts; extend safe/recoverable bulk (dismiss/unflag) to reports + flagged via a generic `bulkToolbar`. Keep destructive bulk out. *(medium / medium)*
- **`admin.html:389, 472`** — bulk approve runs serially with per-item `alert()` and never re-enables the button on throw; use `Promise.allSettled` + one summary toast. *(medium / small)*
- **`admin.html:575` vs `472`** — verify approving a pending reply (only flips `moderationStatus`, doesn't clear `pendingReason`) won't get re-detected by `onReplyUpdated` into an approve-loop. *(low / medium — verification)*

### Theme 9 — UX polish

- **`ExploreView:584`** — "trending" actually shows newest; recency-decayed re-rank (mirror TopView's `feltScore`). *(high / small)*
- **`FeedView:365`** — Following tab flashes "you follow no one" during in-flight fetch; gate on `hasLoadedFollowingOnce`. *(low / small)*
- **`FeedView:721`** — "X new posts" banner fires on score reordering, not arrivals; drive off a real id-diff or remove. *(low / small)*
- **`CreateAccountView:138`** — password fields have no show/hide toggle and no inline match/length feedback on the highest-friction screen. *(low / small)*
- **`OnboardingView:165`** — welcome step shows a spinner where the "next" button should be while the acceptance read resolves; only gate step ≥1 forward. *(medium / small)*
- **`OnboardingView:279`** — "decline" silently deletes the just-created account with no confirmation; add one for the destructive path. *(low / small)*
- **`DailyMomentView:104`** — "screenshot this" CTA undercuts the cleaner branded share card; drop or soften to "keep this." *(low / small)*
- **`DraftsView:51`** — whitespace-only drafts render blank rows; swipe-delete is immediate with no undo on high-regret grief content. *(low / small)*
- **`ComposeView:497`** — 3 mode banners (letter/whisper/midnight) are near-identical; `modeBanner(...)` mirroring the existing `warningBanner`. *(low / small)*
- **`ComposeView:473`** — tag pill recomputes `tags.first(where:)` 4× per render; reuse the bound `tagData`. *(low / small)*
- **`ComposeView:417, 685`** — draft persisted to disk every keystroke; debounce 500ms-1s + flush on background. *(low / small)*
- **`GifPickerView:71`** — clear button bypasses the 400ms search debounce and re-fetches trending; route through the debounce + guard re-entry. *(low / small)*
- **`ComposeView:1051`** — GIF re-downloads on every consumer (compose→feed→detail); add an `NSCache` in `GifLoadGuard` behind the existing host/size guards. *(medium / small)*
- **`ShareCardView:522`** — font ladder keys off `text.count` (grapheme) while wrapping is UTF-16; emoji/CJK posts can overflow, and preview/render thresholds differ. Align ladders + add `minimumScaleFactor`/max-lines safety net. *(low / small)*
- **`ShareCardView:405-669`** — 12-way mood styling is 5 parallel switches indexed by the same Int with a magic `< 7` dark boundary; replace with one `[CardStyle]` array. *(low / medium)*

### Theme 10 — Testing gaps

Zero coverage on the most subtle, regression-prone logic.

- **`functions/` (no test runner at all)** — `claimedTransaction`/`claimTriggerEvent`/`setPostLive` are exported *for tests that don't exist*. Add firebase-functions-test + emulator covering: double-delivery increments once; thrown write leaves no claim doc; one sub-claim committed + sibling failing retries only the failing side; create+delete race converges. Highest-leverage CF gap. *(high / medium)*
- **Server↔client detector parity** — maintain one `{input, expectedFlag, expectedCrisisLevel}` fixtures file; run against JS in CI and load the *same* fixtures in a Swift unit test. Converts "keep in sync" comments into an enforced check. *(medium / medium)*
- **`PostDetailView:749, 1412`** — `buildThreadedReplies`/`flattenReplies` are pure functions with gnarly edges (orphans, parent-after-child, depth>max, live/held dedup); trivially testable without Firebase. *(medium / medium)*
- **`OnboardingView:468`, `CreateAccountView:296`** — handle-fallback, "only flip isComplete if both writes succeed," and rollback-on-double-failure are untested and have all regressed before. *(medium / medium)*

### Theme 11 — Product / brand ideas (all anonymity-safe, no metrics/social)

- **Tier the crisis hotline by detected language** (`FeedView` crisisLevel consumers + i18n lists) — you already ship foreign hotlines and detect ES/PT/FR crisis phrases; surface the matching country's hotline instead of the US 988 default. Quiet, non-gamified, meets in-crisis non-English users where they are. *(medium / medium)*
- **Anniversary self-timeline** (`AnniversaryCardView`) — when a user reflects on a past post, store it and on the next anniversary stack the original line + prior reflections ("a year ago you wrote this / six months ago you felt this / today…"). Deepens the existing reflections subcollection — a payoff the feature can only deliver over time. No new social surface, no de-anonymization, no counter. *(medium / medium)*
- **"Pick a line to share" for long posts** (`ShareCardView`) — let authors of 2000-char letters distill one line onto the card (the rest implied). Matches the existing "the things we can't say out loud travel the farthest" framing; produces far more shareable cards. Gate to long posts. *(medium / medium)*

*(Also structure the i18n crisis lists as `{phrase, lang, tier}` when they move to JSON, to enable per-language native-speaker review — `index.js:2582`.)*

---

## Quick Wins (small effort, real value)

1. **`FeedView:1875`** — route client `crisisLevel` through the server's normalize+no-space matcher. *(safety)*
2. **`FeedView:1781-2815`** — move the moderation engine into its own file (pure cut/paste).
3. **`index.js:460`** — delete dead `logCounterDrift` (and its misleading comment).
4. **`ExploreView:584`** — recency-decayed re-rank so "trending" means something.
5. **`PostDetailView:2047`** — fix "posts or messages" → "posts or replies."
6. **`admin.html:185`** — trim the stale App Check narrative to one correct line.
7. **`index.js:2692`** — reuse `matchesCrisisPhrase` for threat/harassment lists.
8. **4 email-regex sites** — one `String.isValidEmail`.
9. **`index.js:1-13`** — add `setGlobalOptions` + raise cascade memory/timeout + cap counter `maxInstances`.
10. **`ProfileView:665`/`747`** — drop the duplicate `authorId` count() aggregation.
11. **Accessibility labels** — profile/other-profile tabs, Settings toggles, WeeklyRecap close button (one-liners each).
12. **Hot-path `print()`** across discovery/feed — wrap in `#if DEBUG`.
13. **`OnboardingView:165`** — don't gate the welcome step's "next" behind the acceptance read.

## Bigger Bets (large effort, high impact — plan these)

1. **Replace custom Apple/Google sign-in buttons** (`SplashView:79`) — effectively launch-blocking for App Review; needs `SignInWithAppleButton` + official Google asset. *(high impact, medium-large)*
2. **Single-source the crisis/PII wordlists** across `index.js` / `moderation.js` / `FeedView.swift` via one JSON → Node + iOS resource. Retires an entire safety-regression class.
3. **Dynamic Type for the reading surfaces** — `Font.custom(…, relativeTo:)` across the type ramp. Table-stakes accessibility for a reading product.
4. **Design-system adoption sweep** — promote top hexes to tokens, fix the dead reactive-theme wiring, add a lint to stop new raw `Color(hex:)`/`.system(size:)`. Makes the "change the palette in one place" promise real.
5. **Modularize `functions/index.js`** into domain files (one module/PR) — unblocks everything else in CF and makes deploy diffs reviewable.
6. **Collapse the CF cleanup/resume/counter machinery** into deleter/drainer/increment factories — ~300+ lines gone, drift bugs (e.g. the `cleanupReplies` orderBy) eliminated at the source.
7. **Stand up automated tests** for the idempotency machinery, the thread-build pure functions, and the onboarding rollback state machine — the three places the comments admit bugs already landed.

---

**Already strong, don't touch for its own sake:** the idempotency/claimedTransaction reasoning, the optimistic-update centralization in `PostInteractionManager`, the cross-account stale-snapshot cache handling, App Check / doc-id / draft Data-Protection boundaries, the UTF-16 truncation + GIF hardening + pasteboard-expiry work, and the design-system *foundation* itself. The work above is overwhelmingly about consolidation, adoption, and finishing passes — not fixing broken things.