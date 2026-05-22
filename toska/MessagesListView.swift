import SwiftUI
import FirebaseAuth
@preconcurrency import FirebaseFirestore

@MainActor
struct MessagesListView: View {
    @Environment(\.dismiss) var dismiss
    @State private var conversations: [ConversationItem] = []
    @State private var isLoading = true
    @State private var selectedConversation: ConversationItem? = nil
    @State private var listener: ListenerRegistration? = nil
    
    var body: some View {
            // Presented as a navigation push from ProfileView (not a sheet),
            // so this view does NOT wrap itself in a NavigationStack — the
            // outer stack handles the push, and `dismiss()` on the back
            // chevron pops back to the profile. Wrapping in our own
            // NavigationStack here would create a nested stack and the
            // selectedConversation push would land inside the inner one,
            // making the swipe-back gesture inconsistent.
            ZStack {
            LateNightTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                ToskaHeader(title: "messages", onBack: { dismiss() })

                if isLoading {
                    SkeletonFeed(kind: .conversation, count: 4)
                    Spacer()
                } else if conversations.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 30, weight: .ultraLight))
                            .foregroundColor(Color.toskaBlue.opacity(0.4))
                            .padding(.bottom, 2)
                        Text("no messages yet")
                                                                            .font(.system(size: 14, weight: .medium))
                                                                            .foregroundColor(Color.toskaTextLight)
                        Text("sometimes the hardest part is saying the first thing.")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(Color.toskaDivider)
                                                    .multilineTextAlignment(.center)
                                                    .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(conversations) { convo in
                                Button {
                                    selectedConversation = convo
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle()
                                                .fill(Color.toskaBlue.opacity(0.12))
                                                .frame(width: 44, height: 44)
                                            Text(String(convo.otherHandle.replacingOccurrences(of: "anonymous_", with: "").prefix(1)).uppercased())
                                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                                .foregroundColor(Color.toskaBlue)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(convo.otherHandle)
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundColor(Color.toskaBlue)
                                                Spacer()
                                                Text(convo.timeAgo)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color.toskaTimestamp)
                                            }

                                            HStack(spacing: 6) {
                                                Text(convo.lastMessage)
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Color(hex: "888888"))
                                                    .lineLimit(1)

                                                Spacer()

                                                if convo.isSealed {
                                                    Text("sealed")
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundColor(Color.toskaTimestamp)
                                                        .padding(.horizontal, 7)
                                                        .padding(.vertical, 3)
                                                        .background(Color(hex: "dfe1e5").opacity(0.5))
                                                        .cornerRadius(6)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
            .onAppear { startListening() }
                    .onDisappear {
                        listener?.remove()
                        listener = nil
                    }
                    // Belt-and-suspenders: sign-out can happen while this view is on
                    // screen (session expiry, force-revoke, account-switch race).
                    // onDisappear isn't guaranteed to fire before the SplashView
                    // swap, so explicitly drop the listener and clear local state
                    // on sign-out — matches the pattern in NotificationsView,
                    // ConversationView, FeelingCircleView, and PostDetailView.
                    .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
                        listener?.remove()
                        listener = nil
                        conversations = []
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                        startListening()
                    }
                    // Block fired while this view is on-screen: the snapshot
                    // listener only re-derives on Firestore document changes,
                    // so a freshly-blocked user's conversation lingered in
                    // the list until the user left and came back. Strip the
                    // blocked user's row locally to match what BlockedUsersCache
                    // already filters at startListening time.
                    .onReceive(NotificationCenter.default.publisher(for: .userBlocked)) { notif in
                        if let blockedUid = notif.userInfo?["userId"] as? String {
                            conversations.removeAll { $0.otherUserId == blockedUid }
                        }
                    }
                    .navigationDestination(item: $selectedConversation) { convo in
                        ConversationView(
                            conversationId: convo.id,
                            otherHandle: convo.otherHandle,
                            otherUserId: convo.otherUserId
                        )
                        .navigationBarHidden(true)
                    }
                    .navigationBarHidden(true)
                    .hidesAppTabBar()
    }

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoading = false
            return
        }
        
        // Fetch blocked users first, then listen
        startConversationListener(uid: uid)
    }
    
    func startConversationListener(uid: String) {
        listener?.remove()
        let capturedUid = uid
        listener = Firestore.firestore().collection("conversations")
            .whereField("participants", arrayContains: uid)
            .order(by: "lastMessageAt", descending: true)
            .limit(to: 30)
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard Auth.auth().currentUser?.uid == capturedUid else { return }
                    if let error = error {
                        // Without surfacing this, a permission-denied or
                        // network drop leaves the user staring at the
                        // spinner forever. At minimum log it; the empty-
                        // state UI is shown when documents come back nil
                        // so the user isn't completely stuck.
                        print("⚠️ MessagesListView listener error: \(error)")
                        Telemetry.recordError(error, context: "MessagesListView.listener")
                        isLoading = false
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        isLoading = false
                        return
                    }
                    
                    conversations = documents.compactMap { doc -> ConversationItem? in
                        let data = doc.data()
                        let participants = data["participants"] as? [String] ?? []
                        let handles = data["participantHandles"] as? [String: String] ?? [:]
                        let messageCounts = data["messageCount"] as? [String: Int] ?? [:]
                        let lastMessageAt = (data["lastMessageAt"] as? Timestamp)?.dateValue() ?? Date()
                        
                        guard let otherUid = participants.first(where: { $0 != uid }) else { return nil }
                        if BlockedUsersCache.shared.isBlocked(otherUid) { return nil }
                        let otherHandle = handles[otherUid] ?? "anonymous"
                        let myCount = messageCounts[uid] ?? 0
                        let theirCount = messageCounts[otherUid] ?? 0
                        let messageLimit = ToskaConstants.messageLimit
                                let isSealed = myCount >= messageLimit && theirCount >= messageLimit
                        
                        return ConversationItem(
                            id: doc.documentID,
                            otherUserId: otherUid,
                            otherHandle: otherHandle,
                            lastMessage: data["lastMessage"] as? String ?? "",
                            lastMessageAt: lastMessageAt,
                            timeAgo: FeedView.timeAgoString(from: lastMessageAt),
                            isSealed: isSealed,
                            myMessageCount: myCount,
                            theirMessageCount: theirCount
                        )
                    }
                    
                    isLoading = false
                }
            }
    }
}

struct ConversationItem: Identifiable, Hashable {
    let id: String
    let otherUserId: String
    let otherHandle: String
    let lastMessage: String
    let lastMessageAt: Date
    let timeAgo: String
    let isSealed: Bool
    let myMessageCount: Int
    let theirMessageCount: Int
}
