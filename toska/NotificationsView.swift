import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

private struct NotifFollowUser: Identifiable, Hashable {
    let id: String
    let handle: String
}

@MainActor
struct NotificationsView: View {
    @State private var notifications: [NotificationItem] = []
    @State private var isLoading = true
    // Push primer state. We use AppStorage so the primer is shown at most
    // once across launches — after the user accepts or declines, we never
    // bother them again from this surface. The system prompt fires only
    // after they tap "yes" on the primer, giving Apple's permission alert
    // some context instead of appearing cold.
    @AppStorage(UserDefaultsKeys.pushPrimerShown) private var pushPrimerShown = false
    @State private var showPushPrimer = false
    @State private var selectedPostId: String? = nil
    @State private var selectedPostData: PostDetailData? = nil
    @State private var showPost = false
    @State private var selectedFollowUser: NotifFollowUser? = nil
    @State private var lastFetchTime: Date? = nil
    @State private var showDeletedPostAlert = false
    @State private var markAsReadTask: Task<Void, Never>? = nil
    // Real-time listener for the notification feed. Replaces the earlier
    // one-shot loadNotifications/pull-to-refresh model so likes, replies,
    // follows, and messages land in the UI as the Cloud Function writes
    // them — no user action required.
    @State private var notificationsListener: ListenerRegistration? = nil
    // H2: surface a load failure instead of showing the empty state on error.
    @State private var notificationsLoadFailed = false
    // Tracks whether the mark-as-read sweep has already been scheduled for
    // this appear. The listener fires on every snapshot delta; we only want
    // to mark-read once per visit, not on every keystroke of someone else
    // liking a post.
    @State private var markReadScheduledThisVisit = false

    // Cached splits — recomputed only when `notifications` changes (see
    // .onChange below) instead of on every body render. Saves a pair of
    // 50-item filters per redraw, which adds up while scrolling.
    @State private var todayNotifs: [NotificationItem] = []
    @State private var earlierNotifs: [NotificationItem] = []

    private func recomputeNotificationGroups() {
        let calendar = Calendar.current
        var today: [NotificationItem] = []
        var earlier: [NotificationItem] = []
        for notif in notifications {
            if calendar.isDateInToday(notif.createdAt) {
                today.append(notif)
            } else {
                earlier.append(notif)
            }
        }
        todayNotifs = today
        earlierNotifs = earlier
    }

    var body: some View {
        ZStack {
            LateNightTheme.feedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Root tab — no back chevron.
                ToskaHeader(title: "notifications")

                // MARK: - Content
                //
                // Single ScrollView wraps all three branches so pull-to-refresh
                // works regardless of state — previously .refreshable was only
                // on the populated branch, so an empty notifications inbox had
                // nothing to pull. GeometryReader gives the inner content a
                // viewport-height min so the empty/loading states stay centered
                // and there's still enough vertical room to overscroll.
                GeometryReader { geo in
                    ScrollView(showsIndicators: false) {
                        if isLoading {
                            VStack {
                                SkeletonFeed(kind: .notification, count: 5)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        } else if notificationsLoadFailed && notifications.isEmpty {
                            VStack {
                                ToskaErrorBanner("couldn't load notifications — check your connection") {
                                    notificationsLoadFailed = false
                                    isLoading = true
                                    startListeningToNotifications()
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        } else if notifications.isEmpty {
                            VStack(spacing: 16) {
                                Spacer()
                                Image(systemName: "heart.text.square")
                                    .font(.system(size: 30, weight: .ultraLight))
                                    .foregroundColor(Color.toskaBlue.opacity(0.4))
                                    .padding(.bottom, 4)
                                Text("\"someone will feel\nwhat you wrote.\"")
                                    .font(ToskaFont.serifItalic(20))
                                    .foregroundColor(Color.toskaTimestamp)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(4)
                                Text(timeAwareNotifEmpty())
                                    .font(ToskaFont.sans(11))
                                    .foregroundColor(Color.toskaDivider)
                                    .multilineTextAlignment(.center)
                                Spacer()
                            }
                            .padding(.horizontal, 48)
                            // Span full width so the centered text is actually
                            // centered. ScrollView content defaults to leading
                            // alignment; without maxWidth: .infinity the VStack
                            // hugged its widest line and sat on the left.
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        } else {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                if !todayNotifs.isEmpty {
                                    Section {
                                        ForEach(todayNotifs) { notif in
                                            notifRow(notif)
                                        }
                                    } header: {
                                        sectionHeader("new")
                                    }
                                }

                                if !earlierNotifs.isEmpty {
                                    Section {
                                        ForEach(earlierNotifs) { notif in
                                            notifRow(notif)
                                        }
                                    } header: {
                                        sectionHeader("earlier")
                                    }
                                }

                                if notifications.count >= 50 {
                                    Text("showing your 50 most recent notifications")
                                        .font(ToskaFont.sans(11))
                                        .foregroundColor(Color.toskaPlaceholderGray)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }

                                Color.clear.frame(height: 130)
                            }
                        }
                    }
                    .refreshable {
                        // Real pull-to-refresh: force a server-side fetch so
                        // the spinner reflects an actual round-trip and recovers
                        // from any transient listener silence; then re-bucket
                        // today/earlier so a notification that was "new" earlier
                        // moves to "earlier" after midnight crosses. The live
                        // listener stays attached and applies any deltas as
                        // they arrive — re-attaching it would flicker on the
                        // transient empty snapshot between remove + re-register.
                        if let uid = Auth.auth().currentUser?.uid {
                            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                Firestore.firestore()
                                    .collection("users").document(uid).collection("notifications")
                                    .order(by: "createdAt", descending: true)
                                    .limit(to: 50)
                                    .getDocuments(source: .server) { _, _ in
                                        cont.resume()
                                    }
                            }
                        }
                        recomputeNotificationGroups()
                    }
                }
            }
        }
        .onAppear {
            if #available(iOS 16, *) {
                UNUserNotificationCenter.current().setBadgeCount(0)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            recomputeNotificationGroups()
            // First-time visit shows an in-app primer explaining why we want
            // push permission. Only after the user taps "yes, notify me" do
            // we trigger the system prompt — giving Apple's alert context.
            if !pushPrimerShown {
                showPushPrimer = true
            }
            // The listener handles its own idempotency (replaces on re-attach),
            // so the lastFetchTime debounce is no longer needed for fresh data.
            // Kept as a no-op property so any future callers compile cleanly.
            lastFetchTime = Date()
            startListeningToNotifications()
        }
        .overlay {
            if showPushPrimer {
                pushPrimerCard
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showPushPrimer)
        .onChange(of: notifications) { _, _ in
            recomputeNotificationGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Firestore's snapshot listener automatically reconnects and
            // delivers a fresh snapshot when the app returns to foreground,
            // so nothing to do here. Previously this forced a re-attach,
            // which risked flickering the list if the cache-then-server
            // sequence produced a transient empty state.
        }
        .onDisappear {
            markAsReadTask?.cancel()
            markAsReadTask = nil
            stopListeningToNotifications()
        }
        // Belt-and-suspenders: sign-out can happen while this view is on
        // screen (session expiry, force-revoke). onDisappear isn't guaranteed
        // to fire before the splash-swap, so explicitly drop the listener
        // and clear local state on sign-out.
        .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
            markAsReadTask?.cancel()
            markAsReadTask = nil
            stopListeningToNotifications()
            notifications = []
        }
        // Tap-active-bell-to-pop-to-root. MainTabView posts this when the
        // bell is tapped while .notifications is already the selected tab.
        // Reset every push / sheet binding here so the user lands back on
        // the inbox list regardless of which destination they'd opened.
        .onReceive(NotificationCenter.default.publisher(for: .popNotificationsTabToRoot)) { _ in
            showPost = false
            selectedPostId = nil
            selectedPostData = nil
            selectedFollowUser = nil
        }
        .navigationDestination(isPresented: $showPost) {
                                    if let post = selectedPostData, let postId = selectedPostId {
                                        PostDetailView(
                                            postId: postId,
                                            handle: post.handle,
                                            text: post.text,
                                            tag: post.tag,
                                            likes: post.likes,
                                            reposts: post.reposts,
                                            replies: post.replies,
                                            time: post.time,
                                            authorId: post.authorId
                                        )
                                        .navigationBarHidden(true)
                                    }
                                }
        .navigationDestination(item: $selectedFollowUser) { user in
                    OtherProfileView(userId: user.id, handle: user.handle)
                        .navigationBarHidden(true)
                }
        // Conversation destination removed when DMs were cut. Tapping a
        // legacy message notification no longer routes anywhere; the
        // notification row stays inert until the row-level handler is
        // also pruned. See notifRow for where the route is suppressed.
        .alert("post deleted", isPresented: $showDeletedPostAlert) {
            Button("ok") {}
        } message: {
            Text("this post is gone. some things dont last.")
        }
    }

    // MARK: - Section Header

    func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(ToskaFont.eyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundColor(ToskaColor.text3)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(LateNightTheme.feedBackground)
    }

    // MARK: - Row

    func notifRow(_ notif: NotificationItem) -> some View {
            Button { handleNotifTap(notif) } label: {
                HStack(spacing: 12) {
                    // Type icon — larger and inside a soft tinted circle so
                    // each notification class reads at a glance without
                    // needing to parse the copy. Mirrors the bumped icon
                    // sizing on the feed row's action bar (15pt → 17pt).
                    ZStack {
                        Circle()
                            .fill(iconColor(for: notif.type).opacity(notif.isUnread ? 0.16 : 0.11))
                            .frame(width: 34, height: 34)
                        Image(systemName: notif.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(iconColor(for: notif.type))
                    }

                    // Text
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notif.displayText)
                            .font(ToskaFont.sans(13, weight: notif.isUnread ? .medium : .regular))
                            .foregroundColor(ToskaColor.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(notif.time)
                            .font(ToskaFont.sans(12))
                            .foregroundColor(notif.isUnread ? ToskaColor.accent : ToskaColor.time)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Unread → accent left bar (per design); all rows get a hairline.
                .overlay(alignment: .leading) {
                    if notif.isUnread {
                        Rectangle()
                            .fill(ToskaColor.accent)
                            .frame(width: 2.5)
                            .padding(.vertical, 16)
                    }
                }
                .overlay(Rectangle().fill(ToskaColor.divider).frame(height: 0.5), alignment: .bottom)
            }
            .buttonStyle(.plain)
        }

    // MARK: - Helpers

    func avatarInitial(for notif: NotificationItem) -> String {
        let first = notif.displayText.components(separatedBy: " ").first ?? ""
        let cleaned = first.replacingOccurrences(of: "anonymous_", with: "")
        return String(cleaned.prefix(1)).uppercased()
    }

    func timeAwareNotifEmpty() -> String {
            // Matches timeOfDayLabel's 21:00 boundary so "tonight" is consistent
            // across every surface (prompt label, weather phrase, this empty state).
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 21 || hour < 5 {
                return "quiet tonight.\nyoure not alone though."
            } else if hour < 12 {
                return "nothing yet this morning.\nthats okay."
            } else {
                return "nothing yet.\nsay something. someone will hear it."
            }
        }

    func handleNotifTap(_ notif: NotificationItem) {
        if notif.type == "follow" && !notif.fromUserId.isEmpty {
            Firestore.firestore().collection("users").document(notif.fromUserId).getDocument { snapshot, _ in
                Task { @MainActor in
                    let handle = snapshot?.data()?["handle"] as? String ?? "anonymous"
                    selectedFollowUser = NotifFollowUser(id: notif.fromUserId, handle: handle)
                }
            }
        } else {
            // like / reply / repost / save / milestone all open the post.
            // A legacy "message" notif (DMs cut) has an empty postId, so
            // openPost() guards it to a no-op.
            openPost(postId: notif.postId)
        }
    }

    func openPost(postId: String) {
        guard !postId.isEmpty else { return }
        Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, error in
            Task { @MainActor in
                // Distinguish "post is genuinely deleted" (snapshot exists but
                // is empty / non-existent) from "the request itself failed"
                // (network drop, permission). Without this, a network error
                // wrongly tells the user the post was deleted, which it
                // wasn't — and we'd then irreversibly delete their
                // notifications referencing that post.
                if let error = error {
                    print("⚠️ openPost: getDocument failed: \(error)")
                    // Don't prune notifications on transient error — the post
                    // may still exist on the server.
                    return
                }
                guard let data = snapshot?.data() else {
                    if let uid = Auth.auth().currentUser?.uid {
                        Task {
                            let notifSnap = try? await Firestore.firestore()
                                .collection("users").document(uid).collection("notifications")
                                .whereField("postId", isEqualTo: postId)
                                .getDocumentsAsync()
                            for doc in notifSnap?.documents ?? [] {
                                try? await doc.reference.delete()
                            }
                        }
                    }
                    showDeletedPostAlert = true
                    return
                }
                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                selectedPostId = postId
                selectedPostData = PostDetailData(
                    handle: data["authorHandle"] as? String ?? "anonymous",
                    text: data["text"] as? String ?? "",
                    tag: data["tag"] as? String,
                    likes: data["likeCount"] as? Int ?? 0,
                    reposts: data["repostCount"] as? Int ?? 0,
                    replies: data["replyCount"] as? Int ?? 0,
                    time: FeedView.timeAgoString(from: createdAt),
                    authorId: data["authorId"] as? String ?? ""
                )
                showPost = true
            }
        }
    }

    func iconColor(for type: String) -> Color {
        switch type {
        case "like": return Color.toskaWhisperPink
        case "reply": return Color.toskaBlue
        case "follow": return Color.toskaFollowGreen
        case "repost": return Color.toskaMovingOnGreen
        case "save": return Color.toskaAccentTan
        case "milestone": return Color.toskaAccentGold
        default: return Color.toskaPlaceholderGray
        }
    }

    func iconName(for type: String) -> String {
        switch type {
        case "like": return "heart.fill"
        case "reply": return "bubble.left.fill"
        case "follow": return "person.badge.plus"
        case "repost": return "arrow.2.squarepath"
        case "save": return "bookmark.fill"
        case "milestone": return "star.fill"
        default: return "bell.fill"
        }
    }

    // markAsRead(documentIds:) was removed as unused — markAllRemainingAsRead
    // is the single mark-read surface and covers both the loaded-page subset
    // and any backlog up to its 500-doc cap.

    func markAllRemainingAsRead() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        // 400 keeps each batch under Firestore's 500-op limit. If a full page
        // comes back there may be more unread, so we keep sweeping until the
        // backlog is cleared — otherwise a user with >500 unread keeps the
        // badge visually zeroed (onAppear) while server isRead stays false.
        db.collection("users").document(uid).collection("notifications")
            .whereField("isRead", isEqualTo: false)
            .limit(to: 400)
            .getDocuments { snapshot, _ in
                guard let docs = snapshot?.documents, !docs.isEmpty else { return }
                let batch = db.batch()
                for doc in docs { batch.updateData(["isRead": true], forDocument: doc.reference) }
                batch.commit { error in
                    if let error = error {
                        print("⚠️ markAllRemainingAsRead batch failed: \(error)")
                        return
                    }
                    // T-9 (2026-06-11): markAllRemainingAsRead is @MainActor-
                    // isolated, but this commit completion runs on a nonisolated
                    // callback queue. Hop back to the main actor for the recursive
                    // sweep (matches the scheduled call site) — fixes the cross-
                    // actor call warning and the Swift 6 hard-error.
                    if docs.count >= 400 { Task { @MainActor in self.markAllRemainingAsRead() } }
                }
            }
    }

    /// Attach a real-time listener to the user's 50 most recent notifications.
    /// Previously we did a one-shot fetch + pull-to-refresh, which meant a new
    /// like/reply/follow didn't appear until the user pulled down. With this,
    /// likes land the moment the Cloud Function writes them.
    ///
    /// Call from onAppear. Removed in onDisappear via stopListeningToNotifications().
    /// Idempotent — calling twice replaces the existing listener.
    func startListeningToNotifications() {
        guard let uid = Auth.auth().currentUser?.uid else { isLoading = false; return }
        // Replace any existing listener (e.g. if this is called twice on
        // rapid foreground-background-foreground transitions).
        notificationsListener?.remove()
        markReadScheduledThisVisit = false

        // Capture uid so the snapshot callback can verify it still serves the
        // active user before mutating @State. Without this, a sign-out
        // immediately after this view appears can leave the listener firing
        // one more snapshot that writes the previous account's notifications
        // into the new account's UI.
        let capturedUid = uid
        let db = Firestore.firestore()
        notificationsListener = db.collection("users").document(uid).collection("notifications")
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let error = error {
                        print("⚠️ notifications listener error: \(error)")
                        isLoading = false
                        notificationsLoadFailed = true
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        isLoading = false
                        return
                    }
                    notificationsLoadFailed = false

                    // Filter out notifications from blocked users at render time.
                    let visibleDocuments = documents.filter { doc in
                        let fromUserId = doc.data()["fromUserId"] as? String ?? ""
                        return fromUserId.isEmpty || !BlockedUsersCache.shared.isBlocked(fromUserId)
                    }

                    notifications = visibleDocuments.map { doc -> NotificationItem in
                        let data = doc.data()
                        let type = data["type"] as? String ?? "like"
                        let fromHandle = data["fromHandle"] as? String ?? "anonymous"
                        let message = data["message"] as? String ?? ""
                        let isRead = data["isRead"] as? Bool ?? false
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let postId = data["postId"] as? String ?? ""
                        let fromUserId = data["fromUserId"] as? String ?? ""

                        let displayText: String
                        switch type {
                        case "like": displayText = "\(fromHandle) felt this"
                        case "reply":
                            let preview = String(message.prefix(80))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            displayText = preview.isEmpty
                                ? "\(fromHandle) replied to your post"
                                : "\(fromHandle) replied: \u{201C}\(preview)\u{201D}"
                        case "follow": displayText = "\(fromHandle) followed you"
                        case "repost": displayText = "\(fromHandle) shared your words"
                        case "save": displayText = "\(fromHandle) saved your post"
                        case "milestone": displayText = message.isEmpty ? "your words reached people" : message
                        default: displayText = message
                        }

                        return NotificationItem(
                            id: doc.documentID,
                            icon: iconName(for: type),
                            displayText: displayText,
                            type: type,
                            time: FeedView.timeAgoString(from: createdAt),
                            isUnread: !isRead,
                            createdAt: createdAt,
                            postId: postId,
                            fromUserId: fromUserId
                        )
                    }

                    // markAllRemainingAsRead sweeps every unread notification up to 500
                    // in one batch. We only want to schedule it once per visit — the
                    // listener fires on every snapshot delta, and we don't want to
                    // bombard Firestore with a batch commit each time a new like
                    // lands while the user is sitting on the tab. Reset happens in
                    // startListeningToNotifications() on next appear.
                    if !markReadScheduledThisVisit {
                        markReadScheduledThisVisit = true
                        markAsReadTask?.cancel()
                        markAsReadTask = Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            guard !Task.isCancelled else { return }
                            markAllRemainingAsRead()
                        }
                    }

                    isLoading = false
                }
            }
    }

    func stopListeningToNotifications() {
        notificationsListener?.remove()
        notificationsListener = nil
    }

    // MARK: - Push permission primer
    //
    // Shown once on first visit to the Notifications tab. Apple's system
    // permission alert is one-shot per install — if the user taps "Don't
    // Allow," we can't ever ask again from code. So we show a friendly
    // in-app screen first, and only invoke the system prompt after they
    // affirmatively want notifications. "not now" sets pushPrimerShown
    // without asking the system, leaving the door open via Settings.

    private var pushPrimerCard: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture {} // swallow taps so background stays interactable only via card

            VStack(spacing: 16) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(Color.toskaBlue)

                Text("turn on notifications?")
                    .font(ToskaFont.serifItalic(18))
                    .foregroundColor(LateNightTheme.handleText)

                Text("we'll let you know when someone feels what you wrote, replies to you, or follows you.\n\nthats it. no marketing. no daily nudges.")
                    .font(ToskaFont.sans(12))
                    .foregroundColor(LateNightTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)

                VStack(spacing: 8) {
                    Button {
                        Telemetry.pushPrimerDecision(accepted: true)
                        pushPrimerShown = true
                        showPushPrimer = false
                        // Trigger the actual system prompt only after the
                        // user has opted in here. If they tap "Don't Allow"
                        // on the system prompt we can't ask again — but at
                        // least we got the most informed signal possible.
                        PushNotificationManager.shared.requestPermission()
                    } label: {
                        Text("yes, notify me")
                            .font(ToskaFont.sans(13, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.toskaBlue)
                            .cornerRadius(12)
                    }

                    Button {
                        Telemetry.pushPrimerDecision(accepted: false)
                        pushPrimerShown = true
                        showPushPrimer = false
                    } label: {
                        Text("not now")
                            .font(ToskaFont.sans(12))
                            .foregroundColor(LateNightTheme.secondaryText)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 4)

                Text("you can change this any time in Settings → Notifications")
                    .font(ToskaFont.sans(11))
                    .foregroundColor(LateNightTheme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(ToskaSpace.xl)
            .background(LateNightTheme.cardBackground)
            .cornerRadius(16)
            .padding(.horizontal, 32)
        }
    }
}
