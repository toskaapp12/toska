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
    @State private var showReportFailedAlert = false
    @State private var showBlockFailedAlert = false
    @State private var lastFollowTime: Date? = nil
    @State private var hasFetchedInitial = false
    @State private var showFollowerCount = false
    // H2: surface a profile-load failure instead of showing a blank/default
    // header forever. Set when the user-doc read errors with no data; the
    // banner's retry re-runs the full initial load.
    @State private var profileLoadFailed = false
    
    var isOwnProfile: Bool {
        userId == Auth.auth().currentUser?.uid
    }
    
    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                ToskaHeader(
                    title: handle,
                    onBack: { dismiss() }
                ) {
                    if !isOwnProfile {
                        // Menu (popover) instead of a .confirmationDialog so
                        // the report/block options drop down directly under
                        // the ⋯ button — the dialog rendered as a system
                        // action sheet pinned to the screen bottom, which
                        // felt disconnected from where the user tapped.
                        Menu {
                            Button {
                                reportUser()
                            } label: {
                                Label("report", systemImage: "flag")
                            }
                            Button(role: .destructive) {
                                blockUser()
                            } label: {
                                Label("block", systemImage: "person.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundColor(Color.toskaTimestamp)
                                // Larger hit target so the Menu reliably
                                // opens — the bare 17pt image was too small
                                // to land a tap cleanly.
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Report or block \(handle)")
                    }
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if profileLoadFailed {
                            ToskaErrorBanner("couldn't load this profile — check your connection") {
                                profileLoadFailed = false
                                loadProfile()
                                loadPosts()
                                loadReplies()
                            }
                        }
                        // Profile info — Threads-y treatment: handle was
                        // already shown big in the ToskaHeader above; this
                        // section is the secondary info (join date, stats,
                        // primary follow + message CTAs). Bumped sizes:
                        // counts 13pt → 16pt bold, labels 9pt → 12pt;
                        // calendar/join 8-9pt → 11pt; follow button text
                        // 12pt → 14pt with bigger pill.
                        VStack(alignment: .leading, spacing: 16) {
                            if !joinedDate.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar").font(.system(size: 10))
                                    Text("joined \(joinedDate)").font(ToskaFont.sans(11))
                                }
                                .foregroundColor(Color.toskaTimestamp)
                            }

                            if showFollowerCount {
                                HStack(spacing: 24) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(followerCount)").font(ToskaFont.sans(16, weight: .bold)).foregroundColor(Color.toskaTextDark)
                                        Text("followers").font(ToskaFont.sans(12)).foregroundColor(Color.toskaTimestamp)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(followingCount)").font(ToskaFont.sans(16, weight: .bold)).foregroundColor(Color.toskaTextDark)
                                        Text("following").font(ToskaFont.sans(12)).foregroundColor(Color.toskaTimestamp)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(formatCount(totalLikes)).font(ToskaFont.sans(16, weight: .bold)).foregroundColor(Color.toskaTextDark)
                                        Text("felt").font(ToskaFont.sans(12)).foregroundColor(Color.toskaTimestamp)
                                    }
                                }
                            }

                            if !isOwnProfile {
                                // DMs were cut as a product decision — Toska is
                                // posts + replies + reposts, not a chat app.
                                // Envelope button removed; conversation/messages
                                // code stays in place for legacy data only.
                                Button { toggleFollow() } label: {
                                    Text(isFollowing ? "following" : "follow")
                                        .font(ToskaFont.sans(13, weight: .semibold))
                                        .foregroundColor(isFollowing ? Color(hex: "888888") : .white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(isFollowing ? Color.toskaBorderLight : Color.toskaBlue)
                                        .cornerRadius(22)
                                }
                            } else {
                                Text("this is you")
                                    .font(ToskaFont.sans(11))
                                    .foregroundColor(Color.toskaTimestamp)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                        
                        HStack(spacing: 0) {
                            Button { selectedTab = 0 } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: selectedTab == 0 ? "square.grid.2x2.fill" : "square.grid.2x2")
                                        .font(.system(size: 14, weight: selectedTab == 0 ? .medium : .light))
                                        .foregroundColor(selectedTab == 0 ? Color.toskaBlue : Color.toskaInactiveGray)
                                    Capsule().fill(selectedTab == 0 ? Color.toskaBlue : Color.clear).frame(height: 2)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .accessibilityLabel("posts")
                            Button { selectedTab = 1 } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: selectedTab == 1 ? "bubble.left.fill" : "bubble.left")
                                        .font(.system(size: 14, weight: selectedTab == 1 ? .medium : .light))
                                        .foregroundColor(selectedTab == 1 ? Color.toskaBlue : Color.toskaInactiveGray)
                                    Capsule().fill(selectedTab == 1 ? Color.toskaBlue : Color.clear).frame(height: 2)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .accessibilityLabel("replies")
                        }
                        .padding(.horizontal, 40)
                        
                        Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                        
                        if selectedTab == 0 {
                            if posts.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "pencil.line")
                                        .font(.system(size: 28, weight: .ultraLight))
                                        .foregroundColor(Color.toskaBlue.opacity(0.4))
                                        .padding(.bottom, 4)
                                    Text("nothing here yet")
                                        .font(.custom("Georgia-Italic", size: 18))
                                        .foregroundColor(Color.toskaTextLight)
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
                                VStack(spacing: 16) {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 28, weight: .ultraLight))
                                        .foregroundColor(Color.toskaBlue.opacity(0.4))
                                        .padding(.bottom, 4)
                                    Text("quiet so far")
                                        .font(.custom("Georgia-Italic", size: 18))
                                        .foregroundColor(Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(userReplies) { reply in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrowshape.turn.up.left")
                                                    .font(.system(size: 8))
                                                Text("replying to \(reply.parentHandle)")
                                                    .font(ToskaFont.sans(11, weight: .medium))
                                            }
                                            .foregroundColor(Color.toskaTextLight)
                                            
                                            Text(reply.parentText)
                                                .font(ToskaFont.sans(11))
                                                .foregroundColor(Color.toskaTimestamp)
                                                .lineLimit(2)
                                            
                                            HStack(spacing: 0) {
                                                Rectangle()
                                                    .fill(Color.toskaBlue.opacity(0.3))
                                                    .frame(width: 2)
                                                    .padding(.trailing, 8)
                                                
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(reply.replyText)
                                                        .font(.custom("Georgia", size: 13))
                                                        .foregroundColor(Color.toskaTextDark)
                                                        .lineSpacing(3)
                                                    
                                                    Text(reply.replyTime)
                                                        .font(ToskaFont.sans(11, weight: .light))
                                                        .foregroundColor(Color.toskaInactiveGray)
                                                }
                                            }
                                            .padding(.top, 4)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .background(Color.white)
                                        .overlay(
                                            Rectangle()
                                                .fill(Color.toskaBorderLight)
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
            // Block enforcement is the gate: loadProfile/loadPosts/loadReplies
            // run only AFTER we confirm neither side has blocked the other.
            // (Previously they fired in parallel with the async check, so a
            // blocked user's content could paint before dismiss() landed.)
            loadIfNotBlocked()
            if !isOwnProfile { checkFollowing() }
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
        .alert("couldnt report", isPresented: $showReportFailedAlert) {
            Button("ok") {}
        } message: {
            Text("something went wrong. please try again in a bit.")
        }
        .alert("couldnt block", isPresented: $showBlockFailedAlert) {
            Button("ok") {}
        } message: {
            Text("something went wrong. check your connection and try again.")
        }
        // Tapping any bottom-tab button (home, trending, notifications, profile)
        // posts .dismissAllSheets via MainTabView. Pop ourselves on receive so
        // a user reading someone's profile lands on the destination tab's root
        // instead of returning to find the profile still pushed under it
        // (Twitter / Threads pattern: tapping a tab always shows that tab's
        // root). PostDetailView already does the same.
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            dismiss()
        }
        .hidesAppTabBar()
    }

    // MARK: - Check Blocked
    
    func loadIfNotBlocked() {
            // Own profile or unauthed: no block relationship to check — load directly.
            guard let uid = Auth.auth().currentUser?.uid, uid != userId else {
                loadProfile(); loadPosts(); loadReplies()
                return
            }
            let db = Firestore.firestore()
            Task { @MainActor in
                do {
                    let iBlockedSnap = try await db.collection("users").document(uid)
                        .collection("blocked").document(userId).getDocumentAsync()
                    if iBlockedSnap.exists { dismiss(); return }
                    let theyBlockedSnap = try await db.collection("users").document(userId)
                        .collection("blocked").document(uid).getDocumentAsync()
                    if theyBlockedSnap.exists { dismiss(); return }
                    // Confirmed not blocked in either direction — safe to render.
                    loadProfile(); loadPosts(); loadReplies()
                } catch {
                    // Fail CLOSED. A block is a safety guarantee in an anonymous
                    // app; if we can't determine block state (network/permission
                    // error), do NOT render content that might belong to a
                    // blocked user. Dismiss rather than fail open.
                    print("⚠️ OtherProfileView block check failed, failing closed: \(error)")
                    dismiss()
                }
            }
        }
    
    // MARK: - Load Profile
    
    func loadProfile() {
        Firestore.firestore().collection("users").document(userId).getDocument { snapshot, error in
            Task { @MainActor in
                guard let data = snapshot?.data() else {
                    // Distinguish a real read failure (show retry) from a
                    // genuinely missing/deleted user doc (leave the banner off).
                    if error != nil { profileLoadFailed = true }
                    return
                }
                profileLoadFailed = false
                followerCount = data["followerCount"] as? Int ?? 0
                followingCount = data["followingCount"] as? Int ?? 0
                totalLikes = data["totalLikes"] as? Int ?? 0
                // F-1 (2026-06-16): default OFF to match every signup path and
                // Settings (all write/read false). A user-doc missing this field
                // (legacy/partial doc) must NOT expose follower counts.
                showFollowerCount = data["showFollowerCount"] as? Bool ?? false
                if let timestamp = data["createdAt"] as? Timestamp {
                    joinedDate = ToskaFormatters.monthYear.string(from: timestamp.dateValue())
                }
            }
        }
    }
    
    // MARK: - Load Posts
    
    func loadPosts() {
        Firestore.firestore().collection("posts")
            // moderationStatus filter required by firestore.rules
            // 2026-05-31 (see FeedViewModel.fetchPosts comment). This
            // view shows OTHER users' posts, so isOwner doesn't apply.
            .whereField("moderationStatus", isEqualTo: "live")
            .whereField("authorId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments { snapshot, _ in
                Task { @MainActor in
                    guard let documents = snapshot?.documents else { return }
                                        posts = documents.compactMap { doc in
                                                                let data = doc.data()
                                                                if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return nil }
                                                                // Hide server-flagged posts — keeps this view consistent with the main
                                                                // feed's filterBlocked behavior so a moderated post doesn't appear on
                                                                // someone's profile after it was hidden from the feed.
                                                                if data["flagged"] as? Bool == true { return nil }
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
        // Capture the uid this read is for. After the async round-trip the
        // signed-in user may have changed (account switch on the same device);
        // without rechecking, account A's follow relationship would be stamped
        // into account B's view of this profile. Mirrors the recheck pattern in
        // ProfileView.loadPresenceStreak / PostDetailView.checkIfLiked.
        let capturedUid = uid
        Firestore.firestore().collection("users").document(uid).collection("following").document(userId).getDocument { snapshot, _ in
            Task { @MainActor in
                guard Auth.auth().currentUser?.uid == capturedUid else { return }
                isFollowing = snapshot?.exists == true
            }
        }
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
                // Unfollow: delete subcollection docs. Counter decrements
                // handled by Cloud Function on follow doc delete.
                let batch = db.batch()
                batch.deleteDocument(followingRef)
                batch.deleteDocument(followerRef)
                batch.commit { error in
                    if error != nil {
                        // Roll back optimistic update — but only if the active
                        // user is still the one who issued this action. Without
                        // the recheck, a sign-out (or account switch) between
                        // the tap and the rollback callback would mutate the
                        // new user's state with the previous user's revert.
                        Task { @MainActor in
                            guard Auth.auth().currentUser?.uid == uid else { return }
                            self.isFollowing = true
                            self.followerCount += 1
                        }
                        return
                    }
                }
            } else {
                // Follow: batch subcollection writes + atomic count increments.
                // Resolve the handle async first: a cold UserHandleCache returns
                // the "anonymous" sentinel until its first snapshot lands, and
                // writing that into their /followers doc + follow notification
                // PERSISTS ("anonymous followed you" / "anonymous" in their
                // followers list) — the reverse-index re-fetch only refreshes
                // EMPTY handles. Same user-doc fallback the reply/repost paths use.
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    var myHandle = UserHandleCache.shared.handle
                    if myHandle == "anonymous" {
                        if let snap = try? await db.collection("users").document(uid).getDocumentAsync(),
                           let h = snap.data()?["handle"] as? String, !h.isEmpty {
                            myHandle = h
                        }
                    }
                    let batch = db.batch()
                    batch.setData(["handle": handle, "createdAt": FieldValue.serverTimestamp()], forDocument: followingRef)
                    batch.setData(["handle": myHandle, "createdAt": FieldValue.serverTimestamp()], forDocument: followerRef)
                    batch.commit { error in
                    if error != nil {
                        // Roll back optimistic update — same uid recheck as
                        // the unfollow path above.
                        Task { @MainActor in
                            guard Auth.auth().currentUser?.uid == uid else { return }
                            self.isFollowing = false
                            self.followerCount = max(0, self.followerCount - 1)
                        }
                        return
                    }
                    // Counter increments handled by Cloud Function on follow doc create.
                    // Send follow notification
                    // `message` is no longer written — the notification rule
                    // rejects the field. NotificationsView's follow case uses
                    // fixed copy ("@handle followed you") and never read it.
                    db.collection("users").document(self.userId).collection("notifications")
                        .document("follow_\(uid)")
                        .setData([
                            "type": "follow", "fromHandle": myHandle, "fromUserId": uid,
                            "postId": "", "isRead": false,
                            "createdAt": FieldValue.serverTimestamp()
                        ], merge: false)
                    }
                }
            }
        }

    // MARK: - Block User
    
    func blockUser() {
                guard let uid = Auth.auth().currentUser?.uid, uid != userId else { return }
                // Offline: surface it instead of a silent no-op tap.
                guard NetworkMonitor.shared.isConnected else { showBlockFailedAlert = true; return }
                let db = Firestore.firestore()
                let uidRef = db.collection("users").document(uid)
                let theirRef = db.collection("users").document(userId)

            Task { @MainActor in
                // Route the block through BlockedUsersCache (optimistic local
                // hide + revert on failure) but AWAIT the result and gate the
                // "user blocked" confirmation + dismiss on it. Previously this was
                // fire-and-forget, so a failed write still showed "you wont see
                // them anymore" and navigated away while the block didn't persist
                // — the blocked user's content would reappear.
                let blocked = await BlockedUsersCache.shared.block(userId, handle: handle)
                guard blocked else { showBlockFailedAlert = true; return }

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

                // Counter decrements handled by Cloud Function on follow doc delete.

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
        ]) { error in
            // Only confirm success when the write actually lands — a rules
            // denial otherwise showed a false "user reported" alert.
            if error != nil {
                showReportFailedAlert = true
            } else {
                Telemetry.reportSubmitted(target: .user, reasonCode: "other")
                showReportedAlert = true
            }
        }
    }

    // startConversation was removed when DMs were cut as a product decision.
    // ConversationView / MessagesListView and the Firestore conversations
    // collection still exist for legacy data, but no UI surface in the app
    // creates new conversations anymore.
}
