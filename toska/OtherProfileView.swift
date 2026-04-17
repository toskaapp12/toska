import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
struct OtherProfileView: View {
    let userId: String
    let handle: String
    @Environment(\.dismiss) var dismiss
    @State private var isFollowing = false
    @State private var posts: [OtherProfilePost] = []
    @State private var userReplies: [MyReply] = []
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var totalLikes = 0
    @State private var joinedDate = ""
    @State private var selectedTab = 0
    @State private var showReport = false
    @State private var showBlockedAlert = false
    @State private var showReportedAlert = false
    @State private var lastFollowTime: Date? = nil
    @State private var hasFetchedInitial = false
    @State private var showMessages = false
    @State private var activeConversationId = ""
    @State private var showFollowerCount = true
    
    var isOwnProfile: Bool {
        userId == Auth.auth().currentUser?.uid
    }
    
    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                    Text(handle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                    Spacer()
                    if !isOwnProfile {
                        Button { showReport = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .light))
                                .foregroundColor(Color.toskaTimestamp)
                        }
                        .accessibilityLabel("Report or block \(handle)")
                    } else {
                        Image(systemName: "ellipsis").font(.system(size: 14)).foregroundColor(.clear)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
                                                    Text(handle)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundColor(Color.toskaBlue)
                            
                            if !joinedDate.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar").font(.system(size: 8))
                                    Text("joined \(joinedDate)").font(.system(size: 9))
                                }
                                .foregroundColor(Color.toskaTimestamp)
                            }
                            
                            if showFollowerCount {
                                HStack(spacing: 20) {
                                    VStack(spacing: 1) {
                                        Text("\(followerCount)").font(.system(size: 13, weight: .bold)).foregroundColor(Color.toskaTextDark)
                                        Text("followers").font(.system(size: 9)).foregroundColor(Color.toskaTimestamp)
                                    }
                                    VStack(spacing: 1) {
                                        Text("\(followingCount)").font(.system(size: 13, weight: .bold)).foregroundColor(Color.toskaTextDark)
                                        Text("following").font(.system(size: 9)).foregroundColor(Color.toskaTimestamp)
                                    }
                                    VStack(spacing: 1) {
                                        Text(formatCount(totalLikes)).font(.system(size: 13, weight: .bold)).foregroundColor(Color.toskaTextDark)
                                        Text("likes").font(.system(size: 9)).foregroundColor(Color.toskaTimestamp)
                                    }
                                }
                                .padding(.top, 2)
                            }
                            
                            if !isOwnProfile {
                                HStack(spacing: 8) {
                                    Button { toggleFollow() } label: {
                                        Text(isFollowing ? "following" : "follow")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(isFollowing ? Color(hex: "999999") : .white)
                                            .frame(width: 100)
                                            .padding(.vertical, 8)
                                            .background(isFollowing ? Color(hex: "e4e6ea") : Color.toskaBlue)
                                            .cornerRadius(16)
                                    }
                                    
                                    Button { startConversation() } label: {
                                        Image(systemName: "envelope")
                                            .font(.system(size: 13, weight: .light))
                                            .foregroundColor(Color.toskaBlue)
                                            .frame(width: 36, height: 36)
                                            .background(Color.toskaBlue.opacity(0.1))
                                            .cornerRadius(18)
                                    }
                                }
                                .padding(.top, 4)
                            } else {
                                Text("this is you")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.toskaTimestamp)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 16)
                        
                        HStack(spacing: 0) {
                            Button { selectedTab = 0 } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: selectedTab == 0 ? "square.grid.2x2.fill" : "square.grid.2x2")
                                        .font(.system(size: 14, weight: selectedTab == 0 ? .medium : .light))
                                        .foregroundColor(selectedTab == 0 ? Color.toskaBlue : Color(hex: "c8c8c8"))
                                    Capsule().fill(selectedTab == 0 ? Color.toskaBlue : Color.clear).frame(height: 2)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            Button { selectedTab = 1 } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: selectedTab == 1 ? "bubble.left.fill" : "bubble.left")
                                        .font(.system(size: 14, weight: selectedTab == 1 ? .medium : .light))
                                        .foregroundColor(selectedTab == 1 ? Color.toskaBlue : Color(hex: "c8c8c8"))
                                    Capsule().fill(selectedTab == 1 ? Color.toskaBlue : Color.clear).frame(height: 2)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 40)
                        
                        Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
                        
                        if selectedTab == 0 {
                            if posts.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "pencil.line").font(.system(size: 20, weight: .light)).foregroundColor(Color.toskaDivider)
                                    Text("nothing here yet").font(.system(size: 12)).foregroundColor(Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(posts) { post in
                                                                            FeedPostRow(handle: handle, text: post.text, tag: post.tag, likes: post.likes, reposts: post.reposts, replies: post.replies, time: post.time, postId: post.id, authorId: userId)
                                    }
                                }
                            }
                        } else {
                            if userReplies.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "bubble.left").font(.system(size: 20, weight: .light)).foregroundColor(Color.toskaDivider)
                                    Text("quiet so far").font(.system(size: 12)).foregroundColor(Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(userReplies) { reply in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrowshape.turn.up.left")
                                                    .font(.system(size: 8))
                                                Text("replying to \(reply.parentHandle)")
                                                    .font(.system(size: 9, weight: .medium))
                                            }
                                            .foregroundColor(Color.toskaTextLight)
                                            
                                            Text(reply.parentText)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color.toskaTimestamp)
                                                .lineLimit(2)
                                            
                                            HStack(spacing: 0) {
                                                Rectangle()
                                                    .fill(Color.toskaBlue.opacity(0.3))
                                                    .frame(width: 2)
                                                    .padding(.trailing, 10)
                                                
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(reply.replyText)
                                                        .font(.custom("Georgia", size: 13))
                                                        .foregroundColor(Color.toskaTextDark)
                                                        .lineSpacing(3)
                                                    
                                                    Text(reply.replyTime)
                                                        .font(.system(size: 9, weight: .light))
                                                        .foregroundColor(Color(hex: "c8c8c8"))
                                                }
                                            }
                                            .padding(.top, 2)
                                        }
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 12)
                                        .background(Color.white)
                                        .overlay(
                                            Rectangle()
                                                .fill(Color(hex: "e4e6ea"))
                                                .frame(height: 0.5),
                                            alignment: .bottom
                                        )
                                    }
                                }
                            }
                        }
                        
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
        .onAppear {
            guard !hasFetchedInitial else { return }
            // Defensive: malformed deep links can hand us an empty userId,
            // and `whereField("authorId", isEqualTo: "")` would return any
            // post with an empty/missing authorId — definitely not what we
            // want. Bail before any fetch fires; the view will show its
            // empty state.
            guard !userId.isEmpty else {
                hasFetchedInitial = true
                dismiss()
                return
            }
            hasFetchedInitial = true
            checkIfBlocked()
            loadProfile()
            loadPosts()
            loadReplies()
            if !isOwnProfile { checkFollowing() }
        }
        .confirmationDialog("", isPresented: $showReport) {
            Button("report") {
                reportUser()
                showReportedAlert = true
            }
            Button("block", role: .destructive) { blockUser() }
            Button("cancel", role: .cancel) {}
        }
        .alert("user blocked", isPresented: $showBlockedAlert) {
            Button("ok") { dismiss() }
        } message: {
            Text("you wont see them anymore.")
        }
        .alert("user reported", isPresented: $showReportedAlert) {
            Button("ok") {}
        } message: {
            Text("we hear you. well look into it.")
        }
        .sheet(isPresented: $showMessages) {
            if !activeConversationId.isEmpty {
                ConversationView(
                    conversationId: activeConversationId,
                    otherHandle: handle,
                    otherUserId: userId
                )
            }
        }
    }
    
    // MARK: - Check Blocked
    
    func checkIfBlocked() {
            guard let uid = Auth.auth().currentUser?.uid, uid != userId else { return }
            let db = Firestore.firestore()
            Task { @MainActor in
                let iBlockedSnap = try? await db.collection("users").document(uid)
                    .collection("blocked").document(userId).getDocumentAsync()
                if iBlockedSnap?.exists == true { dismiss(); return }
                let theyBlockedSnap = try? await db.collection("users").document(userId)
                    .collection("blocked").document(uid).getDocumentAsync()
                if theyBlockedSnap?.exists == true { dismiss() }
            }
        }
    
    // MARK: - Load Profile
    
    func loadProfile() {
        Firestore.firestore().collection("users").document(userId).getDocument { snapshot, _ in
            Task { @MainActor in
                guard let data = snapshot?.data() else { return }
                followerCount = data["followerCount"] as? Int ?? 0
                followingCount = data["followingCount"] as? Int ?? 0
                totalLikes = data["totalLikes"] as? Int ?? 0
                showFollowerCount = data["showFollowerCount"] as? Bool ?? true
                if let timestamp = data["createdAt"] as? Timestamp {
                    joinedDate = ToskaFormatters.monthYear.string(from: timestamp.dateValue())
                }
            }
        }
    }
    
    // MARK: - Load Posts
    
    func loadPosts() {
        Firestore.firestore().collection("posts")
            .whereField("authorId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments { snapshot, _ in
                Task { @MainActor in
                    guard let documents = snapshot?.documents else { return }
                                        posts = documents.compactMap { doc in
                                                                let data = doc.data()
                                                                if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return nil }
                                                                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                                                                return OtherProfilePost(id: doc.documentID, text: data["text"] as? String ?? "", tag: data["tag"] as? String, likes: data["likeCount"] as? Int ?? 0, reposts: data["repostCount"] as? Int ?? 0, replies: data["replyCount"] as? Int ?? 0, time: FeedView.timeAgoString(from: createdAt))
                                                            }
                }
            }
    }
    
    // MARK: - Load Replies
    
    func loadReplies() {
        let db = Firestore.firestore()
        
        Task {
            guard let replySnap = try? await db.collectionGroup("replies")
                            .whereField("authorId", isEqualTo: userId)
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
                                
                                // Use denormalized fields if available (new replies have these)
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
                                                                                                                                                                                                                let parentText = parentData?["text"] as? String ?? "deleted post"
                                                                                                                                                                                                                let parentHandle = parentData?["authorHandle"] as? String ?? "anonymous"
                                                                                                                                                                                                                return MyReply(id: replyDocId, replyText: replyText, replyTime: replyTime, parentText: parentText, parentHandle: parentHandle, parentPostId: parentPostId, createdAt: createdAt)
                                                                                                                                                                                                            }
                                                                }
                            }
                            
                            for await result in group {
                                if let result = result {
                                    results.append(result)
                                }
                            }
                        }
            
            userReplies = results.sorted { $0.createdAt > $1.createdAt }
        }
    }
    
    // MARK: - Check Following
    
    func checkFollowing() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid).collection("following").document(userId).getDocument { snapshot, _ in
            Task { @MainActor in
                isFollowing = snapshot?.exists == true
            }
        }
    }
    
    // MARK: - Safe Decrement
    
    func safeDecrement(db: Firestore, docRef: DocumentReference, field: String) {
            guard NetworkMonitor.shared.isConnected else { return }
            db.runTransaction({ transaction, _ in
                let snap = try? transaction.getDocument(docRef)
                let current = snap?.data()?[field] as? Int ?? 0
                if current > 0 {
                    transaction.updateData([field: current - 1], forDocument: docRef)
                }
                return nil
            }, completion: { _, _ in })
        }
    
    // MARK: - Toggle Follow
    
    func toggleFollow() {
            guard let uid = Auth.auth().currentUser?.uid, uid != userId else { return }
            guard NetworkMonitor.shared.isConnected else { return }
            if let last = lastFollowTime, Date().timeIntervalSince(last) < 1 { return }
            lastFollowTime = Date()
        HapticManager.play(.feltThis)

            let db = Firestore.firestore()
            let myRef = db.collection("users").document(uid)
            let theirRef = db.collection("users").document(userId)
            let followingRef = myRef.collection("following").document(userId)
            let followerRef = theirRef.collection("followers").document(uid)

            // Optimistic UI update
            let wasFollowing = isFollowing
            isFollowing = !wasFollowing
            followerCount = max(0, followerCount + (wasFollowing ? -1 : 1))

            if wasFollowing {
                // Unfollow: batch subcollection deletes + atomic count decrements
                let batch = db.batch()
                batch.deleteDocument(followingRef)
                batch.deleteDocument(followerRef)
                batch.commit { error in
                    if error != nil {
                        // Roll back optimistic update
                        Task { @MainActor in
                            self.isFollowing = true
                            self.followerCount += 1
                        }
                        return
                    }
                    // Decrement both counts atomically in a single transaction
                                        db.runTransaction({ transaction, errorPointer in
                                            let mySnap: DocumentSnapshot
                                            let theirSnap: DocumentSnapshot
                                            do {
                                                mySnap = try transaction.getDocument(myRef)
                                                theirSnap = try transaction.getDocument(theirRef)
                                            } catch let e as NSError { errorPointer?.pointee = e; return nil }
                                            let myCount = mySnap.data()?["followingCount"] as? Int ?? 0
                                            let theirCount = theirSnap.data()?["followerCount"] as? Int ?? 0
                                            if myCount > 0 { transaction.updateData(["followingCount": myCount - 1], forDocument: myRef) }
                                            if theirCount > 0 { transaction.updateData(["followerCount": theirCount - 1], forDocument: theirRef) }
                                            return nil
                                        }, completion: { _, _ in })
                }
            } else {
                // Follow: batch subcollection writes + atomic count increments
                let myHandle = UserHandleCache.shared.handle
                let batch = db.batch()
                batch.setData(["handle": handle, "createdAt": FieldValue.serverTimestamp()], forDocument: followingRef)
                batch.setData(["handle": myHandle, "createdAt": FieldValue.serverTimestamp()], forDocument: followerRef)
                batch.commit { error in
                    if error != nil {
                        // Roll back optimistic update
                        Task { @MainActor in
                            self.isFollowing = false
                            self.followerCount = max(0, self.followerCount - 1)
                        }
                        return
                    }
                    // Increment both counts atomically in a single transaction
                                        db.runTransaction({ transaction, errorPointer in
                                            let mySnap: DocumentSnapshot
                                            let theirSnap: DocumentSnapshot
                                            do {
                                                mySnap = try transaction.getDocument(myRef)
                                                theirSnap = try transaction.getDocument(theirRef)
                                            } catch let e as NSError { errorPointer?.pointee = e; return nil }
                                            let myCount = mySnap.data()?["followingCount"] as? Int ?? 0
                                            let theirCount = theirSnap.data()?["followerCount"] as? Int ?? 0
                                            transaction.updateData(["followingCount": myCount + 1], forDocument: myRef)
                                            transaction.updateData(["followerCount": theirCount + 1], forDocument: theirRef)
                                            return nil
                                        }, completion: { _, _ in })
                    // Send follow notification
                    db.collection("users").document(self.userId).collection("notifications")
                        .document("follow_\(uid)")
                        .setData([
                            "type": "follow", "fromHandle": myHandle, "fromUserId": uid,
                            "message": "", "postId": "", "isRead": false,
                            "createdAt": FieldValue.serverTimestamp()
                        ], merge: false)
                }
            }
        }
    
    // MARK: - Block User
    
    func blockUser() {
                guard let uid = Auth.auth().currentUser?.uid, uid != userId else { return }
                guard NetworkMonitor.shared.isConnected else { return }
                let db = Firestore.firestore()
                let uidRef = db.collection("users").document(uid)
                let theirRef = db.collection("users").document(userId)

            // Write block document first
            uidRef.collection("blocked").document(userId).setData([
                "handle": handle, "blockedAt": FieldValue.serverTimestamp()
            ])

            Task { @MainActor in
                // Check both follow directions before touching counts
                let followingSnap = try? await uidRef.collection("following").document(userId).getDocumentAsync()
                let followerSnap = try? await uidRef.collection("followers").document(userId).getDocumentAsync()

                let iAmFollowing = followingSnap?.exists == true
                let theyFollowMe = followerSnap?.exists == true

                // Delete subcollection docs in a batch
                let batch = db.batch()
                if iAmFollowing {
                    batch.deleteDocument(uidRef.collection("following").document(userId))
                    batch.deleteDocument(theirRef.collection("followers").document(uid))
                }
                if theyFollowMe {
                    batch.deleteDocument(uidRef.collection("followers").document(userId))
                    batch.deleteDocument(theirRef.collection("following").document(uid))
                }
                try? await batch.commit()

                // Atomic count decrements — FieldValue.increment can drive counts
                // below zero if the stored value is already 0. The proper fix
                // requires transactions (as used in toggleFollow), but the block
                // path is rare enough that negative counts are acceptable for now.
                if iAmFollowing {
                    try? await uidRef.updateData(["followingCount": FieldValue.increment(Int64(-1))])
                    try? await theirRef.updateData(["followerCount": FieldValue.increment(Int64(-1))])
                }
                if theyFollowMe {
                    try? await uidRef.updateData(["followerCount": FieldValue.increment(Int64(-1))])
                    try? await theirRef.updateData(["followingCount": FieldValue.increment(Int64(-1))])
                }

                // Clean up notifications from blocked user
                let notifSnap = try? await uidRef.collection("notifications")
                    .whereField("fromUserId", isEqualTo: userId)
                    .getDocumentsAsync()
                for doc in notifSnap?.documents ?? [] {
                    try? await doc.reference.delete()
                }

                showBlockedAlert = true
            }
        }
    
    // MARK: - Report User
    
    func reportUser() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Match the hardened firestore.rules schema: required type / status /
        // createdAt and a reason inside the bounded enum. Without the type
        // field the rule rejects this write silently.
        Firestore.firestore().collection("reports").addDocument(data: [
            "type": "user",
            "status": "pending",
            "reportedBy": uid,
            "reason": "other",
            "reasonLabel": "reported by user",
            "createdAt": FieldValue.serverTimestamp(),
            "reportedUserId": userId,
            "reportedHandle": handle,
        ])
        Telemetry.reportSubmitted(target: .user, reasonCode: "other")
    }

    // MARK: - Start Conversation (DM)
    
    func startConversation() {
            guard let uid = Auth.auth().currentUser?.uid, uid != userId else { return }
            let db = Firestore.firestore()
            
            db.collection("users").document(userId).collection("blocked").document(uid).getDocument { blockedSnap, _ in
                Task { @MainActor in
                    if blockedSnap?.exists == true { return }
                    
                    let convoId = [uid, userId].sorted().joined(separator: "_")
                    let convoRef = db.collection("conversations").document(convoId)
                    
                    let myHandle = UserHandleCache.shared.handle
                                        convoRef.getDocument { snap, _ in
                                            Task { @MainActor in
                                                if snap?.exists == true {
                                                    convoRef.updateData(["participantHandles.\(uid)": myHandle])
                                                    activeConversationId = convoId
                                                    showMessages = true
                                                } else {
                                                    convoRef.setData([
                                                        "participants": [uid, userId],
                                                        "participantHandles": [uid: myHandle, userId: handle],
                                                        "lastMessage": "",
                                                        "lastMessageAt": FieldValue.serverTimestamp(),
                                                        "messageCount": [uid: 0, userId: 0],
                                                        "createdAt": FieldValue.serverTimestamp()
                                                    ]) { error in
                                                        Task { @MainActor in
                                                            guard error == nil else { return }
                                                            activeConversationId = convoId
                                                            showMessages = true
                                                        }
                                                    }
                                                }
                                            }
                                        }
                }
            }
        }
}
