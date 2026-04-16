import SwiftUI
import FirebaseFirestore

@MainActor
struct LastThingSaidView: View {
    @Environment(\.dismiss) var dismiss
    struct FinalPost {
            let handle: String
            let text: String
            let tag: String?
            let likes: Int
            let leftAgo: String
        }
        
        @State private var finalPosts: [FinalPost] = []
        @State private var isLoading = true
        
        var displayPosts: [FinalPost] { finalPosts }
    
    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 2) {
                        Text("the last thing they said")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text("final posts from people who left")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.25))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14))
                        .foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                
                if isLoading && finalPosts.isEmpty {
                    Spacer()
                    ProgressView().tint(Color.toskaBlue)
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            VStack(spacing: 8) {
                                Image(systemName: "leaf")
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundColor(Color.toskaBlue.opacity(0.4))
                                
                                Text("some people come to toska, say what they\nneed to say, and leave. these are their\nlast words before they went.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.2))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                            }
                            .padding(.vertical, 24)
                            
                            if finalPosts.isEmpty && !isLoading {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles").font(.system(size: 8))
                                    Text("examples — real posts will appear as people leave toska")
                                        .font(.system(size: 9))
                                }
                                .foregroundColor(.white.opacity(0.15))
                                .padding(.bottom, 8)
                            }
                            
                            ForEach(Array(displayPosts.enumerated()), id: \.offset) { index, post in
                                                            VStack(alignment: .leading, spacing: 0) {
                                                                HStack(spacing: 5) {
                                                                    Circle()
                                                                        .fill(.white.opacity(0.1))
                                                                        .frame(width: 5, height: 5)
                                                                    
                                                                    Text(post.leftAgo)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                    .padding(.bottom, 8)
                                    
                                                                Text(post.text)
                                        .font(.custom("Georgia", size: 15))
                                        .foregroundColor(.white.opacity(0.85))
                                        .lineSpacing(5)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.bottom, 10)
                                    
                                    HStack {
                                        if let tag = post.tag {
                                            Text(tag)
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundColor(tagColor(for: tag).opacity(0.4))
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 3) {
                                            Image(systemName: "heart.fill")
                                                .font(.system(size: 8))
                                            Text("\(formatCount(post.likes)) felt this")
                                                .font(.system(size: 9, weight: .medium))
                                        }
                                        .foregroundColor(Color.toskaBlue.opacity(0.4))
                                    }
                                    .padding(.bottom, 4)
                                    
                                                                Text(post.handle)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.1))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 18)
                                
                                if index < displayPosts.count - 1 {
                                    HStack {
                                        Spacer()
                                        Circle()
                                            .fill(.white.opacity(0.06))
                                            .frame(width: 3, height: 3)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            
                            VStack(spacing: 6) {
                                Rectangle()
                                    .fill(.white.opacity(0.04))
                                    .frame(width: 40, height: 0.5)
                                
                                Text("some goodbyes are never said out loud")
                                    .font(.custom("Georgia-Italic", size: 11))
                                    .foregroundColor(.white.opacity(0.12))
                                
                                Text("toska")
                                    .font(.custom("Georgia-Italic", size: 10))
                                    .foregroundColor(.white.opacity(0.08))
                            }
                            .padding(.vertical, 30)
                            
                            Color.clear.frame(height: 40)
                        }
                    }
                }
            }
        }
        .onAppear {
            fetchFinalPosts()
        }
    }
    
    func fetchFinalPosts() {
        let db = Firestore.firestore()
        
        db.collection("finalPosts")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 20)
                    .getDocuments { snapshot, _ in
                        Task { @MainActor in
                            guard let documents = snapshot?.documents else {
                                isLoading = false
                                return
                            }
                            
                            finalPosts = documents.compactMap { doc in
                                                let data = doc.data()
                                                let authorId = data["authorId"] as? String ?? ""
                                                if BlockedUsersCache.shared.isBlocked(authorId) { return nil }
                                                let leftAt = (data["leftAt"] as? Timestamp)?.dateValue() ?? Date()
                                                
                                return FinalPost(
                                                                                    handle: data["authorHandle"] as? String ?? "anonymous",
                                                                                    text: data["text"] as? String ?? "",
                                                                                    tag: data["tag"] as? String,
                                                                                    likes: data["likeCount"] as? Int ?? 0,
                                                                                    leftAgo: timeAgoLeft(from: leftAt)
                                                                                )
                                            }
                            
                            isLoading = false
                        }
                    }
    }
    
    func timeAgoLeft(from date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days == 0 { return "left today" }
        if days == 1 { return "left yesterday" }
        if days < 7 { return "left \(days) days ago" }
        let weeks = days / 7
        if weeks < 5 { return "left \(weeks) \(weeks == 1 ? "week" : "weeks") ago" }
        let months = days / 30
        return "left \(months) \(months == 1 ? "month" : "months") ago"
    }
    
}
