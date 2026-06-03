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
    @FocusState private var searchFocused: Bool

    /// True when post matches the current search query (or no query is set).
    /// Case-insensitive substring on handle, text, and tag.
    private func matchesSearch(_ post: FeedPost) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return post.handle.lowercased().contains(q)
            || post.text.lowercased().contains(q)
            || (post.tag?.lowercased().contains(q) ?? false)
    }

    var body: some View {
            VStack(spacing: 0) {
                    // MARK: - Header
                    //
                    // Just the wordmark. The search affordance lives below the
                    // prompt card now (see InlineSearchBar after FeedHeaderCard
                    // in the scroll content), so there's no need for a header
                    // search button. ExploreView is still reachable from the
                    // empty-feed state ("explore" button) for the rare case
                    // where someone has no posts in the window AND wants the
                    // tag chips / trending / "feeling people" experience.
            HStack {
                            Text("toska")
                                .toskaScreenTitle()
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

            // MARK: - Take-a-break banner
            //
            // Soft, non-modal. Shows after 15 minutes of continuous time on
            // the feed; tap dismisses. Specific to the mental-health-
            // adjacent brand: heartbreak doomscrolling is real and the
            // wedge is that we don't pretend engagement is universally
            // good. The banner doesn't gate anything — just a gentle ask.
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
                            .foregroundColor(Color(hex: "6ba58e"))
                        Text("you've been here a while. take a breath if you need.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Color.toskaTextDark)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.toskaDivider)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(hex: "6ba58e").opacity(0.08))
                    .cornerRadius(10)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // MARK: - New posts available banner
            //
            // Twitter-style affordance — when the snapshot listener delivers
            // new posts while the user is on the feed, surface a small pill
            // that scrolls to top + clears on tap. Hidden when count is 0.
            if newPostsBadgeCount > 0 {
                Button {
                    NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        newPostsBadgeCount = 0
                    }
                    HapticManager.play(.tabSwitch)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                        Text(newPostsBadgeCount == 1
                             ? "1 new post · tap to see"
                             : "\(newPostsBadgeCount) new posts · tap to see")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.toskaBlue)
                    .clipShape(Capsule())
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // MARK: - Tab bar (full-width segmented control)
            HStack(spacing: 3) {
                ForEach(0..<vm.tabs.count, id: \.self) { index in
                    let isSel = vm.selectedTab == index
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.selectedTab = index
                        }
                    } label: {
                        Text(vm.tabs[index])
                            .font(.system(size: 14, weight: isSel ? .semibold : .medium))
                            .foregroundColor(isSel ? ToskaColor.text : ToskaColor.text2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSel ? ToskaColor.card : Color.clear)
                                    .shadow(color: isSel ? Color.black.opacity(0.08) : Color.clear, radius: 3, x: 0, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(ToskaColor.input)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            
            Rectangle()
                .fill(LateNightTheme.divider)
                .frame(height: 0.5)
            
                GeometryReader { geo in
                            ScrollViewReader { proxy in
                                ScrollView(showsIndicators: false) {
                            // VStack, not LazyVStack. LazyVStack inside this
                            // ScrollView produces a blank feed on cold launch:
                            // posts arrive in vm.posts and the body recomputes
                            // into the loaded ForEach branch, but the LazyVStack
                            // reports near-zero measured height and never
                            // materialises the rows until pull-to-refresh
                            // re-triggers layout. The earlier perf concern
                            // (eager render of 60+ posts firing the 5-from-end
                            // prefetch immediately) is acceptable in exchange
                            // for the feed actually appearing on launch — the
                            // user-visible bug here is far worse than the
                            // wasted prefetch.
                                    VStack(spacing: 0) {
                                                                                Color.clear.frame(height: 0).id("feedTop")
                                ToskaRefreshHeader(
                                                                                                    isRefreshing: vm.isRefreshing,
                                                                                                    triggerProgress: CGFloat(min(Double(vm.dragOffset) / 80.0, 1.0))
                                                                                                )
                                                                                                .frame(height: vm.isRefreshing ? 60 : max(0, CGFloat(vm.dragOffset) - 10))
                                                                                                .clipped()
                                            if let error = vm.fetchError {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "exclamationmark.circle")
                                                        .font(.system(size: 10))
                                                    Text(error)
                                                        .font(.system(size: 11))
                                                    Spacer()
                                                    Button {
                                                        vm.fetchError = nil
                                                        vm.fetchPosts()
                                                    } label: {
                                                        Text("retry")
                                                            .font(.system(size: 11, weight: .semibold))
                                                    }
                                                }
                                                .foregroundColor(Color(hex: "c45c5c"))
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .frame(maxWidth: .infinity)
                                                .background(Color(hex: "c45c5c").opacity(0.06))
                                            }
                                // MARK: - Collapsed feed header
                                // Hidden while searching (focused or query present)
                                // so the search + filter chips take over the top.
                                                    if vm.selectedTab == 0 && !(searchFocused || !searchText.isEmpty) {
                                                        FeedHeaderCard(vm: vm)
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
                                HStack(spacing: 10) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 17, weight: .regular))
                                            .foregroundColor(ToskaColor.text2)
                                        TextField("search", text: $searchText)
                                            .font(.system(size: 14))
                                            .foregroundColor(ToskaColor.handle)
                                            .autocorrectionDisabled()
                                            .textInputAutocapitalization(.never)
                                            .focused($searchFocused)
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
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(ToskaColor.input)
                                    .overlay(
                                        Capsule().stroke(ToskaColor.divider, lineWidth: 1)
                                    )
                                    .clipShape(Capsule())

                                    // Cancel — appears while searching; clears the
                                    // query and drops focus, returning to the feed.
                                    if searchFocused || !searchText.isEmpty {
                                        Button {
                                            searchText = ""
                                            searchFocused = false
                                        } label: {
                                            Text("cancel")
                                                .font(.system(size: 15))
                                                .foregroundColor(ToskaColor.accent)
                                        }
                                        .transition(.opacity)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 6)

                                // Category pills — appear only while the
                                // search bar is focused. Tapping a pill
                                // fills searchText with the tag name (which
                                // triggers matchesSearch to filter posts on
                                // post.tag), dismisses the keyboard, and
                                // returns the user to the filtered feed.
                                // Hidden as soon as focus leaves the search
                                // bar so the chrome doesn't compete with the
                                // feed in the resting state.
                                if searchFocused || !searchText.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            // "all" — clears the tag filter. Selected
                                            // (dark pill) when no tag query is active.
                                            let allSelected = searchText.isEmpty
                                            Button {
                                                searchText = ""
                                            } label: {
                                                Text("all")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(allSelected ? ToskaColor.bg : ToskaColor.text2)
                                                    .padding(.horizontal, 13)
                                                    .padding(.vertical, 5)
                                                    .background(allSelected ? ToskaColor.handle : Color.clear)
                                                    .overlay(Capsule().stroke(allSelected ? Color.clear : ToskaColor.divider, lineWidth: 1))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)

                                            ForEach(sharedTags, id: \.name) { tag in
                                                let isSel = searchText == tag.name
                                                Button {
                                                    searchText = tag.name
                                                    searchFocused = false
                                                } label: {
                                                    HStack(spacing: 5) {
                                                        Image(systemName: tag.icon)
                                                            .font(.system(size: 11))
                                                        Text(tag.name)
                                                            .font(.system(size: 13, weight: .medium))
                                                    }
                                                    .foregroundColor(isSel ? Color(hex: "FFFFFF") : Color(hex: tag.colorHex))
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 7)
                                                    .background(isSel ? Color(hex: tag.colorHex) : Color(hex: tag.colorHex).opacity(0.12))
                                                    .clipShape(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                    .padding(.top, 10)
                                    .padding(.bottom, 12)
                                    .transition(.opacity)
                                }

                                if vm.selectedTab == 1 && vm.followingPosts.isEmpty {
                                                        VStack(spacing: 12) {
                                                            Text("\"the things we don't\nsay out loud still\nneed somewhere to go.\"")
                                                                .font(ToskaFont.serifItalic(20))
                                                                .foregroundColor(LateNightTheme.tertiaryText)
                                                                .multilineTextAlignment(.center)
                                                                .lineSpacing(4)
                                                            Text("follow someone to see their words here")
                                                                .font(.system(size: 11))
                                                                .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
                                                        }
                                                        .frame(maxWidth: .infinity)
                                                        .padding(.vertical, 60)
                                                    }
                                        
                                        if vm.selectedTab == 1 && vm.followingFetchIncomplete {
                                            HStack(spacing: 6) {
                                                Image(systemName: "exclamationmark.circle")
                                                    .font(.system(size: 10))
                                                Text("some posts may be missing — pull to refresh")
                                                    .font(.system(size: 11))
                                            }
                                            .foregroundColor(Color(hex: "c49a6c"))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity)
                                            .background(Color(hex: "c49a6c").opacity(0.06))
                                        }
                    
                    
                                if vm.currentPosts.isEmpty && !vm.hasLoadedOnce {
                                                                    #if DEBUG
                                                                    let _ = print("🎨 BODY — branch: SKELETONS (posts.isEmpty, !hasLoadedOnce)")
                                                                    #endif
                                                                    ForEach(0..<6, id: \.self) { _ in
                                                                        SkeletonPostRow()
                                                                            .background(LateNightTheme.background)
                                                                    }
                                                                } else if vm.currentPosts.isEmpty && vm.hasLoadedOnce && vm.selectedTab == 0 {
                                                                    #if DEBUG
                                                                    let _ = print("🎨 BODY — branch: EMPTY STATE (posts.isEmpty, hasLoadedOnce, tab 0)")
                                                                    #endif
                                    // First-run empty state. The fetch finished
                                    // and there's genuinely nothing to show
                                    // (no posts in window, none from people
                                    // they follow). Coach concrete actions
                                    // instead of leaving a blank screen.
                                    VStack(spacing: 14) {
                                        Image(systemName: "moon.stars")
                                            .font(.system(size: 28, weight: .light))
                                            .foregroundColor(LateNightTheme.tertiaryText)
                                        Text("\"its quiet right now.\"")
                                            .font(.custom("Georgia-Italic", size: 18))
                                            .foregroundColor(LateNightTheme.secondaryText)
                                            .multilineTextAlignment(.center)
                                        Text("be the first one to say what you couldnt say to them.\nor go find someone who already did.")
                                            .font(.system(size: 12))
                                            .foregroundColor(LateNightTheme.tertiaryText)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(3)
                                            .padding(.horizontal, 24)
                                        HStack(spacing: 10) {
                                            Button {
                                                NotificationCenter.default.post(name: .openComposeFromEmptyFeed, object: nil)
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "plus.circle")
                                                        .font(.system(size: 11))
                                                    Text("say something")
                                                        .font(.system(size: 12, weight: .medium))
                                                }
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 10)
                                                .background(Color.toskaBlue)
                                                .cornerRadius(10)
                                            }
                                            Button {
                                                vm.showExplore = true
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "magnifyingglass")
                                                        .font(.system(size: 11))
                                                    Text("explore")
                                                        .font(.system(size: 12, weight: .medium))
                                                }
                                                .foregroundColor(Color.toskaBlue)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 10)
                                                .background(Color.toskaBlue.opacity(0.1))
                                                .cornerRadius(10)
                                            }
                                        }
                                        .padding(.top, 4)
                                        Text("pull down to refresh")
                                            .font(.system(size: 9))
                                            .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
                                            .padding(.top, 8)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                                    .padding(.bottom, 40)
                                                                } else {
                                                                                                                                    ForEach(vm.currentPosts.filter(matchesSearch)) { post in
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
                                                                                                                                                reposterHandle: post.originalHandle != nil ? post.handle : nil
                                                                                                                                                                                                                                                                                            )
                                                                                                                                                                                                                                                                                            .id(post.id)
                                                                                                                                                                                                                                                                                            .onAppear {
                                                                                                                                                                                                                                                                                                // Prefetch the next page when this row is
                                                                                                                                                                                                                                                                                                // ~5 posts from the end. By the time the
                                                                                                                                                                                                                                                                                                // user reaches the bottom, the next page
                                                                                                                                                                                                                                                                                                // is usually already loaded — no visible
                                                                                                                                                                                                                                                                                                // spinner, smoother feed.
                                                                                                                                                                                                                                                                                                guard vm.selectedTab == 0,
                                                                                                                                                                                                                                                                                                      vm.hasMorePosts,
                                                                                                                                                                                                                                                                                                      !vm.isLoadingMore,
                                                                                                                                                                                                                                                                                                      vm.posts.count >= 5,
                                                                                                                                                                                                                                                                                                      post.id == vm.posts[vm.posts.count - 5].id else { return }
                                                                                                                                                                                                                                                                                                vm.loadMorePosts()
                                                                                                                                                                                                                                                                                            }
                                                                                                                                                                                                                                                                                        }
                                                                                                                                                                                                                                                                                    }
                                                                                                                                                                                                                                                        } // end else hasLoadedOnce

                                                                                                                                                                                                            if vm.selectedTab == 0 && vm.hasMorePosts && !vm.posts.isEmpty {
                                            // Visible loading spinner remains as the fallback for
                                            // slow networks where the prefetch (attached to each
                                            // post row 5-from-end via .onAppear) hasn't finished
                                            // by the time the user reaches the bottom.
                                            ProgressView()
                                                .tint(Color.toskaBlue)
                                                .padding(.vertical, 20)
                                                .onAppear {
                                                    if !vm.isLoadingMore {
                                                        vm.loadMorePosts()
                                                    }
                                                }
                                        }
                    
                    if vm.selectedTab == 0 && !vm.hasMorePosts && !vm.posts.isEmpty {
                                                                VStack(spacing: 4) {
                                                                    Text("no more posts to show")
                                                                        .font(.system(size: 10))
                                                                        .foregroundColor(LateNightTheme.tertiaryText)
                                                                    // Only annotate when posts are hidden by blocking.
                                                                    // The neutral end-line stands on its own otherwise —
                                                                    // the old poetic sublines ("close the app. or dont.")
                                                                    // read as awkward at the bottom of a real feed.
                                                                    if vm.endedDueToBlocking {
                                                                        Text("some posts are hidden")
                                                                            .font(.custom("Georgia-Italic", size: 10))
                                                                            .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
                                                                    }
                                                                }
                                                                .padding(.vertical, 20)
                                                            }
                    
                                Color.clear.frame(height: 80)
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
                                                            vm.refreshAll()
                                                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                                                        }
                                                .frame(width: geo.size.width, height: geo.size.height)
                                                }
                                            }
                                            .background(LateNightTheme.background)
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
        .fullScreenCover(isPresented: $vm.showDailyMoment) {
                    EdgeSwipeDismissWrapper {
                        DailyMomentView()
                            .onAppear { HapticManager.play(.postAppear) }
                    }
                }
        .navigationDestination(isPresented: $vm.showWitnessPost) {
                    if let witness = vm.witnessPost {
                        PostDetailView(
                            postId: witness.postId,
                            handle: witness.handle,
                            text: witness.text,
                            tag: witness.tag,
                            likes: witness.likeCount,
                            reposts: witness.repostCount,
                            replies: 0,
                            time: witness.timeString
                        )
                        .navigationBarHidden(true)
                    }
                }
        .onReceive(NotificationCenter.default.publisher(for: .newPostCreated)) { _ in
            vm.handleNewPostCreated()
            // The local user just created a post — auto-scroll to top so
            // they see it land, and resync the new-posts baseline so the
            // banner doesn't pop "1 new post" referring to their own
            // freshly-published content.
            NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
            newPostsBadgeCount = 0
            previousPostCount = -1 // re-baseline on next .onChange tick
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
            vm.posts.removeAll { $0.id == deletedId }
            vm.followingPosts.removeAll { $0.id == deletedId }
        }
        .onChange(of: vm.posts.count) { _, newValue in
            // "X new posts available" delta tracking. previousPostCount
            // initializes to -1 so the first snapshot (cold-load) doesn't
            // false-trigger the banner against an empty starting state.
            // Subsequent positive deltas (listener delivers new docs)
            // increment the badge; the user dismisses with a tap.
            if previousPostCount == -1 {
                previousPostCount = newValue
            } else if newValue > previousPostCount {
                withAnimation(.easeInOut(duration: 0.25)) {
                    newPostsBadgeCount += (newValue - previousPostCount)
                }
                previousPostCount = newValue
            } else if newValue < previousPostCount {
                // List shrunk (block + filter, refresh, etc.) — re-sync
                // baseline without bumping the badge.
                previousPostCount = newValue
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
                originalHandle: data["originalHandle"] as? String
            )
        }
    
    // MARK: - Helpers
    
    static func timeAgoString(from date: Date) -> String {
            ToskaFormatters.timeAgo(from: date)
        }
}

// MARK: - Feed Post Row

@MainActor
struct FeedPostRow: View {
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
                        isAlreadyReposted: isReposted
                    )
                    .navigationBarHidden(true)
                } label: {
                  VStack(alignment: .leading, spacing: 0) {
                // Repost provenance — small "@reposter reposted" line above
                // the handle row when this post is a repost. Without this,
                // reposts looked identical to original posts and readers had
                // no way to tell the visible handle was the reposter rather
                // than the original author. Only renders when reposterHandle
                // is set (FeedView passes it for reposts; other call sites
                // pass nil so this row is hidden there).
                if let reposter = reposterHandle, !reposter.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 10, weight: .regular))
                        Text("\(reposter) reposted")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(ToskaColor.text3)
                    .padding(.bottom, 6)
                }

                // Handle row — Threads-ish: bigger handle for stronger
                // visual anchor, slightly bigger time for legibility, the
                // separator dot and ellipsis bumped to match.
                    HStack(spacing: 6) {
                                            Text(handle)
                                                .font(ToskaFont.handle)
                                                .foregroundColor(ToskaColor.accent)

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
                                                    .padding(.trailing, 2)
                                            }

                                            if isMidnightPost {
                                                Image(systemName: "moon.fill")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(Color(hex: "8b7ec8").opacity(0.5))
                                            }

                                            if isWhisperPost {
                                                Image(systemName: "eye.slash")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(Color(hex: "c47a8a").opacity(0.5))
                                            }

                                            // Report/block menu. Hidden on the user's
                                            // own posts and on posts where we don't
                                            // have an authorId (repost/legacy docs).
                                            if !authorId.isEmpty, authorId != Auth.auth().currentUser?.uid {
                                                Menu {
                                                    Button {
                                                        showReportSheet = true
                                                    } label: {
                                                        Label("report", systemImage: "flag")
                                                    }
                                                    Button(role: .destructive) {
                                                        showBlockConfirm = true
                                                    } label: {
                                                        Label("block \(handle)", systemImage: "person.slash")
                                                    }
                                                } label: {
                                                    Image(systemName: "ellipsis")
                                                        .font(.system(size: 13))
                                                        .foregroundColor(ToskaColor.text3)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 4)
                                                        .contentShape(Rectangle())
                                                }
                                                .accessibilityLabel("More options for \(handle)'s post")
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
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(Color(hex: "c9a97a"))
                            
                            Text(text)
                                                            .font(ToskaFont.postBody)
                                                            .foregroundColor(ToskaColor.text)
                                                            .lineSpacing(4)
                                                            .lineLimit(3)
                            
                            Button {
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                onLetterExpand?()
                                                            }
                                                        } label: {
                                Text("read this letter...")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color.toskaBlue)
                                    .padding(.top, 2)
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
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(Color(hex: "c9a97a"))
                            }
                            
                            Text(text)
                                                            .font(ToskaFont.postBody)
                                                            .foregroundColor(ToskaColor.text)
                                                            .lineSpacing(4)
                                                            .multilineTextAlignment(.leading)
                        }
                        .padding(.bottom, 8)
                                            }
                                        }
                                        
                                        // Tag pill — slightly bigger so it
                                        // reads as a real chip, not a footnote.
                                        // Now includes the tag's SF Symbol
                                        // alongside the name (icon defined in
                                        // sharedTags); matches how Compose and
                                        // Explore render the same chips so the
                                        // visual vocabulary is consistent.
                                        if let tag = tag {
                                            HStack(spacing: 4) {
                                                Image(systemName: ToskaEmotion.icon(tag))
                                                    .font(.system(size: 10, weight: .medium))
                                                Text(tag)
                                                    .font(.system(size: 11, weight: .semibold))
                                            }
                                            .foregroundColor(tagColor(for: tag))
                                            .padding(.vertical, 4)
                                            .padding(.leading, 8)
                                            .padding(.trailing, 10)
                                            .background(tagColor(for: tag).opacity(0.13))
                                            .clipShape(Capsule())
                                            .padding(.bottom, 10)
                                        }
                                        
                                        // GIF — animated. Uses StableGifPreview
                                        // (shared from ComposeView) so frames
                                        // actually animate via UIImageView; the
                                        // old AsyncImage path only showed the
                                        // first frame because SwiftUI's Image
                                        // doesn't iterate GIF frames.
                if let gifUrl = gifUrl, !gifUrl.isEmpty {
                    StableGifPreview(urlString: gifUrl, maxHeight: 200)
                        .padding(.bottom, 10)
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
                                        HStack(spacing: 0) {
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
                                                    isAlreadyReposted: isReposted
                                                )
                                                .navigationBarHidden(true)
                                            } label: {
                                                actionLabel(icon: "bubble.left", count: replies, isActive: false)
                                            }
                                            .accessibilityLabel("Reply")
                                            .accessibilityValue(replies == 1 ? "1 reply" : "\(replies) replies")
                                            .buttonStyle(.plain)

                                            Spacer(minLength: 8)

                                            // repost
                                            Button { repostPost() } label: {
                                                actionLabel(icon: "arrow.2.squarepath", count: localRepostCount, isActive: isReposted, activeColor: "5a9e8f")
                                            }
                                            .accessibilityLabel(isReposted ? "Already reposted" : "Repost")
                                            .accessibilityValue(localRepostCount == 1 ? "1 repost" : "\(localRepostCount) reposts")
                                            .buttonStyle(.plain)
                                            .disabled(isRepostPost)
                                            .opacity(isRepostPost ? 0.3 : 1.0)

                                            Spacer(minLength: 8)

                                            // like (with burst overlay — only visible mid-animation;
                                            // allowsHitTesting(false) so taps still hit the button)
                                            Button { toggleLike() } label: {
                                                ZStack {
                                                    actionLabel(icon: isLiked ? "heart.fill" : "heart", count: localLikeCount, isActive: isLiked, activeColor: "c47a8a")
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
                                            .buttonStyle(.plain)
                                            .scaleEffect(likePulse ? 1.15 : 1.0)
                                            .animation(reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.3, dampingFraction: 0.5), value: likePulse)

                                            Spacer(minLength: 8)

                                            // bookmark
                                            Button { toggleSave() } label: {
                                                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                                    .font(.system(size: 15, weight: .regular))
                                                    .foregroundColor(isSaved ? ToskaColor.accent : ToskaColor.text3)
                                            }
                                            .accessibilityLabel(isSaved ? "Unsave post" : "Save post")
                                            .buttonStyle(.plain)

                                            Spacer(minLength: 8)

                                            // share (keep the slot balanced when hidden)
                                            if isShareable {
                                                Button { showShareCard = true } label: {
                                                    Image(systemName: "square.and.arrow.up")
                                                        .font(.system(size: 15, weight: .regular))
                                                        .foregroundColor(ToskaColor.text3)
                                                }
                                                .accessibilityLabel("Share post")
                                                .buttonStyle(.plain)
                                            } else {
                                                Color.clear.frame(width: 18, height: 1)
                                            }
                                        }
                                        // Evenly-spaced row, left-aligned, capped width so the
                                        // icons sit in a tidy band (not stretched edge-to-edge).
                                        .frame(maxWidth: 278, alignment: .leading)
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
                                            // Card interior padding (16 × 17). The press
                                            // highlight lives in FeedRowPressStyle on the
                                            // content link; no manual press gesture here.
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 14)
                                            .contentShape(Rectangle())
                                            // Editorial card: card bg, radius 18, 1px
                                            // hairline border + subtle lift (replaces the
                                            // old full-width row + bottom divider).
                                            .toskaCard()
                                            .padding(.horizontal, 16)
                                            .padding(.bottom, 10)
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
                            Label(isReposted ? "reposted" : "repost", systemImage: "arrow.2.squarepath")
                        }
                        .disabled(isReposted)
                    }

                    if isShareable {
                                            Button {
                                                showShareCard = true
                                            } label: {
                                                Label("share", systemImage: "square.and.arrow.up")
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
                .onChange(of: isAlreadyLiked) { _, newValue in
                    if !postId.isEmpty { isLiked = newValue }
                }
                .onChange(of: isAlreadySaved) { _, newValue in
                    if !postId.isEmpty { isSaved = newValue }
                }
                .onChange(of: isAlreadyReposted) { _, newValue in
                    if !postId.isEmpty { isReposted = newValue }
                }
                // Adopt the latest server counts when the same post id is
                // re-delivered by a feed refresh — without these, the row keeps
                // its first-seen like/repost numbers and drifts from the server.
                .onChange(of: likes) { _, newValue in
                    if !postId.isEmpty { localLikeCount = newValue }
                }
                .onChange(of: reposts) { _, newValue in
                    if !postId.isEmpty { localRepostCount = newValue }
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
                                    Text("you wont see their posts or messages. they wont be notified.")
                                }
    }
    
    // MARK: - Action Label

    func actionLabel(icon: String, count: Int, isActive: Bool, activeColor: String = "828AA0") -> some View {
            HStack(spacing: 5) {
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
            PostInteractionManager.toggleLike(
                postId: postId,
                authorId: authorId,
                currentlyLiked: isLiked,
                currentCount: localLikeCount
            ) { result in
                isLiked = result.isLiked
                localLikeCount = result.newCount
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
            guard !isReposted, !isRepostPost else { return }
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
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
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
                // Collapsed: just the prompt + tap to expand
                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        // Eyebrow — uppercase, tracked, muted.
                                        Text(vm.promptTimeLabel)
                                            .font(ToskaFont.eyebrow)
                                            .textCase(.uppercase)
                                            .foregroundColor(ToskaColor.text3)
                                            .tracking(1.4)

                                        // Greeting — editorial serif italic on the
                                        // plain surface (no card).
                                        Text(vm.todaysPrompt.0)
                                            .font(ToskaFont.serifItalic(17))
                                            .foregroundColor(ToskaColor.text)
                                            .lineSpacing(3)
                                            .lineLimit(isExpanded ? nil : 3)
                                            .multilineTextAlignment(.leading)

                                        // "todays moment" affordance — accent link row
                                        // (sparkle + label + chevron), per design.
                                        HStack(spacing: 6) {
                                            Image(systemName: "sparkle")
                                                .font(.system(size: 13))
                                                .foregroundColor(ToskaColor.accent)
                                            Text("todays moment")
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundColor(ToskaColor.accent)
                                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(ToskaColor.accent)
                                        }
                                        .padding(.top, 2)

                                        if isExpanded {
                                            Text("new one tomorrow.")
                                                .font(.system(size: 10, weight: .regular))
                                                .foregroundColor(ToskaColor.text3)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    // Bumped 8→16 so the prompt card has
                                    // breathing room below the for-you /
                                    // following divider line — the line was
                                    // hugging the top of the blue card.
                                    .padding(.top, 16)
                                }
                                .buttonStyle(.plain)

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
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                                Text("your response")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                                Spacer()
                                Text("tap to open")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color.toskaTimestamp)
                            }
                            Text(response.text)
                                .font(ToskaFont.serif(14))
                                .foregroundColor(ToskaColor.text)
                                .lineSpacing(3)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.toskaBlue.opacity(0.06))
                        .cornerRadius(10)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Expanded content
                if isExpanded {
                    VStack(spacing: 0) {
                        Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)

                        // Respond button — hidden once today's response exists
                        // (soft one-per-day cap). The "your response" card
                        // above replaces it.
                        if vm.todaysPromptResponse == nil {
                            Button { vm.showPromptCompose = true } label: {
                                HStack {
                                    HStack(spacing: 5) {
                                        Image(systemName: vm.todaysPrompt.2)
                                            .font(.system(size: 10))
                                            .foregroundColor(tagColor(for: vm.todaysPrompt.1))
                                        Text(vm.todaysPrompt.1)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(tagColor(for: vm.todaysPrompt.1).opacity(0.6))
                                    }
                                    Spacer()
                                    HStack(spacing: 4) {
                                        Image(systemName: "pencil.line")
                                            .font(.system(size: 10))
                                        Text("respond")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundColor(Color.toskaBlue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.toskaBlue.opacity(0.1))
                                    .cornerRadius(12)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Daily moment
                        if vm.hasDailyMoment {
                            Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                            Button { vm.showDailyMoment = true } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: "c49a6c"))
                                    Text(vm.dailyMomentLabel)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(LateNightTheme.handleText)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .light))
                                        .foregroundColor(LateNightTheme.tertiaryText)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Witness post
                        if vm.witnessPost != nil {
                            Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                            Button { vm.showWitnessPost = true } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.toskaBlue)
                                        .frame(width: 5, height: 5)
                                    Text("someone needs a reply")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color.toskaBlue)
                                    Spacer()
                                    Text("be there")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Color.toskaBlue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.toskaBlue.opacity(0.1))
                                        .cornerRadius(10)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // "most unsaid today" surface removed — it was the same
                        // data as the trending tab (top-liked post in the last
                        // 24h) and pulled the prompt card away from its core
                        // job (prompt → respond → your response). The state +
                        // fetcher stay in FeedViewModel because hasDailyMoment
                        // also depends on that query.
                    }
                }
                
                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
            }

        // Anniversary post (always visible, not collapsed)
        if let annPost = vm.anniversaryPost {
                    AnniversaryCardView(post: annPost, postId: annPost.postId)
                }
    }
}
// MARK: - Custom Refresh Header

struct ToskaRefreshHeader: View {
    let isRefreshing: Bool
    let triggerProgress: CGFloat

    private let phrases = [
            "loading what people typed at 2am...",
            "finding the things nobody said out loud...",
            "pulling up what someone almost deleted...",
            "gathering the unsent texts...",
            "loading what kept someone up tonight...",
            "finding who else is going through it...",
            "collecting the things we pretend we dont feel...",
            "seeing what someone finally admitted...",
            "loading the thoughts that wont stop...",
            "finding the words that hurt to read because theyre yours too...",
        ]

    @State private var currentPhrase = ""
    @State private var opacity: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .tint(Color.toskaBlue)
                    .scaleEffect(0.8)
                Text(currentPhrase)
                    .font(.custom("Georgia-Italic", size: 12))
                    .foregroundColor(Color.toskaBlue.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .opacity(opacity)
                    .animation(.easeIn(duration: 0.3), value: opacity)
            } else {
                if triggerProgress > 0.2 {
                    Text(currentPhrase)
                        .font(.custom("Georgia-Italic", size: 12))
                        .foregroundColor(Color.toskaBlue.opacity(Double(triggerProgress) * 0.7))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            currentPhrase = phrases.randomElement() ?? phrases[0]
        }
        .onChange(of: isRefreshing) { _, newValue in
            if newValue {
                currentPhrase = phrases.randomElement() ?? phrases[0]
                withAnimation { opacity = 1 }
            } else {
                opacity = 0
            }
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
    TagItem(name: "longing", colorHex: "8B92A6", icon: "moon.stars"),
    TagItem(name: "anger", colorHex: "C0635E", icon: "flame"),
    TagItem(name: "regret", colorHex: "8B7EC8", icon: "arrow.uturn.backward"),
    TagItem(name: "acceptance", colorHex: "5F9E89", icon: "leaf"),
    TagItem(name: "confusion", colorHex: "C09A6A", icon: "questionmark.circle"),
    TagItem(name: "unsent", colorHex: "7a97b5", icon: "envelope"),
    TagItem(name: "moving on", colorHex: "5a9e8f", icon: "arrow.right.circle"),
    TagItem(name: "still love you", colorHex: "c47a8a", icon: "heart"),
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
    switch tag {
    case "longing": return Color(hex: "8B92A6")
    case "anger": return Color(hex: "C0635E")
    case "regret": return Color(hex: "8B7EC8")
    case "acceptance": return Color(hex: "5F9E89")
    case "confusion": return Color(hex: "C09A6A")
    case "unsent": return Color(hex: "7A97B5")
    case "moving on": return Color(hex: "5A9E8F")
    case "still love you": return Color(hex: "C47A8A")
    default: return Color(hex: "8B92A6")
    }
}

// MARK: - Content Safety Checks
//
// Split into two tiers so the gentle-check rail can be partially user-controlled
// without disabling the most critical safety surface.
//
// `explicitCrisisPhrases` = direct statements of suicidal ideation or self-harm.
// These always trigger the check-in regardless of the user's gentleCheckIn
// toggle — a person typing these may not be in a state to have pre-opted into
// a safety rail, so the rail is always on. This mirrors iOS Emergency SOS's
// design (can't be fully disabled).
//
// `softConcernPhrases` = expressions of hopelessness/despair that may indicate
// risk but also show up in everyday venting. These respect the user's
// gentleCheckIn toggle so users who find the rail intrusive can opt out of the
// softer tier without losing the explicit-tier safety net.

// Keep in sync with functions/index.js MOD_CRISIS_EXPLICIT / MOD_CRISIS_SOFT.
// (The server additionally normalizes leet/unicode/spaced evasions; the
// client is a best-effort pre-publish check, the server is the backstop.)
let explicitCrisisPhrases = [
    // direct suicide vocabulary + common misspellings
    "suicidal", "suicide", "suicidel", "sucide", "sucidal", "suiside", "suacide",
    // self-killing intent
    "kill myself", "killing myself", "kill my self", "want to kill myself",
    "wanna kill myself", "going to kill myself", "gonna kill myself",
    "off myself", "end myself", "delete myself", "unalive", "unalive myself",
    "hang myself", "hanging myself", "neck myself",
    // ending my life
    "end my life", "ending my life", "end it all", "ending it all",
    "take my own life", "take my life", "want to end my life",
    // wanting to die / be dead
    "want to die", "wanna die", "want to be dead", "ready to die",
    "wish i was dead", "wish i were dead", "wish i could die",
    "better off dead", "rather be dead",
    // self-harm
    "hurt myself", "want to hurt myself", "harm myself", "self harm",
    "self-harm", "selfharm", "cut myself", "cutting myself", "burn myself",
    // not wanting to exist / wake up
    "don't want to wake up", "dont want to wake up", "don't want to be here",
    "dont want to be here", "don't want to exist", "dont want to exist",
    "want to disappear", "want to vanish",
]

let softConcernPhrases = [
    "can't go on", "cant go on", "can't do this anymore", "cant do this anymore",
    "can't keep going", "can't take it anymore", "cant take it anymore",
    "no reason to live", "nothing to live for", "no point in living",
    "no point anymore", "not worth living", "give up on everything",
    "want to give up", "done with life", "done with everything",
    "tired of living", "tired of being alive", "better off without me",
    "everyone better off without me", "no one would care", "no one would notice",
    "nobody cares", "nobody would miss me", "won't be missed",
    "disappear forever", "why am i still here", "wish i wasn't here",
    "wish i didn't exist", "want it to stop", "want it all to end", "nothing left",
]

// Back-compat alias so existing call sites that only care about "is it
// concerning at all" keep working while surfaces migrate to crisisLevel(for:).
let concerningPhrases = explicitCrisisPhrases + softConcernPhrases

enum CrisisLevel {
    /// Explicit ideation or self-harm — always show the check-in.
    case explicit
    /// Softer hopelessness signals — check-in respects gentleCheckIn setting.
    case soft
}

func crisisLevel(for text: String) -> CrisisLevel? {
    let lowered = text.lowercased()
    if explicitCrisisPhrases.contains(where: { lowered.contains($0) }) { return .explicit }
    if softConcernPhrases.contains(where: { lowered.contains($0) }) { return .soft }
    return nil
}

// Confusable map used by `canonicalize`. Covers the unicode points a poster
// most commonly reaches for when trying to slip a name past the warning
// modal: Cyrillic / Greek lookalikes that render visually identical to
// Latin letters in the iOS system font. The map is intentionally LARGER
// than `moderationHomoglyphMap` (used by contentViolation) because the
// name-detection path needs to fold both upper- and lower-case forms — a
// poster typing "sаrah" with Cyrillic а is the exact case we want to catch,
// and the slur-detection map only handles uppercase.
//
// Fullwidth letters (U+FF21..U+FF5A, "Ｓａｒａｈ") are handled by code-point
// arithmetic in `canonicalize` rather than this table — they're contiguous
// and the table would just be 52 mechanical entries.
private let nameConfusableMap: [Character: Character] = [
    // Cyrillic uppercase
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
    "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J",
    // Cyrillic lowercase
    "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
    "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j",
    // Greek uppercase
    "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
    "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    // Greek lowercase
    "α": "a", "β": "b", "ε": "e", "ι": "i", "ο": "o", "ρ": "p",
    "τ": "t", "υ": "y", "χ": "x",
]

private let nameLeetMap: [Character: Character] = [
    "0": "o", "1": "i", "3": "e", "4": "a",
    "5": "s", "7": "t", "8": "b",
    "@": "a", "$": "s",
]

/// Lossless-ish normalization for the name-detection path. Folds the cases
/// that don't change semantic meaning of a name token but do bypass an
/// ASCII-only substring lookup:
///   - NFD decompose then strip combining marks (U+0300..U+036F): "Sårāh" → "Sarah"
///   - Fullwidth ASCII (U+FF21..U+FF5A) → ASCII: "Ｓａｒａｈ" → "Sarah"
///   - Confusable Cyrillic / Greek letters → Latin: "Sаrah" → "Sarah"
///   - Lowercase
///
/// Deliberately does NOT do leet substitution — that's destructive on legit
/// numbers ("3 months ago" must NOT become "e months ago" for the general
/// prose checks). Leet lives in `aggressiveNormalizeForNameMatch`, which is
/// only consulted by the curated-name lookup.
// Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) cover bold/italic/
// script/fraktur/double-struck/sans-serif/monospace letterforms that render
// visually identical to Latin but ship as separate codepoints. Without
// folding, "𝐉𝐨𝐡𝐧" looks like "John" but the name match never fires.
// Each 26-letter run starts at one of these offsets — enumerating them
// is more reliable than NFKC, which is invasive on emoji + symbols.
//
// Mirror of MATH_ALPHA_*_OFFSETS in functions/moderation.js. Keep in sync
// when adding new style ranges.
private let mathAlphaUpperOffsets: [UInt32] = [
    0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D4D0, 0x1D504, 0x1D538,
    0x1D56C, 0x1D5A0, 0x1D5D4, 0x1D608, 0x1D63C, 0x1D670,
]
private let mathAlphaLowerOffsets: [UInt32] = [
    0x1D41A, 0x1D44E, 0x1D482, 0x1D4B6, 0x1D4EA, 0x1D51E, 0x1D552,
    0x1D586, 0x1D5BA, 0x1D5EE, 0x1D622, 0x1D656, 0x1D68A,
]

private func foldMathAlpha(_ value: UInt32) -> Unicode.Scalar? {
    for start in mathAlphaUpperOffsets where value >= start && value <= start + 25 {
        return Unicode.Scalar(0x41 + (value - start))
    }
    for start in mathAlphaLowerOffsets where value >= start && value <= start + 25 {
        return Unicode.Scalar(0x61 + (value - start))
    }
    return nil
}

/// Strip-set: invisible separators + bidi controls that fragment tokens or
/// reverse visual order without changing the codepoint sequence the
/// detector sees. Removed BEFORE NFD decompose so e.g. "Sa​rah" (with a
/// zero-width space splitting Sa | rah) collapses to "sarah" instead of
/// tokenizing into ["sa", "rah"] — the latter never matches a name.
///
/// Covers: U+200B-D (zero-width space/joiner/non-joiner), U+2060 (word
/// joiner), U+202A-E (LRE/RLE/PDF/LRO/RLO bidi controls), U+2066-9
/// (LRI/RLI/FSI/PDI bidi isolates), U+FEFF (BOM / zero-width no-break).
///
/// Mirror of STRIP_INVISIBLE_RE in functions/moderation.js.
private func stripInvisibleSeparators(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if (v >= 0x200B && v <= 0x200D) { continue }
        if v == 0x2060 { continue }
        if (v >= 0x202A && v <= 0x202E) { continue }
        if (v >= 0x2066 && v <= 0x2069) { continue }
        if v == 0xFEFF { continue }
        out.unicodeScalars.append(scalar)
    }
    return out
}

/// Strips invisible separators + combining marks but preserves case, and
/// does NOT fold confusables / fullwidth / math-alpha. Used to tokenize
/// text in Layers 4 / 4.5: an attacker who inserts standalone combining
/// marks (e.g. `S̶arah` = S + U+0336 + arah) fragments the token under
/// the default `CharacterSet.alphanumerics.inverted` split because
/// combining marks are Mn category. Stripping them first re-merges the
/// token so the name lookup sees `Sarah` as one capitalized word.
/// Mirror of stripCombiningMarksKeepCase in functions/moderation.js.
private func stripCombiningMarksKeepCase(_ text: String) -> String {
    let stripped = stripInvisibleSeparators(text)
    let decomposed = stripped.decomposedStringWithCanonicalMapping
    var result = ""
    result.reserveCapacity(decomposed.count)
    for scalar in decomposed.unicodeScalars {
        let value = scalar.value
        if value >= 0x0300 && value <= 0x036F { continue }
        result.unicodeScalars.append(scalar)
    }
    return result
}

private func canonicalize(_ text: String) -> String {
    let stripped = stripInvisibleSeparators(text)
    let decomposed = stripped.decomposedStringWithCanonicalMapping
    var result = ""
    result.reserveCapacity(decomposed.count)
    for scalar in decomposed.unicodeScalars {
        let value = scalar.value
        // Combining marks — drop after NFD decompose.
        if value >= 0x0300 && value <= 0x036F { continue }
        // Fullwidth uppercase A-Z (U+FF21..U+FF3A).
        if value >= 0xFF21 && value <= 0xFF3A {
            result.unicodeScalars.append(Unicode.Scalar(value - 0xFEE0)!)
            continue
        }
        // Fullwidth lowercase a-z (U+FF41..U+FF5A).
        if value >= 0xFF41 && value <= 0xFF5A {
            result.unicodeScalars.append(Unicode.Scalar(value - 0xFEE0)!)
            continue
        }
        // Mathematical Alphanumeric Symbols → ASCII letter.
        if value >= 0x1D400 && value <= 0x1D7FF {
            if let folded = foldMathAlpha(value) {
                result.unicodeScalars.append(folded)
                continue
            }
        }
        let ch = Character(scalar)
        if let mapped = nameConfusableMap[ch] {
            result.append(mapped)
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    return result.lowercased()
}

/// Aggressive normalization for the curated-name lookup ONLY.
/// Builds on `canonicalize` then:
///   - Substitutes leet characters (0→o, 1→i, 3→e, 4→a, 5→s, 7→t, 8→b, @→a, $→s)
///   - Collapses single-letter separator chains: "j.o.h.n" / "j-o-h-n" /
///     "j_o_h_n" / "j o h n" → "john"
///
/// Conservative on false positives by design: the result is checked ONLY
/// against the curated first/last name sets. We do NOT run this output
/// through the general identifying-pattern keywords or the address regex,
/// because de-leet would mangle legit numeric content ("3 months ago" → "e
/// months ago"; "$200 bucks" → "s200 bucks") and the collapse pass would
/// fuse incidental letter sequences into spurious tokens.
// Compiled once at file scope. Pattern: single letter, then 1+ runs of
// (separator+ then single letter), bounded by word boundaries. Matches
// "j.o.h.n", "j o h n", "j-o-h-n", "j_o_h_n", etc. Single-character classes
// only and no nested quantifiers — backtracking-safe even on a 2000-char
// text. Force-unwrapping is OK here: the pattern is a constant, so a
// failure to compile would surface immediately on first call.
private let nameSeparatorCollapseRegex: NSRegularExpression =
    try! NSRegularExpression(pattern: "\\b[a-z](?:[.\\-_ ]+[a-z])+\\b")

private func aggressiveNormalizeForNameMatch(_ text: String) -> String {
    let canon = canonicalize(text)
    var deLeet = ""
    deLeet.reserveCapacity(canon.count)
    for ch in canon {
        deLeet.append(nameLeetMap[ch] ?? ch)
    }
    var result = deLeet
    let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
    let matches = nameSeparatorCollapseRegex.matches(in: result, range: nsRange)
    // Iterate in reverse so earlier-match indices remain valid as we mutate.
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let collapsed = String(result[range]).filter { $0.isLetter }
        result.replaceSubrange(range, with: collapsed)
    }
    return result
}

/// Surnames intentionally restricted to predominantly-proper-noun forms.
/// Excluded high-FP names that are also common English words: Brown, White,
/// Green, Hill, Wood, Long, King, Price, Young, Ward, Cook, Hall, Gray,
/// Wright, Reed — flagging "the brown dog" or "King" (used as a noun for
/// rulers) on a heartbreak post would be worse than missing a surname mention.
/// Tradeoff accepted: this list intentionally undercovers; the cost of a
/// false positive in this app (deletes a vulnerable user's post) outweighs
/// the cost of missing a surname that could have been caught.
private let commonLastNames: Set<String> = [
    "smith", "johnson", "williams", "jones", "garcia", "miller", "davis",
    "rodriguez", "martinez", "hernandez", "lopez", "gonzalez", "wilson",
    "anderson", "thomas", "taylor", "jackson", "martin", "perez",
    "thompson", "harris", "clark", "ramirez", "lewis", "robinson",
    "scott", "torres", "nguyen", "flores", "adams", "nelson", "rivera",
    "campbell", "mitchell", "carter", "roberts", "gomez", "phillips",
    "evans", "turner", "parker", "cruz", "edwards", "collins", "reyes",
    "stewart", "morris", "morales", "murphy", "rogers", "gutierrez",
    "ortiz", "morgan", "peterson", "bailey", "kelly", "howard", "ramos",
    "richardson", "watson", "chavez", "bennett", "mendoza", "ruiz",
    "hughes", "alvarez", "castillo", "sanders", "patel", "myers", "ross",
    "foster", "jimenez", "cooper", "walker", "allen", "washington",
    "jefferson", "lincoln", "kennedy", "obama",
]

func containsNameOrIdentifyingInfo(_ text: String) -> Bool {
    let commonNames: Set<String> = [
        "james", "john", "robert", "michael", "david", "richard", "joseph", "thomas", "charles",
        "christopher", "matthew", "anthony", "donald", "steven", "andrew", "joshua",
        "kenneth", "kevin", "brian", "george", "timothy", "ronald", "edward", "jason", "jeffrey", "ryan",
        "jacob", "gary", "nicholas", "eric", "jonathan", "stephen", "larry", "justin", "scott", "brandon",
        "benjamin", "samuel", "raymond", "gregory", "alexander", "patrick", "dennis", "jerry",
        "tyler", "aaron", "jose", "adam", "nathan", "henry", "peter", "zachary", "douglas", "harold",
        "patricia", "jennifer", "linda", "barbara", "elizabeth", "susan", "jessica", "sarah", "karen",
        "lisa", "nancy", "betty", "margaret", "sandra", "ashley", "dorothy", "kimberly", "emily", "donna",
        "michelle", "carol", "amanda", "melissa", "deborah", "stephanie", "rebecca", "sharon", "laura", "cynthia",
        "kathleen", "amy", "angela", "shirley", "brenda", "pamela", "emma", "nicole", "helen",
        "samantha", "katherine", "christine", "debra", "rachel", "carolyn", "janet", "catherine", "maria", "heather",
        "diane", "ruth", "julie", "olivia", "joyce", "virginia", "victoria", "kelly", "lauren", "christina",
        "joan", "evelyn", "judith", "megan", "andrea", "cheryl", "hannah", "jacqueline", "martha", "gloria",
        "teresa", "sara", "madison", "frances", "kathryn", "janice", "jean", "abigail", "alice",
        "alex", "chris", "taylor", "casey", "riley", "jamie", "quinn", "avery",
        "cameron", "dakota", "skyler", "charlie", "finley", "harper", "logan",
        "ethan", "aiden", "jackson", "sebastian", "mateo", "owen", "oliver",
        "sophia", "isabella", "charlotte", "amelia", "chloe", "penelope", "layla",
        "nora", "zoey", "eleanor", "hazel", "audrey",
        "claire", "skylar", "paisley", "everly", "caroline",
        "genesis", "emilia", "kennedy", "kinsley", "naomi", "aaliyah", "elena",
        // Common nicknames — added 2026-05-01 sprint after the test suite
        // surfaced an evasion-vector miss for "M1k3" (de-leets to "mike",
        // which had no entry in the full-name list). Filtered out:
        //   - jordan (country, high FP risk)
        //   - max, drew, sue (common verbs/intensifiers)
        //   - bob, rob, nick (also verbs in common usage)
        // Mirror set lives in functions/moderation.js — keep in sync.
        "mike", "tom", "jim", "tim", "dan", "sam", "ben", "tony", "jake",
        "leo", "ian", "kyle", "evan", "greg", "jeff", "kurt", "paul",
        "pete", "eli", "brett", "todd", "troy",
        "liz", "beth", "kate", "ann", "jane", "lynn", "abby", "becky", "jess",
    ]
    let ambiguousWords: Set<String> = [
                // Common English words that happen to also be names
                "will", "grace", "angel", "mark", "frank", "art", "may",
                "joy", "hope", "faith", "chance", "chase", "hunter",
                "summer", "autumn", "winter", "dawn", "eve",
                "rose", "lily", "iris", "ivy", "pearl", "ruby", "amber",
                "brook", "cliff", "dale", "glen", "heath", "lance", "miles",
                "norm", "pat", "ray", "rex", "rod", "skip", "wade",
                "violet", "olive", "sage", "holly", "ginger",
                "sandy", "misty", "stormy", "sunny", "cherry", "candy",
                "destiny", "trinity", "harmony", "melody", "serenity",
            ]
    let identifyingPatterns = [
        "instagram", "insta", "snapchat", "snap", "tiktok", "twitter",
        "facebook", "linkedin", "phone number", "my number", "text me",
        "call me", "dm me", "follow me", "find me", "look me up",
        "last name", "full name", "school name", "works at", "goes to",
        "lives in", "lives on", "lives at", "address",
        "apartment", "apt ", "suite ",
        "her name is", "his name is", "their name is",
        // NOTE: "named " was previously in this list as a broad keyword and
        // false-positived on legitimate sentences like "she named the dog
        // Rex" or "we named the album X". The careful `namedPatterns` check
        // below (which requires the following token to be capitalized) is
        // strictly better and catches the cases we care about ("she was
        // named Olivia") without the FP surface. Same removal in the
        // server-side mirror at functions/moderation.js.
        "zip code", "zipcode",
        "discord", "telegram", "whatsapp", "signal",
        "threads", "bluesky", "reddit",
    ]
    let lowered = text.lowercased()
    for pattern in identifyingPatterns { if lowered.contains(pattern) { return true } }

    // Two-letter social-platform shorthand (ig:/sc:/fb: with optional space).
    // Word-boundary anchored so "dig: deeper", "fab.", "abs-" don't flag.
    // Mirror of SOCIAL_SHORTHAND_RE in functions/moderation.js.
    if text.range(of: "\\b(ig|sc|fb)\\b\\s*[:.\\-]", options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }

    if text.range(of: "@[a-zA-Z]", options: .regularExpression) != nil { return true }

    // Possessive name pattern: "Jessica's", "Mike's" — a capitalized word followed by 's
    if text.range(of: "\\b[A-Z][a-z]{2,}'s\\b", options: .regularExpression) != nil {
        let matches = text.matches(of: /\b([A-Z][a-z]{2,})'s\b/)
        for match in matches {
            let name = String(match.1).lowercased()
            if !ambiguousWords.contains(name) { return true }
        }
    }

    // "my ex [Name]", "my friend [Name]", "my sister [Name]" etc.
    let relationshipPrefixes = ["my ex ", "my friend ", "my bf ", "my gf ",
        "my boyfriend ", "my girlfriend ", "my sister ", "my brother ",
        "my mom ", "my dad ", "my mother ", "my father ",
        "my coworker ", "my boss ", "my roommate ", "my neighbor ",
        "this girl ", "this guy ", "this boy ", "this man ", "this woman "]
    for prefix in relationshipPrefixes {
        if let range = lowered.range(of: prefix) {
            let afterPrefix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let firstWord = afterPrefix.components(separatedBy: CharacterSet.alphanumerics.inverted).first,
               !firstWord.isEmpty, firstWord.count >= 2, firstWord.first?.isUppercase == true {
                return true
            }
        }
    }

    // "named X", "called X", "name is X", "name was X"
    let namedPatterns = ["named ", "called ", "name is ", "name was "]
    for pattern in namedPatterns {
        if let range = lowered.range(of: pattern) {
            let afterPattern = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let firstWord = afterPattern.components(separatedBy: CharacterSet.alphanumerics.inverted).first,
               !firstWord.isEmpty, firstWord.first?.isUppercase == true {
                return true
            }
        }
    }

    // Any capitalized word that looks like a proper noun mid-sentence
    // (not a sentence starter, not an ambiguous word, not a known safe word)
    let safeCapitalizedWords: Set<String> = [
        "i", "im", "ive", "ill", "id",
        "god", "christmas", "easter", "halloween", "valentines",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
        "american", "english", "spanish", "french", "chinese", "japanese",
        "toska", "giphy", "apple", "google", "firebase",
    ]

    // Street address pattern: "123 Main St" / "456 Oak Avenue"
    let streetSuffixes = "street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|road|rd|way|place|pl|court|ct|circle|cir|terrace|trail|parkway|pkwy"
    if text.range(of: "\\d+\\s+[A-Za-z]+\\s+(\(streetSuffixes))\\b", options: .regularExpression) != nil { return true }
    let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let sentenceStarters: Set<String> = Set(sentences.compactMap { sentence in
        sentence.components(separatedBy: CharacterSet.alphanumerics.inverted).first(where: { !$0.isEmpty })
    })
    let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    for word in words {
        let lower = word.lowercased()
        if lower.count < 2 { continue }
        if ambiguousWords.contains(lower) { continue }
        if safeCapitalizedWords.contains(lower) { continue }
        // Known name in database — flag it
        if commonNames.contains(lower) {
            if word.first?.isUppercase == true {
                if sentenceStarters.contains(word) { continue }
                return true
            }
        }
    }

    // Full-name shape: two consecutive Capitalized words ("Tess Salinaro").
    // Mirror of functions/moderation.js looksLikeFullName (2026-06-02). Catches
    // uncommon names with no relationship context; lowercase-surname / bare
    // single names still slip (that needs NER). Excludes common non-name
    // proper nouns so "New York" / "Harry Potter" don't trip it.
    let safeProperNounBigrams: Set<String> = [
        "new york", "new jersey", "new orleans", "new mexico", "new hampshire",
        "los angeles", "san francisco", "san diego", "san antonio", "san jose",
        "las vegas", "rhode island", "north carolina", "south carolina",
        "north dakota", "south dakota", "west virginia", "new zealand",
        "hong kong", "costa rica", "puerto rico", "united states", "united kingdom",
        "great britain", "saudi arabia", "south africa", "south korea",
        "taylor swift", "harry potter", "taco bell", "burger king", "old navy",
        "stranger things", "breaking bad", "black friday",
        "happy birthday", "happy holidays", "merry christmas",
        "good morning", "good evening", "good afternoon", "good night", "good luck",
        "thank god",
    ]
    for match in text.matches(of: /\b([A-Z][a-z]+)\s+([A-Z][a-z]+)\b/) {
        let w1 = String(match.1).lowercased()
        let w2 = String(match.2).lowercased()
        if w1.count < 2 || w2.count < 2 { continue }
        if safeCapitalizedWords.contains(w1) || safeCapitalizedWords.contains(w2) { continue }
        if ambiguousWords.contains(w1) && ambiguousWords.contains(w2) { continue }
        if safeProperNounBigrams.contains("\(w1) \(w2)") { continue }
        return true
    }
    let crisisNumbers = [
            "988-273-8255", "9882738255", "988 273 8255",
            "1-800-273-8255", "18002738255", "1 800 273 8255",
            "741741", "741 741",
            "1-800-799-7233", "18007997233",
            "1-800-656-4673", "18006564673",
        ]
    var digitStripped = text
    for number in crisisNumbers {
        digitStripped = digitStripped.replacingOccurrences(of: number, with: "")
    }
    // Collapse phone-format separators between digits so a formatted phone
    // like `(555) 123-4567` survives the date/year/small-number strips
    // below. Without this, `\b\d{1,3}\b` peels `555`/`123` and
    // `\b\d{4,5}\b` peels `4567` because parens/space/dash sit at word
    // boundaries around each chunk — total digit count goes to zero.
    // Mirror of the JS fix in functions/moderation.js.
    digitStripped = digitStripped
            .replacingOccurrences(of: "(\\d)[-.\\s()]+(?=\\d)", with: "$1", options: .regularExpression)
    digitStripped = digitStripped
            .replacingOccurrences(of: "\\d{1,2}[:/]\\d{2}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{4,5}\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{1,3}\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\$[\\d,]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\d{1,2}/\\d{1,2}/\\d{2,4}", with: "", options: .regularExpression)
        let digits = digitStripped.filter { $0.isNumber }
        if digits.count >= 10 { return true }

    // ============================================================
    // EVASION HARDENING — additive layers for the 2026-05-01 pre-launch sprint.
    //
    // The original chain (above) handles plain prose well, but heartbroken
    // posters in a public-anonymous app sometimes try to dodge the warning
    // modal with cryptic stylization. Generic anonymous social apps fail
    // mostly to harassment + hate speech (Whisper, Yik Yak, Secret all died
    // this way); heartbreak content is structurally brand-safer but
    // introduces a different sharp edge: a poster in a high-emotion state
    // is tempted to identify their ex by name, address, social handle, or
    // workplace. Anonymous + public + named-target = textbook defamation,
    // plus an Apple-Guideline-1.2 takedown trigger.
    //
    // Vectors closed by the layers below:
    //   - Unicode confusables  (Sаrah, Ｓａｒａｈ, Sårāh)
    //   - Leetspeak             (j0hn, 5arah, m1k3, m@tt)
    //   - Separator tricks      (J.o.h.n, j-o-h-n, j o h n, j_o_h_n)
    //   - Last names            (Smith from accounting)
    //   - Apartment / unit nums (apt 4B, unit 12, #207)
    //   - Initials w/ context   (my ex J.S.)
    //   - URLs                  (instagram.com/handle, t.me/handle)
    //
    // Layers run AFTER the original chain so we don't change its semantics —
    // anything that already flagged still flags first; new layers only
    // catch inputs the original missed.
    // ============================================================

    // Layer 1: URL / social-link detection.
    // The existing identifyingPatterns catches the keyword "instagram", but
    // misses domain-style references like "instagram.com/handle" when the
    // surrounding context doesn't already trip the keyword. The url
    // detection in contentViolation() is upstream of name detection at
    // every call site, so most of these are already caught — this layer
    // is defense in depth for surfaces that may eventually consult name
    // detection without a contentViolation gate (and to make the behavior
    // explicit when reading this function in isolation).
    let urlRegexes = [
        "https?://",
        "\\bwww\\.[a-z]",
        "\\b(instagram|tiktok|facebook|twitter|snapchat|linkedin|reddit|youtube|youtu|t|discord|telegram|whatsapp|signal|onlyfans|threads|bluesky|cash\\.app|venmo|paypal)\\.(com|me|gg|tv|be|co|app|net|org|io)\\b",
        "\\b(linktr\\.ee|bit\\.ly|tinyurl)\\b",
    ]
    for pattern in urlRegexes {
        if lowered.range(of: pattern, options: .regularExpression) != nil { return true }
    }

    // Layer 2: Apartment / unit / suite numbers.
    // The existing identifyingPatterns includes "apartment", "apt ", "suite "
    // — but "apt " requires a trailing space, so "apt4B" or "apt.4B" miss.
    // It also has no rule for bare "#207". This layer fixes both.
    let apartmentRegex = "\\b(apt|unit|suite|ste)\\.?\\s*#?\\s*\\d+[a-z]?\\b"
    if lowered.range(of: apartmentRegex, options: .regularExpression) != nil { return true }
    if text.range(of: "#\\s*\\d{1,4}[a-z]?\\b", options: .regularExpression) != nil { return true }

    // Layer 3: Dotted initials with relationship context — "my ex J.S.".
    // The existing relationship-prefix loop tokenizes "J.S." into single
    // chars and bails on the count >= 2 check. Scan a 40-char window after
    // each prefix for a dotted-initials pattern instead.
    for prefix in relationshipPrefixes {
        if let range = lowered.range(of: prefix) {
            let afterPrefix = String(text[range.upperBound...])
            let scanWindow = String(afterPrefix.prefix(40))
            if scanWindow.range(of: "\\b[A-Z]\\.[A-Z]\\.?", options: .regularExpression) != nil {
                return true
            }
        }
    }

    // Layer 4: Per-token canonicalize-then-name-lookup.
    // Catches confusables (Cyrillic/Greek/fullwidth) and accented forms.
    // Capitalization gate: original first character must be uppercase, AND
    // the canonicalized token must not be a sentence-starter in the
    // canonicalized text — same false-positive guards the existing
    // first-name loop applies.
    // Tokenize the COMBINING-MARK-STRIPPED form so an attacker writing
    // `S̶arah` doesn't fragment to ['S', 'arah']. Mirror of the JS Layer
    // 4 fix in functions/moderation.js.
    let canonical = canonicalize(text)
    let canonicalSentenceStarters: Set<String> = Set(
        canonical.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted).first(where: { !$0.isEmpty }) }
    )
    let originalTokens = stripCombiningMarksKeepCase(text)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    for word in originalTokens {
        let canonWord = canonicalize(word)
        if canonWord.count < 2 { continue }
        if ambiguousWords.contains(canonWord) { continue }
        if safeCapitalizedWords.contains(canonWord) { continue }
        let isFirstName = commonNames.contains(canonWord)
        let isLastName = commonLastNames.contains(canonWord) && canonWord.count >= 3
        if !isFirstName && !isLastName { continue }
        guard let firstChar = word.first, firstChar.isUppercase else { continue }
        // Sentence-starter exemption applies only to legit-prose tokens.
        // If canonicalize had to fold confusables / fullwidth / accents to
        // reach the name (i.e. the original lowercased token differs from
        // the canonical token), that's evidence of deliberate evasion and
        // the sentence-start exemption no longer applies — "Mіchael" at the
        // start of a sentence is an attack, not a casual capitalization.
        let isEvasion = word.lowercased() != canonWord
        if !isEvasion && canonicalSentenceStarters.contains(canonWord) { continue }
        return true
    }

    // Layer 4.5: Reversed-token name lookup. Mirror of the server-side
    // moderation.js Layer 4.5. canonicalize strips bidi-override codepoints
    // (so a render-time visual flip can't slip through), but doesn't try
    // a literal reversal — "haraS" written in plain ASCII passes every
    // prior layer because the forward token isn't in the name set. We
    // reverse each canonicalized token and re-check. Length floor of 4
    // keeps false positives down (short reversed strings hit too many
    // common English fragments); palindromes are skipped because the
    // forward layers would have already had a chance.
    for word in originalTokens {
        let canonWord = canonicalize(word)
        if canonWord.count < 4 { continue }
        let reversed = String(canonWord.reversed())
        if reversed == canonWord { continue }
        if ambiguousWords.contains(reversed) { continue }
        if safeCapitalizedWords.contains(reversed) { continue }
        let isFirstRev = commonNames.contains(reversed)
        let isLastRev = commonLastNames.contains(reversed) && reversed.count >= 3
        if isFirstRev || isLastRev { return true }
    }

    // Layer 5: Whole-text aggressive normalization.
    // Catches separator chains (j.o.h.n, j o h n) and leet (j0hn, 5arah)
    // collapsing to a known first or last name. Only flags when the
    // aggressive form differs from the canonical form (i.e. there's
    // actual evidence of evasion — otherwise Layer 4 already had a chance).
    let aggressive = aggressiveNormalizeForNameMatch(text)
    let canonicalTokens = canonical.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    let canonicalTokenSet = Set(canonicalTokens)
    let aggressiveTokens = aggressive.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    for token in aggressiveTokens {
        if ambiguousWords.contains(token) { continue }
        if safeCapitalizedWords.contains(token) { continue }
        let isName = commonNames.contains(token) || (commonLastNames.contains(token) && token.count >= 3)
        if !isName { continue }
        if canonicalTokenSet.contains(token) { continue }  // already had a chance via Layer 4
        return true
    }

    // Layer 6: Identifying-pattern keywords on canonicalized text.
    // The original loop ran identifyingPatterns against `lowered`, missing
    // fullwidth ("Ｉｎｓｔａｇｒａｍ ＠me") and confusable variants. Re-run
    // the same patterns against canonicalized text. (We already returned
    // true for any original-text match above; this only catches inputs
    // where the original missed due to non-ASCII evasion.)
    for pattern in identifyingPatterns {
        if canonical.contains(pattern) { return true }
    }

    return false
}

// Handle generation uses 8 hex chars from a UUID (16^8 ≈ 4 billion combinations).
// No Firestore uniqueness check is performed — collision probability is negligible
// at current scale. If the app grows significantly, consider adding a Firestore
// transaction that verifies uniqueness before committing the handle.
private let handleAdjectives = [
    "quiet", "still", "soft", "lost", "tired", "gentle", "fading", "sleepless",
    "distant", "hollow", "heavy", "broken", "wandering", "waiting", "restless",
    "silent", "lonely", "aching", "drifting", "numb", "awake", "unsaid", "almost",
    "barely", "dimly", "slowly", "sadly", "deeply", "half", "nearly"
]

private let handleNouns = [
    "ghost", "echo", "rain", "shadow", "light", "heart", "moon", "night",
    "storm", "drift", "flame", "cloud", "wave", "stone", "dust", "ember",
    "frost", "shore", "wound", "blur", "haze", "tide", "spark", "soul",
    "dream", "ache", "sigh", "dark", "glow", "void"
]

func generateUniqueHandle(attempt: Int = 0, completion: @escaping (String) -> Void) {
    guard attempt < 10 else {
        completion("anonymous_\(UUID().uuidString.prefix(8).lowercased())")
        return
    }
    let adj = handleAdjectives.randomElement() ?? "quiet"
    let noun = handleNouns.randomElement() ?? "ghost"
    let num = Int.random(in: 1...999)
    let candidate = "\(adj)_\(noun)_\(num)"

    Firestore.firestore().collection("users")
        .whereField("handle", isEqualTo: candidate)
        .limit(to: 1)
        .getDocuments { snapshot, _ in
            if let docs = snapshot?.documents, !docs.isEmpty {
                generateUniqueHandle(attempt: attempt + 1, completion: completion)
            } else {
                completion(candidate)
            }
        }
}

/// Native async variant of `generateUniqueHandle`. Used by sign-up paths
/// (Apple, Google, Email) where wrapping the callback version in a
/// continuation+TaskGroup race created a hang risk: if Firestore was
/// unreachable, the callback never fired, the wrapping Task leaked, and
/// the sign-up button's spinner stayed forever. Native async/await
/// participates in Task cancellation, so a `withTimeout(seconds:)`
/// wrapper actually aborts a stuck attempt.
///
/// On any Firestore error or cancellation, falls back to a UUID-based
/// handle — statistically unique without a network round-trip. On 10
/// candidate collisions in a row (vanishingly unlikely at current scale),
/// also falls back to UUID.
///
/// Total budget recommendation: wrap with `withTimeout(seconds: 5)` at
/// the call site so the worst-case sign-up handle assignment is bounded.
/// On timeout, the call site should also fall back to a UUID handle.
func generateUniqueHandleAsync(attempt: Int = 0) async -> String {
    guard attempt < 10 else {
        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
    }
    let adj = handleAdjectives.randomElement() ?? "quiet"
    let noun = handleNouns.randomElement() ?? "ghost"
    let num = Int.random(in: 1...999)
    let candidate = "\(adj)_\(noun)_\(num)"

    let snap: QuerySnapshot?
    do {
        snap = try await Firestore.firestore().collection("users")
            .whereField("handle", isEqualTo: candidate)
            .limit(to: 1)
            .getDocumentsAsync()
    } catch {
        // Network/permission/timeout — UUID fallback is statistically
        // unique with no further round-trip, which is what we want when
        // the backend is misbehaving during a sign-up flow.
        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
    }
    if Task.isCancelled {
        return "anonymous_\(UUID().uuidString.prefix(8).lowercased())"
    }
    if let docs = snap?.documents, !docs.isEmpty {
        return await generateUniqueHandleAsync(attempt: attempt + 1)
    }
    return candidate
}

func containsConcerningContent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return concerningPhrases.contains(where: { lowered.contains($0) })
}

// MARK: - Content Moderation

enum ContentViolationType {
    case slur
    case threat
    case sexual
    case spam
    case harassment
    case link
}

// Character-lookup tables precomputed at file scope so contentViolation(in:)
// doesn't rebuild them on every keystroke. These are small constants; sharing
// is safe and makes the hot path (normalizeForModeration runs on every typed
// character as the user composes) cheap.
private let moderationZeroWidthCharacters: Set<Character> = [
    "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"
]
private let moderationHomoglyphMap: [Character: Character] = [
    // Cyrillic lookalikes
    "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p",
    "\u{0441}": "c", "\u{0443}": "y", "\u{0445}": "x", "\u{0456}": "i",
    // Greek lookalikes
    "\u{0391}": "a", "\u{0392}": "b", "\u{0395}": "e", "\u{0397}": "h",
    "\u{0399}": "i", "\u{039A}": "k", "\u{039C}": "m", "\u{039D}": "n",
    "\u{039F}": "o", "\u{03A1}": "p", "\u{03A4}": "t", "\u{03A5}": "y",
]

private func normalizeForModeration(_ text: String) -> String {
    // Single-pass normalization:
    //   1. lowercase (Swift's Unicode-aware lowercase)
    //   2. strip zero-width characters
    //   3. fold homoglyphs to their ASCII lookalike
    // Previous implementation looped over 20 homoglyph pairs, each iteration
    // doing s.map(...).reduce("", +) — quadratic string concatenation per
    // pair, ~O(n² × 20) on the text length. On a 2000-character letter this
    // was roughly 80M operations, enough to cause visible typing lag while
    // composing. The current version is a single O(n) walk with O(1)
    // dictionary lookups per character.
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.lowercased() {
        if moderationZeroWidthCharacters.contains(scalar) { continue }
        if let replacement = moderationHomoglyphMap[scalar] {
            result.append(replacement)
        } else {
            result.append(scalar)
        }
    }
    return result
}

private func collapseForModeration(_ text: String) -> String {
    // Collapse runs of 3+ identical letters to 2: "niggggger" → "nigger", "faaag" → "faag"
    // Keeping 2 preserves double-letter words (e.g. "pass", "well") while defeating evasion.
    var result = ""
    var count = 0
    var last: Character = "\0"
    for char in text {
        if char == last && char.isLetter {
            count += 1
            if count <= 2 { result.append(char) }
        } else {
            count = 1
            last = char
            result.append(char)
        }
    }
    return result
}

private func stripSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: " ", with: "")
}

func contentViolation(in text: String) -> ContentViolationType? {
    let normalized = normalizeForModeration(text)
    let collapsed = collapseForModeration(normalized)
    let noSpaces = stripSpaces(normalized)
    let collapsedNoSpaces = stripSpaces(collapsed)

    // Check all four forms for maximum evasion resistance
    let forms = [normalized, collapsed, noSpaces, collapsedNoSpaces]

    // --- Slurs and hate speech ---
    let slurPatterns = [
        "n[i1!*]gg", "f[a@*]gg", "r[e3]t[a@]rd", "tr[a@]nny", "d[yi1]ke",
        "ch[i1]nk", "sp[i1]ck?", "k[i1]ke", "w[e3]tb[a@]ck", "g[o0][o0]k",
        "c[o0][o0]n", "towelhead", "raghead", "beaner", "zipperhead",
    ]
    for form in forms {
        for pattern in slurPatterns {
            if form.range(of: pattern, options: .regularExpression) != nil { return .slur }
        }
    }

    // --- Directed self-harm encouragement (not emotional venting) ---
    let harassmentPhrases = [
        "kill yourself", "kys", "go die", "you should die",
        "hope you die", "go hang yourself", "neck yourself",
        "drink bleach", "jump off a bridge",
        "nobody likes you", "everyone hates you",
        "the world is better without you",
        "you're worthless", "youre worthless",
        "you're pathetic", "youre pathetic",
        "you deserve to suffer", "you deserve to die",
        "go away and never come back",
        "no one will miss you", "noone will miss you",
    ]
    for phrase in harassmentPhrases {
        if normalized.contains(phrase) { return .harassment }
    }
    for phrase in harassmentPhrases {
        if noSpaces.contains(phrase.replacingOccurrences(of: " ", with: "")) { return .harassment }
    }

    // --- Threats and violence (targeted at others) ---
    let threatPhrases = [
        "kill you", "kill him", "kill her", "kill them",
        "shoot you", "shoot him", "shoot her", "shoot them", "shoot up",
        "stab you", "stab him", "stab her", "stab them",
        "bomb", "shoot up the", "blow up", "burn down",
        "rape you", "rape her", "rape him",
        "find you and", "find where you live", "know where you live",
        "hunt you down", "come for you",
        "gonna hurt you", "going to hurt you",
        "beat you", "beat the shit",
        "curb stomp", "slit your throat", "bash your",
        "put a bullet", "put you in the ground",
    ]
    for phrase in threatPhrases {
        if normalized.contains(phrase) { return .threat }
    }

    // --- Sexual content ---
    let sexualPatterns = [
        "porn", "hentai", "xxx", "onlyfans", "only fans",
        "nudes", "send nudes", "dick pic", "pussy pic",
        "jerk off", "jack off", "masturbat",
        "cum on", "cum in", "creampie",
        "blowjob", "blow job", "handjob", "hand job",
        "anal sex", "oral sex",
        "f[u\\*]ck me daddy", "choke me",
        "sex tape", "sextape", "sext me", "sexting",
        "nsfw", "r34", "rule34", "rule 34",
        "hook ?up", "booty ?call",
    ]
    for pattern in sexualPatterns {
        if normalized.range(of: pattern, options: .regularExpression) != nil { return .sexual }
    }

    // --- Spam ---
    let spamPhrases = [
        "buy now", "click here", "limited time", "act now",
        "free money", "make money", "earn money",
        "crypto", "bitcoin", "ethereum", "nft",
        "follow my", "check my bio", "link in bio",
        "discount code", "promo code", "use code",
        "dm me for", "dm for",
        "cashapp", "venmo me", "paypal me",
        "subscribe to", "check out my",
        "telegram", "whatsapp me",
    ]
    for phrase in spamPhrases {
        if normalized.contains(phrase) { return .spam }
    }

    // --- URL/link detection ---
    let urlPatterns = [
        "https?://", "www\\.", "\\.com/", "\\.net/", "\\.org/",
        "\\.io/", "\\.co/", "\\.me/", "\\.ly/",
        "bit\\.ly", "tinyurl", "linktr\\.ee",
    ]
    for pattern in urlPatterns {
        if normalized.range(of: pattern, options: .regularExpression) != nil { return .link }
    }
    // Bare domain pattern: word.tld (but not common false positives)
    let bareDomainExclusions = ["i.e", "e.g", "a.m", "p.m", "u.s", "mr.", "mrs.", "dr."]
    if normalized.range(of: "[a-z0-9]+\\.(com|net|org|io|co|app|xyz|gg|tv|me)\\b", options: .regularExpression) != nil {
        let hasFalsePositive = bareDomainExclusions.contains { normalized.contains($0) }
        if !hasFalsePositive { return .link }
    }

    return nil
}

func contentViolationMessage(for type: ContentViolationType) -> String {
    switch type {
    case .slur:
        return "this contains language that could hurt people. toska is a space for everyone."
    case .threat:
        return "this sounds like it could be threatening toward someone. toska is for expressing feelings, not directing harm."
    case .sexual:
        return "this contains sexual content that isn't appropriate for toska."
    case .spam:
        return "this looks like it might be spam or promotional content."
    case .harassment:
        return "this looks like it's directed at hurting someone. toska is for expressing your own feelings, not tearing others down."
    case .link:
        return "toska doesn't allow links. this is an anonymous space — keep it about the words."
    }
}

// MARK: - Shared Blocked Users Helper
