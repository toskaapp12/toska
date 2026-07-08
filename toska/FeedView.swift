import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/*
 MARK: - Required Firestore Composite Indexes
 
 Create these in Firebase Console > Firestore > Indexes > Composite:
 
 Collection "posts":
   - replyCount ASC, createdAt DESC       (fetchWitnessPost)
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
    @State private var takeBreakBannerShown = false
    @State private var takeBreakTask: Task<Void, Never>? = nil
    // "X new posts" Twitter-style banner. Increments when the Firestore
    // listener delivers more posts than were previously in vm.posts.
    // Tapping scrolls to top + clears the badge. Initialized to -1 so the
    // first snapshot (cold-load) doesn't false-trigger the banner against
    // an empty initial state.
    @State private var newPostsBadgeCount = 0
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
                            Text("toska")
                                .toskaScreenTitle()
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
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundColor(ToskaColor.text)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Search")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
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
    // Soft, non-modal. Shows after 15 minutes of continuous time on
    // the feed; tap dismisses. Specific to the mental-health-
    // adjacent brand: heartbreak doomscrolling is real and the
    // wedge is that we don't pretend engagement is universally
    // good. The banner doesn't gate anything — just a gentle ask.
    @ViewBuilder private var takeBreakBanner: some View {
            if takeBreakBannerShown {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        takeBreakBannerShown = false
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
            if newPostsBadgeCount > 0 {
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
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.toskaBlue)
                    .clipShape(Capsule())
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
    }

    // MARK: - Feed tabs (clean underline style)
    // Replaced the heavy full-width segmented pill track with light
    // text tabs + a short underline indicator under the selected one —
    // quieter and more modern, doesn't compete with the cards below.
    @ViewBuilder private var feedTabs: some View {
            // Left-aligned text tabs (2026 mockup): "for you" / "following" grouped
            // at the leading edge with a short underline under the active one — not
            // spread across the full width.
            HStack(spacing: ToskaSpace.xl) {
                ForEach(0..<vm.tabs.count, id: \.self) { index in
                    let isSel = vm.selectedTab == index
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            vm.selectedTab = index
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Text(vm.tabs[index])
                                .font(ToskaFont.sans(16, weight: isSel ? .semibold : .regular))
                                .foregroundColor(isSel ? ToskaColor.text : ToskaColor.text3)
                            Capsule()
                                .fill(isSel ? ToskaColor.accent : Color.clear)
                                .frame(width: 24, height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
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

                    takeBreakBanner

                    newPostsBanner

                    feedTabs

            Rectangle()
                .fill(LateNightTheme.divider)
                .frame(height: 0.5)

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
                                                 // Arm the take-a-break gentle reminder. 15 minutes
                                                 // of session time → soft banner. MainTabView keeps
                                                 // FeedView alive across tab switches via .opacity,
                                                 // so onAppear here only fires on first feed mount
                                                 // (cold launch or post-sign-in) — the timer keeps
                                                 // ticking when the user is on other tabs, which
                                                 // matches the "you've been here a while" intent
                                                 // better than a per-tab-visit reset would. Sign-out
                                                 // tears down MainTabView entirely, firing
                                                 // onDisappear below and cancelling cleanly.
                                                 takeBreakTask?.cancel()
                                                 if !takeBreakBannerShown {
                                                     takeBreakTask = Task { @MainActor in
                                                         try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                                                         guard !Task.isCancelled else { return }
                                                         withAnimation(.easeInOut(duration: 0.3)) {
                                                             takeBreakBannerShown = true
                                                         }
                                                     }
                                                 }
                                             }
                                             .onDisappear {
                                                 takeBreakTask?.cancel()
                                                 takeBreakTask = nil
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
            vm.handleNewPostCreated()
            newPostsBadgeCount = 0
            previousPostCount = -1 // re-baseline on next .onChange tick
            // Only auto-scroll to the top for a freshly COMPOSED post (so they
            // watch it land). A repost must NOT yank the feed to the top — it
            // updates in place and the user keeps their scroll position.
            let isRepost = (notif.userInfo?["isRepost"] as? Bool) ?? false
            if !isRepost {
                NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
            }
        }
        // Drop the cached daily-prompt response card the moment the user
        // deletes that post via PostDetailView. Without this, the response
        // stays on screen with the deleted text until pull-to-refresh.
        // Also strip the deleted post from the in-memory feed so it
        // disappears from the list immediately.
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    vm.handleForegroundReturn()
                }
        .onReceive(NotificationCenter.default.publisher(for: .saveFeedScrollPosition)) { notif in
                            if let postId = notif.userInfo?["postId"] as? String {
                                vm.savedScrollPostId = postId
                            }
                        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                    vm.showExplore = false
                    vm.showWitnessPost = false
                    vm.showPromptCompose = false
                    vm.showDailyMoment = false
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
                promptDate: data["promptDate"] as? String
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
        // The daily prompt this post answered (FeedView passes
        // FeedView.promptText(for: post.promptDate)). When set, the card shows
        // the prompt in plum above the reply, so prompt answers read as
        // "prompt → reply" across the feed.
        var promptText: String? = nil
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
                    PostDetailView(
                        postId: postId,
                        handle: handle,
                        text: text,
                        tag: tag,
                        likes: localLikeCount,
                        reposts: localRepostCount,
                        replies: replies,
                        time: time,
                        authorId: authorId,
                        isAlreadyLiked: isLiked,
                        isAlreadySaved: isSaved,
                        isAlreadyReposted: isReposted,
                        // Pass GIF/letter/whisper so the detail view's first frame
                        // matches the row — no pop-in reflow on open.
                        gifUrl: gifUrl,
                        isLetter: isLetter,
                        isWhisper: isWhisperPost
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
                    .foregroundColor(ToskaColor.accent)
                    .padding(.bottom, 8)
                }
                // Repost provenance — small "@reposter reposted" line above
                // the handle row when this post is a repost. Without this,
                // reposts looked identical to original posts and readers had
                // no way to tell the visible handle was the reposter rather
                // than the original author. Only renders when reposterHandle
                // is set (FeedView passes it for reposts; other call sites
                // pass nil so this row is hidden there).
                if let reposter = reposterHandle, !reposter.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 10, weight: .regular))
                        Text("\(reposter) reposted")
                            .font(ToskaFont.sans(11, weight: .medium))
                    }
                    .foregroundColor(ToskaColor.text3)
                    .padding(.bottom, 8)
                }

                // Handle row — compact: handle is the anchor with the
                // separator dot and time trailing it.
                    HStack(spacing: 4) {
                                            // De-emphasized: a quiet secondary
                                            // gray (not the loud accent) so the
                                            // post TEXT leads the card and the
                                            // random anonymous handle recedes —
                                            // fits the anonymity-first brand.
                                            Text(handle)
                                                .font(ToskaFont.handle)
                                                .foregroundColor(ToskaColor.text2)

                                            Circle()
                                                .fill(ToskaColor.text3)
                                                .frame(width: 2.5, height: 2.5)

                                            Text(time)
                                                .font(ToskaFont.meta)
                                                .foregroundColor(ToskaColor.text3)

                                            Spacer()

                                            if let rank = rank {
                                                Text(String(format: "%02d", rank))
                                                    .font(ToskaFont.serifItalic(13))
                                                    .foregroundColor(ToskaColor.text3)
                                                    .padding(.trailing, 4)
                                            }

                                            if isMidnightPost {
                                                Image(systemName: "moon.fill")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(Color.toskaMidnightPurple.opacity(0.5))
                                            }

                                            if isWhisperPost {
                                                Image(systemName: "eye.slash")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(Color.toskaWhisperPink.opacity(0.5))
                                            }

                                            // Emotion tag on the RIGHT of the header row
                                            // (2026 mockup): a colored dot + the tag name
                                            // in the tag's color. Replaces the filled pill
                                            // that used to sit below the post text. Report
                                            // / block moved to the long-press menu.
                                            if let tag = tag {
                                                HStack(spacing: 4) {
                                                    Circle()
                                                        .fill(tagColor(for: tag))
                                                        .frame(width: 6, height: 6)
                                                    Text(tag)
                                                        .font(ToskaFont.sans(13, weight: .medium))
                                                        .foregroundColor(tagColor(for: tag))
                                                }
                                            }
                                        }
                                        .padding(.bottom, 8)
                
                // Post text
                if !text.isEmpty {
                    if isLetter && !isLetterExpanded {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "envelope.open")
                                    .font(.system(size: 9))
                                Text("letter")
                                    .font(ToskaFont.sans(10, weight: .semibold))
                            }
                            .foregroundColor(Color.toskaAccentGold)
                            
                            Text(text)
                                                            .font(ToskaFont.postBody)
                                                            .foregroundColor(ToskaColor.text)
                                                            .lineSpacing(ToskaLineSpacing.body)
                                                            .lineLimit(3)
                            
                            Button {
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                onLetterExpand?()
                                                            }
                                                        } label: {
                                Text("read this letter...")
                                    .font(ToskaFont.sans(13, weight: .medium))
                                    .foregroundColor(Color.toskaBlue)
                                    .padding(.top, 4)
                            }
                        }
                                                .padding(.bottom, 4)
                                            } else {
                        VStack(alignment: .leading, spacing: 4) {
                            if isLetter {
                                HStack(spacing: 4) {
                                    Image(systemName: "envelope.open")
                                        .font(.system(size: 9))
                                    Text("letter")
                                        .font(ToskaFont.sans(10, weight: .semibold))
                                }
                                .foregroundColor(Color.toskaAccentGold)
                            }
                            
                            Text(text)
                                                            .font(ToskaFont.postBody)
                                                            .foregroundColor(ToskaColor.text)
                                                            // Comfortable journal-like line height — the post
                                                            // text is the focus, so give it room to breathe.
                                                            .lineSpacing(ToskaLineSpacing.body)
                                                            .multilineTextAlignment(.leading)
                        }
                        .padding(.bottom, 8)
                                            }
                                        }
                                        
                                        // Tag now renders as a colored dot + name on the
                                        // RIGHT of the header row (see handle row above) —
                                        // the old filled pill below the text was removed
                                        // to match the 2026 mockup.

                                        // GIF — animated. Uses StableGifPreview
                                        // (shared from ComposeView) so frames
                                        // actually animate via UIImageView; the
                                        // old AsyncImage path only showed the
                                        // first frame because SwiftUI's Image
                                        // doesn't iterate GIF frames.
                if let gifUrl = gifUrl, !gifUrl.isEmpty {
                    StableGifPreview(urlString: gifUrl, maxHeight: 200)
                        .padding(.bottom, 8)
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

                    // Action bar — larger icons + a bit tighter spacing so
                                    // the row feels more substantial without crowding.
                                    if !postId.isEmpty {
                                        // reply/repost/like grouped tight on the left,
                                        // bookmark/share pushed right (2026 mockup) — the
                                        // Even action spacing on the grid; one flexible
                                        // Spacer before bookmark splits the row.
                                        HStack(spacing: ToskaSpace.xl) {
                                            // reply
                                            NavigationLink {
                                                PostDetailView(
                                                    postId: postId,
                                                    handle: handle,
                                                    text: text,
                                                    tag: tag,
                                                    likes: localLikeCount,
                                                    reposts: localRepostCount,
                                                    replies: replies,
                                                    time: time,
                                                    authorId: authorId,
                                                    isAlreadyLiked: isLiked,
                                                    isAlreadySaved: isSaved,
                                                    isAlreadyReposted: isReposted,
                                                    gifUrl: gifUrl,
                                                    isLetter: isLetter,
                                                    isWhisper: isWhisperPost
                                                )
                                                .navigationBarHidden(true)
                                            } label: {
                                                actionLabel(icon: "bubble.left", count: replies, isActive: false)
                                            }
                                            .accessibilityLabel("Reply")
                                            .accessibilityValue(replies == 1 ? "1 reply" : "\(replies) replies")
                                            .buttonStyle(ToskaTapStyle())

                                            // repost
                                            Button { repostPost() } label: {
                                                actionLabel(icon: "arrow.2.squarepath", count: localRepostCount, isActive: isReposted, activeColor: "3E9B72")
                                            }
                                            .accessibilityLabel(isReposted ? "Undo repost" : "Repost")
                                            .accessibilityValue(localRepostCount == 1 ? "1 repost" : "\(localRepostCount) reposts")
                                            .buttonStyle(ToskaTapStyle())
                                            .disabled(isRepostPost)
                                            .opacity(isRepostPost ? 0.3 : 1.0)

                                            // like (with burst overlay — only visible mid-animation;
                                            // allowsHitTesting(false) so taps still hit the button)
                                            Button { toggleLike() } label: {
                                                ZStack {
                                                    actionLabel(icon: isLiked ? "heart.fill" : "heart", count: localLikeCount, isActive: isLiked, activeColor: "C25C7C")
                                                    Image(systemName: "heart.fill")
                                                        .font(.system(size: 15, weight: .regular))
                                                        .foregroundColor(ToskaColor.badge)
                                                        .scaleEffect(likeBurstScale)
                                                        .opacity(likeBurstOpacity)
                                                        .allowsHitTesting(false)
                                                        .alignmentGuide(.leading) { $0[.leading] }
                                                }
                                            }
                                            .accessibilityLabel(isLiked ? "Unlike post" : "Like post")
                                            .accessibilityValue(localLikeCount == 1 ? "1 person felt this" : "\(localLikeCount) people felt this")
                                            .buttonStyle(ToskaTapStyle())
                                            .scaleEffect(likePulse ? 1.15 : 1.0)
                                            .animation(reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.3, dampingFraction: 0.5), value: likePulse)

                                            // Flexible gap — pushes bookmark + share to
                                            // the trailing edge.
                                            Spacer(minLength: 16)

                                            // bookmark
                                            Button { toggleSave() } label: {
                                                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                                    .font(.system(size: 15, weight: .regular))
                                                    .foregroundColor(isSaved ? ToskaColor.accent : ToskaColor.text3)
                                            }
                                            .accessibilityLabel(isSaved ? "Unsave post" : "Save post")
                                            .buttonStyle(ToskaTapStyle())

                                            // share — hidden for letters & whispers
                                            // (those are private/ephemeral and not
                                            // shareable) and when the author disabled
                                            // sharing.
                                            if isShareable && !isLetter && !isWhisperPost {
                                                Button { showShareCard = true } label: {
                                                    Image(systemName: "square.and.arrow.up")
                                                        .font(.system(size: 15, weight: .regular))
                                                        .foregroundColor(ToskaColor.text3)
                                                }
                                                .accessibilityLabel("Share post")
                                                .buttonStyle(ToskaTapStyle())
                                            } else {
                                                Color.clear.frame(width: 18, height: 1)
                                            }
                                        }
                                        // reply/repost/heart on the left, bookmark/share
                                        // pushed to the trailing edge (2026 mockup).
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, ToskaSpace.sm)
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
                                            // Content-first timeline (2026 redesign): posts
                                            // sit DIRECTLY on the page background — no card
                                            // surface, border, or shadow — separated only by
                                            // air and an almost-invisible hairline, so the
                                            // feed reads as one continuous stream of thoughts
                                            // (X-style), not a stack of floating cards. The
                                            // press highlight still lives in FeedRowPressStyle
                                            // on the content link.
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 16)
                                            .contentShape(Rectangle())
                                            .overlay(alignment: .bottom) {
                                                Rectangle()
                                                    .fill(ToskaColor.divider.opacity(0.5))
                                                    .frame(height: 0.5)
                                            }
                .contextMenu {
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

                    if !isRepostPost {
                        Button {
                            repostPost()
                        } label: {
                            Label(isReposted ? "undo repost" : "repost", systemImage: isReposted ? "arrow.2.squarepath.circle" : "arrow.2.squarepath")
                        }
                    }

                    if isShareable && !isLetter && !isWhisperPost {
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
                    if !postId.isEmpty { isSaved = newValue }
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
                        ShareCardView(text: text, handle: handle, feltCount: localLikeCount, tag: tag)
                            .navigationBarHidden(true)
                    }
                }
                .fullScreenCover(isPresented: $showReportSheet) {
                    EdgeSwipeDismissWrapper {
                        NavigationStack {
                            ReportSheet(target: .post(
                                postId: postId,
                                authorId: authorId,
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
                                        BlockedUsersCache.shared.block(authorId, handle: handle)
                                    }
                                    Button("cancel", role: .cancel) {}
                                } message: {
                                    Text("you wont see their posts or replies. they wont be notified.")
                                }
    }
    
    // MARK: - Action Label

    func actionLabel(icon: String, count: Int, isActive: Bool, activeColor: String = "828AA0") -> some View {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(isActive ? Color(hex: activeColor) : ToskaColor.text3)
                if count > 0 {
                    Text(formatCount(count))
                        .font(ToskaFont.actionCount)
                        .foregroundColor(ToskaColor.text2)
                }
            }
        }
    
    // MARK: - Like
        
        func toggleLike() {
            // N-7: arm the suppression window at tap time, re-arm on completion
            // (mirrors PostDetailView.toggleLike) so a feed refresh can't snap
            // the optimistic count back mid-round-trip.
            suppressLikeListenerUntil = Date().addingTimeInterval(2.0)
            PostInteractionManager.toggleLike(
                postId: postId,
                authorId: authorId,
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
            // Can't repost a repost itself.
            guard !isRepostPost else { return }
            // C-3: arm the suppression window so the feed listener echo doesn't
            // clobber the optimistic count (mirrors toggleLike).
            suppressRepostListenerUntil = Date().addingTimeInterval(2.0)

            // Toggle: if already reposted, UNDO it (delete the repost doc).
            if isReposted {
                PostInteractionManager.unrepost(
                    postId: postId,
                    currentCount: localRepostCount
                ) { result in
                    isReposted = result.isReposted
                    localRepostCount = result.newCount
                    suppressRepostListenerUntil = Date().addingTimeInterval(1.5)
                }
                return
            }

            PostInteractionManager.repost(
                postId: postId,
                postText: text,
                postTag: tag,
                authorId: authorId,
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
                // Don't fire the confirm haptic when offline — the manager
                // silently no-ops there, so the haptic was a false "saved" signal.
                guard NetworkMonitor.shared.isConnected else { return }
                HapticManager.play(.feltThis)
                PostInteractionManager.toggleSave(
                    postId: postId,
                    authorId: authorId,
                    currentlySaved: isSaved
                ) { newSaved in
                    isSaved = newSaved
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

    var body: some View {
        VStack(spacing: 0) {
                // Lavender prompt card (2026 mockup): "✦ TODAY'S PROMPT" eyebrow,
                // serif-italic prompt, and a purple "respond" pill. Soft plum-tinted
                // fill, rounded — the daily prompt is the app's hook, so it reads as
                // a distinct accent card rather than plain text on the page.
                VStack(alignment: .leading, spacing: ToskaSpace.md) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("today's prompt")
                            .font(ToskaFont.sans(11, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(1.3)
                    }
                    .foregroundColor(ToskaColor.accent)

                    Text(vm.todaysPrompt.0)
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(ToskaColor.text)
                        .lineSpacing(ToskaLineSpacing.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if vm.todaysPromptResponse == nil {
                        Button {
                            vm.showPromptCompose = true
                            HapticManager.play(.compose)
                        } label: {
                            Text("respond")
                                .font(ToskaFont.button())
                                .foregroundColor(.white)
                                .padding(.horizontal, ToskaSpace.xl)
                                .padding(.vertical, ToskaSpace.sm)
                                .background(ToskaColor.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, ToskaSpace.xxs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ToskaSpace.lg)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(ToskaColor.accent.opacity(LateNightTheme.isLateNight ? 0.16 : 0.10))
                )
                .padding(.horizontal, ToskaSpace.md)
                .padding(.top, ToskaSpace.md)
                .padding(.bottom, 8)

                // ALWAYS-visible "your response" card (not gated by isExpanded).
                // When the user has responded today, this sits right under the
                // prompt header in the collapsed state so it's immediately
                // visible. Tap pushes PostDetailView (where the existing ⋯
                // menu surfaces edit/delete on own posts).
                if let response = vm.todaysPromptResponse {
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
                            authorId: response.authorId,
                            isAlreadyLiked: false,
                            isAlreadySaved: false,
                            isAlreadyReposted: false
                        )
                        .navigationBarHidden(true)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                                Text("your response")
                                    .font(ToskaFont.sans(10, weight: .semibold))
                                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                                Spacer()
                                Text("tap to open")
                                    .font(ToskaFont.sans(9))
                                    .foregroundColor(Color.toskaTimestamp)
                            }
                            Text(response.text)
                                .font(ToskaFont.serif(14))
                                .foregroundColor(ToskaColor.text)
                                .lineSpacing(3)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.toskaBlue.opacity(0.06))
                        .cornerRadius(10)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
    TagItem(name: "longing", colorHex: "6E7BA0", icon: "moon.stars"),
    TagItem(name: "numb", colorHex: "7C8A93", icon: "circle.dotted"),
    TagItem(name: "anger", colorHex: "BC554F", icon: "flame"),
    TagItem(name: "regret", colorHex: "7E6FC0", icon: "arrow.uturn.backward"),
    TagItem(name: "acceptance", colorHex: "4E9B82", icon: "leaf"),
    TagItem(name: "confusion", colorHex: "BE8E50", icon: "questionmark.circle"),
    TagItem(name: "unsent", colorHex: "6B8AAE", icon: "envelope"),
    TagItem(name: "moving on", colorHex: "4E9B88", icon: "arrow.right.circle"),
    TagItem(name: "still love you", colorHex: "C56F82", icon: "heart"),
]

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
    // 2026 de-plain pass: the emotion colors were so desaturated (and rendered
    // at 16% opacity) that every tag washed out to the same gray — the feed read
    // as colorless. These are modestly deepened so each emotion reads as a real,
    // distinct hue while staying dusty/editorial, not neon. "numb" was missing
    // from the palette entirely (fell back to gray); it now has its own cool
    // slate. Kept in sync with sharedTags below.
    // Mood color language (2026 design spec).
    switch tag {
    case "longing": return Color(hex: "5E50A6")      // violet
    case "rebuilding": return Color(hex: "3E7E5C")   // green
    case "acceptance": return Color(hex: "3F6796")   // blue
    case "lonely": return Color(hex: "5A6478")       // slate
    case "numb": return Color(hex: "6F6B7B")         // neutral grey-violet
    case "anger": return Color(hex: "BC554F")
    case "regret": return Color(hex: "7E6FC0")
    case "confusion": return Color(hex: "BE8E50")
    case "unsent": return Color(hex: "6B8AAE")
    case "moving on": return Color(hex: "3E7E5C")
    case "still love you": return Color(hex: "C56F82")
    default: return Color(hex: "6F6B7B")
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
                                                                                                                                                        handle: post.originalHandle ?? post.handle,
                                                                                                                                                        text: post.text,
                                                                                                                                                        tag: post.tag,
                                                                                                                                                        likes: post.likes,
                                                                                                                                                        reposts: post.reposts,
                                                                                                                                                        replies: post.replies,
                                                                                                                                                        time: post.time,
                                                                                                                                                        postId: post.id,
                                                                                                                                                        authorId: post.authorId,
                                                                                                                                                        isAlreadyReposted: vm.repostedPostIds.contains(post.id),
                                                                                                                                                        isAlreadyLiked: vm.likedPostIds.contains(post.id),
                                                                                                                                                        isAlreadySaved: vm.savedPostIds.contains(post.id),
                                                                                                                                                        isShareable: post.isShareable,
                                                                                                                                                        gifUrl: vm.postGifUrls[post.id],
                                                                                                                                                        isMidnightPost: vm.midnightPostIds.contains(post.id),
                                                                                                                                                        isLetter: vm.letterPostIds.contains(post.id),
                                                                                                                                                        isRepostPost: vm.repostPostIds.contains(post.id),
                                                                                                                                                        isWhisperPost: vm.whisperPostIds.contains(post.id),
                                                                                                                                                        isLetterExpanded: vm.expandedLetterIds.contains(post.id),
                                                                                                                                                        onLetterExpand: { vm.expandedLetterIds.insert(post.id) },
                                                                                                                                                        reposterHandle: post.originalHandle != nil ? post.handle : nil,
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
                                                            Text("\"the things we don't\nsay out loud still\nneed somewhere to go.\"")
                                                                .font(ToskaFont.serifItalic(20))
                                                                .foregroundColor(LateNightTheme.tertiaryText)
                                                                .multilineTextAlignment(.center)
                                                                .lineSpacing(4)
                                                            Text("follow someone to see their words here")
                                                                .font(ToskaFont.sans(11))
                                                                .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
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
                                        Text("\"its quiet right now.\"")
                                            .font(ToskaFont.serifItalic(18))
                                            .foregroundColor(LateNightTheme.secondaryText)
                                            .multilineTextAlignment(.center)
                                        Text("be the first one to say what you couldnt say to them.\nor go find someone who already did.")
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
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(Color.toskaBlue)
                                                .cornerRadius(10)
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
                                                .foregroundColor(Color.toskaBlue)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(Color.toskaBlue.opacity(0.1))
                                                .cornerRadius(10)
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
                                                                                                                                    if !searchText.isEmpty && visible.isEmpty {
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
