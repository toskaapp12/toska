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
    // FIX: only the feed tab is rendered on cold start. Other tabs are added
    // to this set the first time the user selects them, then kept alive so
    // scroll position and state are preserved on subsequent visits.
    @State private var loadedTabs: Set<Tab> = [.feed]

    var body: some View {
        ZStack(alignment: .bottom) {
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

            // MARK: - Tab bar
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
                            .foregroundColor(selectedTab == .feed ? LateNightTheme.handleText : Color(hex: "c0c0c0"))
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
                                .fill(Color(hex: "9198a8"))
                                .frame(width: 40, height: 40)
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    .accessibilityLabel("New post")
                    .frame(maxWidth: .infinity)

                    // Notifications with badge
                    Button {
                        HapticManager.play(.tabSwitch)
                        NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .notifications }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: selectedTab == .notifications ? "bell.fill" : "bell")
                                .font(.system(size: 20, weight: selectedTab == .notifications ? .medium : .light))
                                .foregroundColor(selectedTab == .notifications ? LateNightTheme.handleText : Color(hex: "c0c0c0"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if unreadCount > 0 {
                                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: "c47a8a"))
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: 2)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Notifications\(unreadCount > 0 ? ", \(unreadCount) unread" : "")")

                    tabIcon(icon: "person", activeIcon: "person.fill", tab: .profile)
                }
                .frame(height: 50)
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
                .background(
                    Group {
                        if LateNightTheme.isLateNight {
                            LateNightTheme.cardBackground
                        } else {
                            Color.clear.background(.ultraThinMaterial)
                        }
                    }
                )
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .fullScreenCover(isPresented: $showCompose) {
            ComposeView()
        }
        // MARK: - Push notification deep link
        .fullScreenCover(item: Binding(
            get: { pushPostId.map { PostSelection(id: $0) } },
            set: { if $0 == nil { pushPostId = nil } }
        )) { selection in
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
        .onReceive(NotificationCenter.default.publisher(for: .openPostFromPush)) { notification in
            guard let postId = notification.userInfo?["postId"] as? String, !postId.isEmpty else { return }
            selectedTab = .feed
            pushPostId = postId
        }
        .onAppear {
            print("⚡️ MainTabView appeared")
            startUnreadListener()
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
            NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            Image(systemName: selectedTab == tab ? activeIcon : icon)
                .font(.system(size: 20, weight: selectedTab == tab ? .medium : .light))
                .foregroundColor(selectedTab == tab ? LateNightTheme.handleText : Color(hex: "c0c0c0"))
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

    func startUnreadListener() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        unreadListener?.remove()
        unreadListener = nil
        fetchUnreadCount(uid: uid)
        unreadPollTask?.cancel()
        unreadPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }
                fetchUnreadCount(uid: uid)
            }
        }
    }

    func fetchUnreadCount(uid: String) {
        Firestore.firestore()
            .collection("users").document(uid).collection("notifications")
            .whereField("isRead", isEqualTo: false)
            .count.getAggregation(source: .server) { [uid] snapshot, _ in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == uid else { return }
                    self.unreadCount = Int(truncating: snapshot?.count ?? 0)
                }
            }
    }
}
