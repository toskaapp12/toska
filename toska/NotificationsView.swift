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
    // Shown when a follow notification's actor no longer exists, instead of
    // navigating to an empty/broken profile.
    @State private var showDeletedUserAlert = false
    // Shown when the referenced post exists but the read was DENIED (e.g. it
    // was moderation-held after the notification landed). Transient network
    // errors stay silent (the post may be fine — don't claim otherwise), but
    // a permission-denied is deterministic and a silent dead tap read as a
    // broken row.
    @State private var showCantOpenAlert = false
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
    // Referenced post text per postId, for the quoted line in each row.
    @State private var postTexts: [String: String] = [:]
    // all / mentions filter (mentions == replies to you).
    @State private var notifTab = 0

    // Tab filter: "all" shows everything; "mentions" shows only replies to you.
    private var shownToday: [NotificationItem] {
        notifTab == 0 ? todayNotifs : todayNotifs.filter { $0.type == "reply" }
    }
    private var shownEarlier: [NotificationItem] {
        notifTab == 0 ? earlierNotifs : earlierNotifs.filter { $0.type == "reply" }
    }

    private func recomputeNotificationGroups() {
        // 1) Fold multiple "likes" on the SAME post into one row
        //    ("X and N others felt this"). Notifications arrive newest-first, so
        //    the first like seen per post is the actor we show; the rest bump the
        //    count. Every other type stays its own row.
        var grouped: [NotificationItem] = []
        var likeIndexByPost: [String: Int] = [:]
        var actorsByPost: [String: Set<String>] = [:]   // dedupe the same actor across re-likes
        for n in notifications {
            if n.type == "like", !n.postId.isEmpty, let idx = likeIndexByPost[n.postId] {
                // Count a folded like only for a NEW actor (so an unlike→re-like by
                // the same person doesn't read as two people), and keep the group
                // unread if ANY of its members is unread.
                let actor = n.fromUserId
                if actor.isEmpty || actorsByPost[n.postId]?.contains(actor) != true {
                    grouped[idx].othersCount += 1
                    if !actor.isEmpty { actorsByPost[n.postId, default: []].insert(actor) }
                }
                if n.isUnread { grouped[idx].isUnread = true }
            } else {
                if n.type == "like", !n.postId.isEmpty {
                    likeIndexByPost[n.postId] = grouped.count
                    if !n.fromUserId.isEmpty { actorsByPost[n.postId] = [n.fromUserId] }
                }
                grouped.append(n)
            }
        }
        // 2) Attach the referenced post text (quote) from the per-document fetch.
        grouped = grouped.map { item in
            guard item.quote == nil, !item.postId.isEmpty, let t = postTexts[item.postId] else { return item }
            var x = item
            x.quote = String(t.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
            return x
        }
        // 3) Bucket into new / earlier.
        let calendar = Calendar.current
        todayNotifs = grouped.filter { calendar.isDateInToday($0.createdAt) }
        earlierNotifs = grouped.filter { !calendar.isDateInToday($0.createdAt) }
    }

    // Fetch the text of every post referenced by a notification (per-document,
    // NOT an `in` batch — one moderation-held post would fail the whole batch) so
    // each row can quote the moment it's about. Results cached in postTexts, then
    // groups recompute once all have returned to show the quotes.
    private func fetchPostTexts() {
        let ids = Array(Set(notifications.map { $0.postId }.filter { !$0.isEmpty && postTexts[$0] == nil }))
        guard !ids.isEmpty else { return }
        let db = Firestore.firestore()
        // Per-document fetch, NOT a whereField(documentID in [...]) batch: a single
        // `in` query fails ENTIRELY (permission-denied) if any one of the ids is a
        // moderation-held post by another author, which would silently drop quotes
        // for the whole batch. Individual gets let a denied/missing post fail on its
        // own without poisoning the rest. Recompute once when all have returned.
        let group = DispatchGroup()
        for id in ids {
            group.enter()
            db.collection("posts").document(id).getDocument { snap, _ in
                Task { @MainActor in
                    if let t = snap?.data()?["text"] as? String { postTexts[id] = t }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { recomputeNotificationGroups() }
    }

    var body: some View {
        ZStack {
            LateNightTheme.feedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Root tab — no back chevron. "mark read" appears only when there's
                // something unread to clear.
                ToskaHeader(title: "notifications", onBack: nil) {
                    if notifications.contains(where: { $0.isUnread }) {
                        Button { markAllRemainingAsRead() } label: {
                            Text("mark read")
                                .font(ToskaFont.sans(14, weight: .semibold))
                                .foregroundColor(ToskaColor.accent)
                        }
                    }
                }

                // all / mentions tabs (mentions = replies to you)
                HStack(spacing: 24) {
                    ForEach(0..<2, id: \.self) { i in
                        Button { notifTab = i } label: {
                            VStack(spacing: 6) {
                                Text(["all", "mentions"][i])
                                    .font(ToskaFont.sans(16, weight: notifTab == i ? .semibold : .regular))
                                    .foregroundColor(notifTab == i ? ToskaColor.text : ToskaColor.text3)
                                Rectangle()
                                    .fill(notifTab == i ? ToskaColor.accent : Color.clear)
                                    .frame(width: 22, height: 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .background(LateNightTheme.feedBackground)

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
                        } else if shownToday.isEmpty && shownEarlier.isEmpty {
                            // Based on the FILTERED arrays, not `notifications` — so
                            // the "mentions" tab with no replies shows an empty state
                            // instead of a blank list.
                            VStack(spacing: 16) {
                                Spacer()
                                Image(systemName: notifTab == 1 ? "bubble.left" : "heart.text.square")
                                    .font(.system(size: 30, weight: .ultraLight))
                                    .foregroundColor(Color.toskaBlue.opacity(0.4))
                                    .padding(.bottom, 4)
                                Text(notifTab == 1 ? "\"no replies yet.\"" : "\"someone will feel\nwhat you wrote.\"")
                                    .font(ToskaFont.serifItalic(20))
                                    // text2, not toskaTimestamp (#c0c0c0 ≈ 1.6:1 on
                                    // white) — the empty-state headline must be readable.
                                    .foregroundColor(ToskaColor.text2)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(4)
                                Text(notifTab == 1 ? "when someone replies to your moments, it lands here" : timeAwareNotifEmpty())
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
                                if !shownToday.isEmpty {
                                    Section {
                                        ForEach(shownToday) { notif in
                                            notifRow(notif)
                                        }
                                    } header: {
                                        sectionHeader("new")
                                    }
                                }

                                if !shownEarlier.isEmpty {
                                    Section {
                                        ForEach(shownEarlier) { notif in
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
        // LOW-P3-4 (2026-07-20 launch audit): re-filter on an in-session block,
        // mirroring the feed (FeedView.swift:465). The snapshot map filters
        // blocked actors, but a block landing while sitting on this tab left the
        // blocked user's existing rows on screen until the next delta. Prune in
        // place now so they drop immediately.
        .onReceive(NotificationCenter.default.publisher(for: .userBlocked)) { notif in
            if let userId = notif.userInfo?["userId"] as? String, !userId.isEmpty {
                notifications.removeAll { $0.fromUserId == userId }
            }
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
        .alert("theyre gone", isPresented: $showDeletedUserAlert) {
            Button("ok") {}
        } message: {
            Text("this person isnt here anymore.")
        }
        .alert("cant open this", isPresented: $showCantOpenAlert) {
            Button("ok") {}
        } message: {
            Text("this post isnt available right now.")
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
                HStack(alignment: .top, spacing: 12) {
                    // Type icon in a soft tinted circle (one color per class).
                    ZStack {
                        Circle()
                            .fill(iconColor(for: notif.type).opacity(0.14))
                            .frame(width: 38, height: 38)
                        Image(systemName: notif.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(iconColor(for: notif.type))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        // Title: bold actor + (optional "and N others") + action phrase.
                        (Text(notif.fromHandle.isEmpty ? "someone" : notif.fromHandle)
                            .font(ToskaFont.sans(14, weight: .semibold))
                            .foregroundColor(ToskaColor.text)
                         + Text(notif.othersCount > 0 ? " and \(notif.othersCount) \(notif.othersCount == 1 ? "other" : "others") " : " ")
                            .font(ToskaFont.sans(14))
                            .foregroundColor(ToskaColor.text)
                         + Text(notif.actionText)
                            .font(ToskaFont.sans(14))
                            .foregroundColor(ToskaColor.text2))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        // The post this notification is about — quoted, serif, with
                        // a left rule (filled in after the batch post-text fetch).
                        if let q = notif.quote, !q.isEmpty {
                            Text("\u{201C}\(q)\u{201D}")
                                .font(ToskaFont.serifItalic(14))
                                .foregroundColor(ToskaColor.text3)
                                .lineSpacing(3)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(ToskaColor.divider).frame(width: 2)
                                }
                        }

                        // Reply body in its own soft bubble.
                        if let r = notif.replyText, !r.isEmpty {
                            Text(r)
                                .font(ToskaFont.serif(14))
                                .foregroundColor(ToskaColor.text)
                                .lineSpacing(3)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ToskaColor.input, in: RoundedRectangle(cornerRadius: 10))
                        }

                        Text(notif.time)
                            .font(ToskaFont.sans(12))
                            .foregroundColor(notif.isUnread ? ToskaColor.accent : ToskaColor.time)
                    }

                    Spacer(minLength: 8)

                    if notif.isUnread {
                        Circle().fill(ToskaColor.accent).frame(width: 7, height: 7).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 17)
                .background(notif.isUnread ? ToskaColor.accent.opacity(0.045) : Color.clear)
                .overlay(Rectangle().fill(ToskaColor.divider.opacity(0.5)).frame(height: 0.5), alignment: .bottom)
                .contentShape(Rectangle())
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
            Firestore.firestore().collection("users").document(notif.fromUserId).getDocument { snapshot, error in
                Task { @MainActor in
                    // Only navigate if the actor still exists. On a genuine
                    // missing doc (deleted account), show a "they're gone" note
                    // instead of pushing an empty/broken profile. A transient
                    // error is left alone (don't claim they're gone on a blip).
                    if error != nil { return }
                    guard let data = snapshot?.data() else {
                        showDeletedUserAlert = true
                        return
                    }
                    let handle = data["handle"] as? String ?? "anonymous"
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
                    // permission-denied is deterministic (post moderation-held
                    // or otherwise unreadable) — tell the user instead of a
                    // silent dead tap. Transient errors stay silent, and we
                    // never prune notifications on either: the post may still
                    // exist on the server.
                    let nsError = error as NSError
                    if nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 7 {
                        showCantOpenAlert = true
                    }
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
        markAllRemainingAsRead(pinnedUid: uid)
    }

    private func markAllRemainingAsRead(pinnedUid: String) {
        // Pin the uid across the recursive sweep. The recursive continuation is
        // a bare Task that the sign-out / onDisappear cancels don't reach, so if
        // an account switch lands mid-sweep on a shared device, re-reading
        // currentUser would mark the NEW user's notifications read (a
        // cross-account write). Bail if the signed-in user changed.
        guard Auth.auth().currentUser?.uid == pinnedUid else { return }
        let db = Firestore.firestore()
        // 400 keeps each batch under Firestore's 500-op limit. If a full page
        // comes back there may be more unread, so we keep sweeping until the
        // backlog is cleared — otherwise a user with >500 unread keeps the
        // badge visually zeroed (onAppear) while server isRead stays false.
        db.collection("users").document(pinnedUid).collection("notifications")
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
                    if docs.count >= 400 { Task { @MainActor in self.markAllRemainingAsRead(pinnedUid: pinnedUid) } }
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

                        // Actor (bold) + action phrase shown separately in the row.
                        var actor = fromHandle
                        let action: String
                        var replyBody: String? = nil
                        switch type {
                        case "like":   action = "felt this"
                        case "reply":
                            action = "replied to your moment"
                            let preview = message.trimmingCharacters(in: .whitespacesAndNewlines)
                            replyBody = preview.isEmpty ? nil : preview
                        case "follow":   action = "followed you"
                        case "repost":   action = "shared your words"
                        case "save":     action = "saved your post"
                        case "milestone":
                            actor = "your words"
                            action = message.isEmpty ? "reached people who needed them"
                                : message.replacingOccurrences(of: "your words ", with: "")
                        default: action = message
                        }
                        let displayText = "\(actor) \(action)"

                        return NotificationItem(
                            id: doc.documentID,
                            icon: iconName(for: type),
                            displayText: displayText,
                            type: type,
                            time: FeedView.timeAgoString(from: createdAt),
                            isUnread: !isRead,
                            createdAt: createdAt,
                            postId: postId,
                            fromUserId: fromUserId,
                            fromHandle: actor,
                            actionText: action,
                            othersCount: 0,
                            quote: nil,
                            replyText: replyBody
                        )
                    }

                    // Pull the referenced post texts so each row can quote the moment.
                    fetchPostTexts()

                    // markAllRemainingAsRead sweeps every unread notification up to 500
                    // in one batch. We only want to schedule it once per visit — the
                    // listener fires on every snapshot delta, and we don't want to
                    // bombard Firestore with a batch commit each time a new like
                    // lands while the user is sitting on the tab. Reset happens in
                    // startListeningToNotifications() on next appear.
                    if !markReadScheduledThisVisit {
                        markReadScheduledThisVisit = true
                        markAsReadTask?.cancel()
                        // Pin the uid at SCHEDULE time (not fire time). If we let
                        // the no-arg markAllRemainingAsRead() re-read currentUser
                        // when the 3s timer fires, an account switch in that window
                        // would pin to the NEW user and mark THEIR notifications
                        // read (authed as them, so the rules allow it — no server
                        // backstop). Pinning to the scheduling user means a fire
                        // under a different account targets the original user's
                        // docs and is rejected. Matches MainTabView's sweep.
                        let pinnedUid = Auth.auth().currentUser?.uid
                        markAsReadTask = Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            guard !Task.isCancelled, let pinnedUid else { return }
                            markAllRemainingAsRead(pinnedUid: pinnedUid)
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
                            // Accent fill, not toskaBlue — the muted slate grey
                            // reads as a DISABLED button on a primary CTA.
                            .background(ToskaColor.accent)
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
