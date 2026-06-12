import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseAppCheck
@preconcurrency import FirebaseFirestore



@MainActor
struct ProfileView: View {
    @State private var selectedTab = 0
    // Tabs whose data has been fetched (lazy-load — see onAppear / loadTabIfNeeded).
    @State private var loadedTabs: Set<Int> = []
    @State private var showSettings = false
    @State private var userHandle = "anonymous"
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var totalLikes = 0
    @State private var postCount = 0
    @State private var joinedDate = ""
    @State private var myPosts: [MyPost] = []
    @State private var savedPosts: [SavedPost] = []
    @State private var savedReplies: [SavedReply] = []
    @State private var myReplies: [MyReply] = []
    @State private var likedPosts: [SavedPost] = []
    @State private var likedReplies: [LikedReply] = []
    @State private var selectedPostId: String? = nil
    @State private var selectedPostData: PostDetailData? = nil
    @State private var showPost = false
    @State private var showEditReply = false
    @State private var editReplyText = ""
    @State private var editReplyId = ""
    @State private var editReplyPostId = ""
    @State private var showDeleteReplyAlert = false
    @State private var deleteReplyId = ""
    @State private var deleteReplyPostId = ""
    // Surfaced when deleteReply fails. Was previously a silent no-op — the
    // row stayed on screen with no indication the delete failed.
    @State private var deleteReplyError: String? = nil
    @State private var hasFetchedInitial = false
    @State private var presenceStreak = 0
    @State private var totalNights = 0
    // Gates the streak-share button while ImageRenderer rasterizes. Mirrors
    // the isRendering pattern in ShareCardView — ImageRenderer is @MainActor
    // and blocks the main thread during render, so without feedback the user
    // taps share and the app appears frozen.
    @State private var isStreakRendering = false
    
    // Each tuple is (inactive icon, active icon) for the profile tab bar.
    // SF Symbols `note.text` has no filled pair, so we substitute
    // `text.document` (outlined) → `text.document.fill` (filled) to match the
    // heart/bookmark pattern and give the first tab a visible active state.
    let tabIcons = [
        ("text.document", "text.document.fill"),
        ("heart", "heart.fill"),
        ("bookmark", "bookmark.fill"),
        ("bubble.left", "bubble.left.fill"),
        ("arrow.2.squarepath", "arrow.2.squarepath"),
    ]
    // VoiceOver labels for the icon-only profile tabs, index-aligned with
    // tabIcons (posts / liked / saved / replies / reposts).
    let tabAccessibilityLabels = ["posts", "liked", "saved", "replies", "reposts"]
    var avatarInitial: String {
        let cleaned = userHandle.replacingOccurrences(of: "anonymous_", with: "")
        return String(cleaned.prefix(1)).uppercased()
    }
    
    var avatarColor: Color {
        let colors: [Color] = [
            Color.toskaBlue, Color.toskaMidnightPurple, Color.toskaFollowGreen,
            Color.toskaWhisperPink, Color.toskaAccentTan, Color.toskaUnsentBlue,
            Color.toskaMovingOnGreen, Color.toskaErrorRed
        ]
        var hash: UInt64 = 5381
        for char in userHandle.utf8 {
            hash = hash &* 33 &+ UInt64(char)
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
    
    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Profile root tab — large bold handle as the title via
                // ToskaHeader, with messages + settings icons in the
                // trailing slot. No back chevron (root tab).
                ToskaHeader(title: "profile", onBack: nil) {
                    // Messages envelope removed when DMs were cut. Only
                    // settings remains in the trailing slot.
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(ToskaColor.text)
                    }
                    .accessibilityLabel("settings")
                }
                
                ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                                    // Top-of-list anchor — used by the
                                    // tap-active-tab-to-scroll-to-top pattern
                                    // (MainTabView posts scrollProfileToTop
                                    // when the user re-taps the profile tab).
                                    Color.clear.frame(height: 0).id("top")
                                    VStack(alignment: .leading, spacing: 0) {
                                        // Identity — eyebrow + large serif handle
                                        // + the anonymity bio line. Reads quiet and
                                        // editorial; no follower/stat chrome (the
                                        // anonymity is the point).
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("anonymous")
                                                .font(ToskaFont.eyebrow)
                                                .textCase(.uppercase)
                                                .tracking(1.4)
                                                .foregroundColor(ToskaColor.text3)

                                            Text("@\(userHandle)")
                                                .font(ToskaFont.serifMedium(22))
                                                .tracking(-0.4)
                                                .foregroundColor(ToskaColor.text)

                                            Text("no name, no face. just the things you needed to say.")
                                                .font(ToskaFont.serifItalic(14))
                                                .foregroundColor(ToskaColor.text2)
                                                .lineSpacing(3)
                                                .fixedSize(horizontal: false, vertical: true)

                                            // Joined date (Twitter-style) — calendar + month/year.
                                            HStack(spacing: 5) {
                                                Image(systemName: "calendar")
                                                    .font(.system(size: 11, weight: .medium))
                                                Text("joined \(joinedDate.lowercased())")
                                                    .font(.system(size: 12.5, weight: .regular))
                                            }
                                            .foregroundColor(ToskaColor.text3)
                                            .padding(.top, 2)

                                            // Following / followers stats — both tappable to
                                            // their lists (the user asked for the Twitter-style
                                            // row). Count bold in the text color, label muted.
                                            HStack(spacing: 18) {
                                                NavigationLink(destination: FollowListView(title: "following").navigationBarHidden(true)) {
                                                    HStack(spacing: 4) {
                                                        Text("\(followingCount)")
                                                            .font(.system(size: 13.5, weight: .bold))
                                                            .foregroundColor(ToskaColor.text)
                                                        Text("following")
                                                            .font(.system(size: 13.5, weight: .regular))
                                                            .foregroundColor(ToskaColor.text2)
                                                    }
                                                }
                                                NavigationLink(destination: FollowListView(title: "followers").navigationBarHidden(true)) {
                                                    HStack(spacing: 4) {
                                                        Text("\(followerCount)")
                                                            .font(.system(size: 13.5, weight: .bold))
                                                            .foregroundColor(ToskaColor.text)
                                                        Text("followers")
                                                            .font(.system(size: 13.5, weight: .regular))
                                                            .foregroundColor(ToskaColor.text2)
                                                    }
                                                }
                                            }
                                            .padding(.top, 4)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 6)
                                        .padding(.bottom, 18)
                        
                                        HStack(spacing: 0) {
                                            ForEach(0..<tabIcons.count, id: \.self) { index in
                                                Button {
                                                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = index }
                                                } label: {
                                                    VStack(spacing: 9) {
                                                        Image(systemName: selectedTab == index ? tabIcons[index].1 : tabIcons[index].0)
                                                            .font(.system(size: 18, weight: selectedTab == index ? .medium : .regular))
                                                            .foregroundColor(selectedTab == index ? ToskaColor.handle : ToskaColor.time)
                                                        Rectangle()
                                                            .fill(selectedTab == index ? ToskaColor.handle : Color.clear)
                                                            .frame(width: 26, height: 2)
                                                    }
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.top, 13)
                                                }
                                                .accessibilityLabel(tabAccessibilityLabels[index])
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .overlay(
                                            Rectangle().fill(ToskaColor.divider).frame(height: 1),
                                            alignment: .bottom
                                        )
                                        // Breathing room between the tab underline/divider
                                        // and the first content card below it.
                                        .padding(.bottom, 10)

                                        switch selectedTab {
                                                                case 0:
                                                                    let authoredPosts = myPosts.filter { !$0.isRepost }
                                                                    if authoredPosts.isEmpty {
                                                                        emptyState(icon: "square.and.pencil", title: "nothing here yet.", subtitle: "say the thing you cant say anywhere else.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(authoredPosts) { post in
                                                                                Button { openMyPost(post) } label: {
                                                                                    VStack(alignment: .leading, spacing: 0) {
                                                                                        if post.pendingReview {
                                                                                            PendingReviewBanner(reasonLabel: post.pendingReasonLabel, isCrisis: post.pendingReasonIsCrisis)
                                                                                        }
                                                                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: Auth.auth().currentUser?.uid ?? "", isRepostPost: post.isRepost)
                                                                                    }
                                                                                }
                                                                                .buttonStyle(.plain)
                                                                            }
                                                                            // The fetch caps at 50 posts COMBINED (authored +
                                                                            // reposts), so key the truncation note on the full
                                                                            // myPosts count, not the filtered authored subset —
                                                                            // otherwise it never shows for users who repost.
                                                                            if myPosts.count >= 50 {
                                                                                Text("showing your 50 most recent posts")
                                                                                    .font(.system(size: 9)).foregroundColor(Color.toskaPlaceholderGray)
                                                                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                                                            }
                                                                        }
                                                                    }
                                                                case 4:
                                                                    let repostItems = myPosts.filter { $0.isRepost }
                                                                    if repostItems.isEmpty {
                                                                        emptyState(icon: "arrow.2.squarepath", title: "no reposts yet.", subtitle: "when something says it better than you could, repost it.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(repostItems) { post in
                                                                                Button { openMyPost(post) } label: {
                                                                                    VStack(alignment: .leading, spacing: 0) {
                                                                                        HStack(spacing: 4) {
                                                                                            Image(systemName: "arrow.2.squarepath")
                                                                                                .font(.system(size: 9))
                                                                                            Text("you reposted")
                                                                                                .font(.system(size: 10, weight: .medium))
                                                                                        }
                                                                                        .foregroundColor(Color.toskaMovingOnGreen)
                                                                                        .padding(.horizontal, 16)
                                                                                        .padding(.top, 8)
                                                                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: Auth.auth().currentUser?.uid ?? "", isRepostPost: post.isRepost)
                                                                                    }
                                                                                }
                                                                                .buttonStyle(.plain)
                                                                            }
                                                                        }
                                                                    }
                                                                case 1:
                                                                    let likedItems = mergedLikedItems
                                                                    if likedItems.isEmpty {
                                                                        emptyState(icon: "heart", title: "nothing felt yet.", subtitle: "youll know it when you see it.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(likedItems) { item in
                                                                                switch item {
                                                                                case .post(let post):
                                                                                    Button { openSavedPost(post) } label: {
                                                                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id)
                                                                                    }
                                                                                    .buttonStyle(.plain)
                                                                                case .reply(let liked):
                                                                                    Button { openLikedReply(liked) } label: {
                                                                                        ReplyEngagementRow(handle: liked.replyHandle, text: liked.replyText, time: liked.likedAt)
                                                                                    }
                                                                                    .buttonStyle(.plain)
                                                                                }
                                                                            }
                                                                            if likedItems.count >= 100 {
                                                                                Text("showing your most recent likes")
                                                                                    .font(.system(size: 9)).foregroundColor(Color.toskaPlaceholderGray)
                                                                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                                                            }
                                                                        }
                                                                    }
                                                                case 2:
                                                                    let items = mergedSavedItems
                                                                    if items.isEmpty {
                                                                        emptyState(icon: "bookmark", title: "nothing saved.", subtitle: "some things are worth keeping.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(items) { item in
                                                                                switch item {
                                                                                case .post(let post):
                                                                                    Button { openSavedPost(post) } label: {
                                                                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id)
                                                                                    }
                                                                                    .buttonStyle(.plain)
                                                                                case .reply(let saved):
                                                                                    Button { openSavedReply(saved) } label: {
                                                                                        ReplyEngagementRow(handle: saved.replyHandle, text: saved.replyText, time: saved.savedAt)
                                                                                    }
                                                                                    .buttonStyle(.plain)
                                                                                }
                                                                            }
                                                                            if items.count >= 100 {
                                                                                Text("showing your most recent saves")
                                                                                    .font(.system(size: 9)).foregroundColor(Color.toskaPlaceholderGray)
                                                                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                                                            }
                                                                        }
                                                                    }
                                                                case 3:
                                                                    if myReplies.isEmpty {
                                                                        emptyState(icon: "arrowshape.turn.up.left", title: "no replies yet.", subtitle: "say something back to someone who needed it.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(myReplies) { reply in
                                                                                replyRow(reply)
                                                                            }
                                                                            if myReplies.count >= 30 {
                                                                                Text("showing your most recent replies")
                                                                                    .font(.system(size: 9)).foregroundColor(Color.toskaPlaceholderGray)
                                                                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                                                            }
                                                                        }
                                                                    }
                                                                default: EmptyView()
                                                                }

                        Color.clear.frame(height: 80)
                    }
                }
                .refreshable {
                                    loadProfile()
                                    switch selectedTab {
                                    case 0: loadMyPosts()
                                    case 1:
                                        loadLikedPosts()
                                        loadLikedReplies()
                                    case 2:
                                        loadSavedPosts()
                                        loadSavedReplies()
                                    case 3:
                                        loadMyReplies()
                                    default: break
                                    }
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                }
                .onReceive(NotificationCenter.default.publisher(for: .scrollProfileToTop)) { _ in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                } // end ScrollViewReader
            }
        }
        .navigationDestination(isPresented: $showSettings) { SettingsView() }
        .navigationDestination(isPresented: $showPost) {
                            if let postData = selectedPostData, let postId = selectedPostId {
                                PostDetailView(postId: postId, handle: postData.handle, text: postData.text, tag: postData.tag, likes: postData.likes, reposts: postData.reposts, replies: postData.replies, time: postData.time, authorId: postData.authorId)
                                    .navigationBarHidden(true)
                            }
                        }
        .navigationDestination(isPresented: $showEditReply) {
            EditReplyView(postId: editReplyPostId, replyId: editReplyId, replyText: $editReplyText) {
                if let idx = myReplies.firstIndex(where: { $0.id == editReplyId }) {
                    let old = myReplies[idx]
                    myReplies[idx] = MyReply(id: old.id, replyText: editReplyText, replyTime: old.replyTime, parentText: old.parentText, parentHandle: old.parentHandle, parentPostId: old.parentPostId, createdAt: old.createdAt)
                }
            }
            .navigationBarHidden(true)
            .hidesAppTabBar()
        }
        .alert("delete this reply?", isPresented: $showDeleteReplyAlert) {
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) {
                deleteReply(replyId: deleteReplyId, postId: deleteReplyPostId)
            }
        } message: {
            Text("this is permanent.")
        }
        // Failure feedback for deleteReply. Bound to a Bool projection of
        // the optional error string so SwiftUI dismisses the alert when
        // the user taps OK (which sets the underlying string back to nil).
        .alert(
            "couldn't delete",
            isPresented: Binding(
                get: { deleteReplyError != nil },
                set: { if !$0 { deleteReplyError = nil } }
            ),
            presenting: deleteReplyError
        ) { _ in
            Button("ok", role: .cancel) { deleteReplyError = nil }
        } message: { error in
            Text(error)
        }
        .onAppear {
                    if !hasFetchedInitial {
                        hasFetchedInitial = true
                        // IMPROVE (2026-06-11): lazy-load tabs. Previously all six
                        // datasets (posts + liked posts/replies + saved posts/replies
                        // + my replies) were fetched on every profile open — most
                        // users only look at their posts. Now only the default
                        // (posts) tab loads up front; the others load on first
                        // switch via loadTabIfNeeded, cutting profile-open reads
                        // substantially for the common case.
                        loadMyPosts()
                        loadedTabs = [0]
                        ensurePresenceThenLoadStreak()
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            reconcileCountsIfNeeded()
                        }
                    }
                    loadProfile()
                }
        .onChange(of: selectedTab) { _, newValue in
            loadTabIfNeeded(newValue)
        }
        // Reset on sign-out so any in-flight ProfileView state from the
        // previous account doesn't blend into the next user's UI when
        // MainTabView remounts. hasFetchedInitial=false re-arms the
        // onAppear fetches; clearing the local arrays avoids a flash of
        // the previous account's posts before the fresh fetches land.
        .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
            hasFetchedInitial = false
            loadedTabs = []
            myPosts = []
            likedPosts = []
            likedReplies = []
            savedPosts = []
            savedReplies = []
            myReplies = []
            postCount = 0
            followerCount = 0
            followingCount = 0
            totalLikes = 0
            presenceStreak = 0
            totalNights = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                    showSettings = false
                    showEditReply = false
                }
    }
    
    func ensurePresenceThenLoadStreak() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let today = ToskaFormatters.dateKey.string(from: Date())
        db.collection("users").document(uid).collection("presence").document(today).setData([
            "date": today, "createdAt": FieldValue.serverTimestamp()
        ], merge: true) { _ in
            Task { @MainActor in loadPresenceStreak() }
        }
    }
    
    func loadPresenceStreak() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid).collection("presence")
            .order(by: "date", descending: true).limit(to: 365)
            .getDocuments { snapshot, _ in
                Task { @MainActor in
                    guard let docs = snapshot?.documents else { return }
                    // Cross-session guard (2026-06-01 audit): don't paint a
                    // prior account's streak onto a new session if the account
                    // switched while this query was in flight.
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    totalNights = docs.count
                    let calendar = Calendar.current
                    var streak = 0
                    var checkDate = calendar.startOfDay(for: Date())
                    let dateStrings = Set(docs.compactMap { $0.data()["date"] as? String })
                    while true {
                        let dateString = ToskaFormatters.dateKey.string(from: checkDate)
                        if dateStrings.contains(dateString) {
                            streak += 1
                            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
                            checkDate = prev
                        } else { break }
                    }
                    presenceStreak = streak
                }
            }
    }
    
    func openMyPost(_ post: MyPost) {
        guard !post.id.isEmpty else { return }
        Firestore.firestore().collection("posts").document(post.id).getDocument { snapshot, _ in
            Task { @MainActor in
                guard snapshot?.data() != nil else { myPosts.removeAll { $0.id == post.id }; return }
                let uid = Auth.auth().currentUser?.uid ?? ""
                selectedPostId = post.id
                selectedPostData = PostDetailData(handle: userHandle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, authorId: uid)
                showPost = true
            }
        }
    }
    
    func openSavedPost(_ post: SavedPost) {
        guard !post.id.isEmpty else { return }
        let db = Firestore.firestore()
        db.collection("posts").document(post.id).getDocument { snapshot, _ in
            Task { @MainActor in
                guard let data = snapshot?.data() else {
                    if let uid = Auth.auth().currentUser?.uid {
                        db.collection("users").document(uid).collection("saved").document(post.id).delete()
                        db.collection("users").document(uid).collection("liked").document(post.id).delete()
                    }
                    savedPosts.removeAll { $0.id == post.id }
                    likedPosts.removeAll { $0.id == post.id }
                    return
                }
                let authorId = data["authorId"] as? String ?? ""
                selectedPostId = post.id
                selectedPostData = PostDetailData(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, authorId: authorId)
                showPost = true
            }
        }
    }
    
    func replyRow(_ reply: MyReply) -> some View {
        Button {
            if !reply.parentPostId.isEmpty {
                selectedPostId = reply.parentPostId
                selectedPostData = PostDetailData(handle: reply.parentHandle, text: reply.parentText, tag: nil, likes: 0, reposts: 0, replies: 0, time: "", authorId: "")
                showPost = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 8))
                    Text("replying to \(reply.parentHandle)").font(.system(size: 10, weight: .medium))
                    Text("·").font(.system(size: 8)).foregroundColor(Color.toskaDivider)
                    Text(reply.replyTime).font(.system(size: 10, weight: .light)).foregroundColor(Color.toskaInactiveGray)
                }.foregroundColor(Color.toskaTextLight)
                
                Text(reply.parentText)
                    .font(.system(size: 11))
                    .foregroundColor(Color.toskaTimestamp)
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .overlay(
                        Rectangle()
                            .fill(Color.toskaDivider)
                            .frame(width: 1.5),
                        alignment: .leading
                    )
                
                Text(reply.replyText)
                    .font(ToskaFont.serif(14))
                    .foregroundColor(Color.toskaTextDark)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(LateNightTheme.background)
            .overlay(Rectangle().fill(LateNightTheme.divider).frame(height: 0.5), alignment: .bottom)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editReplyId = reply.id
                editReplyPostId = reply.parentPostId
                editReplyText = reply.replyText
                showEditReply = true
            } label: {
                Label("edit reply", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteReplyId = reply.id
                deleteReplyPostId = reply.parentPostId
                showDeleteReplyAlert = true
            } label: {
                Label("delete reply", systemImage: "trash")
            }
        }
    }
    
    func deleteReply(replyId: String, postId: String) {
            guard !replyId.isEmpty, !postId.isEmpty else { return }
            // Counter decrement is handled server-side by the
            // onReplyDeletedUpdateCount Cloud Function (functions/index.js).
            // The previous client transaction also tried to write replyCount
            // on the parent post — but the post update rule only permits the
            // post author, so it failed permission_denied for replies on
            // other people's posts (silently aborting the whole transaction
            // and leaving the reply in place). The new rule additionally
            // blocks counter writes from any client; doing the delete as a
            // plain document delete lets the server-side trigger keep the
            // count consistent without a permission fight.
            Firestore.firestore()
                .collection("posts").document(postId)
                .collection("replies").document(replyId)
                .delete { error in
                    Task { @MainActor in
                        if let error = error {
                            // Surface the failure so the row doesn't silently
                            // stay on screen as if nothing happened. Previously
                            // a delete failure (network drop, permission edge
                            // case) was logged nowhere and the user had no
                            // signal that their delete didn't take effect.
                            print("⚠️ deleteReply failed: \(error)")
                            Telemetry.recordError(error, context: "ProfileView.deleteReply")
                            deleteReplyError = "couldn't delete — try again"
                        } else {
                            myReplies.removeAll { $0.id == replyId }
                        }
                    }
                }
        }
    
    func emptyState(icon: String = "tray", title: String, subtitle: String) -> some View {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundColor(Color.toskaBlue.opacity(0.4))
                    .padding(.bottom, 2)
                Text(title)
                    .font(ToskaFont.serifItalic(18))
                    .foregroundColor(Color.toskaTextLight)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color.toskaDivider)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    
    func shareStreak() {
        guard !isStreakRendering else { return }
        isStreakRendering = true
        // Yield one frame so SwiftUI can paint the disabled/spinner state
        // before ImageRenderer blocks main for the rasterize. Mirrors the
        // withRenderIndicator helper in ShareCardView.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            shareStreakRender()
            isStreakRendering = false
        }
    }

    private func shareStreakRender() {
        let streakLabel = presenceStreak > 1 ? "\(presenceStreak) nights in a row" : ""

        let cardView = ZStack {
            Color.toskaNearBlack
            
            VStack(spacing: 0) {
                Spacer()
                
                Image(systemName: "moon.stars")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(Color.toskaBlue)
                    .padding(.bottom, 16)
                
                Text("i've been on toska")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.bottom, 4)
                
                Text("\(totalNights) \(totalNights == 1 ? "night" : "nights")")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)
                
                if !streakLabel.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "flame")
                            .font(.system(size: 10))
                        Text(streakLabel)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color.toskaAccentTan)
                    .padding(.bottom, 8)
                }
                
                Text("saying what i never said")
                    .font(ToskaFont.serifItalic(13))
                    .foregroundColor(.white.opacity(0.25))
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("toska")
                        .font(ToskaFont.serifItalic(18))
                        .foregroundColor(.white.opacity(0.15))
                    Text("for the things you cant say out loud")
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
    
    // MARK: - Data Loading
    
    func loadProfile() {
           guard let uid = Auth.auth().currentUser?.uid else { return }
           let db = Firestore.firestore()
           Task { @MainActor in
               do {
                   let snapshot = try await db.collection("users").document(uid).getDocumentAsync()
                   // Re-check auth between the captured uid and the live one before
                   // writing to @State. If the user signed out and a different user
                   // signed in while this fetch was in flight (Tab A sign-out, Tab B
                   // sign-in within a single SwiftUI body update), the previous
                   // user's profile data would otherwise briefly land in the new
                   // user's UI before their own fetch caught up. Mirrors the
                   // listener-callback pattern applied across the app.
                   guard Auth.auth().currentUser?.uid == uid else { return }
                   guard let data = snapshot.data() else { return }
                   userHandle = data["handle"] as? String ?? "anonymous"
                   followerCount = data["followerCount"] as? Int ?? 0
                   followingCount = data["followingCount"] as? Int ?? 0
                   totalLikes = data["totalLikes"] as? Int ?? 0
                   if let timestamp = data["createdAt"] as? Timestamp {
                       joinedDate = ToskaFormatters.monthYear.string(from: timestamp.dateValue())
                   }
                   let postSnap = try? await db.collection("posts")
                       .whereField("authorId", isEqualTo: uid)
                       .count.getAggregation(source: .server)
                   guard Auth.auth().currentUser?.uid == uid else { return }
                   postCount = Int(truncating: postSnap?.count ?? 0)
               } catch {
                   print("⚠️ loadProfile failed: \(error)")
               }
           }
       }
    
    func reconcileCountsIfNeeded() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let lastKey = UserDefaultsKeys.lastReconcileDate(uid: uid)
            // 24h gate. abs() guards against clock skew — if the user's
            // device clock jumped backwards (manual change, NTP correction,
            // timezone fiddling), `Date().timeIntervalSince(lastReconcile)`
            // could be negative and pass the < 86400 check forever, leaving
            // the user permanently unable to reconcile. abs() makes the gate
            // equivalent to "more than 24h have *elapsed* in either direction
            // since last reconcile" which is the actual intent.
            if let lastReconcile = UserDefaults.standard.object(forKey: lastKey) as? Date,
               abs(Date().timeIntervalSince(lastReconcile)) < 86400 { return }

            // Reconciliation now runs server-side via the reconcileMyCounts
            // Cloud Function. Previously the client did the count() and
            // wrote followerCount/followingCount to its own user doc — the
            // numbers shown to other users were essentially client-supplied.
            // The endpoint requires both an App Check token and a Firebase
            // ID token, then reads/writes via Admin SDK so it doesn't
            // depend on the user-doc rule allowing self-writes.
            Task { @MainActor in
                // Derive the project from the running FirebaseApp so Debug/
                // staging builds hit their own reconcileMyCounts instead of
                // cross-calling prod (toska-4ebf4). Fail safe if unavailable.
                guard let projectID = FirebaseApp.app()?.options.projectID else {
                    print("⚠️ reconcileMyCounts: no FirebaseApp projectID; skipping")
                    return
                }
                guard let endpoint = URL(string: "https://us-central1-\(projectID).cloudfunctions.net/reconcileMyCounts") else { return }
                guard let idToken = try? await Auth.auth().currentUser?.getIDToken() else { return }
                let appCheckToken: String?
                do {
                    appCheckToken = try await AppCheck.appCheck().token(forcingRefresh: false).token
                } catch {
                    print("⚠️ reconcileMyCounts: app check token fetch failed: \(error)")
                    return
                }

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
                if let appCheckToken {
                    request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
                }

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    // Same uid-recheck as loadProfile — the request can take
                    // seconds, and a sign-out/sign-in race during that window
                    // would otherwise let the previous user's reconciled
                    // counts overwrite the new user's UI.
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return
                    }
                    if let f = json["followerCount"] as? Int { self.followerCount = f }
                    if let f = json["followingCount"] as? Int { self.followingCount = f }
                    UserDefaults.standard.set(Date(), forKey: lastKey)
                } catch {
                    print("⚠️ reconcileMyCounts call failed: \(error)")
                }
            }
    }
    
    // Lazy tab loader: fetch a tab's data the first time it's shown. The replies
    // tab (3) always re-fetches so a reply the user just posted elsewhere appears
    // without a manual pull-to-refresh (it was already special-cased this way).
    func loadTabIfNeeded(_ tab: Int) {
        if tab == 3 { loadMyReplies(); loadedTabs.insert(3); return }
        guard !loadedTabs.contains(tab) else { return }
        loadedTabs.insert(tab)
        switch tab {
        case 0: loadMyPosts()
        case 1: loadLikedPosts(); loadLikedReplies()
        case 2: loadSavedPosts(); loadSavedReplies()
        default: break
        }
    }

    func loadMyPosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let postsQuery = db.collection("posts").whereField("authorId", isEqualTo: uid)

        // postCount is owned by loadProfile(), which runs the same
        // authorId==uid count() aggregation. loadMyPosts() is always paired
        // with loadProfile() (onAppear + tab-0 refresh), so we drop the
        // duplicate server count() here and just fetch the post list — saving
        // one aggregation round-trip on every profile load.
        postsQuery.order(by: "createdAt", descending: true).limit(to: 50)
            .getDocuments { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    if let error = error {
                        print("⚠️ loadMyPosts list fetch failed: \(error)")
                        return
                    }
                    guard let documents = snapshot?.documents else { return }
                    myPosts = documents.compactMap { doc in
                        let data = doc.data()
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return nil }
                        // 2026-05-31: do NOT hide flagged/pending posts from
                        // the author themselves anymore. The new pending-
                        // review banner tells them explicitly that the post
                        // is held for admin approval, which is better than a
                        // silent disappearance ("did my post even publish?").
                        // The previous "if flagged, hide from author" check
                        // is removed for this reason.
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let isRepost = data["isRepost"] as? Bool ?? false
                        let originalHandle = data["originalHandle"] as? String
                        let modStatus = data["moderationStatus"] as? String ?? "live"
                        let isPending = modStatus == "pending_review"
                        let reasonLabel = isPending
                            ? pendingReasonLabelFor(data["pendingReason"] as? String)
                            : nil
                        let isCrisisHold = isPending && (data["pendingReason"] as? String) == "crisis"
                        return MyPost(id: doc.documentID, text: data["text"] as? String ?? "", tag: data["tag"] as? String, likes: data["likeCount"] as? Int ?? 0, reposts: data["repostCount"] as? Int ?? 0, replies: data["replyCount"] as? Int ?? 0, time: FeedView.timeAgoString(from: createdAt), handle: isRepost ? (originalHandle ?? "anonymous") : (data["authorHandle"] as? String ?? "anonymous"), isRepost: isRepost, originalHandle: originalHandle, pendingReview: isPending, pendingReasonLabel: reasonLabel, pendingReasonIsCrisis: isCrisisHold)
                    }
                }
            }
    }
    
    func loadSavedPosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let savedSnap = try? await db.collection("users").document(uid).collection("saved")
                .order(by: "createdAt", descending: true).limit(to: 50)
                .getDocumentsAsync() else { return }
            // Auth recheck after the await — sign-out/sign-in race protection.
            guard Auth.auth().currentUser?.uid == uid else { return }
            let postIds = savedSnap.documents.map { $0.documentID }
            guard !postIds.isEmpty else { return }
            let chunks = stride(from: 0, to: postIds.count, by: 30).map { Array(postIds[$0..<min($0 + 30, postIds.count)]) }
            var allResults: [SavedPost] = []
            await withTaskGroup(of: (found: [SavedPost], requested: [String]).self) { group in
                for chunk in chunks {
                    group.addTask {
                        guard let postSnap = try? await db.collection("posts")
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocumentsAsync() else { return (found: [], requested: chunk) }
                        let results: [SavedPost] = postSnap.documents.compactMap { doc in
                            let data = doc.data()
                            guard data["text"] != nil else { return nil }
                            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                            return SavedPost(id: doc.documentID, handle: data["authorHandle"] as? String ?? "anonymous", text: data["text"] as? String ?? "", tag: data["tag"] as? String, likes: data["likeCount"] as? Int ?? 0, reposts: data["repostCount"] as? Int ?? 0, replies: data["replyCount"] as? Int ?? 0, time: ToskaFormatters.timeAgo(from: createdAt), createdAt: createdAt)
                        }
                        return (found: results, requested: chunk)
                    }
                }
                for await chunkResult in group {
                    allResults.append(contentsOf: chunkResult.found)
                    let foundIds = Set(chunkResult.found.map { $0.id })
                    let missingIds = chunkResult.requested.filter { !foundIds.contains($0) }
                    if !missingIds.isEmpty {
                        let cleanupBatch = db.batch()
                        for missingId in missingIds {
                            cleanupBatch.deleteDocument(db.collection("users").document(uid).collection("saved").document(missingId))
                        }
                        Task {
                            do { try await cleanupBatch.commit() }
                            catch { print("⚠️ saved posts cleanup batch failed: \(error)") }
                        }
                    }
                }
            }
            savedPosts = allResults.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // Saved replies live in users/{uid}/savedReplies — each doc is keyed by
    // the reply id and carries a save-time snapshot of {postId, replyText,
    // replyHandle, createdAt}. Loading them is a single query: we don't
    // re-fetch the actual reply or parent post on display because the snapshot
    // captures everything the saved-tab row needs. The trade-off is that a
    // reply edit or parent-post delete doesn't propagate here — accepted for
    // v1.0 (edits are rare, deletes self-heal on tap when fetchParent fails).
    func loadSavedReplies() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let snap = try? await db.collection("users").document(uid).collection("savedReplies")
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .getDocumentsAsync() else { return }
            guard Auth.auth().currentUser?.uid == uid else { return }
            let results: [SavedReply] = snap.documents.compactMap { doc in
                let data = doc.data()
                guard let postId = data["postId"] as? String, !postId.isEmpty else { return nil }
                let savedAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                return SavedReply(
                    id: doc.documentID,
                    postId: postId,
                    replyText: data["replyText"] as? String ?? "",
                    replyHandle: data["replyHandle"] as? String ?? "anonymous",
                    savedAt: savedAt
                )
            }
            savedReplies = results.sorted { $0.savedAt > $1.savedAt }
        }
    }
    /// Sortable union of saved posts and saved replies for the "saved" tab.
    /// Each variant carries its own createdAt for the merge sort. Tap
    /// behavior diverges: posts use the existing openSavedPost path; replies
    /// fetch the parent post async then open PostDetailView pointing at it.
    enum SavedItem: Identifiable {
        case post(SavedPost)
        case reply(SavedReply)
        var id: String {
            switch self {
            case .post(let p): return "post:\(p.id)"
            case .reply(let r): return "reply:\(r.id)"
            }
        }
        var createdAt: Date {
            switch self {
            case .post(let p): return p.createdAt
            case .reply(let r): return r.savedAt
            }
        }
    }

    var mergedSavedItems: [SavedItem] {
        let posts = savedPosts.map { SavedItem.post($0) }
        let replies = savedReplies.map { SavedItem.reply($0) }
        return (posts + replies).sorted { $0.createdAt > $1.createdAt }
    }

    // Tap handler for a saved-reply row. Fetches the parent post (one read)
    // and navigates to PostDetailView showing the thread that contains the
    // reply. If the parent post no longer exists (edge case after delete),
    // clean up the orphaned savedReplies entry so the row stops appearing
    // — same self-healing pattern loadSavedPosts uses for missing posts.
    func openSavedReply(_ saved: SavedReply) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task { @MainActor in
            guard let snap = try? await db.collection("posts").document(saved.postId).getDocumentAsync(),
                  let data = snap.data(),
                  data["text"] != nil else {
                // Parent gone — clean up the stale saved-reply entry.
                try? await db.collection("users").document(uid)
                    .collection("savedReplies").document(saved.id).delete()
                savedReplies.removeAll { $0.id == saved.id }
                return
            }
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            selectedPostId = saved.postId
            selectedPostData = PostDetailData(
                handle: data["authorHandle"] as? String ?? "anonymous",
                text: data["text"] as? String ?? "",
                tag: data["tag"] as? String,
                likes: data["likeCount"] as? Int ?? 0,
                reposts: data["repostCount"] as? Int ?? 0,
                replies: data["replyCount"] as? Int ?? 0,
                time: ToskaFormatters.timeAgo(from: createdAt),
                authorId: data["authorId"] as? String ?? "",
                isShareable: data["isShareable"] as? Bool ?? true
            )
            showPost = true
        }
    }

    // Liked replies — same shape + same trade-offs as saved replies.
    // Single query against the reverse index (users/{uid}/likedReplies),
    // each doc carries a save-time snapshot of replyText + replyHandle so
    // the liked tab renders without per-reply fetches.
    func loadLikedReplies() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let snap = try? await db.collection("users").document(uid).collection("likedReplies")
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .getDocumentsAsync() else { return }
            guard Auth.auth().currentUser?.uid == uid else { return }
            let results: [LikedReply] = snap.documents.compactMap { doc in
                let data = doc.data()
                guard let postId = data["postId"] as? String, !postId.isEmpty else { return nil }
                let likedAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                return LikedReply(
                    id: doc.documentID,
                    postId: postId,
                    replyText: data["replyText"] as? String ?? "",
                    replyHandle: data["replyHandle"] as? String ?? "anonymous",
                    likedAt: likedAt
                )
            }
            likedReplies = results.sorted { $0.likedAt > $1.likedAt }
        }
    }

    /// Sortable union for the "liked" tab. Mirrors SavedItem.
    enum LikedItem: Identifiable {
        case post(SavedPost)
        case reply(LikedReply)
        var id: String {
            switch self {
            case .post(let p): return "post:\(p.id)"
            case .reply(let r): return "reply:\(r.id)"
            }
        }
        var createdAt: Date {
            switch self {
            case .post(let p): return p.createdAt
            case .reply(let r): return r.likedAt
            }
        }
    }

    var mergedLikedItems: [LikedItem] {
        let posts = likedPosts.map { LikedItem.post($0) }
        let replies = likedReplies.map { LikedItem.reply($0) }
        return (posts + replies).sorted { $0.createdAt > $1.createdAt }
    }

    // Tap handler for a liked-reply row. Same self-healing on stale data
    // as openSavedReply: if the parent post is gone, clean up the orphan
    // likedReplies entry + remove from local array.
    func openLikedReply(_ liked: LikedReply) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task { @MainActor in
            guard let snap = try? await db.collection("posts").document(liked.postId).getDocumentAsync(),
                  let data = snap.data(),
                  data["text"] != nil else {
                try? await db.collection("users").document(uid)
                    .collection("likedReplies").document(liked.id).delete()
                likedReplies.removeAll { $0.id == liked.id }
                return
            }
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            selectedPostId = liked.postId
            selectedPostData = PostDetailData(
                handle: data["authorHandle"] as? String ?? "anonymous",
                text: data["text"] as? String ?? "",
                tag: data["tag"] as? String,
                likes: data["likeCount"] as? Int ?? 0,
                reposts: data["repostCount"] as? Int ?? 0,
                replies: data["replyCount"] as? Int ?? 0,
                time: ToskaFormatters.timeAgo(from: createdAt),
                authorId: data["authorId"] as? String ?? "",
                isShareable: data["isShareable"] as? Bool ?? true
            )
            showPost = true
        }
    }

    func loadLikedPosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let likedSnap = try? await db.collection("users").document(uid).collection("liked")
                .order(by: "createdAt", descending: true).limit(to: 50)
                .getDocumentsAsync() else { likedPosts = []; return }
            // Auth recheck after the await — sign-out/sign-in race protection.
            guard Auth.auth().currentUser?.uid == uid else { return }
            let postIds = likedSnap.documents.map { $0.documentID }
            guard !postIds.isEmpty else { likedPosts = []; return }
            let chunks = stride(from: 0, to: postIds.count, by: 30).map { Array(postIds[$0..<min($0 + 30, postIds.count)]) }
            var allResults: [SavedPost] = []
            await withTaskGroup(of: (found: [SavedPost], requested: [String]).self) { group in
                for chunk in chunks {
                    group.addTask {
                        guard let postSnap = try? await db.collection("posts")
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocumentsAsync() else { return (found: [], requested: chunk) }
                        let results: [SavedPost] = postSnap.documents.compactMap { doc in
                            let data = doc.data()
                            guard data["text"] != nil else { return nil }
                            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                            return SavedPost(id: doc.documentID, handle: data["authorHandle"] as? String ?? "anonymous", text: data["text"] as? String ?? "", tag: data["tag"] as? String, likes: data["likeCount"] as? Int ?? 0, reposts: data["repostCount"] as? Int ?? 0, replies: data["replyCount"] as? Int ?? 0, time: ToskaFormatters.timeAgo(from: createdAt), createdAt: createdAt)
                        }
                        return (found: results, requested: chunk)
                    }
                }
                for await chunkResult in group {
                    allResults.append(contentsOf: chunkResult.found)
                    let foundIds = Set(chunkResult.found.map { $0.id })
                    let missingIds = chunkResult.requested.filter { !foundIds.contains($0) }
                    if !missingIds.isEmpty {
                        let cleanupBatch = db.batch()
                        for missingId in missingIds {
                            cleanupBatch.deleteDocument(db.collection("users").document(uid).collection("liked").document(missingId))
                        }
                        Task {
                            do { try await cleanupBatch.commit() }
                            catch { print("⚠️ liked posts cleanup batch failed: \(error)") }
                        }
                    }
                }
            }
            likedPosts = allResults.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    /// Loads the current user's own replies for the "replies" profile tab.
    /// Mirrors OtherProfileView.loadReplies, scoped to the signed-in uid.
    /// Uses the replies collection-group index (authorId ASC, createdAt DESC)
    /// that OtherProfileView already relies on. Denormalized parentPostText/
    /// parentPostHandle are used when present; older replies fall back to
    /// fetching the parent post for context.
    func loadMyReplies() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let replySnap = try? await db.collectionGroup("replies")
                .whereField("authorId", isEqualTo: uid)
                .order(by: "createdAt", descending: true)
                .limit(to: 30)
                .getDocumentsAsync() else { return }

            var results: [MyReply] = []
            await withTaskGroup(of: MyReply?.self) { group in
                for doc in replySnap.documents {
                    let data = doc.data()
                    let replyText = data["text"] as? String ?? ""
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    let replyTime = ToskaFormatters.timeAgo(from: createdAt)
                    let replyDocId = doc.documentID

                    if let parentText = data["parentPostText"] as? String {
                        let parentHandle = data["parentPostHandle"] as? String ?? "anonymous"
                        let parentPostId = doc.reference.parent.parent?.documentID ?? ""
                        group.addTask {
                            MyReply(id: replyDocId, replyText: replyText, replyTime: replyTime, parentText: parentText, parentHandle: parentHandle, parentPostId: parentPostId, createdAt: createdAt)
                        }
                    } else {
                        guard let parentRef = doc.reference.parent.parent else { continue }
                        let parentPostId = parentRef.documentID
                        group.addTask {
                            let parentSnap = try? await parentRef.getDocumentAsync()
                            let parentData = parentSnap?.data()
                            let parentText = parentData?["text"] as? String ?? "deleted post"
                            let parentHandle = parentData?["authorHandle"] as? String ?? "anonymous"
                            return MyReply(id: replyDocId, replyText: replyText, replyTime: replyTime, parentText: parentText, parentHandle: parentHandle, parentPostId: parentPostId, createdAt: createdAt)
                        }
                    }
                }
                for await result in group {
                    if let result = result { results.append(result) }
                }
            }
            // Cross-session guard (2026-06-01 audit): the collectionGroup query
            // + nested parent-post fetches above can outlive a sign-out/sign-in.
            // Without rechecking the captured uid, a task in flight when the
            // account switches would render User A's authored replies on User
            // B's profile. Mirrors loadMyPosts / loadSavedPosts / loadLikedPosts.
            guard Auth.auth().currentUser?.uid == uid else { return }
            myReplies = results.sorted { $0.createdAt > $1.createdAt }
        }
    }
}

// MARK: - Reply Engagement Row
//
// Renders a reply that the user has either saved or liked, in their
// profile's "saved" / "liked" tabs. Visually distinguished from
// FeedPostRow with a leading reply-glyph + dimmer chrome so the user
// can tell at a glance that this entry is a reply, not a top-level
// post. Tap navigates to the parent post (handled in the enclosing
// ProfileView via openSavedReply / openLikedReply). Generic over the
// reply data so both SavedReply and LikedReply call sites reuse it.
struct ReplyEngagementRow: View {
    let handle: String
    let text: String
    let time: Date
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 11, weight: .light))
                .foregroundColor(Color.toskaBlue.opacity(0.7))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(handle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                    Text("· reply")
                        .font(.system(size: 9))
                        .foregroundColor(Color.toskaTimestamp)
                    Spacer()
                    Text(ToskaFormatters.timeAgo(from: time))
                        .font(.system(size: 9, weight: .light))
                        .foregroundColor(Color.toskaInactiveGray)
                }
                Text(text)
                    .font(ToskaFont.serif(13))
                    .foregroundColor(Color.toskaTextDark)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                Text("tap to read in thread")
                    .font(.system(size: 9))
                    .foregroundColor(Color.toskaDivider)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.toskaBorderLight.opacity(0.5)).frame(height: 0.5)
        }
    }
}

// MARK: - Follow User (for sheet navigation)

struct FollowUser: Identifiable, Hashable {
    let id: String
    let handle: String
}

// MARK: - Follow List View

@MainActor
struct FollowListView: View {
    let title: String
    @Environment(\.dismiss) var dismiss
    @State private var users: [(id: String, handle: String)] = []
    @State private var isLoading = true
    @State private var selectedUser: FollowUser? = nil
    @State private var hasFetchedInitial = false
    @State private var blockedUserIds: Set<String> = []
    // Unfollow flow — only meaningful on the "following" tab. Tapping the
    // trailing "following" pill primes this state, which opens the
    // confirmation alert below. On confirm we optimistically remove the
    // row + fire a batch delete; on failure we restore and surface an
    // inline auto-dismissing error toast.
    @State private var pendingUnfollow: (id: String, handle: String)? = nil
    @State private var unfollowError: String? = nil

    private var isFollowingTab: Bool { title == "following" }

    var body: some View {
        // No inner NavigationStack — this view is pushed onto the parent's
        // stack (ProfileView's NavigationStack via .navigationDestination).
        // Inner-stack would nest and break .navigationDestination(item:)
        // for the row-tap → OtherProfileView push below.
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ToskaHeader(title: title, onBack: { dismiss() })
                    if isLoading {
                        Spacer(); ProgressView().tint(Color.toskaBlue); Spacer()
                    } else if users.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("no \(title) yet").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextLight)
                            Text(isFollowingTab
                                 ? "tap a handle on a post to follow someone"
                                 : "keep posting — people you reach will follow")
                                .font(.system(size: 12))
                                .foregroundColor(Color.toskaPlaceholderGray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(users.enumerated()), id: \.element.0) { index, user in
                                    FollowRow(
                                        handle: user.handle,
                                        showUnfollow: isFollowingTab,
                                        onTap: { selectedUser = FollowUser(id: user.id, handle: user.handle) },
                                        onUnfollow: { pendingUnfollow = (id: user.id, handle: user.handle) }
                                    )
                                    if index < users.count - 1 {
                                        Rectangle().fill(Color.toskaDividerHairline.opacity(0.5)).frame(height: 0.5).padding(.leading, 16)
                                    }
                                }
                                if users.count >= 50 {
                                    Text("showing your first 50 \(title)")
                                        .font(.system(size: 9)).foregroundColor(Color.toskaPlaceholderGray)
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                }
                            }
                        }
                    }
                }

                // Inline error toast (unfollow failure). Auto-dismisses
                // via the 3s Task scheduled in performUnfollow; sits
                // above the bottom edge so it doesn't conflict with the
                // pull-to-dismiss gesture on the sheet.
                if let err = unfollowError {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(10)
                            .padding(.bottom, 32)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear {
                guard !hasFetchedInitial else { return }
                hasFetchedInitial = true
                loadUsers()
            }
            .navigationDestination(item: $selectedUser) { user in
                OtherProfileView(userId: user.id, handle: user.handle)
                    .navigationBarHidden(true)
            }
            // Unfollow confirmation. Two-step deliberately — unfollow is
            // an undoable action elsewhere in the app (re-follow), but
            // surfacing a quick confirm here prevents accidental loss of
            // a handle the user actually wanted to keep following.
            .alert(
                "unfollow \(pendingUnfollow?.handle ?? "")?",
                isPresented: Binding(
                    get: { pendingUnfollow != nil },
                    set: { if !$0 { pendingUnfollow = nil } }
                ),
                presenting: pendingUnfollow
            ) { user in
                Button("cancel", role: .cancel) { pendingUnfollow = nil }
                Button("unfollow", role: .destructive) {
                    performUnfollow(userId: user.id)
                    pendingUnfollow = nil
                }
            } message: { _ in
                Text("you can re-follow anytime.")
            }
            .navigationBarHidden(true)
            .hidesAppTabBar()
    }

    // Optimistic unfollow. Mirrors OtherProfileView.toggleFollow's unfollow
    // branch (batch-delete both follow-graph docs; counter decrement is
    // handled server-side by onFollowDeletedUpdateCounts). On failure we
    // restore the local row and surface a 3s inline toast.
    func performUnfollow(userId: String) {
        guard let myUid = Auth.auth().currentUser?.uid else { return }
        guard NetworkMonitor.shared.isConnected else {
            withAnimation { unfollowError = "you're offline" }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { unfollowError = nil }
            }
            return
        }
        let originalUsers = users
        withAnimation(.easeInOut(duration: 0.2)) {
            users.removeAll { $0.id == userId }
        }
        HapticManager.play(.tabSwitch)

        let db = Firestore.firestore()
        let followingRef = db.collection("users").document(myUid).collection("following").document(userId)
        let followerRef = db.collection("users").document(userId).collection("followers").document(myUid)
        let batch = db.batch()
        batch.deleteDocument(followingRef)
        batch.deleteDocument(followerRef)
        batch.commit { error in
            Task { @MainActor in
                // Same uid-recheck pattern as OtherProfileView.toggleFollow:
                // sign-out (or account switch) between the tap and the
                // callback must not mutate the new user's state.
                guard Auth.auth().currentUser?.uid == myUid else { return }
                if let error = error {
                    print("⚠️ FollowListView.unfollow failed: \(error)")
                    Telemetry.recordError(error, context: "FollowListView.performUnfollow")
                    withAnimation {
                        users = originalUsers
                        unfollowError = "couldn't unfollow — try again"
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation { unfollowError = nil }
                    }
                }
            }
        }
    }
    
    func loadUsers() {
        guard let uid = Auth.auth().currentUser?.uid else { isLoading = false; return }
        let db = Firestore.firestore()
        let collection = title == "followers" ? "followers" : "following"
        Task {
            if let blockedSnap = try? await db.collection("users").document(uid).collection("blocked").getDocumentsAsync() {
                blockedUserIds = Set(blockedSnap.documents.map { $0.documentID })
            }
            
            guard let snapshot = try? await db.collection("users").document(uid).collection(collection)
                .limit(to: 50)
                .getDocumentsAsync() else { isLoading = false; return }
            let documents = snapshot.documents.filter { !blockedUserIds.contains($0.documentID) }
            if documents.isEmpty { isLoading = false; return }
            var fetched: [(id: String, handle: String)] = []
            var needsFetch: [String] = []
            for doc in documents {
                if let handle = doc.data()["handle"] as? String, !handle.isEmpty {
                    fetched.append((id: doc.documentID, handle: handle))
                } else { needsFetch.append(doc.documentID) }
            }
            if !needsFetch.isEmpty {
                await withTaskGroup(of: (id: String, handle: String).self) { group in
                    for userId in needsFetch {
                        group.addTask {
                            let userSnap = try? await db.collection("users").document(userId).getDocumentAsync()
                            return (id: userId, handle: userSnap?.data()?["handle"] as? String ?? "anonymous")
                        }
                    }
                    for await result in group { fetched.append(result) }
                }
            }
            // Dedup by id. With both the per-doc handle path and the
            // collateral fetch path appending to the same array, a corrupt
            // double-follow doc (or a future race that creates one) would
            // render the same user twice. Walking by id keeps the first
            // occurrence's handle (which is what the doc itself stored —
            // truthier than a fallback fetch).
            var seen = Set<String>()
            users = fetched.compactMap { entry in
                guard !seen.contains(entry.id) else { return nil }
                seen.insert(entry.id)
                return entry
            }
            isLoading = false
        }
    }
}

// MARK: - Follow Row
//
// One row in FollowListView. Whole row is tappable → navigates to the
// user's profile. On the "following" tab the trailing affordance is an
// unfollow pill (tap → confirmation alert in the parent); on the
// "followers" tab it's a chevron (followers control their own follow
// doc, so no inline action is meaningful — the only thing the user can
// do is block, which lives in OtherProfileView). The Button captures
// taps within its bounds, so tapping the pill does NOT also trigger
// the row's onTap.
@MainActor
private struct FollowRow: View {
    let handle: String
    let showUnfollow: Bool
    let onTap: () -> Void
    let onUnfollow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(handle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.toskaBlue)
                .lineLimit(1)

            Spacer()

            if showUnfollow {
                Button(action: onUnfollow) {
                    Text("following")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "888888"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().stroke(Color.toskaDividerHairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(Color.toskaDivider)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Edit Reply View

@MainActor
struct EditReplyView: View {
    let postId: String
    let replyId: String
    @Binding var replyText: String
    var onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var isSaving = false
    // Safety check state — mirrors the create-reply flow in PostDetailView.
    // Without these, a user could initially write a clean reply, then edit
    // it later to add personal info or crisis content with no validation.
    @State private var showNameWarning = false
    @State private var showGentleCheck = false
    @State private var gentleCheckLevel: CrisisLevel = .soft
    // Hard content-policy gate (slurs / threats / sexual content / spam).
    // Without this, an edit can sneak prohibited content past the
    // create-reply moderation pre-check. Mirror of ComposeView's pattern.
    @State private var showContentWarning = false
    @State private var contentWarningMessage = ""
    // Surfaced inline below the edit field when saveReply fails. Cleared
    // on the next attempt or on successful save (success dismisses the view).
    @State private var saveError: String? = nil

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color.toskaMidGray)
                    }
                    Spacer()
                    Text("edit reply").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { attemptSave() } label: {
                        Text("save").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving ? Color.toskaDivider : Color.toskaBlue)
                            .cornerRadius(16)
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

                if let saveError {
                    Text(saveError)
                        .font(.system(size: 11))
                        .foregroundColor(Color.toskaErrorRed)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                ZStack(alignment: .topLeading) {
                    if replyText.isEmpty {
                        Text("say what you feel...")
                            .font(ToskaFont.serif(16)).foregroundColor(Color(hex: "c0c3ca"))
                            .padding(.horizontal, 18).padding(.top, 16)
                    }
                    TextEditor(text: $replyText)
                        .font(ToskaFont.serif(16)).foregroundColor(Color(hex: "1a1a1a"))
                        .lineSpacing(4).scrollContentBackground(.hidden)
                        .padding(.horizontal, 14).padding(.top, 8)
                        .onChange(of: replyText) { _, newValue in
                            if newValue.count > 500 { replyText = String(newValue.prefix(500)) }
                        }
                }
                .frame(maxHeight: .infinity)

                Spacer()
            }
        }
        .alert("keep it anonymous", isPresented: $showNameWarning) {
            Button("edit") {}
            Button("save anyway", role: .destructive) {
                if let level = crisisCheckLevelRespectingSetting(for: replyText) {
                    gentleCheckLevel = level
                    showGentleCheck = true
                } else {
                    saveReply()
                }
            }
        } message: {
            Text("your reply may include a name or identifying info. toska is anonymous for everyone.")
        }
        .alert("content not allowed", isPresented: $showContentWarning) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(contentWarningMessage)
        }
        .overlay {
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: gentleCheckLevel,
                    onProceed: { saveReply() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
    }

    /// Validates content-policy, name, and crisis-content before letting
    /// saveReply proceed. Without this, an edit can quietly inject content
    /// that the original reply-create flow would have intercepted.
    /// Order: hard policy violations first (slurs / threats / sexual / spam
    /// → block save), then identifying-info warning (allow with confirm),
    /// then crisis check (allow with check-in). The server-side
    /// onReplyUpdated trigger re-runs moderation as a backstop, but
    /// catching it client-side gives the user a chance to revise before
    /// the reply gets deleted or flagged in their absence.
    func attemptSave() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let violation = contentViolation(in: trimmed) {
            contentWarningMessage = contentViolationMessage(for: violation)
            showContentWarning = true
            return
        }
        if containsNameOrIdentifyingInfo(trimmed) { showNameWarning = true; return }
        if let level = crisisCheckLevelRespectingSetting(for: trimmed) {
            gentleCheckLevel = level
            showGentleCheck = true
            return
        }
        saveReply()
    }

    func saveReply() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !postId.isEmpty, !replyId.isEmpty else { return }
        isSaving = true
        saveError = nil
        Firestore.firestore().collection("posts").document(postId).collection("replies").document(replyId)
            .updateData(["text": trimmed, "editedAt": FieldValue.serverTimestamp()]) { error in
                Task { @MainActor in
                    isSaving = false
                    if let error = error {
                        // Previously a save failure left isSaving=false but
                        // showed nothing to the user — the save button just
                        // became tappable again with no error context. Now
                        // we surface a banner so the user knows to retry
                        // and Crashlytics gets the failure for diagnosis.
                        print("⚠️ EditReply.saveReply failed: \(error)")
                        Telemetry.recordError(error, context: "EditReplyView.saveReply")
                        saveError = "couldn't save — try again"
                        return
                    }
                    replyText = trimmed
                    onSave()
                    dismiss()
                }
            }
    }
}

// 2026-05-31: "under review" banner shown above the author's own pending
// posts in ProfileView. Without this, the author sees their post on their
// own profile and assumes it published normally — there's no signal that
// other users can't see it. Banner sits between the optional repost
// chevron and the FeedPostRow content so it groups visually with the
// post body but doesn't compete with the post text for attention.
struct PendingReviewBanner: View {
    let reasonLabel: String?
    // N-14: when the post was held for crisis/concerning content, surface
    // region-appropriate support resources right here — "resources on
    // detection." Additive only; the server still reviews every such post.
    var isCrisis: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isCrisis ? "heart.fill" : "eye.slash.fill")
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("under review — visible only to you")
                    .font(.system(size: 11, weight: .semibold))
                if let label = reasonLabel {
                    Text(label)
                        .font(.system(size: 10))
                        .opacity(0.85)
                }
                if isCrisis {
                    Text("if you're struggling, you're not alone — support is here:")
                        .font(.system(size: 10))
                        .opacity(0.9)
                        .padding(.top, 3)
                    ForEach(CrisisLines.resources.prefix(2), id: \.url) { res in
                        if let url = URL(string: res.url) {
                            Link(destination: url) {
                                HStack(spacing: 5) {
                                    Image(systemName: res.icon).font(.system(size: 10))
                                    Text(res.label).font(.system(size: 11, weight: .semibold)).underline()
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(Color(hex: "9a7843"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.toskaAccentTan.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(Color.toskaAccentTan)
                .frame(width: 3)
                .frame(maxHeight: .infinity),
            alignment: .leading
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// Maps the server-side pendingReason taxonomy onto short author-facing
// labels. Stays generic enough not to give an evasion-tuner a precise
// "this exact word tripped it" signal — the reason hints at the
// category, not the specific phrase that matched.
func pendingReasonLabelFor(_ reason: String?) -> String? {
    switch reason {
    case "pii":              return "may contain names or contact info"
    case "crisis":           return "checking in — flagged for safety review"
    case "abuse_hate":       return "flagged for hateful language"
    case "abuse_harassment": return "flagged for harassment language"
    case "abuse_threat":     return "flagged for threatening language"
    case "abuse_sexual":     return "flagged for sexual content"
    case "abuse_link":       return "contains a link — held for review"
    case "abuse_spam":       return "flagged as possible spam"
    case "user_reports":     return "multiple reports — held for review"
    case nil:                return nil
    default:                 return "held for review"
    }
}
