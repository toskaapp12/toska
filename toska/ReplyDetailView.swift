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
    // Bumped at the start of every snapshot-processing Task; a Task whose
    // captured value is stale after its stamp await bails instead of writing a
    // list that predates a newer snapshot (which would drop a just-arrived reply).
    @State private var attachGeneration = 0
    // Seeds the focal reply's interaction state (likeCount/isLiked/isSaved) from
    // the prop only on first appear. onAppear re-fires when a child reply push
    // pops; re-seeding would reset an optimistic like the user just made (the
    // listener refreshes likeCount but NOT isLiked/isSaved), and a follow-up
    // no-op like would then stick a phantom +1.
    @State private var didSeedReplyState = false
    @State private var replyListener: ListenerRegistration? = nil

    // Composer
    @State private var composerText: String = ""
    @State private var isPosting = false
    @State private var postError: String? = nil
    @State private var showGentleCheck = false
    @State private var gentleCheckLevel: CrisisLevel = .soft
    @State private var gentleCheckTopic: CrisisTopic? = nil
    @State private var crisisConfirmed = false
    @State private var showContentWarning = false
    @State private var contentWarningMessage = ""
    @State private var showNameWarning = false
    @State private var nameConfirmed = false
    @FocusState private var composerFocused: Bool

    // Edit / delete / report / share sheets
    @State private var showEditReply = false
    @State private var editText: String = ""
    @State private var showDeleteAlert = false
    @State private var deleteError: String = ""
    @State private var showShareCard = false
    // Reply-share consent denied at tap time (author's allowSharing is off).
    @State private var shareBlocked = false
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
                                Button {
                                    // Consent check at tap time — replies carry no
                                    // denormalized isShareable (see ShareConsent).
                                    Task { @MainActor in
                                        if await ShareConsent.authorAllowsSharing(replyAuthorId) {
                                            showShareCard = true
                                        } else {
                                            shareBlocked = true
                                        }
                                    }
                                } label: {
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
                                    .font(ToskaFont.serifItalic(16))
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
                                        onToggleLike: { toggleChildLike(child) },
                                        onToggleSave: { toggleChildSave(child) },
                                        onRepost: { repostChild(child) },
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
        .alert("sharing is off", isPresented: $shareBlocked) {
            Button("got it", role: .cancel) {}
        } message: {
            Text("the writer of this reply keeps sharing turned off, so it can't leave toska.")
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
            // Interaction state seeded once; onAppear re-fires on pop-return and
            // must not clobber the user's optimistic like/save. The listener
            // keeps likeCount live thereafter.
            if !didSeedReplyState {
                didSeedReplyState = true
                likeCount = reply.likes
                isLiked = reply.isLiked
                isSaved = reply.isSaved
            }
            attachListener()
        }
        .onDisappear {
            replyListener?.remove()
            replyListener = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            dismiss()
        }
        // LOW-P3-5 (2026-07-20 launch audit): if the FOCAL reply's author gets
        // blocked (from this view's block button, or elsewhere while open),
        // leave — the snapshot only re-filters CHILDREN, so the focal node would
        // otherwise keep rendering a blocked author. Mirrors PostDetailView:279.
        .onReceive(NotificationCenter.default.publisher(for: .userBlocked)) { notif in
            if let blockedId = notif.userInfo?["userId"] as? String,
               !blockedId.isEmpty, blockedId == replyAuthorId {
                dismiss()
            }
        }
        .hidesAppTabBar()
        .overlay {
            if showGentleCheck {
                CrisisCheckInView(
                    isPresented: $showGentleCheck,
                    level: gentleCheckLevel,
                    topic: gentleCheckTopic,
                    onProceed: { crisisConfirmed = true; sendReply() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showGentleCheck)
        .alert("hold on", isPresented: $showContentWarning) {
            Button("edit") {}
        } message: { Text(contentWarningMessage) }
        .alert("keep it anonymous", isPresented: $showNameWarning) {
            Button("edit") {}
            Button("reply anyway", role: .destructive) {
                nameConfirmed = true
                sendReply()
            }
        } message: { Text("your reply may include a name or identifying info. toska is anonymous for everyone.") }
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
                .autocorrectionDisabled(false)  // autocorrect ON for content (2026-07-21)
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
            // Bound the read like PostDetailView.fetchReplies (T-6): without a
            // limit this listener reads every live reply under the post on each
            // drill-in and rebuilds on every delta, with cost scaling to the
            // whole thread even though only direct children are rendered.
            .limit(to: 500)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let error = error {
                        print("⚠️ ReplyDetailView listener error: \(error)")
                        return
                    }
                    guard let docs = snapshot?.documents else { return }
                    attachGeneration += 1
                    let gen = attachGeneration
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
                    // Carry forward interaction state we've already resolved for
                    // existing children (including optimistic toggles) so we
                    // don't re-read likedReplies/savedReplies on every delta.
                    let priorState = Dictionary(
                        children.map { ($0.id, ($0.isLiked, $0.isSaved, $0.isReposted)) },
                        uniquingKeysWith: { a, _ in a }
                    )
                    for i in newChildren.indices {
                        if let s = priorState[newChildren[i].id] {
                            newChildren[i].isLiked = s.0
                            newChildren[i].isSaved = s.1
                            newChildren[i].isReposted = s.2
                        }
                    }
                    // Stamp children we haven't resolved yet (first load / newly
                    // arrived). Without this, children seed isLiked/isSaved=false,
                    // so a reply you already liked renders un-liked and tapping
                    // like is a server no-op that leaves the optimistic +1 stuck.
                    let unresolved = newChildren.filter { priorState[$0.id] == nil }
                    if let uid = Auth.auth().currentUser?.uid, !unresolved.isEmpty {
                        let stamped = await PostDetailView.stampReplyInteractionState(
                            replies: unresolved,
                            replyIds: unresolved.map { $0.id },
                            uid: uid,
                            db: Firestore.firestore()
                        )
                        let stampedMap = Dictionary(
                            stamped.map { ($0.id, ($0.isLiked, $0.isSaved, $0.isReposted)) },
                            uniquingKeysWith: { a, _ in a }
                        )
                        for i in newChildren.indices {
                            if let s = stampedMap[newChildren[i].id] {
                                newChildren[i].isLiked = s.0
                                newChildren[i].isSaved = s.1
                                newChildren[i].isReposted = s.2
                            }
                        }
                    }
                    // Preserve my own just-sent reply that hasn't been promoted
                    // to `live` yet. The listener only sees live replies, so a
                    // snapshot delta triggered by ANOTHER user's reply would
                    // otherwise wipe the optimistic child I just inserted in
                    // sendReply() — making my reply appear to vanish. Once mine
                    // goes live it shows up in newChildren (same id) and is no
                    // longer "still pending", so there's no duplicate.
                    let liveIds = Set(newChildren.map { $0.id })
                    let myUid = Auth.auth().currentUser?.uid
                    // Self-heal: preserve the optimistic own-reply only for a
                    // bounded window. If it hasn't been promoted to `live` within
                    // ~2 min it was HELD for review (or rejected) — the single
                    // live-listener here never sees it, so keeping it forever made
                    // a held reply read as live with no "under review" banner. The
                    // held copy already surfaces in the main PostDetailView thread
                    // (with the banner), so drop the ghost here instead of leaking it.
                    let stillPending = children.filter {
                        $0.authorId == myUid && !liveIds.contains($0.id)
                            && Date().timeIntervalSince($0.createdAt) < 120
                    }
                    // Only the newest snapshot's Task writes. If a later snapshot
                    // started while we were awaiting the stamp, it holds the
                    // complete current live set — bail so we don't overwrite it
                    // with our older (possibly reply-missing) list.
                    guard gen == attachGeneration else { return }
                    children = (newChildren + stillPending).sorted { $0.createdAt < $1.createdAt }
                    hasLoadedChildren = true
                }
            }
    }

    // MARK: - Send Reply

    private func sendReply() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !postId.isEmpty else { return }
        guard Auth.auth().currentUser?.uid != nil else { return }
        guard !isPosting else { return }
        // T-8 (2026-06-11): restricted users can't reply (the reply-create rule
        // enforces notRestricted() server-side; this gives a clear message
        // instead of a generic Firestore failure, matching ComposeView/
        // PostDetailView).
        guard !UserHandleCache.shared.isRestricted else {
            postError = "your account is restricted and can't reply right now."
            return
        }
        // Rate-limit (5s) — parity with PostDetailView.sendReply.
        if let last = RateLimiter.shared.lastReplyTime, Date().timeIntervalSince(last) < 5 { return }
        // Content-violation gate (profanity/slurs/harassment/threats/spam/links).
        // This was MISSING on the drill-down composer, so those bypassed the
        // client guard here even though the main reply composer (PostDetailView)
        // runs it. Edit-only, matching PostDetailView (no "reply anyway").
        if let violation = contentViolation(in: trimmed) {
            contentWarningMessage = contentViolationMessage(for: violation)
            showContentWarning = true
            return
        }
        // Name / identifying-info gate — "reply anyway" override, like PostDetailView.
        if !nameConfirmed, containsNameOrIdentifyingInfo(trimmed) {
            showNameWarning = true
            return
        }
        // Crisis check-in — surface support resources to the author before the
        // reply is sent, matching ComposeView + PostDetailView's reply path. The
        // server also flags/pages on a concerning reply; this is the user-facing
        // rail. onProceed sets crisisConfirmed and re-enters to actually post.
        if !crisisConfirmed, let level = crisisCheckLevelRespectingSetting(for: trimmed) {
            gentleCheckLevel = level
            gentleCheckTopic = crisisTopic(for: trimmed)
            showGentleCheck = true
            return
        }
        performReplyPost(trimmed)
    }

    private func performReplyPost(_ trimmed: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Offline guard: Firestore's setData completion never fires while
        // offline, so without this `isPosting` would stick true forever — the
        // send button spins and the composer locks for the whole offline window,
        // with a ghost optimistic reply showing. Every PostInteractionManager
        // write path already guards this; the drill-down composer regressed it.
        guard NetworkMonitor.shared.isConnected else {
            postError = "you're offline — try again when you're connected"
            return
        }
        crisisConfirmed = false
        nameConfirmed = false
        isPosting = true
        postError = nil
        RateLimiter.shared.lastReplyTime = Date()
        // Pre-generate the doc id so the optimistic child and the real write
        // share an identity — when the reply is promoted to live the listener
        // replaces the optimistic copy with the same-id server doc, no dupe.
        let newDocRef = Firestore.firestore()
            .collection("posts").document(postId)
            .collection("replies").document()
        Task { @MainActor in
            // Resolve handle. The reply-create rule pins authorHandle to the
            // user-doc handle, so a cold UserHandleCache ("anonymous" sentinel)
            // would be REJECTED. Fall back to the user doc — same fix the repost
            // paths use (PostInteractionManager.repost).
            var myHandle = UserHandleCache.shared.handle
            if myHandle == "anonymous" {
                if let snap = try? await Firestore.firestore()
                    .collection("users").document(uid).getDocumentAsync(),
                   let h = snap.data()?["handle"] as? String, !h.isEmpty {
                    myHandle = h
                }
            }
            let now = Date()
            // Optimistically show my reply immediately. The listener only shows
            // `live` replies and mine starts as pending_validation, so without
            // this the reply vanishes after send — the user assumes it failed
            // and resends, producing duplicate replies.
            let optimistic = ThreadedReply(
                id: newDocRef.documentID,
                handle: myHandle,
                text: trimmed,
                likes: 0,
                time: FeedView.timeAgoString(from: now),
                createdAt: now,
                authorId: uid,
                parentReplyId: reply.id,
                children: [],
                isLiked: false,
                isSaved: false,
                isReposted: false,
                repostCount: 0
            )
            children.append(optimistic)
            composerText = ""
            composerFocused = false
            HapticManager.play(.feltThis)

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
            newDocRef.setData(replyData) { err in
                Task { @MainActor in
                    isPosting = false
                    if let err = err {
                        // Roll back the optimistic insert and restore the text.
                        // Release the rate-limit stamp so the failed send doesn't
                        // block the retry for the remaining 5s window (parity with
                        // PostDetailView.postReplyNow).
                        RateLimiter.shared.lastReplyTime = nil
                        children.removeAll { $0.id == newDocRef.documentID }
                        composerText = trimmed
                        let nsErr = err as NSError
                        if nsErr.domain == "FIRFirestoreErrorDomain", nsErr.code == 7 {
                            postError = "still setting up your account — try again in a moment"
                        } else {
                            postError = "couldn't reply. try again."
                        }
                    }
                }
            }
        }
    }

    // MARK: - Child-reply interactions
    // The child rows in this thread were previously wired only for reply/comment,
    // so nested replies couldn't be liked/saved/reposted and their like count was
    // hidden (SwipeToReplyRow gates the heart on onToggleLike != nil). Mirror the
    // PostDetailView child wiring, mutating our local `children` array.

    private func mutateChild(_ id: String, _ mutate: (inout ThreadedReply) -> Void) {
        if let i = children.firstIndex(where: { $0.id == id }) {
            mutate(&children[i])
        }
    }

    private func toggleChildLike(_ child: ThreadedReply) {
        PostInteractionManager.toggleReplyLike(
            postId: postId, replyId: child.id,
            replyText: child.text, replyHandle: child.handle,
            replyAuthorId: child.authorId,
            currentlyLiked: child.isLiked, currentCount: child.likes
        ) { result in
            mutateChild(child.id) { $0.isLiked = result.isLiked; $0.likes = result.newCount }
        }
    }

    private func toggleChildSave(_ child: ThreadedReply) {
        HapticManager.play(.feltThis)
        PostInteractionManager.toggleReplySave(
            postId: postId, replyId: child.id,
            replyText: child.text, replyHandle: child.handle,
            replyAuthorId: child.authorId,
            currentlySaved: child.isSaved
        ) { newSaved in
            mutateChild(child.id) { $0.isSaved = newSaved }
        }
    }

    private func repostChild(_ child: ThreadedReply) {
        let currentCount = child.repostCount
        if child.isReposted {
            PostInteractionManager.unrepostReply(replyId: child.id, currentCount: currentCount) { result in
                mutateChild(child.id) { $0.isReposted = result.isReposted; $0.repostCount = result.newCount }
            }
            return
        }
        PostInteractionManager.repostReply(
            postId: postId, replyId: child.id,
            replyText: child.text, replyAuthorId: child.authorId,
            replyAuthorHandle: child.handle, currentCount: currentCount
        ) { result in
            mutateChild(child.id) { $0.isReposted = result.isReposted; $0.repostCount = result.newCount }
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
            replyAuthorId: replyAuthorId,
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
                        // Profile tabs are one-shot fetches (2026-07-29 sync
                        // sweep) — see PostDetailView.deleteReply.
                        NotificationCenter.default.post(name: .replyDeleted, object: nil,
                                                        userInfo: ["replyId": reply.id])
                        dismiss()
                    }
                }
            }
    }
}
