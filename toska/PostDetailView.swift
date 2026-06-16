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
    @State private var isLetter = false

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
                            postText = text
                            likeCount = likes
                            localRepostCount = reposts
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
                dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
                          dismiss()
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
            .navigationDestination(isPresented: $showEditSheet) {
                EditPostView(postId: postId, isLetter: isLetter, currentText: $postText, editText: $editText)
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
            }
            .navigationDestination(isPresented: $showShareCard) {
                ShareCardView(text: postText, handle: handle, feltCount: likeCount, tag: tag)
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
            LateNightTheme.background.ignoresSafeArea()
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
                            .padding(.horizontal, 18)
                            .padding(.top, 14)

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
                                        .padding(.leading, 18)
                                }
                            }
                            .transition(.opacity)
                        } else if replyList.isEmpty {
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
                                                    .font(.system(size: 11, weight: .medium))
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
                                        onShare: { shareReply = item.reply },
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

            HStack(spacing: 10) {
                TextField("say something gently…", text: $replyText)
                    .font(.system(size: 14))
                    .focused($replyFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(ToskaColor.input)
                    .clipShape(Capsule())
                    .onChange(of: replyText) { _, newValue in
                        if newValue.count > 500 { replyText = String(newValue.prefix(500)) }
                        // Persist reply draft per post so a kill mid-typing
                        // doesn't lose words. Cleared on successful send.
                        // N-4: protected DraftStore instead of UserDefaults.
                        if !postId.isEmpty {
                            DraftStore.set(
                                replyText,
                                forKey: UserDefaultsKeys.replyDraft(postId: postId)
                            )
                        }
                    }
                Button { sendReply() } label: {
                    ZStack {
                        Circle()
                            .fill((replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyGifUrl == nil) ? ToskaColor.input : ToskaColor.accent)
                            .frame(width: 40, height: 40)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor((replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyGifUrl == nil) ? ToskaColor.text3 : .white)
                    }
                }
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyGifUrl == nil)
            }
            .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
        .background(
            LateNightTheme.cardBackground.ignoresSafeArea(edges: .bottom)
                .overlay(Rectangle().fill(ToskaColor.divider).frame(height: 0.5), alignment: .top)
        )
           }

    // MARK: - Post Header Section

    var postHeaderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if !isOwnPost && !authorUserId.isEmpty { showOtherProfile = true }
                } label: {
                    // De-emphasized handle (quiet gray, not accent) so the post
                    // text leads — matches the feed.
                    Text(handle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(ToskaColor.text2)
                }
                if isOwnPost {
                    Text("· you")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ToskaColor.text3)
                }
                if let tag = tag {
                    Text("·").font(.system(size: 9)).foregroundColor(Color.toskaDivider)
                    // Softer filled chip (Capsule, medium weight, 0.16 fill) —
                    // matches the feed tag chip vocabulary.
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(tagColor(for: tag))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(tagColor(for: tag).opacity(0.16))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(time)
                    .font(.system(size: 12.5))
                    .foregroundColor(ToskaColor.time)
            }
            .padding(.bottom, 10)

            Text(postText)
                .toskaPostDetailBody()
                .foregroundColor(ToskaColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            // Attached GIF, if the post has one. Read from Firestore by the
            // live listener (data["gifUrl"]) — PostDetailView previously never
            // rendered the post's GIF, so opening a GIF post from the feed
            // showed only the text. StableGifPreview (shared from ComposeView)
            // sidesteps SwiftUI's AsyncImage cancellation issue inside views
            // that recompute frequently.
            if let gifUrl = postGifUrl, !gifUrl.isEmpty {
                StableGifPreview(urlString: gifUrl)
                    .padding(.bottom, 14)
            }

            HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Text(formatFull(likeCount))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(likePulse ? Color.toskaBlue : Color.toskaTextDark)
                                    .scaleEffect(likePulse ? 1.15 : 1.0)
                                    .animation(reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.3, dampingFraction: 0.5), value: likePulse)
                                Text("felt this")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(likePulse ? Color.toskaBlue : Color.toskaTextLight)
                            }
                            statLabel(count: replyList.isEmpty ? replies : replyList.count, label: "replies")
                            Spacer()
                        }
                        .padding(.bottom, 10)

            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

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

                           // Share — opens ShareCardView (the same path as the
                           // feed row's share button). Previously absent from
                           // the post detail action row; users had to back out
                           // to the feed to share a post.
                           Button { showShareCard = true } label: {
                               Image(systemName: "square.and.arrow.up")
                                   .font(.system(size: 15, weight: .light))
                                   .foregroundColor(Color.toskaTextLight)
                           }
                           .accessibilityLabel("Share post")
                           .frame(maxWidth: .infinity)
                       }
                       .padding(.vertical, 8)
            Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
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
        let flat = byId.values.sorted { $0.createdAt < $1.createdAt }

        print("ℹ️ fetchReplies recombine for post \(postId): \(rawLiveReplies.count) live + \(rawHeldReplies.count) held → \(flat.count)")
        withAnimation(.easeInOut(duration: 0.2)) {
            replyList = buildThreadedReplies(from: flat)
            hasLoadedReplies = true
        }
        if let uid = Auth.auth().currentUser?.uid, !flat.isEmpty {
            let replyIds = flat.map { $0.id }
            let db = Firestore.firestore()
            let stamped = await Self.stampReplyInteractionState(
                replies: flat, replyIds: replyIds, uid: uid, db: db
            )
            replyList = buildThreadedReplies(from: stamped)
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
            currentlySaved: currentlySaved
        ) { newSaved in
            mutateReplyInTree(replyId: replyId) { r in
                r.isSaved = newSaved
            }
        }
    }

    private func repostReplyAt(replyId: String) {
        guard let reply = findReplyInTree(replyId: replyId) else { return }
        if reply.isReposted { return } // idempotent — already reposted
        let currentCount = reply.repostCount
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
    private static func stampReplyInteractionState(
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
    @State private var isSaving = false
    @State private var saveError = ""

    private var charLimit: Int { isLetter ? 2000 : 500 }

    var body: some View {
        ZStack {
            LateNightTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("cancel").font(.system(size: 13)).foregroundColor(Color.toskaMidGray)
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

                Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)

                if !saveError.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        Text(saveError).font(.system(size: 11))
                    }
                    .foregroundColor(Color.toskaErrorRed)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.toskaErrorRed.opacity(0.05))
                }

                ZStack(alignment: .topLeading) {
                    if editText.isEmpty {
                        Text("say what you never said...")
                            .font(ToskaFont.serif(16)).foregroundColor(ToskaColor.text3)
                            .padding(.horizontal, 18).padding(.top, 16)
                    }
                    TextEditor(text: $editText)
                        .font(ToskaFont.serif(16)).foregroundColor(ToskaColor.text)
                        .lineSpacing(4).scrollContentBackground(.hidden)
                        .padding(.horizontal, 14).padding(.top, 8)
                        .onChange(of: editText) { _, newValue in
                            if newValue.count > charLimit { editText = String(newValue.prefix(charLimit)) }
                            if !saveError.isEmpty { saveError = "" }
                        }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    Rectangle().fill(Color.toskaBorderLight).frame(height: 0.5)
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil").font(.system(size: 10))
                            Text("editing your post").font(.system(size: 10))
                        }
                        .foregroundColor(Color.toskaAccentGold)
                        Spacer()
                        ZStack {
                            Circle().stroke(Color.toskaBorderLight, lineWidth: 1.5).frame(width: 22, height: 22)
                            Circle()
                                .trim(from: 0, to: CGFloat(editText.count) / CGFloat(charLimit))
                                .stroke(editText.count > charLimit - 50 ? Color.toskaErrorRed : Color.toskaBlue,
                                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 22, height: 22).rotationEffect(.degrees(-90))
                        }
                        Text("\(charLimit - editText.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(editText.count > charLimit - 50 ? Color.toskaErrorRed : Color.toskaTimestamp)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if item.depth > 0 {
                        Rectangle().fill(Color.toskaBlue.opacity(0.2))
                            .frame(width: 2, height: 16).cornerRadius(1).padding(.trailing, 4)
                    }
                    Text(item.reply.handle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(ToskaColor.text2)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(Color.toskaDivider)
                    Text(item.reply.time)
                        .font(.system(size: 12))
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
                                .padding(.horizontal, 6)
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
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.2.squarepath")
                                        .font(.system(size: 17, weight: .regular))
                                    if item.reply.repostCount > 0 {
                                        Text("\(item.reply.repostCount)")
                                            .font(.system(size: 12))
                                    }
                                }
                                .foregroundColor(item.reply.isReposted ? Color.toskaMovingOnGreen : Color.toskaDivider)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.reply.isReposted ? "Already reposted" : "Repost reply")
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
                                HStack(spacing: 5) {
                                    Image(systemName: item.reply.isLiked ? "heart.fill" : "heart")
                                        .font(.system(size: 17, weight: .regular))
                                    if item.reply.likes > 0 {
                                        Text("\(item.reply.likes)")
                                            .font(.system(size: 12))
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
            .padding(.trailing, 18)
            .padding(.vertical, 14)
            .background(LateNightTheme.background)
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
