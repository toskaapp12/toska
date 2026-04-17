import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
struct TopView: View {
    @State private var rankedPosts: [RankedPost] = []
        @State private var isLoading = true
        @State private var selectedPostId: String? = nil
    @State private var selectedPostData: PostDetailData? = nil
    @State private var showPost = false
            @State private var hasFetchedInitial = false
    
    var body: some View {
        ZStack {
                        LateNightTheme.background.ignoresSafeArea()
                        
                        VStack(spacing: 0) {
                    HStack {
                        Text("felt the most")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(Color.toskaTextDark)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: "6ba58e"))
                                .frame(width: 5, height: 5)
                            Text("right now")
                                                            .font(.system(size: 10, weight: .semibold))
                                                            .foregroundColor(Color(hex: "6ba58e"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)
                    
                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.toskaBlue)
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            if rankedPosts.isEmpty {
                                                            VStack(spacing: 8) {
                                                                Image(systemName: "chart.line.uptrend.xyaxis")
                                                                    .font(.system(size: 24, weight: .light))
                                                                    .foregroundColor(Color.toskaDivider)
                                                                Text("nothing yet")
                                                                                                                                                                                                    .font(.system(size: 13))
                                                                                                                                                                                                    .foregroundColor(Color.toskaTextLight)
                                                                                                                                                                                                Text("everyones being quiet right now.")
                                                                                                                                                                                                    .font(.system(size: 11))
                                                                                                                                                                                                    .foregroundColor(Color(hex: "cccccc"))
                                                            }
                                                            .frame(maxWidth: .infinity)
                                                            .padding(.vertical, 80)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(rankedPosts.enumerated()), id: \.element.id) { index, post in
                                                                            let rank = index + 1
                                        Button {
                                                                                    openPost(postId: post.id, authorId: post.authorId)
                                                                                } label: {
                                                                                    VStack(alignment: .leading, spacing: 0) {
                                                                                        HStack(alignment: .top, spacing: 10) {
                                                                                            // Rank badge
                                                                                            Text("\(rank)")
                                                                                                .font(.system(size: rank <= 3 ? 16 : 11, weight: .bold, design: .rounded))
                                                                                                .foregroundColor(rank == 1 ? Color(hex: "c9a97a") : rank == 2 ? Color.toskaTextLight : rank == 3 ? Color(hex: "cd7f32") : Color.toskaDivider)
                                                                                                .frame(width: 24, alignment: .center)
                                                                                                .padding(.top, 2)
                                                                                            
                                                                                            VStack(alignment: .leading, spacing: 6) {
                                                                                                HStack(spacing: 4) {
                                                                                                    Text(post.handle)
                                                                                                        .font(.system(size: 11, weight: .semibold))
                                                                                                        .foregroundColor(Color.toskaBlue)
                                                                                                    Spacer()
                                                                                                    if let tag = post.tag {
                                                                                                        Text(tag)
                                                                                                            .font(.system(size: 9, weight: .medium))
                                                                                                            .foregroundColor(tagColor(for: tag).opacity(0.8))
                                                                                                            .padding(.horizontal, 7)
                                                                                                            .padding(.vertical, 2.5)
                                                                                                            .background(tagColor(for: tag).opacity(0.07))
                                                                                                            .cornerRadius(4)
                                                                                                    }
                                                                                                }
                                                                                                
                                                                                                Text(post.text)
                                                                                                    .font(.custom("Georgia", size: 15))
                                                                                                    .foregroundColor(Color(hex: "1a1a1a"))
                                                                                                    .lineSpacing(4)
                                                                                                    .multilineTextAlignment(.leading)
                                                                                                    .fixedSize(horizontal: false, vertical: true)
                                                                                                
                                                                                                HStack(spacing: 3) {
                                                                                                    Image(systemName: "heart.fill")
                                                                                                        .font(.system(size: 9))
                                                                                                    Text("\(formatCount(post.likes)) felt this")
                                                                                                        .font(.system(size: 10))
                                                                                                }
                                                                                                .foregroundColor(Color(hex: "c47a8a").opacity(0.6))
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                    .padding(.horizontal, 16)
                                                                                    .padding(.vertical, 14)
                                                                                }
                                                                                .buttonStyle(.plain)
                                                                                
                                                                                Rectangle()
                                                                                    .fill(Color(hex: "dfe1e5"))
                                                                                    .frame(height: 0.5)
                                    }
                                    
                                    Color.clear.frame(height: 80)
                                }
                            }
                        }
                        .refreshable {
                                                    await withCheckedContinuation { continuation in
                                                        fetchTopPosts(onComplete: { continuation.resume() })
                                                    }
                                                }
                    }
                }
            }
        .onAppear {
                    guard !hasFetchedInitial else { return }
                    hasFetchedInitial = true
            fetchTopPosts()
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
    }
    
    
    func fetchTopPosts(onComplete: (() -> Void)? = nil) {
                    let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
        Firestore.firestore().collection("posts")
                            .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
                            .order(by: "createdAt", descending: true)
                            .limit(to: 50)
                    .getDocuments { snapshot, error in
                    Task { @MainActor in
                        if let error = error {
                                                                            print("❌ TopView query error: \(error)")
                                                                            isLoading = false
                                                                            onComplete?()
                                                                            return
                                                                        }
                                                guard let documents = snapshot?.documents else {
                                                    isLoading = false
                                                    onComplete?()
                                                    return
                                                }
                        print("📊 TopView got \(documents.count) docs")
                        // Filter blocked/expired, compute engagement + velocity
                        var engaged: [(handle: String, text: String, tag: String?, likes: Int, id: String, authorId: String, score: Double)] = []
                        
                        for doc in documents {
                            let data = doc.data()
                            let authorId = data["authorId"] as? String ?? ""
                            if BlockedUsersCache.shared.isBlocked(authorId) { continue }
                            if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { continue }
                            
                            let likeCount = data["likeCount"] as? Int ?? 0
                            let replyCount = data["replyCount"] as? Int ?? 0
                            let repostCount = data["repostCount"] as? Int ?? 0
                            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                            
                            let hoursAge = max(0.5, Date().timeIntervalSince(createdAt) / 3600)
                            let engagement = Double(likeCount) + Double(replyCount) * 2 + Double(repostCount) * 1.5
                            
                            let recencyMultiplier: Double
                            if hoursAge < 2 { recencyMultiplier = 3.0 }
                            else if hoursAge < 6 { recencyMultiplier = 2.0 }
                            else if hoursAge < 12 { recencyMultiplier = 1.5 }
                            else { recencyMultiplier = 1.0 }
                            
                            let velocity = (engagement / hoursAge) * recencyMultiplier
                            
                            let entry = (
                                handle: data["authorHandle"] as? String ?? "anonymous",
                                text: data["text"] as? String ?? "",
                                tag: data["tag"] as? String,
                                likes: likeCount,
                                id: doc.documentID,
                                authorId: authorId,
                                score: velocity
                            )
                            
                            if engagement > 0 {
                                                            engaged.append(entry)
                                                        }
                        }
                        
                        // Only show posts with actual engagement — if nothing has
                                                // any likes/replies/reposts yet, show the empty state rather
                                                // than listing posts in an arbitrary order labeled "trending"
                                                rankedPosts = engaged
                                                    .sorted { $0.score > $1.score }
                                                    .prefix(10)
                                                    .map { RankedPost(id: $0.id, handle: $0.handle, text: $0.text, tag: $0.tag, likes: $0.likes, authorId: $0.authorId) }
                        print("📊 TopView showing \(rankedPosts.count) ranked, engaged: \(engaged.count)")
                        isLoading = false
                                                onComplete?()
                                            }
                                        }
                                }
    
    func rankColor(for rank: Int) -> Color {
        switch rank {
        case 2: return Color.toskaTimestamp
        case 3: return Color(hex: "cd7f32")
        default: return Color(hex: "cccccc")
        }
    }
    
    func formatFull(_ count: Int) -> String {
                ToskaFormatters.decimalNumber.string(from: NSNumber(value: count)) ?? "\(count)"
            }
        
        func openPost(postId: String, authorId: String) {
            guard !postId.isEmpty else { return }
            Firestore.firestore().collection("posts").document(postId).getDocument { snapshot, _ in
                Task { @MainActor in
                    guard let data = snapshot?.data() else {
                                            rankedPosts.removeAll { $0.id == postId }
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
                                            authorId: authorId
                                        )
                    showPost = true
                }
            }
        }
        
        }
