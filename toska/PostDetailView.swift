import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// Hashable conformance is required so .navigationDestination(item:) can
// use ThreadedReply as a navigation-path identity for the reply-share
// push. Swift synthesizes Hashable since all stored fields are Hashable
// (String, Int, Bool, Optional<String>, recursive Array of self).
struct ThreadedReply: Identifiable, Hashable {
    let id: String
    let handle: String
    let text: String
    var likes: Int
    let time: String
    // Raw createdAt, kept so the two reply queries (M-1: live replies +
    // the author's own held replies) can be merged back into a single
    // chronological thread client-side. The server orders each query, but
    // the merged list has to be re-sorted across both.
    let createdAt: Date
    let authorId: String
    let parentReplyId: String?
    var children: [ThreadedReply]
    // M-1: this reply is the current user's own reply held at
    // moderationStatus == "pending_review" — hidden from everyone else,
    // shown to its author with an "under review" banner. pendingReasonLabel
    // is the user-facing category ("may contain names or contact info").
    var isPending: Bool = false
    var pendingReasonLabel: String? = nil
    // Per-user interaction state — stamped during fetchReplies by
    // intersecting the snapshot's reply ids with the current user's
    // likedReplies / savedReplies / own reposts. Mutable so the toggle
    // handlers in SwipeToReplyRow can update optimistically without
    // rebuilding the whole list. Default false so newly-arriving
    // replies in the listener delta render as un-interacted until the
    // post-snapshot state-load fills them in.
    var isLiked: Bool = false
    var isSaved: Bool = false
    var isReposted: Bool = false
    var repostCount: Int = 0
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

    init(postId: String, handle: String, text: String, tag: String?, likes: Int, reposts: Int, replies: Int, time: String, authorId: String = "", isAlreadyLiked: Bool = false, isAlreadySaved: Bool = false, isAlreadyReposted: Bool = false, gifUrl: String? = nil, isLetter: Bool = false, isWhisper: Bool = false) {
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
        // Seed the display @State from the init params so the FIRST rendered
        // frame is complete. Otherwise the body/counts render empty/"0" and pop
        // to full size one frame later — mid-push — which reads as a glitchy,
        // non-seamless open (a vertical reflow while the view slides in).
        // State(initialValue:) runs ONLY at first identity creation, so onAppear
        // re-fires and edits are preserved automatically (this replaces the old
        // didSeedContent guard); the live listener keeps them synced afterward.
        _postText = State(initialValue: text)
        _likeCount = State(initialValue: likes)
        _localRepostCount = State(initialValue: reposts)
        _postGifUrl = State(initialValue: gifUrl)
        _isLetter = State(initialValue: isLetter)
        _isWhisper = State(initialValue: isWhisper)
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var replyFocused: Bool
    @State private var replyText = ""
    @State private var isLiked = false
    @State private var isSaved = false
    @State private var isReposted = false
    @State private var likeCount: Int = 0
    @State private var localRepostCount: Int = 0
    @State private var replyList: [ThreadedReply] = []
    // True once the reply snapshot listener has returned at least once. Lets
    // the UI show reply skeletons while loading instead of flashing the
    // "be the first to reply" empty state and then popping replies in.
    @State private var hasLoadedReplies = false
    // Reply ids whose collapsed deep-thread subtree the user has expanded
    // via the "show N more replies" stub. Persists across listener
    // re-renders within the lifetime of this PostDetailView (new push of
    // PostDetailView resets to empty). Set semantics so expanding the
    // same thread twice is idempotent.
    @State private var expandedDeepThreads: Set<String> = []
    @State private var replyingToId: String? = nil
    @State private var replyingToHandle: String? = nil
    @State private var showShareCard = false
    // Per-reply share — set when the user taps the share icon on a reply
    // row; presents a ShareCardView for the reply's text + handle. Uses
    // sheet(item:) so SwiftUI auto-binds the dismiss + presentation to
    // the optional state without a separate Bool flag.
    @State private var shareReply: ThreadedReply? = nil
    // Set when a reply-share tap is denied because the reply author's
    // allowSharing is off (checked at tap time — replies carry no
    // denormalized isShareable; see ShareConsent).
    @State private var replyShareBlocked = false
    @State private var showOtherProfile = false
    @State private var authorUserId = ""
    @State private var isAuthorIdLoading = true
    @State private var likePulse = false
    @State private var likePulseTask: Task<Void, Never>? = nil
    @State private var liveListener: ListenerRegistration? = nil
    @State private var suppressListenerUntil: Date = .distantPast
    @State private var showDeleteAlert = false
    @State private var showAdminDeleteAlert = false
    @State private var showEditSheet = false
    @State private var editText = ""
    @State private var isDeleting = false
    @State private var deleteError = ""
    @State private var didOpenHaptic = false
    @State private var replyDraftSaveTask: Task<Void, Never>? = nil   // debounces the encrypted reply-draft write
    @State private var postText: String = ""
    // GIF URL attached to the post. Populated by the live snapshot listener
    // (startLiveListener), so it appears as soon as the post doc is read and
    // updates if the post's gifUrl ever changes server-side.
    @State private var postGifUrl: String? = nil
    @State private var showBlockedAlert = false
    @State private var showReportedAlert = false
    @State private var showReportFailedAlert = false
    @State private var showReplyNameWarning = false
    @State private var showReplyContentWarning = false
    @State private var replyContentWarningMessage = ""
    @State private var showReplyGentleCheck = false
    @State private var pendingReplyText = ""
    @State private var replyGentleCheckLevel: CrisisLevel = .soft
    @State private var replyGentleCheckTopic: CrisisTopic? = nil
    @State private var replyGifUrl: String? = nil
    @State private var showReplyGifPicker = false
    // Edit / delete for the viewer's own reply, from the reply context menu.
    // The reply snapshot listener (replyListener) reflects the change in
    // replyList automatically, so there's no manual list mutation here.
    @State private var editReplyId = ""
    @State private var editReplyText = ""
    @State private var showEditReply = false
    @State private var deleteReplyId = ""
    @State private var showDeleteReplyAlert = false
    @State private var deleteReplyError: String? = nil
    // Surfaced when a reply can't be sent (e.g. offline) so the user gets
    // feedback instead of a silent no-op + a duplicate on reconnect.
    @State private var replyPostError: String? = nil
    @State private var isLetter = false
    @State private var isWhisper = false
    // Sharing consent, mirrored from the live listener. Starts FALSE (share
    // button hidden) until server truth arrives — fail-closed is the right
    // direction for a consent gate. The feed treats a missing field as
    // shareable (legacy pre-stamp docs); the listener mirror below matches
    // that, so the two surfaces agree once the first snapshot lands. A live
    // revocation (onAllowSharingChanged backfill) hides the button mid-view.
    @State private var isShareable = false
    // Midnight flag, fetched alongside isLetter/isWhisper below. Only gates
    // the public share LINK (the /p/{id} web page 404s midnight posts) — the
    // image-card share stays available for midnight posts, matching the feed.
    @State private var isMidnight = false

    var isOwnPost: Bool {
        authorUserId == Auth.auth().currentUser?.uid
    }

    // MARK: - Body

    var body: some View {
        mainContent
            .safeAreaInset(edge: .bottom, spacing: 0) { replyBarView }
            .hidesAppTabBar()
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(false)
            .onAppear {
                            // NOTE: removed the post-open keyboard prewarm — on a real
                            // device the becomeFirstResponder briefly flashed the
                            // keyboard as a rectangle over the reply bar when the post
                            // opened. The launch-time prewarm (KeyboardDismiss) stays.
                            // Light haptic on first open (gated so returning to this
                            // post from a deeper push doesn't re-fire).
                            if !didOpenHaptic {
                                didOpenHaptic = true
                                HapticManager.play(.tabSwitch)
                            }
                            // postText/likeCount/localRepostCount/postGifUrl/
                            // isLetter/isWhisper are now seeded from the init
                            // params in init() (via State(initialValue:)) so the
                            // first frame is complete and the open is seamless.
                            // The live listener keeps them synced with server
                            // truth (incl. edits) thereafter.
                            if !postId.isEmpty {
                                Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, error in
                                    Task { @MainActor in
                                        if let error = error {
                                            // The reply UI silently uses the 500-char limit
                                            // when isLetter stays false on error — fine for
                                            // letters that never resolve, but worth surfacing.
                                            Telemetry.recordError(error, context: "PostDetailView.isLetter.fetch")
                                            return
                                        }
                                        if snapshot?.data()?["isLetter"] as? Bool == true { isLetter = true }
                                        if snapshot?.data()?["isWhisper"] as? Bool == true { isWhisper = true }
                                        if snapshot?.data()?["isMidnightPost"] as? Bool == true { isMidnight = true }
                                    }
                                }
                                // Restore any reply draft persisted from a
                                // prior session that was killed mid-typing.
                                // N-4: from the protected DraftStore (migrates +
                                // scrubs a legacy UserDefaults copy on first read).
                                if replyText.isEmpty {
                                    let key = UserDefaultsKeys.replyDraft(postId: postId)
                                    if let saved = DraftStore.get(forKey: key), !saved.isEmpty {
                                        replyText = saved
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
                                // M-2 (2026-07-19 audit): opening a thread whose
                                // author you've already blocked (e.g. from the
                                // Saved/Liked tab) must not render their content.
                                // The .userBlocked receiver only covers blocking
                                // WHILE viewing; this covers already-blocked-on-open.
                                if BlockedUsersCache.shared.isBlocked(authorId) { dismiss(); return }
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
                            teardownReplyListeners()
                            likePulseTask?.cancel()
                            likePulseTask = nil
                        }
            // Sign-out tears down both Firestore listeners and dismisses back
            // to the splash. Without this, a session expiring while on the
            // detail view leaves the listeners attached to a stale uid; their
            // next snapshot would log a permission-denied error and the post
            // would silently freeze in its last-rendered state.
            .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
                liveListener?.remove()
                liveListener = nil
                teardownReplyListeners()
                likePulseTask?.cancel()
                likePulseTask = nil
                // The debounced reply-draft write must not land after the
                // sign-out scrub (cross-user draft leak on a shared device).
                replyDraftSaveTask?.cancel()
                replyDraftSaveTask = nil
                dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                          dismiss()
                      }
            .onReceive(NotificationCenter.default.publisher(for: .userBlocked)) { notif in
                // If the blocked user is the POST author (blocked via one of
                // their replies in this thread, or from their profile), the
                // whole thread is now hidden content — leave instead of
                // rendering a headless thread whose next refresh denies.
                if let blockedId = notif.userInfo?["userId"] as? String,
                   !blockedId.isEmpty, blockedId == authorUserId {
                    dismiss()
                    return
                }
                // Blocking a reply author from within the thread must clear their
                // replies immediately. The reply listener only re-runs the blocked
                // filter on a server delta (which won't fire), so rebuild now.
                Task { await recombineReplies() }
            }
            // confirmationDialog removed — the ⋯ button is now a Menu (popover
            // anchored under the dots), so edit/delete/report/block are
            // rendered inline by SwiftUI without needing a separate sheet.
            .alert("couldn't delete", isPresented: .init(get: { !deleteError.isEmpty }, set: { if !$0 { deleteError = "" } })) {
                Button("ok") { deleteError = "" }
            } message: { Text(deleteError) }
            .alert("delete this post?", isPresented: $showDeleteAlert) {
                            Button("cancel", role: .cancel) {}
                            Button("delete", role: .destructive) { deletePost() }
                        } message: {
                            Text("this is permanent. it'll be gone for everyone.")
                        }
            .alert("delete this post for everyone?", isPresented: $showAdminDeleteAlert) {
                            Button("cancel", role: .cancel) {}
                            Button("delete (admin)", role: .destructive) { adminDeletePost() }
                        } message: {
                            Text("removes the post and its replies permanently. this action is recorded in the admin audit log.")
                        }
            .alert("user blocked", isPresented: $showBlockedAlert) {
                Button("ok") { dismiss() }
            } message: { Text("you won't see posts from this person anymore.") }
            .alert("post reported", isPresented: $showReportedAlert) {
                Button("ok") {}
            } message: { Text("thanks for letting us know. we'll review this post.") }
            .alert("couldn't report", isPresented: $showReportFailedAlert) {
                Button("ok") {}
            } message: { Text("something went wrong. please try again in a bit.") }
            .alert("hold on", isPresented: $showReplyContentWarning) {
                Button("edit") {}
            } message: { Text(replyContentWarningMessage) }
            .alert("couldn't reply", isPresented: Binding(
                get: { replyPostError != nil },
                set: { if !$0 { replyPostError = nil } }
            )) {
                Button("ok", role: .cancel) {}
            } message: { Text(replyPostError ?? "") }
            .alert("keep it anonymous", isPresented: $showReplyNameWarning) {
                Button("edit") {}
                Button("reply anyway", role: .destructive) {
                    if let level = crisisCheckLevelRespectingSetting(for: pendingReplyText) {
                        replyGentleCheckLevel = level
                        replyGentleCheckTopic = crisisTopic(for: pendingReplyText)
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
                        topic: replyGentleCheckTopic,
                        onProceed: { postReplyNow(pendingReplyText) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showReplyGentleCheck)
            .navigationDestination(isPresented: $showEditSheet) {
                EditPostView(postId: postId, isLetter: isLetter, currentText: $postText, editText: $editText)
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
            }
            .navigationDestination(isPresented: $showShareCard) {
                ShareCardView(text: postText, handle: handle, feltCount: likeCount, tag: tag,
                              shareURL: ShareConsent.publicShareURL(
                                  postId: postId, isShareable: isShareable,
                                  isLetter: isLetter, isWhisper: isWhisper,
                                  isMidnight: isMidnight))
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
            }
            .navigationDestination(item: $shareReply) { reply in
                // Reply share — same ShareCardView component as post share,
                // parameterized with reply fields. tag is nil because
                // replies don't carry tags; the card renders without the
                // tag chip in that case (ShareCardView already handles
                // optional tag).
                ShareCardView(text: reply.text, handle: reply.handle, feltCount: reply.likes, tag: nil)
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
            }
            .alert("sharing is off", isPresented: $replyShareBlocked) {
                Button("got it", role: .cancel) {}
            } message: {
                Text("the writer of this reply keeps sharing turned off, so it can't leave toska.")
            }
            .navigationDestination(isPresented: $showOtherProfile) {
                            OtherProfileView(userId: authorUserId, handle: handle)
                                .navigationBarHidden(true)
                        }
            .navigationDestination(isPresented: $showReplyGifPicker) {
                GifPickerView { url in replyGifUrl = url }
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
            }
            // Edit own reply in the thread. Reuses EditReplyView (defined in
            // ProfileView.swift). The reply snapshot listener refreshes the
            // edited text into replyList, so no onSave mutation is needed here.
            .navigationDestination(isPresented: $showEditReply) {
                EditReplyView(postId: postId, replyId: editReplyId, replyText: $editReplyText) { }
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
            }
            .alert("delete this reply?", isPresented: $showDeleteReplyAlert) {
                Button("delete", role: .destructive) { deleteReply(replyId: deleteReplyId) }
                Button("cancel", role: .cancel) {}
            } message: {
                Text("this can't be undone.")
            }
            .alert(
                "couldn't delete",
                isPresented: Binding(
                    get: { deleteReplyError != nil },
                    set: { if !$0 { deleteReplyError = nil } }
                ),
                presenting: deleteReplyError
            ) { _ in
                Button("ok", role: .cancel) { deleteReplyError = nil }
            } message: { msg in
                Text(msg)
            }
    }

    // MARK: - Main Content

    var mainContent: some View {
        ZStack {
            LateNightTheme.feedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header — ToskaHeader with the ellipsis menu in the trailing
                // slot. The swipe-down-to-dismiss gesture is preserved on the
                // header bounds (legacy from when PostDetailView was a sheet;
                // still works as a redundant gesture alongside the system
                // swipe-from-left and the back chevron).
                ToskaHeader(
                    title: "post",
                    onBack: { dismiss() }
                ) {
                    // Menu (popover anchored under the ⋯ button) instead of
                    // a .confirmationDialog action sheet pinned to the screen
                    // bottom. Matches OtherProfileView's pattern so options
                    // appear right where the user tapped, with a 44pt tap
                    // target so the bare 17pt image is reliably hit.
                    Menu {
                        if isOwnPost {
                            Button {
                                editText = postText
                                showEditSheet = true
                            } label: {
                                Label("edit post", systemImage: "pencil")
                            }
                            // postText can still be empty on the push/deep-link
                            // path (init seeds text:"" and the live listener
                            // hasn't delivered yet — authorUserId arrives via a
                            // separate fetch, so the menu can unlock first).
                            // Editing from an empty buffer would let a save
                            // replace the whole post with the typed fragment;
                            // posts are never legitimately empty (rules: size>0).
                            // Disabled (not a silent no-op) until the text lands.
                            .disabled(postText.isEmpty)
                            Button(role: .destructive) {
                                showDeleteAlert = true
                            } label: {
                                Label("delete post", systemImage: "trash")
                            }
                        } else {
                            Button {
                                reportPost()
                            } label: {
                                Label("report", systemImage: "flag")
                            }
                            Button(role: .destructive) {
                                blockUser()
                            } label: {
                                Label("block", systemImage: "person.slash")
                            }
                            // Admin-only removal of someone else's post from
                            // right here — mirrors FeedPostRow's context-menu
                            // item. firestore.rules enforces the admin gate
                            // server-side; this button is convenience only.
                            if AdminManager.shared.isAdmin && !postId.isEmpty {
                                Button(role: .destructive) {
                                    showAdminDeleteAlert = true
                                } label: {
                                    Label("delete post (admin)", systemImage: "trash")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(Color.toskaTimestamp)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .opacity(isAuthorIdLoading ? 0 : 1)
                    .accessibilityLabel(isOwnPost ? "Edit or delete post" : "Report or block")
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.height > 80 && abs(value.translation.width) < 60 {
                                dismiss()
                            }
                        }
                )

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        postHeaderSection
                            .padding(.horizontal, 16)
                            .padding(.top, 16)

                        if replyLoadFailed {
                            ToskaErrorBanner("couldn't load replies — check your connection") {
                                replyLoadFailed = false
                                fetchReplies()
                            }
                            .padding(.top, 8)
                        }

                        if replyList.isEmpty && !hasLoadedReplies && replies > 0 {
                            // Loading state. The post is known to have replies
                            // (count arrived with the post), but the snapshot
                            // listener hasn't returned yet. Show skeletons so
                            // there's no flash of the "be the first to reply"
                            // empty state before the real replies fade in.
                            LazyVStack(spacing: 0) {
                                ForEach(0..<min(max(replies, 1), 5), id: \.self) { _ in
                                    SkeletonReplyRow()
                                    Rectangle()
                                        .fill(Color.toskaBorderLight.opacity(0.5))
                                        .frame(height: 0.5)
                                        .padding(.leading, 16)
                                }
                            }
                            .transition(.opacity)
                        } else if replyList.isEmpty {
                                                    VStack(spacing: 8) {
                                                        Text("\"some words just need\na witness.\"")
                                                            .font(ToskaFont.serifItalic(18))
                                                            .foregroundColor(Color.toskaTimestamp)
                                                            .multilineTextAlignment(.center)
                                                            .lineSpacing(4)
                                                        Text("be the first to reply")
                                                            .font(ToskaFont.sans(11))
                                                            .foregroundColor(Color.toskaDivider)
                                                    }
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 40)
                        } else {
                            LazyVStack(spacing: 0) {
                                let flat = flattenReplies(replyList)
                                ForEach(Array(flat.enumerated()), id: \.element.id) { index, item in
                                    let indent = CGFloat(item.depth) * 24
                                    if item.hiddenChildren > 0 {
                                        // Show-more stub for a collapsed
                                        // deep-thread subtree. Tap expands.
                                        Button {
                                            expandedDeepThreads.insert(item.reply.id)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.turn.down.right")
                                                    .font(.system(size: 10, weight: .light))
                                                Text(item.hiddenChildren == 1
                                                     ? "show 1 more reply"
                                                     : "show \(item.hiddenChildren) more replies")
                                                    .font(ToskaFont.sans(11, weight: .medium))
                                            }
                                            .foregroundColor(Color.toskaBlue)
                                            .padding(.leading, 18 + indent + 18)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        if index < flat.count - 1 {
                                            Rectangle()
                                                .fill(Color.toskaBorderLight.opacity(0.3))
                                                .frame(height: 0.5)
                                                .padding(.leading, 18 + indent)
                                        }
                                    } else {
                                    SwipeToReplyRow(
                                        item: item,
                                        indent: indent,
                                        onReply: {
                                            replyingToId = item.reply.id
                                            replyingToHandle = item.reply.handle
                                            replyFocused = true
                                        },
                                        postId: postId,
                                        onToggleLike: { toggleReplyLikeAt(replyId: item.reply.id) },
                                        onToggleSave: { toggleReplySaveAt(replyId: item.reply.id) },
                                        onRepost: { repostReplyAt(replyId: item.reply.id) },
                                        onComment: {
                                            replyingToId = item.reply.id
                                            replyingToHandle = item.reply.handle
                                            replyFocused = true
                                        },
                                        onShare: { requestReplyShare(item.reply) },
                                        onEdit: {
                                            editReplyId = item.reply.id
                                            editReplyText = item.reply.text
                                            showEditReply = true
                                        },
                                        onDelete: {
                                            deleteReplyId = item.reply.id
                                            showDeleteReplyAlert = true
                                        }
                                    )
                                    if index < flat.count - 1 {
                                        Rectangle()
                                            .fill(Color.toskaBorderLight.opacity(item.depth > 0 ? 0.3 : 0.5))
                                            .frame(height: 0.5)
                                            .padding(.leading, 18 + indent)
                                    }
                                    } // end else (regular row branch)
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
            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

            if let gifUrl = replyGifUrl {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        // 2026-06-01 audit: use StableGifPreview, not a raw
                        // AsyncImage. replyBarView also holds the $replyText
                        // TextField, so it recomputes on every keystroke — a
                        // raw AsyncImage re-cancels its load each time
                        // (NSURLError -999), flickering the attached-GIF
                        // thumbnail. StableGifPreview owns its load +
                        // placeholder/failure and survives the recompute
                        // (same fix already used at PostDetailView:627 and
                        // FeedView:992).
                        StableGifPreview(urlString: gifUrl, maxHeight: 100)
                        Button { withAnimation { replyGifUrl = nil } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Color.toskaMidGray)
                                .background(Circle().fill(.white))
                        }
                        .offset(x: -2, y: 2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let handle = replyingToHandle {
                HStack(spacing: 8) {
                    Text("replying to \(handle)")
                        .font(ToskaFont.sans(11))
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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                TextField("say something gently…", text: $replyText)
                .autocorrectionDisabled(false)  // autocorrect ON for content (2026-07-21)
                    .font(.system(size: 14))
                    .focused($replyFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(ToskaColor.input)
                    .clipShape(Capsule())
                    // Subtle hairline so the field reads as a distinct input
                    // against the near-same-gray bar background instead of
                    // blending into it.
                    .overlay(Capsule().stroke(ToskaColor.divider.opacity(0.6), lineWidth: 0.5))
                    .onChange(of: replyText) { _, newValue in
                        // Truncate on UTF-16 length to match the Firestore rule's
                        // size() check (mirrors ComposeView) so heavy-emoji replies
                        // don't silently fail the server-side write.
                        if newValue.utf16.count > 500 {
                            var utf16Count = 0
                            var endIdx = newValue.startIndex
                            for ch in newValue {
                                let chUtf16 = String(ch).utf16.count
                                if utf16Count + chUtf16 > 500 { break }
                                utf16Count += chUtf16
                                endIdx = newValue.index(after: endIdx)
                            }
                            replyText = String(newValue[..<endIdx])
                        }
                        // Persist reply draft per post so a kill mid-typing doesn't
                        // lose words. DEBOUNCED (perf): DraftStore.set is a synchronous
                        // encrypted atomic disk write — doing it every keystroke lagged
                        // typing. Wait ~0.5s after typing stops; empty writes (clear on
                        // send) go through immediately.
                        if !postId.isEmpty {
                            let key = UserDefaultsKeys.replyDraft(postId: postId)
                            replyDraftSaveTask?.cancel()
                            if replyText.isEmpty {
                                DraftStore.set(replyText, forKey: key)
                            } else {
                                let toSave = replyText
                                replyDraftSaveTask = Task {
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    guard !Task.isCancelled else { return }
                                    // Sign-out scrub guard: a keystroke <0.5s
                                    // before an out-of-band session expiry must
                                    // not re-persist this draft AFTER
                                    // ContentView's DraftStore.clearAll() — the
                                    // next user on a shared device would
                                    // otherwise inherit it.
                                    guard Auth.auth().currentUser != nil else { return }
                                    DraftStore.set(toSave, forKey: key)
                                }
                            }
                        }
                    }
                // M4 (2026-07-22): enablement must mirror sendReply's guard
                // (text >= 2 chars — rules require text on every reply, so a
                // GIF alone can never send). The old `|| gif attached` condition
                // lit the button for GIF-only / 1-char replies whose tap then
                // silently returned.
                let replyIsSendable = replyText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                Button { sendReply() } label: {
                    ZStack {
                        Circle()
                            .fill(replyIsSendable ? ToskaColor.accent : ToskaColor.input)
                            .frame(width: 40, height: 40)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(replyIsSendable ? .white : ToskaColor.text3)
                    }
                }
                .disabled(!replyIsSendable)
            }
            .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
        .background(
            LateNightTheme.cardBackground.ignoresSafeArea(edges: .bottom)
                .overlay(Rectangle().fill(ToskaColor.divider).frame(height: 0.5), alignment: .top)
        )
           }

    // MARK: - Post Header Section

    var postHeaderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header mirrors the feed row: emotion avatar as the left anchor,
            // handle + time stacked beside it, and the feeling as a pill on the
            // trailing edge — so tapping into a post feels continuous with the feed.
            HStack(alignment: .center, spacing: 11) {
                emotionAvatar(for: tag, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        if !isOwnPost && !authorUserId.isEmpty { showOtherProfile = true }
                    } label: {
                        HStack(spacing: 6) {
                            Text(handle)
                                .font(ToskaFont.sans(15, weight: .semibold))
                                .foregroundColor(ToskaColor.text2)
                            if isOwnPost {
                                Text("· you")
                                    .font(ToskaFont.sans(11, weight: .medium))
                                    .foregroundColor(ToskaColor.text3)
                            }
                        }
                    }
                    Text(time)
                        .font(ToskaFont.sans(12))
                        .foregroundColor(ToskaColor.time)
                }
                Spacer()
                if let tag = tag {
                    Text(tag)
                        .font(ToskaFont.sans(11, weight: .semibold))
                        .foregroundColor(tagColor(for: tag))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(tagColor(for: tag).opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            .padding(.bottom, 16)

            Text(postText)
                .toskaPostDetailBody()
                .foregroundColor(ToskaColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            // Attached GIF, if the post has one. Read from Firestore by the
            // live listener (data["gifUrl"]) — PostDetailView previously never
            // rendered the post's GIF, so opening a GIF post from the feed
            // showed only the text. StableGifPreview (shared from ComposeView)
            // sidesteps SwiftUI's AsyncImage cancellation issue inside views
            // that recompute frequently.
            if let gifUrl = postGifUrl, !gifUrl.isEmpty {
                StableGifPreview(urlString: gifUrl)
                    .padding(.bottom, 16)
            }

            HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Text(formatFull(likeCount))
                                    .font(ToskaFont.sans(12, weight: .bold))
                                    .foregroundColor(likePulse ? Color.toskaBlue : Color.toskaTextDark)
                                    .scaleEffect(likePulse ? 1.15 : 1.0)
                                    .animation(reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.3, dampingFraction: 0.5), value: likePulse)
                                Text("felt this")
                                    .font(ToskaFont.sans(11, weight: .medium))
                                    .foregroundColor(likePulse ? Color.toskaBlue : Color.toskaTextLight)
                            }
                            // replyList.count is ROOT replies only (nested live in
                            // .children), so it undercounted threaded posts. Count the
                            // whole tree; fall back to (and never drop below) the server
                            // `replies` value we opened with.
                            statLabel(count: replyList.isEmpty ? replies : max(replies, countAllReplies(replyList)), label: "replies")
                            // 2026-07-30 owner: show reposts alongside felt/replies.
                            statLabel(count: reposts, label: "reposts")
                            Spacer()
                        }
                        .padding(.bottom, 8)

            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

            HStack(spacing: 0) {
                           Button { replyFocused = true } label: {
                               Image(systemName: "bubble.left")
                                   .font(.system(size: 15, weight: .light))
                                   .foregroundColor(Color.toskaTextLight)
                           }
                           .accessibilityLabel("Reply")
                           .frame(maxWidth: .infinity)

                           // LOW-P3-7 (2026-07-20 launch audit): hide like + repost
                           // on your OWN post. Both are no-ops on own content
                           // (PostInteractionManager guards + rules deny self-like/
                           // self-repost), and the reply row already hides them on
                           // own replies — this makes the post row consistent.
                           if !isOwnPost {
                               Button { toggleLike() } label: {
                                   Image(systemName: isLiked ? "heart.fill" : "heart")
                                       .font(.system(size: 15, weight: isLiked ? .medium : .light))
                                       .foregroundColor(isLiked ? Color.toskaWhisperPink : Color.toskaTextLight)
                               }
                               .accessibilityLabel(isLiked ? "Unlike post" : "Like post")
                               .accessibilityValue("\(formatFull(likeCount)) people felt this")
                               .frame(maxWidth: .infinity)

                               Button { repostPost() } label: {
                                   Image(systemName: "arrow.2.squarepath")
                                       .font(.system(size: 15, weight: .light))
                                       .foregroundColor(isReposted ? Color.toskaMovingOnGreen : Color.toskaTextLight)
                               }
                               .accessibilityLabel(isReposted ? "Undo repost" : "Repost")
                               .frame(maxWidth: .infinity)
                               // Whispers can't be reposted (ephemeral — the copy would
                               // outlive the original). Midnight posts are caught by the
                               // tap-time fetch in PostInteractionManager.repost; the
                               // detail view doesn't carry that flag.
                               .disabled(isWhisper)
                               .opacity(isWhisper ? 0.3 : 1.0)
                           }

                           Button { toggleSave() } label: {
                               Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                   .font(.system(size: 15, weight: .light))
                                   .foregroundColor(isSaved ? Color.toskaBlue : Color.toskaTextLight)
                           }
                           .accessibilityLabel(isSaved ? "Unsave post" : "Save post")
                           .frame(maxWidth: .infinity)

                           // Share — opens ShareCardView (the same path as the
                           // feed row's share button). Hidden for letters &
                           // whispers, which are private/ephemeral and not
                           // shareable, AND for posts whose author revoked
                           // sharing consent (isShareable, live-mirrored from
                           // the listener) — this now fully mirrors the feed
                           // row's gating; previously consent revocation never
                           // reached this surface.
                           if isShareable && !isLetter && !isWhisper {
                               Button { showShareCard = true } label: {
                                   Image(systemName: "square.and.arrow.up")
                                       .font(.system(size: 15, weight: .light))
                                       .foregroundColor(Color.toskaTextLight)
                               }
                               .accessibilityLabel("Share post")
                               .frame(maxWidth: .infinity)
                           }
                       }
                       .padding(.vertical, 8)
            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
        }
    }

    // MARK: - UI Helpers

    func statLabel(count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text(formatFull(count)).font(ToskaFont.sans(11, weight: .semibold)).foregroundColor(Color.toskaTextDark)
            Text(label).font(ToskaFont.sans(11)).foregroundColor(Color.toskaTextLight)
        }
    }

    func actionButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .light))
                Text(label).font(ToskaFont.sans(8))
            }
            .foregroundColor(active ? Color.toskaBlue : Color.toskaInactiveGray)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Flattened Reply Helpers

    struct FlatReply: Identifiable {
        let id: String
        let reply: ThreadedReply
        let depth: Int
        // > 0 indicates this row is a "show N more replies" stub for a
        // collapsed deep-thread subtree, not a real reply. The render
        // branches on this to surface a tappable expansion affordance.
        var hiddenChildren: Int = 0
    }

    /// Total number of replies in the threaded tree (root + all nested), for the
    /// "N replies" stat — replyList.count is root-only and undercounts.
    func countAllReplies(_ replies: [ThreadedReply]) -> Int {
        replies.reduce(0) { $0 + 1 + countAllReplies($1.children) }
    }

    func flattenReplies(_ replies: [ThreadedReply], depth: Int = 0, maxDepth: Int = 3) -> [FlatReply] {
            var result: [FlatReply] = []
            var seen: Set<String> = []
            func countDescendants(_ nodes: [ThreadedReply]) -> Int {
                var n = 0
                for c in nodes { n += 1 + countDescendants(c.children) }
                return n
            }
            func walk(_ nodes: [ThreadedReply], d: Int) {
                for reply in nodes {
                    guard !seen.contains(reply.id) else { continue }
                    seen.insert(reply.id)
                    result.append(FlatReply(id: reply.id, reply: reply, depth: d))
                    // At the deepest visible depth: if the reply has
                    // children AND the user hasn't expanded this subtree
                    // yet, append a stub row carrying the descendant
                    // count and skip recursion. Tapping the stub adds
                    // this reply's id to expandedDeepThreads, which
                    // re-runs flatten and includes the full subtree.
                    if d == maxDepth && !reply.children.isEmpty {
                        if !expandedDeepThreads.contains(reply.id) {
                            let n = countDescendants(reply.children)
                            result.append(FlatReply(
                                id: "\(reply.id)_stub",
                                reply: reply,
                                depth: d,
                                hiddenChildren: n
                            ))
                            continue
                        }
                    }
                    let childDepth = d < maxDepth ? d + 1 : d
                    walk(reply.children, d: childDepth)
                }
            }
            walk(replies, d: depth)
            return result
        }

    // MARK: - Reply Share Consent

    // Replies have no denormalized isShareable, so consent is checked at tap
    // time against the reply author's public allowSharing projection. Fail
    // closed: on any read failure the card never presents.
    func requestReplyShare(_ reply: ThreadedReply) {
        Task { @MainActor in
            if await ShareConsent.authorAllowsSharing(reply.authorId) {
                shareReply = reply
            } else {
                replyShareBlocked = true
            }
        }
    }

    // MARK: - Live Listener

    func startLiveListener() {
        guard !postId.isEmpty else { return }
        liveListener?.remove()
        // Capture uid so the snapshot callback can verify it's still serving
        // the same account before mutating @State or dismissing the view.
        // Without this, a sign-out + sign-in to a different account can let
        // a delayed snapshot (e.g. moderator deletes the post) dismiss the
        // post-detail view in the new user's session.
        let capturedUid = Auth.auth().currentUser?.uid
        let registration = Firestore.firestore().collection("posts").document(postId)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let error = error {
                        Telemetry.recordError(error, context: "PostDetailView.liveListener")
                        return
                    }
                    if snapshot?.exists == false {
                        self.liveListener?.remove()
                        self.liveListener = nil
                        self.dismiss()
                        return
                    }
                    guard let data = snapshot?.data() else { return }
                    if data["isLetter"] as? Bool == true { isLetter = true }
                    if data["isWhisper"] as? Bool == true { isWhisper = true }
                    // Unconditional assignment (not set-if-true): consent
                    // revocation while the view is open must hide the share
                    // button, not just enable it. Missing field == shareable,
                    // matching FeedView.feedPost(from:).
                    isShareable = data["isShareable"] as? Bool ?? true
                    // Mirror the post body from server truth so an edit (this
                    // user's via EditPostView, or a remote edit) is reflected.
                    // The view's onAppear seeds postText from the immutable init
                    // param and re-fires on pop-return from EditPostView; without
                    // this, saving an edit would revert the visible text to the
                    // pre-edit value with no self-heal.
                    if let snapText = data["text"] as? String, snapText != postText {
                        postText = snapText
                    }
                    // repostCount isn't rendered here but seeds unrepost math;
                    // keep it live so an unrepost after a push-pop decrements from
                    // the current base rather than the stale init param.
                    if let snapReposts = data["repostCount"] as? Int, snapReposts != localRepostCount {
                        localRepostCount = max(0, snapReposts)
                    }
                    // Pull the attached GIF URL so postHeaderSection can render
                    // it. nil/empty string both clear the preview cleanly.
                    let snapGif = data["gifUrl"] as? String
                    if snapGif != postGifUrl { postGifUrl = snapGif }
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
            // Re-arm suppression from completion time. On slow networks the
            // fixed 2s-from-tap window can lapse before the write round-trips,
            // so without this the live listener re-applies the same server
            // count and re-pulses (visible count flicker). 1.5s absorbs the echo.
            suppressListenerUntil = Date().addingTimeInterval(1.5)
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

    // Each check captures uid at call time and gates the @State write on
    // the auth uid still matching when the Firestore callback resolves.
    // Without the gate, a sign-out + sign-in to a different account during
    // the round-trip lands account A's like/save/repost status in account
    // B's view state.
    func checkIfLiked() {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        let capturedUid = uid
        Firestore.firestore().collection("posts").document(postId).collection("likes").document(uid).getDocument { snapshot, _ in
            Task { @MainActor in
                guard Auth.auth().currentUser?.uid == capturedUid else { return }
                isLiked = snapshot?.exists == true
            }
        }
    }

    func checkIfSaved() {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        let capturedUid = uid
        Firestore.firestore().collection("users").document(uid).collection("saved").document(postId).getDocument { snapshot, _ in
            Task { @MainActor in
                guard Auth.auth().currentUser?.uid == capturedUid else { return }
                isSaved = snapshot?.exists == true
            }
        }
    }

    func checkIfReposted() {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        let capturedUid = uid
        Firestore.firestore().collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: true)
            .whereField("originalPostId", isEqualTo: postId)
            .limit(to: 1)
            .getDocuments { snapshot, _ in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let docs = snapshot?.documents, !docs.isEmpty { isReposted = true }
                }
            }
    }

    // MARK: - Repost

    func repostPost() {
        // Toggle: undo the repost if already reposted, else create it.
        if isReposted {
            PostInteractionManager.unrepost(
                postId: postId, currentCount: localRepostCount
            ) { result in
                isReposted = result.isReposted
                localRepostCount = result.newCount
            }
            return
        }
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
            let followingSnap = try? await db.collection("users").document(uid)
                .collection("following").document(blockedUserId).getDocumentAsync()
            if followingSnap?.exists == true {
                try? await db.collection("users").document(uid).collection("following").document(blockedUserId).delete()
                try? await db.collection("users").document(blockedUserId).collection("followers").document(uid).delete()
                // Counter decrements handled by Cloud Function on follow doc delete.
            }

            let followerSnap = try? await db.collection("users").document(uid)
                .collection("followers").document(blockedUserId).getDocumentAsync()
            if followerSnap?.exists == true {
                try? await db.collection("users").document(uid).collection("followers").document(blockedUserId).delete()
                try? await db.collection("users").document(blockedUserId).collection("following").document(uid).delete()
                // Counter decrements handled by Cloud Function on follow doc delete.
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
            ]) { error in
                // Only confirm success when the write actually lands — a rules
                // denial otherwise showed a false "post reported" alert.
                if error != nil {
                    showReportFailedAlert = true
                } else {
                    Telemetry.reportSubmitted(target: .post, reasonCode: "other")
                    showReportedAlert = true
                }
            }
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

                // Delete likes. T-6 (2026-06-11): cap the read at 500 — the
                // server trigger onPostDeletedCleanupSubtree deletes any remaining
                // likes/replies/reflections once the post doc is removed below, so
                // the client only needs a bounded best-effort first pass instead of
                // reading the entire (possibly huge) likes set.
                let likeSnap = try await db.collection("posts").document(postId).collection("likes").limit(to: 500).getDocumentsAsync()
                let likeDocs = likeSnap.documents

                // Delete only the likes subcollection docs (posts/{postId}/likes/{uid}),
                // which the post author is permitted to delete per firestore.rules.
                // Other users' /users/{uid}/liked/{postId} refs are NOT deleted here —
                // each user owns their own /liked subcollection, and trying to batch-
                // delete them from the post author's session fails the whole batch
                // with permission-denied, aborting the delete entirely. Stale /liked
                // refs self-clean on next visit via ProfileView.loadLikedPosts.
                let likeChunks = stride(from: 0, to: likeDocs.count, by: 499).map {
                    Array(likeDocs[$0..<min($0 + 499, likeDocs.count)])
                }
                for chunk in likeChunks {
                    let batch = db.batch()
                    for doc in chunk {
                        batch.deleteDocument(doc.reference)
                    }
                    try await batch.commit()
                }

                // totalLikes decrements handled by Cloud Function on each like doc deletion above.
            } catch {
                isDeleting = false
                deleteError = "couldn't delete — failed to clean up replies/likes: \(error.localizedDescription)"
                return
            }

            // T-6: bounded best-effort; onPostDeletedCleanupReposts /
            // onPostDeletedCleanupSubtree (Admin SDK) clean up any remainder.
            let repostSnap = try? await db.collection("posts")
                .whereField("isRepost", isEqualTo: true)
                .whereField("originalPostId", isEqualTo: postId)
                .limit(to: 500)
                .getDocumentsAsync()
            for doc in repostSnap?.documents ?? [] { try? await doc.reference.delete() }

            let reflectionSnap = try? await db.collection("posts").document(postId).collection("reflections").limit(to: 500).getDocumentsAsync()
            for doc in reflectionSnap?.documents ?? [] { try? await doc.reference.delete() }

            if let uid = Auth.auth().currentUser?.uid {
                            try? await db.collection("users").document(uid).collection("saved").document(postId).delete()
                            try? await db.collection("users").document(uid).collection("liked").document(postId).delete()
                        }

            do {
                try await db.collection("posts").document(postId).delete()
                isDeleting = false
                // Tell the rest of the app that this postId no longer exists,
                // so cached references can invalidate (e.g. FeedViewModel's
                // todaysPromptResponse card on the home feed). Without this,
                // a user who deletes their daily-prompt response sees the
                // response card stuck on the deleted text until the next
                // pull-to-refresh.
                NotificationCenter.default.post(
                    name: .postDeleted,
                    object: nil,
                    userInfo: ["postId": postId]
                )
                dismiss()
            } catch {
                isDeleting = false
                deleteError = "couldn't delete — \(error.localizedDescription)"
            }
        }
    }

    /// Admin-only removal of another user's post. Unlike the own-post
    /// deletePost() above, this does NO client-side reply/like cleanup —
    /// the like docs belong to other users and an admin batch-delete of
    /// them would permission-fail and abort the whole delete. The server
    /// triggers (onPostDeletedCleanupSubtree / -Reposts) own the cascade.
    /// deletedBy/deletedAt are stamped first so auditPostDeletion records
    /// the acting admin off the pre-delete snapshot, exactly like
    /// AdminModerationView.deletePost.
    private func adminDeletePost() {
        guard AdminManager.shared.isAdmin, !postId.isEmpty, !isDeleting,
              let adminUid = Auth.auth().currentUser?.uid else { return }
        isDeleting = true
        let ref = Firestore.firestore().collection("posts").document(postId)
        Task { @MainActor in
            do {
                try await ref.updateData([
                    "deletedBy": adminUid,
                    "deletedAt": FieldValue.serverTimestamp(),
                ])
                try await ref.delete()
                isDeleting = false
                NotificationCenter.default.post(
                    name: .postDeleted,
                    object: nil,
                    userInfo: ["postId": postId]
                )
                dismiss()
            } catch {
                isDeleting = false
                deleteError = "couldn't delete — \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Replies

    // M-1: the reply thread is read with TWO constrained queries because the
    // reply read rule hides held replies from non-authors. Query A = live
    // replies (everyone); query B = the current user's own held replies (shown
    // with an "under review" banner). An unfiltered listener would be denied
    // the moment any held reply existed under the post.
    @State private var replyListenerLive: ListenerRegistration? = nil
    @State private var replyListenerHeld: ListenerRegistration? = nil
    @State private var rawLiveReplies: [ThreadedReply] = []
    @State private var rawHeldReplies: [ThreadedReply] = []
    // H2: surface a reply-load failure instead of silently showing an empty
    // thread. Set in the listener error branches, cleared on the next good
    // snapshot; the banner's retry re-attaches the listeners via fetchReplies().
    @State private var replyLoadFailed = false

    private func teardownReplyListeners() {
        replyListenerLive?.remove(); replyListenerLive = nil
        replyListenerHeld?.remove(); replyListenerHeld = nil
    }

    // Decode one reply doc into a ThreadedReply (or nil if the author is
    // blocked). isPending is computed from the doc's own moderationStatus, so
    // the same decode works for query A (live → never pending) and query B
    // (the author's own replies → pending iff held).
    private static func threadedReply(from doc: QueryDocumentSnapshot) -> ThreadedReply? {
        let data = doc.data()
        let authorId = data["authorId"] as? String ?? ""
        if BlockedUsersCache.shared.isBlocked(authorId) { return nil }
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let isPending = (data["moderationStatus"] as? String) == "pending_review"
        return ThreadedReply(
            id: doc.documentID,
            handle: data["authorHandle"] as? String ?? "anonymous",
            text: data["text"] as? String ?? "",
            likes: data["likeCount"] as? Int ?? 0,
            time: FeedView.timeAgoString(from: createdAt),
            createdAt: createdAt,
            authorId: authorId,
            parentReplyId: data["parentReplyId"] as? String,
            children: [],
            isPending: isPending,
            pendingReasonLabel: isPending ? pendingReasonLabelFor(data["pendingReason"] as? String) : nil,
            isLiked: false,
            isSaved: false,
            isReposted: false,
            repostCount: data["repostCount"] as? Int ?? 0
        )
    }

    func fetchReplies() {
        guard !postId.isEmpty else { return }
        teardownReplyListeners()
        // Capture uid so the snapshot callbacks can verify they're still
        // serving the same account before writing replyList (sign-out/sign-in
        // race guard — see startLiveListener).
        let capturedUid = Auth.auth().currentUser?.uid
        let repliesRef = Firestore.firestore().collection("posts").document(postId).collection("replies")

        // Query A — live replies, visible to everyone. MUST filter to "live":
        // the reply read rule denies held replies to non-authors, and a list
        // query fails entirely if any returned doc is rule-denied. Clean
        // replies are stamped "live" server-side by validateReply; legacy
        // replies were backfilled by backfillReplyModerationStatus.js.
        // T-6 (2026-06-11): bound the live-replies listener. Previously
        // unbounded, it read the ENTIRE reply set on open + rebuilt the tree on
        // every new reply — a read-cost/main-thread cost that scales with
        // engagement. Fetch the NEWEST 500 (descending + limit); recombineReplies
        // sorts ascending internally, so display order is unchanged and new
        // replies always enter the window. Threads under 500 are fully intact;
        // for the rare mega-thread (>500) the oldest replies fall outside the
        // window — true cursor pagination for deep threads is a follow-up.
        replyListenerLive = repliesRef
            .whereField("moderationStatus", isEqualTo: "live")
            .order(by: "createdAt", descending: true)
            .limit(to: 500)
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("⚠️ fetchReplies(live) listener error for post \(postId): \(error)")
                    Telemetry.recordError(error, context: "PostDetailView.fetchReplies.live")
                    Task { @MainActor in
                        guard Auth.auth().currentUser?.uid == capturedUid else { return }
                        replyLoadFailed = true
                    }
                    return
                }
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    guard let documents = snapshot?.documents else { return }
                    replyLoadFailed = false
                    rawLiveReplies = documents.compactMap { Self.threadedReply(from: $0) }
                    await recombineReplies()
                }
            }

        // Query B — ALL of the current user's own replies under this post
        // (live, held, or freshly-created-not-yet-promoted). authorId == me
        // satisfies the read rule's author disjunct, keeping the query
        // rule-safe, and including the not-yet-"live" window means the author's
        // just-posted reply shows immediately instead of flickering out until
        // validateReply stamps "live". Held ones (moderationStatus ==
        // "pending_review") render with the "under review" banner; the rest are
        // deduped against query A in recombineReplies.
        if let uid = capturedUid {
            replyListenerHeld = repliesRef
                .whereField("authorId", isEqualTo: uid)
                .order(by: "createdAt", descending: false)
                .addSnapshotListener { snapshot, error in
                    if let error = error {
                        print("⚠️ fetchReplies(mine) listener error for post \(postId): \(error)")
                        Telemetry.recordError(error, context: "PostDetailView.fetchReplies.mine")
                        Task { @MainActor in
                            guard Auth.auth().currentUser?.uid == capturedUid else { return }
                            replyLoadFailed = true
                        }
                        return
                    }
                    Task { @MainActor in
                        guard Auth.auth().currentUser?.uid == capturedUid else { return }
                        guard let documents = snapshot?.documents else { return }
                        rawHeldReplies = documents.compactMap { Self.threadedReply(from: $0) }
                        await recombineReplies()
                    }
                }
        } else {
            rawHeldReplies = []
        }
    }

    // Merge the live + own-held reply sets into one chronological thread,
    // render immediately, then stamp per-user interaction state. Both listeners
    // call this; @MainActor serializes them so the raw-store reads are
    // consistent.
    @MainActor
    private func recombineReplies() async {
        var byId: [String: ThreadedReply] = [:]
        for r in rawLiveReplies { byId[r.id] = r }
        for r in rawHeldReplies where byId[r.id] == nil { byId[r.id] = r }
        var flat = byId.values.sorted { $0.createdAt < $1.createdAt }

        // Carry forward interaction state we've already resolved (INCLUDING
        // in-flight optimistic toggles) for replies already on screen, so a
        // snapshot delta (e.g. another user's reply arriving) can't re-stamp a
        // reply you just liked back to un-liked and strand the optimistic +1.
        // Mirrors ReplyDetailView's build-42 carry-forward; only genuinely-new
        // replies get re-stamped from the server below.
        var priorState: [String: (Bool, Bool, Bool)] = [:]
        func collect(_ replies: [ThreadedReply]) {
            for r in replies { priorState[r.id] = (r.isLiked, r.isSaved, r.isReposted); collect(r.children) }
        }
        collect(replyList)
        for i in flat.indices {
            if let s = priorState[flat[i].id] {
                flat[i].isLiked = s.0; flat[i].isSaved = s.1; flat[i].isReposted = s.2
            }
        }

        print("ℹ️ fetchReplies recombine for post \(postId): \(rawLiveReplies.count) live + \(rawHeldReplies.count) held → \(flat.count)")
        withAnimation(.easeInOut(duration: 0.2)) {
            replyList = buildThreadedReplies(from: flat)
            hasLoadedReplies = true
        }
        let unresolved = flat.filter { priorState[$0.id] == nil }
        if let uid = Auth.auth().currentUser?.uid, !unresolved.isEmpty {
            let db = Firestore.firestore()
            let stamped = await Self.stampReplyInteractionState(
                replies: unresolved, replyIds: unresolved.map { $0.id }, uid: uid, db: db
            )
            let stampedMap = Dictionary(
                stamped.map { ($0.id, ($0.isLiked, $0.isSaved, $0.isReposted)) },
                uniquingKeysWith: { a, _ in a }
            )
            // Re-derive PRESENCE from the current raw stores rather than writing
            // the pre-await `flat`: another listener delta (query A or B) may have
            // landed during the stamp await, and rebuilding from stale `flat`
            // would silently DROP the reply it added until the view is reopened.
            // Re-read current on-screen interaction state and overlay our fresh
            // stamps, so two interleaving recombines converge regardless of which
            // finishes last.
            var freshById: [String: ThreadedReply] = [:]
            for r in rawLiveReplies { freshById[r.id] = r }
            for r in rawHeldReplies where freshById[r.id] == nil { freshById[r.id] = r }
            var freshFlat = freshById.values.sorted { $0.createdAt < $1.createdAt }
            var state: [String: (Bool, Bool, Bool)] = [:]
            func collectState(_ replies: [ThreadedReply]) {
                for r in replies { state[r.id] = (r.isLiked, r.isSaved, r.isReposted); collectState(r.children) }
            }
            collectState(replyList)
            for (id, s) in stampedMap { state[id] = s }
            for i in freshFlat.indices {
                if let s = state[freshFlat[i].id] {
                    freshFlat[i].isLiked = s.0; freshFlat[i].isSaved = s.1; freshFlat[i].isReposted = s.2
                }
            }
            replyList = buildThreadedReplies(from: freshFlat)
        }
    }

    // Walks the threaded replyList recursively, mutating the first reply
    // whose id matches. Returns true on hit so the recursion short-circuits
    // up the stack. Used by the per-reply toggle handlers below to apply
    // optimistic UI updates + final reconciled state without rebuilding
    // the whole tree from scratch.
    @discardableResult
    private func mutateReplyInTree(replyId: String, mutate: (inout ThreadedReply) -> Void) -> Bool {
        func walk(_ replies: inout [ThreadedReply]) -> Bool {
            for i in replies.indices {
                if replies[i].id == replyId {
                    mutate(&replies[i])
                    return true
                }
                if walk(&replies[i].children) { return true }
            }
            return false
        }
        return walk(&replyList)
    }

    // Looks up the current state of a reply by id without mutating. Used
    // by the toggle handlers to read the latest (post-optimistic) state
    // before passing into PostInteractionManager.
    private func findReplyInTree(replyId: String) -> ThreadedReply? {
        func walk(_ replies: [ThreadedReply]) -> ThreadedReply? {
            for r in replies {
                if r.id == replyId { return r }
                if let found = walk(r.children) { return found }
            }
            return nil
        }
        return walk(replyList)
    }

    // MARK: - Reply interaction handlers

    private func toggleReplyLikeAt(replyId: String) {
        guard let reply = findReplyInTree(replyId: replyId) else { return }
        let currentlyLiked = reply.isLiked
        let currentCount = reply.likes
        PostInteractionManager.toggleReplyLike(
            postId: postId,
            replyId: reply.id,
            replyText: reply.text,
            replyHandle: reply.handle,
            replyAuthorId: reply.authorId,
            currentlyLiked: currentlyLiked,
            currentCount: currentCount
        ) { result in
            mutateReplyInTree(replyId: replyId) { r in
                r.isLiked = result.isLiked
                r.likes = result.newCount
            }
        }
    }

    /// Deletes the viewer's own reply. Plain document delete — the
    /// onReplyDeletedUpdateCount Cloud Function decrements the post's
    /// replyCount, and the reply snapshot listener removes it from replyList.
    /// Mirrors ProfileView.deleteReply (the post update rule blocks client
    /// counter writes, so a transaction here would fail permission_denied).
    private func deleteReply(replyId: String) {
        guard !replyId.isEmpty, !postId.isEmpty else { return }
        Firestore.firestore()
            .collection("posts").document(postId)
            .collection("replies").document(replyId)
            .delete { error in
                Task { @MainActor in
                    if let error = error {
                        print("⚠️ deleteReply failed: \(error)")
                        Telemetry.recordError(error, context: "PostDetailView.deleteReply")
                        deleteReplyError = "couldn't delete — try again"
                    } else {
                        // This thread self-heals via the reply listener; the
                        // profile's Replies/Saved/Liked tabs are one-shot
                        // fetches and need the signal (2026-07-29 sync sweep).
                        NotificationCenter.default.post(name: .replyDeleted, object: nil,
                                                        userInfo: ["replyId": replyId])
                    }
                }
            }
    }

    private func toggleReplySaveAt(replyId: String) {
        guard let reply = findReplyInTree(replyId: replyId) else { return }
        let currentlySaved = reply.isSaved
        PostInteractionManager.toggleReplySave(
            postId: postId,
            replyId: reply.id,
            replyText: reply.text,
            replyHandle: reply.handle,
            replyAuthorId: reply.authorId,
            currentlySaved: currentlySaved
        ) { newSaved in
            mutateReplyInTree(replyId: replyId) { r in
                r.isSaved = newSaved
            }
        }
    }

    private func repostReplyAt(replyId: String) {
        guard let reply = findReplyInTree(replyId: replyId) else { return }
        let currentCount = reply.repostCount
        // Toggle: undo the reply-repost if already reposted.
        if reply.isReposted {
            PostInteractionManager.unrepostReply(
                replyId: reply.id,
                currentCount: currentCount
            ) { result in
                mutateReplyInTree(replyId: replyId) { r in
                    r.isReposted = result.isReposted
                    r.repostCount = result.newCount
                }
            }
            return
        }
        PostInteractionManager.repostReply(
            postId: postId,
            replyId: reply.id,
            replyText: reply.text,
            replyAuthorId: reply.authorId,
            replyAuthorHandle: reply.handle,
            currentCount: currentCount
        ) { result in
            mutateReplyInTree(replyId: replyId) { r in
                r.isReposted = result.isReposted
                r.repostCount = result.newCount
            }
        }
    }

    // Stamps isLiked / isSaved / isReposted on each reply in `replies` by
    // intersecting the snapshot's reply ids with the user's reverse indices
    // (likedReplies, savedReplies) and the user's own reply-reposts
    // (looked up via deterministic doc ids: posts/{uid}_replyrepost_{replyId}).
    //
    // Firestore's `whereField(FieldPath.documentID(), in:)` is capped at 30
    // values per query, so reply ids get batched into 30-sized chunks.
    // Repost existence uses N parallel getDocument calls rather than a
    // single composite query — keeps us from needing a new index on
    // (authorId, originalReplyId) for this v1.0 path. If repost-state
    // checks ever become a hot path, swap to the indexed query.
    // Internal (not private) so ReplyDetailView can reuse the same stamping to
    // seed its children's like/save/repost state — otherwise children render as
    // un-interacted and a like on an already-liked reply is a server no-op that
    // leaves the optimistic +1 stuck.
    static func stampReplyInteractionState(
        replies: [ThreadedReply],
        replyIds: [String],
        uid: String,
        db: Firestore
    ) async -> [ThreadedReply] {
        let chunks = stride(from: 0, to: replyIds.count, by: 30).map {
            Array(replyIds[$0..<min($0 + 30, replyIds.count)])
        }

        var likedSet: Set<String> = []
        var savedSet: Set<String> = []
        var repostedSet: Set<String> = []

        for chunk in chunks {
            async let likedSnap = try? db.collection("users").document(uid)
                .collection("likedReplies")
                .whereField(FieldPath.documentID(), in: chunk)
                .getDocumentsAsync()
            async let savedSnap = try? db.collection("users").document(uid)
                .collection("savedReplies")
                .whereField(FieldPath.documentID(), in: chunk)
                .getDocumentsAsync()
            if let docs = await likedSnap?.documents {
                for d in docs { likedSet.insert(d.documentID) }
            }
            if let docs = await savedSnap?.documents {
                for d in docs { savedSet.insert(d.documentID) }
            }
        }

        await withTaskGroup(of: String?.self) { group in
            for replyId in replyIds {
                group.addTask {
                    let docId = "\(uid)_replyrepost_\(replyId)"
                    let snap = try? await db.collection("posts").document(docId).getDocumentAsync()
                    return (snap?.exists == true) ? replyId : nil
                }
            }
            for await result in group {
                if let id = result { repostedSet.insert(id) }
            }
        }

        return replies.map { reply in
            var r = reply
            r.isLiked = likedSet.contains(reply.id)
            r.isSaved = savedSet.contains(reply.id)
            r.isReposted = repostedSet.contains(reply.id)
            return r
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
        // E-1 (2026-06-16): a `visiting` (in-progress / "gray") set breaks cycles
        // in the parentReplyId graph. `resolved` alone is inserted only AFTER the
        // child loop, so a cyclic tree (A.parent=B, B.parent=A — only reachable
        // via a tampered client writing arbitrary parentReplyId) would recurse
        // forever → stack-overflow crash. Bailing when a node is already on the
        // current DFS stack guarantees termination on any graph.
        var visiting = Set<String>()

        func visit(_ id: String) {
            guard !resolved.contains(id), !visiting.contains(id) else { return }
            visiting.insert(id)
            for childId in childIdsMap[id] ?? [] { visit(childId) }
            visiting.remove(id)
            resolved.insert(id)
            order.append(id)
        }

        for id in rootIds { visit(id) }
        for reply in flat where !resolved.contains(reply.id) { visit(reply.id) }
        for id in order {
            guard lookup[id] != nil else { continue }
            let kids = (childIdsMap[id] ?? []).compactMap { lookup[$0] }
            lookup[id]?.children = kids
        }
        return rootIds.compactMap { lookup[$0] }
    }

    func lookupAuthorId() {
        guard !postId.isEmpty else { isAuthorIdLoading = false; return }
        Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, error in
            Task { @MainActor in
                // Distinguish "post doc has no authorId" (real data issue —
                // clear the field) from "fetch failed" (network, permission —
                // preserve whatever we had). The old code treated both the
                // same, which made the "view author's profile" button vanish
                // on any transient Firestore error.
                if let error = error {
                    print("⚠️ lookupAuthorId failed: \(error)")
                    isAuthorIdLoading = false
                    return
                }
                guard let data = snapshot?.data() else {
                    // Post doc doesn't exist — clear the field; the view's
                    // liveListener will dismiss the screen shortly.
                    authorUserId = ""
                    isAuthorIdLoading = false
                    return
                }
                authorUserId = data["authorId"] as? String ?? ""
                // M-2 (2026-07-19 audit): the post whose author we just resolved
                // may be one the viewer already blocked (opened by id with no
                // author passed in). Leave rather than render blocked content.
                if !authorUserId.isEmpty, BlockedUsersCache.shared.isBlocked(authorUserId) { dismiss(); return }
                isAuthorIdLoading = false
            }
        }
    }

    func sendReply() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 2 else { return }
        guard Auth.auth().currentUser?.uid != nil, !postId.isEmpty else { return }
        if UserHandleCache.shared.isRestricted { return }
        if BlockedUsersCache.shared.isBlocked(authorUserId) { return }
        if let last = RateLimiter.shared.lastReplyTime, Date().timeIntervalSince(last) < 5 { return }
        if let violation = contentViolation(in: trimmed) {
            replyContentWarningMessage = contentViolationMessage(for: violation)
            showReplyContentWarning = true
            return
        }
        if containsNameOrIdentifyingInfo(trimmed) { pendingReplyText = trimmed; showReplyNameWarning = true; return }
        if let level = crisisCheckLevelRespectingSetting(for: trimmed) {
            replyGentleCheckTopic = crisisTopic(for: trimmed)
            pendingReplyText = trimmed
            replyGentleCheckLevel = level
            showReplyGentleCheck = true
            return
        }
        postReplyNow(trimmed)
    }

    func postReplyNow(_ trimmed: String) {
        guard let uid = Auth.auth().currentUser?.uid, !postId.isEmpty else { return }
        // Offline guard: batch.commit() never resolves offline, so the catch
        // rollback (which releases lastReplyTime and restores the text) never
        // runs. The user sees the send haptic, nothing appears, and after the 5s
        // window a retry queues a SECOND write — both land on reconnect as
        // duplicate replies. Fail fast with feedback instead.
        guard NetworkMonitor.shared.isConnected else {
            replyPostError = "you're offline — try again when you're connected"
            return
        }
        RateLimiter.shared.lastReplyTime = Date()
        HapticManager.play(.send)
        let db = Firestore.firestore()
        let currentReplyText = trimmed
        Task { @MainActor in
            // Resolve handle. The reply-create rule pins authorHandle to the
            // user-doc handle, so a cold UserHandleCache ("anonymous" sentinel)
            // would be REJECTED with a generic error during the launch / just-
            // signed-in window. Fall back to the user doc — same fix the repost
            // and ReplyDetailView paths use.
            var replyHandle = UserHandleCache.shared.handle
            if replyHandle == "anonymous" {
                if let snap = try? await db.collection("users").document(uid).getDocumentAsync(),
                   let h = snap.data()?["handle"] as? String, !h.isEmpty {
                    replyHandle = h
                }
            }
            var replyData: [String: Any] = [
                "authorId": uid, "authorHandle": replyHandle, "text": currentReplyText,
                "likeCount": 0, "createdAt": FieldValue.serverTimestamp(),
                "parentPostText": postText, "parentPostHandle": handle,
                // T-2 (2026-06-11): start the reply hidden, mirroring posts, so a
                // reply that validateReply will hold for PII is never third-party-
                // readable in the pre-trigger window. validateReply promotes a
                // clean reply to "live". The author sees it immediately via the
                // optimistic insert below.
                "moderationStatus": "pending_validation"
            ]
            if let parentId = replyingToId { replyData["parentReplyId"] = parentId }
            if let gifUrl = replyGifUrl { replyData["gifUrl"] = gifUrl }

            let postRef = db.collection("posts").document(postId)
            let replyRef = postRef.collection("replies").document()
            let batch = db.batch()
            batch.setData(replyData, forDocument: replyRef)
            // replyCount increment handled by Cloud Function on reply doc create.

            do {
                try await batch.commit()
                Telemetry.replyCreated(
                    parentIsOwn: self.authorUserId == uid,
                    hasGif: self.replyGifUrl != nil
                )
                if !self.authorUserId.isEmpty, self.authorUserId != uid {
                    self.sendNotification(toUserId: self.authorUserId, type: "reply", message: currentReplyText)
                }
                let newReply = ThreadedReply(
                    id: replyRef.documentID, handle: replyHandle, text: currentReplyText,
                    likes: 0, time: "now", createdAt: Date(), authorId: uid,
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
                if !self.postId.isEmpty {
                    // N-4: clear the protected reply draft on successful send.
                    DraftStore.remove(
                        forKey: UserDefaultsKeys.replyDraft(postId: self.postId)
                    )
                }
                self.replyGifUrl = nil
                self.replyFocused = false
                self.replyingToId = nil
                self.replyingToHandle = nil
            } catch {
                Telemetry.recordError(error, context: "PostDetailView.postReply")
                self.replyText = currentReplyText
                // The send failed — nothing was posted, so release the 5s
                // rate-limit window the attempt consumed (line 1397) so the
                // user can retry immediately instead of being blocked.
                RateLimiter.shared.lastReplyTime = nil
                // Tell the user (same alert the offline guard uses) — a
                // silent failure looked like the reply just vanished.
                self.replyPostError = "couldn't send — try again."
            }
        }
    }

    func sendNotification(toUserId: String, type: String, message: String) {
        PostInteractionManager.sendNotification(postId: postId, toUserId: toUserId, type: type, message: message)
    }

    // startConversation removed when DMs were cut.

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
    @State private var editGentleCheckTopic: CrisisTopic? = nil
    @State private var isSaving = false
    @State private var saveError = ""

    // isLetter can lag behind truth: unseeded call sites (profile, notifications,
    // top, push deep-link) resolve it via an async fetch, and a failed fetch
    // leaves it false forever. Floor the limit at the existing text length so an
    // edit begun before it resolves can never truncate a 2000-char letter to 500
    // — the server rule enforces the real cap on save regardless.
    private var charLimit: Int { max(isLetter ? 2000 : 500, currentText.utf16.count) }

    var body: some View {
        ZStack {
            LateNightTheme.feedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(ToskaFont.sans(13)).foregroundColor(Color.toskaMidGray)
                    }
                    Spacer()
                    Text("edit post").font(ToskaFont.sans(13, weight: .medium)).foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Button { attemptSave() } label: {
                        HStack(spacing: 4) {
                            if isSaving { ProgressView().scaleEffect(0.7).tint(.white) }
                            else { Image(systemName: "checkmark").font(ToskaFont.sans(11)); Text("save").font(ToskaFont.sans(13, weight: .semibold)) }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(editText.isEmpty || editText == currentText ? Color.toskaDivider : Color.toskaBlue)
                        .cornerRadius(16)
                    }
                    .disabled(editText.isEmpty || editText == currentText || isSaving)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

                if !saveError.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        Text(saveError).font(ToskaFont.sans(11))
                    }
                    .foregroundColor(Color.toskaErrorRed)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.toskaErrorRed.opacity(0.05))
                }

                ZStack(alignment: .topLeading) {
                    if editText.isEmpty {
                        Text("say what you never said...")
                            .font(ToskaFont.serif(16)).foregroundColor(ToskaColor.text3)
                            .padding(.horizontal, 16).padding(.top, 16)
                    }
                    TextEditor(text: $editText)
                    .autocorrectionDisabled(false)  // autocorrect ON for content (2026-07-21)
                        .font(ToskaFont.serif(16)).foregroundColor(ToskaColor.text)
                        .lineSpacing(4).scrollContentBackground(.hidden)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .onChange(of: editText) { _, newValue in
                            // Truncate on UTF-16 length (the metric the Firestore
                            // rule's size() check uses) so heavy-emoji edits don't
                            // silently fail the server-side write. Mirrors ComposeView.
                            if newValue.utf16.count > charLimit {
                                var utf16Count = 0
                                var endIdx = newValue.startIndex
                                for ch in newValue {
                                    let chUtf16 = String(ch).utf16.count
                                    if utf16Count + chUtf16 > charLimit { break }
                                    utf16Count += chUtf16
                                    endIdx = newValue.index(after: endIdx)
                                }
                                editText = String(newValue[..<endIdx])
                            }
                            if !saveError.isEmpty { saveError = "" }
                        }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil").font(.system(size: 10))
                            Text("editing your post").font(ToskaFont.sans(11))
                        }
                        .foregroundColor(Color.toskaAccentGold)
                        Spacer()
                        ZStack {
                            Circle().stroke(Color.toskaBorderLight, lineWidth: 1.5).frame(width: 22, height: 22)
                            Circle()
                                .trim(from: 0, to: CGFloat(editText.utf16.count) / CGFloat(charLimit))
                                .stroke(editText.utf16.count > charLimit - 50 ? Color.toskaErrorRed : Color.toskaBlue,
                                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 22, height: 22).rotationEffect(.degrees(-90))
                        }
                        Text("\(charLimit - editText.utf16.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(editText.utf16.count > charLimit - 50 ? Color.toskaErrorRed : Color.toskaTimestamp)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .background(LateNightTheme.feedBackground)
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
            editGentleCheckTopic = crisisTopic(for: editText)
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
                    topic: editGentleCheckTopic,
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
        // Restriction gates EDIT exactly like create (the update rule now
        // enforces this server-side) — without it a restricted account
        // publishes new text by editing an old live post.
        guard !UserHandleCache.shared.isRestricted else {
            saveError = "your account is under review. you cannot edit right now."
            return
        }
        // Offline guard: updateData's completion never fires offline, so the
        // spinner hung forever while the queued edit silently landed on
        // reconnect — after the user had concluded it failed. Same fail-fast
        // as postReplyNow.
        guard NetworkMonitor.shared.isConnected else {
            saveError = "you're offline — try again when you're connected."
            return
        }
        isSaving = true
        saveError = ""
        Firestore.firestore().collection("posts").document(postId).updateData([
            "text": editText, "editedAt": FieldValue.serverTimestamp()
        ]) { error in
            Task { @MainActor in
                isSaving = false
                if let error = error { saveError = "couldn't save — \(error.localizedDescription)" }
                else {
                    currentText = editText
                    // Feed / Top / profile Posts tab are one-shot fetches and
                    // kept showing the pre-edit text until manual refresh
                    // (2026-07-29 sync sweep).
                    NotificationCenter.default.post(name: .postEdited, object: nil,
                                                    userInfo: ["postId": postId])
                    dismiss()
                }
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
    /// Per-reply interaction handlers — closures that PostDetailView
    /// wires to PostInteractionManager + replyList mutation. Optional so
    /// other call sites (none today, but kept future-proof) can render the
    /// row read-only by passing nil. When nil, the action row is hidden.
    var onToggleLike: (() -> Void)? = nil
    var onToggleSave: (() -> Void)? = nil
    var onRepost: (() -> Void)? = nil
    /// Mirror of onReply but bound to the chat-bubble icon (vs the
    /// swipe-from-right gesture). Same action, different affordance —
    /// the icon is a tap target for users who don't discover the swipe.
    var onComment: (() -> Void)? = nil
    /// Opens a ShareCardView sheet for the reply text — same external-
    /// share path posts use. Implemented in PostDetailView, which owns
    /// the sheet presentation state.
    var onShare: (() -> Void)? = nil
    /// Edit / delete the viewer's OWN reply. Surfaced in the context menu
    /// only when the reply's authorId matches the signed-in user.
    /// PostDetailView owns the edit sheet + delete confirmation.
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var showReportSheet = false
    @State private var showBlockConfirm = false

    var body: some View {
        // The row body — wrapped below in a NavigationLink so the whole row
        // is tappable to open the reply as its own page (ReplyDetailView).
        // Inner Buttons + Menu use .plain styling so they intercept their own
        // taps and don't trigger the link.
        rowContent
    }

    private var rowContent: some View {
        NavigationLink {
            ReplyDetailView(postId: postId, reply: item.reply)
                .navigationBarHidden(true)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if item.depth > 0 {
                        Rectangle().fill(Color.toskaBlue.opacity(0.2))
                            .frame(width: 2, height: 16).cornerRadius(1).padding(.trailing, 4)
                    }
                    Text(item.reply.handle)
                        .font(ToskaFont.sans(13, weight: .medium))
                        .foregroundColor(ToskaColor.text2)
                    Text("·")
                        .font(ToskaFont.sans(11))
                        .foregroundColor(Color.toskaDivider)
                    Text(item.reply.time)
                        .font(ToskaFont.sans(12))
                        .foregroundColor(Color.toskaTimestamp)
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
                                .font(.system(size: 13))
                                .foregroundColor(Color.toskaTimestamp)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("More options for \(item.reply.handle)'s reply")
                    }
                }
                Text(item.reply.text)
                    .toskaReplyBody()
                    .foregroundColor(ToskaColor.text)
                // M-1: the author's own held reply shows an "under review"
                // banner (it's hidden from everyone else). The interaction row
                // is suppressed below since a hidden reply can't be engaged with.
                if item.reply.isPending {
                    PendingReviewBanner(reasonLabel: item.reply.pendingReasonLabel)
                        .padding(.top, 4)
                }
                // Interactive action row — like, save, repost. Matches the
                // affordances on a top-level post. Each icon is hidden when
                // the corresponding handler isn't wired (defensive — current
                // PostDetailView always wires all three; older call sites or
                // future read-only renders pass nil). Hides the repost icon
                // on the user's own reply since reposting yourself doesn't
                // make sense and the PostInteractionManager.repostReply guard
                // would reject it anyway.
                if !item.reply.isPending && (onToggleLike != nil || onToggleSave != nil || onRepost != nil || onComment != nil || onShare != nil) {
                    // Layout mirrors FeedPostRow's action bar (FeedView.swift:790)
                    // exactly: comment / repost / bookmark / share clustered on the
                    // left at 28pt spacing, then Spacer, then heart on the right
                    // with its count. Same icon sizes (14pt for the count-bearing
                    // icons, 16pt for plain ones), same active colors (5a9e8f
                    // for repost-active, c47a8a for like-active). The only thing
                    // that differs from a top-level post is the absence of a
                    // "context-menu on long-press" — kept tight to the canonical
                    // tap-row for reply density.
                    HStack(spacing: 24) {
                        if let onComment = onComment {
                            Button {
                                onComment()
                            } label: {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color.toskaDivider)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reply to this reply")
                        }
                        if let onRepost = onRepost,
                           item.reply.authorId != Auth.auth().currentUser?.uid {
                            Button {
                                onRepost()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.2.squarepath")
                                        .font(.system(size: 17, weight: .regular))
                                    if item.reply.repostCount > 0 {
                                        Text("\(item.reply.repostCount)")
                                            .font(ToskaFont.sans(12))
                                    }
                                }
                                .foregroundColor(item.reply.isReposted ? Color.toskaMovingOnGreen : Color.toskaDivider)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.reply.isReposted ? "Undo repost" : "Repost reply")
                        }
                        if let onToggleSave = onToggleSave {
                            Button {
                                onToggleSave()
                            } label: {
                                Image(systemName: item.reply.isSaved ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(item.reply.isSaved ? Color.toskaBlue : Color.toskaDivider)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.reply.isSaved ? "Unsave reply" : "Save reply")
                        }
                        if let onShare = onShare {
                            Button {
                                onShare()
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color.toskaDivider)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Share reply")
                        }
                        Spacer()
                        if let onToggleLike = onToggleLike {
                            Button {
                                onToggleLike()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: item.reply.isLiked ? "heart.fill" : "heart")
                                        .font(.system(size: 17, weight: .regular))
                                    if item.reply.likes > 0 {
                                        Text("\(item.reply.likes)")
                                            .font(ToskaFont.sans(12))
                                    }
                                }
                                .foregroundColor(item.reply.isLiked ? Color.toskaWhisperPink : Color.toskaDivider)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.reply.isLiked ? "Unlike reply" : "Like reply")
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.leading, 18 + indent)
            .padding(.trailing, 16)
            .padding(.vertical, 16)
            .background(LateNightTheme.feedBackground)
            .contentShape(Rectangle())
        } // end NavigationLink label
        // .plain so the row content is rendered as-is instead of in the
        // default tinted NavigationLink style.
        .buttonStyle(.plain)
        // N-3 (2026-06-09 re-review): a held (pending_review) reply must not
        // drill into ReplyDetailView — that page filters its children to
        // moderationStatus=="live" and has no pending banner, so it rendered a
        // held reply as a normal post with a working composer and like stats.
        // The row already shows the PendingReviewBanner inline; disable the
        // navigation so the held reply has no normal-post detail surface.
        // (Held replies are visible only to their own author, so this is a
        // self-consistency fix, not a third-party leak.)
        .disabled(item.reply.isPending)
        // Long-press context menu — mirror of FeedPostRow's context menu so
        // every reply gets the same like / save / repost / share / reply
        // action surface as a post does. The tap-row at the top of the
        // reply already exposes these as buttons; this is the discoverable
        // quick-access surface for users who reach for long-press.
        .contextMenu {
            if let onToggleLike = onToggleLike {
                Button { onToggleLike() } label: {
                    Label(
                        item.reply.isLiked ? "unlike" : "felt this",
                        systemImage: item.reply.isLiked ? "heart.slash" : "heart"
                    )
                }
            }
            if let onToggleSave = onToggleSave {
                Button { onToggleSave() } label: {
                    Label(
                        item.reply.isSaved ? "unsave" : "save",
                        systemImage: item.reply.isSaved ? "bookmark.slash" : "bookmark"
                    )
                }
            }
            if let onRepost = onRepost,
               item.reply.authorId != Auth.auth().currentUser?.uid,
               !item.reply.isReposted {
                Button { onRepost() } label: {
                    Label("repost", systemImage: "arrow.2.squarepath")
                }
            }
            if let onShare = onShare {
                Button { onShare() } label: {
                    Label("share", systemImage: "square.and.arrow.up")
                }
            }
            if let onComment = onComment {
                Button { onComment() } label: {
                    Label("reply", systemImage: "bubble.left")
                }
            }
            // Own reply → edit / delete. Mirrors the post author's edit/delete
            // menu and ProfileView's reply context menu, so you can manage a
            // reply right where you read it instead of only from your profile.
            if let onEdit = onEdit,
               item.reply.authorId == Auth.auth().currentUser?.uid {
                Divider()
                Button { onEdit() } label: {
                    Label("edit reply", systemImage: "pencil")
                }
                if let onDelete = onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("delete reply", systemImage: "trash")
                    }
                }
            }
            if !postId.isEmpty,
               !item.reply.authorId.isEmpty,
               item.reply.authorId != Auth.auth().currentUser?.uid {
                Divider()
                Button { showReportSheet = true } label: {
                    Label("report", systemImage: "flag")
                }
                Button(role: .destructive) { showBlockConfirm = true } label: {
                    Label("block \(item.reply.handle)", systemImage: "person.slash")
                }
            }
        }
        .navigationDestination(isPresented: $showReportSheet) {
            ReportSheet(target: .reply(
                postId: postId,
                replyId: item.reply.id,
                authorId: item.reply.authorId,
                authorHandle: item.reply.handle,
                text: item.reply.text
            ))
            .navigationBarHidden(true)
            .hidesAppTabBar()
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
            Text("you wont see their posts or replies. they wont be notified.")
        }
    }
}
