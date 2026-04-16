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
            NavigationStack {
            ZStack {
            Color(hex: "f0f1f3").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.toskaBlue)
                    }
                    Spacer()
                    Text("messages")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.toskaTextDark)
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14))
                        .foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)
                
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.toskaBlue)
                    Spacer()
                } else if conversations.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(Color.toskaDivider)
                        Text("no messages yet")
                                                                            .font(.system(size: 14, weight: .medium))
                                                                            .foregroundColor(Color.toskaTextLight)
                        Text("sometimes the hardest part is saying the first thing.")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(Color(hex: "cccccc"))
                                                    .multilineTextAlignment(.center)
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
                                                .fill(Color.toskaBlue.opacity(0.1))
                                                .frame(width: 40, height: 40)
                                            Text(String(convo.otherHandle.replacingOccurrences(of: "anonymous_", with: "").prefix(1)).uppercased())
                                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                                .foregroundColor(Color.toskaBlue)
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(convo.otherHandle)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundColor(Color.toskaTextDark)
                                                Spacer()
                                                Text(convo.timeAgo)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color.toskaTimestamp)
                                            }
                                            
                                            HStack(spacing: 4) {
                                                Text(convo.lastMessage)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(Color(hex: "999999"))
                                                    .lineLimit(1)
                                                
                                                Spacer()
                                                
                                                if convo.isSealed {
                                                    Text("sealed")
                                                        .font(.system(size: 9, weight: .medium))
                                                        .foregroundColor(Color.toskaTimestamp)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color(hex: "dfe1e5").opacity(0.5))
                                                        .cornerRadius(4)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                
                                Rectangle()
                                    .fill(Color(hex: "dfe1e5"))
                                    .frame(height: 0.5)
                                    .padding(.leading, 68)
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
                    .navigationDestination(item: $selectedConversation) { convo in
                        ConversationView(
                            conversationId: convo.id,
                            otherHandle: convo.otherHandle,
                            otherUserId: convo.otherUserId
                        )
                        .navigationBarHidden(true)
                    }
                    .navigationBarHidden(true)
                    }
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
        listener = Firestore.firestore().collection("conversations")
            .whereField("participants", arrayContains: uid)
            .order(by: "lastMessageAt", descending: true)
            .limit(to: 30)
            .addSnapshotListener { snapshot, _ in
                Task { @MainActor in
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
