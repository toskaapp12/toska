import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

enum Tab {
    case feed, top, notifications, profile
}

@MainActor
struct MainTabView: View {
    @State private var selectedTab: Tab = .feed
    @State private var showCompose = false
    @State private var unreadCount = 0
    @StateObject private var feedVM = FeedViewModel()
    @State private var pendingUnreadTask: Task<Void, Never>? = nil
    @State private var unreadListener: ListenerRegistration? = nil
    @State private var unreadPollTask: Task<Void, Never>? = nil
    @State private var pushPostId: String? = nil
    // Push deep-link surfaces. Each is set when the user taps a notification
    // of the matching type; the corresponding fullScreenCover/sheet opens
    // the right destination. We use Identifiable wrappers so SwiftUI can
    // distinguish the value-bound presentation modifiers.
    // pushConversation state removed when DMs were cut.
    @State private var pushProfileUser: UserSelection? = nil
    // FIX: only the feed tab is rendered on cold start. Other tabs are added
    // to this set the first time the user selects them, then kept alive so
    // scroll position and state are preserved on subsequent visits.
    @State private var loadedTabs: Set<Tab> = [.feed]
    // Undo-block toast state. Populated when .userBlocked fires; cleared
    // either when the user taps "undo" or after 4 seconds elapsed. The
    // BlockedUserToast inner struct identifies a specific block event so
    // a fresh block during an active toast properly replaces the prior
    // one (rather than queueing or stacking).
    @State private var pendingUndoBlock: BlockedUserToast? = nil
    @State private var undoToastDismissTask: Task<Void, Never>? = nil
    struct BlockedUserToast: Identifiable, Equatable {
        let id = UUID()
        let userId: String
        let handle: String
    }
    // Set true by any pushed drill-in view via .hidesAppTabBar(); the tab
    // bar slides off-screen so reply composers, action rows, and other
    // bottom-anchored UI inside pushed detail views aren't covered.
    @State private var tabBarHidden = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Continuous page-color base so the area behind/below the floating
            // tab pill is the SAME surface as the feed — no distinct lighter
            // panel/seam showing behind the bar. The pill floats over one
            // uniform background instead of a separate bottom panel.
            ToskaColor.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                OfflineBannerView()

                ZStack {
                    // Feed — always loaded, never torn down.
                    NavigationStack {
                        FeedView(vm: feedVM)
                            .navigationBarHidden(true)
                    }
                    .opacity(selectedTab == .feed ? 1 : 0)
                    .allowsHitTesting(selectedTab == .feed)

                    // Top — created on first visit, kept alive after that.
                    if loadedTabs.contains(.top) {
                        NavigationStack {
                            TopView()
                                .navigationBarHidden(true)
                        }
                        .opacity(selectedTab == .top ? 1 : 0)
                        .allowsHitTesting(selectedTab == .top)
                    }

                    // Notifications — created on first visit, kept alive after that.
                    if loadedTabs.contains(.notifications) {
                        NavigationStack {
                            NotificationsView()
                                .navigationBarHidden(true)
                        }
                        .opacity(selectedTab == .notifications ? 1 : 0)
                        .allowsHitTesting(selectedTab == .notifications)
                    }

                    // Profile — created on first visit, kept alive after that.
                    if loadedTabs.contains(.profile) {
                        NavigationStack {
                            ProfileView()
                                .navigationBarHidden(true)
                        }
                        .opacity(selectedTab == .profile ? 1 : 0)
                        .allowsHitTesting(selectedTab == .profile)
                    }
                }
            }
            // Reserve space at the bottom so the floating tab pill (in the
            // ZStack overlay below) never covers content. ~92pt = pill height
            // (60) + bottom margin (16) + breathing room (16). Pushing the
            // content up by this amount means a pushed view's bottom-anchored
            // UI — PostDetailView's reply composer, the conversation
            // composer, etc. — sits above the pill instead of behind it.
            .padding(.bottom, 92)

            // MARK: - Tab bar
            // Always visible (the hide preference is intentionally ignored,
            // see .onPreferenceChange below). Sits in the ZStack overlay so
            // it stays at the screen bottom; the inner content VStack above
            // is padded to leave room.
            if !tabBarHidden {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        HapticManager.play(.tabSwitch)
                        NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
                        if selectedTab == .feed {
                            NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
                        }
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .feed }
                    } label: {
                        Image(systemName: selectedTab == .feed ? "house.fill" : "house")
                            .font(.system(size: 20, weight: selectedTab == .feed ? .medium : .light))
                            .foregroundColor(selectedTab == .feed ? LateNightTheme.handleText : LateNightTheme.timeText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityLabel("Home")

                    tabIcon(icon: "chart.line.uptrend.xyaxis", activeIcon: "chart.line.uptrend.xyaxis", tab: .top)

                    // Compose button
                    Button {
                        HapticManager.play(.tabSwitch)
                        showCompose = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(ToskaColor.accent)
                                .frame(width: 50, height: 50)
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                    }
                    .accessibilityLabel("New post")
                    .frame(maxWidth: .infinity)

                    // Notifications with badge
                    Button {
                        HapticManager.play(.tabSwitch)
                        // Active-tab re-tap pops the notifications nav stack
                        // back to the inbox root (standard iOS pattern from
                        // Twitter/Instagram). If we're on a different tab,
                        // dismissAllSheets + tab switch behaves as before.
                        if selectedTab == .notifications {
                            NotificationCenter.default.post(name: .popNotificationsTabToRoot, object: nil)
                        } else {
                            NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
                            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .notifications }
                        }
                    } label: {
                        Image(systemName: selectedTab == .notifications ? "bell.fill" : "bell")
                            .font(.system(size: 20, weight: selectedTab == .notifications ? .medium : .light))
                            .foregroundColor(selectedTab == .notifications ? LateNightTheme.handleText : LateNightTheme.timeText)
                            .overlay(alignment: .topTrailing) {
                                if unreadCount > 0 {
                                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(ToskaColor.badge)
                                        .clipShape(Capsule())
                                        // Hug the bell's top-right corner. Overlay
                                        // attaches to the bell's bounding box (vs.
                                        // the prior ZStack that anchored to the
                                        // expanded tab-slot frame, which floated
                                        // the badge way up and out to the right).
                                        .offset(x: 8, y: -6)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityLabel("Notifications\(unreadCount > 0 ? ", \(unreadCount) unread" : "")")

                    tabIcon(icon: "person", activeIcon: "person.fill", tab: .profile)
                }
                .frame(height: 62)
                .padding(.horizontal, 14)
                // Instagram-style floating "home bar": the tab row is a rounded
                // pill lifted OFF the bottom edge — detached on the sides and
                // above the home indicator, an elevated white (card) surface with
                // a bold two-layer drop shadow — instead of a flat edge-to-edge
                // panel. The page shows behind/below it so it reads as floating.
                // MODERNIZED (2026 / iOS 26): the floating home bar is now a
                // Liquid Glass capsule — translucent and refractive, so the feed
                // scrolls visibly beneath it (the iconic iOS 26 look) instead of
                // the old opaque white pill. A thin rim-light overlay defines the
                // glass edge; the layered drop shadow keeps it floating.
                .toskaGlass(in: Capsule(), frosted: true)
                .overlay(
                    Capsule().stroke(Color.white.opacity(LateNightTheme.isLateNight ? 0.10 : 0.35), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
                .shadow(color: .black.opacity(0.16), radius: 28, x: 0, y: 14)
                // Outer margins detach the pill from the screen edges and lift it
                // above the home indicator (the enclosing ZStack ignores the
                // bottom safe area, so this padding is the manual home-indicator
                // clearance).
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            } // end if !tabBarHidden

            // Undo-block toast — overlays the tab bar with a "blocked X · undo"
            // pill that auto-dismisses after 4s or on tap of "undo". The
            // 4s window matches iOS Mail's undo-send affordance: long enough
            // for a misclick recovery, short enough not to linger after the
            // user has moved on. Positioned just above the tab bar (offset)
            // via padding(.bottom) so it doesn't collide with the icons.
            if let toast = pendingUndoBlock {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text("blocked \(toast.handle)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            Task {
                                _ = await BlockedUsersCache.shared.unblock(toast.userId)
                            }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                pendingUndoBlock = nil
                            }
                            undoToastDismissTask?.cancel()
                            undoToastDismissTask = nil
                            HapticManager.play(.tabSwitch)
                        } label: {
                            Text("undo")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(hex: "f5c97a"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 88) // above the tab bar
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .onPreferenceChange(HidesAppTabBarKey.self) { _ in
            // Tab bar is intentionally always visible — drill-in views can
            // still declare `.hidesAppTabBar()`, the preference just isn't
            // honored at the bar level anymore. Keeps navigation consistent
            // so the user never loses their place. To restore per-screen
            // hiding, set `tabBarHidden = hidden` here.
            withAnimation(.easeInOut(duration: 0.22)) {
                tabBarHidden = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userBlocked)) { notif in
            // Show the undo toast on every block emitted by BlockedUsersCache.
            // userInfo carries `userId` always and `handle` when the caller
            // had it (most do — block surfaces in PostDetailView, OtherProfileView,
            // and SwipeToReplyRow all pass handle). Skip the toast if handle
            // is missing — without a name to address, the "undo" affordance
            // is confusing.
            guard let userId = notif.userInfo?["userId"] as? String,
                  let handle = notif.userInfo?["handle"] as? String,
                  !handle.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                pendingUndoBlock = BlockedUserToast(userId: userId, handle: handle)
            }
            undoToastDismissTask?.cancel()
            undoToastDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    pendingUndoBlock = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showCompose) {
            EdgeSwipeDismissWrapper { ComposeView() }
        }
        // MARK: - Push notification deep link
        .fullScreenCover(item: Binding(
            get: { pushPostId.map { PostSelection(id: $0) } },
            set: { if $0 == nil { pushPostId = nil } }
        )) { selection in
            EdgeSwipeDismissWrapper {
                PostDetailView(
                    postId: selection.id,
                    handle: "",
                    text: "",
                    tag: nil,
                    likes: 0,
                    reposts: 0,
                    replies: 0,
                    time: ""
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPostFromPush)) { notification in
            guard let postId = notification.userInfo?["postId"] as? String, !postId.isEmpty else { return }
            PushNotificationManager.shared.pendingIntent = nil
            showCompose = false
            pushProfileUser = nil
            selectedTab = .feed
            pushPostId = postId
        }
        // DM push routing was removed when DMs were cut; a legacy 'message'
        // push from an older build simply has no handler and is ignored.
        .onReceive(NotificationCenter.default.publisher(for: .openProfileFromPush)) { notification in
            guard let userId = notification.userInfo?["userId"] as? String, !userId.isEmpty else { return }
            PushNotificationManager.shared.pendingIntent = nil
            showCompose = false
            pushPostId = nil
            pushProfileUser = UserSelection(id: userId, handle: "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openComposeFromEmptyFeed)) { _ in
            HapticManager.play(.tabSwitch)
            showCompose = true
        }
        // pushConversation cover removed when DMs were cut.
        .fullScreenCover(item: $pushProfileUser) { selection in
            EdgeSwipeDismissWrapper {
                OtherProfileView(userId: selection.id, handle: selection.handle)
            }
        }
        .onAppear {
            print("⚡️ MainTabView appeared")
            startUnreadListener()
            // Drain any push-tap intent that fired before this view's
            // NotificationCenter observers were attached (cold-launch race).
            // PushNotificationManager stashes the intent in pendingIntent;
            // we replay it here so the deep link still routes correctly.
            if let intent = PushNotificationManager.shared.pendingIntent {
                PushNotificationManager.shared.pendingIntent = nil
                switch intent.kind {
                case .post where !intent.postId.isEmpty:
                    selectedTab = .feed
                    pushPostId = intent.postId
                case .profile where !intent.userId.isEmpty:
                    pushProfileUser = UserSelection(id: intent.userId, handle: "")
                default:
                    break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDidVerify)) { _ in
            feedVM.loadInitialData()
        }
        .onDisappear {
            unreadListener?.remove()
            unreadListener = nil
            unreadPollTask?.cancel()
            unreadPollTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
            unreadListener?.remove()
            unreadListener = nil
            unreadPollTask?.cancel()
            unreadPollTask = nil
            // Tear down the feed view-model's listeners and in-flight tasks
            // on sign-out. MainTabView is held by SwiftUI for a tick after
            // the SplashView swap, and feedVM is a @StateObject that
            // outlives a quick sign-out/sign-in for a different account
            // unless we explicitly cancel here. Without this, likedListener
            // / savedListener / repostedListener would keep firing against
            // the previous uid until the next loadInitialData call (which
            // also resets state) — a race window where the new user briefly
            // sees the old user's liked/saved/repost markers.
            feedVM.cancelAllTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            pendingUnreadTask?.cancel()
            pendingUnreadTask = nil
            startUnreadListener()
        }
        .onChange(of: selectedTab) { _, newTab in
            // FIX: mark the tab as loaded the first time it is selected.
            // The ZStack conditionals above check loadedTabs before rendering,
            // so each tab view is instantiated exactly once and never torn down.
            loadedTabs.insert(newTab)

            pendingUnreadTask?.cancel()
            if newTab == .notifications && unreadCount > 0 {
                pendingUnreadTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    await markAllNotificationsRead()
                }
            }
        }
    }

    // MARK: - Tab Icon Helper

    func tabIcon(icon: String, activeIcon: String, tab: Tab) -> some View {
        Button {
            HapticManager.play(.tabSwitch)
            // Active-tab re-tap → scroll-to-top within that tab. Universal
            // iOS pattern. Feed already had a scrollFeedToTop notification
            // for its empty-state CTA; top + profile got dedicated names
            // when this pattern was generalized. Notifications has its own
            // pop-to-root path on the bell button (different button site
            // since it carries the unread badge layout).
            if selectedTab == tab {
                switch tab {
                case .feed:    NotificationCenter.default.post(name: .scrollFeedToTop, object: nil)
                case .top:     NotificationCenter.default.post(name: .scrollTopTabToTop, object: nil)
                case .profile: NotificationCenter.default.post(name: .scrollProfileToTop, object: nil)
                case .notifications: break // handled by the bell button site, not via tabIcon
                }
            } else {
                NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
                withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            }
        } label: {
            Image(systemName: selectedTab == tab ? activeIcon : icon)
                .font(.system(size: 20, weight: selectedTab == tab ? .medium : .light))
                .foregroundColor(selectedTab == tab ? LateNightTheme.handleText : LateNightTheme.timeText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(
            tab == .feed ? "Home" :
            tab == .top ? "Trending" :
            tab == .profile ? "Profile" : "Notifications"
        )
    }

    // MARK: - Notifications

    func markAllNotificationsRead() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let baseQuery = db.collection("users").document(uid).collection("notifications")
            .whereField("isRead", isEqualTo: false)

        var hasMore = true
        while hasMore && !Task.isCancelled {
            guard let snapshot = try? await baseQuery.limit(to: 100).getDocumentsAsync() else { break }
            guard !snapshot.documents.isEmpty else { break }

            let batch = db.batch()
            for doc in snapshot.documents {
                batch.updateData(["isRead": true], forDocument: doc.reference)
            }
            do {
                try await batch.commit()
            } catch {
                print("⚠️ markAllNotificationsRead batch failed: \(error)")
                break
            }

            hasMore = snapshot.documents.count >= 100
        }
    }

    /// Replaced the 30-second polling loop with a snapshot listener. Firestore
    /// listeners are push-based: the badge updates the moment a notification is
    /// created or marked read, with zero polling cost in between. Firestore
    /// SDK auto-pauses listeners when the app is backgrounded and resyncs on
    /// foreground (MainTabView's willEnterForeground handler also calls this
    /// to defensively re-attach).
    ///
    /// The query limits to 100 docs because the badge caps at "99+" anyway —
    /// no need to pull the full unread set for users with thousands.
    func startUnreadListener() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        unreadListener?.remove()
        unreadListener = nil
        unreadPollTask?.cancel()
        unreadPollTask = nil

        unreadListener = Firestore.firestore()
            .collection("users").document(uid).collection("notifications")
            .whereField("isRead", isEqualTo: false)
            .limit(to: 100)
            .addSnapshotListener { [uid] snapshot, _ in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    self.unreadCount = snapshot?.documents.count ?? 0
                }
            }
    }
}
