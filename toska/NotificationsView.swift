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
    @State private var selectedPostId: String? = nil
    @State private var selectedPostData: PostDetailData? = nil
    @State private var showPost = false
    @State private var selectedFollowUser: NotifFollowUser? = nil
    @State private var lastFetchTime: Date? = nil
    @State private var showDeletedPostAlert = false
    @State private var markAsReadTask: Task<Void, Never>? = nil
    @State private var selectedConversation: (id: String, handle: String, userId: String)? = nil
    @State private var showConversation = false

    var todayNotifs: [NotificationItem] {
        notifications.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    var earlierNotifs: [NotificationItem] {
        notifications.filter { !Calendar.current.isDateInToday($0.createdAt) }
    }

    var body: some View {
        ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Header
                HStack {
                    Text("notifications")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(Color(hex: "1a1a1a"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)

                // MARK: - Content
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color(hex: "9198a8"))
                    Spacer()
                } else if notifications.isEmpty {
                    Spacer()
                                        VStack(spacing: 12) {
                                            Text("\"someone will feel\nwhat you wrote.\"")
                                                .font(.custom("Georgia-Italic", size: 20))
                                                .foregroundColor(Color(hex: "c0c0c0"))
                                                .multilineTextAlignment(.center)
                                                .lineSpacing(4)
                                            Text(timeAwareNotifEmpty())
                                                .font(.system(size: 11))
                                                .foregroundColor(Color(hex: "d0d0d0"))
                                                .multilineTextAlignment(.center)
                                        }
                                        .padding(.horizontal, 48)
                                        Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
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
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: "cccccc"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }

                            Color.clear.frame(height: 80)
                        }
                    }
                    .refreshable {
                                            await withCheckedContinuation { continuation in
                                                loadNotifications(onComplete: { continuation.resume() })
                                            }
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
            if let last = lastFetchTime, Date().timeIntervalSince(last) < 30 { return }
            lastFetchTime = Date()
            loadNotifications()
        }
        .onDisappear {
            markAsReadTask?.cancel()
            markAsReadTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DismissAllSheets"))) { _ in
                    showConversation = false
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
        .sheet(isPresented: $showConversation) {
            if let convo = selectedConversation {
                ConversationView(
                    conversationId: convo.id,
                    otherHandle: convo.handle,
                    otherUserId: convo.userId
                )
            }
        }
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
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Color(hex: "1a1a1a"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "f0f1f3"))
    }

    // MARK: - Row

    func notifRow(_ notif: NotificationItem) -> some View {
            Button { handleNotifTap(notif) } label: {
                HStack(spacing: 0) {
                    // Type icon — small, subtle
                    Image(systemName: notif.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(iconColor(for: notif.type).opacity(0.7))
                        .frame(width: 28)
                    
                    // Text
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notif.displayText)
                            .font(.system(size: 13, weight: notif.isUnread ? .medium : .regular))
                            .foregroundColor(Color(hex: "2a2a2a"))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(notif.time)
                            .font(.system(size: 11))
                            .foregroundColor(notif.isUnread ? Color(hex: "9198a8") : Color(hex: "c0c0c0"))
                    }
                    
                    Spacer()
                    
                    if notif.isUnread {
                        Circle()
                            .fill(Color(hex: "9198a8"))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(notif.isUnread ? Color(hex: "9198a8").opacity(0.04) : Color.clear)
                .overlay(
                    Rectangle()
                        .fill(Color(hex: "dfe1e5").opacity(0.5))
                        .frame(height: 0.5),
                    alignment: .bottom
                )
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
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 22 || hour < 5 {
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
        } else if notif.type == "message" && !notif.fromUserId.isEmpty {
            openConversation(fromUserId: notif.fromUserId)
        } else {
            openPost(postId: notif.postId)
        }
    }

    func openConversation(fromUserId: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let convoId = [uid, fromUserId].sorted().joined(separator: "_")
        db.collection("conversations").document(convoId).getDocument { snapshot, _ in
            Task { @MainActor in
                guard let data = snapshot?.data() else { return }
                let handles = data["participantHandles"] as? [String: String] ?? [:]
                let otherHandle = handles[fromUserId] ?? "anonymous"
                selectedConversation = (id: convoId, handle: otherHandle, userId: fromUserId)
                showConversation = true
            }
        }
    }

    func openPost(postId: String) {
        guard !postId.isEmpty else { return }
        Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, _ in
            Task { @MainActor in
                guard let data = snapshot?.data() else {
                    if let uid = Auth.auth().currentUser?.uid {
                        Firestore.firestore().collection("users").document(uid).collection("notifications")
                            .whereField("postId", isEqualTo: postId)
                            .getDocuments { notifSnap, _ in
                                for doc in notifSnap?.documents ?? [] { doc.reference.delete() }
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
        case "like": return Color(hex: "c47a8a")
        case "reply": return Color(hex: "9198a8")
        case "follow": return Color(hex: "6ba58e")
        case "repost": return Color(hex: "5a9e8f")
        case "save": return Color(hex: "c49a6c")
        case "milestone": return Color(hex: "c9a97a")
        case "message": return Color(hex: "9198a8")
        default: return Color(hex: "cccccc")
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
        case "message": return "envelope.fill"
        default: return "bell.fill"
        }
    }

    func markAsRead(documentIds: [String]) {
        guard !documentIds.isEmpty, let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let chunks = stride(from: 0, to: documentIds.count, by: 500).map {
            Array(documentIds[$0..<min($0 + 500, documentIds.count)])
        }
        for chunk in chunks {
            let batch = db.batch()
            for docId in chunk {
                let ref = db.collection("users").document(uid).collection("notifications").document(docId)
                batch.updateData(["isRead": true], forDocument: ref)
            }
            batch.commit { error in
                if let error = error {
                    print("⚠️ markAsRead batch failed: \(error)")
                }
            }
        }
    }

    func markAllRemainingAsRead() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        db.collection("users").document(uid).collection("notifications")
            .whereField("isRead", isEqualTo: false)
            .limit(to: 500)
            .getDocuments { snapshot, _ in
                guard let docs = snapshot?.documents, !docs.isEmpty else { return }
                let batch = db.batch()
                for doc in docs { batch.updateData(["isRead": true], forDocument: doc.reference) }
                batch.commit { error in
                    if let error = error {
                        print("⚠️ markAllRemainingAsRead batch failed: \(error)")
                    }
                }
            }
    }

    func loadNotifications(onComplete: (() -> Void)? = nil) {
            guard let uid = Auth.auth().currentUser?.uid else { isLoading = false; onComplete?(); return }
        let db = Firestore.firestore()
        db.collection("users").document(uid).collection("notifications")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 50)
                    .getDocuments { snapshot, error in
                        Task { @MainActor in
                            if let error = error {
                                                            print("⚠️ loadNotifications error: \(error)")
                                                            isLoading = false
                                                            onComplete?()
                                                            return
                                                        }
                                                        guard let documents = snapshot?.documents else { isLoading = false; onComplete?(); return }

                            // Filter out notifications from blocked users
                            let visibleDocuments = documents.filter { doc in
                                let fromUserId = doc.data()["fromUserId"] as? String ?? ""
                                return fromUserId.isEmpty || !BlockedUsersCache.shared.isBlocked(fromUserId)
                            }

                            notifications = visibleDocuments.map { doc in
                        let docId = doc.documentID
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
                        case "message": displayText = "\(fromHandle) sent you a message"
                        default: displayText = message
                        }

                        return NotificationItem(
                            id: docId,
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

                            let unreadIds = visibleDocuments
                                                    .filter { ($0.data()["isRead"] as? Bool ?? false) == false }
                                                    .map { $0.documentID }
                    markAsReadTask?.cancel()
                    markAsReadTask = Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        markAsRead(documentIds: unreadIds)
                        markAllRemainingAsRead()
                    }

                            isLoading = false
                                                onComplete?()
                                            }
                                        }
                                }
}
