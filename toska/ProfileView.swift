import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore



@MainActor
struct ProfileView: View {
    @State private var selectedTab = 0
    @State private var showSettings = false
    @State private var showFollowing = false
    @State private var showFollowers = false
    @State private var userHandle = "anonymous"
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var totalLikes = 0
    @State private var postCount = 0
    @State private var joinedDate = ""
    @State private var myPosts: [MyPost] = []
    @State private var savedPosts: [SavedPost] = []
    @State private var myReplies: [MyReply] = []
    @State private var likedPosts: [SavedPost] = []
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
    @State private var hasFetchedInitial = false
    @State private var showMessagesList = false
    @State private var showWeeklyRecap = false
    @State private var presenceStreak = 0
    @State private var totalNights = 0
    
    let tabIcons = [("note.text", "note.text"), ("heart", "heart.fill"), ("bookmark", "bookmark.fill")]
    var avatarInitial: String {
        let cleaned = userHandle.replacingOccurrences(of: "anonymous_", with: "")
        return String(cleaned.prefix(1)).uppercased()
    }
    
    var avatarColor: Color {
        let colors: [Color] = [
            Color.toskaBlue, Color(hex: "8b7ec8"), Color(hex: "6ba58e"),
            Color(hex: "c47a8a"), Color(hex: "c49a6c"), Color(hex: "7a97b5"),
            Color(hex: "5a9e8f"), Color(hex: "c45c5c")
        ]
        var hash: UInt64 = 5381
        for char in userHandle.utf8 {
            hash = hash &* 33 &+ UInt64(char)
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
    
    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Text(userHandle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color.toskaTextDark)
                    Spacer()
                    HStack(spacing: 16) {
                        Button { showMessagesList = true } label: {
                            Image(systemName: "envelope")
                                .font(.system(size: 16, weight: .light))
                                .foregroundColor(Color(hex: "999999"))
                        }
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 16, weight: .light))
                                .foregroundColor(Color(hex: "999999"))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                ScrollView(showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        // Compact profile info
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 4) {
                                                Text("joined \(joinedDate)")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color.toskaTextLight)
                                                
                                                if LateNightTheme.isLateNight {
                                                    Text("·")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(Color.toskaTextLight)
                                                    Text("still here at this hour.")
                                                        .font(.custom("Georgia-Italic", size: 10))
                                                        .foregroundColor(Color.toskaBlue.opacity(0.4))
                                                }
                                            }
                                            
                                            // Stats inline
                                            HStack(spacing: 12) {
                                                statLabel(count: postCount, label: "posts")
                                                Button { showFollowers = true } label: { statLabel(count: followerCount, label: "followers") }
                                                Button { showFollowing = true } label: { statLabel(count: followingCount, label: "following") }
                                                statLabel(count: totalLikes, label: "felt")
                                            }
                                            
                                            if totalNights > 0 {
                                                HStack(spacing: 8) {
                                                    Button {
                                                        showWeeklyRecap = true
                                                    } label: {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: "moon.stars").font(.system(size: 9))
                                                            Text("here for \(totalNights) \(totalNights == 1 ? "night" : "nights")")
                                                                .font(.system(size: 11))
                                                            if presenceStreak > 1 {
                                                                Text("· \(presenceStreak) in a row")
                                                                    .font(.system(size: 11))
                                                                    .foregroundColor(Color.toskaBlue)
                                                            }
                                                        }
                                                        .foregroundColor(Color.toskaTextLight)
                                                    }
                                                    .buttonStyle(.plain)
                                                    
                                                    Button {
                                                        shareStreak()
                                                    } label: {
                                                        Image(systemName: "square.and.arrow.up")
                                                            .font(.system(size: 9, weight: .light))
                                                            .foregroundColor(Color.toskaDivider)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.top, 8)
                                        .padding(.bottom, 14)
                        
                                        HStack(spacing: 0) {
                                                                    ForEach(0..<tabIcons.count, id: \.self) { index in
                                                                        Button {
                                                                            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = index }
                                                                        } label: {
                                                                            VStack(spacing: 6) {
                                                                                Image(systemName: selectedTab == index ? tabIcons[index].1 : tabIcons[index].0)
                                                                                    .font(.system(size: 18, weight: selectedTab == index ? .medium : .light))
                                                                                    .foregroundColor(selectedTab == index ? Color.toskaBlue : Color(hex: "c8c8c8"))
                                                                                Capsule()
                                                                                    .fill(selectedTab == index ? Color.toskaBlue : Color.clear)
                                                                                    .frame(height: 2)
                                                                            }
                                                                            .frame(maxWidth: .infinity)
                                                                        }
                                                                    }
                                                                }
                                                                .padding(.horizontal, 16)
                                                                .padding(.vertical, 6)
                        
                        Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)
                        
                                        switch selectedTab {
                                                                case 0:
                                                                    if myPosts.isEmpty {
                                                                        emptyState(title: "nothing here yet.", subtitle: "say the thing you cant say anywhere else.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(myPosts) { post in
                                                                                Button { openMyPost(post) } label: {
                                                                                    VStack(alignment: .leading, spacing: 0) {
                                                                                        if post.isRepost {
                                                                                            HStack(spacing: 4) {
                                                                                                Image(systemName: "arrow.2.squarepath")
                                                                                                    .font(.system(size: 9))
                                                                                                Text("you reposted")
                                                                                                    .font(.system(size: 10, weight: .medium))
                                                                                            }
                                                                                            .foregroundColor(Color(hex: "5a9e8f"))
                                                                                            .padding(.horizontal, 16)
                                                                                            .padding(.top, 8)
                                                                                        }
                                                                                        FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: Auth.auth().currentUser?.uid ?? "", isRepostPost: post.isRepost)
                                                                                    }
                                                                                }
                                                                                .buttonStyle(.plain)
                                                                            }
                                                                            if myPosts.count >= 50 {
                                                                                Text("showing your 50 most recent posts")
                                                                                    .font(.system(size: 9)).foregroundColor(Color(hex: "cccccc"))
                                                                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                                                            }
                                                                        }
                                                                    }
                                                                case 1:
                                                                    if likedPosts.isEmpty {
                                                                        emptyState(title: "nothing felt yet.", subtitle: "youll know it when you see it.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(likedPosts) { post in
                                                                                Button { openSavedPost(post) } label: {
                                                                                    FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id)
                                                                                }
                                                                                .buttonStyle(.plain)
                                                                            }
                                                                            if likedPosts.count >= 50 {
                                                                                Text("showing your 50 most recent likes")
                                                                                    .font(.system(size: 9)).foregroundColor(Color(hex: "cccccc"))
                                                                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                                                            }
                                                                        }
                                                                    }
                                                                case 2:
                                                                    if savedPosts.isEmpty {
                                                                        emptyState(title: "nothing saved.", subtitle: "some things are worth keeping.")
                                                                    } else {
                                                                        LazyVStack(spacing: 0) {
                                                                            ForEach(savedPosts) { post in
                                                                                Button { openSavedPost(post) } label: {
                                                                                    FeedPostRow(handle: post.handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id)
                                                                                }
                                                                                .buttonStyle(.plain)
                                                                            }
                                                                            if savedPosts.count >= 50 {
                                                                                Text("showing your 50 most recent saves")
                                                                                    .font(.system(size: 9)).foregroundColor(Color(hex: "cccccc"))
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
                                    case 1: loadLikedPosts()
                                    case 2: loadSavedPosts()
                                    default: break
                                    }
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showMessagesList) { MessagesListView() }
        .fullScreenCover(isPresented: $showWeeklyRecap) { WeeklyRecapView() }
        .sheet(isPresented: $showFollowers) { FollowListView(title: "followers") }
        .sheet(isPresented: $showFollowing) { FollowListView(title: "following") }
        .navigationDestination(isPresented: $showPost) {
                            if let postData = selectedPostData, let postId = selectedPostId {
                                PostDetailView(postId: postId, handle: postData.handle, text: postData.text, tag: postData.tag, likes: postData.likes, reposts: postData.reposts, replies: postData.replies, time: postData.time, authorId: postData.authorId)
                                    .navigationBarHidden(true)
                            }
                        }
        .sheet(isPresented: $showEditReply) {
            EditReplyView(postId: editReplyPostId, replyId: editReplyId, replyText: $editReplyText) {
                if let idx = myReplies.firstIndex(where: { $0.id == editReplyId }) {
                    let old = myReplies[idx]
                    myReplies[idx] = MyReply(id: old.id, replyText: editReplyText, replyTime: old.replyTime, parentText: old.parentText, parentHandle: old.parentHandle, parentPostId: old.parentPostId, createdAt: old.createdAt)
                }
            }
        }
        .alert("delete this reply?", isPresented: $showDeleteReplyAlert) {
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) {
                deleteReply(replyId: deleteReplyId, postId: deleteReplyPostId)
            }
        } message: {
            Text("this is permanent.")
        }
        .onAppear {
                    if !hasFetchedInitial {
                        hasFetchedInitial = true
                                                loadMyPosts()
                                                loadLikedPosts()
                                                loadSavedPosts()
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            reconcileCountsIfNeeded()
                        }
                        ensurePresenceThenLoadStreak()
                    }
                    loadProfile()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        reconcileCountsIfNeeded()
                    }
                    ensurePresenceThenLoadStreak()
                }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                    showSettings = false
                    showMessagesList = false
                    showFollowers = false
                    showFollowing = false
                    showEditReply = false
                    showWeeklyRecap = false
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
    
    func statLabel(count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(formatCount(count))").font(.system(size: 13, weight: .bold)).foregroundColor(Color.toskaTextDark)
            Text(label).font(.system(size: 13)).foregroundColor(Color.toskaTextLight)
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
                    Text(reply.replyTime).font(.system(size: 10, weight: .light)).foregroundColor(Color(hex: "c8c8c8"))
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
                    .font(.custom("Georgia", size: 14))
                    .foregroundColor(Color.toskaTextDark)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(hex: "f0f1f3"))
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
            let db = Firestore.firestore()
            let postRef = db.collection("posts").document(postId)

            db.runTransaction({ transaction, errorPointer in
                let postSnap: DocumentSnapshot
                do { postSnap = try transaction.getDocument(postRef) }
                catch let e as NSError { errorPointer?.pointee = e; return nil }

                guard postSnap.exists else { return nil }

                let currentCount = postSnap.data()?["replyCount"] as? Int ?? 0
                transaction.deleteDocument(db.collection("posts").document(postId).collection("replies").document(replyId))
                if currentCount > 0 {
                    transaction.updateData(["replyCount": currentCount - 1], forDocument: postRef)
                }
                return nil
            }, completion: { _, error in
                Task { @MainActor in
                    if error == nil { myReplies.removeAll { $0.id == replyId } }
                }
            })
        }
    
    func emptyState(title: String, subtitle: String) -> some View {
            VStack(spacing: 12) {
                Text(title)
                    .font(.custom("Georgia-Italic", size: 18))
                    .foregroundColor(Color.toskaTextLight)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color.toskaDivider)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    
    func shareStreak() {
        let streakLabel = presenceStreak > 1 ? "\(presenceStreak) nights in a row" : ""
        
        let cardView = ZStack {
            Color(hex: "0a0908")
            
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
                    .foregroundColor(Color(hex: "c49a6c"))
                    .padding(.bottom, 8)
                }
                
                Text("saying what i never said")
                    .font(.custom("Georgia-Italic", size: 13))
                    .foregroundColor(.white.opacity(0.25))
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 18))
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
                   postCount = Int(truncating: postSnap?.count ?? 0)
               } catch {
                   print("⚠️ loadProfile failed: \(error)")
               }
           }
       }
    
    func reconcileCountsIfNeeded() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
        let lastKey = UserDefaultsKeys.lastReconcileDate(uid: uid)
                   if let lastReconcile = UserDefaults.standard.object(forKey: lastKey) as? Date,
                      Date().timeIntervalSince(lastReconcile) < 86400 { return }
            let db = Firestore.firestore()
            let userRef = db.collection("users").document(uid)

            Task { @MainActor in
                var updates: [String: Any] = [:]

                let followerSnap = try? await db.collection("users").document(uid)
                    .collection("followers").count.getAggregation(source: .server)
                if let count = followerSnap?.count {
                    let actual = Int(truncating: count)
                    if actual != self.followerCount {
                        self.followerCount = actual
                        updates["followerCount"] = actual
                    }
                }

                let followingSnap = try? await db.collection("users").document(uid)
                    .collection("following").count.getAggregation(source: .server)
                if let count = followingSnap?.count {
                    let actual = Int(truncating: count)
                    if actual != self.followingCount {
                        self.followingCount = actual
                        updates["followingCount"] = actual
                    }
                }

                if !updates.isEmpty {
                    try? await userRef.updateData(updates)
                }
                UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastReconcileDate(uid: uid))
            }
    }
    
    func loadMyPosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let postsQuery = db.collection("posts").whereField("authorId", isEqualTo: uid)

        postsQuery.count.getAggregation(source: .server) { snapshot, error in
            Task { @MainActor in
                if let error = error {
                    print("⚠️ loadMyPosts count aggregation failed: \(error)")
                    return
                }
                if let count = snapshot?.count {
                    postCount = Int(truncating: count)
                }
            }
        }

        postsQuery.order(by: "createdAt", descending: true).limit(to: 50)
            .getDocuments { snapshot, error in
                Task { @MainActor in
                    if let error = error {
                        print("⚠️ loadMyPosts list fetch failed: \(error)")
                        return
                    }
                    guard let documents = snapshot?.documents else { return }
                    myPosts = documents.compactMap { doc in
                        let data = doc.data()
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return nil }
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let isRepost = data["isRepost"] as? Bool ?? false
                        let originalHandle = data["originalHandle"] as? String
                        return MyPost(id: doc.documentID, text: data["text"] as? String ?? "", tag: data["tag"] as? String, likes: data["likeCount"] as? Int ?? 0, reposts: data["repostCount"] as? Int ?? 0, replies: data["replyCount"] as? Int ?? 0, time: FeedView.timeAgoString(from: createdAt), handle: isRepost ? (originalHandle ?? "anonymous") : (data["authorHandle"] as? String ?? "anonymous"), isRepost: isRepost, originalHandle: originalHandle)
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
                        cleanupBatch.commit { error in
                            if let error = error {
                                print("⚠️ saved posts cleanup batch failed: \(error)")
                            }
                        }
                    }
                }
            }
            savedPosts = allResults.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    func loadLikedPosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let likedSnap = try? await db.collection("users").document(uid).collection("liked")
                .order(by: "createdAt", descending: true).limit(to: 50)
                .getDocumentsAsync() else { likedPosts = []; return }
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
                        cleanupBatch.commit { error in
                            if let error = error {
                                print("⚠️ liked posts cleanup batch failed: \(error)")
                            }
                        }
                    }
                }
            }
            likedPosts = allResults.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    func loadMyReplies() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        Task {
            guard let replySnap = try? await db.collectionGroup("replies")
                .whereField("authorId", isEqualTo: uid)
                .order(by: "createdAt", descending: true).limit(to: 30)
                .getDocumentsAsync() else { return }
            var results: [MyReply] = []
            await withTaskGroup(of: MyReply?.self) { group in
                for doc in replySnap.documents {
                    let data = doc.data()
                    let replyText = data["text"] as? String ?? ""
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    let replyTime = ToskaFormatters.timeAgo(from: createdAt)
                    
                    if let parentText = data["parentPostText"] as? String {
                        let parentHandle = data["parentPostHandle"] as? String ?? "anonymous"
                        let replyDocId = doc.documentID
                        let parentPostId = doc.reference.parent.parent?.documentID ?? ""
                        group.addTask {
                            return MyReply(id: replyDocId, replyText: replyText, replyTime: replyTime, parentText: parentText, parentHandle: parentHandle, parentPostId: parentPostId, createdAt: createdAt)
                        }
                    } else {
                        guard let parentRef = doc.reference.parent.parent else { continue }
                        let replyDocId = doc.documentID
                        let parentPostId = parentRef.documentID
                        group.addTask {
                            let parentSnap = try? await parentRef.getDocumentAsync()
                            let parentData = parentSnap?.data()
                            return MyReply(id: replyDocId, replyText: replyText, replyTime: replyTime, parentText: parentData?["text"] as? String ?? "deleted post", parentHandle: parentData?["authorHandle"] as? String ?? "anonymous", parentPostId: parentPostId, createdAt: createdAt)
                        }
                    }
                }
                for await result in group {
                    if let result = result { results.append(result) }
                }
            }
            myReplies = results.sorted { $0.createdAt > $1.createdAt }
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
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "f0f1f3").ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .light)).foregroundColor(Color(hex: "999999"))
                        }
                        Spacer()
                        Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(Color.toskaTextDark)
                        Spacer()
                        Image(systemName: "xmark").font(.system(size: 14)).foregroundColor(.clear)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)
                    if isLoading {
                        Spacer(); ProgressView().tint(Color.toskaBlue); Spacer()
                    } else if users.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("no \(title) yet").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextLight)
                            Text("explore and connect with others").font(.system(size: 12)).foregroundColor(Color(hex: "cccccc"))
                        }
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(users.enumerated()), id: \.element.0) { index, user in
                                    Button { selectedUser = FollowUser(id: user.id, handle: user.handle) } label: {
                                                                            HStack(spacing: 12) {
                                                                                Text(user.handle).font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextDark)
                                                                                Spacer()
                                                                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .light)).foregroundColor(Color.toskaDivider)
                                                                            }
                                                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                                                        }
                                    .buttonStyle(.plain)
                                    if index < users.count - 1 {
                                                                            Rectangle().fill(Color(hex: "dfe1e5").opacity(0.5)).frame(height: 0.5).padding(.leading, 16)
                                                                        }
                                }
                                if users.count >= 50 {
                                    Text("showing your first 50 \(title)")
                                        .font(.system(size: 9)).foregroundColor(Color(hex: "cccccc"))
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                }
                            }
                        }
                    }
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
            .navigationBarHidden(true)
        } // closes NavigationStack
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
            users = fetched
            isLoading = false
        }
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
    
    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("edit reply").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { saveReply() } label: {
                        Text("save").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving ? Color.toskaDivider : Color.toskaBlue)
                            .cornerRadius(16)
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                
                Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
                
                ZStack(alignment: .topLeading) {
                    if replyText.isEmpty {
                        Text("say what you feel...")
                            .font(.custom("Georgia", size: 16)).foregroundColor(Color(hex: "c0c3ca"))
                            .padding(.horizontal, 18).padding(.top, 16)
                    }
                    TextEditor(text: $replyText)
                        .font(.custom("Georgia", size: 16)).foregroundColor(Color(hex: "1a1a1a"))
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
    }
    
    func saveReply() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !postId.isEmpty, !replyId.isEmpty else { return }
        isSaving = true
        Firestore.firestore().collection("posts").document(postId).collection("replies").document(replyId)
            .updateData(["text": trimmed, "editedAt": FieldValue.serverTimestamp()]) { error in
                Task { @MainActor in
                    isSaving = false
                    if error == nil {
                        replyText = trimmed
                        onSave()
                        dismiss()
                    }
                }
            }
    }
}
