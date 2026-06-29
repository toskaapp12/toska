import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// ReplyDetailView — Twitter-style reply-as-post page.
//
// Tap a reply (in PostDetailView or another ReplyDetailView) and it renders
// AS IF it were a post: the reply at top, its direct child replies below,
// composer at the bottom. To drill deeper, tap any child reply and another
// ReplyDetailView is pushed onto the stack. Each level is its own page; back
// gesture pops one level. Same mental model as Twitter.
//
// Direct-children-only (no depth-flattening) is deliberate. Threading lives
// in the navigation stack instead of an in-page indented tree, which matches
// the brand's slower / less-noisy posture and keeps this view small.
@MainActor
struct ReplyDetailView: View {
    @Environment(\.dismiss) var dismiss
    let postId: String
    let reply: ThreadedReply

    // Mirror state — initialised from the passed-in reply, kept fresh by the
    // snapshot listener so edits / new likes / new replies land live here.
    @State private var replyText: String = ""
    @State private var replyHandle: String = ""
    @State private var replyTime: String = ""
    @State private var replyAuthorId: String = ""
    @State private var likeCount: Int = 0
    @State private var isLiked: Bool = false
    @State private var isSaved: Bool = false

    @State private var children: [ThreadedReply] = []
    @State private var hasLoadedChildren = false
    @State private var replyListener: ListenerRegistration? = nil

    // Composer
    @State private var composerText: String = ""
    @State private var isPosting = false
    @State private var postError: String? = nil
    @FocusState private var composerFocused: Bool

    // Edit / delete / report / share sheets
    @State private var showEditReply = false
    @State private var editText: String = ""
    @State private var showDeleteAlert = false
    @State private var deleteError: String = ""
    @State private var showShareCard = false
    @State private var showReportSheet = false
    @State private var showBlockConfirm = false
    @State private var showOtherProfile = false

    var isOwnReply: Bool { replyAuthorId == Auth.auth().currentUser?.uid }

    var body: some View {
        ZStack(alignment: .bottom) {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ToskaHeader(title: "post", onBack: { dismiss() }) {
                    if !replyAuthorId.isEmpty {
                        Menu {
                            if isOwnReply {
                                Button {
                                    editText = replyText
                                    showEditReply = true
                                } label: { Label("edit reply", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    showDeleteAlert = true
                                } label: { Label("delete reply", systemImage: "trash") }
                            } else {
                                Button { showReportSheet = true } label: {
                                    Label("report", systemImage: "flag")
                                }
                                Button(role: .destructive) { showBlockConfirm = true } label: {
                                    Label("block \(replyHandle)", systemImage: "person.slash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundColor(Color.toskaTimestamp)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("more options")
                    }
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Reply rendered as the "post."
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                // De-emphasized handle (quiet gray, not loud blue)
                                // so the reply text leads — matches the feed.
                                // Tappable → the reply author's profile (mirrors the
                                // post header in PostDetailView). Previously a plain
                                // Text, so tapping a reply author's name did nothing.
                                Button {
                                    if !isOwnReply && !replyAuthorId.isEmpty { showOtherProfile = true }
                                } label: {
                                    Text(replyHandle)
                                        .font(ToskaFont.sans(12, weight: .medium))
                                        .foregroundColor(ToskaColor.text2)
                                }
                                .buttonStyle(.plain)
                                if isOwnReply {
                                    Text("· you")
                                        .font(ToskaFont.sans(11, weight: .medium))
                                        .foregroundColor(ToskaColor.text3)
                                }
                                Spacer()
                                Text(replyTime)
                                    .font(ToskaFont.sans(11, weight: .light))
                                    .foregroundColor(Color.toskaInactiveGray)
                            }
                            .padding(.bottom, 8)

                            Text(replyText)
                                // G-1 (2026-06-16): route through the design-system
                                // serif token so the reply body scales with Dynamic
                                // Type (relativeTo: .body) and matches feed/detail
                                // reading surfaces, instead of a fixed-size Georgia.
                                .font(ToskaFont.replyBody)
                                .foregroundColor(Color(hex: "1a1a1a"))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)

                            // Stats — minimal.
                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Text("\(likeCount)")
                                        .font(ToskaFont.sans(12, weight: .bold))
                                        .foregroundColor(Color.toskaTextDark)
                                    Text("felt this").font(ToskaFont.sans(11))
                                        .foregroundColor(Color.toskaTextLight)
                                }
                                HStack(spacing: 4) {
                                    Text("\(children.count)")
                                        .font(ToskaFont.sans(12, weight: .bold))
                                        .foregroundColor(Color.toskaTextDark)
                                    Text(children.count == 1 ? "reply" : "replies")
                                        .font(ToskaFont.sans(11))
                                        .foregroundColor(Color.toskaTextLight)
                                }
                            }
                            .padding(.bottom, 8)

                            // Action row.
                            HStack(spacing: 0) {
                                Button { composerFocused = true } label: {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 15, weight: .light))
                                        .foregroundColor(Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("reply")
                                Button { toggleLike() } label: {
                                    Image(systemName: isLiked ? "heart.fill" : "heart")
                                        .font(.system(size: 15, weight: isLiked ? .medium : .light))
                                        .foregroundColor(isLiked ? Color.toskaWhisperPink : Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(isLiked ? "unlike, felt this" : "felt this")
                                Button { toggleSave() } label: {
                                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                        .font(.system(size: 15, weight: .light))
                                        .foregroundColor(isSaved ? Color.toskaBlue : Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(isSaved ? "remove from saved" : "save")
                                Button { showShareCard = true } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .light))
                                        .foregroundColor(Color.toskaTextLight)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("share")
                            }
                            .padding(.vertical, 8)
                            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // Direct children only. Each is a SwipeToReplyRow whose
                        // tap pushes its own ReplyDetailView, so grandchildren
                        // are reachable by drilling — one level per push.
                        if children.isEmpty && !hasLoadedChildren {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<3, id: \.self) { _ in
                                    SkeletonReplyRow()
                                    Rectangle().fill(Color.toskaBorderLight.opacity(0.5))
                                        .frame(height: 0.5).padding(.leading, 16)
                                }
                            }
                        } else if children.isEmpty {
                            VStack(spacing: 8) {
                                Text("\"some words just need\na witness.\"")
                                    .font(.custom("Georgia-Italic", size: 16))
                                    .foregroundColor(Color.toskaTimestamp)
                                    .multilineTextAlignment(.center)
                                Text("be the first to reply")
                                    .font(ToskaFont.sans(11))
                                    .foregroundColor(Color.toskaDivider)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                                    let flat = PostDetailView.FlatReply(
                                        id: child.id, reply: child, depth: 0, hiddenChildren: 0
                                    )
                                    SwipeToReplyRow(
                                        item: flat,
                                        indent: 0,
                                        onReply: { composerFocused = true },
                                        postId: postId,
                                        onComment: { composerFocused = true }
                                    )
                                    if index < children.count - 1 {
                                        Rectangle().fill(Color.toskaBorderLight.opacity(0.5))
                                            .frame(height: 0.5).padding(.leading, 16)
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 90)
                    }
                }
                composerBar
            }
        }
        .navigationDestination(isPresented: $showEditReply) {
            EditReplyView(postId: postId, replyId: reply.id, replyText: $editText) { }
                .navigationBarHidden(true)
        }
        .navigationDestination(isPresented: $showShareCard) {
            ShareCardView(text: replyText, handle: replyHandle, feltCount: likeCount, tag: nil)
                .navigationBarHidden(true)
        }
        .navigationDestination(isPresented: $showReportSheet) {
            ReportSheet(target: .reply(
                postId: postId, replyId: reply.id,
                authorId: replyAuthorId, authorHandle: replyHandle, text: replyText
            ))
            .navigationBarHidden(true)
        }
        .navigationDestination(isPresented: $showOtherProfile) {
            OtherProfileView(userId: replyAuthorId, handle: replyHandle)
        }
        .alert("delete this reply?", isPresented: $showDeleteAlert) {
            Button("delete", role: .destructive) { deleteReply() }
            Button("cancel", role: .cancel) {}
        } message: { Text("this can't be undone.") }
        .alert("couldn't delete", isPresented: .init(
            get: { !deleteError.isEmpty },
            set: { if !$0 { deleteError = "" } }
        )) {
            Button("ok") { deleteError = "" }
        } message: { Text(deleteError) }
        .confirmationDialog(
            "block \(replyHandle)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("block", role: .destructive) {
                BlockedUsersCache.shared.block(replyAuthorId, handle: replyHandle)
                dismiss()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("you wont see their posts or replies. they wont be notified.")
        }
        .onAppear {
            replyText = reply.text
            replyHandle = reply.handle
            replyTime = reply.time
            replyAuthorId = reply.authorId
            likeCount = reply.likes
            isLiked = reply.isLiked
            isSaved = reply.isSaved
            attachListener()
        }
        .onDisappear {
            replyListener?.remove()
            replyListener = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            dismiss()
        }
        .hidesAppTabBar()
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            if let err = postError, !err.isEmpty {
                Text(err).font(ToskaFont.sans(11)).foregroundColor(Color.toskaErrorRed)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
            HStack(spacing: 8) {
                TextField("say what you can't say anywhere else", text: $composerText, axis: .vertical)
                    .font(ToskaFont.sans(13))
                    .focused($composerFocused)
                    .lineLimit(1...4)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(hex: "f0f0ec"))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Button { sendReply() } label: {
                    Image(systemName: isPosting ? "ellipsis" : "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(canPost ? Color.toskaBlue : Color.toskaBlue.opacity(0.4))
                        .clipShape(Circle())
                }
                .disabled(!canPost || isPosting)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white)
        }
    }

    var canPost: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Snapshot listener on the post's replies subcollection. We filter to:
    //   - the focal reply (for live text / like-count refresh).
    //   - direct children (parentReplyId == focal id) for the thread below.
    private func attachListener() {
        guard !postId.isEmpty else { return }
        replyListener?.remove()
        let capturedUid = Auth.auth().currentUser?.uid
        // M-1: filter to live replies. A held reply (moderationStatus ==
        // "pending_review") is denied to non-authors by the reply read rule,
        // so an unfiltered list query would fail. The author's own held replies
        // still surface in the main PostDetailView thread (with a banner); this
        // drill-down view intentionally shows only live children to keep the
        // query rule-safe without a second listener.
        replyListener = Firestore.firestore()
            .collection("posts").document(postId).collection("replies")
            .whereField("moderationStatus", isEqualTo: "live")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let error = error {
                        print("⚠️ ReplyDetailView listener error: \(error)")
                        return
                    }
                    guard let docs = snapshot?.documents else { return }
                    var newChildren: [ThreadedReply] = []
                    for doc in docs {
                        let data = doc.data()
                        let authorId = data["authorId"] as? String ?? ""
                        if BlockedUsersCache.shared.isBlocked(authorId) { continue }
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let item = ThreadedReply(
                            id: doc.documentID,
                            handle: data["authorHandle"] as? String ?? "anonymous",
                            text: data["text"] as? String ?? "",
                            likes: data["likeCount"] as? Int ?? 0,
                            time: FeedView.timeAgoString(from: createdAt),
                            createdAt: createdAt,
                            authorId: authorId,
                            parentReplyId: data["parentReplyId"] as? String,
                            children: [],
                            isLiked: false,
                            isSaved: false,
                            isReposted: false,
                            repostCount: data["repostCount"] as? Int ?? 0
                        )
                        if doc.documentID == reply.id {
                            // Refresh focal reply state from the live snapshot.
                            replyText = item.text
                            replyHandle = item.handle
                            likeCount = item.likes
                        }
                        if item.parentReplyId == reply.id {
                            newChildren.append(item)
                        }
                    }
                    children = newChildren
                    hasLoadedChildren = true
                }
            }
    }

    // MARK: - Send Reply

    private func sendReply() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !postId.isEmpty else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // T-8 (2026-06-11): restricted users can't reply (the reply-create rule
        // enforces notRestricted() server-side; this gives a clear message
        // instead of a generic Firestore failure, matching ComposeView/
        // PostDetailView).
        guard !UserHandleCache.shared.isRestricted else {
            postError = "your account is restricted and can't reply right now."
            return
        }
        let myHandle = UserHandleCache.shared.handle
        isPosting = true
        postError = nil
        let replyData: [String: Any] = [
            "authorId": uid,
            "authorHandle": myHandle,
            "text": trimmed,
            "likeCount": 0,
            "createdAt": FieldValue.serverTimestamp(),
            "parentPostText": replyText,
            "parentPostHandle": replyHandle,
            "parentReplyId": reply.id,
            // T-2 (2026-06-11): start hidden, mirroring posts/PostDetailView.
            "moderationStatus": "pending_validation"
        ]
        Firestore.firestore().collection("posts").document(postId)
            .collection("replies").addDocument(data: replyData) { err in
                Task { @MainActor in
                    isPosting = false
                    if let err = err {
                        let nsErr = err as NSError
                        if nsErr.domain == "FIRFirestoreErrorDomain", nsErr.code == 7 {
                            postError = "still setting up your account — try again in a moment"
                        } else {
                            postError = "couldn't reply. try again."
                        }
                    } else {
                        composerText = ""
                        composerFocused = false
                        HapticManager.play(.feltThis)
                    }
                }
            }
    }

    // MARK: - Like / Save (signatures pulled from PostInteractionManager)

    private func toggleLike() {
        PostInteractionManager.toggleReplyLike(
            postId: postId, replyId: reply.id,
            replyText: replyText, replyHandle: replyHandle,
            replyAuthorId: replyAuthorId,
            currentlyLiked: isLiked, currentCount: likeCount
        ) { result in
            isLiked = result.isLiked
            likeCount = result.newCount
        }
    }

    private func toggleSave() {
        HapticManager.play(.feltThis)
        PostInteractionManager.toggleReplySave(
            postId: postId, replyId: reply.id,
            replyText: replyText, replyHandle: replyHandle,
            currentlySaved: isSaved
        ) { newSaved in
            isSaved = newSaved
        }
    }

    // MARK: - Delete

    private func deleteReply() {
        Firestore.firestore()
            .collection("posts").document(postId)
            .collection("replies").document(reply.id)
            .delete { err in
                Task { @MainActor in
                    if let err = err {
                        deleteError = "couldn't delete — \(err.localizedDescription)"
                    } else {
                        dismiss()
                    }
                }
            }
    }
}
