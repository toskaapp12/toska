import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

struct ThreadedReply: Identifiable {
    let id: String
    let handle: String
    let text: String
    let likes: Int
    let time: String
    let authorId: String
    let parentReplyId: String?
    var children: [ThreadedReply]
}

@MainActor
struct PostDetailView: View {
    let postId: String
    let handle: String
    let text: String
    let tag: String?
    let likes: Int
    let reposts: Int
    let replies: Int
    let time: String
    let authorId: String

    let initialIsLiked: Bool
    let initialIsSaved: Bool
    let initialIsReposted: Bool

    init(postId: String, handle: String, text: String, tag: String?, likes: Int, reposts: Int, replies: Int, time: String, authorId: String = "", isAlreadyLiked: Bool = false, isAlreadySaved: Bool = false, isAlreadyReposted: Bool = false) {
        self.postId = postId
        self.handle = handle
        self.text = text
        self.tag = tag
        self.likes = likes
        self.reposts = reposts
        self.replies = replies
        self.time = time
        self.authorId = authorId
        self.initialIsLiked = isAlreadyLiked
        self.initialIsSaved = isAlreadySaved
        self.initialIsReposted = isAlreadyReposted
    }

    @Environment(\.dismiss) var dismiss
    @FocusState private var replyFocused: Bool
    @State private var replyText = ""
    @State private var isLiked = false
    @State private var isSaved = false
    @State private var isReposted = false
    @State private var likeCount: Int = 0
    @State private var localRepostCount: Int = 0
    @State private var replyList: [ThreadedReply] = []
    @State private var replyingToId: String? = nil
    @State private var replyingToHandle: String? = nil
    @State private var showReport = false
    @State private var showShareCard = false
    @State private var showOtherProfile = false
    @State private var authorUserId = ""
    @State private var isAuthorIdLoading = true
    @State private var likePulse = false
    @State private var likePulseTask: Task<Void, Never>? = nil
    @State private var liveListener: ListenerRegistration? = nil
    @State private var suppressListenerUntil: Date = .distantPast
    @State private var showDeleteAlert = false
    @State private var showEditSheet = false
    @State private var editText = ""
    @State private var isDeleting = false
    @State private var deleteError = ""
    @State private var postText: String = ""
    @State private var showBlockedAlert = false
    @State private var showReportedAlert = false
    @State private var showReplyNameWarning = false
    @State private var showReplyContentWarning = false
    @State private var replyContentWarningMessage = ""
    @State private var showReplyGentleCheck = false
    @State private var pendingReplyText = ""
    @State private var replyGentleCheckLevel: CrisisLevel = .soft
    @State private var replyGifUrl: String? = nil
    @State private var showReplyGifPicker = false
    @State private var activeConversation: ConversationSelection? = nil
    @State private var isLetter = false

    var isOwnPost: Bool {
        authorUserId == Auth.auth().currentUser?.uid
    }

    // MARK: - Body

    var body: some View {
        mainContent
            .safeAreaInset(edge: .bottom, spacing: 0) { replyBarView }
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(false)
            .onAppear {
                            postText = text
                            likeCount = likes
                            localRepostCount = reposts
                            if !postId.isEmpty {
                                Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, _ in
                                    Task { @MainActor in
                                        if snapshot?.data()?["isLetter"] as? Bool == true { isLetter = true }
                                    }
                                }
                            }
                            isLiked = initialIsLiked
                            isSaved = initialIsSaved
                            isReposted = initialIsReposted
                            if !postId.isEmpty {
                                checkIfLiked()
                                checkIfSaved()
                                checkIfReposted()
                            }
                            fetchReplies()
                            if !authorId.isEmpty {
                                authorUserId = authorId
                                isAuthorIdLoading = false
                            } else {
                                isAuthorIdLoading = true
                                lookupAuthorId()
                            }
                            startLiveListener()
                        }            .onDisappear {
                            liveListener?.remove()
                            liveListener = nil
                            replyListener?.remove()
                            replyListener = nil
                            likePulseTask?.cancel()
                            likePulseTask = nil
                        }
            .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                          dismiss()
                      }            .confirmationDialog(isOwnPost ? "your post" : "", isPresented: $showReport) {
                if isOwnPost {
                    Button("edit post") { editText = postText; showEditSheet = true }
                    Button("delete post", role: .destructive) { showDeleteAlert = true }
                    Button("cancel", role: .cancel) {}
                } else {
                    Button("report") { reportPost(); showReportedAlert = true }
                    Button("block", role: .destructive) { blockUser() }
                    Button("cancel", role: .cancel) {}
                }
            }
            .alert("couldn't delete", isPresented: .init(get: { !deleteError.isEmpty }, set: { if !$0 { deleteError = "" } })) {
                Button("ok") { deleteError = "" }
            } message: { Text(deleteError) }
            .alert("delete this post?", isPresented: $showDeleteAlert) {
                            Button("cancel", role: .cancel) {}
                            Button("delete", role: .destructive) { deletePost() }
                        } message: {
                            Text("this is permanent. it'll be gone for everyone.")
                        }
            .alert("user blocked", isPresented: $showBlockedAlert) {
                Button("ok") { dismiss() }
            } message: { Text("you won't see posts from this person anymore.") }
            .alert("post reported", isPresented: $showReportedAlert) {
                Button("ok") {}
            } message: { Text("thanks for letting us know. we'll review this post.") }
            .alert("hold on", isPresented: $showReplyContentWarning) {
                Button("edit") {}
            } message: { Text(replyContentWarningMessage) }
            .alert("keep it anonymous", isPresented: $showReplyNameWarning) {
                Button("edit") {}
                Button("reply anyway", role: .destructive) {
                    if let level = crisisCheckLevelRespectingSetting(for: pendingReplyText) {
                        replyGentleCheckLevel = level
                        showReplyGentleCheck = true
                    } else {
                        postReplyNow(pendingReplyText)
                    }
                }
            } message: { Text("your reply may include a name or identifying info. toska is anonymous for everyone.") }
            .overlay {
                if showReplyGentleCheck {
                    CrisisCheckInView(
                        isPresented: $showReplyGentleCheck,
                        level: replyGentleCheckLevel,
                        onProceed: { postReplyNow(pendingReplyText) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showReplyGentleCheck)
            .sheet(isPresented: $showEditSheet) {
                EditPostView(postId: postId, isLetter: isLetter, currentText: $postText, editText: $editText)
            }
            .sheet(isPresented: $showShareCard) {
                ShareCardView(text: postText, handle: handle, feltCount: likeCount, tag: tag)
            }
            .sheet(isPresented: $showOtherProfile) {
                            OtherProfileView(userId: authorUserId, handle: handle)
                        }
            .sheet(isPresented: $showReplyGifPicker) {
                GifPickerView { url in replyGifUrl = url }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $activeConversation) { convo in
                ConversationView(conversationId: convo.id, otherHandle: convo.handle, otherUserId: convo.userId)
            }
    }

    // MARK: - Main Content

    var mainContent: some View {
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
                    Text("post")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { showReport = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.toskaTimestamp)
                    }
                    .opacity(isAuthorIdLoading ? 0 : 1)
                    .accessibilityLabel(isOwnPost ? "Edit or delete post" : "Report or block")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        postHeaderSection
                            .padding(.horizontal, 18)
                            .padding(.top, 14)

                        if replyList.isEmpty {
                                                    VStack(spacing: 10) {
                                                        Text("\"some words just need\na witness.\"")
                                                            .font(.custom("Georgia-Italic", size: 18))
                                                            .foregroundColor(Color.toskaTimestamp)
                                                            .multilineTextAlignment(.center)
                                                            .lineSpacing(4)
                                                        Text("be the first to reply")
                                                            .font(.system(size: 11))
                                                            .foregroundColor(Color.toskaDivider)
                                                    }
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 40)
                        } else {
                            LazyVStack(spacing: 0) {
                                let flat = flattenReplies(replyList)
                                ForEach(Array(flat.enumerated()), id: \.element.id) { index, item in
                                    let indent = CGFloat(item.depth) * 24
                                    SwipeToReplyRow(item: item, indent: indent, onReply: {
                                        replyingToId = item.reply.id
                                        replyingToHandle = item.reply.handle
                                        replyFocused = true
                                    }, postId: postId)
                                    if index < flat.count - 1 {
                                        Rectangle()
                                            .fill(Color(hex: "e4e6ea").opacity(item.depth > 0 ? 0.3 : 0.5))
                                            .frame(height: 0.5)
                                            .padding(.leading, 18 + indent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reply Bar

    var replyBarView: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)

            if let gifUrl = replyGifUrl, let url = URL(string: gifUrl) {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 100).cornerRadius(8)
                                    .transition(.opacity)
                            case .failure:
                                Color(hex: "e8eaed").frame(width: 80, height: 60).cornerRadius(8)
                                    .overlay(
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.system(size: 12, weight: .light))
                                            .foregroundColor(Color.toskaTimestamp)
                                    )
                            default:
                                Color(hex: "e8eaed").frame(width: 80, height: 60).cornerRadius(8)
                                    .overlay(ProgressView().scaleEffect(0.5).tint(Color.toskaTimestamp))
                            }
                        }
                        Button { withAnimation { replyGifUrl = nil } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Color(hex: "999999"))
                                .background(Circle().fill(.white))
                        }
                        .offset(x: -2, y: 2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            if let handle = replyingToHandle {
                HStack(spacing: 6) {
                    Text("replying to \(handle)")
                        .font(.system(size: 11))
                        .foregroundColor(Color.toskaBlue)
                    Spacer()
                    Button {
                        replyingToId = nil
                        replyingToHandle = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color.toskaTimestamp)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            HStack(spacing: 8) {
                TextField("say what you feel...", text: $replyText)
                    .font(.system(size: 13))
                    .focused($replyFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(hex: "e8eaed"))
                    .cornerRadius(20)
                    .onChange(of: replyText) { _, newValue in
                        if newValue.count > 500 { replyText = String(newValue.prefix(500)) }
                    }
                Button { sendReply() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(
                            replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyGifUrl == nil
                                ? Color.toskaDivider : Color.toskaBlue
                        )
                }
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyGifUrl == nil)
            }
            .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
        .background(Color.white.ignoresSafeArea(edges: .bottom))
           }

    // MARK: - Post Header Section

    var postHeaderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if !isOwnPost && !authorUserId.isEmpty { showOtherProfile = true }
                } label: {
                    Text(handle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                }
                if isOwnPost {
                    Text("· you")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.toskaBlue.opacity(0.5))
                }
                if let tag = tag {
                    Text("·").font(.system(size: 9)).foregroundColor(Color.toskaDivider)
                    Text(tag)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(tagColor(for: tag).opacity(0.8))
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(tagColor(for: tag).opacity(0.07))
                        .cornerRadius(4)
                }
                Spacer()
                Text(time)
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(Color(hex: "c8c8c8"))
            }
            .padding(.bottom, 10)

            Text(postText)
                .font(.custom("Georgia", size: 16))
                .foregroundColor(Color(hex: "1a1a1a"))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Text(formatFull(likeCount))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(likePulse ? Color.toskaBlue : Color.toskaTextDark)
                                    .scaleEffect(likePulse ? 1.15 : 1.0)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: likePulse)
                                Text("felt this")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(likePulse ? Color.toskaBlue : Color.toskaTextLight)
                            }
                            statLabel(count: replyList.isEmpty ? replies : replyList.count, label: "replies")
                            Spacer()
                        }
                        .padding(.bottom, 10)

            Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)

            HStack(spacing: 0) {
                           Button { replyFocused = true } label: {
                               Image(systemName: "bubble.left")
                                   .font(.system(size: 15, weight: .light))
                                   .foregroundColor(Color.toskaTextLight)
                           }
                           .accessibilityLabel("Reply")
                           .frame(maxWidth: .infinity)

                           Button { toggleLike() } label: {
                               Image(systemName: isLiked ? "heart.fill" : "heart")
                                   .font(.system(size: 15, weight: isLiked ? .medium : .light))
                                   .foregroundColor(isLiked ? Color(hex: "c47a8a") : Color.toskaTextLight)
                           }
                           .accessibilityLabel(isLiked ? "Unlike post" : "Like post")
                           .accessibilityValue("\(formatFull(likeCount)) people felt this")
                           .frame(maxWidth: .infinity)

                           Button { repostPost() } label: {
                               Image(systemName: "arrow.2.squarepath")
                                   .font(.system(size: 15, weight: .light))
                                   .foregroundColor(isReposted ? Color(hex: "5a9e8f") : Color.toskaTextLight)
                           }
                           .accessibilityLabel(isReposted ? "Already reposted" : "Repost")
                           .frame(maxWidth: .infinity)
                           .disabled(isReposted)

                           Button { toggleSave() } label: {
                               Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                   .font(.system(size: 15, weight: .light))
                                   .foregroundColor(isSaved ? Color.toskaBlue : Color.toskaTextLight)
                           }
                           .accessibilityLabel(isSaved ? "Unsave post" : "Save post")
                           .frame(maxWidth: .infinity)

                           if !isOwnPost && !isAuthorIdLoading && !authorUserId.isEmpty {
                               Button { startConversation() } label: {
                                   Image(systemName: "envelope")
                                       .font(.system(size: 15, weight: .light))
                                       .foregroundColor(Color.toskaTextLight)
                               }
                               .accessibilityLabel("Send message")
                               .frame(maxWidth: .infinity)
                           }
                       }
                       .padding(.vertical, 8)
            Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
        }
    }

    // MARK: - UI Helpers

    func statLabel(count: Int, label: String) -> some View {
        HStack(spacing: 3) {
            Text(formatFull(count)).font(.system(size: 11, weight: .semibold)).foregroundColor(Color.toskaTextDark)
            Text(label).font(.system(size: 11)).foregroundColor(Color.toskaTextLight)
        }
    }

    func actionButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .light))
                Text(label).font(.system(size: 8))
            }
            .foregroundColor(active ? Color.toskaBlue : Color(hex: "c8c8c8"))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Flattened Reply Helpers

    struct FlatReply: Identifiable {
        let id: String
        let reply: ThreadedReply
        let depth: Int
    }

    func flattenReplies(_ replies: [ThreadedReply], depth: Int = 0, maxDepth: Int = 3) -> [FlatReply] {
            var result: [FlatReply] = []
            var seen: Set<String> = []
            func walk(_ nodes: [ThreadedReply], d: Int) {
                for reply in nodes {
                    guard !seen.contains(reply.id) else { continue }
                    seen.insert(reply.id)
                    result.append(FlatReply(id: reply.id, reply: reply, depth: d))
                    let childDepth = d < maxDepth ? d + 1 : d
                    walk(reply.children, d: childDepth)
                }
            }
            walk(replies, d: depth)
            return result
        }

    // MARK: - Live Listener

    func startLiveListener() {
        guard !postId.isEmpty else { return }
        liveListener?.remove()
        let registration = Firestore.firestore().collection("posts").document(postId)
            .addSnapshotListener { snapshot, _ in
                Task { @MainActor in
                    if snapshot?.exists == false {
                        self.liveListener?.remove()
                        self.liveListener = nil
                        self.dismiss()
                        return
                    }
                    guard let data = snapshot?.data() else { return }
                    if data["isLetter"] as? Bool == true { isLetter = true }
                    let newCount = data["likeCount"] as? Int ?? 0
                    if Date() > suppressListenerUntil && newCount != likeCount {
                        likeCount = max(0, newCount)
                        likePulse = true
                        likePulseTask?.cancel()
                        likePulseTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            likePulse = false
                        }
                    }
                }
            }
        liveListener = registration
    }

    // MARK: - Like

    func toggleLike() {
        suppressListenerUntil = Date().addingTimeInterval(2.0)
        PostInteractionManager.toggleLike(
            postId: postId, authorId: authorUserId,
            currentlyLiked: isLiked, currentCount: likeCount
        ) { result in
            isLiked = result.isLiked
            likeCount = result.newCount
            if result.isLiked {
                likePulse = true
                likePulseTask?.cancel()
                likePulseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    likePulse = false
                }
            }
        }
    }

    // MARK: - Save

    func toggleSave() {
        PostInteractionManager.toggleSave(
            postId: postId, authorId: authorUserId, currentlySaved: isSaved
        ) { newSaved in isSaved = newSaved }
    }

    // MARK: - Check States

    func checkIfLiked() {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        Firestore.firestore().collection("posts").document(postId).collection("likes").document(uid).getDocument { snapshot, _ in
            Task { @MainActor in isLiked = snapshot?.exists == true }
        }
    }

    func checkIfSaved() {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        Firestore.firestore().collection("users").document(uid).collection("saved").document(postId).getDocument { snapshot, _ in
            Task { @MainActor in isSaved = snapshot?.exists == true }
        }
    }

    func checkIfReposted() {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        Firestore.firestore().collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: true)
            .whereField("originalPostId", isEqualTo: postId)
            .limit(to: 1)
            .getDocuments { snapshot, _ in
                Task { @MainActor in
                    if let docs = snapshot?.documents, !docs.isEmpty { isReposted = true }
                }
            }
    }

    // MARK: - Repost

    func repostPost() {
        guard !isReposted else { return }
        PostInteractionManager.repost(
            postId: postId, postText: postText, postTag: tag,
            authorId: authorUserId, originalHandle: handle, currentCount: localRepostCount
        ) { result in
            isReposted = result.isReposted
            localRepostCount = result.newCount
        }
    }

    // MARK: - Block

    func blockUser() {
        guard let uid = Auth.auth().currentUser?.uid, !authorUserId.isEmpty, uid != authorUserId else { return }
        let db = Firestore.firestore()
        let blockedUserId = authorUserId

        // BlockedUsersCache.block() now owns the Firestore write and revert
               // logic — no separate setData call needed here.
               BlockedUsersCache.shared.block(blockedUserId, handle: handle)

        db.collection("users").document(uid).collection("notifications")
            .whereField("fromUserId", isEqualTo: blockedUserId)
            .getDocuments { snapshot, _ in
                Task { @MainActor in
                    for doc in snapshot?.documents ?? [] { doc.reference.delete() }
                }
            }

        Task { @MainActor in
            let uidRef = db.collection("users").document(uid)
            let authorRef = db.collection("users").document(blockedUserId)

            let followingSnap = try? await db.collection("users").document(uid)
                .collection("following").document(blockedUserId).getDocumentAsync()
            if followingSnap?.exists == true {
                try? await db.collection("users").document(uid).collection("following").document(blockedUserId).delete()
                try? await db.collection("users").document(blockedUserId).collection("followers").document(uid).delete()
                // WARNING: These count decrements use try? — if either fails silently,
                // followingCount/followerCount will drift (be 1 too high). A periodic
                // recount or Cloud Function is recommended to reconcile over time.
                try? await uidRef.updateData(["followingCount": FieldValue.increment(Int64(-1))])
                try? await authorRef.updateData(["followerCount": FieldValue.increment(Int64(-1))])
            }

            let followerSnap = try? await db.collection("users").document(uid)
                .collection("followers").document(blockedUserId).getDocumentAsync()
            if followerSnap?.exists == true {
                try? await db.collection("users").document(uid).collection("followers").document(blockedUserId).delete()
                try? await db.collection("users").document(blockedUserId).collection("following").document(uid).delete()
                // WARNING: Same count-drift risk as above — try? swallows errors on
                // these decrements, so followerCount/followingCount may become stale.
                try? await uidRef.updateData(["followerCount": FieldValue.increment(Int64(-1))])
                try? await authorRef.updateData(["followingCount": FieldValue.increment(Int64(-1))])
            }
        }

        HapticManager.play(.milestone)
        showBlockedAlert = true
    }

    // MARK: - Report

    func reportPost() {
            guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
            // Writes must match the hardened firestore.rules schema for the
            // reports collection: required type/status/createdAt, only fields
            // in the keys.hasOnly() allow list, reportedBy must match the
            // authed user. Renamed authorId → reportedUserId and authorHandle
            // → reportedHandle to match the rule's vocabulary.
            Firestore.firestore().collection("reports").addDocument(data: [
                "type": "post",
                "status": "pending",
                "reportedBy": uid,
                "reason": "other",
                "reasonLabel": "reported by user",
                "createdAt": FieldValue.serverTimestamp(),
                "postId": postId,
                "reportedUserId": authorUserId,
                "reportedHandle": handle,
                "text": postText,
            ])
            Telemetry.reportSubmitted(target: .post, reasonCode: "other")
        }

    // MARK: - Delete

    func deletePost() {
        guard !postId.isEmpty, !isDeleting else { return }
        isDeleting = true
        let db = Firestore.firestore()

        Task { @MainActor in
            do {
                // Delete all replies in batches, looping until none remain
                var hasMoreReplies = true
                while hasMoreReplies {
                    let replySnap = try await db.collection("posts").document(postId).collection("replies")
                        .limit(to: 500).getDocumentsAsync()
                    if replySnap.documents.isEmpty {
                        hasMoreReplies = false
                    } else {
                        let replyBatch = db.batch()
                        for doc in replySnap.documents { replyBatch.deleteDocument(doc.reference) }
                        try await replyBatch.commit()
                    }
                }

                // Delete all likes
                let likeSnap = try await db.collection("posts").document(postId).collection("likes").getDocumentsAsync()
                let likeDocs = likeSnap.documents
                let likeCount = likeDocs.count

                let likeChunks = stride(from: 0, to: likeDocs.count, by: 249).map {
                    Array(likeDocs[$0..<min($0 + 249, likeDocs.count)])
                }
                for chunk in likeChunks {
                    let batch = db.batch()
                    for doc in chunk {
                        batch.deleteDocument(doc.reference)
                        batch.deleteDocument(db.collection("users").document(doc.documentID).collection("liked").document(postId))
                    }
                    try await batch.commit()
                }

                if likeCount > 0 && !authorUserId.isEmpty {
                    try? await db.collection("users").document(authorUserId).updateData([
                        "totalLikes": FieldValue.increment(Int64(-likeCount))
                    ])
                }
            } catch {
                isDeleting = false
                deleteError = "couldn't delete — failed to clean up replies/likes: \(error.localizedDescription)"
                return
            }

            let repostSnap = try? await db.collection("posts")
                .whereField("isRepost", isEqualTo: true)
                .whereField("originalPostId", isEqualTo: postId)
                .getDocumentsAsync()
            for doc in repostSnap?.documents ?? [] { try? await doc.reference.delete() }

            let reflectionSnap = try? await db.collection("posts").document(postId).collection("reflections").getDocumentsAsync()
            for doc in reflectionSnap?.documents ?? [] { try? await doc.reference.delete() }

            if let uid = Auth.auth().currentUser?.uid {
                            try? await db.collection("users").document(uid).collection("saved").document(postId).delete()
                            try? await db.collection("users").document(uid).collection("liked").document(postId).delete()
                        }

            do {
                try await db.collection("posts").document(postId).delete()
                isDeleting = false
                dismiss()
            } catch {
                isDeleting = false
                deleteError = "couldn't delete — \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Replies

    @State private var replyListener: ListenerRegistration? = nil

        func fetchReplies() {
            guard !postId.isEmpty else { return }
            replyListener?.remove()
            replyListener = Firestore.firestore().collection("posts").document(postId).collection("replies")
                .order(by: "createdAt", descending: false)
                .addSnapshotListener { snapshot, _ in
                Task { @MainActor in
                    guard let documents = snapshot?.documents else { return }
                    let flat = documents.compactMap { doc -> ThreadedReply? in
                        let data = doc.data()
                        let authorId = data["authorId"] as? String ?? ""
                        if BlockedUsersCache.shared.isBlocked(authorId) { return nil }
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        return ThreadedReply(
                            id: doc.documentID,
                            handle: data["authorHandle"] as? String ?? "anonymous",
                            text: data["text"] as? String ?? "",
                            likes: data["likeCount"] as? Int ?? 0,
                            time: FeedView.timeAgoString(from: createdAt),
                            authorId: authorId,
                            parentReplyId: data["parentReplyId"] as? String,
                            children: []
                        )
                    }
                    replyList = buildThreadedReplies(from: flat)
                }
            }
    }

    func buildThreadedReplies(from flat: [ThreadedReply]) -> [ThreadedReply] {
        var lookup: [String: ThreadedReply] = [:]
        for reply in flat { var c = reply; c.children = []; lookup[c.id] = c }

        var childIdsMap: [String: [String]] = [:]
        var rootIds: [String] = []

        for reply in flat {
            if let parentId = reply.parentReplyId, lookup[parentId] != nil {
                childIdsMap[parentId, default: []].append(reply.id)
            } else {
                rootIds.append(reply.id)
            }
        }

        var resolved = Set<String>()
        var order: [String] = []

        func visit(_ id: String) {
            guard !resolved.contains(id) else { return }
            for childId in childIdsMap[id] ?? [] { visit(childId) }
            resolved.insert(id)
            order.append(id)
        }

        for id in rootIds { visit(id) }
        for reply in flat where !resolved.contains(reply.id) { visit(reply.id) }
        for id in order {
            guard lookup[id] != nil else { continue }
            lookup[id]!.children = (childIdsMap[id] ?? []).compactMap { lookup[$0] }
        }
        return rootIds.compactMap { lookup[$0] }
    }

    func lookupAuthorId() {
        guard !postId.isEmpty else { isAuthorIdLoading = false; return }
        Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, _ in
            Task { @MainActor in
                guard let data = snapshot?.data() else {
                    authorUserId = ""
                    isAuthorIdLoading = false
                    return
                }
                authorUserId = data["authorId"] as? String ?? ""
                isAuthorIdLoading = false
            }
        }
    }

    func sendReply() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 2 else { return }
        guard Auth.auth().currentUser?.uid != nil, !postId.isEmpty else { return }
        if BlockedUsersCache.shared.isBlocked(authorUserId) { return }
        if let last = RateLimiter.shared.lastReplyTime, Date().timeIntervalSince(last) < 5 { return }
        if let violation = contentViolation(in: trimmed) {
            replyContentWarningMessage = contentViolationMessage(for: violation)
            showReplyContentWarning = true
            return
        }
        if containsNameOrIdentifyingInfo(trimmed) { pendingReplyText = trimmed; showReplyNameWarning = true; return }
        if let level = crisisCheckLevelRespectingSetting(for: trimmed) {
            pendingReplyText = trimmed
            replyGentleCheckLevel = level
            showReplyGentleCheck = true
            return
        }
        postReplyNow(trimmed)
    }

    func postReplyNow(_ trimmed: String) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        RateLimiter.shared.lastReplyTime = Date()
        HapticManager.play(.send)
        let db = Firestore.firestore()
        let currentReplyText = trimmed
        Task { @MainActor in
            let replyHandle = UserHandleCache.shared.handle
            var replyData: [String: Any] = [
                "authorId": uid, "authorHandle": replyHandle, "text": currentReplyText,
                "likeCount": 0, "createdAt": FieldValue.serverTimestamp(),
                "parentPostText": postText, "parentPostHandle": handle
            ]
            if let parentId = replyingToId { replyData["parentReplyId"] = parentId }
            if let gifUrl = replyGifUrl { replyData["gifUrl"] = gifUrl }

            let postRef = db.collection("posts").document(postId)
            let replyRef = postRef.collection("replies").document()
            let batch = db.batch()
            batch.setData(replyData, forDocument: replyRef)
            batch.updateData(["replyCount": FieldValue.increment(Int64(1))], forDocument: postRef)

            batch.commit { error in
                Task { @MainActor in
                    if let error = error {
                        Telemetry.recordError(error, context: "PostDetailView.postReply")
                        self.replyText = currentReplyText
                        return
                    }
                    Telemetry.replyCreated(
                        parentIsOwn: self.authorUserId == uid,
                        hasGif: self.replyGifUrl != nil
                    )
                    if !self.authorUserId.isEmpty, self.authorUserId != uid {
                        self.sendNotification(toUserId: self.authorUserId, type: "reply", message: currentReplyText)
                    }
                    let newReply = ThreadedReply(
                        id: replyRef.documentID, handle: replyHandle, text: currentReplyText,
                        likes: 0, time: "now", authorId: uid,
                        parentReplyId: self.replyingToId, children: []
                    )
                    if let parentId = self.replyingToId {
                        func appendToParent(_ nodes: inout [ThreadedReply], depth: Int = 0) -> Bool {
                            guard depth < 64 else { return false }
                            for i in nodes.indices {
                                if nodes[i].id == parentId { nodes[i].children.append(newReply); return true }
                                if appendToParent(&nodes[i].children, depth: depth + 1) { return true }
                            }
                            return false
                        }
                        if !appendToParent(&self.replyList) { self.replyList.append(newReply) }
                    } else {
                        self.replyList.append(newReply)
                    }
                    self.replyText = ""
                    self.replyGifUrl = nil
                    self.replyFocused = false
                    self.replyingToId = nil
                    self.replyingToHandle = nil
                }
            }
        }
    }

    func sendNotification(toUserId: String, type: String, message: String) {
        PostInteractionManager.sendNotification(postId: postId, toUserId: toUserId, type: type, message: message)
    }

    // MARK: - DM Conversation

    func startConversation() {
        guard let uid = Auth.auth().currentUser?.uid, !authorUserId.isEmpty, uid != authorUserId else { return }
        let db = Firestore.firestore()
        let convoId = [uid, authorUserId].sorted().joined(separator: "_")
        let convoRef = db.collection("conversations").document(convoId)

        Task { @MainActor in
            let theyBlockedMe = try? await db.collection("users").document(authorUserId).collection("blocked").document(uid).getDocumentAsync()
            if theyBlockedMe?.exists == true { return }
            let iBlockedThem = try? await db.collection("users").document(uid).collection("blocked").document(authorUserId).getDocumentAsync()
            if iBlockedThem?.exists == true { return }

            let myHandle = UserHandleCache.shared.handle
            let existing = try? await convoRef.getDocumentAsync()
            if existing?.exists == true {
                activeConversation = ConversationSelection(id: convoId, handle: handle, userId: authorUserId)
                return
            }
            try? await convoRef.setData([
                "participants": [uid, authorUserId],
                "participantHandles": [uid: myHandle, authorUserId: handle],
                "lastMessage": "", "lastMessageAt": FieldValue.serverTimestamp(),
                "messageCount": [uid: 0, authorUserId: 0],
                "createdAt": FieldValue.serverTimestamp()
            ])
            activeConversation = ConversationSelection(id: convoId, handle: handle, userId: authorUserId)
        }
    }

    func formatFull(_ count: Int) -> String {
        ToskaFormatters.decimalNumber.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Edit Post View

@MainActor
struct EditPostView: View {
    let postId: String
    let isLetter: Bool
    @Binding var currentText: String
    @Binding var editText: String
    @Environment(\.dismiss) var dismiss
    @State private var showNameWarning = false
    @State private var showContentWarning = false
    @State private var editContentWarningMessage = ""
    @State private var showGentleCheck = false
    @State private var editGentleCheckLevel: CrisisLevel = .soft
    @State private var isSaving = false
    @State private var saveError = ""

    private var charLimit: Int { isLetter ? 2000 : 500 }

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color(hex: "999999"))
                    }
                    Spacer()
                    Text("edit post").font(.system(size: 14, weight: .medium)).foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { attemptSave() } label: {
                        HStack(spacing: 4) {
                            if isSaving { ProgressView().scaleEffect(0.7).tint(.white) }
                            else { Image(systemName: "checkmark").font(.system(size: 11)); Text("save").font(.system(size: 13, weight: .semibold)) }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(editText.isEmpty || editText == currentText ? Color.toskaDivider : Color.toskaBlue)
                        .cornerRadius(16)
                    }
                    .disabled(editText.isEmpty || editText == currentText || isSaving)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)

                if !saveError.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        Text(saveError).font(.system(size: 11))
                    }
                    .foregroundColor(Color(hex: "c45c5c"))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "c45c5c").opacity(0.05))
                }

                ZStack(alignment: .topLeading) {
                    if editText.isEmpty {
                        Text("say what you never said...")
                            .font(.custom("Georgia", size: 16)).foregroundColor(Color(hex: "c0c3ca"))
                            .padding(.horizontal, 18).padding(.top, 16)
                    }
                    TextEditor(text: $editText)
                        .font(.custom("Georgia", size: 16)).foregroundColor(Color(hex: "1a1a1a"))
                        .lineSpacing(4).scrollContentBackground(.hidden)
                        .padding(.horizontal, 14).padding(.top, 8)
                        .onChange(of: editText) { _, newValue in
                            if newValue.count > charLimit { editText = String(newValue.prefix(charLimit)) }
                            if !saveError.isEmpty { saveError = "" }
                        }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    Rectangle().fill(Color(hex: "e4e6ea")).frame(height: 0.5)
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil").font(.system(size: 10))
                            Text("editing your post").font(.system(size: 10))
                        }
                        .foregroundColor(Color(hex: "c9a97a"))
                        Spacer()
                        ZStack {
                            Circle().stroke(Color(hex: "e4e6ea"), lineWidth: 1.5).frame(width: 22, height: 22)
                            Circle()
                                .trim(from: 0, to: CGFloat(editText.count) / CGFloat(charLimit))
                                .stroke(editText.count > charLimit - 50 ? Color(hex: "c45c5c") : Color.toskaBlue,
                                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 22, height: 22).rotationEffect(.degrees(-90))
                        }
                        Text("\(charLimit - editText.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(editText.count > charLimit - 50 ? Color(hex: "c45c5c") : Color.toskaTimestamp)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .background(Color.white)
            }
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .alert("hold on", isPresented: $showContentWarning) {
            Button("edit") {}
        } message: { Text(editContentWarningMessage) }
        .alert("keep it anonymous", isPresented: $showNameWarning) {
            Button("edit") {}
            Button("save anyway", role: .destructive) {
                showNameWarning = false
                if let level = crisisCheckLevelRespectingSetting(for: editText) {
                    editGentleCheckLevel = level
                    showGentleCheck = true
                } else {
                    saveEdit()
                }
            }
        } message: { Text("your edit may include a name or identifying info. toska is anonymous for everyone.") }
        .overlay {
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: editGentleCheckLevel,
                    onProceed: { saveEdit() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
    }

    func attemptSave() {
        guard !postId.isEmpty, !editText.isEmpty else { return }
        if let violation = contentViolation(in: editText) {
            editContentWarningMessage = contentViolationMessage(for: violation)
            showContentWarning = true
            return
        }
        if containsNameOrIdentifyingInfo(editText) { showNameWarning = true; return }
        if let level = crisisCheckLevelRespectingSetting(for: editText) {
            editGentleCheckLevel = level
            showGentleCheck = true
            return
        }
        saveEdit()
    }

    func saveEdit() {
        guard !postId.isEmpty, !editText.isEmpty else { return }
        isSaving = true
        saveError = ""
        Firestore.firestore().collection("posts").document(postId).updateData([
            "text": editText, "editedAt": FieldValue.serverTimestamp()
        ]) { error in
            Task { @MainActor in
                isSaving = false
                if let error = error { saveError = "couldn't save — \(error.localizedDescription)" }
                else { currentText = editText; dismiss() }
            }
        }
    }
}

// MARK: - Swipe To Reply Row

struct SwipeToReplyRow: View {
    let item: PostDetailView.FlatReply
    let indent: CGFloat
    let onReply: () -> Void
    /// Parent post ID — needed so the report payload knows which post this
    /// reply belongs to. Empty string disables the report/block menu.
    var postId: String = ""
    @State private var dragOffset: CGFloat = 0
    @State private var hasTriggered = false
    @State private var showReportSheet = false
    @State private var showBlockConfirm = false
    private let triggerThreshold: CGFloat = 60

    var body: some View {
        ZStack(alignment: .leading) {
            HStack {
                Spacer()
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color.toskaBlue)
                    .opacity(min(dragOffset / triggerThreshold, 1.0))
                    .scaleEffect(min(0.6 + (dragOffset / triggerThreshold) * 0.4, 1.0))
                    .padding(.trailing, 20)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if item.depth > 0 {
                        Rectangle().fill(Color.toskaBlue.opacity(0.2))
                            .frame(width: 2, height: 14).cornerRadius(1).padding(.trailing, 4)
                    }
                    Text(item.reply.handle).font(.system(size: 10, weight: .semibold)).foregroundColor(Color.toskaBlue)
                    Text("·").font(.system(size: 8)).foregroundColor(Color.toskaDivider)
                    Text(item.reply.time).font(.system(size: 9, weight: .light)).foregroundColor(Color(hex: "c8c8c8"))
                    Spacer()
                    // Per-reply report/block menu. Hidden on your own replies
                    // and when postId is unknown (empty string parent).
                    if !postId.isEmpty,
                       !item.reply.authorId.isEmpty,
                       item.reply.authorId != Auth.auth().currentUser?.uid {
                        Menu {
                            Button {
                                showReportSheet = true
                            } label: {
                                Label("report", systemImage: "flag")
                            }
                            Button(role: .destructive) {
                                showBlockConfirm = true
                            } label: {
                                Label("block \(item.reply.handle)", systemImage: "person.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10))
                                .foregroundColor(Color.toskaTimestamp)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("More options for \(item.reply.handle)'s reply")
                    }
                }
                Text(item.reply.text).font(.custom("Georgia", size: 13)).foregroundColor(Color.toskaTextDark).lineSpacing(3)
                if item.reply.likes > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "heart").font(.system(size: 9, weight: .light))
                        Text("\(item.reply.likes)").font(.system(size: 9))
                    }
                    .foregroundColor(Color(hex: "d8d8d8")).padding(.top, 2)
                }
            }
            .padding(.leading, 18 + indent).padding(.trailing, 18).padding(.vertical, 10)
            .background(LateNightTheme.background)
            .offset(x: dragOffset)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard value.translation.width > 0 else { return }
                        let raw = value.translation.width
                        dragOffset = raw < triggerThreshold ? raw : triggerThreshold + (raw - triggerThreshold) * 0.2
                        if dragOffset >= triggerThreshold && !hasTriggered {
                            hasTriggered = true
                            HapticManager.play(.tabSwitch)
                        }
                    }
                    .onEnded { value in
                        if value.translation.width >= triggerThreshold { onReply() }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = 0 }
                        hasTriggered = false
                    }
            )
        }
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(target: .reply(
                postId: postId,
                replyId: item.reply.id,
                authorId: item.reply.authorId,
                authorHandle: item.reply.handle,
                text: item.reply.text
            ))
        }
        .confirmationDialog(
            "block \(item.reply.handle)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("block", role: .destructive) {
                BlockedUsersCache.shared.block(item.reply.authorId, handle: item.reply.handle)
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("you wont see their posts or messages. they wont be notified.")
        }
    }
}
