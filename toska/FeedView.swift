import SwiftUI
import FirebaseAuth
import FirebaseFirestore
@preconcurrency import FirebaseFirestore

/*
 MARK: - Required Firestore Composite Indexes
 
 Create these in Firebase Console > Firestore > Indexes > Composite:
 
 Collection "posts":
   - authorId ASC, createdAt DESC         (fetchAnniversaryPost, loadMyPosts, loadPosts by author)
   - createdAt ASC, likeCount DESC        (fetchTopPosts — TopView)
   - tag ASC, createdAt DESC              (fetchPeopleFeelingThis, fetchPostsForTag — ExploreView)
   - authorId ASC, isRepost ASC, originalPostId ASC  (checkIfReposted, repostPost — 3-field dedup)
   - isRepost ASC, originalPostId ASC     (deletePost repost cleanup)
   - authorId ASC, createdAt ASC, createdAt ASC  (fetchAnniversaryPost — range query on createdAt)
 
 Collection "notifications":
    - createdAt ASC                        (pruneOldNotifications — inequality filter)
  
  Collection "conversations":
    - participants ARRAY, lastMessageAt DESC   (MessagesListView listener)
 
 Collection Group "replies":
   - authorId ASC, createdAt DESC         (loadMyReplies, loadReplies)
 
 Tip: Run the app and check Xcode console — Firestore prints clickable links
 to auto-create each missing index. The 3-field repost dedup index is critical —
 without it, repost checks will fail at runtime.
*/

@MainActor
struct FeedView: View {
    @ObservedObject var vm: FeedViewModel

    // Inline search state. The search bar lives below the prompt card
    // (rendered after FeedHeaderCard in the scroll content) and filters
    // vm.currentPosts in-memory by handle / text / tag containing the
    // query. No Firestore round-trip — searches only what's already
    // loaded. Cleared text returns to the unfiltered feed.
    @State private var searchText = ""
    // Search collapses to a 🔍 icon in the header; tapping it reveals the search
    // bar (2026 mockup). Kept open while a query is active so results stay visible.
    @State private var showSearch = false
    // Take-a-break gentle reminder. After 15 minutes of continuous time on
    // the feed, a soft banner appears at the top — non-modal, dismissable
    // with a tap. Specific to a mental-health-adjacent app: heartbreak
    // doomscrolling is real and the brand wedge is that we don't pretend
    // engagement is universally good. Task arms on onAppear, cancels on
    // onDisappear so tabbing away resets the timer cleanly.
    // Take-a-break banner state now lives in FeedViewModel (2026-07-30):
    // trigger changed from a 15-minute session timer to rapid-posting.
    // "X new posts" Twitter-style banner. Increments when the Firestore
    // listener delivers more posts than were previously in vm.posts.
    // Tapping scrolls to top + clears the badge. Initialized to -1 so the
    // first snapshot (cold-load) doesn't false-trigger the banner against
    // an empty initial state.
    @State private var newPostsBadgeCount = 0
    @ObservedObject private var policy = ClientPolicyManager.shared
    @State private var previousPostCount = -1
    // Head post id at the last count change. A pagination call APPENDS to the
    // tail (count grows, head unchanged), which must not trigger the "new posts"
    // banner; only a genuine head insertion should. Without this the banner
    // fired on every scroll-to-load.
    @State private var previousHeadId: String? = nil
    @FocusState private var searchFocused: Bool

    /// True when post matches the current search query (or no query is set).
    /// Case-insensitive substring on handle, text, and tag.

    // MARK: - Header
    //
    // Just the wordmark. The search affordance lives below the
    // prompt card now (see InlineSearchBar after FeedHeaderCard
    // in the scroll content), so there's no need for a header
    // search button. ExploreView is still reachable from the
    // empty-feed state ("explore" button) for the rare case
    // where someone has no posts in the window AND wants the
    // tag chips / trending / "feeling people" experience.
    @ViewBuilder private var headerSection: some View {
            HStack {
                            // Wordmark — Literata 20, ink (design 2026-09-16).
                            Text("toska")
                                .font(ToskaFont.serif(20))
                                .tracking(-0.24)
                                .foregroundColor(ToskaColor.text)
                            Spacer()
                            // Search toggle (2026 mockup): a magnifying glass in the
                            // top-right reveals the search bar below the header.
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    showSearch.toggle()
                                }
                                if showSearch {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        searchFocused = true
                                    }
                                } else {
                                    searchText = ""
                                    searchFocused = false
                                }
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundColor(ToskaColor.text2)
                                    .frame(width: 44, height: 44, alignment: .trailing)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Search")
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 6)
    }

    // Header search bar — revealed by the 🔍 toggle. Sits between the header and
    // the tabs (2026 mockup). The TextField + category chips moved up here from
    // the per-column body so search is one control at the screen level.
    @ViewBuilder private var headerSearchBar: some View {
        if showSearch || !searchText.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundColor(ToskaColor.text3)
                        TextField("search moments, people, feelings", text: $searchText)
                            .font(.system(size: 15))
                            .foregroundColor(ToskaColor.handle)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            // Stable selector for XCUITest (the placeholder is
                            // copy, not a contract) — testFeedSearchBar taps the
                            // 🔍 toggle then finds this field by identifier.
                            .accessibilityIdentifier("feedSearchField")
                            .accessibilityLabel("Search")
                            // Server-wide search fires on SUBMIT (the local
                            // filter stays instant as-you-type); results
                            // clear whenever the query empties.
                            .onSubmit { vm.runServerSearch(searchText) }
                            .onChange(of: searchText) { _, newValue in
                                if newValue.isEmpty { vm.clearServerSearch() }
                            }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(ToskaColor.text3)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(ToskaColor.input, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Take-a-break banner
    //
    // Soft, non-modal. 2026-07-30 owner change: shows only on RAPID
    // POSTING (2nd composed post within 60s — see
    // FeedViewModel.registerComposeForBreakNudge), auto-hides after
    // 10s; tap dismisses. Specific to the mental-health-adjacent
    // brand: the nudge is for spiraling, not for merely being here.
    // The banner doesn't gate anything — just a gentle ask.
    // Kill switch companion: an app-wide maintenance notice set on
    // config/clientPolicy renders as a quiet banner at the feed head.
    @ViewBuilder private var policyNoticeBanner: some View {
        if !policy.notice.isEmpty {
            Text(policy.notice)
                .font(ToskaFont.sans(12, weight: .medium))
                .foregroundColor(ToskaColor.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(ToskaColor.promptBg)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder private var takeBreakBanner: some View {
            if vm.showTakeBreakBanner {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        vm.showTakeBreakBanner = false
                    }
                    HapticManager.play(.tabSwitch)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "leaf")
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(Color.toskaFollowGreen)
                        Text("you've been here a while. take a breath if you need.")
                            .font(ToskaFont.sans(12, weight: .regular))
                            .foregroundColor(Color.toskaTextDark)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.toskaDivider)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.toskaFollowGreen.opacity(0.08))
                    .cornerRadius(10)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
    }

    // MARK: - New posts available banner
    //
    // Twitter-style affordance — when the snapshot listener delivers
    // new posts while the user is on the feed, surface a small pill
    // that scrolls to top + clears on tap. Hidden when count is 0.
    @ViewBuilder private var newPostsBanner: some View {
            // L4 (2026-07-22): the count tracks the FOR-YOU head (vm.posts), so
            // only show it on that tab — on Following it advertised posts the
            // visible list doesn't contain (and its scroll-to-top went nowhere
            // useful). The count keeps accumulating; it shows on switch-back.
            if newPostsBadgeCount > 0 && vm.selectedTab == 0 {
                Button {
                    NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        newPostsBadgeCount = 0
                    }
                    HapticManager.play(.tabSwitch)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                        Text(newPostsBadgeCount == 1
                             ? "1 new post · tap to see"
                             : "\(newPostsBadgeCount) new posts · tap to see")
                            .font(ToskaFont.sans(12, weight: .medium))
                    }
                    .foregroundColor(ToskaColor.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ToskaColor.accent)
                    .clipShape(Capsule())
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
    }

    // MARK: - Feed tabs
    // Text tabs (design 2026-09-16): "for you" / "following" at 13pt, active
    // ink semibold, inactive soft — NO underline, the weight + ink carry it.
    @ViewBuilder private var feedTabs: some View {
            HStack(spacing: 20) {
                ForEach(0..<vm.tabs.count, id: \.self) { index in
                    let isSel = vm.selectedTab == index
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            vm.selectedTab = index
                        }
                    } label: {
                        Text(vm.tabs[index])
                            .font(ToskaFont.sans(12.5, weight: isSel ? .semibold : .regular))
                            .foregroundColor(isSel ? ToskaColor.text : ToskaColor.text2)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    // MARK: - Inline search
    //
    // Sits directly under the prompt card. Real
    // TextField; filters vm.currentPosts in-memory
    // by handle / text / tag. No sheet, no
    // navigation — results display in place of
    // the unfiltered feed below. ExploreView
    // (tag chips, trending, "feeling people")
    // remains accessible from the empty-feed
    // state's "explore" button below for the
    // separate browse-by-tag flow.

    // Category pills — appear only while the
    // search bar is focused. Tapping a pill
    // fills searchText with the tag name (which
    // triggers matchesSearch to filter posts on
    // post.tag), dismisses the keyboard, and
    // returns the user to the filtered feed.
    // Hidden as soon as focus leaves the search
    // bar so the chrome doesn't compete with the
    // feed in the resting state.

    var body: some View {
            VStack(spacing: 0) {
                    headerSection

                    headerSearchBar

                    policyNoticeBanner

                    takeBreakBanner

                    newPostsBanner

                    feedTabs

            Rectangle()
                .fill(LateNightTheme.divider)
                .frame(height: 1)

            SwipePager(selection: $vm.selectedTab, ids: [0, 1]) { tab in
                FeedColumn(vm: vm, tab: tab, searchText: $searchText, searchFocused: $searchFocused)
            }
                                            }
                                            .background(LateNightTheme.feedBackground)
               // Group into a single accessibility container so the identifier
               // lands on ONE queryable Other element. Without .contain, SwiftUI
               // propagates the identifier onto every child (header text, tab
               // buttons, scroll view) and XCUITest's otherElements["feedView"]
               // matches nothing — which silently broke the UI suite's logged-in
               // anchor after the feed redesign (2026-06-11 walkthrough finding).
               .accessibilityElement(children: .contain)
               .accessibilityIdentifier("feedView")
               .onAppear {
                                                 print("⚡️ FeedView onAppear — hasLoadedOnce: \(vm.hasLoadedOnce), hasAuth: \(Auth.auth().currentUser != nil), posts.count: \(vm.posts.count)")
                                                 vm.dragOffset = 0
                                                 vm.savedScrollPostId = nil
                                                 if !vm.hasLoadedOnce {
                                                     if Auth.auth().currentUser != nil {
                                                         print("⚡️ FeedView onAppear — calling loadInitialData")
                                                         vm.loadInitialData()
                                                     } else {
                                                         print("🛑 FeedView onAppear — skipped, auth is nil")
                                                     }
                                                 } else {
                                                     print("⚡️ FeedView onAppear — skipped, hasLoadedOnce already true")
                                                 }
                                                 // Take-a-break arming removed (2026-07-30): the
                                                 // 15-minute session timer popped the banner
                                                 // mid-scroll — trigger is now rapid posting, wired
                                                 // in the .newPostCreated handler below.
                                             }
               .onReceive(NotificationCenter.default.publisher(for: .authDidVerify)) { _ in
                                                 print("⚡️ AuthDidVerify received in FeedView — hasLoadedOnce: \(vm.hasLoadedOnce), posts.count: \(vm.posts.count)")
                                                 if !vm.hasLoadedOnce {
                                                     print("⚡️ AuthDidVerify received in FeedView — calling loadInitialData")
                                                     vm.loadInitialData()
                                                 }
                                             }
               .navigationDestination(isPresented: $vm.showExplore) {
                   ExploreView().navigationBarHidden(true)
               }
        .fullScreenCover(isPresented: $vm.showPromptCompose) {
                            EdgeSwipeDismissWrapper {
                                ComposeView(
                                    initialText: "",
                                    initialTag: vm.todaysPrompt.1,
                                    // Stamps the resulting post doc with today's
                                    // prompt-date marker so FeedHeaderCard can
                                    // detect "you already responded today" and
                                    // surface the response with edit/delete.
                                    promptDate: vm.todaysPromptDateString
                                )
                                .onAppear { HapticManager.play(.compose) }
                            }
        }
        // Daily Moment + witness-post surfaces removed — they had no entry point
        // (showDailyMoment / showWitnessPost were only ever set false), so the
        // covers were dead. DailyMomentView.swift is now orphaned (safe to delete).
        .onReceive(NotificationCenter.default.publisher(for: .newPostCreated)) { notif in
            // Refresh the feed so the just-created content lands in real time
            // (a composed post OR a repost). Re-baseline the new-posts banner so
            // it doesn't pop "1 new post" for the user's own content either way.
            // 2026-07-30: instant local echo — all guard logic lives in the
            // view model (keeps this closure inside the type-checker limit).
            // Owner report (2026-09-22): a repost mid-scroll still "took you
            // to the top" — not via the guarded scroll below, but because
            // handleNewPostCreated's refetch cycle wholesale-replaces and
            // RE-SCORES `posts`, reordering the list under the viewport.
            // Reposts update in place (postInteractionChanged flips the
            // button + count) and need NO refetch — the repost row itself
            // surfaces on the next natural refresh. Composed posts keep the
            // full cycle (echo + promote-catching refetches).
            let isRepost = (notif.userInfo?["isRepost"] as? Bool) ?? false
            // Owner re-ruling (2026-09-22 eve): NO feed insert on repost —
            // the head-insert pushed the feed down under the tap. The row
            // updates in place; the copy reaches profile→reposts via its
            // own handler and the feed on the next natural refresh (X does
            // the same: your RT doesn't shove your own timeline).
            if !isRepost {
                vm.insertOptimisticPost(from: notif.userInfo)
                vm.handleNewPostCreated()
                // Owner report (2026-07-29): "my post doesn't show up until I
                // refresh." The just-created post is pending_validation until
                // validatePost promotes it (~1-3s server-side), and the feed
                // query pins moderationStatus=="live" — so the instant refresh
                // above can't see it yet. Two spaced follow-up fetches let it
                // pop in on its own once the server flips it live.
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    vm.handleNewPostCreated()
                    try? await Task.sleep(nanoseconds: 4_500_000_000)
                    vm.handleNewPostCreated()
                }
            }
            newPostsBadgeCount = 0
            previousPostCount = -1 // re-baseline on next .onChange tick
            // Only auto-scroll to the top for a freshly COMPOSED post (so they
            // watch it land). A repost must NOT yank the feed to the top — it
            // updates in place and the user keeps their scroll position.
            if !isRepost {
                vm.registerComposeForBreakNudge()
                NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
            }
        }
        // Drop the cached daily-prompt response card the moment the user
        // deletes that post via PostDetailView. Without this, the response
        // stays on screen with the deleted text until pull-to-refresh.
        // Also strip the deleted post from the in-memory feed so it
        // disappears from the list immediately.
        // 2026-07-29 sync sweep: an edited post's text updates in the feed
        // without pull-to-refresh (rows come from one-shot fetches).
        .onReceive(NotificationCenter.default.publisher(for: .postEdited)) { _ in
            vm.handlePostEdited()
        }
        .onReceive(NotificationCenter.default.publisher(for: .postDeleted)) { notif in
            guard let deletedId = notif.userInfo?["postId"] as? String else { return }
            if vm.todaysPromptResponse?.id == deletedId {
                vm.todaysPromptResponse = nil
            }
            // The anniversary card isn't part of the posts arrays, so removing it
            // from those isn't enough — clear it explicitly when its own post is
            // deleted, or the card lingers with deleted content until cold launch
            // (pull-to-refresh's lean refreshFeed no longer re-fetches it).
            if vm.anniversaryPost?.postId == deletedId {
                vm.anniversaryPost = nil
            }
            vm.posts.removeAll { $0.id == deletedId }
            vm.followingPosts.removeAll { $0.id == deletedId }
        }
        .onChange(of: vm.posts.count) { _, newValue in
            // "X new posts available" delta tracking. previousPostCount
            // initializes to -1 so the first snapshot (cold-load) doesn't
            // false-trigger the banner against an empty starting state.
            // Subsequent positive deltas (listener delivers new docs)
            // increment the badge; the user dismisses with a tap.
            let newHeadId = vm.posts.first?.id
            if previousPostCount == -1 {
                previousPostCount = newValue
            } else if newValue > previousPostCount {
                // Only bump the badge when posts were inserted at the HEAD (the
                // first id changed). A pagination append grows the count with the
                // head unchanged and must NOT trigger the banner — that was the
                // misfire where "N new posts" appeared during ordinary scrolling.
                // Also require a non-nil previous head: an all-blocked page wipes
                // posts to [] (head → nil) then loadMore repopulates (nil → B),
                // which would otherwise false-fire the full page count.
                if newHeadId != previousHeadId, previousHeadId != nil {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        newPostsBadgeCount += (newValue - previousPostCount)
                    }
                }
                previousPostCount = newValue
            } else if newValue < previousPostCount {
                // List shrunk (block + filter, refresh, etc.) — re-sync
                // baseline without bumping the badge.
                previousPostCount = newValue
            }
            previousHeadId = newHeadId
        }
        .onChange(of: vm.posts.first?.id) { _, newHead in
            // A refresh can re-score and reorder the feed WITHOUT changing the
            // count — the count-based handler above never fires, previousHeadId
            // goes stale, and the next pagination append (count grows, head
            // still the post-refresh one) read as "new posts at the head" and
            // false-fired the banner mid-scroll. Re-baseline on count-neutral
            // head moves only; when count changed too, the handler above owns
            // the transition (this check is order-independent with it: it
            // compares against the CURRENT count, so whichever handler runs
            // second is a no-op).
            if vm.posts.count == previousPostCount {
                previousHeadId = newHead
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .postInteractionChanged)) { notif in
                    if let info = notif.userInfo {
                        vm.handleInteractionChanged(info)
                    }
                }
        .onReceive(NotificationCenter.default.publisher(for: .userBlocked)) { notif in
                    // Strip the blocked user's posts from the in-memory feed
                    // as soon as a block lands, so the user doesn't see the
                    // offender's content lingering in the feed they're
                    // scrolling. See BlockedUsersCache.block(_:).
                    if let userId = notif.userInfo?["userId"] as? String {
                        vm.handleUserBlocked(userId: userId)
                    }
                }
        .onReceive(NotificationCenter.default.publisher(for: .userFollowingChanged)) { _ in
                    // A follow/unfollow just committed on a profile — refresh the
                    // Following tab so the change is reflected immediately.
                    vm.fetchFollowingPosts()
                }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // If the app was backgrounded with the search bar open but no
                    // query typed, iOS restores its keyboard on resume — the app
                    // "opens with the keypad up." Collapse an empty search on
                    // return so we always resume into the clean feed.
                    if showSearch && searchText.isEmpty {
                        searchFocused = false
                        showSearch = false
                    }
                    vm.handleForegroundReturn()
                }
        .onReceive(NotificationCenter.default.publisher(for: .saveFeedScrollPosition)) { notif in
                            if let postId = notif.userInfo?["postId"] as? String {
                                vm.savedScrollPostId = postId
                            }
                        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                    vm.showExplore = false
                    vm.showPromptCompose = false
                }

                    }
    
    // MARK: - Helper to build post tuple from Firestore doc
    
    static func feedPost(from doc: QueryDocumentSnapshot) -> FeedPost {
            let data = doc.data()
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            return FeedPost(
                id: doc.documentID,
                handle: data["authorHandle"] as? String ?? "anonymous",
                text: data["text"] as? String ?? "",
                tag: data["tag"] as? String,
                likes: data["likeCount"] as? Int ?? 0,
                reposts: data["repostCount"] as? Int ?? 0,
                replies: data["replyCount"] as? Int ?? 0,
                time: Self.timeAgoString(from: createdAt),
                authorId: data["authorId"] as? String ?? "",
                isShareable: data["isShareable"] as? Bool ?? true,
                originalHandle: data["originalHandle"] as? String,
                originalAuthorId: data["originalAuthorId"] as? String,
                originalPostId: data["originalPostId"] as? String,
                promptDate: data["promptDate"] as? String,
                isRepost: data["isRepost"] as? Bool ?? false
            )
        }

    // MARK: - Helpers

    static func timeAgoString(from date: Date) -> String {
            ToskaFormatters.timeAgo(from: date)
        }

    /// The daily-prompt TEXT a post was answering, derived from its promptDate
    /// (yyyy-MM-dd). Prompts are deterministic by day-of-year, so the date alone
    /// recovers the exact prompt — no need to store the text on every post.
    /// Returns nil for non-prompt posts.
    static func promptText(for promptDate: String?) -> String? {
        guard let promptDate = promptDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: promptDate),
              !FeedViewModel.dailyPrompts.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
        return FeedViewModel.dailyPrompts[day % FeedViewModel.dailyPrompts.count].0
    }
}

// MARK: - Feed Post Row

@MainActor
struct FeedPostRow: View, Equatable {
    // Equatable so the feed can wrap rows in .equatable(): when one post's
    // interaction state changes (a like/save mutates the VM's @Published sets and
    // recomputes the whole feed body), SwiftUI skips re-rendering every OTHER row
    // because their value inputs are unchanged. Without this, the closures below
    // are recreated each ForEach pass, so SwiftUI can never skip a row — every
    // like re-rendered all ~20 visible rows. The onLetterExpand closure is
    // intentionally NOT compared (it captures post.id, already covered by postId).
    nonisolated static func == (l: FeedPostRow, r: FeedPostRow) -> Bool {
        l.handle == r.handle
            && l.text == r.text
            && l.tag == r.tag
            && l.likes == r.likes
            && l.reposts == r.reposts
            && l.replies == r.replies
            && l.time == r.time
            && l.postId == r.postId
            && l.authorId == r.authorId
            && l.isAlreadyReposted == r.isAlreadyReposted
            && l.isAlreadyLiked == r.isAlreadyLiked
            && l.isAlreadySaved == r.isAlreadySaved
            && l.isShareable == r.isShareable
            && l.gifUrl == r.gifUrl
            && l.isMidnightPost == r.isMidnightPost
            && l.isLetter == r.isLetter
            && l.isRepostPost == r.isRepostPost
            && l.isWhisperPost == r.isWhisperPost
            && l.isLetterExpanded == r.isLetterExpanded
            && l.reposterHandle == r.reposterHandle
            && l.promptText == r.promptText
            && l.rank == r.rank
    }

    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    var postId: String = ""
    var authorId: String = ""
    // M4 (2026-07-22): like/repost your OWN post are silent no-ops
    // (PostInteractionManager guards + rules deny them) — hide the buttons the
    // way PostDetailView does, instead of rendering dead taps. Rows built
    // without authorId (empty string) keep the buttons: better a guarded no-op
    // than hiding real actions on someone else's post.
    // The DISPLAYED handle's owner is you (original author on repost rows).
    var displayedHandleIsOwn: Bool {
        let owner = isRepostPost ? (originalAuthorId ?? "") : authorId
        return !owner.isEmpty && owner == Auth.auth().currentUser?.uid
    }

    var isOwnPost: Bool {
        // Keys on the INTERACTION target: your own repost of someone else's
        // words is not "your post" for felt/save purposes — the original
        // author's is (owner report 2026-09-21: couldn't like own repost).
        let target = originalPostId != nil ? (originalAuthorId ?? "") : authorId
        return !target.isEmpty && target == Auth.auth().currentUser?.uid
    }
    var isAlreadyReposted: Bool = false
    var isAlreadyLiked: Bool = false
    var isAlreadySaved: Bool = false
        var isShareable: Bool = true
        var gifUrl: String? = nil
        var isMidnightPost: Bool = false
            var isLetter: Bool = false
        var isRepostPost: Bool = false
            var isWhisperPost: Bool = false
        var isLetterExpanded: Bool = false
        var onLetterExpand: (() -> Void)? = nil
        // Reposter's handle when this row is a repost — populated by
        // FeedView when post.originalHandle is set. Drives the
        // "@handle reposted" provenance row at the top of the cell.
        var reposterHandle: String? = nil
        // Repost retarget (owner 2026-09-21, "can't like my repost"): on a
        // repost row, interactions act on the ORIGINAL post — the web client
        // has always worked this way (targetPostId = originalPostId). Without
        // it, liking your own repost hit the copy you author (self-like,
        // correctly denied) and reposting from a repost row hit "cannot
        // repost a repost". nil on non-repost rows.
        var originalPostId: String? = nil
        var originalAuthorId: String? = nil
        // The doc interactions actually target: the original when this row
        // is a repost, the row's own post otherwise.
        private var interactionPostId: String { originalPostId ?? postId }
        private var interactionAuthorId: String {
            originalPostId != nil ? (originalAuthorId ?? "") : authorId
        }
        // The daily prompt this post answered (FeedView passes
        // FeedView.promptText(for: post.promptDate)). When set, the card shows
        // the prompt in plum above the reply, so prompt answers read as
        // "prompt → reply" across the feed.
        var promptText: String? = nil
        // Profile pages render the author's rows under their own header —
        // repeating the handle on every meta line there is noise (owner
        // 2026-09-17 detail pass). Feed/search leave it false.
        var hideMetaHandle: Bool = false
        // Optional leaderboard rank (felt-most page). When set, a subtle
        // serif-italic "01" badge renders at the trailing edge of the handle
        // row. nil everywhere else, so the feed is unaffected.
        var rank: Int? = nil

        @State private var isSaved = false
        @State private var isLiked = false
        @State private var isReposted = false
        @State private var localLikeCount: Int = 0
        @State private var localRepostCount: Int = 0
    @State private var hasInitialized = false
        // N-7 (2026-06-09 re-review): absorb the feed re-delivery echo after an
        // optimistic like, mirroring PostDetailView's suppressListenerUntil. A
        // refresh arriving in the ~1-2s before the Cloud Function increments the
        // server likeCount used to snap localLikeCount back to N then forward to
        // N+1 again — a visible flicker. Skip the listener overwrite inside the
        // window.
        @State private var suppressLikeListenerUntil: Date = .distantPast
        // C-3 (2026-06-11): same suppression window for the repost count — a feed
        // re-delivery mid-round-trip was overwriting the optimistic repost count
        // and flickering it (the like path already had this; reposts didn't).
        @State private var suppressRepostListenerUntil: Date = .distantPast
        // Owner report (2026-09-22, "click twice to unsave"): saves had NO
        // echo-suppression window (likes/reposts did) — the save's delayed
        // listener echo re-filled the bookmark right after an unsave tap,
        // forcing a second tap. Same pattern as the other two.
        @State private var suppressSaveListenerUntil: Date = .distantPast
        @State private var likePulse = false
            @State private var repostPulse = false
            @State private var likePulseTask: Task<Void, Never>? = nil
            @State private var repostPulseTask: Task<Void, Never>? = nil
            // Heart burst overlay state — drives a brief expanding+fading
            // heart that overlays the like icon when the user taps to like.
            // Combined with the existing likePulse scale, the burst makes
            // a like feel rewarding rather than transactional. Both reset
            // automatically and don't compose with anything else.
            @State private var likeBurstScale: CGFloat = 1.0
            @State private var likeBurstOpacity: Double = 0.0
            @State private var showShareCard = false
        @State private var showReportSheet = false
        @State private var showBlockConfirm = false
        @State private var showAdminDeleteConfirm = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
                // 2026-09-16 design: no avatar, no card — words first, then the
                // feeling line (dot + coloured word · handle · time), then the
                // stats line, separated from the next post by a full hairline.
                VStack(alignment: .leading, spacing: 0) {
                // Tapping the post content PUSHES PostDetailView in from the
                // right (real navigation), not a modal pop-up. A
                // destination-closure NavigationLink is used instead of
                // .navigationDestination(...) because FeedPostRow renders
                // dozens of times in an eager VStack across several screens;
                // per-row navigationDestination declarations collide in one
                // NavigationStack and silently stop working. Destination-closure
                // links each carry their own destination, so there's no
                // collision. The action bar lives OUTSIDE this link so its
                // buttons never fight the link's tap.
                NavigationLink {
                    // Repost rows open the ORIGINAL's detail (web parity):
                    // replies, likes, and the ⋯ menu all belong to the post
                    // whose words are on screen, not the reposter's copy.
                    PostDetailView(
                        postId: interactionPostId,
                        handle: handle, // call sites already pass the ORIGINAL author's handle on repost rows
                        text: text,
                        tag: tag,
                        likes: localLikeCount,
                        reposts: localRepostCount,
                        replies: replies,
                        time: time,
                        authorId: interactionAuthorId,
                        isAlreadyLiked: isLiked,
                        isAlreadySaved: isSaved,
                        isAlreadyReposted: isReposted,
                        // Pass GIF/letter/whisper so the detail view's first frame
                        // matches the row — no pop-in reflow on open.
                        gifUrl: gifUrl,
                        isLetter: isLetter,
                        isWhisper: isWhisperPost,
                        isShareable: isShareable
                    )
                    .navigationBarHidden(true)
                } label: {
                  VStack(alignment: .leading, spacing: 0) {
                // Daily-prompt header — when this post is a response to the day's
                // prompt, show the prompt itself in plum above the reply so the
                // card reads "prompt → reply" (the answer in context).
                if let prompt = promptText, !prompt.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .semibold))
                        Text(prompt)
                            .font(ToskaFont.serifItalic(13))
                            .lineSpacing(1)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundColor(ToskaColor.accentText)
                    .padding(.bottom, 10)
                }
                // Repost provenance — small "@reposter reposted" line above
                // the handle row when this post is a repost. Without this,
                // reposts looked identical to original posts and readers had
                // no way to tell the visible handle was the reposter rather
                // than the original author. Only renders when reposterHandle
                // is set (FeedView passes it for reposts; other call sites
                // pass nil so this row is hidden there).
                if let reposter = reposterHandle, !reposter.isEmpty {
                    // "you reposted" for your own reposts (owner 2026-09-22) —
                    // parroting your random handle back at you hid that the
                    // repost was yours. Accent tint, same "accent = you" rule
                    // as the meta-line handle.
                    let reposterIsMe = !authorId.isEmpty && authorId == Auth.auth().currentUser?.uid && isRepostPost
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 10, weight: .regular))
                        Text(reposterIsMe ? "you reposted" : "\(reposter) reposted")
                            .font(ToskaFont.sans(11.5, weight: .medium))
                    }
                    .foregroundColor(reposterIsMe ? ToskaColor.accentText : ToskaColor.handle)
                    .padding(.bottom, 10)
                }

                // Meta line first — dot + feeling · handle · time above the
                // words (2026-09-17 owner request; flipped from the design's
                // words-first order).
                metaLine

                // Post text — 17/1.6 (matches the web's 17px body and the
                // detail view; the design's 18.5 read oversized on device);
                // letters 16 with looser leading.
                if !text.isEmpty {
                    if isLetter && !isLetterExpanded {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(text)
                                .font(ToskaFont.serif(14.5))
                                .foregroundColor(ToskaColor.text)
                                .lineSpacing(4.5)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                                .padding(.top, 10)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    onLetterExpand?()
                                }
                            } label: {
                                Text("keep reading")
                                    .font(ToskaFont.sans(12.5, weight: .semibold))
                                    .foregroundColor(ToskaColor.accentText)
                                    .padding(.top, 13)
                                    .contentShape(Rectangle())
                            }
                        }
                    } else {
                        Text(text)
                            .font(isLetter ? ToskaFont.serif(14.5) : ToskaFont.serif(15))
                            .foregroundColor(ToskaColor.text)
                            .lineSpacing(4.5)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 10)
                    }
                }

                                        // GIF — animated. Uses StableGifPreview
                                        // (shared from ComposeView) so frames
                                        // actually animate via UIImageView; the
                                        // old AsyncImage path only showed the
                                        // first frame because SwiftUI's Image
                                        // doesn't iterate GIF frames.
                if let gifUrl = gifUrl, !gifUrl.isEmpty {
                    StableGifPreview(urlString: gifUrl, maxHeight: 200)
                        .padding(.top, 12)
                }

                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                } // end NavigationLink label
                // Drive the press highlight from the link's ButtonStyle, not a
                // manual gesture. The scroll view owns touch arbitration, so
                // isPressed is only true on a deliberate press and is cancelled
                // the instant a scroll begins — no highlight flicker while
                // scrolling, and the link never fires on a scroll/flick
                // (UITableView / Twitter behavior). See FeedRowPressStyle.
                .buttonStyle(FeedRowPressStyle())
                // Sample/placeholder posts (empty postId) aren't real and have
                // no detail to open — disable the link so tapping them is inert.
                .disabled(postId.isEmpty)

                    // Stats line — "41 felt this | 2 replies | 3 reposts" with
                                    // hairline separators, bookmark + share trailing
                                    // (design 2026-09-16). Zeros included so every row
                                    // has the same shape; numerals tabular. The words
                                    // ARE the actions: felt this = like, replies opens
                                    // the post, reposts toggles the repost.
                                    if !postId.isEmpty {
                                        HStack(spacing: 10) {
                                            // felt this (like) — with the burst overlay.
                                            // X-parity (owner 2026-09-22): live on your OWN
                                            // posts too (X lets you like yourself).
                                            Button { toggleLike() } label: { feltLabel }
                                            .accessibilityLabel(isLiked ? "Unlike post" : "Like post")
                                            .accessibilityValue(localLikeCount == 1 ? "1 person felt this" : "\(localLikeCount) people felt this")
                                            .buttonStyle(ToskaTapStyle())
                                            .scaleEffect(likePulse ? 1.1 : 1.0)
                                            .animation(reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.3, dampingFraction: 0.5), value: likePulse)

                                            statSeparator

                                            // replies — opens the post
                                            NavigationLink {
                                                PostDetailView(
                                                    postId: interactionPostId,
                                                    handle: handle,
                                                    text: text,
                                                    tag: tag,
                                                    likes: localLikeCount,
                                                    reposts: localRepostCount,
                                                    replies: replies,
                                                    time: time,
                                                    authorId: interactionAuthorId,
                                                    isAlreadyLiked: isLiked,
                                                    isAlreadySaved: isSaved,
                                                    isAlreadyReposted: isReposted,
                                                    gifUrl: gifUrl,
                                                    isLetter: isLetter,
                                                    isWhisper: isWhisperPost,
                                                    isShareable: isShareable
                                                )
                                                .navigationBarHidden(true)
                                            } label: {
                                                statText(replies, "reply", "replies")
                                                    .padding(.vertical, 11)
                                            }
                                            .accessibilityLabel("Reply")
                                            .accessibilityValue(replies == 1 ? "1 reply" : "\(replies) replies")
                                            .buttonStyle(ToskaTapStyle())

                                            statSeparator

                                            // reposts — read-only on your OWN posts
                                            // (owner re-ruling 2026-09-22 eve: no
                                            // self-repost; felt stays live); dimmed for
                                            // ephemerals + legacy id-less repost docs.
                                            if isOwnPost {
                                                statText(localRepostCount, "repost", "reposts")
                                                    .accessibilityLabel(localRepostCount == 1 ? "1 repost" : "\(localRepostCount) reposts")
                                            } else {
                                            Button { repostPost() } label: {
                                                statText(localRepostCount, "repost", "reposts")
                                                    .foregroundColor(isReposted ? ToskaColor.accentText : ToskaColor.handle)
                                                    .padding(.vertical, 11)
                                            }
                                            .accessibilityLabel(isReposted ? "Undo repost" : "Repost")
                                            .accessibilityValue(localRepostCount == 1 ? "1 repost" : "\(localRepostCount) reposts")
                                            .buttonStyle(ToskaTapStyle())
                                            .disabled((isRepostPost && originalPostId == nil) || isWhisperPost || isMidnightPost)
                                            .opacity(((isRepostPost && originalPostId == nil) || isWhisperPost || isMidnightPost) ? 0.3 : 1.0)
                                            }

                                            Spacer(minLength: 6)

                                            // bookmark + share trailing, 14pt, dot colour
                                            Button { toggleSave() } label: {
                                                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                                    .font(.system(size: 14, weight: .regular))
                                                    .foregroundColor(isSaved ? ToskaColor.accentText : ToskaColor.dot)
                                                    // 44pt-band hit area — the bare 14pt glyph
                                                    // was a ~10pt-wide target (2026-09-17 gate).
                                                    .frame(minWidth: 30, minHeight: 44)
                                                    .contentShape(Rectangle())
                                            }
                                            .accessibilityLabel(isSaved ? "Unsave post" : "Save post")
                                            .buttonStyle(ToskaTapStyle())

                                            // share — hidden for letters & whispers
                                            // (private/ephemeral, not shareable) and when
                                            // the author disabled sharing.
                                            if isShareable && !isLetter && !isWhisperPost && !isMidnightPost {
                                                Button { showShareCard = true } label: {
                                                    Image(systemName: "square.and.arrow.up")
                                                        .font(.system(size: 14, weight: .regular))
                                                        .foregroundColor(ToskaColor.dot)
                                                        .frame(minWidth: 30, minHeight: 44, alignment: .trailing)
                                                        .contentShape(Rectangle())
                                                }
                                                .accessibilityLabel("Share post")
                                                .buttonStyle(ToskaTapStyle())
                                            }
                                        }
                                        .font(ToskaFont.sans(11.5))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .foregroundColor(ToskaColor.handle)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .padding(.top, 4)
                                    }
                                }
                                            // Span the full width so the whole card is one
                                            // tap target — without this the row is only as
                                            // wide as its widest child, so short / text-only
                                            // posts (and the empty space beside them) had dead
                                            // zones that didn't open the post. Combined with
                                            // .contentShape(Rectangle()) + .onTapGesture below,
                                            // tapping anywhere on the post opens it; the action
                                            // buttons still capture their own taps.
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            // Content-first timeline (design 2026-09-16):
                                            // posts sit DIRECTLY on the paper — no card
                                            // surface, border, or shadow — separated by a
                                            // full-bleed hairline. Padding 24/28 (letters
                                            // breathe a little more, 30 vertical).
                                            .padding(.horizontal, 28)
                                            .padding(.top, isLetter ? 30 : 24)
                                            .padding(.bottom, isLetter ? 26 : 18)
                                            .contentShape(Rectangle())
                                            .overlay(alignment: .bottom) {
                                                Rectangle()
                                                    .fill(ToskaColor.divider)
                                                    .frame(height: 1)
                                            }
                .contextMenu {
                    // M4: like/repost are no-ops on your own post — omit them here
                    // the same way the action bar renders them read-only.
                    // X-parity (2026-09-22): felt available on your own posts too.
                    Button {
                        toggleLike()
                    } label: {
                        Label(isLiked ? "unlike" : "felt this", systemImage: isLiked ? "heart.slash" : "heart")
                    }

                    Button {
                        toggleSave()
                    } label: {
                        Label(isSaved ? "unsave" : "save", systemImage: isSaved ? "bookmark.slash" : "bookmark")
                    }

                    // Repost rows WITH an originalPostId now offer repost too
                    // (it targets the original — web parity); only legacy
                    // repost docs without the id stay repost-less.
                    if (!isRepostPost || originalPostId != nil) && !isOwnPost {
                        Button {
                            repostPost()
                        } label: {
                            // Owner report (2026-09-22): "arrow.2.squarepath.circle"
                            // isn't a real SF Symbol — the undo row rendered
                            // iconless. Same repost glyph both ways; the label
                            // text carries the difference (X does the same).
                            Label(isReposted ? "undo repost" : "repost", systemImage: "arrow.2.squarepath")
                        }
                    }

                    if isShareable && !isLetter && !isWhisperPost && !isMidnightPost {
                                            Button {
                                                showShareCard = true
                                            } label: {
                                                Label("share", systemImage: "square.and.arrow.up")
                                            }
                                        }

                    // Report / block moved here (long-press) so the post header can
                    // stay clean — the tag sits where the inline ⋯ menu used to.
                    if !authorId.isEmpty, authorId != Auth.auth().currentUser?.uid {
                        Divider()
                        Button { showReportSheet = true } label: {
                            Label("report", systemImage: "flag")
                        }
                        Button(role: .destructive) { showBlockConfirm = true } label: {
                            Label("block \(handle)", systemImage: "person.slash")
                        }
                        // Admin-only: remove someone else's post right from the
                        // feed instead of routing through report → moderation
                        // queue. Gated by the same admins/{uid} doc the
                        // moderation row in Settings uses; firestore.rules
                        // independently enforces it server-side, so this button
                        // is convenience, not the security boundary.
                        if AdminManager.shared.isAdmin && !postId.isEmpty {
                            Button(role: .destructive) { showAdminDeleteConfirm = true } label: {
                                Label("delete post (admin)", systemImage: "trash")
                            }
                        }
                    }
                }
                .onAppear {
                                                    if !hasInitialized {
                                                        hasInitialized = true
                                                        localLikeCount = likes
                                                        localRepostCount = reposts
                                                        isLiked = isAlreadyLiked
                                                        isSaved = isAlreadySaved
                                                        isReposted = isAlreadyReposted
                                                    }
                                                }
                                .onDisappear {
                                    likePulseTask?.cancel()
                                    repostPulseTask?.cancel()
                                }
                // Gate the boolean flips behind the same suppression window as the
                // counts — otherwise a listener echo (repostedPostIds updating just
                // after an optimistic tap) re-flips the heart/repost icon back for a
                // beat before settling, the exact flicker the count suppression kills.
                .onChange(of: isAlreadyLiked) { _, newValue in
                    if !postId.isEmpty && Date() > suppressLikeListenerUntil { isLiked = newValue }
                }
                .onChange(of: isAlreadySaved) { _, newValue in
                    if !postId.isEmpty && Date() > suppressSaveListenerUntil { isSaved = newValue }
                }
                .onChange(of: isAlreadyReposted) { _, newValue in
                    if !postId.isEmpty && Date() > suppressRepostListenerUntil { isReposted = newValue }
                }
                // Adopt the latest server counts when the same post id is
                // re-delivered by a feed refresh — without these, the row keeps
                // its first-seen like/repost numbers and drifts from the server.
                .onChange(of: likes) { _, newValue in
                    // N-7: ignore the server echo during the post-tap suppression
                    // window so the optimistic count doesn't flicker.
                    if !postId.isEmpty && Date() > suppressLikeListenerUntil {
                        localLikeCount = newValue
                    }
                }
                .onChange(of: reposts) { _, newValue in
                    // C-3: ignore the server echo during the post-tap suppression
                    // window so the optimistic repost count doesn't flicker.
                    if !postId.isEmpty && Date() > suppressRepostListenerUntil {
                        localRepostCount = newValue
                    }
                }
                // Opening the post uses push navigation (the NavigationLink
                // wrapping the content above) so it slides in from the right.
                // Share and report stay as modal covers — secondary leaf
                // actions where a modal is conventional. Per-row covers don't
                // collide the way per-row navigationDestination(isPresented:)
                // did, which is why these two are safe to keep per-row.
                .fullScreenCover(isPresented: $showShareCard) {
                    EdgeSwipeDismissWrapper {
                        ShareCardView(text: text, handle: handle, feltCount: localLikeCount, tag: tag,
                                      shareURL: ShareConsent.publicShareURL(
                                          postId: interactionPostId, isShareable: isShareable,
                                          isLetter: isLetter, isWhisper: isWhisperPost,
                                          isMidnight: isMidnightPost))
                            .navigationBarHidden(true)
                    }
                }
                .fullScreenCover(isPresented: $showReportSheet) {
                    EdgeSwipeDismissWrapper {
                        NavigationStack {
                            // Repost rows report/block the ORIGINAL author —
                            // the words on screen are theirs (handle already
                            // shows them); the reposter is reachable via
                            // their own rows.
                            ReportSheet(target: .post(
                                postId: interactionPostId,
                                authorId: interactionAuthorId,
                                authorHandle: handle,
                                text: text
                            ))
                            .navigationBarHidden(true)
                        }
                    }
                }
                                .confirmationDialog(
                                    "block \(handle)?",
                                    isPresented: $showBlockConfirm,
                                    titleVisibility: .visible
                                ) {
                                    Button("block", role: .destructive) {
                                        BlockedUsersCache.shared.block(interactionAuthorId, handle: handle)
                                    }
                                    Button("cancel", role: .cancel) {}
                                } message: {
                                    Text("you won't see their posts or replies. they won't be notified.")
                                }
                                .confirmationDialog(
                                    "delete this post for everyone?",
                                    isPresented: $showAdminDeleteConfirm,
                                    titleVisibility: .visible
                                ) {
                                    Button("delete (admin)", role: .destructive) { adminDeletePost() }
                                    Button("cancel", role: .cancel) {}
                                } message: {
                                    Text("removes the post and its replies permanently. this action is recorded in the admin audit log.")
                                }
    }

    /// Admin-only removal of another user's post, straight from the feed.
    /// Two-step mirror of AdminModerationView.deletePost: stamp deletedBy/
    /// deletedAt first so auditPostDeletion logs the acting admin off the
    /// pre-delete snapshot, then delete. Server triggers clean up the reply
    /// subtree, likes, and repost copies — no client-side cascade (the
    /// own-post path's like cleanup would permission-fail for an admin).
    private func adminDeletePost() {
        guard AdminManager.shared.isAdmin, !postId.isEmpty,
              let adminUid = Auth.auth().currentUser?.uid else { return }
        let ref = Firestore.firestore().collection("posts").document(postId)
        Task { @MainActor in
            do {
                try await ref.updateData([
                    "deletedBy": adminUid,
                    "deletedAt": FieldValue.serverTimestamp(),
                ])
                try await ref.delete()
                // Same signal the own-post delete path sends — strips the post
                // from the in-memory feed and any cached cards immediately.
                NotificationCenter.default.post(name: .postDeleted, object: nil,
                                                userInfo: ["postId": postId])
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                Telemetry.recordError(error, context: "FeedPostRow.adminDeletePost")
            }
        }
    }
    
    // MARK: - Meta + stats pieces (design 2026-09-16)

    /// Meta line under the words: 5pt dot + coloured feeling word · handle ·
    /// time, all 11.5pt. Letters read "letter · N min · 2d". Ephemeral badges
    /// and the most-felt rank keep their slots at the trailing edge.
    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 8) {
            if let tag = tag {
                Circle()
                    .fill(tagDotColor(for: tag))
                    .frame(width: 5, height: 5)
                Text(tag)
                    .font(ToskaFont.sans(11.5, weight: .medium))
                    .foregroundColor(tagColor(for: tag))
                Text("·").foregroundColor(ToskaColor.dot)
            }
            if !hideMetaHandle {
                // Your handle renders in ACCENT everywhere your words appear
                // (owner 2026-09-22): anonymous handles aren't self-
                // recognizable, and ink-violet already means "you" app-wide
                // (felt hearts, write pill, your-response check).
                Text(handle)
                    .foregroundColor(displayedHandleIsOwn ? ToskaColor.accentText : nil)
                    .fontWeight(displayedHandleIsOwn ? .medium : nil)
                Text("·").foregroundColor(ToskaColor.dot)
            }
            Text(metaTimeText)
            if isMidnightPost {
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundColor(ToskaColor.dot)
            }
            if isWhisperPost {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundColor(ToskaColor.dot)
            }
            if let rank = rank {
                Spacer(minLength: 8)
                Text(String(format: "%02d", rank))
                    .font(ToskaFont.sans(11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(ToskaColor.accentText)
            }
        }
        .font(ToskaFont.sans(11.5))
        .foregroundColor(ToskaColor.handle)
    }

    /// "letter · 3 min · 2d" for letters (reading time at ~200 wpm), plain
    /// relative time otherwise.
    private var metaTimeText: String {
        guard isLetter else { return time }
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let mins = max(1, Int((Double(words) / 200.0).rounded(.up)))
        return "letter · \(mins) min · \(time)"
    }

    /// "41 felt this" — count semibold, word regular; the whole element takes
    /// the feeling's text colour when liked (heart fills to match).
    private var feltLabel: some View {
        HStack(spacing: 7) {
            ZStack {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .regular))
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .regular))
                    .scaleEffect(likeBurstScale)
                    .opacity(likeBurstOpacity)
                    .allowsHitTesting(false)
            }
            statText(localLikeCount, "felt this", "felt this")
        }
        .foregroundColor(isLiked ? likedTint : ToskaColor.handle)
        .padding(.vertical, 11)
    }

    /// Liked state borrows the feeling's ink; untagged posts fall back to the
    /// accent text colour.
    private var likedTint: Color {
        tag.map { tagColor(for: $0) } ?? ToskaColor.accentText
    }

    private func statText(_ count: Int, _ one: String, _ many: String) -> Text {
        // Clamp at zero (mirrors the web's statsRow) — drifted counters on a
        // not-yet-reconciled doc must never render "-1 replies".
        let n = max(0, count)
        return Text("\(formatCount(n)) ").fontWeight(.semibold)
            + Text(n == 1 ? one : many)
    }

    private var statSeparator: some View {
        Rectangle()
            .fill(ToskaColor.divider2)
            .frame(width: 1, height: 11)
    }
    
    // MARK: - Like
        
        func toggleLike() {
            // Offline likes now QUEUE (OfflineActionQueue) with an optimistic
            // heart — no warning buzz, the tap is real and syncs on reconnect.
            // N-7: arm the suppression window at tap time, re-arm on completion
            // (mirrors PostDetailView.toggleLike) so a feed refresh can't snap
            // the optimistic count back mid-round-trip.
            suppressLikeListenerUntil = Date().addingTimeInterval(2.0)
            PostInteractionManager.toggleLike(
                postId: interactionPostId,
                authorId: interactionAuthorId,
                currentlyLiked: isLiked,
                currentCount: localLikeCount
            ) { result in
                isLiked = result.isLiked
                localLikeCount = result.newCount
                suppressLikeListenerUntil = Date().addingTimeInterval(1.5)
                if result.isLiked {
                                    likePulse = true
                                    likePulseTask?.cancel()
                                    likePulseTask = Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 600_000_000)
                                        guard !Task.isCancelled else { return }
                                        likePulse = false
                                    }
                                    // Burst: reset to start state, then animate
                                    // out. easeOut over 0.55s makes the heart
                                    // pop quickly then trail off — feels lively
                                    // without being chaotic. Skipped under
                                    // accessibility reduce-motion.
                                    if !reduceMotion {
                                        likeBurstScale = 1.0
                                        likeBurstOpacity = 0.85
                                        withAnimation(.easeOut(duration: 0.55)) {
                                            likeBurstScale = 2.6
                                            likeBurstOpacity = 0.0
                                        }
                                    }
                                }
            }
        }
    
    // MARK: - Repost
        
        func repostPost() {
            // Repost rows retarget to the ORIGINAL (interactionPostId), so
            // tapping repost on someone's repost row reposts the original —
            // web behavior. The only dead end is a repost row that somehow
            // lacks originalPostId (legacy doc): the manager's cannot-repost-
            // a-repost guard still catches that server-side.
            guard !isRepostPost || originalPostId != nil else { return }
            // M4: same offline feedback as toggleLike — the manager no-ops.
            guard NetworkMonitor.shared.isConnected else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            // C-3: arm the suppression window so the feed listener echo doesn't
            // clobber the optimistic count (mirrors toggleLike).
            suppressRepostListenerUntil = Date().addingTimeInterval(2.0)

            // Toggle: if already reposted, UNDO it (delete the repost doc).
            if isReposted {
                PostInteractionManager.unrepost(
                    postId: interactionPostId,
                    currentCount: localRepostCount
                ) { result in
                    isReposted = result.isReposted
                    localRepostCount = result.newCount
                    suppressRepostListenerUntil = Date().addingTimeInterval(1.5)
                }
                return
            }

            PostInteractionManager.repost(
                postId: interactionPostId,
                postText: text,
                postTag: tag,
                authorId: interactionAuthorId,
                originalHandle: handle,
                currentCount: localRepostCount
            ) { result in
                isReposted = result.isReposted
                localRepostCount = result.newCount
                suppressRepostListenerUntil = Date().addingTimeInterval(1.5)
                if result.isReposted {
                                    repostPulse = true
                                    repostPulseTask?.cancel()
                                    repostPulseTask = Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 500_000_000)
                                        guard !Task.isCancelled else { return }
                                        repostPulse = false
                                    }
                                }
            }
        }
    
    // MARK: - Save
            
            func toggleSave() {
                // Offline saves queue with an optimistic bookmark (see
                // OfflineActionQueue) — the confirm haptic is honest now.
                HapticManager.play(.feltThis)
                suppressSaveListenerUntil = Date().addingTimeInterval(2.0)
                PostInteractionManager.toggleSave(
                    postId: interactionPostId,
                    authorId: interactionAuthorId,
                    currentlySaved: isSaved
                ) { newSaved in
                    isSaved = newSaved
                    suppressSaveListenerUntil = Date().addingTimeInterval(1.5)
                }
            }


}

// MARK: - Feed Row Press Style
//
// Press highlight for the tappable post content. Driven by the link's own
// isPressed (which the enclosing ScrollView manages) instead of a manual
// gesture, so the highlight only shows on a deliberate press and is cancelled
// the moment a scroll starts — matching UITableView / Twitter. No flicker
// while scrolling, and the row's tap never fires mid-scroll.
struct FeedRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.toskaDivider.opacity(0.18) : Color.clear)
            // Subtle scale on touch-down so a full-row tap reads instantly (a big
            // row can't scale much without looking odd — 0.99 is enough to register).
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// Press style for the small action buttons (like / repost / save / share /
// reply). `.plain` gave them NO touch-down feedback (the "mushy" feel) — this
// scales + dims them the moment the finger lands, then springs back on release.
struct ToskaTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Collapsible Feed Header Card

@MainActor
struct FeedHeaderCard: View {
    @ObservedObject var vm: FeedViewModel
    @State private var isExpanded = false
    
    // hasContent gate removed — the daily prompt is ALWAYS meaningful (it
    // rotates and the user can always tap "respond"), so the card must
    // always render. The previous gate was inherited from when the card only
    // existed to surface optional secondary content (witness post, weather,
    // daily moment, most-unsaid); removing the most-unsaid surface meant a
    // fresh user on a quiet day saw nothing — no prompt, no respond button.

    /// Display-only sentence case for the prompt (owner 2026-09-17): the
    /// stored prompts are lowercase (brand voice), the band capitalizes the
    /// first letter.
    private var displayPrompt: String {
        let p = vm.todaysPrompt.0
        guard let f = p.first else { return p }
        return f.uppercased() + p.dropFirst()
    }

    var body: some View {
        VStack(spacing: 0) {
                // Today's-prompt band (design 2026-09-16): full-bleed promptBg,
                // uppercase eyebrow, compact serif prompt, "write yours" link —
                // no pill, no counter, closed by a promptHair rule.
                VStack(alignment: .leading, spacing: 0) {
                    Text("today's prompt")
                        .font(ToskaFont.sans(10.5, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.74)
                        .foregroundColor(ToskaColor.promptEyebrow)

                    // Compact prompt (2026-09-17 owner cleanup): 18pt, snug
                    // leading, tight rhythm — the band was reading bulky.
                    Text(displayPrompt)
                        .font(ToskaFont.serif(16))
                        .foregroundColor(ToskaColor.promptInk)
                        .lineSpacing(0)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    // "write yours" until there's a response FOR TODAY, then a
                    // compact "your response" opener (owner 2026-09-17: the
                    // response lives in the feed like any post — no pinned
                    // card at the top; this link is how the author revisits
                    // it). The promptDate == today check also survives the
                    // midnight rollover (yesterday's cached answer must not
                    // lock the new day's prompt).
                    if vm.todaysPromptResponse?.promptDate != vm.todaysPromptDateString {
                        Button {
                            vm.showPromptCompose = true
                            HapticManager.play(.compose)
                        } label: {
                            Text("write yours")
                                .font(ToskaFont.sans(12.5, weight: .semibold))
                                .foregroundColor(ToskaColor.accentText)
                                // Small visible gap; the inset extends the hit
                                // area to the 44pt band without the dead space
                                // a reserved frame added (owner flagged).
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .contentShape(Rectangle().inset(by: -10))
                        }
                        .buttonStyle(.plain)
                    } else if let response = vm.todaysPromptResponse {
                        NavigationLink {
                            PostDetailView(
                                postId: response.id,
                                handle: response.handle,
                                text: response.text,
                                tag: response.tag,
                                likes: response.likes,
                                reposts: response.reposts,
                                replies: response.replies,
                                time: response.time,
                                authorId: response.authorId
                            )
                            .navigationBarHidden(true)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                Text("your response")
                                    .font(ToskaFont.sans(12.5, weight: .semibold))
                            }
                            .foregroundColor(ToskaColor.accentText)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .contentShape(Rectangle().inset(by: -10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View your response")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 14, leading: 28, bottom: 10, trailing: 28))
                .background(ToskaColor.promptBg)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ToskaColor.promptHair)
                        .frame(height: 1)
                }

            }

        // Anniversary post (always visible, not collapsed)
        if let annPost = vm.anniversaryPost {
                    AnniversaryCardView(post: annPost, postId: annPost.postId)
                }
    }
}
// SkeletonPostRow + Skeleton* family now live in ToskaTheme.swift so the
// notification + conversation variants share the same shimmer engine. The
// previous opacity-pulse implementation here was replaced; existing call
// sites (FeedView's own SKELETONS branch above) keep working unchanged.

// MARK: - Shared Tag Data

struct TagItem {
    let name: String
    let colorHex: String
    let icon: String
}

let sharedTags: [TagItem] = [
    TagItem(name: "longing", colorHex: "5A467D", icon: "moon.stars"),
    TagItem(name: "numb", colorHex: "305380", icon: "circle.dotted"),
    TagItem(name: "anger", colorHex: "803F33", icon: "flame"),
    TagItem(name: "regret", colorHex: "76471D", icon: "arrow.uturn.backward"),
    TagItem(name: "acceptance", colorHex: "145E3F", icon: "leaf"),
    TagItem(name: "confusion", colorHex: "005E62", icon: "questionmark.circle"),
    TagItem(name: "unsent", colorHex: "085A78", icon: "envelope"),
    TagItem(name: "moving on", colorHex: "425C24", icon: "arrow.right.circle"),
    TagItem(name: "still love you", colorHex: "7F3A42", icon: "heart"),
]

// The SF Symbol for a tag — single source of truth (the same icon the compose
// picker / Explore / onboarding show), so avatars match everywhere. nil for a
// missing / seed-only tag.
func tagSymbol(for tag: String?) -> String? {
    guard let tag = tag?.lowercased() else { return nil }
    if let icon = sharedTags.first(where: { $0.name == tag })?.icon { return icon }
    // L3 (2026-07-22): seed-only tags — they exist on seeded/legacy posts and
    // in tagColor's palette but are deliberately NOT in sharedTags (adding
    // them there would put them in the compose picker). Give them real icons
    // so their avatars don't fall back to the generic quote glyph.
    switch tag {
    case "rebuilding": return "sunrise"
    case "lonely":     return "moon"
    default:           return nil
    }
}

// The emotion-tinted avatar used across the feed, post detail, and profiles: a
// soft circle in the feeling's color carrying its icon (a plain circle when
// untagged). Shared so every surface renders it identically.
@ViewBuilder func emotionAvatar(for tag: String?, size: CGFloat = 34) -> some View {
    // Tint uses the mid-lightness DOT colour — the dark text colour turns to
    // mud behind a 0.22-opacity fill.
    let tint = tag.map { tagDotColor(for: $0) } ?? ToskaColor.accent
    // Untagged (or a seed-only tag) → a neutral "written thought" quotation
    // glyph in plum, so every avatar carries an icon rather than an empty circle.
    let symbol = tagSymbol(for: tag) ?? "text.quote"
    Circle()
        .fill(tint.opacity(0.22))
        .frame(width: size, height: size)
        .overlay(
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundColor(tint)
        )
}

// MARK: - Shared Helpers

func formatCount(_ count: Int) -> String {
    if count >= 1000 {
        let val = Double(count) / 1000
        return val.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fk", val)
            : String(format: "%.1fk", val)
    }
    return "\(count)"
}

// MARK: - Shared Time-of-Day Labels

// "tonight" starts at 9pm (21:00) rather than 10pm — matches the threshold
// used by OnboardingView.promptTimeLabel and FeedViewModel.weatherPhrase.
// Previously this helper used 22:00 while the duplicated logic in those two
// files used 21:00, so between 9pm and 10pm the app showed "this evening" /
// "tonight" inconsistently depending on which surface the user was on.
func timeOfDayLabel() -> String {
    let hour = Calendar.current.component(.hour, from: Date())
    if hour >= 21 || hour < 5 { return "tonight" }
    else if hour < 12 { return "this morning" }
    else if hour < 17 { return "this afternoon" }
    else { return "this evening" }
}

// MARK: - Tag Color

func tagColor(for tag: String) -> Color {
    // 2026-09-16 design palette — each feeling has a TEXT colour (the word)
    // and a DOT colour (the 5pt dot / avatar tint, see tagDotColor below).
    // Values are the design's oklch pairs converted to sRGB; identical to the
    // web's --em-* / --em-*-t variables. SINGLE SOURCE OF TRUTH with
    // sharedTags below — the two are kept identical. rebuilding + lonely are
    // seed-only tags absent from the design; their values are derived in the
    // same oklch style (rebuilding shares moving-on's green family, lonely a
    // muted slate-violet).
    switch tag {
    case "longing":        return Color(hex: "5A467D")
    case "rebuilding":     return Color(hex: "305F33")
    case "acceptance":     return Color(hex: "145E3F")
    case "lonely":         return Color(hex: "4F4F6D")
    case "numb":           return Color(hex: "305380")
    case "anger":          return Color(hex: "803F33")
    case "regret":         return Color(hex: "76471D")
    case "confusion":      return Color(hex: "005E62")
    case "unsent":         return Color(hex: "085A78")
    case "moving on":      return Color(hex: "425C24")
    case "still love you": return Color(hex: "7F3A42")
    default:               return Color(hex: "56535E")
    }
}

// The feeling's DOT colour — the mid-lightness cut used for the 5pt dot next
// to the word and for tinted fills (avatar circles), where the dark text
// colour would read muddy.
func tagDotColor(for tag: String) -> Color {
    switch tag {
    case "longing":        return Color(hex: "927BBD")
    case "rebuilding":     return Color(hex: "629964")
    case "acceptance":     return Color(hex: "4C9A73")
    case "lonely":         return Color(hex: "8483A8")
    case "numb":           return Color(hex: "5E88BF")
    case "anger":          return Color(hex: "C17565")
    case "regret":         return Color(hex: "B57C4D")
    case "confusion":      return Color(hex: "35989D")
    case "unsent":         return Color(hex: "4192B6")
    case "moving on":      return Color(hex: "759554")
    case "still love you": return Color(hex: "C26F76")
    default:               return Color(hex: "93909B")
    }
}

// MARK: - Shared Blocked Users Helper

struct FeedColumn: View {
    @ObservedObject var vm: FeedViewModel
    let tab: Int
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding

    private func matchesSearch(_ post: FeedPost) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return post.handle.lowercased().contains(q)
            || post.text.lowercased().contains(q)
            || (post.tag?.lowercased().contains(q) ?? false)
    }

    @ViewBuilder private var inlineSearchBar: some View {
                                HStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 15, weight: .regular))
                                            .foregroundColor(ToskaColor.text3)
                                        TextField("search", text: $searchText)
                                            .font(.system(size: 15))
                                            .foregroundColor(ToskaColor.handle)
                                            .autocorrectionDisabled()
                                            .textInputAutocapitalization(.never)
                                            .focused(searchFocused)
                                            .submitLabel(.search)
                                            .accessibilityLabel("Search")
                                        if !searchText.isEmpty {
                                            Button {
                                                searchText = ""
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 15))
                                                    .foregroundColor(ToskaColor.text3)
                                            }
                                            .accessibilityLabel("Clear search")
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    // Quiet gray capsule fill. Was a frosted glass
                                    // material (.thinMaterial / .glassEffect), but
                                    // SwiftUI materials render as an OPAQUE rectangle
                                    // during navigation push/pop (they can't sample
                                    // their backdrop mid-transition) — that was the
                                    // "rectangle covers the search bar for a second"
                                    // flash when opening a post. A solid fill looks
                                    // nearly identical and transitions cleanly.
                                    .background(ToskaColor.input, in: Capsule())

                                    // Cancel — appears while searching; clears the
                                    // query and drops focus, returning to the feed.
                                    if searchFocused.wrappedValue || !searchText.isEmpty {
                                        Button {
                                            searchText = ""
                                            searchFocused.wrappedValue = false
                                        } label: {
                                            Text("cancel")
                                                .font(ToskaFont.sans(15))
                                                .foregroundColor(ToskaColor.accent)
                                        }
                                        .transition(.opacity)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 8)
    }

    @ViewBuilder private var categoryPills: some View {
                                if searchFocused.wrappedValue || !searchText.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            // "all" — clears the tag filter. Selected
                                            // (dark pill) when no tag query is active.
                                            let allSelected = searchText.isEmpty
                                            Button {
                                                searchText = ""
                                            } label: {
                                                Text("all")
                                                    .font(ToskaFont.sans(12, weight: .semibold))
                                                    .foregroundColor(allSelected ? ToskaColor.bg : ToskaColor.text2)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 4)
                                                    .background(allSelected ? ToskaColor.accent : Color.clear)
                                                    .overlay(Capsule().stroke(allSelected ? Color.clear : ToskaColor.divider, lineWidth: 1))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)

                                            ForEach(sharedTags, id: \.name) { tag in
                                                let isSel = searchText == tag.name
                                                Button {
                                                    searchText = tag.name
                                                    searchFocused.wrappedValue = false
                                                } label: {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: tag.icon)
                                                            .font(.system(size: 11))
                                                        Text(tag.name)
                                                            .font(ToskaFont.sans(13, weight: .medium))
                                                    }
                                                    .foregroundColor(isSel ? Color(hex: "FFFFFF") : Color(hex: tag.colorHex))
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 8)
                                                    .background(isSel ? Color(hex: tag.colorHex) : Color(hex: tag.colorHex).opacity(0.12))
                                                    .clipShape(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                    .padding(.top, 8)
                                    .padding(.bottom, 12)
                                    .transition(.opacity)
                                }
    }

    @ViewBuilder
    private func feedRow(for post: FeedPost, prefetchTriggerId: String?) -> some View {
                                                                                                                                                if post.id.hasPrefix("sample_") {
                                                                                                                                                    FeedPostRow(
                                                                                                                                                        handle: post.handle,
                                                                                                                                                        text: post.text,
                                                                                                                                                        tag: post.tag,
                                                                                                                                                        likes: post.likes,
                                                                                                                                                        reposts: post.reposts,
                                                                                                                                                        replies: post.replies,
                                                                                                                                                        time: post.time
                                                                                                                                                    )
                                                                                                                                                    .equatable()
                                                                                                                                                } else {
                                                                                                                                                    FeedPostRow(
                                                                                                                                                        handle: (post.isRepost ? (post.originalHandle ?? post.handle) : post.handle),
                                                                                                                                                        text: post.text,
                                                                                                                                                        tag: post.tag,
                                                                                                                                                        likes: post.likes,
                                                                                                                                                        reposts: post.reposts,
                                                                                                                                                        replies: post.replies,
                                                                                                                                                        time: post.time,
                                                                                                                                                        postId: post.id,
                                                                                                                                                        authorId: post.authorId,
                                                                                                                                                        // Seed state from the INTERACTION target (the
                                                                                                                                                        // original on repost rows) — likes/saves live there.
                                                                                                                                                        isAlreadyReposted: vm.repostedPostIds.contains(post.originalPostId ?? post.id),
                                                                                                                                                        isAlreadyLiked: vm.likedPostIds.contains(post.originalPostId ?? post.id),
                                                                                                                                                        isAlreadySaved: vm.savedPostIds.contains(post.originalPostId ?? post.id),
                                                                                                                                                        isShareable: post.isShareable,
                                                                                                                                                        gifUrl: vm.postGifUrls[post.id],
                                                                                                                                                        isMidnightPost: vm.midnightPostIds.contains(post.id),
                                                                                                                                                        isLetter: vm.letterPostIds.contains(post.id),
                                                                                                                                                        isRepostPost: vm.repostPostIds.contains(post.id),
                                                                                                                                                        isWhisperPost: vm.whisperPostIds.contains(post.id),
                                                                                                                                                        isLetterExpanded: vm.expandedLetterIds.contains(post.id),
                                                                                                                                                        onLetterExpand: { vm.expandedLetterIds.insert(post.id) },
                                                                                                                                                        reposterHandle: (post.isRepost && post.originalHandle != nil) ? post.handle : nil,
                                                                                                                                                        originalPostId: post.isRepost ? post.originalPostId : nil,
                                                                                                                                                        originalAuthorId: post.isRepost ? post.originalAuthorId : nil,
                                                                                                                                                        // The prompt renders in purple above every response
                                                                                                                                                        // row — author included (owner 2026-09-17: with the
                                                                                                                                                        // pinned card gone, the row is the response's one
                                                                                                                                                        // home in the feed and should carry its context).
                                                                                                                                                        promptText: FeedView.promptText(for: post.promptDate)
                                                                                                                                                                                                                                                                                                    )
                                                                                                                                                                                                                                                                                                    .equatable()
                                                                                                                                                                                                                                                                                                    .id(post.id)
                                                                                                                                                                                                                                                                                                    .onAppear {
                                                                                                                                                                                                                                                                                                        // Prefetch the next page when this row is
                                                                                                                                                                                                                                                                                                        // ~5 posts from the end. By the time the
                                                                                                                                                                                                                                                                                                        // user reaches the bottom, the next page
                                                                                                                                                                                                                                                                                                        // is usually already loaded — no visible
                                                                                                                                                                                                                                                                                                        // spinner, smoother feed.
                                                                                                                                                                                                                                                                                                        // Prefetch when the 5-from-end row of the RENDERED list scrolls
                                                                                                                                                                                                                                                                                                        // in. prefetchTriggerId is computed off `visible` (the filtered
                                                                                                                                                                                                                                                                                                        // set actually shown) and is nil when searching or on a short
                                                                                                                                                                                                                                                                                                        // feed — so the trigger row is always in the lazy tail and fires
                                                                                                                                                                                                                                                                                                        // on scroll, not immediately on a small-feed launch.
                                                                                                                                                                                                                                                                                                        guard tab == 0,
                                                                                                                                                                                                                                                                                                              vm.hasMorePosts,
                                                                                                                                                                                                                                                                                                              !vm.isLoadingMore,
                                                                                                                                                                                                                                                                                                              let triggerId = prefetchTriggerId,
                                                                                                                                                                                                                                                                                                              post.id == triggerId else { return }
                                                                                                                                                                                                                                                                                                        vm.loadMorePosts()
                                                                                                                                                                                                                                                                                                    }
                                                                                                                                                                                                                                                                                                }
    }

    var body: some View {
                GeometryReader { geo in
                            ScrollViewReader { proxy in
                                ScrollView(showsIndicators: false) {
                            // Outer VStack (not LazyVStack): a fully-lazy feed here
                            // reports near-zero measured height on cold launch and
                            // never materialises the rows until pull-to-refresh
                            // re-triggers layout (the blank-feed bug). We keep the
                            // container eager, but the post list itself is split
                            // into an EAGER prefix (first 14 — fills the screen so
                            // the ScrollView gets a real height on launch) plus a
                            // LazyVStack TAIL (remaining scored posts, built only as
                            // they scroll in). That gives us both: the feed always
                            // appears on launch AND we don't construct all ~60
                            // scored rows up front. See feedRow(for:).
                                    VStack(spacing: 0) {
                                                                                Color.clear.frame(height: 0).id("feedTop")
                                // Pull-to-refresh is handled entirely by the native
                                // .refreshable below. The old custom ToskaRefreshHeader
                                // was driven by vm.dragOffset/isRefreshing — both now
                                // dead (always 0/false since the custom drag gesture
                                // was removed), so it rendered a second, out-of-sync
                                // spinner box on refresh. Removed (2026 polish).
                                            if let error = vm.fetchError {
                                                HStack(spacing: 8) {
                                                    Image(systemName: "exclamationmark.circle")
                                                        .font(.system(size: 10))
                                                    Text(error)
                                                        .font(ToskaFont.sans(11))
                                                    Spacer()
                                                    Button {
                                                        vm.fetchError = nil
                                                        vm.fetchPosts()
                                                    } label: {
                                                        Text("retry")
                                                            .font(ToskaFont.sans(11, weight: .semibold))
                                                    }
                                                }
                                                .foregroundColor(Color.toskaErrorRed)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .frame(maxWidth: .infinity)
                                                .background(Color.toskaErrorRed.opacity(0.06))
                                            }
                                // MARK: - Collapsed feed header (daily prompt). The
                                // search bar + filter chips now live in the screen
                                // header (toggled by the 🔍 icon), so here we only hide
                                // the prompt while an active query is filtering.
                                                    if tab == 0 && searchText.isEmpty {
                                                        FeedHeaderCard(vm: vm)
                                                    }

                                if tab == 1 && vm.followingPosts.isEmpty {
                                                        VStack(spacing: 12) {
                                                            Text("the things we don't say out loud\nstill need somewhere to go.")
                                                                .font(ToskaFont.serifItalic(16))
                                                                .foregroundColor(ToskaColor.text2)
                                                                .multilineTextAlignment(.center)
                                                                .lineSpacing(3)
                                                            Text("follow someone to see their words here")
                                                                .font(ToskaFont.sans(12.5))
                                                                .foregroundColor(ToskaColor.text3)
                                                            // A way FORWARD — the empty state was a dead
                                                            // end (owner 2026-09-17 user-mindset pass).
                                                            Button {
                                                                vm.showExplore = true
                                                            } label: {
                                                                Text("find people to follow")
                                                                    .font(ToskaFont.sans(12.5, weight: .semibold))
                                                                    .foregroundColor(ToskaColor.accentText)
                                                                    .padding(.horizontal, 16)
                                                                    .frame(minHeight: 36)
                                                                    .overlay(Capsule().stroke(ToskaColor.divider2, lineWidth: 1))
                                                                    .contentShape(Capsule())
                                                            }
                                                            .padding(.top, 6)
                                                        }
                                                        .frame(maxWidth: .infinity)
                                                        .padding(.vertical, 60)
                                                    }
                                        
                                        if tab == 1 && vm.followingFetchIncomplete {
                                            HStack(spacing: 8) {
                                                Image(systemName: "exclamationmark.circle")
                                                    .font(.system(size: 10))
                                                Text("some posts may be missing — pull to refresh")
                                                    .font(ToskaFont.sans(11))
                                            }
                                            .foregroundColor(Color.toskaAccentTan)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity)
                                            .background(Color.toskaAccentTan.opacity(0.06))
                                        }
                    
                    
                                if vm.postsForTab(tab).isEmpty && !vm.hasLoadedOnce {
                                                                    #if DEBUG
                                                                    let _ = print("🎨 BODY — branch: SKELETONS (posts.isEmpty, !hasLoadedOnce)")
                                                                    #endif
                                                                    ForEach(0..<6, id: \.self) { _ in
                                                                        SkeletonPostRow()
                                                                            .background(LateNightTheme.feedBackground)
                                                                    }
                                                                } else if vm.postsForTab(tab).isEmpty && vm.hasLoadedOnce && tab == 0 {
                                                                    #if DEBUG
                                                                    let _ = print("🎨 BODY — branch: EMPTY STATE (posts.isEmpty, hasLoadedOnce, tab 0)")
                                                                    #endif
                                    // First-run empty state. The fetch finished
                                    // and there's genuinely nothing to show
                                    // (no posts in window, none from people
                                    // they follow). Coach concrete actions
                                    // instead of leaving a blank screen.
                                    VStack(spacing: 16) {
                                        Image(systemName: "moon.stars")
                                            .font(.system(size: 28, weight: .light))
                                            .foregroundColor(LateNightTheme.tertiaryText)
                                        Text("it's quiet right now.")
                                            .font(ToskaFont.serifItalic(16))
                                            .foregroundColor(ToskaColor.text2)
                                            .multilineTextAlignment(.center)
                                        Text("be the first one to say what you couldn't say to them.\nor go find someone who already did.")
                                            .font(ToskaFont.sans(12))
                                            .foregroundColor(LateNightTheme.tertiaryText)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(3)
                                            .padding(.horizontal, 24)
                                        HStack(spacing: 8) {
                                            Button {
                                                NotificationCenter.default.post(name: .openComposeFromEmptyFeed, object: nil)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle")
                                                        .font(.system(size: 11))
                                                    Text("say something")
                                                        .font(ToskaFont.sans(12, weight: .medium))
                                                }
                                                .foregroundColor(ToskaColor.onAccent)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(ToskaColor.accent)
                                                .clipShape(Capsule())
                                            }
                                            Button {
                                                vm.showExplore = true
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "magnifyingglass")
                                                        .font(.system(size: 11))
                                                    Text("explore")
                                                        .font(ToskaFont.sans(12, weight: .medium))
                                                }
                                                .foregroundColor(ToskaColor.accentText)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(ToskaColor.input)
                                                .clipShape(Capsule())
                                            }
                                        }
                                        .padding(.top, 4)
                                        Text("pull down to refresh")
                                            .font(ToskaFont.sans(9))
                                            .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
                                            .padding(.top, 8)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                                    .padding(.bottom, 40)
                                                                } else {
                                                                                                                                    let visible = vm.postsForTab(tab).filter(matchesSearch)
                                                                                                                                    // Prefetch trigger = 5-from-end of the RENDERED list, only when
                                                                                                                                    // not searching and the list is long enough that the trigger row
                                                                                                                                    // sits in the LAZY tail (so it fires on scroll, not on launch).
                                                                                                                                    // The eager prefix is prefix(14) (indices 0–13), and the trigger is
                                                                                                                                    // index count-5, so it only clears the eager block when count-5 >= 14,
                                                                                                                                    // i.e. count >= 19. With the old `> 14` guard, feeds of 15–18 put the
                                                                                                                                    // trigger INSIDE the eager prefix → loadMore fired on cold launch.
                                                                                                                                    let prefetchTriggerId: String? = (searchText.isEmpty && visible.count > 18)
                                                                                                                                        ? visible.dropLast(4).last?.id : nil
                                                                                                                                    // Eager prefix fills the screen so the ScrollView measures a real height
                                                                                                                                    // on cold launch (a fully-lazy feed here reports ~0 height and never
                                                                                                                                    // materialises — the blank-feed bug). The tail is a LazyVStack so we
                                                                                                                                    // don't build all ~60 scored rows up front.
                                                                                                                                    if !searchText.isEmpty && visible.isEmpty
                                                                                                                                        && vm.serverSearchResults.isEmpty && !vm.serverSearchInFlight {
                                                                                                                                        // Searching with zero matches: explicit empty state instead of a
                                                                                                                                        // blank column (which also used to drive runaway pagination).
                                                                                                                                        VStack(spacing: 8) {
                                                                                                                                            Text("nothing found")
                                                                                                                                                .font(ToskaFont.serifItalic(17))
                                                                                                                                                .foregroundColor(.primary)
                                                                                                                                            Text("no posts match your search")
                                                                                                                                                .font(ToskaFont.sans(13))
                                                                                                                                                .foregroundColor(Color.toskaTextLight)
                                                                                                                                        }
                                                                                                                                        .frame(maxWidth: .infinity)
                                                                                                                                        .padding(.top, 70)
                                                                                                                                    }
                                                                                                                                    ForEach(Array(visible.prefix(14))) { post in
                                                                                                                                        feedRow(for: post, prefetchTriggerId: prefetchTriggerId)
                                                                                                                                    }
                                                                                                                                    if visible.count > 14 {
                                                                                                                                        LazyVStack(spacing: 0) {
                                                                                                                                            ForEach(Array(visible.dropFirst(14))) { post in
                                                                                                                                                feedRow(for: post, prefetchTriggerId: prefetchTriggerId)
                                                                                                                                            }
                                                                                                                                        }
                                                                                                                                    }
                                                                                                                                    // Server-wide results — everything the local window
                                                                                                                                    // can't see, fetched on search submit. Locally-shown
                                                                                                                                    // ids are excluded so nothing doubles.
                                                                                                                                    if !searchText.isEmpty {
                                                                                                                                        let localIds = Set(visible.map(\.id))
                                                                                                                                        let fromEverywhere = vm.serverSearchResults.filter { !localIds.contains($0.id) }
                                                                                                                                        if vm.serverSearchInFlight {
                                                                                                                                            HStack(spacing: 8) {
                                                                                                                                                ProgressView().controlSize(.small).tint(ToskaColor.accent)
                                                                                                                                                Text("searching everywhere…")
                                                                                                                                                    .font(ToskaFont.sans(12.5))
                                                                                                                                                    .foregroundColor(ToskaColor.text2)
                                                                                                                                            }
                                                                                                                                            .frame(maxWidth: .infinity)
                                                                                                                                            .padding(.vertical, 18)
                                                                                                                                        } else if !fromEverywhere.isEmpty {
                                                                                                                                            Text("from everywhere")
                                                                                                                                                .font(ToskaFont.sans(10.5, weight: .semibold))
                                                                                                                                                .textCase(.uppercase)
                                                                                                                                                .tracking(0.74)
                                                                                                                                                .foregroundColor(ToskaColor.text2)
                                                                                                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                                                                                                .padding(.horizontal, 28)
                                                                                                                                                .padding(.top, 18)
                                                                                                                                                .padding(.bottom, 4)
                                                                                                                                            LazyVStack(spacing: 0) {
                                                                                                                                                ForEach(fromEverywhere) { post in
                                                                                                                                                    feedRow(for: post, prefetchTriggerId: nil)
                                                                                                                                                }
                                                                                                                                            }
                                                                                                                                        }
                                                                                                                                    }
                                                                                                                                                                                                                                                        } // end else hasLoadedOnce

                                                                                                                                                                                                            if tab == 0 && searchText.isEmpty && vm.hasMorePosts && !vm.posts.isEmpty {
                                            // Visible loading spinner remains as the fallback for
                                            // slow networks where the prefetch (attached to each
                                            // post row 5-from-end via .onAppear) hasn't finished
                                            // by the time the user reaches the bottom.
                                            // searchText.isEmpty gate: a search that matches nothing
                                            // must NOT drive pagination through the whole feed (the
                                            // spinner would .onAppear-loop while showing zero results).
                                            ProgressView()
                                                .tint(Color.toskaBlue)
                                                .padding(.vertical, 20)
                                                .onAppear {
                                                    if !vm.isLoadingMore {
                                                        vm.loadMorePosts()
                                                    }
                                                }
                                        }
                    
                    if tab == 0 && !vm.hasMorePosts && !vm.posts.isEmpty {
                                                                VStack(spacing: 4) {
                                                                    Text("no more posts to show")
                                                                        .font(ToskaFont.sans(10))
                                                                        .foregroundColor(LateNightTheme.tertiaryText)
                                                                    // Only annotate when posts are hidden by blocking.
                                                                    // The neutral end-line stands on its own otherwise —
                                                                    // the old poetic sublines ("close the app. or dont.")
                                                                    // read as awkward at the bottom of a real feed.
                                                                    if vm.endedDueToBlocking {
                                                                        Text("some posts are hidden")
                                                                            .font(ToskaFont.serifItalic(10))
                                                                            .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
                                                                    }
                                                                }
                                                                .padding(.vertical, 20)
                                                            }
                    
                                Color.clear.frame(height: 130)
                                                                                }
                                                                                // No outer .id() on the LazyVStack. A previous version keyed
                                                                                // it on hasLoadedOnce to force a clean rebuild on the
                                                                                // skeleton-to-loaded transition, but inside a ScrollView a
                                                                                // LazyVStack rebuild can leave the view reporting zero
                                                                                // measured height — the posts are in vm.posts and the body
                                                                                // returns the right ForEach branch, but nothing renders
                                                                                // until pull-to-refresh re-triggers layout. Letting
                                                                                // SwiftUI's natural diffing swap the skeleton ForEach for
                                                                                // the posts ForEach keeps the LazyVStack identity stable
                                                                                // and avoids the blank-feed-on-launch regression.
                                                                            }
                                                                            // Pin to the exact viewport width — NOT maxHeight.
                                                                            // maxHeight: .infinity would clamp the content to the
                                                                            // viewport height and kill vertical scrolling (that
                                                                            // bug surfaced once the seeded feed filled past one
                                                                            // screen). Fixing the WIDTH to geo.size.width (rather
                                                                            // than maxWidth: .infinity, which grows to fit an
                                                                            // oversized child) guarantees the content can never be
                                                                            // wider than the screen, so the vertical feed can't be
                                                                            // panned sideways even if a row's media overflows.
                                                                            .frame(width: geo.size.width)
                                                                                .onReceive(NotificationCenter.default.publisher(for: .scrollFeedToTop)) { _ in                                                    withAnimation(.easeInOut(duration: 0.4)) {
                                                        proxy.scrollTo("feedTop", anchor: .top)
                                                    }
                                                }
                // Removed .restoreFeedScroll observer — it was never posted
                // anywhere in the project (orphaned wiring). MainTabView's
                // tab-keep-alive (.opacity trick on each NavigationStack)
                // already preserves scroll position when switching tabs, so
                // an explicit save/restore round-trip isn't needed here.
            } // end ScrollViewReader
                                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                        // Native pull-to-refresh. This replaces a custom
                                                        // simultaneousGesture(DragGesture()) that fired on EVERY
                                                        // downward drag — even mid-feed, not just at the top —
                                                        // setting dragOffset and expanding the refresh header,
                                                        // which shoved content around while scrolling and made
                                                        // the feed feel wonky. .refreshable engages only at the
                                                        // top and lets the scroll view own touch arbitration, so
                                                        // normal scrolling stays seamless. refreshAll() refreshes
                                                        // posts + header content, matching the old behavior.
                                                        .refreshable {
                                                            HapticManager.play(.tabSwitch)
                                                            let start = Date()
                                                            vm.refreshFeed()
                                                            // Hold the native spinner until the posts query actually
                                                            // finishes (tracked by isFetchingPosts) instead of a blind
                                                            // 1.2s timer — that timer left the spinner out of sync with
                                                            // the content reflow, which is what felt glitchy. Bounded by
                                                            // a 0.5s floor (no flash on a cached refresh) and a 5s
                                                            // ceiling (can't hang if a fetch stalls).
                                                            while vm.isFetchingPosts && Date().timeIntervalSince(start) < 5 {
                                                                try? await Task.sleep(nanoseconds: 80_000_000)
                                                            }
                                                            let elapsed = Date().timeIntervalSince(start)
                                                            if elapsed < 0.5 {
                                                                try? await Task.sleep(nanoseconds: UInt64((0.5 - elapsed) * 1_000_000_000))
                                                            }
                                                        }
                                                .frame(width: geo.size.width, height: geo.size.height)
                                                }
        .background(LateNightTheme.feedBackground)
    }
}
