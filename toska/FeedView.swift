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

struct SelectedFeedPost: Identifiable, Hashable {
    let id: String
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let authorId: String
    let isLiked: Bool
    let isSaved: Bool
    let isReposted: Bool
}

@MainActor
struct FeedView: View {
    @ObservedObject var vm: FeedViewModel
    @State private var selectedFeedPost: SelectedFeedPost? = nil

    var body: some View {
            // Read all @Published properties that drive the view at the TOP
            // of body so SwiftUI registers the observation dependency before
            // entering lazy containers. vm.posts is used inside a LazyVStack
            // where SwiftUI may not track the read — capturing it here
            // guarantees a re-render when posts arrive from Firestore.
            let isRefreshing = vm.isRefreshing
            let dragOffset = vm.dragOffset
            let posts = vm.posts
            let hasLoadedOnce = vm.hasLoadedOnce
        return VStack(spacing: 0) {
                    // MARK: - Header
            HStack {
                            Text("toska")
                                .font(.custom("Georgia-Italic", size: 22))
                                .foregroundColor(LateNightTheme.handleText)
                            
                            Spacer()
                            
                            Button {
                                vm.showExplore = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 16, weight: .light))
                                    .foregroundColor(LateNightTheme.secondaryText)
                            }
                            .accessibilityLabel("Search")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
            
            // MARK: - Tab bar
            HStack(spacing: 6) {
                ForEach(0..<vm.tabs.count, id: \.self) { index in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.selectedTab = index
                        }
                    } label: {
                        Text(vm.tabs[index])
                            .font(.system(size: 13, weight: vm.selectedTab == index ? .semibold : .regular))
                            .foregroundColor(vm.selectedTab == index ? LateNightTheme.handleText : LateNightTheme.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(vm.selectedTab == index ? LateNightTheme.selectedPill : Color.clear)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            
            Rectangle()
                .fill(LateNightTheme.divider)
                .frame(height: 0.5)
            
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                            // LazyVStack so feed posts render only as they
                            // scroll into view — avoids eager construction of
                            // 60+ FeedPostRows on first load.
                            LazyVStack(spacing: 0) {
                                            Color.clear.frame(height: 0).id("feedTop")
                                ToskaRefreshHeader(
                                                                    isRefreshing: isRefreshing,
                                                                    triggerProgress: CGFloat(min(Double(dragOffset) / 80.0, 1.0))
                                                                )
                                                                .frame(height: isRefreshing ? 60 : max(0, CGFloat(dragOffset) - 10))
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
                                                        vm.fetchRecentPosts()
                                                    } label: {
                                                        Text("retry")
                                                            .font(.system(size: 11, weight: .semibold))
                                                    }
                                                }
                                                .foregroundColor(Color.toskaError)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .frame(maxWidth: .infinity)
                                                .background(Color.toskaError.opacity(0.06))
                                            }
                                // MARK: - Collapsed feed header
                                                    if vm.selectedTab == 0 {
                                                        FeedHeaderCard(vm: vm)
                                                    }
                    
                                if vm.selectedTab == 1 && vm.followingPosts.isEmpty {
                                                        VStack(spacing: 12) {
                                                            Text("\"the things we don't\nsay out loud still\nneed somewhere to go.\"")
                                                                .font(.custom("Georgia-Italic", size: 20))
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
                                            .foregroundColor(Color.toskaWarm)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity)
                                            .background(Color.toskaWarm.opacity(0.06))
                                        }
                    
                    
                                if posts.isEmpty && !hasLoadedOnce {
                                    ForEach(0..<6, id: \.self) { _ in
                                        SkeletonPostRow()
                                            .background(LateNightTheme.background)
                                    }
                                } else if posts.isEmpty && hasLoadedOnce && vm.selectedTab == 0 {
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
                                        Text("be the first one to say something.\nor go find someone who already did.")
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
                                                                                                                                    
                                                                                                                                    ForEach(posts) { post in
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
                                                                                                                                                                                handle: post.handle,
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
                                                                                                                                onSelectPost: {
                                                                                                                                    selectedFeedPost = SelectedFeedPost(
                                                                                                                                        id: post.id, handle: post.handle, text: post.text,
                                                                                                                                        tag: post.tag, likes: post.likes, reposts: post.reposts,
                                                                                                                                        replies: post.replies, time: post.time, authorId: post.authorId,
                                                                                                                                        isLiked: vm.likedPostIds.contains(post.id),
                                                                                                                                        isSaved: vm.savedPostIds.contains(post.id),
                                                                                                                                        isReposted: vm.repostedPostIds.contains(post.id)
                                                                                                                                    )
                                                                                                                                }
                                                                                                                                                                                                                                                                                )
                                                                                                                                                                                                                                                                                .id(post.id)
                                                                                                                                                                                                                                                             }
                                                                                        }
                    
                                        } // end else hasLoadedOnce

                                                            if vm.selectedTab == 0 && vm.hasMorePosts && !posts.isEmpty {
                                            ProgressView()
                                                .tint(Color.toskaBlue)
                                                .padding(.vertical, 20)
                                                .onAppear {
                                                    if !vm.isLoadingMore {
                                                        vm.loadMorePosts()
                                                    }
                                                }
                                        }
                    
                    if vm.selectedTab == 0 && !vm.hasMorePosts && !posts.isEmpty {
                                                                VStack(spacing: 4) {
                                                                    Text(vm.endedDueToBlocking
                                                                         ? "no more posts to show"
                                                                         : "youve read everything.")
                                                                        .font(.system(size: 10))
                                                                        .foregroundColor(LateNightTheme.tertiaryText)
                                                                    Text(vm.endedDueToBlocking
                                                                         ? "some posts are hidden"
                                                                                                                                                                                                                      : LateNightTheme.isLateNight
                                                                                                                                                                                                                         ? "try to sleep. or dont. were here either way."
                                                                                                                                                                                                                         : "close the app. or dont. well be here.")
                                                                        .font(.custom("Georgia-Italic", size: 10))
                                                                        .foregroundColor(LateNightTheme.tertiaryText.opacity(0.6))
                                                                }
                                                                .padding(.vertical, 20)
                                                            }
                    
                    Color.clear.frame(height: 80)
                }
            }
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
                                                            .simultaneousGesture(
                                                    DragGesture()
                                .onChanged { value in
                                                                    guard value.translation.height > 0 else { return }
                                                                    vm.dragOffset = value.translation.height
                                                                }
                                                                .onEnded { value in
                                                                    if value.translation.height > 80 && !isRefreshing {
                                        vm.isRefreshing = true
                                        HapticManager.play(.tabSwitch)
                                        Task { @MainActor in
                                            await vm.refreshAll()
                                            withAnimation(.easeOut(duration: 0.3)) {
                                                vm.isRefreshing = false
                                                vm.dragOffset = 0
                                            }
                                        }
                                    } else {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                            vm.dragOffset = 0
                                        }
                                    }
                                }
                        )
        }
        .background(LateNightTheme.background)
               .navigationDestination(item: $selectedFeedPost) { post in
                   PostDetailView(
                       postId: post.id,
                       handle: post.handle,
                       text: post.text,
                       tag: post.tag,
                       likes: post.likes,
                       reposts: post.reposts,
                       replies: post.replies,
                       time: post.time,
                       authorId: post.authorId,
                       isAlreadyLiked: post.isLiked,
                       isAlreadySaved: post.isSaved,
                       isAlreadyReposted: post.isReposted
                   )
                   .navigationBarHidden(true)
               }
               .accessibilityIdentifier("feedView")
               .onAppear {
                                  vm.dragOffset = 0
                                  vm.savedScrollPostId = nil
                                  if !hasLoadedOnce {
                                      if Auth.auth().currentUser != nil {
                                          vm.loadInitialData()
                                      }
                                  }
                              }
               .onReceive(NotificationCenter.default.publisher(for: .authDidVerify)) { _ in
                                  if !hasLoadedOnce {
                                      print("⚡️ AuthDidVerify received in FeedView — calling loadInitialData")
                                      vm.loadInitialData()
                                  }
                              }
               .sheet(isPresented: $vm.showExplore) {
                   ExploreView()
               }
        .fullScreenCover(isPresented: $vm.showPromptCompose) {
                            ComposeView(
                                initialText: "",
                                initialTag: vm.todaysPrompt.1
                            )
                            .onAppear { HapticManager.play(.compose) }
        }
        .fullScreenCover(isPresented: $vm.showDailyMoment) {
                    DailyMomentView()
                        .onAppear { HapticManager.play(.postAppear) }
                }
        .sheet(isPresented: $vm.showWitnessPost) {
                    if let witness = vm.witnessPost {
                        PostDetailView(
                            postId: witness.postId,
                            handle: witness.handle,
                            text: witness.text,
                            tag: witness.tag,
                            likes: 0,
                            reposts: 0,
                            replies: 0,
                            time: witness.timeString
                        )
                    }
                }
        .onReceive(NotificationCenter.default.publisher(for: .newPostCreated)) { _ in
            vm.handleNewPostCreated()
        }
        .onReceive(NotificationCenter.default.publisher(for: .postInteractionChanged)) { notif in
                    if let info = notif.userInfo {
                        vm.handleInteractionChanged(info)
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
                isShareable: data["isShareable"] as? Bool ?? true
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
        var onSelectPost: (() -> Void)? = nil
        
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
            @State private var showShareCard = false
        @State private var showReportSheet = false
        @State private var showBlockConfirm = false

    var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                // Handle row
                    HStack(spacing: 4) {
                                            Text(handle)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Color.toskaBlue)
                                            
                                            Text("·")
                                                .font(.system(size: 9))
                                                .foregroundColor(Color.toskaDivider)
                                            
                                            Text(time)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color.toskaTimestamp)
                                            
                                            Spacer()
                                            
                                            if isMidnightPost {
                                                Image(systemName: "moon.fill")
                                                    .font(.system(size: 8))
                                                    .foregroundColor(Color.toskaPurple.opacity(0.5))
                                            }
                                            
                                            if isWhisperPost {
                                                Image(systemName: "eye.slash")
                                                    .font(.system(size: 8))
                                                    .foregroundColor(Color.toskaPink.opacity(0.5))
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
                                                        .font(.system(size: 11))
                                                        .foregroundColor(Color.toskaTimestamp)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
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
                            .foregroundColor(Color.toskaGold)
                            
                            Text(text)
                                                            .font(.custom("Georgia", size: 15))
                                                            .foregroundColor(LateNightTheme.primaryText)
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
                                .foregroundColor(Color.toskaGold)
                            }
                            
                            Text(text)
                                                            .font(.custom("Georgia", size: 15))
                                                            .foregroundColor(LateNightTheme.primaryText)
                                                            .lineSpacing(4)
                                                            .multilineTextAlignment(.leading)
                        }
                        .padding(.bottom, 4)
                                            }
                                        }
                                        
                                        // Tag pill
                                        if let tag = tag {
                                            Text(tag)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(tagColor(for: tag).opacity(0.7))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(tagColor(for: tag).opacity(0.06))
                                                .cornerRadius(10)
                                                .padding(.bottom, 2)
                                                                                        }
                                        
                                        // GIF
                if let gifUrl = gifUrl, let url = URL(string: gifUrl) {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 200)
                                .cornerRadius(10)
                                .transition(.opacity)
                        case .failure:
                            // Distinguish a load failure from "still loading" so
                            // the user has a hint that something went wrong
                            // rather than staring at an empty box.
                            LateNightTheme.inputBackground
                                .frame(height: 120)
                                .cornerRadius(10)
                                .overlay(
                                    VStack(spacing: 4) {
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.system(size: 16, weight: .light))
                                        Text("couldn't load gif")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundColor(LateNightTheme.tertiaryText)
                                )
                        default:
                            LateNightTheme.inputBackground
                                .frame(height: 120)
                                .cornerRadius(10)
                                .overlay(ProgressView().scaleEffect(0.7).tint(LateNightTheme.tertiaryText))
                        }
                    }
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !postId.isEmpty { onSelectPost?() }
                    }
                }
                
                    // Action bar
                                    if !postId.isEmpty {
                                        HStack(spacing: 0) {
                                            // Left group: reply + repost
                                            Button {
                                                NotificationCenter.default.post(
                                                    name: .saveFeedScrollPosition,
                                                    object: nil,
                                                    userInfo: ["postId": postId]
                                                )
                                                onSelectPost?()
                                            } label: {
                                                actionLabel(icon: "bubble.left", count: replies, isActive: false)
                                            }
                                            .accessibilityLabel("Reply")
                                            .accessibilityValue(replies == 1 ? "1 reply" : "\(replies) replies")
                                            .buttonStyle(.plain)

                                            Spacer().frame(width: 28)

                                            Button { repostPost() } label: {
                                                actionLabel(icon: "arrow.2.squarepath", count: localRepostCount, isActive: isReposted, activeColor: "5a9e8f")
                                            }
                                            .accessibilityLabel(isReposted ? "Already reposted" : "Repost")
                                            .accessibilityValue(localRepostCount == 1 ? "1 repost" : "\(localRepostCount) reposts")
                                            .buttonStyle(.plain)
                                            .disabled(isRepostPost)
                                            .opacity(isRepostPost ? Toska.disabledOpacity : 1.0)

                                            Spacer()

                                            // Right group: share + bookmark + heart (thumb zone)
                                            if isShareable {
                                                Button { showShareCard = true } label: {
                                                    Image(systemName: "square.and.arrow.up")
                                                        .font(.system(size: 16, weight: .light))
                                                        .foregroundColor(Color.toskaDivider)
                                                }
                                                .accessibilityLabel("Share post")
                                                .buttonStyle(.plain)

                                                Spacer().frame(width: 28)
                                            }

                                            Button { toggleSave() } label: {
                                                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                                    .font(.system(size: 16, weight: .light))
                                                    .foregroundColor(isSaved ? Color.toskaBlue : Color.toskaDivider)
                                            }
                                            .accessibilityLabel(isSaved ? "Unsave post" : "Save post")
                                            .buttonStyle(.plain)

                                            Spacer().frame(width: 28)

                                            Button { toggleLike() } label: {
                                                actionLabel(icon: isLiked ? "heart.fill" : "heart", count: localLikeCount, isActive: isLiked, activeColor: "c47a8a")
                                            }
                                            .accessibilityLabel(isLiked ? "Unlike post" : "Like post")
                                            .accessibilityValue(localLikeCount == 1 ? "1 person felt this" : "\(localLikeCount) people felt this")
                                            .buttonStyle(.plain)
                                            .scaleEffect(likePulse ? 1.15 : 1.0)
                                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: likePulse)
                                        }
                                        .padding(.top, 12)
                                    }
                                }
                                            .padding(.horizontal, 16)
                                            .padding(.top, 14)
                                            .padding(.bottom, 12)
                                            .background(LateNightTheme.background)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                                            if !postId.isEmpty {
                                                                                NotificationCenter.default.post(
                                                                                    name: .saveFeedScrollPosition,
                                                                                    object: nil,
                                                                                    userInfo: ["postId": postId]
                                                                                )
                                    onSelectPost?()
                                }
                            }
                            .overlay(
                                Rectangle()
                                    .fill(LateNightTheme.divider)
                                    .frame(height: 0.5),
                                alignment: .bottom
                            )
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

                    Divider()

                    Button {
                        onSelectPost?()
                    } label: {
                        Label("open post", systemImage: "bubble.left")
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
                .sheet(isPresented: $showShareCard) {
                                    ShareCardView(text: text, handle: handle, feltCount: localLikeCount, tag: tag)
                                }
                                .sheet(isPresented: $showReportSheet) {
                                    ReportSheet(target: .post(
                                        postId: postId,
                                        authorId: authorId,
                                        authorHandle: handle,
                                        text: text
                                    ))
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
    
    func actionLabel(icon: String, count: Int, isActive: Bool, activeColor: String = "9198a8") -> some View {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .light))
                if count > 0 {
                    Text(formatCount(count))
                        .font(.system(size: 12))
                }
            }
            .foregroundColor(isActive ? Color(hex: activeColor) : Color.toskaDivider)
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
    
    
    // MARK: - Share
    
    func sharePost() {
            let cardView = ZStack {
                Color(hex: "0a0908")
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    // Tag pill
                    if let tag = tag {
                        HStack(spacing: 5) {
                            let tagData = sharedTags.first(where: { $0.name == tag })
                            Image(systemName: tagData?.icon ?? "tag")
                                .font(.system(size: 11))
                            Text(tag)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(tagColor(for: tag).opacity(0.6))
                        .padding(.bottom, 20)
                    }
                    
                    // Post text
                    Text(text)
                        .font(.custom("Georgia", size: 22))
                        .foregroundColor(.white.opacity(0.95))
                        .lineSpacing(8)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Spacer()
                    
                    // Social proof
                    if localLikeCount > 0 {
                        Text("\(formatCount(localLikeCount)) felt this")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.toskaPink.opacity(0.7))
                            .padding(.bottom, 8)
                    }
                    
                    // Handle
                                        Text("— someone on toska")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.2))
                                            .padding(.bottom, 24)
                    
                    // Branding
                    VStack(spacing: 4) {
                        Text("toska")
                            .font(.custom("Georgia-Italic", size: 18))
                            .foregroundColor(.white.opacity(0.15))
                        Text("say what you never said")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.08))
                    }
                    .padding(.bottom, 40)
                }
            }
            .frame(width: 1080 / 3, height: 1920 / 3)
                        .environment(\.colorScheme, .dark)
                        
                        let renderer = ImageRenderer(content: cardView)
            renderer.scale = 3.0
            
            if let image = renderer.uiImage {
                presentShareSheet(with: [image])
            }
        }
    
}
// MARK: - Collapsible Feed Header Card

@MainActor
struct FeedHeaderCard: View {
    @ObservedObject var vm: FeedViewModel
    @State private var isExpanded = false
    
    private var hasContent: Bool {
        !vm.emotionalWeather.isEmpty || vm.witnessPost != nil || !vm.mostUnsaidText.isEmpty || vm.hasDailyMoment
    }
    
    var body: some View {
        if hasContent {
            VStack(spacing: 0) {
                // Collapsed: just the prompt + tap to expand
                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                                } label: {
                                    HStack(spacing: 0) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(vm.promptTimeLabel)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.5))
                                                .tracking(0.5)
                                            
                                            Text(vm.todaysPrompt.0)
                                                .font(.custom("Georgia-Italic", size: 14))
                                                .foregroundColor(.white.opacity(0.9))
                                                .lineLimit(isExpanded ? nil : 2)
                                                .multilineTextAlignment(.leading)
                                        }
                                        
                                        Spacer()
                                        
                                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .light))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color.toskaBlue)
                                    .cornerRadius(12)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                }
                                .buttonStyle(.plain)
                
                // Expanded content
                if isExpanded {
                    VStack(spacing: 0) {
                        Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                        
                        // Prompt respond button
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
                        
                        // Daily moment
                        if vm.hasDailyMoment {
                            Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                            Button { vm.showDailyMoment = true } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.toskaWarm)
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
                        if let witness = vm.witnessPost {
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
                        
                        // Most unsaid
                        if !vm.mostUnsaidText.isEmpty {
                            Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("most unsaid today")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Color.toskaBlue)
                                    Spacer()
                                    Text("\(formatCount(vm.mostUnsaidLikes)) felt this")
                                        .font(.system(size: 10))
                                        .foregroundColor(LateNightTheme.tertiaryText)
                                }
                                Text(vm.mostUnsaidText)
                                    .font(.custom("Georgia", size: 13))
                                    .foregroundColor(LateNightTheme.primaryText)
                                    .lineSpacing(3)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                }
                
                Rectangle().fill(LateNightTheme.divider).frame(height: 0.5)
            }
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

// MARK: - Skeleton Post Row

struct SkeletonPostRow: View {
    @State private var shimmer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LateNightTheme.divider)
                    .frame(width: 100, height: 11)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LateNightTheme.divider)
                    .frame(width: 28, height: 11)
                Spacer()
            }
            .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LateNightTheme.divider)
                    .frame(maxWidth: .infinity)
                    .frame(height: 13)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LateNightTheme.divider)
                    .frame(maxWidth: .infinity)
                    .frame(height: 13)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LateNightTheme.divider)
                    .frame(width: 160, height: 13)
            }
            .padding(.bottom, 12)
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LateNightTheme.divider)
                        .frame(width: 28, height: 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(LateNightTheme.divider.opacity(0.4))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .opacity(shimmer ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
            }
        }

// MARK: - Shared Tag Data

struct TagItem {
    let name: String
    let colorHex: String
    let icon: String
}

let sharedTags: [TagItem] = [
    TagItem(name: "longing", colorHex: "9198a8", icon: "moon.stars"),
    TagItem(name: "anger", colorHex: "c45c5c", icon: "flame"),
    TagItem(name: "regret", colorHex: "8b7ec8", icon: "arrow.uturn.backward"),
    TagItem(name: "acceptance", colorHex: "6ba58e", icon: "leaf"),
    TagItem(name: "confusion", colorHex: "c49a6c", icon: "questionmark.circle"),
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

func timeOfDayLabel() -> String {
    let hour = Calendar.current.component(.hour, from: Date())
    if hour >= 22 || hour < 5 { return "tonight" }
    else if hour < 12 { return "this morning" }
    else if hour < 17 { return "this afternoon" }
    else { return "this evening" }
}

// MARK: - Tag Color

func tagColor(for tag: String) -> Color {
    switch tag {
    case "longing": return Color.toskaBlue
    case "anger": return Color.toskaError
    case "regret": return Color.toskaPurple
    case "acceptance": return Color.toskaGreen
    case "confusion": return Color.toskaWarm
    case "unsent": return Color(hex: "7a97b5")
    case "moving on": return Color.toskaTeal
    case "still love you": return Color.toskaPink
    default: return Color.toskaBlue
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

let explicitCrisisPhrases = [
    "kill myself", "end my life", "end it all", "take my own life",
    "want to die", "wish i was dead", "wish i wasn't here", "better off dead",
    "hurt myself", "want to hurt myself", "self harm", "self-harm",
    "don't want to wake up", "don't want to be here", "don't want to exist",
    "want to disappear",
]

let softConcernPhrases = [
    "can't go on", "no reason to live", "no point anymore",
    "nobody cares", "disappear forever", "not worth it",
    "give up on everything", "better off without me",
    "no one would care", "no one would notice", "can't do this anymore",
    "done with life", "want it to stop", "want it all to end",
    "nothing left", "not worth living", "why am i still here",
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
        "lives in", "lives on", "address",
    ]
    let lowered = text.lowercased()
    for pattern in identifyingPatterns { if lowered.contains(pattern) { return true } }
    if text.range(of: "@[a-zA-Z]", options: .regularExpression) != nil { return true }
    let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let sentenceStarters: Set<String> = Set(sentences.compactMap { sentence in
        sentence.components(separatedBy: CharacterSet.alphanumerics.inverted).first(where: { !$0.isEmpty })
    })
    let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    for word in words {
        let lower = word.lowercased()
        if lower.count < 3 { continue }
        if ambiguousWords.contains(lower) { continue }
        if commonNames.contains(lower) {
            if word.first?.isUppercase == true {
                if sentenceStarters.contains(word) { continue }
                return true
            }
        }
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
    digitStripped = digitStripped
            .replacingOccurrences(of: "\\d{1,2}[:/]\\d{2}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{4,5}\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d{1,3}\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\$[\\d,]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\d{1,2}/\\d{1,2}/\\d{2,4}", with: "", options: .regularExpression)
        let digits = digitStripped.filter { $0.isNumber }
        if digits.count >= 10 { return true }
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

func containsConcerningContent(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return concerningPhrases.contains(where: { lowered.contains($0) })
}

// MARK: - Shared Blocked Users Helper
