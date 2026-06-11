# toska — Comprehensive Feature & Functionality Audit

**App:** toska — an anonymous, breakup/heartbreak-focused social app ("for the things you couldnt say to your ex"). SwiftUI front end, Firebase (Auth, Firestore, Cloud Functions, FCM, App Check) backend.
**Date:** 2026-06-03
**Scope:** Every screen, feature, data flow, Firestore interaction, Cloud Function, safety/moderation surface, and privacy posture, documented page-by-page and feature-by-feature — plus how they interconnect.
**Method:** Six independent deep reads of the actual source (not assumptions), each owning a subsystem, with `file:line` citations throughout.
**Environments:** Debug builds → `toskastaging`; Release builds → `toska-4ebf4` (prod). Selected in `toskaApp.swift`.

---

## How it all works together (architecture synthesis)

**Shell & entry.** `toskaApp` (`@main`) installs an `AppDelegate` that boots Firebase (staging vs prod by build config), App Check (debug provider vs App Attest), URL cache, push delegates, haptics, and an auth-state listener. The single window hosts `ContentView`, a 4-state router: **loading → onboarding → logged-in (`MainTabView`) → splash (`SplashView`)**. A post-auth `verifyUserDocument` gate (up to 8 retries) confirms the Firestore user doc exists, resolves onboarding/policy-version status, self-heals a missing adult confirmation, then posts `.authDidVerify` — the signal that triggers the feed to load.

**The data spine.** Everything is Firestore. Top-level collections: `posts` (with `replies`, `likes`, `reflections` subcollections), `users` (with owner-only `private/data` for email/fcmToken/mood/prefs, plus `following`/`followers`/`saved`/`liked`/`savedReplies`/`likedReplies`/`blocked`/`presence`/`drafts`/`notifications` subcollections), `reports`, `conversations`+`messages` (DM infra — see findings), `feelingCircles`+`messages`, `dailyMoment`, `meta` (tag/stage counts), `pendingDeletions`, `admins`/`adminAuditLog`. **Every engagement counter (`likeCount`/`replyCount`/`repostCount`/follower aggregates) is server-owned** — Cloud Functions maintain them on subcollection writes; clients only do optimistic local math and never write the aggregate, which is what makes the transactional like/save/repost paths safe against drift.

**The moderation pipeline is the backbone of safety.** A post is created **hidden** (`moderationStatus: "pending_validation"`; feeds query `moderationStatus == "live"`, and an equality filter doesn't match field-less/pending docs — fail-closed). Client-side pre-publish gates (content-violation hard block, name/PII soft warning, crisis check-in) are UX rails only; the authoritative enforcement is server-side: `validatePost`/`onPostCreated` run normalized wordlist + crisis + PII detection, then promote to `live`, hold as `pending_review`, or flag. Edits re-moderate. Reports auto-hide at ≥3 distinct reporters and have a monitored 24h SLA. Crisis content pages admins.

**Shared runtime services** stitch the UI together: `UserHandleCache` (handle, `allowSharing`, `gentleCheckIn`, `breakupStage`, restriction state), `BlockedUsersCache` (synchronous off-main block checks + `.userBlocked` broadcast), `PostInteractionManager` (all like/save/repost transactions + optimistic broadcasts + notification writes), `NetworkMonitor`/`RateLimiter`, `HapticManager`, `Telemetry` (opt-out, PII-redacting). NotificationCenter is the in-app event bus: `.authDidVerify`, `.newPostCreated`, `.postDeleted`, `.userBlocked`, `.userDidSignOut`, the scroll/pop family, and push deep-link intents.

**Anonymity is the product wedge** and is enforced structurally: peers see only an anonymous `handle` + counts; email/token/mood live in the owner-only `private/data` subcollection; push payloads are server-authored and name no one; crash logs are PII-scrubbed; the rules layer denies cross-user reads of legacy PII and blocked relationships.

**The user journey:** sign up (email/Apple/Google) → 17+ age gate (server-attested `confirmAdult`) → Terms/Content-Policy acceptance (versioned) → onboarding (identity, breakup stage, mood, optional first post) → the **feed** (for-you ranked client-side by recency+engagement+mood+stage; following tab; daily prompt masthead; inline search/filter). From any post the user can open the **detail** (threaded replies, reply composer, like/save/repost/share/report/block), **compose** (letter/whisper/midnight modes, tags, GIF, safety gates), visit **profiles** (own: posts/likes/saved/replies tabs; others: posts/replies + follow/block/report), browse **top** ("felt the most") and **explore** (tags/trending/people), read **notifications**, and manage **settings** (privacy, notifications, followers/following, blocked users, weekly recap, account/delete/export, content policy). "Moment" features (daily moment, weekly recap, anniversary reflection, share cards) add reflective, shareable surfaces.

---

## Table of Contents

1. App Lifecycle, Authentication & Onboarding
2. Home Feed, Navigation & Post Interactions
3. Composing, Post Detail, Replies & Drafts
4. Profiles, Social Graph & Discovery
5. Notifications, Settings & Moment Features
6. Backend, Security Rules, Moderation, Safety & Privacy
7. Consolidated Findings, Risks & Recommendations

---

## 1. App Lifecycle, Authentication & Onboarding

This subsystem covers everything from cold launch through the first authenticated screen: Firebase bootstrap, App Check, the auth-state listener, the four sign-in paths (email / Apple / Google / returning), the 17+ age gate, the Terms/Content-Policy acceptance + version re-prompt, the anonymous-handle system, the multi-step onboarding, and the root routing state machine.

### 1.1 App entry & startup (`toska/toskaApp.swift`)

The app is a SwiftUI `@main App` (`toskaApp`, line 149-150) that installs an `AppDelegate` via `@UIApplicationDelegateAdaptor` (line 151). The single scene is a `WindowGroup` wrapping `ContentView()` (line 154-155), with three global modifiers: `.environment(LateNightThemeManager.shared)` (theme), `.dynamicTypeSize(...DynamicTypeSize.accessibility3)` (Dynamic Type capped — brand uses fixed sizes), and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` → `handleUniversalLink`.

**`didFinishLaunchingWithOptions` (line 38-124)** runs in order: (1) **App Check** — `#if DEBUG` `AppCheckDebugProviderFactory`, release `AppAttestProviderFactory` (returns nil on simulators); (2) **Firebase env** — DEBUG loads `GoogleService-Info-Staging.plist` → `toskastaging`, release bare `FirebaseApp.configure()` → `toska-4ebf4`; (3) FirebasePerformance link-assertion; (4) URLCache bumped 50MB/200MB; (5) push delegates → `PushNotificationManager.shared`; (6) `HapticManager.prepareAll()`; (7) **auth-state listener** that, on sign-in, starts `BlockedUsersCache`/`UserHandleCache`, and on sign-out stops both.

Push is **not** requested at launch — only via `PushNotificationManager.requestPermission()` from the in-context primer/Settings. **Universal links** (`handleUniversalLink`, line 181-213) accept only `https://www.toskaapp.com/p/{postId}`, validate the id via `isValidFirestoreDocId`, and post `.openPostFromPush` (the same path push taps use).

### 1.2 Root routing — `ContentView`

A 4-way `Group` switch: `isLoading||showVerifyError` → blue loading/retry splash; `showOnboarding && !onboardingComplete` → `OnboardingView`; `isLoggedIn` → `MainTabView`; else `SplashView`. Whole tree gets `.dismissKeyboardOnTap()` + a `ToskaPaperGrain()` overlay. A policy-update `fullScreenCover` re-prompts on version bump (decline → sign out, **not** delete).

**`verifyUserDocumentAsync` (line 254-355)** — the post-auth gate. Loops up to **8 attempts** reading `users/{uid}`; permission-denied/unauthenticated → stop + retry screen; transient → linear backoff (~28s worst case). If the doc exists, reads `hasCompletedOnboarding` (→ onboarding) and `acceptedPolicyVersion` (→ policy re-prompt), **auto-heals** a missing `confirmedAdult` via `confirmAdultServerSideFireAndForget`, flips `isLoggedIn`, records presence, and after 300ms posts **`.authDidVerify`** — the signal that triggers the feed load. Exhausting 8 attempts → "setting up your account" retry screen. Side effects: `recordPresence` (writes `users/{uid}/presence/{date}`), `pruneOldNotifications` (batch-deletes >90-day notifications).

### 1.3 Auth landing — `SplashView`

Blue screen with "im new here" / "sign in" / Google / Apple, plus terms/privacy links. **`createUserDocumentIfNeeded`** (shared by Google): existing user → sign-in path; new user → bounded handle gen (5s timeout, `anonymous_<8hex>` fallback), writes the user doc with **exactly** `handle, followerCount:0, followingCount:0, totalLikes:0, allowSharing:true, showFollowerCount:false, hasCompletedOnboarding:false, createdAt`, then writes `email` into owner-only `users/{uid}/private/data`, and posts `.showOnboarding` + `.userDidSignIn`. **Google sign-in** has orphaned-auth rollback (delete → fallback signOut) on any failure.

### 1.4 Email signup — `CreateAccountView`

Shows the anonymous handle with a **shuffle** reroll, email, password + confirm (≥8 chars, `.newPassword` for Keychain strong-password). **No Firebase Auth account is created until the age + policy gates pass** — `attemptCreateAccount` only sets `showAgeGate`. `createAccount` (after gates) creates the user, writes the user doc (six base fields **+** `acceptedPolicyVersion` + `acceptedPolicyAt`), writes email to `private/data`, sets the local `recentlyConfirmedAdult` flag, awaits `confirmAdultServerSide` (`try?`), and has full orphaned-auth rollback.

### 1.5–1.6 Email sign-in / reset

`SignInView` wraps `Auth.signIn` in a 30s timeout; success → `.userDidSignIn`; errors → `friendlyAuthErrorMessage`. `PasswordResetView` sends a reset (30s timeout) with a "link sent" state. **Wrong-password (17009) and no-account (17011) collapse to one neutral message on sign-in** for anti-enumeration; the **reset path does not collapse** (residual enumeration vector — see findings).

### 1.7 Apple sign-in — `AppleSignInHelper`

`@StateObject ObservableObject` holding the pending continuation. Requests `[.email]` with a SHA-256 nonce; saves the Apple authorizationCode to the keychain for later revocation. New user → same six base fields (no policy/adult), `.showOnboarding`; existing → sign-in. Full rollback. Token revocation retries 4× with backoff. Keychain items are service-scoped. `randomNonceString` uses rejection sampling (no modulo bias).

### 1.8 Onboarding — `OnboardingView`

5 steps: welcome → identity (shows anonymous handle) → **stage** ("where are you in it", 7 options, with live cohort count from `meta/breakupStageCounts`) → **mood** (emotion grid) → **first post** (time-aware prompt → ComposeView). The **age/policy gate runs inside onboarding** (`checkAcceptanceStatus`) for Apple/Google new users: reads/consumes the local `recentlyConfirmedAdult` flag + the user doc; shows `AgeGateView` then `PolicyAcceptanceView` if needed. Forward buttons spinner-block until the gate resolves. **Decline → `declineAndSignOut`** deletes the (already-created) Apple/Google account. Stage/mood/onboarding-complete writes go to `private/data`/main doc and are awaited (surface retry alerts on failure).

### 1.9 Age gate, policy & server confirmation (`ToskaTheme.swift`)

`AgeGateView` — self-declared 17+, **no DOB collected, no records written during the screen** (email path runs it pre-account). `PolicyAcceptanceView` — scrollable full ToS/Content Policy with a **required checkbox** (App-Review informed-consent defensibility); `isReviewMode` variant for Settings. `currentPolicyVersion = 1`. `recordPolicyAcceptance` writes `acceptedPolicyVersion`/`acceptedPolicyAt` only. `confirmAdultServerSide` calls the **`confirmAdult` Callable** (`enforceAppCheck`, 5/hr), the **only** writer of `confirmedAdult` (rules deny clients).

### 1.10 Caches & wiring

`UserHandleCache` (`@Observable` singleton, started on sign-in) listens on `users/{uid}` + `private/data` for handle/allowSharing/gentleCheckIn/breakupStage/restriction, with captured-uid rechecks. `UserDefaultsKeys` centralizes `pushPrimerShown`, compose-draft keys, and the per-uid `recentlyConfirmedAdult` bridge flag. This subsystem **posts** `.showOnboarding`/`.userDidSignIn`/`.userDidSignOut`/`.authDidVerify`/`.openPostFromPush`; `.authDidVerify` triggers the feed load.

### 1.11 Edge cases & reviewer notes

Orphaned-auth rollback on all three new-account paths; bounded timeouts (5s handle, 30s sign-in/reset, ~28s doc-verify); transient-vs-permanent classification in doc verify; email-enumeration collapse on sign-in (with project-level Email Enumeration Protection as the authoritative fix). **Reviewer angles:** age gate is account-blocking before any content; email lives only in owner-only `private/data`; the in-app versioned policy names the publisher (SALTE DEVELOPMENT LLC), commits to 24h moderation, and discloses Firebase data use with analytics opt-out. **Residual:** the password-reset path can reveal account existence (17011) unless Firebase Email Enumeration Protection is enabled.

---

## 2. Home Feed, Navigation & Post Interactions

This section documents the home-feed surface (`FeedView`), its view-model (`FeedViewModel`), the post card (`FeedPostRow`), the shared interaction service (`PostInteractionManager`), and the app's custom tab bar / deep-link router (`MainTabView`), plus the supporting infrastructure (`NetworkMonitor`/`RateLimiter`, `HapticManager`, `OfflineBannerView`, `KeyboardDismiss`, `NotificationNames`).

### 2.1 Tab Bar & App Shell (`MainTabView.swift`)

The `Tab` enum has only **four** cases — `feed, top, notifications, profile` (`:6`). The fifth slot is the **compose** button (circular accent `+`, `:125-140`), which opens a `ComposeView` full-screen cover. Bar order: Home, Top (chart), Compose (+), Notifications (bell w/ badge), Profile.

**Lazy keep-alive:** only `.feed` is in `loadedTabs` at cold start; other tabs are instantiated on first selection and **never torn down** (visibility via `.opacity`/`.allowsHitTesting`), preserving scroll position + nav state. `feedVM` is a `@StateObject` owned here. Tab switches play a `.tabSwitch` haptic, post `.dismissAllSheets`, animate `selectedTab`. **Active-tab re-tap**: Home/Top/Profile scroll-to-top; the Notifications bell pops to root (`.popNotificationsTabToRoot`).

**Unread badge** (`:160-174`): a capsule on the bell capped to "99+", driven by a **snapshot listener** on `users/{uid}/notifications` where `isRead==false` limit 100, with a `currentUser.uid == uid` recheck in the callback, re-attached on foreground, torn down on disappear/sign-out. Selecting the notifications tab with `unread>0` triggers a 3s-debounced `markAllNotificationsRead()` (batch pages of 100).

**Push deep-link routing:** `.openPostFromPush` → feed + `pushPostId` (presents `PostDetailView` placeholder that self-fetches); `.openProfileFromPush` → `OtherProfileView`; `.openComposeFromEmptyFeed` → compose. **DM push routing removed** (`.conversation` intents ignored). Cold-launch race bridged by draining `PushNotificationManager.shared.pendingIntent` in `onAppear`.

**Undo-block toast** (`:201-267`): a "blocked @handle · undo" pill for **4s** on `.userBlocked` (requires non-empty handle); undo → `BlockedUsersCache.unblock`. **Tab-bar hiding is intentionally disabled** (`onPreferenceChange` hard-sets `tabBarHidden=false`); content padded `.bottom, 92`. **Sign-out teardown** removes the unread listener + `feedVM.cancelAllTasks()` (prevents the old uid's listeners leaking markers into a new account).

### 2.2 The Feed Screen Layout (`FeedView.swift`)

Top→bottom: masthead wordmark; take-a-break banner; "X new posts" banner; for-you/following segmented control (`vm.tabs`); 0.5px divider; then `GeometryReader → ScrollViewReader → ScrollView` with: a `"feedTop"` anchor; the (vestigial) `ToskaRefreshHeader`; an inline `fetchError` retry banner; `FeedHeaderCard` (hidden while searching); inline search + filter chips; following-empty/`followingFetchIncomplete` states; the post list/skeletons/empty branch; load-more spinner + end-of-feed line.

**Critical:** the list is a plain **`VStack`, not `LazyVStack`** — a LazyVStack here reports near-zero height on cold launch and never materializes rows (blank-feed bug); the trade-off is eager render + immediate prefetch. Width pinned to `geo.size.width` to prevent horizontal panning on media overflow. Scroll-to-top via `.scrollFeedToTop` → `proxy.scrollTo("feedTop")`.

### 2.3 The Post Card (`FeedPostRow`, `:792-1366`)

A `.toskaCard()` (radius 18, hairline border) with a tappable content `NavigationLink` and an action bar **outside** the link. Tapping pushes `PostDetailView` via a **destination-closure NavigationLink** (per-row `navigationDestination(isPresented:)` would collide), passing the local optimistic state; `.disabled(postId.isEmpty)`; `FeedRowPressStyle` press highlight. Elements: repost provenance row (shows original author + "@reposter reposted"); handle row (accent handle, 2.5px dot, time, optional rank badge, midnight/whisper glyphs, report/block `⋯` menu hidden on own/authorless posts); post body (letter mode clamps to 3 lines + "read this letter..." expand); tag pill (icon + name, 13% tint); GIF via `StableGifPreview` (animated UIImageView) capped 200px.

**Action bar** (max-width 278): reply (`bubble.left`, second NavigationLink), repost (disabled+dimmed on reposts), like (heart with **burst** scale 1→2.6 fade + `likePulse` spring, both skipped under reduce-motion), bookmark, share (only if `isShareable`; `Color.clear` spacer keeps balance). Context menu duplicates felt/save/repost/share. Per-row covers (share/report/block-confirm) are safe to keep per-row.

**Local state:** seeded once on first `onAppear` (`hasInitialized`), then `onChange` re-adopts server-delivered `isAlreadyLiked/Saved/Reposted` **and** `likes`/`reposts` counts on re-delivery (prevents count drift). `actionLabel` hides 0 counts and formats with k-suffix.

### 2.4 Feed Loading & Ranking (`fetchPosts`, `:589-729`)

**For-you query:** `posts where moderationStatus=="live" order createdAt desc limit 60`. The `live` filter is **required by rules** (omitting it denies the whole read). Coalesced by `isFetchingPosts`. **Client scoring**: recency buckets (+50…+10), engagement with **stage-aware time decay** (`decayFloor` 0.6/0.45/0.35/0.2 by breakup stage), mood match (+15), engaged-tag boost (×5 from last-50 liked tags), has-tag (+3), letter (+5), and a **day-stable jitter** (0–5, hash of id+day). Top **20** become `posts`. **Pagination cursor** = `documents.last` (chronological), not `topDocs.last` (avoids "holes in the feed"). Empty-batch recursion keeps paging. Query failure → empty state, not infinite spinner.

### 2.5 Blocking Filter (`filterBlocked`, `:523-536`)

`nonisolated` (callable off-main). Drops blocked `authorId`/`originalAuthorId`, **expired** (`expiresAt<now`), and server-**flagged** posts. Repeated in witness/most-unsaid/weather fetches. **Live block removal:** `.userBlocked` → `handleUserBlocked` strips the author's posts from both arrays in-memory + prunes orphaned per-post metadata.

### 2.6 For-You vs Following

**Following feed** reads ≤200 followed ids, chunks by 30 (`in`-limit), fan-out queries `live` + `authorId in chunk` + `createdAt > 3d`, merges/sorts/caps at **50**, sets `followingFetchIncomplete` if any chunk failed or the list truncated at 200 (→ "some posts may be missing" banner). **No pagination on the following tab.** `currentPosts` returns `followingPosts` for tab 1 else `posts`.

### 2.7 Pagination / Load More (`loadMorePosts`, `:733-784`)

Guarded by `!isLoadingMore && hasMorePosts && lastDocument!=nil`; `start(afterDocument:) limit 20`; **dedups within the page** (seen-set mutated in the loop); `hasMorePosts = count>=20`. Blocking-saturation recursion capped at **depth 5** → `endedDueToBlocking` ("some posts are hidden"). Two triggers: a 5-from-end prefetch (tab 0 only) and a fallback visible `ProgressView`. **Refresh** uses native `.refreshable` → `refreshAll()` + 1.2s. **Vestigial:** `isRefreshing`/`dragOffset` and the custom `ToskaRefreshHeader` spinner are never set true.

### 2.8 Snapshot Listeners & Interaction Markers (`:375-443`)

Three listeners keep markers in sync (push-based, replacing ~1500 reads/refresh): `liked` (limit 500), `saved` (limit 500), and reposted (`authorId==uid && isRepost==true` → `originalPostId`, limit 200). Idempotent, captured-uid-guarded, torn down in `cancelAllTasks`. These stamp each row's `isAlready*`. Per-post metadata (gif/midnight/letter/repost/whisper) extracted + soft-capped at 800. **"X new posts" banner** tracks `posts.count` deltas (`previousPostCount` starts at -1 so cold-load doesn't trigger; own posts suppressed). **Cross-surface sync** (`postInteractionChanged`) flips the same post's state wherever rendered.

### 2.9 Masthead / Daily Prompt / "todays moment" (`FeedHeaderCard`, `:1385-1610`)

Always renders. Collapsed: eyebrow `promptTimeLabel`, prompt text (`dayOfYear % 31` table, 3-line clamp), "✦ todays moment ›" expand. **"your response"** card (when `todaysPromptResponse != nil`, query `authorId==uid && promptDate==today`) pushes detail. The **one-per-day cap is client-only** (bypassable). Expanded: respond button (→ ComposeView with `promptDate`), daily-moment row (→ `DailyMomentView`), **witness post** ("someone needs a reply" — a recent `replyCount==0` post not yours), anniversary card. Also: **emotional weather** (top tag last 6h).

### 2.10 Inline Search & Filter Chips (`:42-68, 257-362`)

A real `TextField` doing **in-memory** filtering (`matchesSearch` over handle/text/tag) — no Firestore round-trip. Clear + "cancel" buttons. **Filter chips** appear while focused/non-empty: an "all" chip + `sharedTags` chips that set `searchText = tag.name`. The feed header hides while searching. Keyboard dismissal is a window-level tap recognizer that lets text-field/scroll/row taps fall through.

### 2.11 Like / Save / Repost (`PostInteractionManager.swift`)

`@MainActor` shared service. **`toggleLike`:** auth guard before optimistic update; 0.8s/post rate gate + in-flight set (closes the slow-transaction double-tap window); timestamp recorded on attempt; optimistic `onUpdate` + `postInteractionChanged` broadcast; **transaction** dedups against an existing like doc, writes `posts/{id}/likes/{uid}` + `users/{uid}/liked/{id}`; **counter is Cloud-Function-owned** (client never writes `likeCount`); on success a "like" notification to a non-self author; rollback + reverted broadcast on failure. **`toggleSave`** is a 1s-gated transactional toggle of `users/{uid}/saved/{id}`. **`repost`** has fail-safe dedup (any error fails safe), a post-existence check before the optimistic update, an atomic transaction writing a deterministic-id (`{uid}_repost_{postId}`) repost doc inheriting `isShareable` and starting `pending_validation`; `repostCount` is CF-owned; posts `.newPostCreated`. **`sendNotification`** uses deterministic ids (idempotent) and deliberately omits `message` (a CF backfills it after verifying a real reply — closes a notification-spoof hole). Every counter is CF-owned; clients only do optimistic local math.

### 2.12–2.13 Edge cases & connections

Empty feed (skeletons / coaching CTA / following-poetic states); `.postDeleted` strips deleted posts live; offline banner via `NetworkMonitor`; count drift mitigated by CF counters + row re-adoption; double-tap races handled by per-post gates + in-flight set + transactional reads; `cancelAllTasks` + captured-uid rechecks prevent cross-account leakage; foreground refresh throttled to 60s. **Connections:** opens PostDetail/Compose/Explore/DailyMoment/ShareCard/Report/OtherProfile; creates like/save/repost notifications feeding the badge + NotificationsView; cross-cutting NotificationCenter events (`.newPostCreated`, `.postDeleted`, scroll/pop family, `.postInteractionChanged`, `.userBlocked`).

---

## 3. Composing, Post Detail, Replies & Drafts

### 3.1 Compose (`ComposeView.swift`)

**Inputs:** `initialText`/`initialTag` (drafts/prompts), `promptDate` (daily-prompt stamp), `onPostSuccess`, `editingDraftId` (→ "update" + deletes the draft on publish). Wrapped in a `NavigationStack` so the GIF picker pushes.

**Toolbar (5 controls):** tag picker (drops the 8-emotion scroll), **whisper** (1hr; forces midnight off), **midnight** (expires at local midnight; forces whisper off), **letter** (2000-char limit), **GIF** (pushes `GifPickerView`). Each mode shows a dismissible banner.

**Char limit:** 500 (2000 letter). Counter measured in **UTF-16 code units** (`max(text.count, utf16.count)`) because the Firestore rule validates `text.size()` (UTF-16) — so an emoji-heavy "looks-under-limit" post never silently fails server validation. `onChange` truncates by walking grapheme clusters accumulating UTF-16 width (single-pass). Two counters: toolbar ring (red <50 left) + inline numeric (red at limit).

**Pre-publish gates (`attemptPost`, in order, on trimmed text):** (1) in-flight/empty; (2) offline (banner + 1s connectivity poll); (3) **rate limit** 30s (bypassed under UI_TESTING); (4) **content-violation** (`contentViolation` — slur/threat/sexual/spam/harassment/link via homoglyph-fold + run-collapse + regex) → **hard block** modal (edit only, no override); (5) **name/identifying-info** (`containsNameOrIdentifyingInfo`, confusable-folding) → **soft** "keep it anonymous" (offers "post anyway"); (6) **crisis check-in** (`crisisCheckLevelRespectingSetting`): `.explicit` always shows; `.soft` only if `gentleCheckIn` on. All four gates are **client-side and bypassable**; the server backstop is `pending_validation` + `validatePost`.

**The exact post doc (top-level `posts`):** `authorId, authorHandle, text(trimmed), likeCount:0, repostCount:0, replyCount:0, isRepost:false, isShareable(=allowSharing), createdAt(server), moderationStatus:"pending_validation"`, plus conditional `tag`, `gifUrl`, `isLetter`, `promptDate`, and the whisper/midnight `expiresAt`+flag. `RateLimiter.lastPostTime` set at attempt (anti-dupe). Handle resolved fresh from cache (Firestore fallback). On success: `Telemetry.postCreated`, clears drafts, deletes source draft, posts `.newPostCreated`. On `permission-denied` (age-gate not landed) → fires `confirmAdultServerSide` + "still setting up" message; rolls `lastPostTime` back to ~5s wait.

**Drafts:** `users/{uid}/drafts/{id}`; `canSave` is less gated than post (no rate limit, restricted users may save). **Persistence across kills** via `@AppStorage` compose-draft text/tag, restored on appear. **GIF preview** (`StableGifPreview`) owns bytes in `@State` + decodes all frames via ImageIO `UIViewRepresentable` (SwiftUI `Image` won't animate; AsyncImage cancels on recompute).

### 3.2 Post detail (`PostDetailView.swift`)

Header `ToskaHeader` "post" + back + drag-to-dismiss + trailing `Menu` (own → edit/delete; others → report/block). Body: tappable handle (→ OtherProfileView), tag chip, `.toskaPostDetailBody()` text (live `@State`), GIF (filled by listener), felt/replies counts, a 5-button action row.

**Live listener** on `posts/{postId}`: captured-uid-guarded; **`exists==false` → dismiss** (delete pops the viewer); updates isLetter/gif/likeCount with a 600ms pulse, suppressed while `Date()<=suppressListenerUntil` (re-armed on like completion to absorb slow-network echoes).

**Edit** (`EditPostView`): re-runs the same 3 gates (content hard-block, name soft, crisis); writes `text`+`editedAt` (note: writes **untrimmed** `editText`). **Delete** (author-only): cascades replies (500-batches), the post's `likes` (499-chunks, leaves other users' mirrors to self-clean), reposts, `reflections`, the author's own saved/liked mirrors, then the post doc; posts `.postDeleted`; counters left to CFs.

**Threaded replies:** snapshot listener on `replies` ordered ascending, filters blocked authors, renders text then enriches interaction state in a second pass. `buildThreadedReplies` builds a parent→child tree; `flattenReplies` walks to **maxDepth 3**, emitting a "show N more replies" stub at depth 3 (tap → `expandedDeepThreads`); rows indent `depth*24`. Skeletons while loading; "some words just need a witness" empty state.

**Reply composer** (`safeAreaInset .bottom`): optional GIF preview, "replying to {handle}" chip, `TextField` "say something gently…", send. **Char limit 500**, **per-post draft** in `UserDefaults`, **5s rate limit**. `postReplyNow`: ≥2 chars, not restricted/blocked, same 3 content gates, then **optimistic insert** into `replyList`. **Reply doc** (`posts/{id}/replies/{auto}`): `authorId, authorHandle, text, likeCount:0, createdAt, parentPostText, parentPostHandle, parentReplyId?, gifUrl?`; `replyCount` CF-incremented; a `reply` **notification** to a non-self author. On failure: restores text + **clears `lastReplyTime`** (instant retry).

**Like/save/repost** (post + replies) all delegate to `PostInteractionManager` (transactional, reverse-indexed, deterministic-id, idempotent). Reply-like/save/repost write `posts/{id}/replies/{rid}/likes/{uid}` + `users/{uid}/likedReplies|savedReplies/{rid}` (snapshotting text/handle); reply-repost creates a top-level post `{uid}_replyrepost_{rid}`. **Reply interactions create no notification in v1.0.** **Report/block** write the hardened `reports` schema / delegate to `BlockedUsersCache`.

### 3.3 Replies as first-class (`ReplyDetailView.swift`)

Renders a reply **as a post** with its **direct children only**; tapping a child pushes another `ReplyDetailView` (one level/push). Listener refreshes the focal reply + collects `parentReplyId==reply.id` children (blocked-filtered, uid-guarded). Action row: reply/like/save/share (**no repost here**). **Composer divergence:** no char limit, no rate limit, **no content/name/crisis gating, and no notification** — relies on the listener (server moderation still backstops).

### 3.4–3.6 Drafts, GIF picker, shared helpers

**`DraftsView`** lists `users/{uid}/drafts` (snapshot, ≤100, uid-guarded); tap → ComposeView(editingDraftId); swipe-to-delete. **`GifPickerView`** proxies Giphy via the `giphyProxy` Callable (App Check + ID token; key in Secret Manager); 400ms-debounced search, trending default, prefers `fixed_width` URL, retry on error, "Powered by GIPHY" attribution. **`FirestoreExtensions`** provides `getDocumentAsync`/`getDocumentsAsync`, `isValidFirestoreDocId`, `withTimeout`.

### 3.7–3.8 Edge cases & connections

Empty/over-limit handled by disabled buttons + live truncation; offline disables post + polls; compose rolls `lastPostTime` back on failure (anti-dupe), reply **clears** it (instant retry); optimistic replies dropped by the listener if moderation removes them; deleted-parent dismiss; drafts/reply-drafts survive kills; GIF failures show "couldn't load"; **all content gates are client-side/bypassable, server `pending_validation`+`validatePost` is the real backstop.** **Notable inconsistencies:** ReplyDetailView composer has no gating/notification; `EditPostView` writes untrimmed text; reply-repost reachable from inline rows but not ReplyDetailView's action row.

---

## 4. Profiles, Social Graph & Discovery

### 4.1 Own Profile (`ProfileView.swift`)

**Identity header** (editorial, no follower chrome): eyebrow `"anonymous · here since {joinedDate}"`, serif `"@{handle}"`, fixed bio `"no name, no face. just the things you needed to say."` (no bio field). Follower/following counts are **not** shown here (intentional — "the anonymity is the point"); they surface only in Settings.

**Four content tabs** (icon row: posts/likes/saved/replies), pre-loaded once on first appear:
1. **Posts** — `posts where authorId==uid order createdAt desc limit 50` (+ count aggregation). Drops expired but **keeps flagged/pending visible to the author** with a `PendingReviewBanner`. Reposts show "you reposted". Tap → `openMyPost` re-reads + self-heals (removes deleted).
2. **Likes** — merged union of liked **posts** (`users/{uid}/liked` → batch-fetch in 30-chunks, orphan-clean) + liked **replies** (`users/{uid}/likedReplies`, denormalized snapshot), sorted by like-time.
3. **Saved** — same merged pattern (`saved` + `savedReplies`).
4. **Replies** — collection-group `replies where authorId==uid limit 30`, denormalized-or-refetch parent; context menu **edit** (`EditReplyView`, full re-moderation) / **delete** (plain delete, CF decrement).

**Count reconciliation** (`reconcileMyCounts`, App Check + ID token, 24h-gated) authoritatively rewrites follower/following via Admin SDK. Every loader rechecks `currentUser.uid==uid`; `.userDidSignOut` wipes all state.

### 4.2 FollowListView (followers/following)

Defined in ProfileView but **only reachable from Settings** now. Reads `users/{uid}/followers|following` (limit 50), filters blocked ids, dedups, refetches missing handles. **Unfollow** (following tab only): confirm → optimistic remove → batch-delete `following/{t}` + target's `followers/{me}` (CF decrements); rollback + 3s toast on failure. Followers tab is non-interactive (visit profile to block). Row tap → `OtherProfileView`.

### 4.3 OtherProfileView (`OtherProfileView.swift`)

Header shows `"joined {date}"` and — unlike own-profile — a **visible follower/following/felt stats row** gated by the target's `showFollowerCount` flag. **Two tabs** (posts/replies — no likes/saved, those are private): posts (`live && authorId==target`, drops expired+flagged); replies (collection-group, read-only). **Follow/unfollow** (`toggleFollow`): not-self/online/1s-debounced; optimistic flip; batch writes both edges + a `follow` notification; rollback on error. **Block** routes through `BlockedUsersCache.block`, severs the follow graph **both directions**, deletes notifications from the blocked user, dismisses. **Report** writes the hardened `reports` schema. **Guards:** `checkIfBlocked` dismisses if **either** party blocked the other; empty `userId` from a malformed deep link is caught before any query. DMs gone (envelope removed).

### 4.4 TopView — "felt the most"

**Period selector** today/this week/all time → cutoffs −24h/−7d/**−365d** ("all time" is a rolling year). Re-fetches on change. **Query:** `posts where live && createdAt>cutoff order createdAt desc limit 100`, then **client-ranked**: skip blocked/expired/flagged/concerning/repost; `score = likeCount + createdAt/1e12`; top **10**. Ranking is bounded by the 100-doc recency window. **Summary line**: two most-frequent tags, tinted. **Distribution bar**: up to 7 equal segments (one per top post, by tag color — post-count, not like-weighted). **Hero** + `02`-style ranked rows → `PostDetailView`. Empty/refresh/scroll-to-top supported.

### 4.5 ExploreView

**Stage chips** (`meta/breakupStageCounts`, single CF-maintained doc) + **tag chips** (`meta/tagCounts`). **Trending** (`live && createdAt>−24h && isRepost==false order createdAt desc, likeCount desc limit 10`, take 5 — recency-dominant). **Tag detail** (`live && tag==t && isRepost==false limit 30`). **People feeling this** (`live && tag==t && createdAt>−24h`, distinct non-blocked handles, take 5 — **not tappable**, no DM affordance). **Search**: client-side substring over text/tag/handle, lazy-loads ≤100 recent + a tag query, merges/dedups, cancellable. Blocking filtered at parse + on appear.

### 4.6 FeelingCircleView — real but **orphaned**

Fully wired to Firestore (`feelingCircles/{dateKey_tag}` + `messages`): join (CREATE-vs-UPDATE rule branch), live message listener, **5-message/user cap** via server count aggregation, full content/PII/crisis moderation, restricted-user block, blocked-author filter, sign-out teardown. `circleId` keyed on **local** date+tag (timezone split is intentional). **But `grep` finds zero call sites** — a complete, production-quality feature currently **unreachable** in the shipping UI (missing wiring or intended de-scope shipping as dead code).

### 4.7 Blocking subsystem (`BlockedUsersCache.swift`)

Storage `users/{uid}/blocked/{id}`. `shared` singleton with a **`nonisolated isBlocked`** (NSLock-guarded) for off-main checks; a snapshot listener keeps the set fresh (keeps existing set on listener error — never briefly un-blocks everyone); captured-uid recheck. block/unblock are optimistic-then-persisted-then-reverted; `block` broadcasts `.userBlocked`. **Enforcement** is layered across feed/detail/top/explore/circle/follow-list. **Undo** in two places: the 4s MainTabView toast and the Settings `BlockedUsersListView`.

### 4.8–4.9 Edge cases & connections

Stale-list deletes self-heal everywhere (re-fetch + orphan clean); replies to deleted parents render "deleted post"; **cold-start block window** (cache not yet warm) + **OtherProfileView shell render before the async block check** are the two leakage risks; follower count can exceed visible rows (blocked-filtered + 50-cap + 24h reconcile); "all time" = 365d / top-100 window. **No `.userUnblocked` broadcast** — unblocked content reappears only on refetch. Connections: all rows funnel to `PostDetailView`; handle taps → `OtherProfileView`; `.userBlocked` is the block spine; counts are server-authoritative.

---

## 5. Notifications, Settings & Moment Features

### 5.1 In-App Notification Feed (`NotificationsView.swift`)

`NotificationItem` docs at `users/{uid}/notifications/{id}` (server-written). **Types/rendering:** like ("felt this"), reply ("replied: '{80-char preview}'"), follow, repost ("shared your words"), save, milestone (verbatim `message`), message (legacy DM — **inert tap**), default. (No dedicated anniversary/circle notification types.) **Load:** real-time snapshot listener ordered `createdAt` desc limit 50, captured-uid-guarded, blocked-author-filtered at render. **Sectioning** "new"/"earlier" (isDateInToday), recomputed on change. **Mark-read sweep** (once/visit, 3s debounce): `isRead==false` limit **400**, batch, **recurses on a full page** (clears >500 backlog). A **second** sweep lives in MainTabView (100/batch). Badge zeroed on appear. Pull-to-refresh forces a server round-trip + re-buckets. **Deep-link tap:** follow → OtherProfileView; message → no-op; else → `openPost` (distinguishes network error from a truly-deleted post, which prunes referencing notifications). Pop-to-root on bell re-tap.

### 5.2 First-Run Push Primer

`@AppStorage(pushPrimerShown)`-gated custom modal on first tab visit. "yes" → Telemetry + **only now** `requestPermission()` (contextual system prompt); "not now" → never fires the system prompt. Correct one-shot iOS pattern.

### 5.3 Push Plumbing (`PushNotificationManager.swift`)

`@MainActor` singleton, both UN + Messaging delegate. Permission requested only from the primer "yes" and the Settings push toggle — never cold. **FCM token** written to owner-only `users/{uid}/private/data` (not the public doc — impersonation/spoof defense). `clearFCMToken` does `Messaging.deleteToken` (FCM-level invalidation for shared-device safety) + `FieldValue.delete()`; called on sign-out/delete/reauth/onboarding. Foreground presentation always banners. **Tapped routing** (`didReceive`): validates every id via `isValidFirestoreDocId`, calls `completionHandler()` first, then routes (message→conversation[dead], follow→profile, default→post) + stashes `pendingIntent` for the cold-launch race (MainTabView drains it; `.conversation` ignored).

### 5.4 Settings (`SettingsView.swift`)

`UserSettings` model (allowSharing, showFollowerCount, 7 notify toggles, pushEnabled, gentleCheckIn). Pushed (not sheeted) from Profile.
- **Privacy:** allow sharing + show follower count (→ main user doc); share anonymous usage (`@AppStorage`, gates all Telemetry); view content policy (`PolicyAcceptanceView(isReviewMode)`); privacy/terms links.
- **Notifications:** master push + 7 mini-toggles (incl. vestigial **messages**). Flipping push on checks OS settings (`.notDetermined`→prompt, `.denied`→deep-link-to-Settings alert).
- **Content:** gentle check-in (read app-wide via `UserHandleCache`; `.explicit` crisis always shows regardless), drafts, **your week** (WeeklyRecap), **followers/following**, blocked users.
- **Account:** change email, change password (if password provider linked), export my data; sign-in methods (with "add a backup sign-in"); sign out (clears FCM → signOut → `.userDidSignOut`).
- **Persistence:** 500ms-debounced single batch (writes public fields to main doc + **deletes 9 legacy sensitive fields** off it; prefs to `private/data`); failure re-pulls server state (visual revert); flushes pending save on disappear. **No theme toggle** — late-night is automatic (`hour < 5`).

### 5.5 Delete Account

3-phase: `clearFCMToken` → Apple token revocation (detached) → delete stale `pendingDeletions/{uid}` → write fresh cascade-intent marker → immediately `Auth.currentUser.delete()` (must land in the CF's 10s grace window; on failure writes `cancelled:true`; `requiresRecentLogin`→reauth alert). The CF cascades posts/notifications/followers/private/data/etc. **Actual erasure is server-side, asynchronous, best-effort with an hourly backstop** — the biggest privacy-completeness dependency.

### 5.6 Data Export

GDPR Art. 15 JSON: account (main+private, **fcmToken stripped**), authored posts (≤5000), authored replies (≤5000), liked/saved IDs, following/follower **handles only** (never others' UIDs), notifications. Excludes others' content, DMs, blocked IDs. Timestamps→ISO8601; written to temp; share sheet; **temp file auto-deleted after 5 min**.

### 5.7 Daily Moment (`DailyMomentView.swift`)

`fullScreenCover` reflection card. Fetch: `dailyMoment/{utcDateKey}` (UTC-pinned, curator/Admin-only write) re-checked for moderation at render; else most-liked last-24h post; else 1 of 5 day-deterministic **fallbacks** (never blank). **No respond field** — only a "share moment" (`ImageRenderer` 360×640 @3x → share sheet).

### 5.8 Weekly Recap (`WeeklyRecapView.swift`)

Settings → "your week". Four concurrent `async let` queries (calendar-startOfDay 7-day window): postCount, communityPostCount, top post (sorted by likes, moderation-filtered), tag distribution. States: loading / "nothing this week." / stats. **Share button hidden while loading** (can't share zeros); `ImageRenderer` 390×690 dark @3x.

### 5.9 Anniversary Card (`AnniversaryCardView.swift`)

Inline feed card (always-visible) when `vm.anniversaryPost!=nil` (milestone-window query of the user's own posts). "how do you feel about this now?" reveals a 500-char TextField; **author guard** re-verifies `authorId==uid`; loads/saves `posts/{postId}/reflections/{uid}`; runs name + crisis gates before save. Only "anniversary" surface (no notification type).

### 5.10 Share Card (`ShareCardView.swift`)

From PostDetail/Feed/ReplyDetail with `(text, handle, feltCount, tag)`. Pickers: 12 **styles** (bg/glow/colors), 4 **fonts** (serif/sans/mono/hand — user-pickable, why Georgia is preserved), font size (0.8/1.0/1.25), alignment, ratio (story/square/wide), felt-count toggle. `ImageRenderer` @3x with `withRenderIndicator` (paints disabled state first). Targets: save→Photos (`NSPhotoLibraryAddUsageDescription`), Instagram Stories pasteboard, X, iMessage/More share sheet, copy text. Confirmation overlay after. Website URL deliberately removed from the card. **No PII** (already-anonymous public content).

### 5.11 Legacy DMs — **CONFIRMED CUT (dead code)**

`MessagesListView.swift`, `ConversationView.swift`, `MessageBubble.swift` are orphaned (no live call sites). Live dead-references: NotificationsView message branch is a no-op; MainTabView ignores `.conversation`; **`PushNotificationManager` still routes `message`→`.openConversationFromPush` which nothing observes** (silent dead-end); Settings still shows a "messages" toggle + `notifyMessages`. **Recommendation:** delete the three files + the message push route + the toggle, or restore DMs intentionally.

### 5.12–5.13 Edge cases, privacy & connections

Cross-account safety (uid rechecks + sign-out clears + FCM-level token invalidation); push ids validated before routing; two idempotent mark-read sweeps may race (only redundant commits); daily-moment UTC-curated vs device-local fallback inconsistency; photo permission is **add-only** (least privilege); share cards/reflections carry no PII; reflection crisis rail always fires; **delete completeness fully delegated to CFs** (async/best-effort); `shareAnonymousUsage` is UserDefaults-only (doesn't survive reinstall) while notify prefs are Firestore-only. Connections: CFs write notifications + send push + own `dailyMoment`/`pendingDeletions`; MainTabView owns the bell badge + second sweep; `UserHandleCache` is the runtime source for `gentleCheckIn`; `presentShareSheet`+`ImageRenderer` shared across all moment surfaces; late-night automatic everywhere.

---

§§SECTION6§§

---

## 7. Consolidated Findings, Risks & Recommendations

This roundup aggregates the load-bearing findings surfaced across all six subsystem audits, grouped by theme. None are show-stoppers; several are App-Store-submission-relevant.

### 7.1 Dead / unreachable code & cut-feature remnants
- **Direct Messages: backend fully live, UI cut.** The product decision (memory: "DMs cut 2026-05-28") removed the UI, but `conversations`/`messages` Firestore rules, indexes, the `onMessageCreated*` Cloud Functions, and three Swift files (`MessagesListView.swift`, `ConversationView.swift`, `MessageBubble.swift`) all still ship. `PushNotificationManager.didReceive` **still routes** `type=="message"` to `.openConversationFromPush`, which nothing observes (silent dead-end). Settings still shows a "messages" notification toggle (`notifyMessages`). **Recommendation:** reconcile before submission — delete the dead Swift files + the message push route + the toggle, or restore DMs intentionally. A reviewer who sees `ConversationView` may question it (§6.5).
- **FeelingCircleView is fully built, moderated, real-data — and has zero call sites.** Ephemeral per-emotion rooms with a 5-message cap, full content moderation, and sign-out teardown, but `grep` finds no instantiation. Either a missing-wiring regression or intended de-scope shipping as dead code (§4.6).
- **Vestigial pull-to-refresh.** `FeedViewModel.isRefreshing`/`dragOffset` and the custom `ToskaRefreshHeader` are never set true; the live refresh is SwiftUI's native `.refreshable` (§2.7).
- **Profile streak code** (`shareStreak`/`shareStreakRender`/`presenceStreak`/`totalNights`) is orphaned by the identity-block redesign (loaded but not displayed) — known, low-severity, flagged in the prior bug pass.

### 7.2 Security / data-integrity gaps
- **`followerCount` / `followingCount` / `totalLikes` are client-self-writable on the user doc.** The `users` update rule does not deny these counter fields in the owner branch, so a tampered client can self-inflate; `reconcileMyCounts` + follow triggers eventually correct it, but there's a window. The lockdown was explicitly deferred (§6.1 #3). **Recommendation:** add them to the update deny-list, or accept the documented window.
- **Block enforcement has a cold-start window.** TopView/ExploreView/Feed filter against the in-memory `BlockedUsersCache`; before its first snapshot lands, a blocked author's content can momentarily appear (§4.8).
- **`OtherProfileView` renders its shell + issues post/reply queries before the async mutual-block check resolves**, so a target who blocked the viewer can flash for a frame before dismissal (§4.8).
- **No `.userUnblocked` broadcast** — unblocked content only reappears on refetch/relaunch (§4.9).
- **Password-reset email enumeration.** `PasswordResetView` surfaces `friendlyAuthErrorMessage` directly (maps 17011 → "no account"), unlike the sign-in path which collapses it. Residual enumeration vector unless Firebase project-level Email Enumeration Protection is enabled (§1.11).

### 7.3 App Store review risk
- **Moderation is regex/wordlist-only and English-only.** Hate/threat/sexual/harassment are static lists; trivially evaded by novel phrasing and non-English. The monitored 24h report SLA is the 1.2-compliant backstop — be ready to explain it (§6.2, §6.5).
- **Entitlements:** `toska.entitlements` has `aps-environment: development`; only `toska.Release.entitlements` has `production`. Confirm the Release build is signed with Release entitlements or prod/TestFlight push fails silently. App Attest is `production` in both (good) (§6.5).
- **App Check enforcement** on prod Firestore is documented as Enforced but has been silently flipped to Unenforced by Firebase during past outages — verify at submission (§6.5).
- **Admin crisis push includes up to 100 chars of post body** — the one push path that transmits content (intentional for triage, but in tension with the lock-screen-privacy posture applied elsewhere) (§6.2).

### 7.4 Behavioral inconsistencies (polish)
- **`ReplyDetailView`'s composer applies no content/name/crisis/rate-limit/char gating and sends no notification** — diverges from `PostDetailView`'s reply path (server moderation still backstops it) (§3.8).
- **`EditPostView.saveEdit` writes untrimmed text** (§3.2.4).
- **"All time" on the Top page is a rolling 365-day window**, and ranking only considers the 100 most-recent posts in the period — a genuinely top-liked older post can be excluded (§4.4).
- **The daily-prompt one-per-day cap is client-only** and bypassable by a tampered client (§2.9).
- **Two independent mark-read sweeps** (NotificationsView + MainTabView) can race; both idempotent, so the only cost is redundant batch commits (§5.1).
- **Reply-like / reply-save / reply-repost and ReplyDetailView replies create no in-app notification** in v1.0 (§3.8).
- Nomenclature: there are **4 tabs, not 5** — the center "+" is the compose button, not a `Tab` case (§2.1).

### 7.5 What is solid (verified strengths)
- Optimistic like/save/repost with transactional dedup, deterministic repost ids, paired rollback broadcasts, and per-post rate + in-flight guards (§2.11).
- Listener/task lifecycle: every view tears down listeners on disappear AND `.userDidSignOut`, with captured-uid rechecks before every post-await state write — comprehensive cross-account-leak protection (§2.12, §4.7, §5.12).
- Deleted-post-from-stale-list handling and nil-field defaults across every loader; no force-unwraps/unchecked subscripts in the reviewed flows.
- The notification-write rules require a real backing event per type (closes push-spam/spoof); reports schema is hardened; blocking is bidirectional and enforced at the rules layer, send time, and display.
- Privacy: anonymity is structural (email/token/mood in owner-only `private/data`; server-authored name-free push; PII-scrubbed crash logs; `NSPrivacyTracking=false` with accurate manifest); deletion is full erasure with a resumable Cloud-Function cascade; in-app GDPR export.
- 1.2 UGC compliance: in-app versioned EULA/content policy naming the publisher (SALTE DEVELOPMENT LLC), server moderation, monitored 24h report SLA, bidirectional block, admin restriction/ejection, and a 17+ server-attested age gate.

### 7.6 Suggested pre-submission action list
1. Reconcile the live DM backend/rules/files with the "DMs cut" decision (delete or restore).
2. Wire or remove `FeelingCircleView`.
3. Lock `followerCount`/`followingCount`/`totalLikes` as server-owned in the `users` update rule (or accept the window).
4. Confirm Release entitlements (`aps-environment: production`) are signed; verify prod Firestore App Check is **Enforced**.
5. Enable Firebase Email Enumeration Protection (closes the reset-path enumeration vector).
6. Be prepared to defend wordlist/English-only moderation to a 1.2 reviewer (lead with the 24h SLA).
7. Optional polish: unify `ReplyDetailView` gating with `PostDetailView`; trim `EditPostView` text; remove the vestigial refresh header and `notifyMessages` toggle.
